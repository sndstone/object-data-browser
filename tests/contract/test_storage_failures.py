"""Loopback-only HTTP fixtures: no cloud credentials or user storage involved."""
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse

import pytest

class FixtureProfile(dict):
    pass


@pytest.fixture
def storage_fixture():
    class Handler(BaseHTTPRequestHandler):
        aborted = False
        hold_parts = False
        part_started = threading.Event()
        release_parts = threading.Event()
        def log_message(self, *_):
            pass

        def respond(self, body, status=200):
            data = body.encode()
            self.send_response(status)
            self.send_header("Content-Type", "application/xml")
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            self.wfile.write(data)

        def do_POST(self):
            self.rfile.read(int(self.headers.get("Content-Length", "0")))
            if "uploads" in self.path:
                self.respond('<InitiateMultipartUploadResult xmlns="http://s3.amazonaws.com/doc/2006-03-01/"><Bucket>fixture-bucket</Bucket><Key>large.bin</Key><UploadId>fixture-upload</UploadId></InitiateMultipartUploadResult>')
                return
            self.respond('''<DeleteResult xmlns="http://s3.amazonaws.com/doc/2006-03-01/">
              <Deleted><Key>allowed.txt</Key></Deleted>
              <Error><Key>denied.txt</Key><Code>AccessDenied</Code><Message>Fixture denied deletion</Message></Error>
            </DeleteResult>''')

        def do_PUT(self):
            self.rfile.read(int(self.headers.get("Content-Length", "0")))
            if Handler.hold_parts:
                Handler.part_started.set()
                Handler.release_parts.wait(15)
            self.respond('<Error><Code>InvalidRequest</Code><Message>Injected part failure</Message></Error>', 400)

        def do_DELETE(self):
            if self.path.endswith('denied.txt'):
                self.respond('<Error><Code>AuthorizationFailure</Code><Message>Fixture denied deletion</Message></Error>', 403)
                return
            Handler.aborted = True
            self.respond('', 202 if 'uploadId' not in self.path else 204)

        def do_GET(self):
            query = parse_qs(urlparse(self.path).query)
            if query.get('restype') == ['container']:
                second = query.get('marker') == ['fixture-next']
                self.respond(f'''<EnumerationResults><Prefix>reports/</Prefix><Blobs><Blob><Name>reports/{'second' if second else 'first'}.txt</Name><Properties><Last-Modified>Sat, 05 Sep 2026 00:00:00 GMT</Last-Modified><Content-Length>5</Content-Length><Content-Type>text/plain</Content-Type><BlobType>BlockBlob</BlobType></Properties></Blob></Blobs><NextMarker>{'' if second else 'fixture-next'}</NextMarker></EnumerationResults>''')
                return
            second = query.get("continuation-token") == ["fixture-next"]
            self.respond(f'''<ListBucketResult xmlns="http://s3.amazonaws.com/doc/2006-03-01/">
              <Name>fixture-bucket</Name><Prefix>reports/</Prefix><MaxKeys>1000</MaxKeys>
              <IsTruncated>{str(not second).lower()}</IsTruncated>
              {'' if second else '<NextContinuationToken>fixture-next</NextContinuationToken>'}
              <Contents><Key>reports/{'second' if second else 'first'}.txt</Key><LastModified>2026-09-05T00:00:00.000Z</LastModified><ETag>"etag"</ETag><Size>5</Size><StorageClass>STANDARD</StorageClass></Contents>
            </ListBucketResult>''')

    server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    try:
        profile = FixtureProfile({"id": "fixture", "name": "Fixture only", "endpointUrl": f"http://127.0.0.1:{server.server_port}",
               "endpointType": "s3Compatible", "region": "us-east-1", "accessKey": "fixture", "secretKey": "fixture",
               "pathStyle": True, "verifyTls": False, "connectTimeoutSeconds": 2, "readTimeoutSeconds": 3,
               "safeRetries": 0})
        profile.handler = Handler
        yield profile
    finally:
        Handler.release_parts.set()
        server.shutdown()
        server.server_close()
        thread.join(timeout=2)


def test_partial_delete_retains_failure_identity(engine, storage_fixture):
    response = engine.request("deleteObjects", params={"profile": storage_fixture,
        "bucketName": "fixture-bucket", "keys": ["allowed.txt", "denied.txt"]})
    assert response["ok"], response
    result = response["result"]
    assert result["successCount"] == 1, result
    assert result["failureCount"] == 1, result
    assert result["failures"][0]["target"] == "denied.txt", result


def test_cursor_is_forwarded_and_completion_is_explicit(engine, storage_fixture):
    params = {"profile": storage_fixture, "bucketName": "fixture-bucket", "prefix": "reports/", "flat": True}
    first = engine.request("listObjects", params=params)
    assert first["ok"], first
    page = first["result"]
    assert page["nextCursor"]["hasMore"], page
    assert page["items"][0]["key"] == "reports/first.txt"
    second = engine.request("listObjects", params={**params, "cursor": page["nextCursor"]})
    assert second["ok"], second
    assert second["result"]["items"][0]["key"] == "reports/second.txt", second
    assert second["result"]["nextCursor"]["hasMore"] is False


def test_controls_never_fabricate_success_for_nonexistent_jobs(engine):
    for method in ("pauseTransfer", "resumeTransfer", "cancelTransfer"):
        response = engine.request(method, params={"jobId": "no-such-fixture-job"})
        assert response["ok"] is False, response
        assert response["error"]["code"] in ("invalid_config", "unsupported_feature"), response


def test_live_controls_reach_a_real_running_transfer(engine, storage_fixture, tmp_path):
    engine_name = str(engine.request('health')['result'].get('engine', '')).lower()
    if 'python' not in engine_name and 'java' not in engine_name:
        pytest.skip('Sequential engines explicitly disable interactive controls')
    storage_fixture.handler.hold_parts = True
    storage_fixture['readTimeoutSeconds'] = 30
    source = tmp_path / 'large.bin'
    with source.open('wb') as output:
        output.truncate(11 * 1024 * 1024)
    engine.send({'requestId': 'controlled-upload', 'method': 'startUpload', 'params': {
        'profile': storage_fixture, 'bucketName': 'fixture-bucket', 'prefix': '',
        'filePaths': [str(source)], 'multipartThresholdMiB': 1, 'multipartChunkMiB': 5}})
    while True:
        event = engine.recv_json(timeout=20)
        if event.get('event') == 'transferProgress':
            job_id = event['job']['id']
            break
    assert storage_fixture.handler.part_started.wait(10), 'Transfer did not reach storage'
    for method, status in [('pauseTransfer', 'paused'), ('resumeTransfer', 'running'), ('cancelTransfer', 'cancelled')]:
        engine.send({'requestId': method, 'method': method, 'params': {'jobId': job_id}})
        while True:
            response = engine.recv_json(timeout=10)
            if response.get('requestId') == method:
                break
        assert response['ok'], response
        assert response['result']['status'] == status, response
    storage_fixture.handler.release_parts.set()
    while True:
        response = engine.recv_json(timeout=20)
        if response.get('requestId') == 'controlled-upload':
            break
    assert response.get('result', {}).get('status') != 'completed', response
    assert storage_fixture.handler.aborted, 'Cancellation did not clean up multipart upload'


def test_multipart_failure_is_not_reported_completed(engine, storage_fixture, tmp_path):
    source = tmp_path / 'large.bin'
    with source.open('wb') as output:
        output.truncate(11 * 1024 * 1024)
    request_id = 'multipart-fixture'
    engine.send({'requestId': request_id, 'method': 'startUpload', 'params': {
        'profile': storage_fixture, 'bucketName': 'fixture-bucket', 'prefix': '',
        'filePaths': [str(source)], 'multipartThresholdMiB': 1, 'multipartChunkMiB': 5}})
    while True:
        response = engine.recv_json(timeout=20)
        if response.get('requestId') == request_id:
            break
    assert response.get('ok') is False or response.get('result', {}).get('status') in ('failed', 'error'), response
    assert storage_fixture.handler.aborted, 'Failed multipart upload was not aborted'


def test_azure_cursor_and_partial_delete_on_supporting_engines(engine, storage_fixture):
    metadata = engine.request('health')['result']
    engine_name = str(metadata.get('engine', '')).lower()
    if 'python' not in engine_name and 'go' not in engine_name:
        pytest.skip('Azure is supported by Python and Go only')
    profile = {**storage_fixture, 'endpointType': 'azureBlob', 'secretKey': 'Zml4dHVyZQ=='}
    params = {'profile': profile, 'bucketName':'fixture-bucket', 'prefix':'reports/', 'flat':True}
    first = engine.request('listObjects', params=params)
    assert first['ok'], first
    cursor = first['result']['nextCursor']
    assert cursor['hasMore'], first
    second = engine.request('listObjects', params={**params, 'cursor':cursor})
    assert second['ok'], second
    assert second['result']['nextCursor']['hasMore'] is False, second
    assert second['result']['items'][0]['key'] == 'reports/second.txt', second
    deleted = engine.request('deleteObjects', params={'profile':profile,'bucketName':'fixture-bucket','keys':['allowed.txt','denied.txt']})
    assert deleted['ok'], deleted
    assert deleted['result']['successCount'] == 1, deleted
    assert deleted['result']['failureCount'] == 1, deleted
