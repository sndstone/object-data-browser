"""Native GCS contract regressions against a disposable loopback JSON API."""
import base64
import hashlib
import importlib.util
import json
import socket
import sys
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from types import SimpleNamespace
from urllib.parse import parse_qs, parse_qsl, quote, unquote, urlencode, urlparse

import pytest
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import padding, rsa


KEY = 'folder/a b/%#?+雪.txt'


@pytest.fixture
def pyengine():
    path = Path(__file__).parents[2] / 'engines/python/src/main.py'
    spec = importlib.util.spec_from_file_location('gcs_test_engine', path)
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    yield module
    if module._GCS_MODULE:
        for client in module._GCS_MODULE._CLIENTS.values():
            client.pool.clear()
    sys.modules.pop(spec.name, None)


@pytest.fixture(scope='module')
def signing_key():
    return rsa.generate_private_key(public_exponent=65537, key_size=2048)


def service_profile(signing_key, base):
    pem = signing_key.private_bytes(serialization.Encoding.PEM, serialization.PrivateFormat.PKCS8,
                                    serialization.NoEncryption()).decode()
    return {'endpointType': 'googleCloudStorage', 'endpointUrl': base,
        'region': 'EU', 'accessKey': 'ignored-mismatched-email', 'secretKey': json.dumps({
            'client_email': 'fixture@example.invalid', 'private_key': pem,
            'project_id': 'fixture-project', 'token_uri': base + '/token'}),
        'maxAttempts': 3, 'maxConcurrentRequests': 2, 'readTimeoutSeconds': 2}


@pytest.fixture
def gcs_config(signing_key):
    return SimpleNamespace(profile=service_profile(signing_key, 'https://fixture.invalid'), requests=[])


@pytest.fixture
def gcs(signing_key):
    class State:
        requests = []
        token_count = 0
        reject_once = False
        rejected = False
        force_401 = False
        error_status = None
        error_reason = 'fixtureError'
        paging = False
        repeated = False
        bucket_cycle = False
        bucket_page = False
        versioning = False
        uploaded = {}
        session = None
        session_data = b''
        session_key = ''
        session_size = 0
        fail_chunk = False
        chunk_failed = False
        permanent_chunk_failure = False
        lose_final_response = False
        cancelled = False
        rewrite_calls = 0
        move_conflict = False
        range_mode = 'valid'
        range_failed = False
        objects = {KEY: b'fixture bytes', 'empty': b'', 'range.bin': b'x' * (2 * 1024**2 + 31)}
        generations = {KEY: '101', 'empty': '301', 'range.bin': '201'}
        errors = []
    state = State()
    state.requests = []
    state.uploaded = {}
    state.objects = dict(state.objects)
    state.generations = dict(state.generations)
    state.errors = []

    class Handler(BaseHTTPRequestHandler):
        protocol_version = 'HTTP/1.1'
        def log_message(self, *_):
            pass
        def send(self, status=200, value=None, headers=None, raw=None):
            data = raw if raw is not None else json.dumps(value).encode() if value is not None else b''
            self.send_response(status)
            self.send_header('Content-Length', str(len(data)))
            self.send_header('Content-Type', 'application/json')
            for name, value in (headers or {}).items():
                self.send_header(name, value)
            self.end_headers()
            try:
                self.wfile.write(data)
            except (BrokenPipeError, ConnectionResetError):
                # The engine hangs up as soon as it rejects a bad response.
                self.close_connection = True
        def metadata(self, key, generation=None):
            return {'name': key, 'size': str(len(state.objects.get(key, b'fixture bytes'))),
                    'generation': generation or state.generations.get(key, '101'),
                    'etag': 'fixture-etag', 'storageClass': 'STANDARD',
                    'contentType': 'text/plain', 'metadata': {'custom': 'value'},
                    'updated': '2026-11-15T12:00:00Z'}
        def bucket(self):
            return {'name': 'fixture', 'location': 'EU', 'versioning': {'enabled': state.versioning},
                    'timeCreated': '2026-11-15T12:00:00Z'}
        def handle_request(self):
            parsed = urlparse(self.path)
            path, query = parsed.path, {k: v[0] for k, v in parse_qs(parsed.query, keep_blank_values=True).items()}
            body = self.rfile.read(int(self.headers.get('Content-Length', '0')))
            state.requests.append((self.command, path, query, dict(self.headers), body))
            if path == '/token':
                assert self.command == 'POST'
                assert self.headers['Content-Type'] == 'application/x-www-form-urlencoded'
                assert not self.headers.get('Authorization')
                form = parse_qs(body.decode())
                assert form['grant_type'] == ['urn:ietf:params:oauth:grant-type:jwt-bearer']
                assertion = form['assertion'][0]
                first, second, signature = assertion.split('.')
                def decode(value):
                    return base64.urlsafe_b64decode(value + '=' * (-len(value) % 4))
                assert json.loads(decode(first)) == {'alg': 'RS256', 'typ': 'JWT'}
                claims = json.loads(decode(second))
                assert claims['iss'] == 'fixture@example.invalid'
                assert claims['aud'] == state.base + '/token'
                assert claims['scope'] == 'https://www.googleapis.com/auth/devstorage.read_write'
                assert 0 < claims['exp'] - claims['iat'] <= 3600
                signing_key.public_key().verify(decode(signature), (first + '.' + second).encode(),
                                                padding.PKCS1v15(), hashes.SHA256())
                state.token_count += 1
                return self.send(value={'access_token': f'KNOWN_TOKEN_{state.token_count}', 'expires_in': 3600, 'token_type': 'Bearer'})
            assert self.headers['Authorization'].startswith('Bearer KNOWN_TOKEN_')
            if state.force_401 or (state.reject_once and not state.rejected):
                state.rejected = True
                return self.send(401, {'error': {'errors': [{'reason': 'authError'}]}})
            if state.error_status:
                return self.send(state.error_status, {'error': {'message': 'DO NOT ECHO ' + state.error_reason,
                    'errors': [{'reason': state.error_reason}]}})
            if path.startswith('/session/'):
                assert self.path == urlparse(state.session).path + '?' + urlparse(state.session).query
                if self.command == 'DELETE':
                    state.cancelled = True
                    return self.send(499)
                assert self.command == 'PUT'
                content_range = self.headers['Content-Range']
                if content_range.startswith('bytes */'):
                    assert not body
                    if len(state.session_data) == state.session_size:
                        return self.send(value=self.metadata(state.session_key))
                    return self.send(308, headers={'Range': 'bytes=0-' + str(len(state.session_data) - 1)} if state.session_data else {})
                first, total = content_range[6:].split('/')
                start, end = map(int, first.split('-'))
                assert int(total) == state.session_size
                assert len(body) == end - start + 1
                assert start == len(state.session_data)
                assert end == state.session_size - 1 or len(body) % (256 * 1024) == 0
                if state.permanent_chunk_failure:
                    return self.send(403, {'error': {'errors': [{'reason': 'forbidden'}]}})
                if state.fail_chunk and not state.chunk_failed:
                    state.chunk_failed = True
                    state.session_data += body[:256 * 1024]
                    # Accept part of a chunk, then drop the connection before
                    # returning a response. The next request must probe status.
                    self.close_connection = True
                    self.connection.shutdown(socket.SHUT_RDWR)
                    self.connection.close()
                    return
                state.session_data += body
                if len(state.session_data) < state.session_size:
                    return self.send(308, headers={'Range': f'bytes=0-{len(state.session_data) - 1}'})
                state.uploaded[state.session_key] = state.session_data
                if state.lose_final_response:
                    state.lose_final_response = False
                    self.close_connection = True
                    self.connection.shutdown(socket.SHUT_RDWR)
                    self.connection.close()
                    return
                return self.send(value=self.metadata(state.session_key))
            if path == '/storage/v1/b':
                assert query['project'] == 'fixture-project'
                if self.command == 'POST':
                    value = json.loads(body)
                    assert value['name'] == 'fixture'
                    assert value.get('location', 'EU') == 'EU'
                    return self.send(value=self.bucket())
                assert self.command == 'GET' and query['maxResults'] == '1000'
                if state.bucket_page:
                    token = query.get('pageToken')
                    if not token:
                        return self.send(value={'nextPageToken': 'empty-buckets'})
                    if state.bucket_cycle:
                        return self.send(value={'nextPageToken': 'empty-buckets' if token == 'other' else 'other'})
                    assert token == 'empty-buckets'
                return self.send(value={'items': [self.bucket()]})
            if path == '/storage/v1/b/fixture':
                if self.command == 'PATCH':
                    state.versioning = json.loads(body)['versioning']['enabled']
                return self.send(204 if self.command == 'DELETE' else 200,
                                 None if self.command == 'DELETE' else self.bucket())
            if path.startswith('/upload/storage/v1/b/fixture/o'):
                assert path == '/upload/storage/v1/b/fixture/o'
                assert self.command == 'POST'
                if query['uploadType'] == 'media':
                    state.uploaded[query['name']] = body
                    return self.send(value=self.metadata(query['name']))
                assert query['uploadType'] == 'resumable'
                assert json.loads(body) == {}
                assert self.headers['X-Upload-Content-Type'] == 'application/octet-stream'
                state.session_size = int(self.headers['X-Upload-Content-Length'])
                state.session_key = query['name']
                state.session = state.base + '/session/KNOWN_SESSION?upload_id=SECRET_SESSION'
                return self.send(headers={'Location': state.session})
            if path == '/storage/v1/b/fixture/o':
                assert self.command == 'GET'
                assert query['maxResults'] == '1000'
                if state.paging:
                    if not query.get('pageToken'):
                        return self.send(value={'nextPageToken': 'after-empty'})
                    assert query['pageToken'] == 'after-empty'
                    if state.repeated:
                        return self.send(value={'nextPageToken': 'after-empty'})
                if query.get('versions') == 'true':
                    assert query['prefix'] == KEY
                    return self.send(value={'items': [self.metadata(KEY, '101'),
                        {**self.metadata(KEY, '99'), 'timeDeleted': '2026-11-14T12:00:00Z'}]})
                return self.send(value={'items': [self.metadata(KEY)], 'prefixes': ['folder/'] if query.get('delimiter') == '/' else []})
            if '/rewriteTo/' in path:
                assert path == '/storage/v1/b/fixture/o/' + quote(KEY, safe='') + '/rewriteTo/b/dest/o/' + quote('copy/' + KEY, safe='')
                assert self.command == 'POST' and json.loads(body) == {}
                assert query['sourceGeneration'] == query['ifSourceGenerationMatch'] == '101'
                state.rewrite_calls += 1
                if query.get('rewriteToken'):
                    assert query['rewriteToken'] == 'rewrite-next'
                    return self.send(value={'done': True, 'resource': self.metadata('copy/' + KEY)})
                return self.send(value={'done': False, 'rewriteToken': 'rewrite-next'})
            prefix = '/storage/v1/b/fixture/o/'
            assert path.startswith(prefix), path
            key = unquote(path[len(prefix):])
            assert path == prefix + quote(key, safe=''), 'object names must be one encoded path segment'
            if key == 'missing':
                return self.send(404, {'error': {'errors': [{'reason': 'notFound'}]}})
            if self.command == 'DELETE':
                if query.get('ifGenerationMatch'):
                    assert query == {'ifGenerationMatch': '101'}
                    if state.move_conflict:
                        return self.send(412, {'error': {'errors': [{'reason': 'conditionNotMet'}]}})
                return self.send(204)
            assert self.command == 'GET'
            if query.get('alt') != 'media':
                return self.send(value=self.metadata(key, query.get('generation')))
            assert query['generation'] == state.generations[key]
            data = state.objects[key]
            total = len(data)
            if not data:
                assert not self.headers.get('Range')
                return self.send(raw=b'')
            start, end = map(int, self.headers['Range'][6:].split('-'))
            data = data[start:end + 1]
            headers = {'Content-Range': f'bytes {start}-{end}/{total}'}
            if state.range_mode == 'retry' and not state.range_failed:
                state.range_failed = True
                self.send_response(206)
                self.send_header('Content-Length', str(len(data)))
                self.send_header('Content-Range', headers['Content-Range'])
                self.end_headers()
                self.wfile.write(data[:2])
                self.wfile.flush()
                self.close_connection = True
                self.connection.shutdown(socket.SHUT_RDWR)
                self.connection.close()
                return
            if state.range_mode == 'wrong-range':
                headers['Content-Range'] = f'bytes {start + 1}-{end}/{total}'
            if state.range_mode == 'short':
                data = data[:-1]
            if state.range_mode == 'oversized':
                data += b'!'
            if state.range_mode == 'ignored':
                return self.send(raw=state.objects[key])
            return self.send(206, headers=headers, raw=data)
        def dispatch(self):
            try:
                self.handle_request()
            except Exception as error:
                state.errors.append(error)
                self.close_connection = True
                raise
        do_GET = do_POST = do_PUT = do_PATCH = do_DELETE = dispatch

    server = ThreadingHTTPServer(('127.0.0.1', 0), Handler)
    state.base = f'http://127.0.0.1:{server.server_port}'
    state.profile = service_profile(signing_key, state.base)
    state.pem = json.loads(state.profile['secretKey'])['private_key']
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    try:
        yield state
    finally:
        server.shutdown()
        server.server_close()
        thread.join()
        assert not state.errors


def call(engine, state, method, **params):
    return engine.handle_request({'method': method, 'params': {'profile': state.profile, **params}})


def requests(state, method, fragment):
    return [r for r in state.requests if r[0] == method and fragment in r[1]]


def test_gcs_bucket_methods_token_cache_and_empty_pages(pyengine, gcs):
    gcs.bucket_page = True
    assert call(pyengine, gcs, 'testProfile')['ok'] is True
    assert call(pyengine, gcs, 'listBuckets')['items'][0]['name'] == 'fixture'
    assert gcs.token_count == 1
    assert call(pyengine, gcs, 'createBucket', bucketName='fixture')['region'] == 'EU'
    assert call(pyengine, gcs, 'setBucketVersioning', bucketName='fixture', enabled=True)['versioningEnabled'] is True
    admin = call(pyengine, gcs, 'getBucketAdminState', bucketName='fixture')
    assert admin['versioningStatus'] == 'Enabled'
    assert admin['sections']['GetBucketLifecycleConfiguration']['state'] == 'unsupported'
    assert call(pyengine, gcs, 'deleteBucket', bucketName='fixture')['deleted']
    listed = requests(gcs, 'GET', '/storage/v1/b')
    assert any(r[2].get('pageToken') == 'empty-buckets' for r in listed)


def test_gcs_known_bucket_avoids_project_listing(pyengine, gcs):
    gcs.profile['knownBucket'] = 'fixture'
    assert call(pyengine, gcs, 'testProfile')['bucketCount'] == 1
    assert len(call(pyengine, gcs, 'listBuckets')['items']) == 1
    assert not [r for r in gcs.requests if r[1] == '/storage/v1/b']


def test_gcs_auth_refreshes_once_on_401_and_before_expiry(pyengine, gcs):
    gcs.reject_once = True
    assert call(pyengine, gcs, 'listBuckets')['items']
    assert gcs.token_count == 2
    client = next(iter(pyengine._gcs_module()._CLIENTS.values()))
    client.expires = pyengine.time.time() + 59
    call(pyengine, gcs, 'listBuckets')
    assert gcs.token_count == 3
    gcs.force_401 = True
    with pytest.raises(pyengine.SidecarError) as error:
        call(pyengine, gcs, 'listBuckets')
    assert error.value.code == 'auth_failed'
    assert error.value.details == {'provider': 'gcs', 'httpStatus': 401, 'reason': 'authError'}
    assert gcs.token_count == 4


def test_gcs_objects_versions_details_and_encoded_names(pyengine, gcs):
    gcs.paging = True
    empty = call(pyengine, gcs, 'listObjects', bucketName='fixture', prefix='')
    assert not empty['items'] and empty['nextCursor'] == {'value': 'after-empty', 'hasMore': True}
    page = call(pyengine, gcs, 'listObjects', bucketName='fixture', cursor=empty['nextCursor'])
    assert page['items'][0]['isFolder'] is True
    assert page['items'][1]['key'] == KEY
    versions = call(pyengine, gcs, 'listObjectVersions', bucketName='fixture', key=KEY)
    assert not versions['items'] and versions['cursor']['hasMore']
    versions = call(pyengine, gcs, 'listObjectVersions', bucketName='fixture', key=KEY, cursor=versions['cursor'])
    assert [(v['versionId'], v['latest'], v['deleteMarker']) for v in versions['items']] == [('101', True, False), ('99', False, False)]
    details = call(pyengine, gcs, 'getObjectDetails', bucketName='fixture', key=KEY, versionId='99')
    assert details['versionId'] == '99' and details['metadata'] == {'custom': 'value'}
    assert requests(gcs, 'GET', quote(KEY, safe=''))[-1][2] == {'generation': '99'}
    call(pyengine, gcs, 'listObjects', bucketName='fixture', flat=True, prefix='folder/', cursor={'value': 'after-empty'})
    assert 'delimiter' not in requests(gcs, 'GET', '/o')[-1][2]


@pytest.mark.parametrize('method', ['listObjects', 'listObjectVersions'])
def test_gcs_rejects_repeated_listing_cursor(pyengine, gcs, method):
    gcs.paging = gcs.repeated = True
    with pytest.raises(pyengine.SidecarError) as error:
        call(pyengine, gcs, method, bucketName='fixture', key=KEY, cursor={'value': 'after-empty'})
    assert error.value.code == 'invalid_response'


def test_gcs_bucket_cursor_cycle_rejected(pyengine, gcs):
    gcs.bucket_page = gcs.bucket_cycle = True
    with pytest.raises(pyengine.SidecarError) as error:
        call(pyengine, gcs, 'listBuckets')
    assert error.value.code == 'invalid_response'


def test_gcs_delete_folder_and_versions(pyengine, gcs):
    assert call(pyengine, gcs, 'createFolder', bucketName='fixture', key=KEY)['key'] == KEY + '/'
    assert gcs.uploaded[KEY + '/'] == b''
    assert call(pyengine, gcs, 'deleteObjects', bucketName='fixture', keys=[KEY, 'missing'])['successCount'] == 2
    assert call(pyengine, gcs, 'deleteObjectVersions', bucketName='fixture', versions=[{'key': KEY, 'versionId': '99'}])['successCount'] == 1
    assert requests(gcs, 'DELETE', quote(KEY, safe=''))[-1][2] == {'generation': '99'}
    gcs.error_status = 403
    result = call(pyengine, gcs, 'deleteObjectVersions', bucketName='fixture', versions=[{'key': KEY, 'versionId': '99'}])
    assert result['failureCount'] == 1 and result['failures'][0]['code'] == 'auth_failed'
    assert result['failures'][0]['versionId'] == '99'


def copy_params():
    return {'sourceBucketName': 'fixture', 'sourceKey': KEY,
            'destinationBucketName': 'dest', 'destinationKey': 'copy/' + KEY}


def test_gcs_rewrite_copy_and_conditional_move(pyengine, gcs):
    result = call(pyengine, gcs, 'copyObject', **copy_params())
    assert result['copied'] and gcs.rewrite_calls == 2
    assert not requests(gcs, 'DELETE', '/o/')
    assert call(pyengine, gcs, 'moveObject', **copy_params())['copied']
    deletion = requests(gcs, 'DELETE', '/o/')[-1]
    assert deletion[2] == {'ifGenerationMatch': '101'}
    gcs.move_conflict = True
    with pytest.raises(pyengine.SidecarError) as error:
        call(pyengine, gcs, 'moveObject', **copy_params())
    assert error.value.code == 'object_conflict'
    assert error.value.details['sourceRetained'] and error.value.details['copied']
    assert 'source retained' in error.value.message


def test_gcs_v4_url_signature_and_expiry(pyengine, gcs_config, signing_key):
    gcs = gcs_config
    result = call(pyengine, gcs, 'generatePresignedUrl', bucketName='fixture', key=KEY, expirationSeconds=999999, versionId='99')
    parsed = urlparse(result['url'])
    query = dict(parse_qsl(parsed.query))
    assert query['X-Goog-Expires'] == '604800' and query['generation'] == '99'
    assert parsed.path == '/fixture/' + quote(KEY, safe='/')
    signature = bytes.fromhex(query.pop('X-Goog-Signature'))
    scope = query['X-Goog-Credential'].split('/', 1)[1]
    assert scope.endswith('/auto/storage/goog4_request')
    canonical = '\n'.join(['GET', parsed.path, urlencode(sorted(query.items()), quote_via=quote, safe='~'),
        'host:' + parsed.netloc + '\n', 'host', 'UNSIGNED-PAYLOAD'])
    to_sign = '\n'.join(['GOOG4-RSA-SHA256', query['X-Goog-Date'], scope, hashlib.sha256(canonical.encode()).hexdigest()])
    signing_key.public_key().verify(signature, to_sign.encode(), padding.PKCS1v15(), hashes.SHA256())
    assert not gcs.requests, 'Signing must not require an OAuth/network call'


def test_gcs_simple_upload_streams_and_resumable_recovers_partial_chunk(pyengine, gcs, tmp_path, monkeypatch):
    small = tmp_path / 'small.bin'
    small.write_bytes(b'small data')
    original = pyengine._FilePart.read
    reads = []
    def read(part, size=-1):
        reads.append(size)
        assert 0 <= size <= 64 * 1024
        return original(part, size)
    monkeypatch.setattr(pyengine._FilePart, 'read', read)
    params = {'bucketName': 'fixture', 'multipartThresholdMiB': 1, 'multipartChunkMiB': 1,
              'objectKeyByPath': {str(small): KEY}}
    result = call(pyengine, gcs, 'startUpload', filePaths=[str(small)], **params)
    assert result['status'] == 'completed' and gcs.uploaded[KEY] == b'small data'
    assert reads
    large = tmp_path / 'large.bin'
    content = bytes(range(256)) * (1024 * 9)
    large.write_bytes(content)
    gcs.fail_chunk = True
    result = call(pyengine, gcs, 'startUpload', bucketName='fixture', filePaths=[str(large)],
                  multipartThresholdMiB=1, multipartChunkMiB=1)
    assert result['status'] == 'completed' and result['bytesTransferred'] == len(content)
    assert gcs.uploaded['large.bin'] == content and not gcs.cancelled
    puts = requests(gcs, 'PUT', '/session/')
    assert puts[1][3]['Content-Range'] == f'bytes */{len(content)}'
    assert puts[2][3]['Content-Range'].startswith('bytes 262144-')
    assert result['partsCompleted'] == result['partsTotal'] == 3


def test_gcs_resumable_lost_final_response_is_probed(pyengine, gcs, tmp_path):
    path = tmp_path / 'source'
    path.write_bytes(b'x' * 1024**2)
    gcs.lose_final_response = True
    result = call(pyengine, gcs, 'startUpload', bucketName='fixture', filePaths=[str(path)], multipartThresholdMiB=1)
    assert result['status'] == 'completed'
    assert requests(gcs, 'PUT', '/session/')[-1][3]['Content-Range'] == f'bytes */{1024**2}'
    assert not gcs.cancelled


def test_gcs_failed_resumable_upload_cancels_session_and_redacts_output(pyengine, gcs, tmp_path, capsys):
    path = tmp_path / 'source'
    path.write_bytes(b'x' * 1024**2)
    gcs.profile['diagnostics'] = {'enableApiLogging': True, 'enableDebugLogging': True}
    gcs.permanent_chunk_failure = True
    request = {'requestId': 'failure', 'method': 'startUpload', 'params': {
        'profile': gcs.profile, 'bucketName': 'fixture', 'filePaths': [str(path)], 'multipartThresholdMiB': 1}}
    pyengine._process_line(json.dumps(request))
    assert gcs.cancelled
    captured = capsys.readouterr()
    assert 'auth_failed' in captured.out and 'GCS SEND' in captured.err
    for secret in [gcs.pem.splitlines()[1], 'KNOWN_TOKEN_1', gcs.session, 'SECRET_SESSION']:
        assert secret not in captured.out + captured.err
    assert pyengine._sanitize_headers({'Location': gcs.session}) == {'Location': '[redacted]'}
    assert pyengine._summarize_http_body('application/json', json.dumps({'private_key': gcs.pem, 'access_token': 'KNOWN_TOKEN_1'}).encode()) == '{"private_key": "[redacted]", "access_token": "[redacted]"}'


@pytest.mark.parametrize('cancel', [False, True])
def test_gcs_source_mutation_and_cancellation_cancel_session(pyengine, gcs, tmp_path, monkeypatch, cancel):
    path = tmp_path / 'source'
    path.write_bytes(b'x' * 2 * 1024**2)
    original = pyengine._transfer_checkpoint
    def checkpoint(control, **kwargs):
        original(control, **kwargs)
        if kwargs['bytes_transferred']:
            if cancel:
                control.status = 'cancelled'
            else:
                with path.open('ab') as handle:
                    handle.write(b'changed')
    monkeypatch.setattr(pyengine, '_transfer_checkpoint', checkpoint)
    if cancel:
        assert call(pyengine, gcs, 'startUpload', bucketName='fixture', filePaths=[str(path)], multipartThresholdMiB=1, multipartChunkMiB=1)['status'] == 'cancelled'
    else:
        with pytest.raises(pyengine.SidecarError) as error:
            call(pyengine, gcs, 'startUpload', bucketName='fixture', filePaths=[str(path)], multipartThresholdMiB=1, multipartChunkMiB=1)
        assert error.value.code == 'object_conflict'
    assert gcs.cancelled


def test_gcs_download_ranges_retry_pin_generation_and_publish_atomically(pyengine, gcs, tmp_path):
    (tmp_path / 'range.bin').write_bytes(b'LOCAL')
    gcs.range_mode = 'retry'
    result = call(pyengine, gcs, 'startDownload', bucketName='fixture', keys=['range.bin', 'empty', KEY],
        destinationPath=str(tmp_path), multipartThresholdMiB=1, multipartChunkMiB=1)
    assert result['status'] == 'completed' and gcs.range_failed
    assert (tmp_path / 'range.bin').read_bytes() == b'LOCAL'
    assert (tmp_path / 'range (1).bin').read_bytes() == gcs.objects['range.bin']
    assert (tmp_path / 'empty').read_bytes() == b''
    assert not list(tmp_path.glob('.odb-*'))
    media = [r for r in gcs.requests if r[2].get('alt') == 'media']
    assert all(r[2].get('generation') for r in media)
    # Ranges run in parallel, so the fixture cuts off whichever arrives first.
    ranges = [r[3].get('Range') for r in media if r[1].endswith('/range.bin')]
    assert 'bytes=0-1048575' in ranges
    assert any(ranges.count(value) >= 2 for value in set(ranges))
    call(pyengine, gcs, 'startDownload', bucketName='fixture', keys=['range.bin'],
         destinationPath=str(tmp_path), conflictPolicy='replace')
    assert (tmp_path / 'range.bin').read_bytes() == gcs.objects['range.bin']


@pytest.mark.parametrize('mode', ['ignored', 'wrong-range', 'short', 'oversized'])
def test_gcs_bad_download_keeps_existing_file(pyengine, gcs, tmp_path, mode):
    target = tmp_path / 'range.bin'
    target.write_bytes(b'LOCAL')
    gcs.range_mode = mode
    with pytest.raises(pyengine.SidecarError) as error:
        call(pyengine, gcs, 'startDownload', bucketName='fixture', keys=['range.bin'],
             destinationPath=str(tmp_path), conflictPolicy='replace', multipartThresholdMiB=1, multipartChunkMiB=1)
    assert error.value.code == 'object_conflict'
    assert target.read_bytes() == b'LOCAL' and list(tmp_path.iterdir()) == [target]


@pytest.mark.parametrize('status,code', [(401, 'auth_failed'), (403, 'auth_failed'), (404, 'unknown'),
                                       (409, 'object_conflict'), (412, 'object_conflict'), (429, 'throttled'), (504, 'timeout')])
def test_gcs_error_mapping(pyengine, gcs, status, code):
    gcs.error_status = status
    with pytest.raises(pyengine.SidecarError) as error:
        call(pyengine, gcs, 'getObjectDetails', bucketName='fixture', key=KEY)
    assert error.value.code == code
    assert error.value.details == {'provider': 'gcs', 'httpStatus': status, 'reason': 'fixtureError'}


@pytest.mark.parametrize('secret', ['not json PRIVATE_FRAGMENT', '{}', '[]', '{"private_key":"PRIVATE_FRAGMENT"}'])
def test_gcs_malformed_key_is_safe_invalid_config(pyengine, secret):
    with pytest.raises(pyengine.SidecarError) as error:
        pyengine.handle_request({'method': 'listBuckets', 'params': {'profile': {
            'endpointType': 'googleCloudStorage', 'secretKey': secret}}})
    assert error.value.code == 'invalid_config'
    assert 'PRIVATE_FRAGMENT' not in str(error.value)


def test_gcs_default_endpoint_email_and_location(pyengine, gcs_config):
    gcs = gcs_config
    profile = pyengine._parse_profile({**gcs.profile, 'endpointUrl': '', 'accessKey': '', 'region': ''})
    client = pyengine._gcs_module().Client(profile, SimpleNamespace(**vars(pyengine)))
    try:
        assert client.base == 'https://storage.googleapis.com'
        assert client.email == 'fixture@example.invalid' and profile.region == ''
    finally:
        client.pool.clear()


def test_gcs_capabilities_and_unsupported_methods(pyengine, gcs_config):
    gcs = gcs_config
    capabilities = {item['key']: item for item in call(pyengine, gcs, 'getCapabilities')['items']}
    for key in ['bucket.lifecycle', 'bucket.policy', 'bucket.cors', 'bucket.encryption', 'bucket.tagging',
                'object.encryption.sse-c', 'object.encryption.azure-cpk', 'storage.admin', 'tools.bulk-delete', 'benchmark', 'object.resumable']:
        assert capabilities[key]['state'] == 'unsupported' and capabilities[key]['reason']
    assert capabilities['bucket.versioning']['state'] == 'supported'
    assert capabilities['object.clientEncryption']['state'] == 'supported'
    methods = ['putBucketLifecycle', 'deleteBucketLifecycle', 'putBucketPolicy', 'deleteBucketPolicy',
        'putBucketCors', 'deleteBucketCors', 'putBucketEncryption', 'deleteBucketEncryption',
        'putBucketTagging', 'deleteBucketTagging', 'runPutTestData', 'runDeleteAll', 'startBenchmark',
        'getBenchmarkStatus', 'pauseBenchmark', 'resumeBenchmark', 'stopBenchmark', 'exportBenchmarkResults', 'storageAction']
    for method in methods:
        with pytest.raises(pyengine.SidecarError) as error:
            call(pyengine, gcs, method)
        assert error.value.code == 'unsupported_feature'
    for method in ['startUpload', 'startDownload', 'getObjectDetails', 'copyObject', 'generatePresignedUrl']:
        with pytest.raises(pyengine.SidecarError) as error:
            call(pyengine, gcs, method, encryption={})
        assert error.value.code == 'invalid_config'
    assert not gcs.requests


def test_unknown_provider_never_dispatches_to_s3(pyengine, monkeypatch):
    monkeypatch.setattr(pyengine, '_build_client', lambda _: pytest.fail('must not build S3 client'))
    profile = {'endpointType': 'unknown-provider', 'accessKey': 'a', 'secretKey': 's', 'endpointUrl': 'https://fixture.invalid'}
    with pytest.raises(pyengine.SidecarError) as error:
        pyengine._parse_profile(profile)
    assert error.value.code == 'invalid_config'
    with pytest.raises(pyengine.SidecarError) as error:
        pyengine.handle_request({'method': 'listBuckets', 'params': {'profile': profile}})
    assert error.value.code == 'invalid_config'


class MemoryResponse:
    def __init__(self, status=200, value=None, headers=None, data=None):
        import io
        self.status = status
        self.headers = headers or {}
        self.body = io.BytesIO(data if data is not None else json.dumps(value).encode() if value is not None else b'')
    def read(self, size=-1):
        return self.body.read(size)
    def close(self):
        self.body.close()
    def release_conn(self):
        pass


@pytest.fixture
def memory_api(pyengine, gcs_config, monkeypatch):
    """Socket-free transport fake also usable inside restricted worker sandboxes."""
    module = pyengine._gcs_module()
    state = SimpleNamespace(profile=gcs_config.profile, requests=[], token_count=0, objects={KEY: b'payload'},
        offset=0, uploaded=b'', fail_chunk=False, failed=False, cancel=False, reject_once=False,
        rejected=False, forced_offset=None, chunk_failure=False, retry_without_progress=False, never_progress=False)
    def send(client, method, url, headers, body, retry=False):
        parsed = urlparse(url)
        query = dict(parse_qsl(parsed.query))
        if hasattr(body, 'read'):
            chunks = []
            while True:
                data = body.read(16384)
                if not data:
                    break
                chunks.append(data)
            body = b''.join(chunks)
        state.requests.append((method, parsed.path, query, dict(headers), body))
        if parsed.path == '/token':
            state.token_count += 1
            return MemoryResponse(value={'access_token': f'KNOWN_TOKEN_{state.token_count}', 'expires_in': 3600})
        if state.reject_once and not state.rejected:
            state.rejected = True
            return MemoryResponse(401, {'error': {'errors': [{'reason': 'authError'}]}})
        if parsed.path == '/storage/v1/b':
            return MemoryResponse(value={'items': [{'name': 'fixture'}]})
        if parsed.path.startswith('/storage/v1/b/fixture/o/'):
            key = unquote(parsed.path.split('/o/', 1)[1])
            data = state.objects[key]
            if query.get('alt') != 'media':
                return MemoryResponse(value={'name': key, 'size': str(len(data)), 'generation': '101'})
            assert query['generation'] == '101'
            if 'Range' not in headers:
                assert not data
                return MemoryResponse(data=b'')
            start, end = map(int, headers['Range'][6:].split('-'))
            return MemoryResponse(206, headers={'Content-Range': f'bytes {start}-{end}/{len(data)}'}, data=data[start:end + 1])
        if parsed.path == '/upload/storage/v1/b/fixture/o':
            state.key = query['name']
            if query['uploadType'] == 'media':
                state.objects[state.key] = body
                return MemoryResponse(value={})
            state.size = int(headers['X-Upload-Content-Length'])
            return MemoryResponse(headers={'Location': 'https://fixture.invalid/session/KNOWN_SESSION?upload_id=SECRET_SESSION'})
        assert parsed.path == '/session/KNOWN_SESSION'
        if method == 'DELETE':
            state.cancel = True
            return MemoryResponse(499)
        content_range = headers['Content-Range']
        if content_range.startswith('bytes */'):
            if state.retry_without_progress:
                state.forced_offset = 0
            return MemoryResponse(308, headers={'Range': f'bytes=0-{state.offset - 1}'} if state.offset else {})
        start, end = map(int, content_range[6:].split('/')[0].split('-'))
        assert start == state.offset and len(body) == end - start + 1
        if state.chunk_failure:
            raise pyengine.SidecarError('timeout', 'Cloud Storage request timed out.')
        if state.fail_chunk and not state.failed:
            state.failed = True
            if not state.retry_without_progress:
                state.uploaded += body[:256 * 1024]
                state.offset += 256 * 1024
            raise pyengine.SidecarError('timeout', 'Cloud Storage request timed out.')
        if state.forced_offset is not None:
            value = state.forced_offset
            state.forced_offset = None
            if state.never_progress:
                state.forced_offset = value
            # An absent Range means no bytes are committed.
            return MemoryResponse(308, headers={'Range': f'bytes=0-{value - 1}'} if value else {})
        state.uploaded += body
        state.offset += len(body)
        if state.offset < state.size:
            return MemoryResponse(308, headers={'Range': f'bytes=0-{state.offset - 1}'})
        state.objects[state.key] = state.uploaded
        return MemoryResponse(value={})
    monkeypatch.setattr(module.Client, '_send', send)
    return state


def test_gcs_socket_free_auth_and_upload_401_rewinds_body(pyengine, memory_api, tmp_path):
    path = tmp_path / 'source'
    path.write_bytes(b'payload')
    memory_api.reject_once = True
    result = call(pyengine, memory_api, 'startUpload', bucketName='fixture', filePaths=[str(path)])
    assert result['status'] == 'completed'
    uploads = requests(memory_api, 'POST', '/upload/')
    assert [r[4] for r in uploads] == [b'payload', b'payload']
    assert memory_api.token_count == 2
    assert uploads[0][3]['Authorization'] != uploads[1][3]['Authorization']
    call(pyengine, memory_api, 'listBuckets')
    assert memory_api.token_count == 2
    client = next(iter(pyengine._gcs_module()._CLIENTS.values()))
    client.expires = pyengine.time.time() + 59
    call(pyengine, memory_api, 'listBuckets')
    assert memory_api.token_count == 3


@pytest.mark.parametrize('zero_committed', [False, True])
def test_gcs_socket_free_resumable_retry_and_progress(pyengine, memory_api, tmp_path, zero_committed):
    source = tmp_path / 'source'
    content = bytes(range(256)) * (1024 * 9)
    source.write_bytes(content)
    memory_api.fail_chunk = True
    memory_api.retry_without_progress = zero_committed
    result = call(pyengine, memory_api, 'startUpload', bucketName='fixture', filePaths=[str(source)],
                  multipartThresholdMiB=1, multipartChunkMiB=1)
    assert result['status'] == 'completed' and result['bytesTransferred'] == len(content)
    assert memory_api.objects['source'] == content and not memory_api.cancel
    assert result['partsCompleted'] == result['partsTotal'] == 3
    assert requests(memory_api, 'PUT', '/session/')[1][3]['Content-Range'] == f'bytes */{len(content)}'


@pytest.mark.parametrize('failure', ['timeout', 'offset', 'no-progress'])
def test_gcs_socket_free_failure_budget_cancels_session(pyengine, memory_api, tmp_path, failure, capsys):
    source = tmp_path / 'source'
    source.write_bytes(b'x' * (2 * 1024**2))
    memory_api.profile['diagnostics'] = {'enableApiLogging': True}
    if failure == 'timeout':
        memory_api.chunk_failure = True
    elif failure == 'offset':
        memory_api.forced_offset = 2 * 1024**2 + 1
    else:
        memory_api.forced_offset = 0
        memory_api.never_progress = True
    with pytest.raises(pyengine.SidecarError):
        call(pyengine, memory_api, 'startUpload', bucketName='fixture', filePaths=[str(source)],
             multipartThresholdMiB=1, multipartChunkMiB=1)
    assert memory_api.cancel
    assert len(requests(memory_api, 'PUT', '/session/')) <= 5
    captured = capsys.readouterr()
    pem = json.loads(memory_api.profile['secretKey'])['private_key']
    for secret in [pem.splitlines()[1], 'KNOWN_TOKEN_1', 'SECRET_SESSION', '/session/KNOWN_SESSION']:
        assert secret not in captured.out + captured.err


def test_gcs_socket_free_client_encryption_roundtrip(pyengine, memory_api, tmp_path):
    content = bytes(range(256)) * 9000
    source = tmp_path / 'plain'
    source.write_bytes(content)
    encoded = lambda value: base64.b64encode(value).decode()
    config = {'format': 'age-v1', 'fileKey': encoded(b'K' * 16), 'payloadNonce': encoded(b'N' * 16), 'header': encoded(b'fixture age header')}
    call(pyengine, memory_api, 'startUpload', bucketName='fixture', filePaths=[str(source)],
         clientEncryption=config, multipartThresholdMiB=1, multipartChunkMiB=1)
    ciphertext = memory_api.objects['plain']
    assert content not in ciphertext and len(ciphertext) > len(content)
    destination = tmp_path / 'download'
    result = call(pyengine, memory_api, 'startDownload', bucketName='fixture', keys=['plain'],
        destinationPath=str(destination), clientEncryption={'format': 'age-v1', 'fileKey': config['fileKey'], 'headerLength': len(b'fixture age header')})
    assert result['status'] == 'completed'
    assert (destination / 'plain').read_bytes() == content


def test_gcs_socket_free_small_download_uses_validated_generation_range(pyengine, memory_api, tmp_path):
    result = call(pyengine, memory_api, 'startDownload', bucketName='fixture', keys=[KEY], destinationPath=str(tmp_path))
    assert result['status'] == 'completed'
    media = [r for r in memory_api.requests if r[2].get('alt') == 'media']
    assert len(media) == 1 and media[0][2]['generation'] == '101'
    assert media[0][3]['Range'] == 'bytes=0-6'
    assert (tmp_path / pyengine._download_name(KEY)).read_bytes() == b'payload'


def test_gcs_signing_jwt_uses_bundled_rsa_primitives(pyengine, gcs_config, signing_key, monkeypatch):
    module = pyengine._gcs_module()
    client = module.Client(pyengine._parse_profile(gcs_config.profile), SimpleNamespace(**vars(pyengine)))
    def send(method, url, headers, body, retry=False):
        assert url == 'https://fixture.invalid/token' and method == 'POST'
        fields = dict(parse_qsl(body.decode()))
        assert fields['grant_type'] == 'urn:ietf:params:oauth:grant-type:jwt-bearer'
        first, second, signature = fields['assertion'].split('.')
        decode = lambda value: base64.urlsafe_b64decode(value + '=' * (-len(value) % 4))
        claims = json.loads(decode(second))
        assert claims['aud'] == url and claims['iss'] == 'fixture@example.invalid'
        assert claims['scope'] == 'https://www.googleapis.com/auth/devstorage.read_write'
        assert claims['exp'] - claims['iat'] == 3600
        signing_key.public_key().verify(decode(signature), (first + '.' + second).encode(), padding.PKCS1v15(), hashes.SHA256())
        return MemoryResponse(value={'access_token': 'KNOWN_TOKEN', 'expires_in': 3600})
    monkeypatch.setattr(client, '_send', send)
    try:
        assert client.access_token() == 'KNOWN_TOKEN'
    finally:
        client.pool.clear()


def test_gcs_secret_url_sanitizers_and_provider_echo_are_safe(pyengine, gcs_config, capsys):
    signed = call(pyengine, gcs_config, 'generatePresignedUrl', bucketName='fixture', key=KEY)['url']
    session = 'https://fixture.invalid/resumable/KNOWN_SESSION?upload_id=SECRET_SESSION'
    profile = pyengine._parse_profile({**gcs_config.profile, 'diagnostics': {'enableApiLogging': True}})
    pyengine._log_http_send(profile, SimpleNamespace(method='GET', url=signed, headers={'Location': session}, body=None))
    assert signed not in capsys.readouterr().err
    assert pyengine._summarize_http_body('text/plain', (session + ' ' + signed).encode()) == '[redacted] [redacted]'
    assert pyengine._safe_diagnostics({'signedUrl': signed, 'resumableSessionUri': session}) == {'signedUrl': '[redacted]', 'resumableSessionUri': '[redacted]'}
    client = next(iter(pyengine._gcs_module()._CLIENTS.values()))
    client.secrets.add('KNOWN_TOKEN')
    error = client.error(403, json.dumps({'error': {'message': gcs_config.profile['secretKey'] + session,
        'errors': [{'reason': 'KNOWN_TOKEN'}]}}).encode())
    assert error.details['reason'] == 'Unknown'
    assert 'KNOWN_TOKEN' not in str(error) and session not in str(error)


def test_gcs_token_cache_isolated_by_profile_id(pyengine, memory_api):
    memory_api.profile['id'] = 'first'
    call(pyengine, memory_api, 'listBuckets')
    memory_api.profile['id'] = 'second'
    call(pyengine, memory_api, 'listBuckets')
    assert memory_api.token_count == 2
    memory_api.profile['id'] = 'first'
    call(pyengine, memory_api, 'listBuckets')
    assert memory_api.token_count == 2


@pytest.mark.parametrize('failure,code', [('timeout', 'timeout'), ('tls', 'tls_error'), ('connection', 'engine_unavailable')])
def test_gcs_socket_free_transport_errors_are_safe(pyengine, gcs_config, monkeypatch, failure, code):
    import urllib3
    module = pyengine._gcs_module()
    client = module.Client(pyengine._parse_profile(gcs_config.profile), SimpleNamespace(**vars(pyengine)))
    error = {'timeout': urllib3.exceptions.ReadTimeoutError(None, '/SECRET_SESSION', 'KNOWN_TOKEN'),
             'tls': urllib3.exceptions.SSLError('KNOWN_TOKEN'),
             'connection': urllib3.exceptions.ProtocolError('KNOWN_TOKEN')}[failure]
    def request(*args, **kwargs):
        assert kwargs['decode_content'] is False
        raise error
    monkeypatch.setattr(client.pool, 'request', request)
    try:
        with pytest.raises(pyengine.SidecarError) as mapped:
            client._send('GET', 'https://fixture.invalid/SECRET_SESSION', {}, None)
        assert mapped.value.code == code
        assert 'KNOWN_TOKEN' not in str(mapped.value) and 'SECRET_SESSION' not in str(mapped.value)
    finally:
        client.pool.clear()


def test_gcs_secret_scopes_cover_concurrent_refresh_and_cleanup(pyengine, gcs_config):
    module = pyengine._gcs_module()
    e = SimpleNamespace(**vars(pyengine))
    client = module.Client(pyengine._parse_profile(gcs_config.profile), e)
    try:
        with module._secret_scope(e, client):
            with module._secret_scope(e, client):
                client.remember('NEW_TOKEN')
                assert pyengine._CUSTOMER_KEYS['NEW_TOKEN'] == 2
                assert pyengine._safe_diagnostics({'message': 'NEW_TOKEN'}) == {'message': '[redacted]'}
            assert pyengine._CUSTOMER_KEYS['NEW_TOKEN'] == 1
        assert not pyengine._CUSTOMER_KEYS and client.active_scopes == 0
    finally:
        client.pool.clear()


@pytest.mark.parametrize('selected', [None, '101'])
def test_gcs_socket_free_move_conditions_the_correct_source(pyengine, gcs_config, selected):
    module = pyengine._gcs_module()
    e = SimpleNamespace(**vars(pyengine))
    calls = []
    def json_request(method, path, query=None, value=None):
        calls.append((method, path, query))
        return {'generation': '101'} if method == 'GET' else {'done': True}
    def request(method, path, query=None):
        calls.append((method, path, query))
        if selected is None:
            # Model a replacement of the live source after the copy: selecting
            # generation=101 would hide it, but the live precondition fails.
            assert query == {'ifGenerationMatch': '101'}
            raise e.SidecarError('object_conflict', 'Precondition failed.', {'provider': 'gcs', 'httpStatus': 412})
        assert query == {'generation': '101', 'ifGenerationMatch': '101'}
    client = SimpleNamespace(e=e, path=lambda b, k: '/b/' + b + '/o/' + quote(k, safe=''),
                             json=json_request, request=request)
    params = {**copy_params(), **({'sourceVersionId': selected} if selected is not None else {})}
    if selected is None:
        with pytest.raises(pyengine.SidecarError) as error:
            module._copy(params, client, move=True)
        assert error.value.details['sourceRetained']
    else:
        assert module._copy(params, client, move=True)['copied']
        assert calls[0][2] == {'generation': '101'}


def test_gcs_rsa_key_file_validation_never_echoes_pem(pyengine, gcs_config):
    value = json.loads(gcs_config.profile['secretKey'])
    value['private_key'] = '-----BEGIN PRIVATE KEY-----\nKNOWN_KEY_FRAGMENT\n-----END PRIVATE KEY-----'
    profile = {**gcs_config.profile, 'secretKey': json.dumps(value)}
    with pytest.raises(pyengine.SidecarError) as error:
        pyengine.handle_request({'method': 'listBuckets', 'params': {'profile': profile}})
    assert error.value.code == 'invalid_config' and 'KNOWN_KEY_FRAGMENT' not in str(error.value)
