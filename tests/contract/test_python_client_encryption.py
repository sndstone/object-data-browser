"""age STREAM vectors and local-only payload transfer regressions."""
import base64
import hashlib
import io
import json
import threading
from collections import Counter
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from types import SimpleNamespace
from urllib.parse import parse_qs, urlparse
from unittest.mock import Mock

import pytest
from cryptography.hazmat.primitives import hashes
from cryptography.hazmat.primitives.ciphers.aead import ChaCha20Poly1305
from cryptography.hazmat.primitives.kdf.hkdf import HKDF

from test_python_encryption import engine as pyengine, profile, request


VECTORS = json.loads((Path(__file__).parents[2] / 'contracts/vectors/age-stream.json').read_text())['cases']


def plaintext(case):
    return bytes((i * 31 + (i >> 8) * 7 + 3) & 255 for i in range(case['plaintextLength']))


def configuration(case, upload=True):
    return {'format': 'age-v1', 'fileKey': case['fileKey'], **(
        {'header': case['header'], 'payloadNonce': case['payloadNonce']} if upload else
        {'headerLength': case['headerLength']})}


def reference_object(case):
    key = HKDF(algorithm=hashes.SHA256(), length=32, salt=base64.b64decode(case['payloadNonce']),
               info=b'payload').derive(base64.b64decode(case['fileKey']))
    cipher, data = ChaCha20Poly1305(key), plaintext(case)
    chunks = [data[i:i + 65536] for i in range(0, len(data), 65536)] or [b'']
    return base64.b64decode(case['header']) + base64.b64decode(case['payloadNonce']) + b''.join(
        cipher.encrypt(i.to_bytes(11, 'big') + bytes([i == len(chunks) - 1]), chunk, None)
        for i, chunk in enumerate(chunks))


def open_object(pyengine, case, data):
    config = pyengine._parse_client_encryption({'clientEncryption': configuration(case, False)}, False, 1)
    output = io.BytesIO()
    def open_range(start, end):
        return io.BytesIO(data[start:end + 1]), f'bytes {start}-{end}/{len(data)}'
    list(pyengine._age_download(output, config, len(data), open_range,
                               SimpleNamespace(max_attempts=1, max_pool_connections=3), None))
    return output.getvalue()


@pytest.mark.parametrize('case', VECTORS, ids=lambda c: str(c['plaintextLength']))
def test_age_vectors(pyengine, tmp_path, case):
    source = tmp_path / 'source'
    source.write_bytes(plaintext(case))
    config = pyengine._parse_client_encryption({'clientEncryption': configuration(case)}, True, 1)
    size = pyengine._age_object_size(config, case['plaintextLength'])
    with source.open('rb') as handle:
        body = pyengine._AgeFilePart(handle, 0, size, None, config, source, pyengine._source_snapshot(source))
        data = b''.join(iter(lambda: body.read(8192), b''))
        assert body.tell() == size
        body.seek(0)
        assert body.read(199) == data[:199]
    assert size == len(data) == case['objectLength']
    assert hashlib.sha256(data).hexdigest() == case['objectSha256']
    assert hashlib.sha256(open_object(pyengine, case, data)).hexdigest() == case['plaintextSha256']
    # Every chunk, including the empty final chunk, authenticates its bytes.
    cipher = pyengine._age_cipher(config['key'], config['nonce'])
    payload = data[case['headerLength'] + 16:]
    chunks = [payload[i:i + 65552] for i in range(0, len(payload), 65552)]
    for index, chunk in enumerate(chunks):
        changed = bytes([chunk[0] ^ 1]) + chunk[1:]
        with pytest.raises(pyengine.SidecarError) as failure:
            pyengine._age_open(cipher, index, index == len(chunks) - 1, changed)
        assert failure.value.code == 'decryption_failed'
        assert failure.value.details == {'chunk': index}


@pytest.mark.parametrize('mutation', ['boundary', 'middle', 'missing-final', 'extra', 'swapped'])
def test_age_rejects_truncation_trailing_and_reordering(pyengine, mutation):
    case = VECTORS[-2]
    data = reference_object(case)
    prefix, payload = data[:case['headerLength'] + 16], data[case['headerLength'] + 16:]
    if mutation == 'boundary': payload = payload[:2 * 65552]
    if mutation == 'middle': payload = payload[:-5]
    if mutation == 'missing-final': payload = payload[:65552]
    if mutation == 'extra': payload += b'x' * 65552
    if mutation == 'swapped': payload = payload[65552:2 * 65552] + payload[:65552] + payload[2 * 65552:]
    with pytest.raises(pyengine.SidecarError) as failure:
        open_object(pyengine, case, prefix + payload)
    assert failure.value.code == 'decryption_failed'
    assert isinstance(failure.value.details['chunk'], int)


@pytest.mark.parametrize('length', [0, 183, 184, 199, 184 + 65552 + 1, 184 + 65552 + 16])
def test_age_impossible_lengths(pyengine, length):
    config = {'headerLength': 168}
    with pytest.raises(pyengine.SidecarError) as failure:
        pyengine._age_plaintext_size(config, length)
    assert failure.value.code == 'decryption_failed'


@pytest.mark.parametrize('upload', [True, False])
@pytest.mark.parametrize('change', ['count', 'format', 'key', 'bad-base64', 'nonce', 'header', 'header-length', 'extra-field'])
def test_age_invalid_configuration(pyengine, upload, change):
    config, count = configuration(VECTORS[1], upload), 1
    if change == 'count': count = 2
    elif change == 'format': config['format'] = 'other'
    elif change == 'key': config['fileKey'] = base64.b64encode(b'x' * 32).decode()
    elif change == 'bad-base64': config['fileKey'] = '!'
    elif change == 'nonce': config['payloadNonce'] = base64.b64encode(b'x').decode()
    elif change == 'header': config['header'] = base64.b64encode(b'x' * 65537).decode()
    elif change == 'header-length': config['headerLength'] = True
    else: config['unexpected'] = 'field'
    with pytest.raises(pyengine.SidecarError) as failure:
        pyengine._parse_client_encryption({'clientEncryption': config}, upload, count)
    assert failure.value.code == 'invalid_config'


@pytest.mark.parametrize('azure', [False, True])
@pytest.mark.parametrize('upload', [False, True])
def test_age_multiple_items_rejected_before_storage(pyengine, profile, monkeypatch, azure, upload):
    client = Mock()
    monkeypatch.setattr(pyengine, '_build_azure_client' if azure else '_build_client', lambda _: client)
    params = {'filePaths': ['one', 'two']} if upload else {'keys': ['one', 'two'], 'destinationPath': 'unused'}
    with pytest.raises(pyengine.SidecarError) as failure:
        request(pyengine, 'startUpload' if upload else 'startDownload',
                {**profile, **({'endpointType': 'azureBlob'} if azure else {})}, bucketName='bucket',
                clientEncryption=configuration(VECTORS[1], upload), **params)
    assert failure.value.code == 'invalid_config'
    assert not client.mock_calls


@pytest.mark.parametrize('start,length', [(0, 7), (160, 50), (180, 65560), (65540, 51), (5 * 1024**2, 12345)])
def test_age_random_ciphertext_ranges_and_retry(pyengine, tmp_path, start, length):
    case = VECTORS[-1]
    source = tmp_path / 'source'
    source.write_bytes(plaintext(case))
    expected = reference_object(case)[start:start + length]
    config = pyengine._parse_client_encryption({'clientEncryption': configuration(case)}, True, 1)
    reads = []
    with source.open('rb') as handle:
        class Tracked:
            def read(self, amount):
                reads.append((handle.tell(), amount))
                assert amount <= 65536
                return handle.read(amount)
            def seek(self, offset): return handle.seek(offset)
            def fileno(self): return handle.fileno()
        body = pyengine._AgeFilePart(Tracked(), start, length, None, config, source, pyengine._source_snapshot(source))
        assert len(body.read(length)) == min(length, 65536)
        body.seek(0)
        assert b''.join(iter(lambda: body.read(), b'')) == expected
        body.seek(0)
        assert b''.join(iter(lambda: body.read(), b'')) == expected
    payload_start = case['headerLength'] + 16
    expected_indices = set(range(max(0, start - payload_start) // 65552,
                                 max(0, start + length - 1 - payload_start) // 65552 + 1)) if start + length > payload_start else set()
    assert {offset // 65536 for offset, _ in reads} == expected_indices


def test_age_source_change_during_retry_aborts(pyengine, profile, monkeypatch, tmp_path):
    source = tmp_path / 'source'
    source.write_bytes(b'x' * (5 * 1024**2 + 1))
    client = Mock()
    client.create_multipart_upload.return_value = {'UploadId': 'upload'}
    def upload(**kwargs):
        body = kwargs['Body']
        body.read(4096)
        with source.open('ab') as output: output.write(b'changed')
        body.seek(0)
        body.read(4096)
    client.upload_part.side_effect = upload
    monkeypatch.setattr(pyengine, '_build_client', lambda _: client)
    with pytest.raises(pyengine.SidecarError) as failure:
        request(pyengine, 'startUpload', profile, bucketName='bucket', filePaths=[str(source)],
                multipartThresholdMiB=1, multipartChunkMiB=5, clientEncryption=configuration(VECTORS[0]))
    assert failure.value.code == 'object_conflict'
    client.abort_multipart_upload.assert_called_once()
    client.complete_multipart_upload.assert_not_called()


@pytest.fixture
def cipher_server():
    class Handler(BaseHTTPRequestHandler):
        data = b''
        parts = {}
        calls = []
        attempts = Counter()
        delivered = []
        second_part = threading.Event()
        aborted = False
        retry = True
        failed_range = False
        def log_message(self, *_): pass
        def respond(self, data=b'', status=200, headers=None, head=False):
            self.send_response(status)
            for name, value in (headers or {}).items(): self.send_header(name, value)
            self.send_header('Content-Length', str(len(data)))
            self.send_header('ETag', '"fixture-v1"')
            self.end_headers()
            if not head: self.wfile.write(data)
        def record(self, body=b''):
            Handler.calls.append((self.command, self.path, dict(self.headers), body))
        def do_HEAD(self):
            self.record()
            self.respond(Handler.data, head=True)
        def do_GET(self):
            self.record()
            assert self.headers.get('If-Match') == '"fixture-v1"'
            start, end = map(int, self.headers['Range'][6:].split('-'))
            span = (start, end)
            Handler.attempts[span] += 1
            if Handler.retry and start > 184 and not Handler.failed_range:
                Handler.failed_range = True
                self.respond(b'<Error><Code>SlowDown</Code></Error>', 503)
                return
            self.respond(Handler.data[start:end + 1], 206,
                         {'Content-Range': f'bytes {start}-{end}/{len(Handler.data)}'})
        def do_POST(self):
            body = self.rfile.read(int(self.headers.get('Content-Length', 0)))
            self.record(body)
            if 'uploads' in self.path:
                self.respond(b'<InitiateMultipartUploadResult><UploadId>fixture</UploadId></InitiateMultipartUploadResult>')
            else:
                Handler.data = b''.join(Handler.parts[i] for i in sorted(Handler.parts))
                self.respond(b'<CompleteMultipartUploadResult><ETag>"fixture-v1"</ETag></CompleteMultipartUploadResult>')
        def do_PUT(self):
            body = self.rfile.read(int(self.headers.get('Content-Length', 0)))
            self.record(body)
            query = parse_qs(urlparse(self.path).query)
            if 'partNumber' not in query:
                Handler.data = body
                self.respond()
                return
            part = int(query['partNumber'][0])
            Handler.attempts[part] += 1
            if part == 1 and Handler.retry:
                assert Handler.second_part.wait(10)
                if Handler.attempts[part] == 1:
                    self.respond(b'<Error><Code>SlowDown</Code></Error>', 503)
                    return
            Handler.parts[part] = body
            Handler.delivered.append(part)
            if part == 2: Handler.second_part.set()
            self.respond()
        def do_DELETE(self):
            self.record()
            Handler.aborted = True
            self.respond(status=204)
    server = ThreadingHTTPServer(('127.0.0.1', 0), Handler)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    profile = {'endpointType': 's3Compatible', 'endpointUrl': f'http://127.0.0.1:{server.server_port}',
               'region': 'us-east-1', 'accessKey': 'fixture', 'secretKey': 'fixture', 'pathStyle': True,
               'maxConcurrentRequests': 3, 'maxAttempts': 2, 'readTimeoutSeconds': 15,
               'diagnostics': {'enableApiLogging': True, 'enableDebugLogging': True}}
    try: yield profile, Handler
    finally:
        Handler.second_part.set()
        server.shutdown()
        server.server_close()
        thread.join(2)


@pytest.mark.parametrize('multipart', [False, True])
def test_age_loopback_upload_download_and_corruption(pyengine, cipher_server, tmp_path, capsys, multipart):
    profile, storage = cipher_server
    case = VECTORS[-1] if multipart else VECTORS[-2]
    source = tmp_path / 'source'
    source.write_bytes(plaintext(case))
    result = request(pyengine, 'startUpload', profile, bucketName='bucket', filePaths=[str(source)],
                     clientEncryption=configuration(case), encryption={'mode': 'sse-s3'},
                     multipartThresholdMiB=1 if multipart else 32, multipartChunkMiB=5)
    assert result['status'] == 'completed'
    assert result['bytesTransferred'] == result['totalBytes'] == case['objectLength']
    assert storage.data == reference_object(case)
    assert hashlib.sha256(storage.data).hexdigest() == case['objectSha256']
    writes = [c for c in storage.calls if c[0] in {'PUT', 'POST'}]
    assert all(int(c[2]['Content-Length']) == len(c[3]) for c in writes)
    initiation = next(c for c in writes if 'uploads' in c[1]) if multipart else writes[0]
    assert initiation[2]['x-amz-server-side-encryption'] == 'AES256'
    if multipart:
        assert storage.delivered.index(2) < storage.delivered.index(1)
        assert storage.attempts[1] == 2
        attempts = [c[3] for c in writes if 'partNumber=1' in c[1]]
        assert len(attempts) == 2 and attempts[0] == attempts[1]
        assert [len(storage.parts[i]) for i in sorted(storage.parts)][:-1] == [5 * 1024**2] * 2
    directory = tmp_path / 'downloads'
    directory.mkdir()
    (directory / 'source').write_bytes(b'existing')
    download = dict(bucketName='bucket', keys=['source'], destinationPath=str(directory),
                    clientEncryption=configuration(case, False), multipartThresholdMiB=1, multipartChunkMiB=1)
    result = request(pyengine, 'startDownload', profile, **download)
    assert result['status'] == 'completed'
    assert (directory / 'source (1)').read_bytes() == plaintext(case)
    assert (directory / 'source').read_bytes() == b'existing'
    assert all('Range' in c[2] and 'If-Match' in c[2] for c in storage.calls if c[0] == 'GET')
    storage.data = storage.data[:185] + bytes([storage.data[185] ^ 1]) + storage.data[186:]
    before = {p.name: p.read_bytes() for p in directory.iterdir()}
    with pytest.raises(pyengine.SidecarError) as failure:
        request(pyengine, 'startDownload', profile, conflictPolicy='replace', **download)
    assert failure.value.code == 'decryption_failed'
    assert failure.value.details == {'chunk': 0}
    assert {p.name: p.read_bytes() for p in directory.iterdir()} == before
    captured = capsys.readouterr()
    assert case['fileKey'] not in captured.out + captured.err + json.dumps(result) + str(failure.value)


class MemoryStorage:
    """The same wire boundaries as loopback, without requiring a socket bind."""
    def __init__(self, multipart=False):
        self.data, self.calls, self.parts = b'', [], {}
        self.multipart = multipart
        self.second_part = threading.Event()
        self.failed_part = self.failed_range = False
        self.delivered = []
        self.aborted = False

    def exchange(self, method, url, headers, body=b''):
        from botocore.exceptions import ReadTimeoutError
        query = parse_qs(urlparse(url).query, keep_blank_values=True)
        data = body if isinstance(body, bytes) else b''.join(iter(lambda: body.read(65536), b''))
        self.calls.append((method, url, headers, data))
        result, response_headers = b'', {'ETag': '"fixture-v1"'}
        if method == 'HEAD':
            response_headers['Content-Length'] = str(len(self.data))
        elif method == 'GET':
            assert headers['if-match'] == '"fixture-v1"'
            start, end = map(int, headers['range'][6:].split('-')) if 'range' in headers else (0, len(self.data) - 1)
            result = self.data[start:end + 1]
            response_headers['Content-Range'] = f'bytes {start}-{end}/{len(self.data)}'
        elif 'uploads' in query:
            result = b'<InitiateMultipartUploadResult><UploadId>fixture</UploadId></InitiateMultipartUploadResult>'
        elif method == 'POST' and 'uploadId' in query:
            self.data = b''.join(self.parts[i] for i in sorted(self.parts))
            result = b'<CompleteMultipartUploadResult><ETag>"fixture-v1"</ETag></CompleteMultipartUploadResult>'
        elif method == 'PUT' and ('partNumber' in query or query.get('comp') == ['block']):
            part = int(query['partNumber'][0]) if 'partNumber' in query else int(base64.b64decode(query['blockid'][0]).decode().split('-')[-1]) + 1
            if self.multipart and part == 1:
                assert self.second_part.wait(10)
                if 'partNumber' in query and not self.failed_part:
                    self.failed_part = True
                    raise ReadTimeoutError(endpoint_url=url)
                if 'partNumber' not in query:
                    body.seek(0)
                    assert b''.join(iter(lambda: body.read(65536), b'')) == data
            self.parts[part] = data
            self.delivered.append(part)
            if part == 2: self.second_part.set()
        elif query.get('comp') == ['blocklist']:
            self.data = b''.join(self.parts[i] for i in sorted(self.parts))
        elif method == 'PUT': self.data = data
        elif method == 'DELETE': self.aborted = True
        response_headers.setdefault('Content-Length', str(len(result)))
        return 206 if method == 'GET' and 'range' in headers else 200, response_headers, result

    def connect(self, pyengine, profile, monkeypatch, azure=False):
        from botocore.awsrequest import AWSResponse
        from urllib3 import HTTPResponse
        from test_python_encryption import Raw
        profile = {**profile, 'maxConcurrentRequests': 3, 'maxAttempts': 2,
                   **({'endpointType': 'azureBlob'} if azure else {})}
        def response(method, url, headers, body):
            headers = {k.lower(): v.decode() if isinstance(v, bytes) else str(v) for k, v in headers.items()}
            return self.exchange(method, url, headers, body)
        if azure:
            client = pyengine._build_azure_client(pyengine._parse_profile(profile))
            def send(method, url, **kwargs):
                status, headers, data = response(method, url, kwargs['headers'], kwargs.get('body') or b'')
                return HTTPResponse(status=status, headers=headers, body=io.BytesIO(data), preload_content=False)
            monkeypatch.setattr(client.pool, 'request', send)
        else:
            client = pyengine._build_client(pyengine._parse_profile(profile))
            def send(req):
                status, headers, data = response(req.method, req.url, req.headers, req.body or b'')
                return AWSResponse(req.url, status, headers, Raw(data))
            monkeypatch.setattr(client._endpoint.http_session, 'send', send)
        return profile


@pytest.mark.parametrize('azure', [False, True])
@pytest.mark.parametrize('multipart', [False, True])
def test_age_signed_transport_roundtrip(pyengine, profile, monkeypatch, tmp_path, capsys, azure, multipart):
    storage = MemoryStorage(multipart)
    profile = storage.connect(pyengine, profile, monkeypatch, azure)
    monkeypatch.setattr(pyengine, '_AZURE_PUT_BLOB_LIMIT', 1 if multipart else 100000000)
    monkeypatch.setattr(pyengine, '_azure_block_size', lambda _: 5 * 1024**2)
    case = VECTORS[-1] if multipart else VECTORS[-2]
    source = tmp_path / 'source'
    source.write_bytes(plaintext(case))
    mode = {'mode': 'azure-scope', 'encryptionScope': 'fixture'} if azure else {'mode': 'sse-s3'}
    uploaded = request(pyengine, 'startUpload', profile, bucketName='bucket', filePaths=[str(source)],
                       clientEncryption=configuration(case), encryption=mode,
                       multipartThresholdMiB=1 if multipart else 32, multipartChunkMiB=5)
    assert uploaded['status'] == 'completed'
    assert storage.data == reference_object(case)
    assert hashlib.sha256(storage.data).hexdigest() == case['objectSha256']
    assert uploaded['totalBytes'] == uploaded['bytesTransferred'] == len(storage.data)
    if multipart:
        assert storage.delivered.index(2) < storage.delivered.index(1)
        assert [len(storage.parts[i]) for i in sorted(storage.parts)][:-1] == [5 * 1024**2] * 2
        if not azure:
            assert storage.failed_part
            attempts = [c[3] for c in storage.calls if 'partNumber=1' in c[1]]
            assert len(attempts) == 2 and attempts[0] == attempts[1]
    puts = [c for c in storage.calls if c[0] == 'PUT']
    assert all(int(c[2]['content-length']) == len(c[3]) for c in puts)
    assert any('x-ms-encryption-scope' in c[2] if azure else 'x-amz-server-side-encryption' in c[2] for c in storage.calls)
    directory = tmp_path / 'downloads'
    params = dict(bucketName='bucket', keys=['source'], destinationPath=str(directory),
                  clientEncryption=configuration(case, False))
    result = request(pyengine, 'startDownload', profile, **params)
    assert result['status'] == 'completed'
    assert result['totalBytes'] == result['bytesTransferred'] == len(storage.data)
    assert (directory / 'source').read_bytes() == plaintext(case)
    # Atomic replacement follows the same path and publishes authenticated plaintext.
    request(pyengine, 'startDownload', profile, conflictPolicy='replace', **params)
    assert sorted(p.name for p in directory.iterdir()) == ['source']
    storage.data = storage.data[:185] + bytes([storage.data[185] ^ 1]) + storage.data[186:]
    with pytest.raises(pyengine.SidecarError) as failure:
        request(pyengine, 'startDownload', profile, conflictPolicy='replace', **params)
    assert failure.value.code == 'decryption_failed'
    assert failure.value.details == {'chunk': 0}
    assert sorted(p.name for p in directory.iterdir()) == ['source']
    assert (directory / 'source').read_bytes() == plaintext(case)
    captured = capsys.readouterr()
    assert case['fileKey'] not in captured.out + captured.err + json.dumps(result) + str(failure.value)


@pytest.mark.parametrize('azure', [False, True])
@pytest.mark.parametrize('key,name', [
    ('folder/report.pdf.age', 'report.pdf'),
    ('folder/.age', '.age'),
    ('folder/notes', 'notes'),
    ('folder/a.age.age', 'a.age'),
])
def test_age_download_publishes_plaintext_name(pyengine, profile, monkeypatch, tmp_path, azure, key, name):
    storage = MemoryStorage()
    profile = storage.connect(pyengine, profile, monkeypatch, azure)
    case = VECTORS[1]
    storage.data = reference_object(case)
    result = request(pyengine, 'startDownload', profile, bucketName='bucket', keys=[key],
                     destinationPath=str(tmp_path), clientEncryption=configuration(case, False))
    assert result['status'] == 'completed'
    assert sorted(p.name for p in tmp_path.iterdir()) == [name]
    assert (tmp_path / name).read_bytes() == plaintext(case)
    assert f'Saved {key} to {tmp_path / name}.' in result['outputLines']
    assert f'Downloading {key} ({len(storage.data)} bytes) to {tmp_path / name}.' in result['outputLines']


@pytest.mark.parametrize('azure', [False, True])
@pytest.mark.parametrize('policy,name', [('keepBoth', 'report (1).pdf'), ('replace', 'report.pdf')])
def test_age_download_collision_uses_plaintext_name(pyengine, profile, monkeypatch, tmp_path, azure, policy, name):
    storage = MemoryStorage()
    profile = storage.connect(pyengine, profile, monkeypatch, azure)
    case = VECTORS[1]
    storage.data = reference_object(case)
    existing = tmp_path / 'report.pdf'
    existing.write_bytes(b'existing')
    result = request(pyengine, 'startDownload', profile, bucketName='bucket', keys=['folder/report.pdf.age'],
                     destinationPath=str(tmp_path), clientEncryption=configuration(case, False),
                     conflictPolicy=policy)
    assert result['status'] == 'completed'
    assert (tmp_path / name).read_bytes() == plaintext(case)
    assert sorted(p.name for p in tmp_path.iterdir()) == sorted({'report.pdf', name})
    if policy == 'keepBoth': assert existing.read_bytes() == b'existing'
    assert f'Saved folder/report.pdf.age to {tmp_path / name}.' in result['outputLines']


@pytest.mark.parametrize('azure', [False, True])
def test_age_suffix_without_client_encryption_keeps_name(pyengine, profile, monkeypatch, tmp_path, azure):
    storage = MemoryStorage()
    profile = storage.connect(pyengine, profile, monkeypatch, azure)
    storage.data = b'ordinary payload'
    result = request(pyengine, 'startDownload', profile, bucketName='bucket', keys=['folder/report.pdf.age'],
                     destinationPath=str(tmp_path))
    assert result['status'] == 'completed'
    assert sorted(p.name for p in tmp_path.iterdir()) == ['report.pdf.age']
    assert (tmp_path / 'report.pdf.age').read_bytes() == storage.data
    assert f'Saved folder/report.pdf.age to {tmp_path / "report.pdf.age"}.' in result['outputLines']


@pytest.mark.parametrize('azure', [False, True])
def test_age_default_off_preserves_wire_and_plaintext(pyengine, profile, monkeypatch, tmp_path, azure):
    storage = MemoryStorage()
    profile = storage.connect(pyengine, profile, monkeypatch, azure)
    source = tmp_path / 'source'
    source.write_bytes(b'ordinary unencrypted payload\x00\xff')
    # Absent and explicit-null requests preserve the original single PUT/GET path.
    transcripts = []
    for index, options in enumerate(({}, {'clientEncryption': None})):
        storage.calls.clear()
        request(pyengine, 'startUpload', profile, bucketName='bucket', filePaths=[str(source)], **options)
        assert storage.data == source.read_bytes()
        directory = tmp_path / f'downloads-{index}'
        result = request(pyengine, 'startDownload', profile, bucketName='bucket', keys=['source'],
                         destinationPath=str(directory), **options)
        assert (directory / 'source').read_bytes() == source.read_bytes()
        assert result['totalBytes'] == result['bytesTransferred'] == len(source.read_bytes())
        # Signing timestamps/authorization and SDK invocation IDs are request-specific.
        transcripts.append([(method, url, {k: v for k, v in headers.items() if k not in {
            'authorization', 'x-amz-date', 'x-ms-date', 'amz-sdk-invocation-id'}}, data)
            for method, url, headers, data in storage.calls])
    assert transcripts[0] == transcripts[1]
    assert [c[0] for c in storage.calls] == ['PUT', 'HEAD', 'GET']
    assert all('range' not in c[2] for c in storage.calls)


def test_age_capability(pyengine):
    items = request(pyengine, 'getCapabilities', {})['items']
    item = next(i for i in items if i['key'] == 'object.clientEncryption')
    assert item['state'] == 'supported'
    assert item['formats'] == ['age-v1']


def test_age_file_key_redacted_at_output_and_persistence_boundaries(pyengine, tmp_path, capsys, monkeypatch):
    key = VECTORS[-1]['fileKey']
    payload = {'clientEncryption': configuration(VECTORS[-1])}
    with pyengine._customer_key_scope(payload):
        pyengine._emit_structured_log('DEBUG', 'test', f'provider echoed {key}', 'api')
        pyengine._write_stdout_line(json.dumps({'outputLines': [key]}))
        error = pyengine.SidecarError('unknown', f'provider echoed {key}', {'nested': {'fileKey': key, 'text': key}})
        pyengine._recovery_write({'id': 'upload-' + 'a' * 32, 'fileKey': key, 'outputLines': [key]})
        safe = pyengine._safe_diagnostics({'response': payload, 'checkpoint': {'fileKey': key}, 'outputLines': [key]})
        assert key not in json.dumps(safe) + str(error) + json.dumps(error.details)
        assert key not in pyengine._summarize_http_body('application/json', json.dumps(payload).encode())
        assert key not in json.dumps(pyengine._sanitize_headers({'fileKey': key}))
        monkeypatch.setattr(pyengine, '_handle_request_impl', lambda _: {'outputLines': [key], **payload})
        assert key not in json.dumps(pyengine.handle_request({'params': payload}))
    captured = capsys.readouterr()
    assert key not in captured.out + captured.err
    artifacts = list(tmp_path.rglob('*'))
    assert artifacts
    for path in artifacts:
        if path.is_file(): assert key.encode() not in path.read_bytes()


@pytest.mark.parametrize('limit', ['parts', 'object'])
def test_age_s3_limits_use_ciphertext_length(pyengine, profile, monkeypatch, limit):
    plain_size = 10000 * 5 * 1024**2 if limit == 'parts' else 50000 * 1024**3 - 1
    monkeypatch.setattr(pyengine, '_source_snapshot', lambda _: (0, 0, plain_size, 0, 0))
    client = Mock()
    monkeypatch.setattr(pyengine, '_build_client', lambda _: client)
    with pytest.raises(pyengine.SidecarError) as failure:
        request(pyengine, 'startUpload', profile, bucketName='bucket', filePaths=['unused'],
                clientEncryption=configuration(VECTORS[0]), multipartThresholdMiB=1,
                multipartChunkMiB=5 if limit == 'parts' else 5120)
    assert failure.value.code == 'invalid_config'
    assert not client.mock_calls


def test_age_ciphertext_length_controls_upload_threshold(pyengine, profile, monkeypatch, tmp_path):
    source = tmp_path / 'source'
    source.write_bytes(b'x' * (1024**2 - 1))
    client = Mock()
    client.create_multipart_upload.return_value = {'UploadId': 'upload'}
    lengths = []
    def upload(**kwargs):
        body = kwargs['Body']
        lengths.append(len(body))
        # SDK reads, hashing and retries operate on the ciphertext view.
        assert len(b''.join(iter(lambda: body.read(65536), b''))) == len(body)
        return {'ETag': '"part"'}
    client.upload_part.side_effect = upload
    monkeypatch.setattr(pyengine, '_build_client', lambda _: client)
    result = request(pyengine, 'startUpload', profile, bucketName='bucket', filePaths=[str(source)],
                     clientEncryption=configuration(VECTORS[0]), multipartThresholdMiB=1, multipartChunkMiB=5)
    expected = pyengine._age_object_size({'headerLength': 168}, source.stat().st_size)
    assert result['bytesTransferred'] == result['totalBytes'] == expected
    assert lengths == [expected]
    assert result['partsTotal'] == 1
    client.put_object.assert_not_called()
    client.complete_multipart_upload.assert_called_once()


def test_age_nonce_and_chunk_stream_retries_keep_ranges_and_validators(pyengine):
    case = VECTORS[-2]
    data = reference_object(case)
    config = pyengine._parse_client_encryption({'clientEncryption': configuration(case, False)}, False, 1)
    calls = Counter()
    bodies = []
    class Broken(io.BytesIO):
        def read(self, amount=-1):
            if self.tell() > 0: raise ConnectionResetError('fixture interrupted body')
            return super().read(2)
    def open_range(start, end):
        calls[(start, end)] += 1
        body = (Broken if calls[(start, end)] == 1 else io.BytesIO)(data[start:end + 1])
        bodies.append(body)
        return body, f'bytes {start}-{end}/{len(data)}'
    output = io.BytesIO()
    received = list(pyengine._age_download(output, config, len(data), open_range,
                    SimpleNamespace(max_attempts=2, max_pool_connections=3), None))
    assert output.getvalue() == plaintext(case)
    assert sum(received) == len(data)
    assert set(calls.values()) == {2}
    assert all(body.closed for body in bodies)


@pytest.mark.parametrize('azure', [False, True])
@pytest.mark.parametrize('invalid', ['length', 'range'])
def test_age_invalid_object_or_range_never_publishes(pyengine, profile, monkeypatch, tmp_path, azure, invalid):
    storage = MemoryStorage()
    profile = storage.connect(pyengine, profile, monkeypatch, azure)
    case = VECTORS[1]
    storage.data = b'bad' if invalid == 'length' else reference_object(case)
    original = storage.exchange
    def exchange(*args):
        status, headers, data = original(*args)
        if 'Content-Range' in headers: headers['Content-Range'] = 'bytes 0-1/2'
        return status, headers, data
    if invalid == 'range': monkeypatch.setattr(storage, 'exchange', exchange)
    with pytest.raises(pyengine.SidecarError) as failure:
        request(pyengine, 'startDownload', profile, bucketName='bucket', keys=['source'],
                destinationPath=str(tmp_path), clientEncryption=configuration(case, False))
    assert failure.value.code == ('decryption_failed' if invalid == 'length' else 'object_conflict')
    assert list(tmp_path.iterdir()) == []


@pytest.mark.parametrize('azure', [False, True])
@pytest.mark.parametrize('policy,name', [('keepBoth', 'report (1).pdf'), ('replace', 'report.pdf')])
def test_age_supplied_name_publication(pyengine, profile, monkeypatch, tmp_path, azure, policy, name):
    storage = MemoryStorage()
    profile = storage.connect(pyengine, profile, monkeypatch, azure)
    case = VECTORS[1]
    storage.data = reference_object(case)
    (tmp_path / 'report.pdf').write_bytes(b'existing')
    config = {**configuration(case, False), 'fileName': 'report.pdf'}
    result = request(pyengine, 'startDownload', profile, bucketName='bucket', keys=['token.age'],
                     destinationPath=str(tmp_path), clientEncryption=config, conflictPolicy=policy)
    assert result['status'] == 'completed'
    assert (tmp_path / name).read_bytes() == plaintext(case)
    assert all('report.pdf' not in str(call) for call in storage.calls)


@pytest.mark.parametrize('azure', [False, True])
@pytest.mark.parametrize('name', [None, 1, False, [], {}, '', '.', '..', 'a/b', 'a\\b', 'a\0b'])
def test_age_invalid_file_name_before_network(pyengine, profile, monkeypatch, tmp_path, azure, name):
    storage = MemoryStorage()
    profile = storage.connect(pyengine, profile, monkeypatch, azure)
    with pytest.raises(pyengine.SidecarError) as failure:
        request(pyengine, 'startDownload', profile, bucketName='bucket', keys=['token.age'],
                destinationPath=str(tmp_path), clientEncryption={**configuration(VECTORS[1], False), 'fileName': name})
    assert failure.value.code == 'invalid_config'
    assert not storage.calls


def test_hidden_download_name_redacted(pyengine, tmp_path, capsys):
    name = 'hidden-name-sentinel.pdf'
    payload = {'clientEncryption': {**configuration(VECTORS[0], False), 'fileName': name}}
    with pyengine._customer_key_scope(payload):
        # The field is redacted wherever the request is recorded or echoed.
        assert name not in json.dumps(pyengine._safe_diagnostics({'request': payload}))
        assert name not in pyengine._summarize_http_body('application/json', json.dumps(payload).encode())
        pyengine._write_stdout_line(json.dumps(pyengine._safe_diagnostics({'trace': payload})))
        pyengine._recovery_write({'id': 'upload-' + 'b' * 32, **payload})
        # The value is an ordinary word and the published path contains it, so
        # it is not scrubbed from text. A file called "a" must not shred output.
        assert pyengine._safe_diagnostics({'outputLines': [f'Saved to /tmp/{name}']}) == {'outputLines': [f'Saved to /tmp/{name}']}
    captured = capsys.readouterr()
    assert name not in captured.out + captured.err
    for path in tmp_path.rglob('*'):
        if path.is_file(): assert name.encode() not in path.read_bytes()
