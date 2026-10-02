"""Rust/Java advanced regressions, exercised with ENGINE_CMD and a disposable S3 fixture."""
import hashlib
import json
import tempfile
import threading
import time
import uuid
import zlib
import xml.etree.ElementTree as ET
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import parse_qs, unquote, urlparse
from xml.sax.saxutils import escape

import pytest


@pytest.fixture
def native_engine(engine):
    name = engine.request('health')['result']['engine']
    if name not in ('rust', 'java'):
        pytest.skip('Native Rust/Java regression suite; use ENGINE_CMD.')
    return engine, name


@pytest.fixture
def s3_fixture():
    class Handler(BaseHTTPRequestHandler):
        protocol_version = "HTTP/1.1"
        objects = {' spaced +%雪 ': b'original'}
        mode = 'normal'
        versioning = ''
        events = []
        lifecycle = None
        puts = 0
        active = 0
        parallel = 0
        lock = threading.Lock()
        deny_inspector = False
        slow_put = 0
        fail_puts = 0
        corrupt_get = False
        put_attempts = 0
        head_delay = 0
        head_started = threading.Event()
        copy_size = None
        changed_list = False
        def log_message(self, *_): pass
        def path_info(self):
            p = urlparse(self.path)
            return unquote(p.path).split('/', 2)[-1], parse_qs(p.query, keep_blank_values=True)
        def reply(self, body='', code=200, headers=None):
            data = body.encode() if isinstance(body, str) else body
            self.send_response(code)
            self.send_header('Content-Type', 'application/xml')
            self.send_header('Content-Length', str(len(data)))
            for k, v in (headers or {}).items(): self.send_header(k, v)
            self.end_headers()
            if self.command != 'HEAD': self.wfile.write(data)
        def error(self, code, status=500): self.reply(f'<Error><Code>{code}</Code><Message>fixture {code}</Message></Error>', status)
        def body(self):
            if self.headers.get('Transfer-Encoding', '').lower() == 'chunked':
                chunks = []
                while True:
                    size = int(self.rfile.readline().split(b';', 1)[0].strip(), 16)
                    if not size:
                        while self.rfile.readline().strip(): pass
                        break
                    chunks.append(self.rfile.read(size)); self.rfile.read(2)
                data = b''.join(chunks)
            else: data = self.rfile.read(int(self.headers.get('Content-Length', 0)))
            if 'aws-chunked' in self.headers.get('Content-Encoding', ''):
                # AWS checksum framing wraps the decoded body in payload chunks.
                output = bytearray()
                while data:
                    header, data = data.split(b'\r\n', 1)
                    length = int(header.split(b';', 1)[0], 16)
                    if not length: break
                    output.extend(data[:length]); data = data[length+2:]
                return bytes(output)
            return data
        def do_GET(self):
            key, q = self.path_info()
            if 'versioning' in q:
                if Handler.versioning == 'unknown': return self.error('AccessDenied', 403)
                return self.reply('<VersioningConfiguration xmlns="http://s3.amazonaws.com/doc/2006-03-01/">' + (f'<Status>{Handler.versioning}</Status>' if Handler.versioning else '') + '</VersioningConfiguration>')
            if 'list-type' in q:
                prefix = q.get('prefix', [''])[0]
                etag = 'replacement' if Handler.changed_list and any(e[0]=='BATCH' for e in Handler.events) else 'original'
                contents = ''.join(f'<Contents><Key>{escape(k)}</Key><Size>{len(v)}</Size><ETag>&quot;{etag}&quot;</ETag><LastModified>2026-01-01T00:00:00Z</LastModified></Contents>' for k, v in Handler.objects.items() if k.startswith(prefix))
                return self.reply('<ListBucketResult xmlns="http://s3.amazonaws.com/doc/2006-03-01/"><IsTruncated>false</IsTruncated>'+contents+'</ListBucketResult>')
            if 'versions' in q:
                if Handler.mode == 'version-pages':
                    next_page = 'key-marker' in q
                    Handler.events.append(('VERSIONS', q.get('key-marker'), q.get('version-id-marker')))
                    key = next(iter(Handler.objects))
                    marker = '' if next_page else '<NextKeyMarker>'+escape(key)+'</NextKeyMarker><NextVersionIdMarker>v1</NextVersionIdMarker>'
                    return self.reply('<ListVersionsResult><IsTruncated>'+str(not next_page).lower()+'</IsTruncated>'+marker+'<Version><Key>'+escape(key)+'</Key><VersionId>'+('v2' if next_page else 'v1')+'</VersionId><Size>8</Size><LastModified>2026-01-01T00:00:00Z</LastModified></Version></ListVersionsResult>')
                contents = ''.join(f'<Version><Key>{escape(k)}</Key><VersionId>null</VersionId><IsLatest>true</IsLatest><LastModified>2026-01-01T00:00:00Z</LastModified><Size>{len(v)}</Size></Version>' for k, v in Handler.objects.items())
                return self.reply('<ListVersionsResult xmlns="http://s3.amazonaws.com/doc/2006-03-01/"><IsTruncated>false</IsTruncated>'+contents+'</ListVersionsResult>')
            if 'lifecycle' in q:
                if Handler.deny_inspector: return self.error('AccessDenied', 403)
                if Handler.lifecycle: return self.reply(Handler.lifecycle, headers={'x-amz-transition-default-minimum-object-size': 'varies_by_storage_class'})
                return self.error('NoSuchLifecycleConfiguration', 404)
            if 'object-lock' in q: return self.reply('<ObjectLockConfiguration xmlns="http://s3.amazonaws.com/doc/2006-03-01/"><ObjectLockEnabled>Enabled</ObjectLockEnabled><Rule><DefaultRetention><Mode>GOVERNANCE</Mode><Years>2</Years></DefaultRetention></Rule></ObjectLockConfiguration>')
            if 'tagging' in q: return self.reply('<Tagging xmlns="http://s3.amazonaws.com/doc/2006-03-01/"><TagSet/></Tagging>')
            if any(k in q for k in ('encryption','policy','cors')): return self.error('NotImplemented', 501)
            if key in Handler.objects:
                data = Handler.objects[key]
                if Handler.corrupt_get and data: data = bytes([data[0] ^ 1]) + data[1:]
                return self.reply(data)
            return self.error('NoSuchKey', 404)
        def do_HEAD(self):
            key, q = self.path_info()
            Handler.events.append(('HEAD', key, q.get('versionId', [None])[0]))
            Handler.head_started.set()
            if Handler.head_delay: time.sleep(Handler.head_delay)
            self.send_response(200)
            self.send_header('Content-Length', str(Handler.copy_size if Handler.copy_size is not None else len(Handler.objects.get(key, b'original'))))
            self.send_header('ETag', '"original"')
            self.send_header('Content-Type', 'application/octet-stream')
            if Handler.mode == 'retained': self.send_header('x-amz-object-lock-mode', 'COMPLIANCE')
            self.end_headers()
        def do_POST(self):
            data = self.body()
            _, q = self.path_info()
            if 'uploads' in q:
                Handler.events.append(('INIT',))
                return self.reply('<InitiateMultipartUploadResult><Bucket>fixture</Bucket><Key>dest</Key><UploadId>upload-fixture</UploadId></InitiateMultipartUploadResult>')
            if 'uploadId' in q:
                Handler.events.append(('COMPLETE',))
                return self.reply('<CompleteMultipartUploadResult><ETag>copied</ETag></CompleteMultipartUploadResult>')
            assert 'delete' in q
            root = ET.fromstring(data)
            def field(o, name): return next((e.text or '' for e in o if e.tag.rsplit('}', 1)[-1] == name), None)
            parts = []
            for node in root:
                if node.tag.rsplit('}', 1)[-1] != 'Object': continue
                key, version = field(node, 'Key'), field(node, 'VersionId')
                Handler.events.append(('BATCH', key, version))
                fail = Handler.mode in ('stale','denied','final-failure','individual-success','retained')
                if fail:
                    code = 'AccessDenied' if Handler.mode == 'denied' else 'InternalError'
                    parts.append(f'<Error><Key>{escape(key)}</Key><Code>{code}</Code><Message>fixture</Message>'+('' if version is None else f'<VersionId>{version}</VersionId>')+'</Error>')
                else:
                    if Handler.mode != 'phantom': Handler.objects.pop(key, None)
                    parts.append(f'<Deleted><Key>{escape(key)}</Key>'+('' if version is None else f'<VersionId>{version}</VersionId>')+'</Deleted>')
            self.reply('<DeleteResult xmlns="http://s3.amazonaws.com/doc/2006-03-01/">'+''.join(parts)+'</DeleteResult>')
        def do_DELETE(self):
            key, q = self.path_info(); Handler.events.append(('DELETE', key, q.get('versionId', [None])[0]))
            if Handler.mode in ('final-failure', 'retained') or (Handler.mode == 'stale' and Handler.objects.get(key) != b''): return self.error('InternalError')
            if Handler.mode != 'phantom' or Handler.objects.get(key) == b'': Handler.objects.pop(key, None)
            self.reply('', 204)
        def do_PUT(self):
            key, q = self.path_info(); data = self.body()
            if self.headers.get('x-amz-copy-source'):
                Handler.events.append(('COPY', self.headers.get('x-amz-copy-source'), self.headers.get('x-amz-copy-source-range'), self.headers.get('x-amz-copy-source-if-match')))
                return self.reply('<CopyPartResult><ETag>copied</ETag></CopyPartResult>' if 'uploadId' in q else '<CopyObjectResult><ETag>copied</ETag></CopyObjectResult>')
            if 'lifecycle' in q:
                Handler.lifecycle = data
                Handler.events.append(('LIFECYCLE', self.headers.get('x-amz-transition-default-minimum-object-size')))
                return self.reply('')
            Handler.events.append(('PUT', key, self.headers.get('If-Match')))
            with Handler.lock:
                Handler.put_attempts += 1
                fail = Handler.fail_puts > 0
                if fail: Handler.fail_puts -= 1
            if fail: return self.error('InternalError')
            with Handler.lock:
                Handler.puts += 1; Handler.active += 1; Handler.parallel = max(Handler.parallel, Handler.active)
            if Handler.slow_put: time.sleep(Handler.slow_put)
            Handler.objects[key] = data
            with Handler.lock: Handler.active -= 1
            self.reply('', headers={'ETag': '"fixture"'})
    class FixtureServer(ThreadingHTTPServer):
        request_queue_size = 64
    server = FixtureServer(('127.0.0.1', 0), Handler)
    thread = threading.Thread(target=server.serve_forever, daemon=True); thread.start()
    profile = {'id': 'native-test', 'endpointType': 's3Compatible', 'endpointUrl': f'http://127.0.0.1:{server.server_port}', 'region': 'us-east-1', 'accessKey': 'fictional-access', 'secretKey': 'fictional-secret', 'sessionToken': 'fictional-token', 'pathStyle': True, 'verifyTls': True, 'maxAttempts': 1, 'connectTimeoutSeconds': 2, 'readTimeoutSeconds': 3}
    try: yield profile, Handler
    finally: server.shutdown(); server.server_close(); thread.join()


def delete(engine, profile, retries=1):
    return engine.request('runDeleteAll', {'profile': profile, 'config': {'bucketName': 'fixture', 'maxRetries': retries, 'maxWorkers': 2, 'batchSize': 1000, 'listMaxKeys': 1000}}, timeout=20)


@pytest.mark.parametrize('mode', ['stale', 'phantom'])
def test_delete_recovers_only_after_normal_and_individual_retries(native_engine, s3_fixture, mode):
    engine, _ = native_engine; profile, fixture = s3_fixture; fixture.mode = mode
    response = delete(engine, profile)
    assert response['ok'], response
    assert response['result']['exitCode'] == 0, response
    assert response['result']['deletedCount'] == 1 and response['result']['verifiedEmpty']
    ops = [e[0] for e in fixture.events if e[0] != 'HEAD']
    assert ops[:2] == ['BATCH', 'BATCH']
    assert ops.index('DELETE') < ops.index('PUT') < len(ops)-1
    assert ops[-1] == 'DELETE' and fixture.puts == 1
    assert next(e[2] for e in fixture.events if e[0] == 'PUT') == '"original"'
    assert all(e[1] == ' spaced +%雪 ' for e in fixture.events)


@pytest.mark.parametrize('versioning,kind,mode', [('', 'awsS3', 'stale'), ('Enabled','s3Compatible','stale'), ('Suspended','s3Compatible','stale'), ('unknown','s3Compatible','stale'), ('','s3Compatible','denied')])
def test_delete_never_overwrites_ineligible_keys(native_engine, s3_fixture, versioning, kind, mode):
    engine, _ = native_engine; profile, fixture = s3_fixture
    fixture.versioning, fixture.mode, profile['endpointType'] = versioning, mode, kind
    response = delete(engine, profile)
    assert response['ok'], response
    assert response['result']['exitCode'] != 0
    assert fixture.puts == 0
    if versioning: assert all(e[2] == 'null' for e in fixture.events if e[0] == 'BATCH')


def test_delete_normal_success_never_puts(native_engine, s3_fixture):
    engine, _ = native_engine; profile, fixture = s3_fixture
    response = delete(engine, profile)
    assert response['ok'] and response['result']['exitCode'] == 0, response
    assert [e[0] for e in fixture.events] == ['BATCH']
    assert fixture.puts == 0


def test_delete_final_failure_reports_empty_object(native_engine, s3_fixture):
    engine, _ = native_engine; profile, fixture = s3_fixture; fixture.mode = 'final-failure'
    response = delete(engine, profile)
    assert response['ok'], response
    assert response['result']['exitCode'] != 0
    assert response['result']['emptyObjectsLeft'] == 1
    assert 'overwritten with an empty object; delete failed' in '\n'.join(response['result']['outputLines'])


def test_inspector_preserves_partial_sections_and_retention_units(native_engine, s3_fixture):
    engine, _ = native_engine; profile, fixture = s3_fixture; fixture.deny_inspector = True
    response = engine.request('getBucketAdminState', {'profile': profile, 'bucketName': 'fixture'})
    assert response['ok'], response
    data = response['result']; assert data['sections']['GetBucketLifecycleConfiguration']['state'] == 'denied'
    assert data['objectLockRetentionValue'] == 2 and data['objectLockRetentionUnit'] == 'years'
    assert data['objectLockRetentionDays'] is None and data['objectLockRetentionYears'] == 2


def test_lifecycle_roundtrip_preserves_complex_fields(native_engine, s3_fixture):
    engine, _ = native_engine; profile, fixture = s3_fixture
    rule = {'ID': 'complex', 'Status': 'Enabled', 'Filter': {'And': {'Prefix': ' scoped/ ', 'Tags': [{'Key': 'tier', 'Value': 'archive'}], 'ObjectSizeGreaterThan': 128, 'ObjectSizeLessThan': 9000}}, 'Expiration': {'Date': '2035-01-01T00:00:00Z'}, 'Transitions': [{'Date': '2030-01-01T00:00:00Z', 'StorageClass': 'GLACIER'}], 'NoncurrentVersionExpiration': {'NoncurrentDays': 365, 'NewerNoncurrentVersions': 5}, 'NoncurrentVersionTransitions': [{'NoncurrentDays': 60, 'NewerNoncurrentVersions': 3, 'StorageClass': 'STANDARD_IA'}]}
    response = engine.request('putBucketLifecycle', {'profile': profile, 'bucketName': 'fixture', 'lifecycleJson': json.dumps({'Rules': [rule], 'TransitionDefaultMinimumObjectSize': 'varies_by_storage_class'})})
    assert response['ok'], response
    actual = json.loads(response['result']['lifecycleJson'])
    # SDK XML dates may be normalized with milliseconds; compare the calendar instant.
    for field in ('Expiration',): assert actual['Rules'][0][field]['Date'].replace('.000Z', 'Z') == rule[field]['Date']
    actual['Rules'][0]['Expiration']['Date'] = rule['Expiration']['Date']
    actual['Rules'][0]['Transitions'][0]['Date'] = actual['Rules'][0]['Transitions'][0]['Date'].replace('.000Z', 'Z')
    assert actual['Rules'] == [rule]
    assert actual['TransitionDefaultMinimumObjectSize'] == 'varies_by_storage_class'
    assert ('LIFECYCLE', 'varies_by_storage_class') in fixture.events


def test_benchmark_progresses_without_polling_and_never_persists_profile(native_engine, s3_fixture, tmp_path):
    engine, name = native_engine; profile, fixture = s3_fixture; fixture.slow_put = .03
    config = {'bucketName': 'fixture', 'testMode': 'operation-count', 'operationCount': 12, 'objectCount': 20, 'objectSizes': [32], 'workloadType': 'write-only', 'concurrentThreads': 4, 'maxPoolConnections': 4, 'connectTimeoutSeconds': 2, 'readTimeoutSeconds': 3, 'maxAttempts': 1, 'csvOutputPath': str(tmp_path/'result.csv'), 'jsonOutputPath': str(tmp_path/'result.json'), 'logFilePath': str(tmp_path/'result.log')}
    started = engine.request('startBenchmark', {'profile': profile, 'config': config})
    assert started['ok'], started
    run_id = started['result']['id']
    assert 'profile' not in started['result']
    deadline = time.monotonic()+5
    while fixture.puts < 12 and time.monotonic() < deadline: time.sleep(.05)
    assert fixture.puts >= 12, 'Work only progresses when polled.'
    status = engine.request('getBenchmarkStatus', {'runId': run_id, 'profile': profile})
    assert status['ok'], status
    assert status['result']['processedCount'] == 12
    assert fixture.parallel > 1, 'Configured benchmark workers must run concurrently.'
    state = Path(tempfile.gettempdir())/f'object-data-browser-{name}-engine'/f'benchmark-{run_id}.json'
    saved = state.read_text()
    for value in ('fictional-access','fictional-secret','fictional-token'): assert value not in saved and value not in json.dumps(status)
    assert 'profile' not in json.loads(saved)


def test_individual_delete_success_does_not_overwrite(native_engine, s3_fixture):
    engine, _ = native_engine; profile, fixture = s3_fixture; fixture.mode = 'individual-success'
    result = delete(engine, profile)
    assert result['ok'] and result['result']['exitCode'] == 0, result
    assert fixture.puts == 0 and [e[0] for e in fixture.events] == ['BATCH', 'BATCH', 'DELETE']


@pytest.mark.parametrize('changed,mode', [(True, 'stale'), (False, 'retained')])
def test_changed_or_retained_object_is_never_overwritten(native_engine, s3_fixture, changed, mode):
    engine, _ = native_engine; profile, fixture = s3_fixture
    fixture.changed_list, fixture.mode = changed, mode
    result = delete(engine, profile)
    assert result['ok'] and result['result']['exitCode'] != 0, result
    assert fixture.puts == 0


def test_cancellation_reaches_the_pre_overwrite_checkpoint(native_engine, s3_fixture):
    engine, _ = native_engine; profile, fixture = s3_fixture
    fixture.mode = 'stale'; fixture.head_delay = .4
    engine.send({'requestId':'delete-running','method':'runDeleteAll','params':{'jobId':'cancel-fixture','profile':profile,'config':{'bucketName':'fixture','maxRetries':0}}})
    assert fixture.head_started.wait(5)
    engine.send({'requestId':'cancel-running','method':'cancelToolExecution','params':{'jobId':'cancel-fixture'}})
    replies = [engine.recv_json(timeout=10),engine.recv_json(timeout=10)]
    result = next(r for r in replies if r.get('requestId') == 'delete-running')
    assert result['ok'] and result['result']['exitCode'] == 130, result
    assert fixture.puts == 0


@pytest.mark.parametrize('versioning', ['Enabled', 'Suspended'])
def test_versioned_delete_preserves_literal_null_id(native_engine, s3_fixture, versioning):
    engine, _ = native_engine; profile, fixture = s3_fixture; fixture.versioning = versioning
    result = delete(engine, profile)
    assert result['ok'] and result['result']['exitCode'] == 0, result
    assert fixture.events == [('BATCH', ' spaced +%雪 ', 'null')]


@pytest.mark.parametrize('size', [0, 5*1024**3, 5*1024**3+1])
def test_copy_boundary_uses_conditioned_multipart_ranges(native_engine, s3_fixture, size):
    engine, _ = native_engine; profile, fixture = s3_fixture; fixture.copy_size = size
    result = engine.request('copyObject', {'profile':profile,'sourceBucketName':'fixture','sourceKey':' spaced +%雪 ','destinationBucketName':'destination','destinationKey':'copy','sourceVersionId':'null'}, timeout=20)
    assert result['ok'] and result['result']['successCount'] == 1, result
    copies = [e for e in fixture.events if e[0] == 'COPY']
    assert all(unquote(e[1]) == 'fixture/ spaced +%雪 ?versionId=null' and e[3] == '"original"' for e in copies)
    if size > 5*1024**3:
        assert ('INIT',) in fixture.events and ('COMPLETE',) in fixture.events
        ranges = sorted(tuple(map(int, e[2][6:].split('-'))) for e in copies)
        assert ranges[0][0] == 0 and ranges[-1][1] == size-1
        assert all(b-a+1 <= 128*1024**2 for a,b in ranges)
        assert all(ranges[i][1]+1 == ranges[i+1][0] for i in range(len(ranges)-1))
    else: assert len(copies) == 1 and copies[0][2] is None


def test_move_keeps_unversioned_compatible_source_without_proven_conditional_delete(native_engine, s3_fixture):
    engine, _ = native_engine; profile, fixture = s3_fixture
    result = engine.request('moveObject', {'profile':profile,'sourceBucketName':'fixture','sourceKey':' spaced +%雪 ','destinationBucketName':'destination','destinationKey':'copy'})
    assert result['ok'] and result['result']['copyCompleted'] and result['result']['sourceRetained'], result
    assert all(e[0] != 'DELETE' for e in fixture.events)


def test_versioned_phantom_listing_has_bounded_normal_retries_and_no_reset(native_engine, s3_fixture):
    engine, _ = native_engine; profile, fixture = s3_fixture
    fixture.versioning = 'Enabled'; fixture.mode = 'phantom'
    result = delete(engine, profile, retries=1)
    assert result['ok'] and result['result']['exitCode'] != 0, result
    assert fixture.events == [('BATCH', ' spaced +%雪 ', 'null'), ('BATCH', ' spaced +%雪 ', 'null')]
    assert result['result']['deletedCount'] == 0 and fixture.puts == 0


def test_native_version_cursor_and_exact_version_inspection(native_engine, s3_fixture):
    engine, _ = native_engine; profile, fixture = s3_fixture; fixture.mode = 'version-pages'
    params = {'profile':profile,'bucketName':'fixture','key':' spaced +%雪 '}
    first = engine.request('listObjectVersions', params)
    assert first['ok'] and first['result']['cursor']['hasMore'], first
    second = engine.request('listObjectVersions', {**params,'cursor':first['result']['cursor']})
    assert second['ok'] and not second['result']['cursor']['hasMore'], second
    assert [first['result']['items'][0]['versionId'],second['result']['items'][0]['versionId']] == ['v1','v2']
    assert fixture.events[-1] == ('VERSIONS', [' spaced +%雪 '], ['v1'])
    details = engine.request('getObjectDetails', {**params,'versionId':'null'})
    assert details['ok'], details
    assert ('HEAD',' spaced +%雪 ','null') in fixture.events
    signed = engine.request('generatePresignedUrl', {**params,'versionId':'null','expirationSeconds':60})
    assert signed['ok'] and parse_qs(urlparse(signed['result']['url']).query)['versionId'] == ['null'], signed


def test_known_bucket_connection_avoids_global_bucket_listing(native_engine, s3_fixture):
    engine, _ = native_engine; profile, _ = s3_fixture; profile['knownBucket']='fixture'
    checked = engine.request('testProfile',{'profile':profile})
    assert checked['ok'] and checked['result']['ok'], checked
    buckets = engine.request('listBuckets',{'profile':profile})
    assert buckets['ok'] and [v['name'] for v in buckets['result']['items']] == ['fixture'], buckets


def benchmark_config(tmp_path, **overrides):
    return {'bucketName': 'fixture', 'testMode': 'operation-count', 'operationCount': 5,
            'objectCount': 1, 'objectSizes': [32768], 'workloadType': 'write-only',
            'concurrentThreads': 1, 'maxPoolConnections': 1, 'connectTimeoutSeconds': 2,
            'readTimeoutSeconds': 3, 'maxAttempts': 2, 'dataCacheMb': 1, 'reducedLogging': True,
            'csvOutputPath': str(tmp_path/'result.csv'), 'jsonOutputPath': str(tmp_path/'result.json'),
            'logFilePath': str(tmp_path/'result.log'), **overrides}


def await_benchmark(engine, profile, run_id):
    deadline = time.monotonic()+15
    while time.monotonic() < deadline:
        response = engine.request('getBenchmarkStatus', {'runId': run_id, 'profile': profile})
        assert response['ok'], response
        if response['result']['status'] != 'running': return response['result']
        time.sleep(.05)
    pytest.fail('Benchmark did not finish within the fixture deadline.')


@pytest.mark.parametrize('in_memory', [False, True])
def test_native_benchmark_payload_storage_and_completion_times(native_engine, s3_fixture, tmp_path, in_memory):
    engine, _ = native_engine; profile, fixture = s3_fixture
    config = benchmark_config(tmp_path, inMemoryData=in_memory)
    started = engine.request('startBenchmark', {'profile': profile, 'config': config})
    assert started['ok'], started
    state = await_benchmark(engine, profile, started['result']['id'])
    assert state['status'] == 'completed' and state['processedCount'] == 5, state
    metrics = state['resultSummary']['detailMetrics']
    assert metrics['cacheBytes'] == (32768 if in_memory else 0)
    assert metrics['errorCount'] == metrics['retryCount'] == 0
    elapsed = [r['elapsedMs'] for r in state['history']]
    assert len(elapsed) == 5 and elapsed == sorted(elapsed) and elapsed[-1] > elapsed[0]
    assert elapsed[-1] <= state['activeElapsedSeconds'] * 1000 + 5
    assert not any(line.startswith('PUT ') for line in state['liveLog'])
    assert state['resultSummary']['totalOperations'] == 5
    assert len(Path(state['config']['csvOutputPath']).read_text().splitlines()) == 6


@pytest.mark.parametrize('failures,attempts,expected_status,retries,errors', [(1, 2, 'completed', 1, 0), (3, 1, 'failed', 0, 1)])
def test_native_benchmark_reports_real_sdk_retries_and_failures(native_engine, s3_fixture, tmp_path, failures, attempts, expected_status, retries, errors):
    engine, _ = native_engine; profile, fixture = s3_fixture; fixture.fail_puts = failures
    config = benchmark_config(tmp_path, operationCount=1, maxAttempts=attempts)
    started = engine.request('startBenchmark', {'profile': profile, 'config': config})
    assert started['ok'], started
    state = await_benchmark(engine, profile, started['result']['id'])
    assert state['status'] == expected_status, state
    metrics = state['resultSummary']['detailMetrics']
    assert metrics['retryCount'] == retries and metrics['errorCount'] == errors, metrics
    assert state['processedCount'] == (1 if expected_status == 'completed' else 0)


@pytest.mark.parametrize('validate,algorithm,corrupt', [(False, 'sha256', False)] +
                         [(True, algorithm, corrupt) for algorithm in ['sha256', 'sha1', 'md5', 'crc32', 'crc32c'] for corrupt in [False, True]])
def test_native_streamed_benchmark_get_validates_pattern_without_full_object_buffers(native_engine, s3_fixture, tmp_path, validate, algorithm, corrupt):
    engine, _ = native_engine; profile, fixture = s3_fixture
    fixture.corrupt_get = corrupt
    config = benchmark_config(tmp_path, inMemoryData=False, workloadType='custom', writePercent=1,
                              readPercent=4, deletePercent=0, validateChecksum=validate, checksumAlgorithm=algorithm)
    started = engine.request('startBenchmark', {'profile': profile, 'config': config})
    assert started['ok'], started
    state = await_benchmark(engine, profile, started['result']['id'])
    assert state['status'] == 'completed', state
    assert state['resultSummary']['operationsByType'] == {'PUT': 1, 'GET': 4}
    gets = [r for r in state['history'] if r['operation'] == 'GET']
    assert all(r['bytesTransferred'] == 32768 for r in gets)
    expected_state = ('validated_failure' if corrupt else 'validated_success') if validate else 'not_used'
    assert all(r['checksumState'] == expected_state for r in gets)
    assert state['resultSummary']['detailMetrics']['checksumAlgorithm'] == algorithm
    for record in gets:
        assert record['checksumAlgorithm'] == algorithm
        data = fixture.objects[record['key']]
        if corrupt: data = bytes([data[0] ^ 1]) + data[1:]
        if algorithm == 'crc32': expected_digest = f'{zlib.crc32(data):08x}'
        elif algorithm == 'crc32c':
            # Independent bitwise reference rather than the engines' optimized implementations.
            crc = 0xffffffff
            for byte in data:
                crc ^= byte
                for _ in range(8): crc = (crc >> 1) ^ (0x82f63b78 if crc & 1 else 0)
            expected_digest = f'{crc ^ 0xffffffff:08x}'
        else: expected_digest = hashlib.new(algorithm, data).hexdigest()
        assert record.get('checksum') == (expected_digest if validate else None)


def test_native_benchmark_rejects_unsupported_checksum_algorithm(native_engine, s3_fixture, tmp_path):
    engine, _ = native_engine; profile, _ = s3_fixture
    result = engine.request('startBenchmark', {'profile': profile,
                            'config': benchmark_config(tmp_path, checksumAlgorithm='unsupported-hash')})
    assert not result['ok'] and result['error']['code'] == 'invalid_config', result


def test_native_benchmark_resume_retains_exact_totals_with_bounded_recent_history(native_engine, s3_fixture, tmp_path):
    """Restore a large checkpoint without issuing 10000 unrelated network requests in the test."""
    engine, name = native_engine; profile, _ = s3_fixture
    config = benchmark_config(tmp_path, operationCount=1)
    started = engine.request('startBenchmark', {'profile': profile, 'config': config})
    assert started['ok'], started
    seed = await_benchmark(engine, profile, started['result']['id'])
    restored_id = f'bench-restored-{uuid.uuid4().hex[:8]}'
    seed.update(id=restored_id, status='paused', processedCount=10000, totalRecordCount=10000,
                totalBytes=32768*10000, totalLatencyMs=10*10000, activeElapsedSeconds=1,
                totalOperationsByType={'PUT':10000}, totalChecksumStats={'not_used':10000})
    seed['history'] = [{**seed['history'][0], 'elapsedMs': .1*i, 'second':1, 'latencyMs':10} for i in range(10000)]
    seed['config'].update(operationCount=10002, csvOutputPath=str(tmp_path/'restored'/'full.csv'),
                          jsonOutputPath=str(tmp_path/'restored'/'full.json'), logFilePath=str(tmp_path/'restored'/'full.log'))
    seed['throughputWindows'] = {'1': {'operationsCount':10000, 'bytes':32768*10000,
                                      'latencyMs':10*10000, 'records':10000, 'operations':{'PUT':10000}}}
    state_path = Path(tempfile.gettempdir())/f'object-data-browser-{name}-engine'/f'benchmark-{restored_id}.json'
    state_path.write_text(json.dumps(seed))
    try:
        resumed = engine.request('resumeBenchmark', {'runId':restored_id, 'profile':profile})
        assert resumed['ok'], resumed
        state = await_benchmark(engine, profile, restored_id)
        assert state['status'] == 'completed' and state['processedCount'] == 10002
        assert len(state['history']) == 10000
        summary = state['resultSummary']; metrics = summary['detailMetrics']
        assert summary['totalOperations'] == summary['operationsByType']['PUT'] == 10002
        assert metrics['historyTruncated'] and metrics['historyRecordsRetained'] == metrics['historyLimit'] == 10000
        assert sum(w['opsPerSecond'] for w in summary['throughputSeries']) == 10002
        assert len(Path(state['config']['csvOutputPath']).read_text().splitlines()) == 3
    finally: state_path.unlink(missing_ok=True)
