"""Shared data-safety regressions using only disposable files and loopback HTTP."""
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import unquote, urlparse

import pytest


@pytest.fixture
def download_server():
    class Handler(BaseHTTPRequestHandler):
        mode = 'valid'
        copy_status = 'success'
        copy_id = 'fixture-copy'
        deletes = 0
        polls = 0
        objects = {'a/report.txt': b'FIRST', 'b/report.txt': b'SECOND', 'existing.txt': b'NEW',
                   'range.bin': b'x' * (1024 * 1024), 'empty.txt': b''}
        def log_message(self, *_): pass
        def key(self): return unquote(urlparse(self.path).path).split('/', 2)[-1]
        def do_HEAD(self):
            if self.path.startswith('/dest/'):
                Handler.polls += 1
                self.send_response(200)
                status = 'success' if Handler.copy_status == 'eventual' else Handler.copy_status
                if status: self.send_header('x-ms-copy-status', status)
                self.send_header('x-ms-copy-id', Handler.copy_id)
                self.send_header('Content-Length', '0')
                self.end_headers()
                return
            self.send_response(200)
            self.send_header('Content-Length', str(len(self.objects.get(self.key(), b'NEW'))))
            self.send_header('ETag', '"fixture-v1"')
            self.end_headers()
        def do_GET(self):
            if Handler.mode == 'failure':
                body = b'<Error><Code>AccessDenied</Code><Message>Fixture denied</Message></Error>'
                self.send_response(403); self.send_header('Content-Length', str(len(body))); self.end_headers(); self.wfile.write(body); return
            data = self.objects.get(self.key(), b'NEW')
            total = len(data)
            range_header = self.headers.get('Range')
            self.send_response(206 if range_header and Handler.mode != 'ignored' else 200)
            if range_header:
                start, end = map(int, range_header[6:].split('-'))
                if Handler.mode != 'ignored': data = data[start:end+1]
                if Handler.mode == 'short': data = data[:3]
                if Handler.mode == 'oversized': data += b'!'
                if Handler.mode != 'ignored': self.send_header('Content-Range', f'bytes {start + (1 if Handler.mode == "wrong-range" else 0)}-{end}/{total}')
            elif Handler.mode == 'short': data = data[:1]
            self.send_header('Content-Length', str(len(data)))
            self.send_header('ETag', '"fixture-v1"')
            self.end_headers()
            self.wfile.write(data)
        def do_PUT(self):
            self.rfile.read(int(self.headers.get('Content-Length', '0')))
            self.send_response(202)
            status = 'pending' if Handler.copy_status == 'eventual' else Handler.copy_status
            if status: self.send_header('x-ms-copy-status', status)
            self.send_header('x-ms-copy-id', 'fixture-copy')
            self.send_header('Content-Length', '0'); self.end_headers()
        def do_DELETE(self):
            Handler.deletes += 1
            self.send_response(403 if Handler.mode == 'delete-failure' else 202)
            self.send_header('Content-Length', '0'); self.end_headers()
    server = ThreadingHTTPServer(('127.0.0.1', 0), Handler)
    thread = threading.Thread(target=server.serve_forever, daemon=True); thread.start()
    profile = {'id': 'fixture', 'endpointType': 's3Compatible', 'endpointUrl': f'http://127.0.0.1:{server.server_port}',
               'region': 'us-east-1', 'accessKey': 'fixture', 'secretKey': 'fixture', 'pathStyle': True,
               'verifyTls': False, 'maxAttempts': 1, 'connectTimeoutSeconds': 2, 'readTimeoutSeconds': 3}
    try: yield profile, Handler
    finally: server.shutdown(); server.server_close(); thread.join()


def download(engine, profile, directory, keys, threshold=32):
    engine.send({'requestId': 'safe-download', 'method': 'startDownload', 'params':{'profile': profile, 'bucketName': 'fixture', 'keys': keys,
        'destinationPath': str(directory), 'multipartThresholdMiB': threshold, 'multipartChunkMiB': 1}})
    while True:
        response = engine.recv_json(timeout=20)
        if response.get('requestId') == 'safe-download': return response


def failed(response):
    return not response['ok'] or response.get('result', {}).get('status') in ('failed', 'error', 'cancelled')


def test_download_keeps_both_names_and_existing_bytes(engine, download_server, tmp_path):
    profile, _ = download_server
    (tmp_path / 'report.txt').write_bytes(b'LOCAL')
    result = download(engine, profile, tmp_path, ['a/report.txt', 'b/report.txt', 'empty.txt'])
    assert result['ok'], result
    assert result['result']['status'] == 'completed', result
    assert (tmp_path / 'report.txt').read_bytes() == b'LOCAL'
    assert sorted(p.read_bytes() for p in tmp_path.iterdir()) == [b'', b'FIRST', b'LOCAL', b'SECOND']
    assert not list(tmp_path.glob('*.part'))


def test_failed_download_preserves_existing_destination(engine, download_server, tmp_path):
    profile, handler = download_server; handler.mode = 'failure'
    (tmp_path / 'existing.txt').write_bytes(b'LOCAL')
    assert failed(download(engine, profile, tmp_path, ['existing.txt']))
    assert [p.name for p in tmp_path.iterdir()] == ['existing.txt']
    assert (tmp_path / 'existing.txt').read_bytes() == b'LOCAL'


@pytest.mark.parametrize('mode', ['short', 'oversized', 'ignored', 'wrong-range'])
def test_bad_range_is_not_published(engine, download_server, tmp_path, mode):
    profile, handler = download_server; handler.mode = mode
    result = download(engine, profile, tmp_path, ['range.bin'], threshold=1)
    assert failed(result), result
    assert list(tmp_path.iterdir()) == []


def test_valid_range_is_published(engine, download_server, tmp_path):
    profile, _ = download_server
    result = download(engine, profile, tmp_path, ['range.bin'], threshold=1)
    assert result['ok'], result
    assert result['result']['status'] == 'completed', result
    assert (tmp_path / 'range.bin').read_bytes() == b'x' * (1024 * 1024)


@pytest.mark.parametrize('status', ['pending', '', 'failed', 'aborted', 'eventual', 'success'])
def test_azure_move_requires_confirmed_copy(engine, download_server, status):
    name = str(engine.request('health')['result'].get('engine', '')).lower()
    if 'python' not in name and 'go' not in name: pytest.skip('Azure unsupported')
    profile, handler = download_server; handler.copy_status = status
    result = engine.request('moveObject', params={'profile': {**profile, 'endpointType': 'azureBlob', 'secretKey': 'Zml4dHVyZQ=='},
        'sourceBucketName': 'source', 'sourceKey': 'important.txt', 'destinationBucketName': 'dest', 'destinationKey': 'important.txt'})
    assert result['ok'] == (status in ('eventual', 'success')), result
    assert handler.deletes == (1 if status in ('eventual', 'success') else 0)


@pytest.mark.parametrize('mode', ['identity', 'delete-failure'])
def test_azure_move_conflicts_are_not_success(engine, download_server, mode):
    name = str(engine.request('health')['result'].get('engine', '')).lower()
    if 'python' not in name and 'go' not in name: pytest.skip('Azure unsupported')
    profile, handler = download_server
    handler.copy_status = 'eventual'
    if mode == 'identity': handler.copy_id = 'different-copy'
    else: handler.mode = mode
    result = engine.request('moveObject', params={'profile': {**profile, 'endpointType': 'azureBlob', 'secretKey': 'Zml4dHVyZQ=='},
        'sourceBucketName': 'source', 'sourceKey': 'important.txt', 'destinationBucketName': 'dest', 'destinationKey': 'important.txt'})
    assert not result['ok'], result
    assert handler.deletes == (0 if mode == 'identity' else 1)


@pytest.mark.parametrize('mode', ['valid', 'failure', 'short'])
def test_replacement_is_published_only_after_validation(engine, download_server, tmp_path, mode):
    profile, handler = download_server; handler.mode = mode
    target = tmp_path / 'existing.txt'; target.write_bytes(b'LOCAL')
    engine.send({'requestId': 'replace', 'method': 'startDownload', 'params': {
        'profile': profile, 'bucketName': 'fixture', 'keys': ['existing.txt'],
        'destinationPath': str(tmp_path), 'multipartThresholdMiB': 32, 'multipartChunkMiB': 1,
        'conflictPolicy': 'replace'}})
    while True:
        response = engine.recv_json(timeout=20)
        if response.get('requestId') == 'replace': break
    if mode == 'valid':
        assert response['ok'], response
        assert target.read_bytes() == b'NEW'
    else:
        assert failed(response), response
        assert target.read_bytes() == b'LOCAL'
    assert [p.name for p in tmp_path.iterdir()] == ['existing.txt']


def test_download_does_not_follow_existing_symlink(engine, download_server, tmp_path):
    profile, _ = download_server
    outside = tmp_path / 'outside'; outside.write_bytes(b'ORIGINAL')
    destination = tmp_path / 'downloads'; destination.mkdir()
    try: (destination / 'existing.txt').symlink_to(outside)
    except OSError: pytest.skip('Symlinks unavailable on this host')
    response = download(engine, profile, destination, ['existing.txt'])
    assert response['ok'], response
    assert outside.read_bytes() == b'ORIGINAL'
    assert (destination / 'existing (1).txt').read_bytes() == b'NEW'


def test_azure_move_to_itself_never_deletes(engine, download_server):
    name = str(engine.request('health')['result'].get('engine', '')).lower()
    if 'python' not in name and 'go' not in name: pytest.skip('Azure unsupported')
    profile, handler = download_server
    response = engine.request('moveObject', params={'profile': {**profile, 'endpointType': 'azureBlob', 'secretKey': 'Zml4dHVyZQ=='},
        'sourceBucketName': 'source', 'sourceKey': 'important.txt', 'destinationBucketName': 'source', 'destinationKey': 'important.txt'})
    assert not response['ok'], response
    assert handler.deletes == 0


@pytest.mark.parametrize('mode', ['valid', 'short', 'wrong-range', 'ignored'])
def test_azure_download_validates_before_publishing(engine, download_server, tmp_path, mode):
    name = str(engine.request('health')['result'].get('engine', '')).lower()
    if 'python' not in name and 'go' not in name: pytest.skip('Azure unsupported')
    profile, handler = download_server; handler.mode = mode
    profile = {**profile, 'endpointType': 'azureBlob', 'secretKey': 'Zml4dHVyZQ=='}
    response = download(engine, profile, tmp_path, ['range.bin'], threshold=1)
    if mode == 'valid':
        assert response['ok'], response
        assert (tmp_path / 'range.bin').read_bytes() == b'x' * (1024 * 1024)
    else:
        assert failed(response), response
        assert list(tmp_path.iterdir()) == []


@pytest.mark.parametrize("chunk_mib", [2048, 4096, 5120])
def test_large_part_setting_does_not_overflow_small_download(engine, download_server, tmp_path, chunk_mib):
    profile, _ = download_server
    engine.send({'requestId': 'large-part-setting', 'method': 'startDownload', 'params': {
        'profile': profile, 'bucketName': 'fixture', 'keys': ['existing.txt'],
        'destinationPath': str(tmp_path), 'multipartThresholdMiB': 32, 'multipartChunkMiB': chunk_mib}})
    while True:
        response = engine.recv_json(timeout=20)
        if response.get('requestId') == 'large-part-setting': break
    assert response['ok'], response
    assert (tmp_path / 'existing.txt').read_bytes() == b'NEW'
