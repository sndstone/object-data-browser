"""Provider encryption against signed SDK/HTTP fixtures; no cloud credentials."""
import base64
import hashlib
import importlib.util
import io
import json
import sys
from pathlib import Path
from types import SimpleNamespace
from urllib.parse import parse_qs, urlparse
from unittest.mock import Mock

import pytest
from botocore.awsrequest import AWSResponse
from botocore.exceptions import ClientError, ReadTimeoutError
from urllib3 import HTTPResponse
from urllib3._collections import HTTPHeaderDict


KEY = base64.b64encode(bytes(range(32))).decode()
SOURCE_KEY = base64.b64encode(bytes(range(32, 64))).decode()
MODES = [None, {'mode': 'bucketDefault'}, {'mode': 'sse-s3'},
         {'mode': 'sse-kms', 'kmsKeyId': 'arn:fixture', 'kmsEncryptionContext': {'purpose': '測試'}, 'bucketKeyEnabled': False},
         {'mode': 'dsse-kms', 'kmsKeyId': 'arn:fixture', 'kmsEncryptionContext': {'purpose': 'test'}},
         {'mode': 'sse-c', 'customerKey': KEY}]
AZURE_MODES = [None, {'mode': 'bucketDefault'}, {'mode': 'azure-scope', 'encryptionScope': 'fixture-scope'},
               {'mode': 'azure-cpk', 'customerKey': KEY}]


@pytest.fixture
def engine(monkeypatch, tmp_path):
    spec = importlib.util.spec_from_file_location('encryption_test_engine', Path(__file__).parents[2] / 'engines/python/src/main.py')
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    monkeypatch.setattr(module, '_runtime_dir', lambda: tmp_path)
    monkeypatch.setattr(module, '_recovery_dir', lambda: tmp_path)
    # Copy's liveness thread has no role in these synchronous fixture requests.
    real_thread = module.threading.Thread
    monkeypatch.setattr(module.threading, 'Thread', lambda *a, **k: SimpleNamespace(start=lambda: None)
                        if getattr(k.get('target'), '__name__', '') == 'heartbeat' else real_thread(*a, **k))
    yield module
    for client in module._CLIENT_CACHE.values(): client.close()
    for client in module._AZURE_CLIENT_CACHE.values(): client.pool.clear()
    sys.modules.pop(spec.name, None)


@pytest.fixture
def profile():
    return {'id': 'encryption-fixture', 'endpointType': 's3Compatible', 'endpointUrl': 'http://127.0.0.1:9876',
            'region': 'us-east-1', 'accessKey': 'fixture', 'secretKey': base64.b64encode(b'fixture').decode(),
            'pathStyle': True, 'maxAttempts': 1, 'maxConcurrentRequests': 1,
            'diagnostics': {'enableApiLogging': True}}


class Raw(io.BytesIO):
    def stream(self, amt=65536, **_):
        while data := self.read(amt): yield data


class StorageFixture:
    def __init__(self, azure=False):
        self.azure, self.calls = azure, []
        self.size = 7
        self.reported = {}
        self.retry_range = False
        self.failed_range = False
        self.fail_write = False
        self.fail_body = False

    def response(self, method, url, headers):
        query = parse_qs(urlparse(url).query, keep_blank_values=True)
        self.calls.append((method, url, headers))
        response_headers = {'ETag': '"etag"', **self.reported}
        status, data = 200, b''
        if method == 'HEAD':
            response_headers['Content-Length'] = str(self.size)
        elif method == 'GET' and ('tagging' in query or query.get('comp') == ['tags']):
            data = b'<Tagging><TagSet/></Tagging>' if not self.azure else b'<Tags><TagSet/></Tags>'
        elif method == 'GET':
            start, end = 0, self.size - 1
            if 'range' in headers:
                start, end = map(int, headers['range'][6:].split('-'))
                status = 206
                response_headers['Content-Range'] = f'bytes {start}-{end}/{self.size}'
                if self.retry_range and not self.failed_range:
                    self.failed_range = True
                    if self.azure: self.fail_body = True
                    else: raise ReadTimeoutError(endpoint_url=url)
            data = b'A' * (end - start + 1)
        elif method in {'PUT', 'POST'} and self.fail_write:
            status = 403
            data = f'<Error><Code>AccessDenied</Code><Message>SSE-C blocked: {KEY}</Message></Error>'.encode()
        elif 'uploads' in query:
            data = b'<InitiateMultipartUploadResult><UploadId>fixture-upload</UploadId></InitiateMultipartUploadResult>'
        elif 'partNumber' in query and 'x-amz-copy-source' in headers:
            data = b'<CopyPartResult><ETag>"etag"</ETag></CopyPartResult>'
        elif 'uploadId' in query and method == 'POST':
            data = b'<CompleteMultipartUploadResult><ETag>"etag"</ETag></CompleteMultipartUploadResult>'
        elif 'x-amz-copy-source' in headers:
            data = b'<CopyObjectResult><ETag>"etag"</ETag></CopyObjectResult>'
        if 'x-ms-copy-source' in headers:
            response_headers.update({'x-ms-copy-id': 'fixture-copy', 'x-ms-copy-status': 'success'})
        response_headers.setdefault('Content-Length', str(len(data)))
        return status, response_headers, data

    def s3_send(self, request):
        headers = {k.lower(): v.decode() if isinstance(v, bytes) else str(v) for k, v in request.headers.items()}
        status, headers, data = self.response(request.method, request.url, headers)
        return AWSResponse(request.url, status, headers, Raw(data))

    def azure_send(self, method, url, **kwargs):
        headers = {k.lower(): str(v) for k, v in kwargs['headers'].items()}
        status, headers, data = self.response(method, url, headers)
        class Body(io.BytesIO):
            def read(self, *args):
                if self.fail_once:
                    self.fail_once = False
                    raise TimeoutError('fixture body timeout')
                return super().read(*args)
        body = Body(data)
        body.fail_once = self.fail_body
        self.fail_body = False
        return HTTPResponse(status=status, headers=HTTPHeaderDict(headers), body=body, preload_content=False)


def connect(engine, profile, monkeypatch, azure=False):
    profile = {**profile, **({'endpointType': 'azureBlob'} if azure else {})}
    parsed = engine._parse_profile(profile)
    fixture = StorageFixture(azure)
    if azure:
        client = engine._build_azure_client(parsed)
        monkeypatch.setattr(client.pool, 'request', fixture.azure_send)
    else:
        client = engine._build_client(parsed)
        monkeypatch.setattr(client._endpoint.http_session, 'send', fixture.s3_send)
    return profile, fixture


def request(engine, method, profile, **params):
    return engine.handle_request({'method': method, 'params': {'profile': profile, **params}})


def encryption_headers(value, source=False):
    if not value or value['mode'] == 'bucketDefault': return {}
    mode = value['mode']
    if mode == 'azure-scope': return {'x-ms-encryption-scope': value['encryptionScope']}
    if mode == 'azure-cpk':
        return {'x-ms-encryption-key': value['customerKey'], 'x-ms-encryption-algorithm': 'AES256',
                'x-ms-encryption-key-sha256': base64.b64encode(hashlib.sha256(base64.b64decode(value['customerKey'])).digest()).decode()}
    if mode == 'sse-c':
        prefix = 'x-amz-copy-source-server-side-encryption-customer-' if source else 'x-amz-server-side-encryption-customer-'
        return {prefix + 'algorithm': 'AES256', prefix + 'key': value['customerKey'],
                prefix + 'key-md5': base64.b64encode(hashlib.md5(base64.b64decode(value['customerKey'])).digest()).decode()}
    result = {'x-amz-server-side-encryption': {'sse-s3': 'AES256', 'sse-kms': 'aws:kms', 'dsse-kms': 'aws:kms:dsse'}[mode]}
    if 'kmsKeyId' in value: result['x-amz-server-side-encryption-aws-kms-key-id'] = value['kmsKeyId']
    if 'kmsEncryptionContext' in value:
        result['x-amz-server-side-encryption-context'] = base64.b64encode(json.dumps(value['kmsEncryptionContext'], ensure_ascii=False, separators=(',', ':')).encode()).decode()
    if 'bucketKeyEnabled' in value: result['x-amz-server-side-encryption-bucket-key-enabled'] = str(value['bucketKeyEnabled']).lower()
    return result


def only_encryption(headers):
    return {k: v for k, v in headers.items() if 'encryption' in k}


@pytest.mark.parametrize('azure,mode', [(False, mode) for mode in MODES] + [(True, mode) for mode in AZURE_MODES])
@pytest.mark.parametrize('multipart', [False, True])
def test_upload_exact_headers_all_modes(engine, profile, monkeypatch, tmp_path, capsys, azure, mode, multipart):
    profile, fixture = connect(engine, profile, monkeypatch, azure)
    monkeypatch.setattr(engine, '_AZURE_PUT_BLOB_LIMIT', 1 if multipart else 100)
    monkeypatch.setattr(engine, '_azure_block_size', lambda _: 4)
    file = tmp_path / 'file'
    file.write_bytes(b'payload' if not multipart or azure else b'A' * (5 * 1024**2 + 1))
    result = request(engine, 'startUpload', profile, bucketName='bucket', filePaths=[str(file)],
                     encryption=mode, multipartThresholdMiB=0 if multipart else 32, multipartChunkMiB=5)
    assert result['status'] == 'completed'
    for verb, url, headers in fixture.calls:
        expected = encryption_headers(mode)
        query = parse_qs(urlparse(url).query, keep_blank_values=True)
        if not azure and ('partNumber' in query or 'uploadId' in query):
            expected = expected if mode and mode['mode'] == 'sse-c' else {}
        assert only_encryption(headers) == expected
    if multipart:
        part_calls = [c for c in fixture.calls if 'partNumber=' in c[1] or parse_qs(urlparse(c[1]).query).get('comp') == ['block']]
        assert len(part_calls) == 2
    captured = capsys.readouterr()
    assert KEY not in json.dumps(result) + captured.out + captured.err


@pytest.mark.parametrize('azure,mode', [(False, mode) for mode in MODES] + [(True, mode) for mode in AZURE_MODES])
@pytest.mark.parametrize('operation', ['createFolder', 'runPutTestData'])
def test_folder_and_generated_data_headers(engine, profile, monkeypatch, azure, mode, operation):
    profile, fixture = connect(engine, profile, monkeypatch, azure)
    params = {'bucketName': 'bucket', 'key': 'folder'} if operation == 'createFolder' else {
        'config': {'bucketName': 'bucket', 'objectCount': 2, 'versions': 2}}
    request(engine, operation, profile, encryption=mode, **params)
    assert len(fixture.calls) == (1 if operation == 'createFolder' else 4)
    assert all(only_encryption(c[2]) == encryption_headers(mode) for c in fixture.calls)


@pytest.mark.parametrize('azure', [False, True])
@pytest.mark.parametrize('ranged', [False, True])
def test_customer_key_download_headers_and_retries(engine, profile, monkeypatch, tmp_path, capsys, azure, ranged):
    profile, fixture = connect(engine, profile, monkeypatch, azure)
    # Retry at the transfer layer, where every re-open must retain the key.
    profile = {**profile, 'maxAttempts': 2}
    # Keep the same transport for the changed immutable profile.
    builder = '_build_azure_client' if azure else '_build_client'
    client = getattr(engine, builder)(engine._parse_profile({**profile, 'maxAttempts': 1}))
    monkeypatch.setattr(engine, builder, lambda _: client)
    fixture.size = 1024**2 + 7 if ranged else 7
    fixture.retry_range = ranged
    mode = {'mode': 'azure-cpk' if azure else 'sse-c', 'customerKey': KEY}
    result = request(engine, 'startDownload', profile, bucketName='bucket', keys=['key'], destinationPath=str(tmp_path),
                     encryption=mode, multipartThresholdMiB=0 if ranged else 32, multipartChunkMiB=1)
    assert result['status'] == 'completed'
    assert (tmp_path / 'key').read_bytes() == b'A' * fixture.size
    assert all(only_encryption(c[2]) == encryption_headers(mode) for c in fixture.calls)
    assert len([c for c in fixture.calls if c[0] == 'GET']) == (3 if ranged else 1)
    captured = capsys.readouterr()
    assert KEY not in captured.out + captured.err + json.dumps(result)


@pytest.mark.parametrize('mode', MODES)
@pytest.mark.parametrize('multipart', [False, True])
def test_s3_copy_headers_single_and_multipart(engine, profile, monkeypatch, capsys, mode, multipart):
    profile, fixture = connect(engine, profile, monkeypatch)
    fixture.size = 5 * 1024**3 + 1 if multipart else 7
    source = {'mode': 'sse-c', 'customerKey': SOURCE_KEY}
    result = request(engine, 'copyObject', profile, sourceBucketName='bucket', sourceKey='source',
                     destinationBucketName='bucket', destinationKey='dest', encryption=mode, sourceEncryption=source)
    assert result['strategy'] == 'server-side-copy'
    for verb, url, headers in fixture.calls:
        query = parse_qs(urlparse(url).query, keep_blank_values=True)
        expected = {}
        if verb == 'HEAD':
            expected = encryption_headers(source) if urlparse(url).path.endswith('/source') else encryption_headers(mode) if mode and mode['mode'] == 'sse-c' else {}
        elif verb in {'PUT', 'POST'}:
            expected = encryption_headers(mode)
            if 'partNumber' in query or 'uploadId' in query:
                expected = expected if mode and mode['mode'] == 'sse-c' else {}
            if 'x-amz-copy-source' in headers: expected = {**expected, **encryption_headers(source, source=True)}
        assert only_encryption(headers) == expected
    if multipart: assert len([c for c in fixture.calls if 'partNumber=' in c[1]]) > 1
    captured = capsys.readouterr()
    assert KEY not in captured.out + captured.err + json.dumps(result)
    assert SOURCE_KEY not in captured.out + captured.err + json.dumps(result)


@pytest.mark.parametrize('move', [False, True])
@pytest.mark.parametrize('dest,source', [({'mode': 'azure-cpk', 'customerKey': KEY}, {'mode': 'azure-cpk', 'customerKey': SOURCE_KEY}),
    (None, {'mode': 'azure-cpk', 'customerKey': SOURCE_KEY}),
    ({'mode': 'azure-scope', 'encryptionScope': 'scope'}, {'mode': 'azure-cpk', 'customerKey': SOURCE_KEY}),
    ({'mode': 'azure-cpk', 'customerKey': KEY}, None)])
def test_azure_cpk_copy_uses_relay(engine, profile, monkeypatch, capsys, move, dest, source):
    profile, fixture = connect(engine, profile, monkeypatch, azure=True)
    result = request(engine, 'moveObject' if move else 'copyObject', profile, sourceBucketName='bucket', sourceKey='source',
                     destinationBucketName='bucket', destinationKey='dest', encryption=dest, sourceEncryption=source)
    assert result['strategy'] == 'relay'
    assert not any('x-ms-copy-source' in c[2] for c in fixture.calls)
    for verb, url, headers in fixture.calls:
        if parse_qs(urlparse(url).query).get('comp') == ['tags'] or verb == 'DELETE': continue
        expected = encryption_headers(source if '/source' in url else dest)
        if verb in {'HEAD', 'GET'} and dest and dest['mode'] == 'azure-scope' and '/source' not in url: expected = {}
        assert only_encryption(headers) == expected
    assert any(c[0] == 'DELETE' for c in fixture.calls) == move
    captured = capsys.readouterr()
    assert KEY not in captured.out + captured.err + json.dumps(result)
    assert SOURCE_KEY not in captured.out + captured.err + json.dumps(result)


@pytest.mark.parametrize('mode', AZURE_MODES)
def test_azure_async_copy_keeps_default_and_scope_headers(engine, profile, monkeypatch, mode):
    if mode and mode['mode'] == 'azure-cpk': return
    profile, fixture = connect(engine, profile, monkeypatch, azure=True)
    request(engine, 'copyObject', profile, sourceBucketName='bucket', sourceKey='source',
            destinationBucketName='bucket', destinationKey='dest', encryption=mode)
    puts = [c for c in fixture.calls if c[0] == 'PUT']
    assert len(puts) == 1 and 'x-ms-copy-source' in puts[0][2]
    assert only_encryption(puts[0][2]) == encryption_headers(mode)


@pytest.mark.parametrize('reported,expected', [({}, None),
    ({'x-amz-server-side-encryption': 'AES256'}, {'mode': 'sse-s3'}),
    ({'x-amz-server-side-encryption': 'aws:kms', 'x-amz-server-side-encryption-aws-kms-key-id': 'arn:key', 'x-amz-server-side-encryption-bucket-key-enabled': 'false'}, {'mode': 'sse-kms', 'kmsKeyId': 'arn:key', 'bucketKeyEnabled': False}),
    ({'x-amz-server-side-encryption': 'aws:kms:dsse'}, {'mode': 'dsse-kms'}),
    ({'x-amz-server-side-encryption-customer-algorithm': 'AES256', 'x-amz-server-side-encryption-customer-key-md5': 'fingerprint'}, {'mode': 'sse-c', 'customerKeyMd5': 'fingerprint'})])
def test_s3_details_normalized_and_keyed_head(engine, profile, monkeypatch, reported, expected):
    profile, fixture = connect(engine, profile, monkeypatch)
    fixture.reported = reported
    mode = {'mode': 'sse-c', 'customerKey': KEY}
    result = request(engine, 'getObjectDetails', profile, bucketName='bucket', key='key', encryption=mode)
    assert result.get('encryption') == expected
    assert only_encryption(fixture.calls[0][2]) == encryption_headers(mode)
    assert only_encryption(fixture.calls[1][2]) == {}


@pytest.mark.parametrize('reported,expected', [({}, None),
    ({'x-ms-server-encrypted': 'true'}, {'mode': 'provider', 'serverEncrypted': True}),
    ({'x-ms-server-encrypted': 'false', 'x-ms-encryption-scope': 'scope'}, {'mode': 'azure-scope', 'serverEncrypted': False, 'encryptionScope': 'scope'}),
    ({'x-ms-encryption-key-sha256': 'fingerprint'}, {'mode': 'azure-cpk', 'customerKeySha256': 'fingerprint'})])
def test_azure_details_normalized_and_keyed_head(engine, profile, monkeypatch, reported, expected):
    profile, fixture = connect(engine, profile, monkeypatch, azure=True)
    fixture.reported = reported
    mode = {'mode': 'azure-cpk', 'customerKey': KEY}
    result = request(engine, 'getObjectDetails', profile, bucketName='bucket', key='key', encryption=mode)
    assert result.get('encryption') == expected
    assert only_encryption(fixture.calls[0][2]) == encryption_headers(mode)


@pytest.mark.parametrize('value', [{}, [], 'sse-s3', {'mode': 'unknown'}, {'mode': []},
    {'mode': 'sse-s3', 'customerKey': KEY}, {'mode': 'bucketDefault', 'customerKey': KEY},
    {'mode': 'dsse-kms', 'bucketKeyEnabled': True}, {'mode': 'sse-kms', 'bucketKeyEnabled': 1},
    {'mode': 'sse-kms', 'kmsKeyId': 1}, {'mode': 'sse-kms', 'kmsEncryptionContext': {'a': 1}},
    {'mode': 'sse-kms', 'kmsEncryptionContext': []}, {'mode': 'sse-c'},
    {'mode': 'sse-c', 'customerKey': KEY[:-1]}, {'mode': 'sse-c', 'customerKey': base64.b64encode(b'x' * 31).decode()},
    {'mode': 'sse-c', 'customerKey': base64.b64encode(b'x' * 33).decode()}, {'mode': 'sse-c', 'customerKey': 5},
    {'mode': 'sse-c', 'customerKey': '測試'}, {'mode': 'azure-scope', 'encryptionScope': 'scope'}])
def test_invalid_options_are_safe_and_do_not_send(engine, profile, monkeypatch, value):
    profile, fixture = connect(engine, profile, monkeypatch)
    with pytest.raises(engine.SidecarError) as raised:
        request(engine, 'createFolder', profile, bucketName='bucket', key='folder', encryption=value)
    assert raised.value.code == 'invalid_config'
    assert KEY not in str(raised.value)
    assert not fixture.calls


@pytest.mark.parametrize('host,valid', [('https://example.invalid', True), ('http://localhost', True),
    ('http://127.1.2.3', True), ('http://[::1]', True), ('http://example.invalid', False),
    ('http://localhost.evil.invalid', False), ('http://192.168.1.1', False)])
@pytest.mark.parametrize('azure', [False, True])
def test_customer_key_requires_tls_or_loopback(engine, profile, host, valid, azure):
    profile = engine._parse_profile({**profile, 'endpointUrl': host, 'endpointType': 'azureBlob' if azure else 's3Compatible'})
    value = {'mode': 'azure-cpk' if azure else 'sse-c', 'customerKey': KEY}
    if valid: assert engine._parse_object_encryption(value, profile) == value
    else:
        with pytest.raises(engine.SidecarError) as raised: engine._parse_object_encryption(value, profile)
        assert raised.value.code == 'invalid_config'


@pytest.mark.parametrize('azure', [False, True])
def test_presign_rejects_customer_keys_and_capabilities(engine, profile, azure):
    profile = {**profile, 'endpointType': 'azureBlob' if azure else 's3Compatible'}
    with pytest.raises(engine.SidecarError) as raised:
        request(engine, 'generatePresignedUrl', profile, bucketName='bucket', key='key',
                encryption={'mode': 'azure-cpk' if azure else 'sse-c', 'customerKey': KEY})
    assert raised.value.code == 'unsupported_feature'
    items = {item['key']: item for item in request(engine, 'getCapabilities', profile)['items']}
    for mode in ['sse-s3', 'sse-kms', 'dsse-kms', 'sse-c', 'azure-scope', 'azure-cpk']:
        assert items['object.encryption.' + mode]['state'] == 'supported'


def test_provider_error_echo_is_redacted_without_mode_retry(engine, profile, monkeypatch, capsys):
    profile, fixture = connect(engine, profile, monkeypatch)
    fixture.fail_write = True
    engine._process_line(json.dumps({'requestId': 'failure', 'method': 'createFolder', 'params': {
        'profile': profile, 'bucketName': 'bucket', 'key': 'key', 'encryption': {'mode': 'sse-c', 'customerKey': KEY}}}))
    captured = capsys.readouterr()
    assert KEY not in captured.out + captured.err
    error = json.loads(captured.out)['error']
    assert error['code'] == 'auth_failed'
    assert error['details']['encryptionHint'] == 'sse_c_blocked'
    assert len(fixture.calls) == 1
    assert engine._CUSTOMER_KEYS == {}


@pytest.mark.parametrize('code,message,operation,status,hint', [
    ('400', 'Bad Request', 'HeadObject', 400, 'sse_c_key_required'),
    ('400', 'Bad Request', 'GetObject', 400, 'sse_c_key_required'),
    ('KMS.AccessDeniedException', 'Denied', 'PutObject', 403, 'kms_access_denied'),
    ('AccessDenied', 'kms:Decrypt is denied', 'GetObject', 403, 'kms_access_denied'),
    ('KMS.DisabledException', 'Disabled', 'PutObject', 400, 'kms_key_unavailable'),
    ('AccessDenied', 'Access denied', 'PutObject', 403, None),
    ('InvalidRequest', 'Customer key mismatch', 'GetObject', 400, 'sse_c_key_mismatch')])
def test_error_hints_keep_error_codes(engine, code, message, operation, status, hint):
    mapped = engine._map_exception(ClientError({'Error': {'Code': code, 'Message': message},
                                               'ResponseMetadata': {'HTTPStatusCode': status}}, operation))
    assert mapped.details.get('encryptionHint') == hint
    assert mapped.code == ('auth_failed' if code == 'AccessDenied' else 'unknown')


def test_secret_fields_and_persistence_boundaries(engine, profile, tmp_path):
    headers = {name: KEY for name in ('x-amz-server-side-encryption-customer-key',
               'X-Amz-Copy-Source-Server-Side-Encryption-Customer-Key', 'X-MS-ENCRYPTION-KEY', 'customerKey')}
    assert all(v == '[redacted]' for v in engine._sanitize_headers(headers).values())
    body = json.dumps({'encryption': {'customerKey': KEY}}).encode()
    assert KEY not in engine._summarize_http_body('application/json', body)
    state = {'id': 'upload-' + 'a' * 32, 'options': {'encryption': {'customerKey': KEY},
             'headers': headers, 'metadata': {'customerKey': KEY}}}
    engine._recovery_write(state)
    assert KEY not in engine._recovery_path(state['id']).read_text()
    engine._write_benchmark_state({'id': 'bench-encryption', 'profile': profile, 'config': state['options']})
    assert KEY not in engine._benchmark_state_path('bench-encryption').read_text()
    workflows = engine._advanced_module().Workflows(engine)
    workflows._atomic_write(tmp_path / 'checkpoint.json', state)
    assert KEY not in (tmp_path / 'checkpoint.json').read_text()


def test_bucket_encryption_round_trip_preserves_all_fields(engine, profile, monkeypatch):
    client = Mock()
    for name in ('get_bucket_versioning', 'get_bucket_lifecycle_configuration', 'get_bucket_policy',
                 'get_bucket_cors', 'get_bucket_tagging', 'get_object_lock_configuration'):
        getattr(client, name).return_value = {}
    config = {'Rules': [{'ApplyServerSideEncryptionByDefault': {'SSEAlgorithm': 'aws:kms', 'KMSMasterKeyID': 'arn:key'},
                         'BucketKeyEnabled': False, 'BlockedEncryptionTypes': {'EncryptionType': ['SSE-C']}}]}
    client.get_bucket_encryption.return_value = {'ServerSideEncryptionConfiguration': config}
    monkeypatch.setattr(engine, '_build_client', lambda _: client)
    state = request(engine, 'getBucketAdminState', profile, bucketName='bucket')
    request(engine, 'putBucketEncryption', profile, bucketName='bucket', encryptionJson=state['encryptionJson'])
    assert client.put_bucket_encryption.call_args.kwargs['ServerSideEncryptionConfiguration'] == config


@pytest.mark.parametrize('azure', [False, True])
def test_absent_encryption_keeps_all_requests_plain(engine, profile, monkeypatch, tmp_path, azure):
    profile, fixture = connect(engine, profile, monkeypatch, azure)
    file = tmp_path / 'upload'
    file.write_bytes(b'payload')
    request(engine, 'startUpload', profile, bucketName='bucket', filePaths=[str(file)])
    request(engine, 'startDownload', profile, bucketName='bucket', keys=['key'], destinationPath=str(tmp_path))
    request(engine, 'getObjectDetails', profile, bucketName='bucket', key='key')
    request(engine, 'createFolder', profile, bucketName='bucket', key='folder')
    request(engine, 'runPutTestData', profile, config={'bucketName': 'bucket', 'objectCount': 1})
    request(engine, 'copyObject', profile, sourceBucketName='bucket', sourceKey='source',
            destinationBucketName='bucket', destinationKey='dest')
    assert all(not only_encryption(c[2]) for c in fixture.calls)
    client = object()
    assert engine._encrypted_client(client, engine._parse_profile(profile), {}) is client


@pytest.mark.parametrize('azure,mode', [(False, mode) for mode in MODES[:-1]] + [(True, mode) for mode in AZURE_MODES[:-1]])
def test_non_customer_modes_are_ignored_for_reads(engine, profile, monkeypatch, tmp_path, azure, mode):
    profile, fixture = connect(engine, profile, monkeypatch, azure)
    request(engine, 'getObjectDetails', profile, bucketName='bucket', key='key', encryption=mode)
    request(engine, 'startDownload', profile, bucketName='bucket', keys=['key'], destinationPath=str(tmp_path), encryption=mode)
    assert all(not only_encryption(c[2]) for c in fixture.calls)


@pytest.mark.parametrize('azure,field,value', [
    (True, 'encryption', {'mode': 'sse-c', 'customerKey': KEY}),
    (True, 'encryption', {'mode': 'azure-scope'}),
    (True, 'encryption', {'mode': 'azure-scope', 'encryptionScope': 2}),
    (True, 'encryption', {'mode': 'azure-cpk', 'customerKey': 'invalid'}),
    (False, 'sourceEncryption', {'mode': 'sse-s3'}),
    (False, 'sourceEncryption', {'mode': 'azure-cpk', 'customerKey': KEY}),
    (True, 'sourceEncryption', {'mode': 'azure-scope', 'encryptionScope': 'scope'}),
    (True, 'sourceEncryption', {'mode': 'sse-c', 'customerKey': KEY})])
def test_copy_validates_both_provider_options_before_requests(engine, profile, monkeypatch, azure, field, value):
    profile, fixture = connect(engine, profile, monkeypatch, azure)
    with pytest.raises(engine.SidecarError) as raised:
        request(engine, 'copyObject', profile, sourceBucketName='bucket', sourceKey='source',
                destinationBucketName='bucket', destinationKey='dest', **{field: value})
    assert raised.value.code == 'invalid_config'
    assert not fixture.calls


def test_conditional_s3_copy_retains_both_customer_keys(engine, profile, monkeypatch):
    profile = {**profile, 'endpointType': 'awsS3'}
    profile, fixture = connect(engine, profile, monkeypatch)
    base_response = fixture.response
    def response(method, url, headers):
        if method == 'HEAD' and urlparse(url).path.endswith('/dest') and len(fixture.calls) == 1:
            fixture.calls.append((method, url, headers))
            return 404, {}, b''
        return base_response(method, url, headers)
    fixture.response = response
    source, dest = {'mode': 'sse-c', 'customerKey': SOURCE_KEY}, {'mode': 'sse-c', 'customerKey': KEY}
    result = request(engine, 'copyObject', profile, sourceBucketName='bucket', sourceKey='source',
                     destinationBucketName='bucket', destinationKey='dest', conflictPolicy='fail',
                     encryption=dest, sourceEncryption=source)
    assert result['strategy'] == 'server-side-copy'
    part = next(c for c in fixture.calls if 'partNumber=' in c[1])
    assert only_encryption(part[2]) == {**encryption_headers(dest), **encryption_headers(source, source=True)}
    complete = next(c for c in fixture.calls if c[0] == 'POST' and 'uploadId=' in c[1])
    assert complete[2]['if-none-match'] == '*'


def test_object_properties_keeps_existing_encryption_shape(engine, profile, monkeypatch):
    monkeypatch.setattr(engine, '_property_copy_protection', lambda *_: ({}, False))
    profile, fixture = connect(engine, profile, monkeypatch)
    # Preserve the existing S3 SDK-shaped options accepted by this action.
    request(engine, 'storageAction', profile, action='objectProperties', bucketName='bucket', key='key',
            encryption={'ServerSideEncryption': 'aws:kms', 'SSEKMSKeyId': 'existing-key'})
    copy = next(c for c in fixture.calls if 'x-amz-copy-source' in c[2])
    assert only_encryption(copy[2]) == {'x-amz-server-side-encryption': 'aws:kms',
                                      'x-amz-server-side-encryption-aws-kms-key-id': 'existing-key'}


def test_redaction_scope_lifetime_and_body_truncation(engine):
    with engine._customer_key_scope({'encryption': {'customerKey': KEY}}):
        assert KEY not in engine._summarize_http_body('application/json', b'x' * 15990 + KEY.encode())
        assert engine._safe_diagnostics({'outputLines': ['echo ' + KEY]}) == {'outputLines': ['echo [redacted]']}
        with engine._customer_key_scope({'sourceEncryption': {'customerKey': KEY}}):
            assert engine._CUSTOMER_KEYS[KEY] == 2
        assert engine._CUSTOMER_KEYS[KEY] == 1
    assert not engine._CUSTOMER_KEYS


@pytest.mark.parametrize('azure', [False, True])
def test_loopback_encrypted_upload_download_and_copy(engine, profile, monkeypatch, tmp_path, capsys, azure):
    """Real sockets complement the transport fixtures when localhost is allowed."""
    import threading
    from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
    fixture = StorageFixture(azure)
    class Handler(BaseHTTPRequestHandler):
        protocol_version = 'HTTP/1.1'
        def log_message(self, *_): pass
        def handle_storage(self):
            self.rfile.read(int(self.headers.get('Content-Length') or 0))
            headers = {k.lower(): v for k, v in self.headers.items()}
            status, response_headers, data = fixture.response(self.command, self.path, headers)
            self.send_response(status)
            for key, value in response_headers.items(): self.send_header(key, value)
            self.end_headers()
            if self.command != 'HEAD': self.wfile.write(data)
        do_GET = do_HEAD = do_PUT = do_POST = do_DELETE = handle_storage
    with ThreadingHTTPServer(('127.0.0.1', 0), Handler) as server:
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        try:
            profile = {**profile, 'endpointUrl': f'http://127.0.0.1:{server.server_port}',
                       'endpointType': 'azureBlob' if azure else 's3Compatible'}
            mode = {'mode': 'azure-cpk' if azure else 'sse-c', 'customerKey': KEY}
            monkeypatch.setattr(engine, '_AZURE_PUT_BLOB_LIMIT', 1)
            monkeypatch.setattr(engine, '_azure_block_size', lambda _: 4)
            file = tmp_path / 'upload'
            file.write_bytes(b'payload')
            request(engine, 'startUpload', profile, bucketName='bucket', filePaths=[str(file)],
                    encryption=mode, multipartThresholdMiB=0)
            request(engine, 'startDownload', profile, bucketName='bucket', keys=['key'], destinationPath=str(tmp_path),
                    encryption=mode, multipartThresholdMiB=0)
            request(engine, 'getObjectDetails', profile, bucketName='bucket', key='key', encryption=mode)
            request(engine, 'copyObject', profile, sourceBucketName='bucket', sourceKey='source',
                    destinationBucketName='bucket', destinationKey='dest', encryption=mode, sourceEncryption=mode)
        finally:
            server.shutdown()
            thread.join(timeout=5)
    for verb, url, headers in fixture.calls:
        query = parse_qs(urlparse(url).query, keep_blank_values=True)
        if 'tagging' in query or query.get('comp') == ['tags']: continue
        expected = encryption_headers(mode)
        if 'x-amz-copy-source' in headers: expected = {**expected, **encryption_headers(mode, source=True)}
        assert only_encryption(headers) == expected
    captured = capsys.readouterr()
    assert KEY not in captured.out + captured.err
