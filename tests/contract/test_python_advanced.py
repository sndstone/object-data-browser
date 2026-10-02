"""Reference-engine administration tests use isolated fakes, never user endpoints."""
import importlib.util
import io
import json
import sys
import time
from datetime import datetime, timezone
from pathlib import Path
from unittest.mock import Mock

import pytest
from botocore.exceptions import ClientError


@pytest.fixture
def pyengine(monkeypatch, tmp_path):
    path = Path(__file__).parents[2] / 'engines/python/src/main.py'
    spec = importlib.util.spec_from_file_location('advanced_test_engine', path)
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    monkeypatch.setattr(module, '_runtime_dir', lambda: tmp_path)
    monkeypatch.chdir(tmp_path)
    monkeypatch.setattr(module, '_emit_transfer_event', lambda _: None)
    yield module
    for run in module._BENCHMARKS.values():
        with run.lock:
            run.state['status'] = 'stopped'
            run.wake.set()
        for worker in run.threads: worker.join(timeout=2)
    sys.modules.pop(spec.name, None)


@pytest.fixture
def profile():
    return {'id': 'fixture', 'endpointType': 's3Compatible', 'endpointUrl': 'https://fixture.invalid',
            'accessKey': 'SENTINEL-ACCESS', 'secretKey': 'SENTINEL-SECRET', 'sessionToken': 'SENTINEL-TOKEN',
            'pathStyle': True, 'maxAttempts': 2}


def error(code):
    return ClientError({'Error': {'Code': code, 'Message': code}, 'ResponseMetadata': {'HTTPStatusCode': 500}}, 'DeleteObject')


def test_benchmark_runs_without_polling_and_never_persists_credentials(pyengine, profile, monkeypatch, tmp_path):
    client = Mock()
    monkeypatch.setattr(pyengine, '_build_client', lambda _: client)
    state = pyengine._start_benchmark({'profile': profile, 'config': {'bucketName': 'fixture',
        'testMode': 'operation-count', 'operationCount': 20, 'concurrentThreads': 3, 'workloadType': 'write-only',
        'objectSizes': [8], 'outputDirectory': str(tmp_path)}})
    run = pyengine._BENCHMARKS[state['id']]
    deadline = time.monotonic() + 5
    while run.state['status'] == 'running' and time.monotonic() < deadline:
        time.sleep(0.01)
    snapshot = pyengine._get_benchmark_status({'runId': state['id']})
    assert snapshot['status'] == 'completed', snapshot
    assert snapshot['processedCount'] == 20
    calls = client.put_object.call_count
    pyengine._get_benchmark_status({'runId': state['id']})
    assert client.put_object.call_count == calls
    for sentinel in ('SENTINEL-ACCESS', 'SENTINEL-SECRET', 'SENTINEL-TOKEN'):
        assert sentinel not in json.dumps(snapshot)
        for path in tmp_path.rglob('*'):
            if path.is_file(): assert sentinel not in path.read_text()


def test_legacy_benchmark_state_is_sanitized_and_requires_reauthorization(pyengine, profile):
    path = pyengine._benchmark_state_path('bench-legacy')
    path.write_text(json.dumps({'id': 'bench-legacy', 'profile': profile, 'status': 'running'}))
    state = pyengine._get_benchmark_status({'runId': 'bench-legacy'})
    assert state['requiresReauthorization']
    assert state['status'] == 'paused'
    assert 'SENTINEL' not in path.read_text()


@pytest.mark.parametrize('status,eligible', [('', True), ('Enabled', False), ('Suspended', False)])
def test_delete_recovery_preserves_version_boundaries(pyengine, monkeypatch, status, eligible):
    monkeypatch.setattr(pyengine.time, 'sleep', lambda _: None)
    client = Mock()
    client.get_bucket_versioning.return_value = {'Status': status} if status else {}
    client.delete_objects.return_value = {'Errors': [{'Key': 'exact /key ', 'Code': 'InternalError'}]}
    client.delete_object.side_effect = [error('InternalError'), error('InternalError'), {}] if eligible else error('InternalError')
    failures = pyengine._delete_batch_with_recovery(client, 'bucket', [{'Key': 'exact /key ', '_ETag': 'etag'}], eligible, 2)
    assert client.delete_objects.call_count == 2
    assert client.put_object.call_count == int(eligible)
    if eligible:
        assert failures == []
        assert client.put_object.call_args.kwargs == {'Bucket': 'bucket', 'Key': 'exact /key ', 'Body': b'', 'IfMatch': 'etag'}
    else:
        assert failures


def test_delete_recovery_reports_empty_object_left_behind(pyengine, monkeypatch):
    monkeypatch.setattr(pyengine.time, 'sleep', lambda _: None)
    client = Mock()
    client.get_bucket_versioning.return_value = {}
    client.delete_objects.return_value = {'Errors': [{'Key': 'key', 'Code': 'InternalError'}]}
    client.delete_object.side_effect = error('InternalError')
    failures = pyengine._delete_batch_with_recovery(client, 'bucket', [{'Key': 'key'}], True, 1)
    assert 'overwritten with an empty object; delete failed' in failures[0][1]


@pytest.mark.parametrize('code', ['AccessDenied', 'InvalidRequest', 'MethodNotAllowed', 'PreconditionFailed'])
def test_delete_recovery_never_overwrites_permission_or_protection_failures(pyengine, code):
    client = Mock()
    client.delete_objects.return_value = {'Errors': [{'Key': 'key', 'Code': code}]}
    assert pyengine._delete_batch_with_recovery(client, 'bucket', [{'Key': 'key'}], True)
    client.put_object.assert_not_called()
    client.delete_object.assert_not_called()


def test_delete_rechecks_versioning_before_empty_put(pyengine, monkeypatch):
    monkeypatch.setattr(pyengine.time, 'sleep', lambda _: None)
    client = Mock()
    client.get_bucket_versioning.return_value = {'Status': 'Enabled'}
    client.delete_object.side_effect = error('InternalError')
    assert pyengine._recover_delete_entry(client, 'bucket', {'Key': 'key'}, {'Code': 'InternalError'}, True, 1)
    client.put_object.assert_not_called()


def test_exact_version_details_and_presign(pyengine, monkeypatch, profile):
    client = Mock()
    client.head_object.return_value = {'ContentLength': 7, 'Metadata': {}, 'ETag': 'tag'}
    client.get_object_tagging.return_value = {'TagSet': []}
    monkeypatch.setattr(pyengine, '_build_client', lambda _: client)
    params = {'profile': profile, 'bucketName': 'bucket', 'key': ' leading /key ', 'versionId': 'null'}
    pyengine._get_object_details(params)
    assert client.head_object.call_args.kwargs == {'Bucket': 'bucket', 'Key': ' leading /key ', 'VersionId': 'null'}
    pyengine._generate_presigned_url(params)
    assert client.generate_presigned_url.call_args.kwargs['Params']['VersionId'] == 'null'


def test_lifecycle_dates_and_retention_years_survive_inspection(pyengine, monkeypatch, profile):
    client = Mock()
    for operation in ('get_bucket_versioning', 'get_bucket_encryption', 'get_bucket_policy', 'get_bucket_cors', 'get_bucket_tagging'):
        getattr(client, operation).return_value = {}
    rule = {'ID': 'complex', 'Status': 'Enabled', 'Filter': {'And': {'Prefix': 'exact/', 'Tags': [{'Key': 'env', 'Value': 'prod'}], 'ObjectSizeGreaterThan': 128}},
            'Expiration': {'Date': datetime(2030, 1, 1, tzinfo=timezone.utc)},
            'NoncurrentVersionExpiration': {'NoncurrentDays': 90, 'NewerNoncurrentVersions': 5}}
    client.get_bucket_lifecycle_configuration.return_value = {'Rules': [rule], 'TransitionDefaultMinimumObjectSize': 'all_storage_classes_128K'}
    client.get_object_lock_configuration.return_value = {'ObjectLockConfiguration': {'Rule': {'DefaultRetention': {'Years': 7, 'Mode': 'COMPLIANCE'}}}}
    monkeypatch.setattr(pyengine, '_build_client', lambda _: client)
    state = pyengine._get_bucket_admin_state({'profile': profile, 'bucketName': 'bucket'})
    assert state['objectLockRetentionDays'] is None
    assert state['objectLockRetentionYears'] == 7
    assert json.loads(state['lifecycleJson'])['Rules'][0]['Filter'] == rule['Filter']
    assert json.loads(state['lifecycleJson'])['Rules'][0]['NoncurrentVersionExpiration']['NewerNoncurrentVersions'] == 5


def test_cross_endpoint_copy_relays_with_independent_credentials_and_pinned_source(pyengine, monkeypatch, profile):
    source, destination = Mock(), Mock()
    source.head_object.return_value = {'ContentLength': 7, 'ETag': 'source-etag', 'Metadata': {'fixture': 'yes'}}
    source.get_object.return_value = {'Body': io.BytesIO(b'payload')}
    source.get_object_tagging.return_value = {'TagSet': [{'Key': 'env', 'Value': 'fixture'}]}
    destination.put_object.return_value = {'VersionId': 'new-version'}
    destination.head_object.return_value = {'ContentLength': 7}
    monkeypatch.setattr(pyengine, '_build_client', lambda p: source if p.endpoint_url == profile['endpointUrl'] else destination)
    result = pyengine._storage_copy({'sourceProfile': profile, 'destinationProfile': {**profile, 'endpointUrl': 'https://other.invalid', 'secretKey': 'other-key'},
        'sourceBucketName': 'source', 'sourceKey': ' leading/key ', 'sourceVersionId': 'old-version',
        'destinationBucketName': 'destination', 'destinationKey': ' leading/key ', 'conflictPolicy': 'replace'})
    assert result['strategy'] == 'relay'
    assert result['bytesCopied'] == 7
    assert source.get_object.call_args.kwargs['VersionId'] == 'old-version'
    assert source.get_object.call_args.kwargs['IfMatch'] == 'source-etag'
    assert destination.put_object.call_args.kwargs['Key'] == ' leading/key '
    assert destination.put_object.call_args.kwargs['Metadata'] == {'fixture': 'yes'}
    assert destination.head_object.call_args.kwargs['VersionId'] == 'new-version'


def test_large_server_side_copy_aborts_on_part_failure(pyengine, monkeypatch, profile):
    client = Mock()
    client.head_object.return_value = {'ContentLength': 6 * 1024**3, 'ETag': 'source-etag', 'Metadata': {}}
    client.get_object_tagging.return_value = {'TagSet': []}
    client.create_multipart_upload.return_value = {'UploadId': 'upload'}
    client.upload_part_copy.side_effect = error('InternalError')
    monkeypatch.setattr(pyengine, '_build_client', lambda _: client)
    with pytest.raises(ClientError):
        pyengine._storage_copy({'profile': profile, 'sourceBucketName': 'src', 'sourceKey': 'key', 'destinationBucketName': 'dst', 'destinationKey': 'key'})
    client.abort_multipart_upload.assert_called_once()
    client.complete_multipart_upload.assert_not_called()


def test_known_bucket_connections_do_not_require_list_buckets(pyengine, monkeypatch, profile):
    client = Mock()
    monkeypatch.setattr(pyengine, '_build_client', lambda _: client)
    profile['knownBucket'] = 'scoped-bucket'
    assert pyengine._list_buckets(profile)['items'][0]['name'] == 'scoped-bucket'
    assert pyengine._test_profile(profile)['bucketCount'] == 1
    client.list_buckets.assert_not_called()
    client.head_bucket.assert_called_once_with(Bucket='scoped-bucket')


def test_access_freshness_never_treats_denied_read_as_empty(pyengine, monkeypatch, profile):
    client = Mock()
    client.get_bucket_policy.side_effect = error('AccessDenied')
    monkeypatch.setattr(pyengine, '_build_client', lambda _: client)
    with pytest.raises(ClientError):
        pyengine._storage_action({'profile': profile, 'action': 'putAccess', 'bucketName': 'bucket',
            'policyJson': '{"Statement": []}', 'expectedPolicyJson': '{}'})
    client.put_bucket_policy.assert_not_called()
    client.delete_bucket_policy.assert_not_called()


def test_ensure_bucket_never_creates_after_denied_head(pyengine, monkeypatch, profile):
    client = Mock()
    client.head_bucket.side_effect = error('AccessDenied')
    monkeypatch.setattr(pyengine, '_build_client', lambda _: client)
    with pytest.raises(ClientError):
        pyengine._storage_action({'action': 'ensureBucket', 'profile': profile, 'bucketName': 'bucket'})
    client.create_bucket.assert_not_called()


@pytest.mark.parametrize('size', [0, 1, 64 * 1024**2, 50000 * 128 * 1024**2, 50000 * 4000 * 1024**2])
def test_azure_block_sizing_respects_block_count_limits(pyengine, size):
    chunk = pyengine._azure_block_size(size)
    assert chunk <= 4000 * 1024**2
    assert (size + chunk - 1) // chunk <= 50000


def test_azure_sas_query_is_signed_without_logging_token(pyengine, monkeypatch, profile):
    logs = []
    monkeypatch.setattr(pyengine, '_emit_structured_log', lambda *args: logs.append(str(args)))
    azure = pyengine._parse_profile({**profile, 'endpointType': 'azureBlob', 'authMode': 'azureSas',
        'secretKey': '', 'sessionToken': 'sp=rw&sig=SENTINEL-SAS', 'diagnostics': {'enableApiLogging': True}})
    client = pyengine._AzureBlobClient(azure)
    response = Mock(status=200, headers={})
    client.pool = Mock()
    client.pool.request.return_value = response
    client.open('HEAD', '/container/key')
    assert 'sig=SENTINEL-SAS' in client.pool.request.call_args.args[1]
    assert 'SENTINEL-SAS' not in '\n'.join(logs)
    assert 'Authorization' not in client.pool.request.call_args.kwargs['headers']


def test_azure_upload_blocks_overlap_and_commit_after_all_parts(pyengine, monkeypatch, profile, tmp_path):
    import threading
    path = tmp_path / 'large.bin'
    with path.open('wb') as handle: handle.truncate(65 * 1024**2)
    active = 0
    maximum = 0
    committed = False
    lock = threading.Lock()
    client = Mock()
    client.blob_path.return_value = '/bucket/large.bin'
    def request(method, path, query=None, **kwargs):
        nonlocal active, maximum, committed
        if query.get('comp') == 'block':
            with lock:
                active += 1
                maximum = max(maximum, active)
            time.sleep(0.02)
            with lock: active -= 1
        else:
            assert active == 0
            committed = True
        return 201, {}, b''
    client.request.side_effect = request
    monkeypatch.setattr(pyengine, '_build_azure_client', lambda _: client)
    result = pyengine._run_transfer(pyengine._azure_start_upload, {'profile': {**profile, 'endpointType': 'azureBlob', 'secretKey': 'Zml4dHVyZQ=='},
        'bucketName': 'bucket', 'filePaths': [str(path)]})
    assert result['status'] == 'completed'
    assert maximum > 1
    assert committed


def test_file_part_seeks_and_reads_only_its_range(pyengine):
    stream = pyengine._FilePart(io.BytesIO(b'beforePAYLOADafter'), 6, 7)
    assert stream.read(3) == b'PAY'
    stream.seek(-2, 2)
    assert stream.read() == b'AD'
    stream.seek(0)
    assert stream.read(999) == b'PAYLOAD'
    assert stream.read(1) == b''
    with pytest.raises(ValueError): stream.seek(8)


def _recovery_fixture(pyengine, profile, tmp_path, monkeypatch):
    monkeypatch.setattr(pyengine, '_recovery_dir', lambda: tmp_path)
    path = tmp_path / 'source.bin'
    with path.open('wb') as handle: handle.truncate(11 * 1024**2)
    identity = pyengine._file_identity(path)
    state = {'id': 'upload-' + 'a' * 32, 'recoveryId': 'upload-' + 'a' * 32,
        'profileRef': pyengine._recovery_profile_ref(profile), 'bucketName': 'bucket', 'key': ' exact/key ',
        'filePath': str(path), 'fileSize': identity['size'], 'sourceIdentity': identity, 'partSize': 5 * 1024**2,
        'parts': [{'PartNumber': 1, 'ETag': 'valid'}, {'PartNumber': 2, 'ETag': 'stale'}],
        'completedBytes': 10 * 1024**2, 'status': 'uploading', 'createdAt': pyengine._now_iso(),
        'ownerPid': None, 'conflictPolicy': 'replace', 'options': {'Metadata': {}}, 'uploadId': 'remote-upload'}
    pyengine._recovery_write(state)
    client = Mock()
    client.list_parts.return_value = {'Parts': [{'PartNumber': 1, 'ETag': 'valid', 'Size': 5 * 1024**2},
                                               {'PartNumber': 2, 'ETag': 'changed', 'Size': 5 * 1024**2}]}
    client.upload_part.side_effect = lambda **kw: {'ETag': f'uploaded-{kw["PartNumber"]}'}
    client.complete_multipart_upload.return_value = {'VersionId': 'new-version'}
    client.head_object.return_value = {'ContentLength': identity['size'], 'VersionId': 'new-version',
        'Metadata': {'object-browser-recovery-id': state['id'], 'object-browser-source-sha256': identity['sha256']}}
    monkeypatch.setattr(pyengine, '_build_client', lambda _: client)
    return state, client, path


def test_durable_upload_reconciles_remote_parts_and_preserves_secret_boundary(pyengine, profile, tmp_path, monkeypatch):
    state, client, path = _recovery_fixture(pyengine, profile, tmp_path, monkeypatch)
    result = pyengine._storage_action({'action': 'resumeUpload', 'profile': profile, 'recoveryId': state['id']})
    assert result['status'] == 'completed'
    assert {call.kwargs['PartNumber'] for call in client.upload_part.call_args_list} == {2, 3}
    assert client.complete_multipart_upload.call_args.kwargs['MultipartUpload']['Parts'][0] == {'PartNumber': 1, 'ETag': 'valid'}
    client.abort_multipart_upload.assert_not_called()
    manifest = pyengine._recovery_path(state['id']).read_text()
    assert 'SENTINEL' not in manifest
    assert 'SENTINEL' not in json.dumps(result)


def test_durable_upload_rejects_changed_source_before_remote_mutation(pyengine, profile, tmp_path, monkeypatch):
    state, client, path = _recovery_fixture(pyengine, profile, tmp_path, monkeypatch)
    with path.open('r+b') as output: output.write(b'changed')
    with pytest.raises(pyengine.SidecarError, match='identity changed'):
        pyengine._storage_action({'action': 'resumeUpload', 'profile': profile, 'recoveryId': state['id']})
    client.upload_part.assert_not_called()
    client.complete_multipart_upload.assert_not_called()


def test_unknown_upload_completion_is_verified_without_replaying(pyengine, profile, tmp_path, monkeypatch):
    state, client, path = _recovery_fixture(pyengine, profile, tmp_path, monkeypatch)
    state['status'] = 'completionUnknown'
    pyengine._recovery_write(state)
    client.head_object.return_value = {'ContentLength': state['fileSize'], 'Metadata': {}}
    result = pyengine._storage_action({'action': 'resumeUpload', 'profile': profile, 'recoveryId': state['id']})
    assert result['status'] == 'completionUnknown'
    assert result['requiresVerification']
    client.upload_part.assert_not_called()
    client.complete_multipart_upload.assert_not_called()


def test_durable_upload_failures_abort_incomplete_uploads(pyengine, profile, tmp_path, monkeypatch):
    state, client, path = _recovery_fixture(pyengine, profile, tmp_path, monkeypatch)
    client.upload_part.side_effect = error('InternalError')
    with pytest.raises(ClientError):
        pyengine._storage_action({'action': 'resumeUpload', 'profile': profile, 'recoveryId': state['id']})
    client.abort_multipart_upload.assert_called_once()
    assert json.loads(pyengine._recovery_path(state['id']).read_text())['status'] == 'failed'


@pytest.mark.parametrize('source_azure,dest_azure', [(False, True), (True, False), (True, True)])
def test_cross_provider_copy_preserves_metadata_headers_and_tags(pyengine, monkeypatch, profile, source_azure, dest_azure):
    source, destination = Mock(), Mock()
    source_profile = {**profile, 'endpointType': 'azureBlob' if source_azure else 's3Compatible', 'secretKey': 'Zml4dHVyZQ=='}
    dest_profile = {**source_profile, 'endpointType': 'azureBlob' if dest_azure else 's3Compatible', 'endpointUrl': 'https://other.invalid'}
    source.head_object.return_value = {'ContentLength': 7, 'ETag': 'etag', 'Metadata': {'project': 'fixture'}, 'ContentType': 'text/plain'}
    source.get_object_tagging.return_value = {'TagSet': [{'Key': 'env', 'Value': 'test'}]}
    source.get_object.return_value = {'Body': io.BytesIO(b'payload')}
    source.blob_path.return_value = '/source/ exact-key '
    source.open.return_value = io.BytesIO(b'payload')
    def read_azure(method, path, **kwargs):
        if method == 'HEAD': return 200, {'Content-Length': '7', 'ETag': 'etag', 'Content-Type': 'text/plain', 'x-ms-meta-project': 'fixture'}, b''
        return 200, {}, b'<Tags><TagSet><Tag><Key>env</Key><Value>test</Value></Tag></TagSet></Tags>'
    source.request.side_effect = read_azure
    destination.head_object.return_value = {'ContentLength': 7}
    destination.put_object.return_value = {}
    destination.blob_path.return_value = '/destination/ exact-key '
    destination.request.side_effect = lambda method, path, **kw: (200, {'Content-Length': '7'}, b'')
    monkeypatch.setattr(pyengine, '_build_client', lambda p: source if p.endpoint_url == profile['endpointUrl'] else destination)
    monkeypatch.setattr(pyengine, '_build_azure_client', lambda p: source if p.endpoint_url == profile['endpointUrl'] else destination)
    result = pyengine._storage_copy({'sourceProfile': source_profile, 'destinationProfile': dest_profile,
        'sourceBucketName': 'source', 'sourceKey': ' exact-key ', 'destinationBucketName': 'destination', 'destinationKey': ' exact-key '})
    assert result['bytesCopied'] == 7
    if dest_azure:
        commit = next(call for call in destination.request.call_args_list if call.kwargs.get('query', {}).get('comp') == 'blocklist')
        assert commit.kwargs['headers']['x-ms-meta-project'] == 'fixture'
        assert commit.kwargs['headers']['x-ms-blob-content-type'] == 'text/plain'
        assert commit.kwargs['headers']['x-ms-tags'] == 'env=test'
    else:
        options = destination.put_object.call_args.kwargs
        assert options['Metadata'] == {'project': 'fixture'}
        assert options['ContentType'] == 'text/plain'
        assert options['Tagging'] == 'env=test'


def test_skip_copy_uses_atomic_destination_condition(pyengine, monkeypatch, profile):
    source, destination = Mock(), Mock()
    source.head_object.return_value = {'ContentLength': 7, 'ETag': 'etag', 'Metadata': {}}
    source.get_object_tagging.return_value = {'TagSet': []}
    source.get_object.return_value = {'Body': io.BytesIO(b'payload')}
    destination.head_object.side_effect = [error('404'), {'ContentLength': 7}]
    destination.put_object.return_value = {}
    monkeypatch.setattr(pyengine, '_build_client', lambda p: source if p.secret_key == profile['secretKey'] else destination)
    result = pyengine._storage_copy({'sourceProfile': profile, 'destinationProfile': {**profile, 'secretKey': 'different-credentials'},
        'sourceBucketName': 'source', 'sourceKey': 'key', 'destinationBucketName': 'destination', 'destinationKey': 'key', 'conflictPolicy': 'skip'})
    assert result['strategy'] == 'relay'
    assert destination.put_object.call_args.kwargs['IfNoneMatch'] == '*'
    source.copy_object.assert_not_called()
    destination.copy_object.assert_not_called()


def test_embedded_copy_error_never_counts_existing_destination_as_success(pyengine, monkeypatch, profile):
    client = Mock()
    client.head_object.return_value = {'ContentLength': 7, 'ETag': 'etag', 'Metadata': {}}
    client.get_object_tagging.return_value = {'TagSet': []}
    client.copy_object.return_value = {'Error': {'Code': 'InternalError'}}
    monkeypatch.setattr(pyengine, '_build_client', lambda _: client)
    with pytest.raises(pyengine.SidecarError, match='embedded mutation error'):
        pyengine._storage_copy({'profile': profile, 'sourceBucketName': 'source', 'sourceKey': 'key', 'destinationBucketName': 'destination', 'destinationKey': 'key'})
    assert client.head_object.call_count == 1


def test_copy_uses_destination_encryption_defaults_across_buckets(pyengine, monkeypatch, profile):
    client = Mock()
    client.head_object.return_value = {'ContentLength': 7, 'ETag': 'etag', 'Metadata': {}, 'ServerSideEncryption': 'aws:kms', 'SSEKMSKeyId': 'source-key'}
    client.get_object_tagging.return_value = {'TagSet': []}
    client.copy_object.return_value = {'CopyObjectResult': {'ETag': 'new-etag'}}
    monkeypatch.setattr(pyengine, '_build_client', lambda _: client)
    pyengine._storage_copy({'profile': profile, 'sourceBucketName': 'source', 'sourceKey': 'key', 'destinationBucketName': 'destination', 'destinationKey': 'key'})
    assert 'SSEKMSKeyId' not in client.copy_object.call_args.kwargs
    assert 'ServerSideEncryption' not in client.copy_object.call_args.kwargs


@pytest.mark.parametrize('token', [None, 'repeated'])
def test_malformed_s3_listing_cursor_is_an_error(pyengine, monkeypatch, profile, token):
    client = Mock()
    client.list_objects_v2.return_value = {'Contents': [], 'IsTruncated': True, 'NextContinuationToken': token}
    monkeypatch.setattr(pyengine, '_build_client', lambda _: client)
    with pytest.raises(pyengine.SidecarError, match='continuation token'):
        pyengine._list_objects({'profile': profile, 'bucketName': 'bucket', 'cursor': {'value': 'repeated'}})


def test_empty_access_preset_removes_only_fresh_policy(pyengine, profile, monkeypatch):
    client = Mock()
    existing = '{"Version":"2012-10-17","Statement":[{"Sid":"ObjectBrowserPreset","Effect":"Allow"}]}'
    client.get_bucket_policy.return_value = {'Policy': existing}
    monkeypatch.setattr(pyengine, '_build_client', lambda _: client)
    result = pyengine._storage_action({'action': 'putAccess', 'profile': profile, 'bucketName': 'bucket',
        'expectedPolicyJson': existing, 'policyJson': '{"Version":"2012-10-17","Statement":[]}'})
    assert result['applied']
    client.delete_bucket_policy.assert_called_once_with(Bucket='bucket')
    client.put_bucket_policy.assert_not_called()


def test_startup_scrubs_owned_legacy_benchmark_artifacts(pyengine, profile, tmp_path):
    legacy = {'id': 'bench-legacy', 'profile': profile, 'status': 'running'}
    path = pyengine._benchmark_state_path('bench-legacy')
    path.write_text(json.dumps(legacy))
    unrelated = tmp_path / 'unrelated.json'
    unrelated.write_text('fixture unrelated state')
    pyengine._scrub_legacy_benchmark_artifacts()
    state = json.loads(path.read_text())
    assert state['requiresReauthorization']
    assert 'SENTINEL' not in path.read_text()
    assert unrelated.read_text() == 'fixture unrelated state'


def test_azure_default_auth_uses_bundled_identity_without_decoding_static_secret(pyengine, monkeypatch, profile):
    import azure.identity
    provider = Mock()
    provider.get_token.return_value = Mock(token='SENTINEL-BEARER')
    monkeypatch.setattr(azure.identity, 'DefaultAzureCredential', lambda: provider)
    logs = []
    monkeypatch.setattr(pyengine, '_emit_structured_log', lambda *args: logs.append(str(args)))
    client = pyengine._AzureBlobClient(pyengine._parse_profile({**profile, 'endpointType': 'azureBlob',
        'authMode': 'azureDefault', 'secretKey': 'invalid base64 unused', 'diagnostics': {'enableApiLogging': True}}))
    client.pool = Mock()
    client.pool.request.return_value = Mock(status=200, headers={})
    client.open('HEAD', '/bucket/key')
    assert client.pool.request.call_args.kwargs['headers']['Authorization'] == 'Bearer SENTINEL-BEARER'
    assert 'SENTINEL-BEARER' not in '\n'.join(logs)


def test_bucket_configuration_preserves_independent_denied_and_supported_sections(pyengine, profile, monkeypatch):
    client = Mock()
    client.get_bucket_replication.side_effect = error('AccessDenied')
    client.get_bucket_notification_configuration.return_value = {'TopicConfigurations': [{'Id': 'notice', 'Events': ['s3:ObjectCreated:*']}]}
    client.get_bucket_ownership_controls.return_value = {'OwnershipControls': {'Rules': [{'ObjectOwnership': 'BucketOwnerEnforced'}]}}
    client.get_public_access_block.side_effect = TimeoutError('fixture timeout')
    monkeypatch.setattr(pyengine, '_build_client', lambda _: client)
    result = pyengine._storage_action({'action': 'getBucketConfiguration', 'profile': profile, 'bucketName': 'bucket'})
    assert result['notification']['TopicConfigurations'][0]['Id'] == 'notice'
    assert result['sections']['GetBucketReplication']['state'] == 'denied'
    assert result['sections']['GetPublicAccessBlock']['state'] == 'error'
    assert result['sections']['GetBucketOwnershipControls']['state'] == 'supported'


def test_object_details_report_actual_identity_restore_and_encryption(pyengine, profile, monkeypatch):
    client = Mock()
    client.head_object.return_value = {'ContentLength': 7, 'Metadata': {}, 'ETag': '"etag"', 'VersionId': 'actual-version',
        'Restore': 'ongoing-request="true"', 'ServerSideEncryption': 'aws:kms', 'SSEKMSKeyId': 'fixture-key',
        'ContentDisposition': 'attachment', 'ContentEncoding': 'gzip', 'ContentLanguage': 'en'}
    client.get_object_tagging.return_value = {'TagSet': []}
    monkeypatch.setattr(pyengine, '_build_client', lambda _: client)
    details = pyengine._get_object_details({'profile': profile, 'bucketName': 'bucket', 'key': 'key'})
    assert details['etag'] == 'etag'
    assert details['versionId'] == 'actual-version'
    assert details['encryption']['SSEKMSKeyId'] == 'fixture-key'
    assert details['restore'] == 'ongoing-request="true"'
    assert details['headers']['Content-Disposition'] == 'attachment'


def test_relay_coalesces_short_reads_and_bounds_each_part(pyengine):
    class ShortReads(io.BytesIO):
        def read(self, count=-1): return super().read(min(count, 3))
    result = []
    for part in pyengine._relay_chunks(ShortReads(b'abcdefghijklmno'), 8):
        result.append(part.read())
    assert result == [b'abcdefgh', b'ijklmno']


@pytest.mark.parametrize('mode,expected', [
    ('write-only', {'PUT': 200}),
    ('read-only', {'GET': 200}),
    ('custom', {'PUT': 40, 'GET': 140, 'DELETE': 20}),
])
def test_benchmark_workload_selection_matches_requested_mix(pyengine, mode, expected):
    from collections import Counter
    state = {'config': {'workloadType': mode, 'writePercent': 20, 'readPercent': 70, 'deletePercent': 10}}
    actual = Counter()
    for index in range(200):
        state['processedCount'] = index
        actual[pyengine._benchmark_operation_for_index(state)] += 1
    assert dict(actual) == expected


def test_benchmark_custom_workload_normalizes_weights(pyengine):
    state = {'config': {'workloadType': 'custom', 'writePercent': 2, 'readPercent': 1, 'deletePercent': 0}}
    operations = []
    for index in range(6):
        state['processedCount'] = index
        operations.append(pyengine._benchmark_operation_for_index(state))
    assert operations == ['PUT', 'PUT', 'GET', 'PUT', 'PUT', 'GET']


def test_benchmark_pure_write_runs_beyond_first_default_mix_window(pyengine, profile):
    import threading
    from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
    calls = []
    class Handler(BaseHTTPRequestHandler):
        protocol_version = 'HTTP/1.1'
        def log_message(self, *_):
            pass
        def do_PUT(self):
            body = self.rfile.read(int(self.headers.get('Content-Length', '0')))
            calls.append((self.command, self.path, body))
            self.send_response(200)
            self.send_header('Content-Length', '0')
            self.send_header('ETag', '"fixture-etag"')
            self.end_headers()
        def do_GET(self):
            calls.append((self.command, self.path, b''))
            self.send_response(500)
            self.send_header('Content-Length', '0')
            self.end_headers()
        do_DELETE = do_GET
    with ThreadingHTTPServer(('127.0.0.1', 0), Handler) as server:
        worker = threading.Thread(target=server.serve_forever, daemon=True)
        worker.start()
        try:
            endpoint = {**profile, 'endpointUrl': f'http://127.0.0.1:{server.server_port}', 'maxAttempts': 1}
            state = pyengine._start_benchmark({'profile': endpoint, 'config': {
                'bucketName': 'fixture', 'testMode': 'operation-count', 'operationCount': 120,
                'concurrentThreads': 4, 'objectCount': 120, 'workloadType': 'write-only',
                'objectSizes': [16], 'randomData': False,
            }})
            run = pyengine._BENCHMARKS[state['id']]
            deadline = time.monotonic() + 10
            while run.state['status'] == 'running' and time.monotonic() < deadline:
                time.sleep(0.01)
            snapshot = pyengine._get_benchmark_status({'runId': state['id']})
            assert snapshot['status'] == 'completed', snapshot
            assert snapshot['processedCount'] == 120
            assert snapshot['resultSummary']['operationsByType'] == {'PUT': 120}
            assert len(calls) == 120
            assert all(method == 'PUT' and body == b'A' * 16 for method, _, body in calls)
            assert len({path for _, path, _ in calls}) == 120
        finally:
            server.shutdown()
            worker.join(timeout=2)


def test_benchmark_read_only_seeds_then_reads_without_deletes(pyengine):
    class Store:
        def __init__(self):
            self.values = {}
            self.puts = 0
            self.gets = 0
        def put_object(self, *, Bucket, Key, Body):
            self.puts += 1
            self.values[Key] = Body
        def get_object(self, *, Bucket, Key):
            self.gets += 1
            return {'Body': io.BytesIO(self.values[Key])}
    store = Store()
    state = {'id': 'read-only-test', 'config': {'bucketName': 'fixture', 'workloadType': 'read-only',
             'objectSizes': [16], 'objectCount': 1, 'randomData': False, 'validateChecksum': True},
             'benchmarkPrefix': 'fixture/', 'history': [], 'activeObjects': [], 'processedCount': 0}
    for _ in range(120):
        pyengine._run_benchmark_operation(state, store)
    assert store.puts == 1
    assert store.gets == 119
    assert pyengine._benchmark_operations_from_history(state['history']) == {'PUT': 1, 'GET': 119}
    assert all(row['checksumState'] == 'validated_success' for row in state['history'] if row['operation'] == 'GET')
