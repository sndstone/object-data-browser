"""s3ConformanceOp for the Python engine against a local fake S3 server."""
import base64
import hashlib
import importlib.util
import json
import sys
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import parse_qs, unquote, urlparse

import pytest

ROOT = Path(__file__).parents[2]
VECTORS = json.loads((ROOT / 'contracts/vectors/s3-conformance-body.json').read_text())
SECRET = 'fixture-secret-key-value-0123456789'
SESSION = 'fixture-session-token-0123456789'


class FakeS3(BaseHTTPRequestHandler):
    store: dict = {}
    requests: list = []

    def log_message(self, *_):
        pass

    def _send(self, status, body=b'', headers=None):
        self.send_response(status)
        for name, value in (headers or {}).items():
            self.send_header(name, value)
        self.send_header('Content-Length', str(len(body)))
        self.send_header('X-Unlisted-Header', 'leak')
        self.send_header('Set-Cookie', 'session=leak')
        self.end_headers()
        if self.command != 'HEAD':
            self.wfile.write(body)

    def _route(self):
        url = urlparse(self.path)
        parts = url.path.lstrip('/').split('/', 1)
        return parts[0], unquote(parts[1]) if len(parts) > 1 else '', parse_qs(url.query, keep_blank_values=True)

    def do_PUT(self):
        bucket, key, query = self._route()
        length = int(self.headers.get('Content-Length') or 0)
        data = self.rfile.read(length)
        FakeS3.requests.append(('PUT', self.path, dict(self.headers)))
        if 'x-amz-copy-source' in {k.lower() for k in self.headers}:
            source = unquote(self.headers['x-amz-copy-source']).lstrip('/').split('/', 1)[1]
            if source not in FakeS3.store:
                return self._send(404, b'<Error><Code>NoSuchKey</Code><Message>missing</Message></Error>')
            FakeS3.store[key] = FakeS3.store[source]
            return self._send(200, b'<CopyObjectResult><ETag>"c"</ETag>'
                                   b'<LastModified>2026-01-02T03:04:05.000Z</LastModified></CopyObjectResult>')
        FakeS3.store[key] = data
        return self._send(200, headers={'ETag': '"%s"' % hashlib.md5(data).hexdigest(),
                                        'x-amz-version-id': 'v1', 'x-amz-meta-Color': 'blue'})

    def do_GET(self):
        bucket, key, query = self._route()
        FakeS3.requests.append(('GET', self.path, dict(self.headers)))
        if 'list-type' in query:
            body = ('<ListBucketResult><Name>b</Name><Prefix></Prefix><KeyCount>1</KeyCount><MaxKeys>1</MaxKeys>'
                    '<IsTruncated>true</IsTruncated><NextContinuationToken>opaque+token/==</NextContinuationToken>'
                    '<Contents><Key>a b+c</Key><ETag>"e"</ETag><Size>3</Size>'
                    '<LastModified>2026-01-02T03:04:05.000Z</LastModified><StorageClass>STANDARD</StorageClass></Contents>'
                    '</ListBucketResult>').encode()
            return self._send(200, body)
        if key == 'redirect':
            return self._send(301, b'<Error><Code>PermanentRedirect</Code><Message>elsewhere</Message></Error>',
                              {'x-amz-bucket-region': 'eu-west-1'})
        if key == 'echo':
            return self._send(403, ('<Error><Code>AccessDenied</Code><Message>token ' + SESSION + ' rejected</Message></Error>').encode())
        if key == 'signing':
            message = ('Signature=deadbeef Signature=&quot;quoted0&quot; X-Amz-Credential=AKIDFIXTURE/20260101 see HTTPS://Host.example/b/k?X-Amz-Signature=cafe '
                       'secret test ' + 'z' * 300 + SESSION)
            return self._send(403, ('<Error><Code>AccessDenied</Code><Message>' + message + '</Message></Error>').encode())
        if key == 'location':
            return self._send(200, b'x', {'Location': 'https://elsewhere.example/b/k?X-Amz-Signature=abc&X-Amz-Credential=def'})
        if key == 'deleted':
            return self._send(404, b'<Error><Code>NoSuchKey</Code><Message>gone</Message></Error>',
                              {'x-amz-delete-marker': 'true', 'x-amz-version-id': 'dm1'})
        if key == 'fresh':
            return self._send(304, headers={'ETag': '"e"'})
        if key not in FakeS3.store:
            return self._send(404, b'<Error><Code>NoSuchKey</Code><Message>The key does not exist</Message></Error>')
        data = FakeS3.store[key]
        return self._send(200, data, {'ETag': '"%s"' % hashlib.md5(data).hexdigest(), 'Content-Type': 'text/plain'})

    def do_HEAD(self):
        bucket, key, query = self._route()
        if key not in FakeS3.store:
            return self._send(404)
        return self._send(200, headers={'ETag': '"x"'})

    def do_POST(self):
        bucket, key, query = self._route()
        length = int(self.headers.get('Content-Length') or 0)
        self.rfile.read(length)
        if 'uploadId' in query:
            return self._send(200, b'<?xml version="1.0"?><Error><Code>InternalError</Code><Message>try again</Message></Error>')
        if 'delete' in query:
            body = (b'<DeleteResult><Deleted><Key>a</Key></Deleted><Deleted><Key>b</Key><DeleteMarker>true</DeleteMarker>'
                    b'<DeleteMarkerVersionId>dm</DeleteMarkerVersionId></Deleted>'
                    b'<Error><Key>c</Key><Code>AccessDenied</Code><Message>no</Message></Error></DeleteResult>')
            return self._send(200, body)
        return self._send(400, b'<Error><Code>InvalidRequest</Code></Error>')


@pytest.fixture(scope='module')
def server():
    httpd = ThreadingHTTPServer(('127.0.0.1', 0), FakeS3)
    thread = threading.Thread(target=httpd.serve_forever, daemon=True)
    thread.start()
    yield f'http://127.0.0.1:{httpd.server_address[1]}'
    httpd.shutdown()


@pytest.fixture
def engine():
    spec = importlib.util.spec_from_file_location('conformance_test_engine', ROOT / 'engines/python/src/main.py')
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    yield module
    sys.modules.pop(spec.name, None)


def profile(url):
    return {'id': 'p', 'endpointType': 's3Compatible', 'endpointUrl': url, 'region': 'us-east-1',
            'accessKey': 'AKIDFIXTURE', 'secretKey': SECRET, 'sessionToken': SESSION, 'pathStyle': True,
            'maxAttempts': 5}


def call(engine, url, op, input=None, **extra):
    return engine.handle_request({'requestId': '1', 'method': 's3ConformanceOp', 'engineVersion': '1.0',
                                  'params': {'profile': profile(url), 'op': op, 'input': input or {}, **extra}})


def test_generator_vectors(engine):
    module = engine._conformance_module()
    for case in VECTORS['cases']:
        data = module.generate_body(case['size'], case['seed'])
        assert hashlib.sha256(data).hexdigest() == case['sha256']
        assert data[:8].hex() == case['first8Hex']


def test_put_get_roundtrip_reports_digest_and_allowlisted_headers(engine, server):
    put = call(engine, server, 'PutObject', {'Bucket': 'b', 'Key': 'k', 'ContentType': 'text/plain'},
               body={'generate': {'size': 2048, 'seed': 7}})
    assert put['outcome'] == 'service' and put['httpStatus'] == 200
    assert put['headers']['x-amz-version-id'] == 'v1'
    assert put['headers']['x-amz-meta-color'] == 'blue'
    assert 'x-unlisted-header' not in put['headers'] and 'set-cookie' not in put['headers']
    assert put['attempts'] == 1 and put['latencyMs'] >= 0
    got = call(engine, server, 'GetObject', {'Bucket': 'b', 'Key': 'k'})
    assert got['httpStatus'] == 200
    assert got['output']['Body'] == {'length': 2048, 'sha256': VECTORS['cases'][4]['sha256']}
    assert all(name == name.lower() for name in got['headers'])


def test_service_errors_are_successful_observations(engine, server):
    missing = call(engine, server, 'GetObject', {'Bucket': 'b', 'Key': 'nope'})
    assert (missing['outcome'], missing['httpStatus'], missing['errorCode']) == ('service', 404, 'NoSuchKey')
    marker = call(engine, server, 'GetObject', {'Bucket': 'b', 'Key': 'deleted'})
    assert marker['headers']['x-amz-delete-marker'] == 'true'
    head = call(engine, server, 'HeadObject', {'Bucket': 'b', 'Key': 'nope'})
    assert (head['outcome'], head['httpStatus']) == ('service', 404)
    fresh = call(engine, server, 'GetObject', {'Bucket': 'b', 'Key': 'fresh', 'IfNoneMatch': '"e"'})
    assert fresh['httpStatus'] == 304


def test_list_projection_keeps_cursor(engine, server):
    listed = call(engine, server, 'ListObjectsV2', {'Bucket': 'b', 'MaxKeys': 1})
    output = listed['output']
    assert output['NextContinuationToken'] == 'opaque+token/=='
    assert output['Contents'][0]['Key'] == 'a b+c'
    assert output['Contents'][0]['LastModified'] == '2026-01-02T03:04:05Z'
    assert output['IsTruncated'] is True


def test_delete_objects_projection(engine, server):
    result = call(engine, server, 'DeleteObjects', {'Bucket': 'b', 'Delete': {'Objects': [{'Key': 'a'}, {'Key': 'b'}, {'Key': 'c'}]}})
    assert [d['Key'] for d in result['output']['Deleted']] == ['a', 'b']
    assert result['output']['Deleted'][1]['DeleteMarker'] is True
    assert result['output']['Errors'][0]['Code'] == 'AccessDenied'


def test_copy_source_encodes_plus_and_space_once(engine, server):
    call(engine, server, 'PutObject', {'Bucket': 'b', 'Key': 'src a+b%c'}, body={'text': 'hello'})
    FakeS3.requests.clear()
    copied = call(engine, server, 'CopyObject', {'Bucket': 'b', 'Key': 'dst', 'CopySource': {'Bucket': 'b', 'Key': 'src a+b%c'}})
    assert copied['httpStatus'] == 200 and copied['output']['CopyObjectResult']['ETag'] == '"c"'
    header = [h for m, p, h in FakeS3.requests if m == 'PUT'][0]
    source = {k.lower(): v for k, v in header.items()}['x-amz-copy-source']
    assert '%2B' in source and '+' not in source and ' ' not in source


def test_unknown_op_and_customer_key_in_input_are_rejected(engine, server):
    with pytest.raises(Exception) as unknown:
        call(engine, server, 'DeleteEverything', {'Bucket': 'b'})
    assert getattr(unknown.value, 'code', '') == 'unsupported_feature'
    with pytest.raises(Exception) as inline:
        call(engine, server, 'PutObject', {'Bucket': 'b', 'Key': 'k', 'SSECustomerKey': 'x'})
    assert getattr(inline.value, 'code', '') == 'invalid_request'


def test_presigned_request_never_returns_url_or_signature(engine, server):
    call(engine, server, 'PutObject', {'Bucket': 'b', 'Key': 'p'}, body={'text': 'presigned'})
    result = call(engine, server, 'PresignedRequest', {'Method': 'GET', 'Bucket': 'b', 'Key': 'p', 'ExpiresIn': 60})
    assert result['httpStatus'] == 200
    assert result['output']['Body']['sha256'] == hashlib.sha256(b'presigned').hexdigest()
    assert 'X-Amz-Signature' in result['output']['Presign']['QueryKeys']
    text = json.dumps(result)
    assert 'X-Amz-Signature=' not in text and SECRET not in text and SESSION not in text
    put = call(engine, server, 'PresignedRequest', {'Method': 'PUT', 'Bucket': 'b', 'Key': 'q', 'ContentType': 'text/plain'},
               body={'text': 'uploaded'})
    assert put['httpStatus'] == 200 and FakeS3.store['q'] == b'uploaded'


def test_capability_and_health(engine):
    caps = engine.handle_request({'method': 'getCapabilities', 'params': {'profile': {'endpointType': 's3Compatible'}}})
    item = next(i for i in caps['items'] if i['key'] == 'conformance.s3')
    assert item['state'] == 'supported' and 'PutObject' in item['ops'] and item['client']['maxAttempts'] == 1
    assert 's3ConformanceOp' in engine.handle_request({'method': 'health', 'params': {}})['methods']


def test_non_s3_profiles_are_unsupported(engine):
    with pytest.raises(Exception) as error:
        engine.handle_request({'method': 's3ConformanceOp', 'params': {
            'profile': {'endpointType': 'azureBlob', 'endpointUrl': 'https://a.blob.core.windows.net', 'authMode': 'azureSas',
                        'azureSasToken': 'sv=x'}, 'op': 'HeadBucket', 'input': {'Bucket': 'b'}}})
    assert getattr(error.value, 'code', '') == 'unsupported_feature'


def test_transport_failure_is_an_observation(engine):
    result = call(engine, 'http://127.0.0.1:9', 'HeadBucket', {'Bucket': 'b'})
    assert result['outcome'] == 'transport' and result['httpStatus'] == 0


def test_customer_key_never_reaches_output(engine, server):
    key = base64.b64encode(bytes(range(32))).decode()
    result = call(engine, server, 'PutObject', {'Bucket': 'b', 'Key': 'sse'}, body={'text': 'x'},
                  encryption={'mode': 'sse-c', 'customerKey': key})
    assert result['httpStatus'] == 200 and key not in json.dumps(result)


def test_one_observation_is_one_request(engine, server):
    FakeS3.requests.clear()
    result = call(engine, server, 'GetObject', {'Bucket': 'b', 'Key': 'redirect'})
    assert (result['httpStatus'], result['errorCode'], result['attempts']) == (301, 'PermanentRedirect', 1)
    assert len([r for r in FakeS3.requests if r[0] == 'GET']) == 1


def test_error_embedded_in_200_keeps_the_wire_status(engine, server):
    result = call(engine, server, 'CompleteMultipartUpload', {
        'Bucket': 'b', 'Key': 'k', 'UploadId': 'u', 'MultipartUpload': {'Parts': [{'PartNumber': 1, 'ETag': '"e"'}]}})
    assert (result['httpStatus'], result['errorCode']) == (200, 'InternalError')


def test_echoed_credentials_and_signed_locations_are_redacted(engine, server):
    echoed = call(engine, server, 'GetObject', {'Bucket': 'b', 'Key': 'echo'})
    assert SESSION not in json.dumps(echoed) and '[redacted]' in echoed['errorMessage']
    located = call(engine, server, 'GetObject', {'Bucket': 'b', 'Key': 'location'})
    assert located['headers']['location'] == 'https://elsewhere.example/b/k?[query]'


def test_diagnostics_scrub_short_credentials_signing_values_and_clip_after(engine, server):
    url = server
    short = {**profile(url), 'accessKey': 'test', 'secretKey': 'test'}
    result = engine.handle_request({'method': 's3ConformanceOp', 'params': {
        'profile': short, 'op': 'GetObject', 'input': {'Bucket': 'b', 'Key': 'signing'}}})
    message = result['errorMessage']
    assert len(message) <= 256
    assert result['errorCode'] == 'AccessDenied'
    for leaked in ('deadbeef', 'quoted0', 'AKIDFIXTURE/2026', 'cafe', ' test '):
        assert leaked not in message, leaked
    # A long session token clipped at the boundary must not survive as a prefix.
    full = call(engine, url, 'GetObject', {'Bucket': 'b', 'Key': 'signing'})
    assert SESSION[:12] not in json.dumps(full)


def test_short_credentials_stay_in_s3_data(engine, server):
    short = {**profile(server), 'accessKey': 'test', 'secretKey': 'test'}
    result = engine.handle_request({'method': 's3ConformanceOp', 'params': {
        'profile': short, 'op': 'ListObjectsV2', 'input': {'Bucket': 'b', 'MaxKeys': 1}}})
    assert result['output']['Contents'][0]['Key'] == 'a b+c'


def test_presigned_error_text_is_unescaped_before_scrubbing(engine, server):
    result = call(engine, server, 'PresignedRequest', {'Method': 'GET', 'Bucket': 'b', 'Key': 'signing', 'ExpiresIn': 60})
    assert result['httpStatus'] == 403 and result['errorCode'] == 'AccessDenied'
    assert 'quoted0' not in json.dumps(result) and 'deadbeef' not in json.dumps(result)
