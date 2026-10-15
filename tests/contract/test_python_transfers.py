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
    real_link = pyengine.os.link
    attempts = []
    def competing_link(source, target):
        attempts.append(target)
        if len(attempts) == 1:
            target.write_bytes(b'CONCURRENT')
        real_link(source, target)
    monkeypatch.setattr(pyengine.os, 'link', competing_link)
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
