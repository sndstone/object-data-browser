"""Transfer safety regressions with disposable files and isolated SDK fakes."""
import importlib.util
import io
import sys
from concurrent.futures import Future
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import Mock

import pytest


@pytest.fixture
def pyengine(monkeypatch):
    path = Path(__file__).parents[2] / 'engines/python/src/main.py'
    spec = importlib.util.spec_from_file_location('transfer_test_engine', path)
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    module._original_emit_transfer_event = module._emit_transfer_event
    monkeypatch.setattr(module, '_emit_transfer_event', lambda _: None)
    yield module
    sys.modules.pop(spec.name, None)


@pytest.fixture
def profile():
    return {'endpointType': 's3Compatible', 'endpointUrl': 'https://fixture.invalid',
            'accessKey': 'fixture', 'secretKey': 'fixture', 'maxConcurrentRequests': 1}


def upload_params(profile, paths, chunk=5):
    return {'profile': profile, 'bucketName': 'fixture', 'filePaths': [str(p) for p in paths],
            'multipartThresholdMiB': 1, 'multipartChunkMiB': chunk}


def sparse_file(path, size):
    with path.open('wb') as output:
        output.truncate(size)
    return path


@pytest.mark.parametrize('chunk,expected', [(0, 5), (1, 5), (4, 5), (5, 5), (8, 8), (5120, 5120), (5121, 5120)])
def test_upload_clamps_s3_part_size_and_allows_small_final_part(pyengine, monkeypatch, profile, tmp_path, chunk, expected):
    source = sparse_file(tmp_path / 'source.bin', 11 * 1024**2)
    client = Mock()
    client.create_multipart_upload.return_value = {'UploadId': 'fixture-upload'}
    client.upload_part.side_effect = lambda **kw: {'ETag': f'"part-{kw["PartNumber"]}"'}
    monkeypatch.setattr(pyengine, '_build_client', lambda _: client)
    result = pyengine._run_transfer(pyengine._start_upload, upload_params(profile, [source], chunk))
    assert result['status'] == 'completed'
    assert result['partSizeBytes'] == expected * 1024**2
    calls = sorted(client.upload_part.call_args_list, key=lambda call: call.kwargs['PartNumber'])
    assert [len(call.kwargs['Body']) for call in calls] == [
        min(expected * 1024**2, 11 * 1024**2 - offset)
        for offset in range(0, 11 * 1024**2, expected * 1024**2)]
    assert all(call.kwargs['Body'].handle.closed for call in calls)
    assert client.complete_multipart_upload.call_args.kwargs['MultipartUpload']['Parts'] == [
        {'PartNumber': index + 1, 'ETag': f'"part-{index + 1}"'} for index in range(len(calls))]
    client.abort_multipart_upload.assert_not_called()


@pytest.mark.parametrize('size,chunk,allowed', [
    (5 * 1024**2 * 10000, 5, True),
    (5 * 1024**2 * 10000 + 1, 5, False),
    (50000 * 1024**3, 5120, True),
    (50000 * 1024**3 + 1, 5120, False),
])
def test_upload_validates_s3_limits_before_client_creation(pyengine, monkeypatch, profile, size, chunk, allowed):
    class Validated(Exception):
        pass
    monkeypatch.setattr(Path, 'stat', lambda _: SimpleNamespace(st_size=size))
    client_factory = Mock(side_effect=Validated)
    monkeypatch.setattr(pyengine, '_build_client', client_factory)
    if allowed:
        with pytest.raises(Validated):
            pyengine._start_upload(upload_params(profile, [Path('fixture.bin')], chunk))
        client_factory.assert_called_once()
    else:
        with pytest.raises(pyengine.SidecarError) as error:
            pyengine._start_upload(upload_params(profile, [Path('fixture.bin')], chunk))
        assert error.value.code == 'invalid_config'
        client_factory.assert_not_called()


class ImmediatePool:
    """Deterministic completed futures; counts submissions without worker races."""
    def __init__(self, **_):
        self.submitted = 0
    def __enter__(self):
        return self
    def __exit__(self, *_):
        pass
    def submit(self, function, item):
        self.submitted += 1
        future = Future()
        try:
            future.set_result(function(item))
        except BaseException as error:
            future.set_exception(error)
        return future


def test_upload_failure_bounds_pending_parts_aborts_and_stops_queued_files(pyengine, monkeypatch, profile, tmp_path):
    source = sparse_file(tmp_path / 'source.bin', 31 * 1024**2)
    queued = sparse_file(tmp_path / 'queued.bin', 1)
    client = Mock()
    client.create_multipart_upload.return_value = {'UploadId': 'fixture-upload'}
    client.upload_part.side_effect = RuntimeError('injected part failure')
    monkeypatch.setattr(pyengine, '_build_client', lambda _: client)
    pool = ImmediatePool()
    monkeypatch.setattr(pyengine, 'ThreadPoolExecutor', lambda **_: pool)
    with pytest.raises(RuntimeError, match='injected part failure'):
        pyengine._run_transfer(pyengine._start_upload, upload_params(profile, [source, queued]))
    assert pool.submitted <= 2  # One worker and at most two pending requests.
    assert client.upload_part.call_count <= 2
    assert all(call.kwargs['Body'].handle.closed for call in client.upload_part.call_args_list)
    client.abort_multipart_upload.assert_called_once_with(Bucket='fixture', Key='source.bin', UploadId='fixture-upload')
    client.complete_multipart_upload.assert_not_called()
    client.put_object.assert_not_called()
    assert not pyengine._TRANSFER_REGISTRY


def test_upload_completion_failure_aborts_and_preserves_original_error(pyengine, monkeypatch, profile, tmp_path):
    source = sparse_file(tmp_path / 'source.bin', 1024**2)
    client = Mock()
    client.create_multipart_upload.return_value = {'UploadId': 'fixture-upload'}
    client.upload_part.return_value = {'ETag': '"part"'}
    client.complete_multipart_upload.side_effect = RuntimeError('completion failed')
    client.abort_multipart_upload.side_effect = RuntimeError('abort failed')
    monkeypatch.setattr(pyengine, '_build_client', lambda _: client)
    with pytest.raises(RuntimeError, match='completion failed'):
        pyengine._run_transfer(pyengine._start_upload, upload_params(profile, [source]))
    client.abort_multipart_upload.assert_called_once()
    assert not pyengine._TRANSFER_REGISTRY


@pytest.mark.parametrize('provider,direction', [('s3', 'upload'), ('s3', 'download'), ('azure', 'upload'), ('azure', 'download')])
def test_queued_event_job_is_immediately_cancellable(pyengine, monkeypatch, profile, tmp_path, provider, direction):
    client = Mock()
    client.head_object.return_value = {'ContentLength': 1024**2, 'ETag': '"fixture"'}
    client.request.return_value = (200, {'Content-Length': str(1024**2), 'ETag': '"fixture"'}, b'')
    monkeypatch.setattr(pyengine, '_build_client', lambda _: client)
    monkeypatch.setattr(pyengine, '_build_azure_client', lambda _: client)
    acknowledged = []
    def cancel_queued(job):
        assert job['status'] == 'queued'
        response = pyengine._transfer_control({'jobId': job['id']}, 'cancelled')
        acknowledged.append(response['status'])
    monkeypatch.setattr(pyengine, '_emit_transfer_event', cancel_queued)
    if direction == 'upload':
        source = sparse_file(tmp_path / 'source.bin', 1024**2)
        params = upload_params(profile, [source])
    else:
        params = {'profile': profile, 'bucketName': 'fixture', 'keys': ['source.bin'], 'destinationPath': str(tmp_path)}
    function = getattr(pyengine, ('_azure_start_' if provider == 'azure' else '_start_') + direction)
    result = pyengine._run_transfer(function, params)
    assert acknowledged == ['cancelling']
    assert result['status'] == 'cancelled'
    client.get_object.assert_not_called()
    client.put_object.assert_not_called()
    client.create_multipart_upload.assert_not_called()
    client.open.assert_not_called()
    if provider == 'azure':
        assert all(call.args[0] == 'HEAD' for call in client.request.call_args_list)
    assert not pyengine._TRANSFER_REGISTRY
    assert not list(tmp_path.glob('.odb-*.part'))


def test_cancel_after_range_response_closes_body_and_discards_partial(pyengine, monkeypatch, profile, tmp_path):
    client = Mock()
    client.head_object.return_value = {'ContentLength': 1024**2, 'ETag': '"fixture"'}
    body = io.BytesIO(b'fixture')
    def get_object(**_):
        control = next(iter(pyengine._TRANSFER_REGISTRY.values()))
        pyengine._transfer_control({'jobId': control.job_id}, 'cancelled')
        return {'Body': body, 'ContentRange': f'bytes 0-{1024**2 - 1}/{1024**2}'}
    client.get_object.side_effect = get_object
    monkeypatch.setattr(pyengine, '_build_client', lambda _: client)
    params = {'profile': profile, 'bucketName': 'fixture', 'keys': ['source.bin'],
              'destinationPath': str(tmp_path), 'multipartThresholdMiB': 1, 'multipartChunkMiB': 1}
    result = pyengine._run_transfer(pyengine._start_download, params)
    assert result['status'] == 'cancelled'
    assert body.closed
    assert list(tmp_path.iterdir()) == []
    assert not pyengine._TRANSFER_REGISTRY


def test_download_many_collisions_scans_directory_once(pyengine, monkeypatch, tmp_path):
    for index in range(1000):
        name = 'REPORT.txt' if index == 0 else f'REPORT ({index}).txt'
        (tmp_path / name).write_bytes(b'LOCAL')
    scans = []
    original_iterdir = Path.iterdir
    def count_scan(path):
        scans.append(path)
        return original_iterdir(path)
    monkeypatch.setattr(Path, 'iterdir', count_scan)
    lines = []
    with pyengine._staged_download(tmp_path, 'folder/report.txt', 'keepBoth', lines) as handle:
        handle.write(b'NEW')
    assert (tmp_path / 'report (1000).txt').read_bytes() == b'NEW'
    assert (tmp_path / 'REPORT.txt').read_bytes() == b'LOCAL'
    assert scans == [tmp_path]
    assert str(tmp_path / 'report (1000).txt') in lines[-1]
    assert not list(tmp_path.glob('.odb-*.part'))


def test_download_concurrent_destination_creation_keeps_both(pyengine, monkeypatch, tmp_path):
    real_link = pyengine._publish_no_replace
    attempts = []
    def competing_link(source, target):
        attempts.append(target)
        if len(attempts) == 1:
            target.write_bytes(b'CONCURRENT')
        real_link(source, target)
    monkeypatch.setattr(pyengine, '_publish_no_replace', competing_link)
    with pyengine._staged_download(tmp_path, 'report.txt', 'keepBoth', []) as handle:
        handle.write(b'NEW')
    assert (tmp_path / 'report.txt').read_bytes() == b'CONCURRENT'
    assert (tmp_path / 'report (1).txt').read_bytes() == b'NEW'
    assert not list(tmp_path.glob('.odb-*.part'))


def test_download_replacement_keeps_case_and_does_not_follow_symlink(pyengine, tmp_path):
    outside = tmp_path / 'outside.txt'
    outside.write_bytes(b'LOCAL')
    directory = tmp_path / 'downloads'
    directory.mkdir()
    target = directory / 'EXISTING.txt'
    try:
        target.symlink_to(outside)
    except OSError:
        pytest.skip('Symlinks unavailable on this host')
    with pyengine._staged_download(directory, 'folder/existing.txt', 'replace', []) as handle:
        handle.write(b'NEW')
    assert outside.read_bytes() == b'LOCAL'
    assert target.read_bytes() == b'NEW'
    assert not target.is_symlink()
    assert sorted(p.name for p in directory.iterdir()) == ['EXISTING.txt']


def test_distinct_versions_of_one_key_remain_distinct_downloads(pyengine, monkeypatch, profile, tmp_path):
    values = {'old': b'OLD', 'new': b'NEW-VERSION'}
    client = Mock()
    client.head_object.side_effect = lambda **kw: {'ContentLength': len(values[kw['VersionId']]), 'ETag': '"' + kw['VersionId'] + '"'}
    client.get_object.side_effect = lambda **kw: {'Body': io.BytesIO(values[kw['VersionId']])}
    monkeypatch.setattr(pyengine, '_build_client', lambda _: client)
    result = pyengine._run_transfer(pyengine._start_download, {'profile': profile, 'bucketName': 'fixture',
        'objects': [{'key': 'same.txt', 'versionId': version} for version in ('old', 'new')],
        'destinationPath': str(tmp_path)})
    assert result['totalBytes'] == result['bytesTransferred'] == 14
    assert result['itemsCompleted'] == 2
    assert (tmp_path / 'same.txt').read_bytes() == b'OLD'
    assert (tmp_path / 'same (1).txt').read_bytes() == b'NEW-VERSION'
    assert [c.kwargs['VersionId'] for c in client.get_object.call_args_list] == ['old', 'new']


def test_changed_upload_source_aborts_before_complete(pyengine, monkeypatch, profile, tmp_path):
    source = sparse_file(tmp_path / 'source.bin', 6 * 1024**2)
    client = Mock()
    client.create_multipart_upload.return_value = {'UploadId': 'upload'}
    def upload(**kw):
        if kw['PartNumber'] == 1:
            with source.open('ab') as output: output.write(b'changed')
        return {'ETag': '"part"'}
    client.upload_part.side_effect = upload
    monkeypatch.setattr(pyengine, '_build_client', lambda _: client)
    with pytest.raises(pyengine.SidecarError, match='source changed'):
        pyengine._run_transfer(pyengine._start_upload, upload_params(profile, [source]))
    client.complete_multipart_upload.assert_not_called()
    client.abort_multipart_upload.assert_called_once()


def test_retry_range_rewrites_offset_and_counts_only_complete_bytes(pyengine, monkeypatch):
    class Broken(io.BytesIO):
        def read(self, count=-1):
            if self.tell() >= 2: raise ConnectionResetError('body interrupted')
            return super().read(min(2, count))
    bodies = [Broken(b'ABCDEF'), io.BytesIO(b'ABCDEF')]
    target = bytearray(6)
    calls = []
    def open_range():
        calls.append('same-etag-and-range')
        return bodies.pop(0), 'bytes 0-5/6'
    def write(offset, data): target[offset:offset+len(data)] = data
    monkeypatch.setattr(pyengine.time, 'sleep', lambda _: None)
    result = pyengine._read_range_with_retry(open_range, write, 0, 5, 6, 2, None)
    assert result == 6 and bytes(target) == b'ABCDEF'
    assert len(calls) == 2


def test_range_disk_errors_and_identity_conflicts_are_not_retried(pyengine):
    calls = []
    def open_range():
        calls.append(1)
        return io.BytesIO(b'abcdef'), 'bytes 0-5/6'
    def disk_error(*_): raise OSError('disk full')
    with pytest.raises(OSError, match='disk full'):
        pyengine._read_range_with_retry(open_range, disk_error, 0, 5, 6, 3, None)
    assert len(calls) == 1
    with pytest.raises(pyengine.SidecarError):
        pyengine._read_range_with_retry(lambda: (io.BytesIO(b'ab'), 'bytes 1-2/6'), lambda *_: None, 0, 5, 6, 3, None)


def test_atomic_publication_does_not_require_hardlinks(pyengine, monkeypatch, tmp_path):
    if pyengine.os.name != 'nt' and pyengine.sys.platform not in {'darwin', 'linux'}:
        pytest.skip('Native no-replace rename unavailable')
    monkeypatch.setattr(pyengine.os, 'link', Mock(side_effect=OSError('hard links unsupported')))
    with pyengine._staged_download(tmp_path, 'native.txt', 'keepBoth', []) as output:
        output.write(b'complete')
    assert (tmp_path / 'native.txt').read_bytes() == b'complete'


def test_incremental_transfer_logs_send_deltas_but_final_result_keeps_history(pyengine, monkeypatch):
    import json
    events = []
    clock = [100.0]
    monkeypatch.setattr(pyengine, '_write_stdout_line', lambda line: events.append(json.loads(line)))
    monkeypatch.setattr(pyengine, '_emit_transfer_event', pyengine._original_emit_transfer_event)
    monkeypatch.setattr(pyengine.time, 'monotonic', lambda: clock[0])
    history = []
    def run(_):
        for index in range(100):
            history.append(str(index))
            clock[0] += .1
            pyengine._emit_transfer_event({'id': 'fixture', 'status': 'running', 'outputLines': history})
        return {'status': 'completed', 'outputLines': history}
    result = pyengine._run_transfer(run, {'incrementalTransferLogs': True, 'progressIntervalMs': 50})
    assert sum(len(event['job']['outputLines']) for event in events) == 100
    assert [event['job']['outputStartLine'] for event in events] == list(range(100))
    assert result['outputLines'] == [str(index) for index in range(100)]
    assert all(event['job']['outputLineCount'] == event['job']['outputStartLine'] + len(event['job']['outputLines']) for event in events)


def test_azure_move_keeps_concurrent_source_replacement(pyengine, monkeypatch, profile):
    client = Mock()
    client.scheme, client.netloc, client.base_path = 'https', 'fixture.invalid', ''
    client.blob_path.side_effect = lambda bucket, key: '/' + bucket + '/' + key
    source = {'etag': '"old"', 'bytes': b'old'}
    requests = []
    def request(method, path, **kwargs):
        requests.append((method, kwargs))
        if method == 'HEAD': return 200, {'ETag': source['etag']}, b''
        if method == 'PUT':
            assert kwargs['headers']['x-ms-source-if-match'] == '"old"'
            source.update(etag='"replacement"', bytes=b'new')
            return 202, {'x-ms-copy-id': 'copy-id', 'x-ms-copy-status': 'success'}, b''
        assert kwargs['headers']['If-Match'] == '"old"'
        if source['etag'] != kwargs['headers']['If-Match']:
            raise pyengine.SidecarError('object_conflict', 'source changed')
        source.clear()
    client.request.side_effect = request
    monkeypatch.setattr(pyengine, '_build_azure_client', lambda _: client)
    with pytest.raises(pyengine.SidecarError, match='source changed'):
        pyengine._azure_move_object({'profile': profile, 'sourceBucketName': 'a', 'sourceKey': 'key',
            'destinationBucketName': 'b', 'destinationKey': 'key'})
    assert source['bytes'] == b'new'
    assert [method for method, _ in requests] == ['HEAD', 'PUT', 'DELETE']


def test_azure_block_dispatch_bounds_pending_futures(pyengine, monkeypatch, profile, tmp_path):
    class CountingFuture(Future):
        consumed = False
        def result(self, *args, **kwargs):
            if not self.consumed:
                self.consumed = True
                pool.pending -= 1
            return super().result(*args, **kwargs)
    class CountingPool(ImmediatePool):
        pending = maximum = 0
        def submit(self, function, item):
            self.submitted += 1
            self.pending += 1
            self.maximum = max(self.maximum, self.pending)
            future = CountingFuture()
            try: future.set_result(function(item))
            except BaseException as error: future.set_exception(error)
            return future
    source = tmp_path / 'source.bin'
    source.write_bytes(b'x' * 200)
    client = Mock()
    client.request.return_value = (200, {}, b'')
    monkeypatch.setattr(pyengine, '_build_azure_client', lambda _: client)
    monkeypatch.setattr(pyengine, '_AZURE_PUT_BLOB_LIMIT', 1)
    monkeypatch.setattr(pyengine, '_azure_block_size', lambda _: 1)
    pool = CountingPool()
    monkeypatch.setattr(pyengine, 'ThreadPoolExecutor', lambda **_: pool)
    result = pyengine._run_transfer(pyengine._azure_start_upload,
        {'profile': profile, 'bucketName': 'fixture', 'filePaths': [str(source)]})
    assert result['bytesTransferred'] == 200 and result['status'] == 'completed'
    assert pool.submitted == 200 and pool.maximum <= 2


def test_azure_duplicate_key_versions_preserve_identity(pyengine, monkeypatch, profile, tmp_path):
    import email.message
    values = {'old': b'OLD', 'new': b'NEW-VERSION'}
    client = Mock()
    client.blob_path.side_effect = lambda bucket, key: f'/{bucket}/{key}'
    def request(method, path, **kwargs):
        version = kwargs['query']['versionid']
        return 200, {'Content-Length': str(len(values[version])), 'ETag': '"' + version + '"'}, b''
    client.request.side_effect = request
    client.open.side_effect = lambda method, path, **kwargs: io.BytesIO(values[kwargs['query']['versionid']])
    monkeypatch.setattr(pyengine, '_build_azure_client', lambda _: client)
    result = pyengine._run_transfer(pyengine._azure_start_download,
        {'profile': profile, 'bucketName': 'fixture', 'destinationPath': str(tmp_path),
         'objects': [{'key': 'same.txt', 'versionId': v} for v in ('old', 'new')]})
    assert result['bytesTransferred'] == result['totalBytes'] == 14
    assert (tmp_path / 'same.txt').read_bytes() == b'OLD'
    assert (tmp_path / 'same (1).txt').read_bytes() == b'NEW-VERSION'


def test_azure_copy_observes_same_copy_beyond_old_poll_budget(pyengine, monkeypatch):
    clock, polls = [0.0], []
    client = Mock()
    class Response(io.BytesIO):
        def __init__(self, status):
            super().__init__(b'')
            self.headers = {'x-ms-copy-id': 'same-copy', 'x-ms-copy-status': status}
    def head(*args, **kwargs):
        polls.append(1)
        return Response('success' if len(polls) == 26 else 'pending')
    client.open.side_effect = head
    monkeypatch.setattr(pyengine.time, 'monotonic', lambda: clock[0])
    monkeypatch.setattr(pyengine.time, 'sleep', lambda seconds: clock.__setitem__(0, clock[0] + seconds))
    pyengine._azure_wait_for_copy(client, '/dest/key', 'pending', 'same-copy', 120)
    assert len(polls) == 26 and clock[0] > 5
    client.request.assert_not_called()


def test_cold_client_creation_does_not_block_unrelated_cached_profile(pyengine, monkeypatch, profile):
    import threading
    warm = pyengine._parse_profile(profile)
    cold = pyengine._parse_profile({**profile, 'secretKey': 'other'})
    cached = object()
    pyengine._CLIENT_CACHE[warm] = cached
    entered, release = threading.Event(), threading.Event()
    result = []
    def create(_):
        entered.set()
        release.wait(2)
        return object()
    monkeypatch.setattr(pyengine, '_new_client', create)
    cold_thread = threading.Thread(target=lambda: pyengine._build_client(cold))
    cold_thread.start()
    assert entered.wait(1)
    warm_thread = threading.Thread(target=lambda: result.append(pyengine._build_client(warm)))
    try:
        warm_thread.start()
        warm_thread.join(.5)
        assert not warm_thread.is_alive() and result == [cached]
    finally:
        release.set()
        warm_thread.join(2)
        cold_thread.join(2)


def test_download_batch_index_avoids_repeated_scans(pyengine, monkeypatch, tmp_path):
    scans = []
    original = Path.iterdir
    def scan(path):
        scans.append(path)
        return original(path)
    monkeypatch.setattr(Path, 'iterdir', scan)
    index = pyengine._DownloadDestination(tmp_path)
    for number in range(256):
        with pyengine._staged_download(tmp_path, f'file-{number}.txt', 'keepBoth', [], index) as handle:
            handle.write(b'COMPLETE')
    if tmp_path.stat().st_mtime_ns % 1_000_000_000:
        assert scans == [tmp_path]
    assert len(list(tmp_path.glob('file-*.txt'))) == 256


@pytest.mark.parametrize('policy,expected', [('keepBoth', 'external (1).txt'), ('replace', 'EXTERNAL.txt')])
def test_download_batch_index_invalidates_external_case_changes(pyengine, tmp_path, policy, expected):
    index = pyengine._DownloadDestination(tmp_path)
    with pyengine._staged_download(tmp_path, 'first.txt', 'keepBoth', [], index) as handle:
        handle.write(b'FIRST')
    existing = tmp_path / 'EXTERNAL.txt'
    existing.write_bytes(b'LOCAL')
    # Explicitly advance the stamp so this also exercises coarse filesystems.
    stamp = tmp_path.stat()
    pyengine.os.utime(tmp_path, ns=(stamp.st_atime_ns, stamp.st_mtime_ns + 2_000_000_001))
    with pyengine._staged_download(tmp_path, 'external.txt', policy, [], index) as handle:
        handle.write(b'COMPLETE')
    assert (tmp_path / expected).read_bytes() == b'COMPLETE'
    if policy == 'keepBoth':
        assert existing.read_bytes() == b'LOCAL'


def test_download_index_notices_external_creation_during_transfer(pyengine, tmp_path):
    index = pyengine._DownloadDestination(tmp_path)
    with pyengine._staged_download(tmp_path, 'during.txt', 'keepBoth', [], index) as handle:
        handle.write(b'COMPLETE')
        (tmp_path / 'DURING.txt').write_bytes(b'LOCAL')
        stamp = tmp_path.stat()
        pyengine.os.utime(tmp_path, ns=(stamp.st_atime_ns, stamp.st_mtime_ns + 2_000_000_001))
    assert (tmp_path / 'DURING.txt').read_bytes() == b'LOCAL'
    assert (tmp_path / 'during (1).txt').read_bytes() == b'COMPLETE'
