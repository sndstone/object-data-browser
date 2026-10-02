"""New durable/admin workflow tests. Only isolated fakes and temporary files."""
import base64
import csv
import hashlib
import hmac
import importlib.util
import io
import json
import sys
from datetime import datetime, timezone, timedelta
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import Mock
from urllib.parse import parse_qs, urlparse

import pytest
from botocore.exceptions import ClientError


@pytest.fixture
def engine(monkeypatch, tmp_path):
    source = Path(__file__).parents[2] / 'engines/python/src/main.py'
    spec = importlib.util.spec_from_file_location('workflow_test_engine', source)
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    monkeypatch.setenv('OBJECT_BROWSER_TRANSFER_DIR', str(tmp_path / 'recovery'))
    monkeypatch.setattr(module, '_runtime_dir', lambda: tmp_path / 'benchmark')
    (tmp_path / 'benchmark').mkdir()
    monkeypatch.setattr(module, '_emit_transfer_event', lambda _: None)
    monkeypatch.chdir(tmp_path)
    yield module
    for run in module._BENCHMARKS.values():
        with run.lock:
            run.state['status'] = 'stopped'
            run.wake.set()
        for worker in run.threads:
            worker.join(timeout=2)
    sys.modules.pop(spec.name, None)


@pytest.fixture
def profile():
    return {'id': 'source', 'endpointType': 's3Compatible', 'endpointUrl': 'https://source.invalid',
            'accessKey': 'SECRET-ACCESS-SENTINEL', 'secretKey': 'SECRET-KEY-SENTINEL', 'sessionToken': 'SECRET-TOKEN-SENTINEL',
            'pathStyle': True, 'maxAttempts': 2}


def sdk_error(code, status=404):
    return ClientError({'Error': {'Code': code, 'Message': 'fixture'}, 'ResponseMetadata': {'HTTPStatusCode': status}}, 'Fixture')


def pair(engine, monkeypatch, profile):
    source, destination = Mock(), Mock()
    destination.get_bucket_versioning.return_value = {'Status': 'Enabled'}
    source.get_bucket_versioning.return_value = {'Status': 'Enabled'}
    destination.list_object_versions.return_value = {}
    source.list_object_versions.return_value = {}
    monkeypatch.setattr(engine, '_build_client', lambda p: source if p.endpoint_url == profile['endpointUrl'] else destination)
    params = {'sourceProfile': profile, 'destinationProfile': {**profile, 'id': 'destination', 'endpointUrl': 'https://destination.invalid'},
              'sourceBucketName': 'source-bucket', 'destinationBucketName': 'destination-bucket'}
    return source, destination, params


def version(ident, age, latest=False, key=' exact /key '):
    return {'Key': key, 'VersionId': ident, 'Size': 3, 'ETag': '"etag"', 'IsLatest': latest,
            'LastModified': datetime(2026, 1, 1, tzinfo=timezone.utc) + timedelta(seconds=age)}


def test_history_replays_oldest_to_newest_and_preserves_final_delete(engine, monkeypatch, profile, tmp_path):
    src, dst, params = pair(engine, monkeypatch, profile)
    src.list_object_versions.return_value = {'Versions': [version('v2', 2), version('null', 1)],
                                            'DeleteMarkers': [version('deleted', 3, True)]}
    src.head_object.return_value = {'Metadata': {'original': 'value'}}
    destination_rows = []
    dst.list_object_versions.side_effect = lambda **_: {'Versions': [row for row in destination_rows if not row['VersionId'].startswith('marker')],
                                                       'DeleteMarkers': [row for row in destination_rows if row['VersionId'].startswith('marker')]}
    calls = []
    def copy(p):
        calls.append(p)
        row = version('dest-' + p['sourceVersionId'], len(calls), True)
        destination_rows.append(row)
        return {'successCount': 1, 'versionId': row['VersionId']}
    monkeypatch.setattr(engine, '_storage_copy', copy)
    def delete(**kwargs):
        calls.append(kwargs)
        destination_rows.append(version('marker-final', 3, True))
        return {'DeleteMarker': True, 'VersionId': 'marker-final'}
    dst.delete_object.side_effect = delete
    plan = engine._storage_action({**params, 'action': 'planHistoryCopy'})
    assert plan['versionCount'] == 2 and plan['deleteMarkerCount'] == 1
    first = engine._storage_action({**params, 'action': 'resumeHistoryCopy', 'recoveryId': plan['id'], 'maxEntries': 1})
    assert first['status'] == 'running' and first['completedCount'] == 1
    done = engine._storage_action({**params, 'action': 'resumeHistoryCopy', 'recoveryId': plan['id']})
    assert done['status'] == 'completed'
    assert [m['sourceVersionId'] for m in done['mappings']] == ['null', 'v2', 'deleted']
    assert done['mappings'][-1]['deleteMarker']
    assert calls[0]['sourceVersionId'] == 'null'
    assert calls[0]['destinationProfile']['maxAttempts'] == 1
    for path in (tmp_path / 'recovery').glob('*.json'):
        assert 'SECRET-' not in path.read_text()


def test_history_unknown_write_never_replayed(engine, monkeypatch, profile):
    src, dst, params = pair(engine, monkeypatch, profile)
    src.list_object_versions.return_value = {'Versions': [version('v1', 1, True)]}
    src.head_object.return_value = {'Metadata': {}}
    copy = Mock(side_effect=TimeoutError('transport'))
    monkeypatch.setattr(engine, '_storage_copy', copy)
    plan = engine._storage_action({**params, 'action': 'planHistoryCopy'})
    with pytest.raises(TimeoutError):
        engine._storage_action({**params, 'action': 'resumeHistoryCopy', 'recoveryId': plan['id']})
    state = engine._storage_action({**params, 'action': 'resumeHistoryCopy', 'recoveryId': plan['id']})
    assert state['status'] == 'outcomeUnknown' and copy.call_count == 1


def test_history_rejects_source_changes_and_nonempty_destination(engine, monkeypatch, profile):
    src, dst, params = pair(engine, monkeypatch, profile)
    src.list_object_versions.return_value = {'Versions': [version('v1', 1, True)]}
    plan = engine._storage_action({**params, 'action': 'planHistoryCopy'})
    src.list_object_versions.return_value = {'Versions': [version('v2', 2, True)]}
    with pytest.raises(engine.SidecarError, match='Source version history changed'):
        engine._storage_action({**params, 'action': 'resumeHistoryCopy', 'recoveryId': plan['id']})
    dst.list_object_versions.return_value = {'DeleteMarkers': [version('old', 1, True)]}
    with pytest.raises(engine.SidecarError, match='empty destination'):
        engine._storage_action({**params, 'action': 'planHistoryCopy'})


def test_history_plan_missing_destination_is_read_only(engine, monkeypatch, profile):
    src, dst, params = pair(engine, monkeypatch, profile)
    dst.get_bucket_versioning.side_effect = sdk_error('NoSuchBucket')
    plan = engine._storage_action({**params, 'action': 'planHistoryCopy', 'createDestinationIfMissing': True})
    assert plan['destinationInitiallyMissing']
    assert not dst.create_bucket.called
    assert not dst.put_bucket_versioning.called


def test_history_version_cursor_must_progress(engine, monkeypatch, profile):
    src, dst, params = pair(engine, monkeypatch, profile)
    src.list_object_versions.return_value = {'IsTruncated': True}
    with pytest.raises(engine.SidecarError, match='cursor'):
        engine._storage_action({**params, 'action': 'planHistoryCopy'})


def test_configuration_maps_explicit_grants_and_checks_destination_freshness(engine, monkeypatch, profile):
    src, dst, params = pair(engine, monkeypatch, profile)
    policy = {'Version': '2012-10-17', 'Statement': {'Effect': 'Allow', 'Principal': {'AWS': 'arn:aws:iam::123456789012:role/Reader'},
              'Action': 's3:GetObject', 'Resource': 'arn:aws:s3:::source-bucket/team/*'}}
    src.get_bucket_policy.return_value = {'Policy': json.dumps(policy)}
    dst.get_bucket_policy.side_effect = sdk_error('NoSuchBucketPolicy')
    plan = engine._storage_action({**params, 'action': 'planBucketConfigurationCopy', 'sections': ['policy']})
    assert not plan['blocked']
    assert plan['changes'][0]['after']['Statement'][0]['Resource'] == 'arn:aws:s3:::destination-bucket/team/*'
    dst.get_bucket_policy.side_effect = None
    dst.get_bucket_policy.return_value = {'Policy': json.dumps({'Statement': []})}
    with pytest.raises(engine.SidecarError, match='changed after review'):
        engine._storage_action({**params, 'action': 'applyBucketConfigurationCopy', 'planId': plan['id']})
    assert not dst.put_bucket_policy.called


@pytest.mark.parametrize('principal', ['*', {'AWS': '*'}, {'Service': 's3.amazonaws.com'}, {'AWS': 'arn:aws:iam::*:role/Reader'}])
def test_configuration_blocks_broad_policy_grants(engine, monkeypatch, profile, principal):
    src, dst, params = pair(engine, monkeypatch, profile)
    src.get_bucket_policy.return_value = {'Policy': json.dumps({'Statement': [{'Effect': 'Allow', 'Principal': principal,
              'Action': 's3:GetObject', 'Resource': 'arn:aws:s3:::source-bucket/*'}]})}
    dst.get_bucket_policy.side_effect = sdk_error('NoSuchBucketPolicy')
    plan = engine._storage_action({**params, 'action': 'planBucketConfigurationCopy', 'sections': ['policy']})
    assert plan['blocked'] and not plan['changes']


def test_configuration_public_block_never_weakens_destination(engine, monkeypatch, profile):
    src, dst, params = pair(engine, monkeypatch, profile)
    fields = ['BlockPublicAcls', 'IgnorePublicAcls', 'BlockPublicPolicy', 'RestrictPublicBuckets']
    src.get_public_access_block.return_value = {'PublicAccessBlockConfiguration': dict.fromkeys(fields, False)}
    dst.get_public_access_block.return_value = {'PublicAccessBlockConfiguration': dict.fromkeys(fields, True)}
    plan = engine._storage_action({**params, 'action': 'planBucketConfigurationCopy', 'sections': ['publicAccessBlock']})
    assert not plan['changes'] and not plan['blocked']


def ranged_client(engine, monkeypatch, data):
    client = Mock()
    client.head_object.return_value = {'ContentLength': len(data), 'ETag': '"stable"', 'VersionId': 'null', 'Metadata': {}}
    def get(**kwargs):
        start, end = map(int, kwargs['Range'][6:].split('-'))
        assert kwargs['IfMatch'] == '"stable"' and kwargs['VersionId'] == 'null'
        return {'Body': io.BytesIO(data[start:end+1]), 'ContentRange': f'bytes {start}-{end}/{len(data)}'}
    client.get_object.side_effect = get
    monkeypatch.setattr(engine, '_build_client', lambda _: client)
    return client


def test_download_resumes_verified_ranges_and_checks_local_tampering(engine, monkeypatch, profile, tmp_path):
    data = b'A' * 1024**2 + b'B' * 1024**2 + b'C'
    client = ranged_client(engine, monkeypatch, data)
    params = {'profile': profile, 'bucketName': 'bucket', 'key': ' exact /file.bin', 'versionId': 'null',
              'destinationDirectory': str(tmp_path), 'multipartChunkMiB': 1, 'maxRanges': 1}
    state = engine._storage_action({**params, 'action': 'startResumableDownload'})
    assert state['status'] == 'paused' and state['completedBytes'] == 1024**2
    with Path(state['stagedPath']).open('r+b') as target:
        target.write(b'corrupt')
    state = engine._storage_action({'profile': profile, 'action': 'resumeDownload', 'recoveryId': state['id']})
    assert state['status'] == 'completed'
    assert Path(state['filePath']).read_bytes() == data
    assert client.get_object.call_count == 4
    for path in (tmp_path / 'recovery').glob('*.json'):
        assert 'SECRET-' not in path.read_text()


def test_download_rejects_remote_change_and_aborts_only_private_stage(engine, monkeypatch, profile, tmp_path):
    data = b'A' * (2 * 1024**2)
    client = ranged_client(engine, monkeypatch, data)
    saved = tmp_path / 'file.bin'
    saved.write_bytes(b'existing')
    state = engine._storage_action({'profile': profile, 'action': 'startResumableDownload', 'bucketName': 'bucket', 'key': 'file.bin',
                                   'destinationDirectory': str(tmp_path), 'multipartChunkMiB': 1, 'maxRanges': 1})
    client.head_object.return_value['ETag'] = 'changed'
    with pytest.raises(engine.SidecarError, match='identity changed'):
        engine._storage_action({'profile': profile, 'action': 'resumeDownload', 'recoveryId': state['id']})
    aborted = engine._storage_action({'profile': profile, 'action': 'abortDownload', 'recoveryId': state['id']})
    assert aborted['status'] == 'aborted' and not Path(state['stagedPath']).exists()
    assert saved.read_bytes() == b'existing'


def azure_profile(profile, mode='static'):
    return {**profile, 'endpointType': 'azureBlob', 'endpointUrl': 'https://fixture.blob.core.windows.net',
            'accessKey': 'fixture', 'secretKey': base64.b64encode(b'account secret').decode(), 'authMode': mode}


def test_azure_version_sas_signature_binds_exact_version(engine, profile, monkeypatch):
    payload = azure_profile(profile)
    client = engine._AzureBlobClient(engine._parse_profile(payload))
    monkeypatch.setattr(engine, '_build_azure_client', lambda _: client)
    response = engine._storage_action({'action': 'presignVersion', 'profile': payload, 'bucketName': 'container',
                                       'key': 'space /key+', 'versionId': '2026-01-01T12:00:00.0000000Z', 'expirationSeconds': 60})
    query = {k: v[0] for k, v in parse_qs(urlparse(response['url']).query).items()}
    assert query['sr'] == 'bv' and query['sp'] == 'r' and query['spr'] == 'https'
    fields = ['r', query['st'], query['se'], '/blob/fixture/container/space /key+', '', '', 'https', query['sv'], 'bv',
              query['versionid'], '', '', '', '', '', '']
    signature = base64.b64encode(hmac.new(b'account secret', '\n'.join(fields).encode(), hashlib.sha256).digest()).decode()
    assert query['sig'] == signature
    assert 'space%20/key%2B' in response['url']


def test_azure_existing_sas_cannot_mint_version_token(engine, profile, monkeypatch):
    payload = {**azure_profile(profile, 'azureSas'), 'azureSasToken': 'sig=secret-token'}
    client = engine._AzureBlobClient(engine._parse_profile(payload))
    monkeypatch.setattr(engine, '_build_azure_client', lambda _: client)
    with pytest.raises(engine.SidecarError, match='cannot mint'):
        engine._storage_action({'action': 'presignVersion', 'profile': payload, 'bucketName': 'container', 'key': 'blob', 'versionId': 'v1'})


def test_azure_protection_targets_exact_version(engine, profile, monkeypatch):
    payload = azure_profile(profile)
    client = Mock()
    client.blob_path.return_value = '/container/blob'
    client.request.return_value = (200, {'x-ms-legal-hold': 'true', 'x-ms-version-id': 'exact'}, b'')
    monkeypatch.setattr(engine, '_build_azure_client', lambda _: client)
    response = engine._storage_action({'action': 'setObjectProtection', 'profile': payload, 'bucketName': 'container', 'key': 'blob',
                                      'versionId': 'exact', 'retention': {'Mode': 'Unlocked', 'untilDate': '2099-01-01T00:00:00Z'}, 'legalHold': True})
    assert response['legalHold']['Status'] == 'ON'
    for call in client.request.call_args_list:
        assert call.kwargs['query']['versionid'] == 'exact'
    assert client.request.call_args_list[0].kwargs['headers']['x-ms-immutability-policy-mode'] == 'Unlocked'


def test_azure_account_management_refuses_shared_key_before_network(engine, profile, monkeypatch):
    payload = azure_profile(profile)
    client = SimpleNamespace(profile=engine._parse_profile(payload), credential=None)
    monkeypatch.setattr(engine, '_build_azure_client', lambda _: client)
    with pytest.raises(engine.SidecarError, match='management-plane RBAC'):
        engine._storage_action({'action': 'getAccountLifecycle', 'profile': payload,
                              'accountResourceId': '/subscriptions/123/resourceGroups/rg/providers/Microsoft.Storage/storageAccounts/fixture'})


def test_adls_refuses_unconfirmed_hns_and_signed_source_is_redacted(engine, profile, monkeypatch):
    payload = azure_profile(profile)
    client = Mock()
    client.request.return_value = (200, {'x-ms-is-hns-enabled': 'false'}, b'')
    monkeypatch.setattr(engine, '_build_azure_client', lambda _: client)
    with pytest.raises(engine.SidecarError, match='confirmed hierarchical'):
        engine._storage_action({'action': 'createDirectory', 'profile': payload, 'bucketName': 'container', 'key': 'directory'})
    assert client.request.call_count == 1
    assert engine._sanitize_headers({'x-ms-rename-source': '/container/key?sig=SECRET'})['x-ms-rename-source'] == '[redacted]'


def test_benchmark_cache_file_mode_and_digests(engine, monkeypatch):
    config = {'inMemoryData': True, 'dataCacheMb': 1}
    cache = engine._BenchmarkPayloadStore(config)
    with cache.body('run', 'key', 1024, False) as first:
        with cache.body('run', 'other', 1024, False) as second:
            assert first is second and cache.bytes == 1024
    streamed = engine._BenchmarkPayloadStore({'inMemoryData': False, 'dataCacheMb': 100})
    with streamed.body('run', 'key', 2 * 1024**2 + 17, True) as body:
        assert not isinstance(body, bytes)
        assert body.read() == engine._benchmark_payload_bytes('run', 'key', 2 * 1024**2 + 17, True)
    for algorithm, expected in [('crc32c', 'e3069283'), ('crc32', 'cbf43926'), ('sha256', hashlib.sha256(b'123456789').hexdigest())]:
        digest = engine._benchmark_digest(algorithm)
        digest.update(b'1234')
        digest.update(b'56789')
        assert digest.digest().hex() == expected


def test_benchmark_retry_error_and_reduced_logging_are_measured(engine):
    client = Mock()
    client.put_object.return_value = {'ResponseMetadata': {'RetryAttempts': 2}}
    state = {'id': 'fixture', 'config': {'bucketName': 'bucket', 'workloadType': 'write-only', 'objectSizes': [8], 'reducedLogging': True},
             'benchmarkPrefix': 'fixture/', 'history': [], 'activeObjects': []}
    engine._run_benchmark_operation(state, client)
    assert state['history'][0]['retryCount'] == 2
    assert not state.get('liveLog')
    client.put_object.side_effect = ClientError({'Error': {'Code': 'AccessDenied', 'Message': 'SECRET'},
                                               'ResponseMetadata': {'RetryAttempts': 3}}, 'PutObject')
    with pytest.raises(ClientError):
        engine._run_benchmark_operation(state, client)
    summary = engine._rebuild_benchmark_summary(state)
    assert summary['detailMetrics']['errorCount'] == 1
    assert summary['detailMetrics']['retryCount'] == 5
    assert 'SECRET' not in json.dumps(state)


def test_benchmark_checksum_failure_keeps_sdk_retries_without_duplicate_record(engine):
    body = io.BytesIO(b'corrupt!')
    client = Mock()
    client.get_object.return_value = {
        'Body': body, 'ResponseMetadata': {'RetryAttempts': 3}}
    state = {
        'id': 'fixture',
        'config': {'bucketName': 'bucket', 'workloadType': 'read-only',
                   'objectSizes': [8], 'randomData': False,
                   'validateChecksum': True, 'checksumAlgorithm': 'sha256'},
        'benchmarkPrefix': 'fixture/', 'history': [],
        'activeObjects': [{'key': 'fixture/key', 'sizeBytes': 8}],
    }
    with pytest.raises(engine.SidecarError, match='checksum validation failed'):
        engine._run_benchmark_operation(state, client)
    assert body.closed
    assert len(state['history']) == 1
    record = state['history'][0]
    assert record['operation'] == 'GET'
    assert record['success'] is False
    assert record['checksumState'] == 'validated_failure'
    assert record['retryCount'] == 3
    metrics = engine._rebuild_benchmark_summary(state)['detailMetrics']
    assert metrics['errorCount'] == 1
    assert metrics['retryCount'] == 3
    assert '_retryCount' not in state


@pytest.mark.parametrize('failure', [None, 'sdk', 'checksum'])
def test_benchmark_records_actual_completion_time_for_every_outcome(engine, monkeypatch, failure):
    clock = [10.0]
    monkeypatch.setattr(engine.time, 'perf_counter', lambda: clock[0])
    client = Mock()
    def request(**_):
        clock[0] += 0.314159
        if failure == 'sdk':
            raise sdk_error('AccessDenied', 403)
        return {'Body': io.BytesIO(b'corrupt!'), 'ResponseMetadata': {'RetryAttempts': 2}}
    client.put_object.side_effect = request
    client.get_object.side_effect = request
    state = {
        'id': 'fixture', 'activeElapsedSeconds': 1.1,
        'config': {'bucketName': 'bucket', 'workloadType': 'read-only' if failure == 'checksum' else 'write-only',
                   'objectSizes': [8], 'randomData': False, 'validateChecksum': True},
        'benchmarkPrefix': 'fixture/', 'history': [],
        'activeObjects': [{'key': 'fixture/key', 'sizeBytes': 8}],
    }
    if failure:
        with pytest.raises((ClientError, engine.SidecarError)):
            engine._run_benchmark_operation(state, client)
    else:
        engine._run_benchmark_operation(state, client)
    assert len(state['history']) == 1
    record = state['history'][0]
    assert record['elapsedMs'] == pytest.approx(1414.159)
    assert record['second'] == 2
    assert record['success'] is (failure is None)
    timeline = engine._rebuild_benchmark_summary(state)['latencyTimeline']
    assert timeline[0]['elapsedMs'] == record['elapsedMs']
    assert timeline[0]['label'] == '1.41s'


def test_benchmark_summary_uses_exact_rows_and_actual_runtime_for_averages(engine):
    elapsed = [0.0, 11.125, 986.0625, 1414.159]
    rows = [{'operation': 'PUT', 'second': int(t / 1000) + 1, 'elapsedMs': t,
             'latencyMs': 1, 'bytesTransferred': 8, 'sizeBytes': 8} for t in elapsed]
    summary = engine._rebuild_benchmark_summary({
        'config': {'objectSizes': [8]}, 'history': rows, 'activeElapsedSeconds': 1.5})
    assert [r['elapsedMs'] for r in summary['latencyTimeline']] == elapsed
    assert all(r['timingPrecision'] == 'measured' for r in summary['latencyTimeline'])
    assert summary['detailMetrics']['averageOpsPerSecond'] == round(4 / 1.5, 1)
    assert summary['detailMetrics']['averageBytesPerSecond'] == round(32 / 1.5, 1)
    assert summary['operationDetails'][0]['avgOpsPerSecond'] == round(4 / 1.5, 1)
    for row in rows:
        row.pop('elapsedMs')
    legacy = engine._rebuild_benchmark_summary({'config': {}, 'history': rows})['latencyTimeline']
    assert [r['elapsedMs'] for r in legacy] == [0, 0, 0, 1000]
    assert all(r['timingPrecision'] == 'second' for r in legacy)


def test_benchmark_monotonic_clock_excludes_only_idle_pause_time(engine, monkeypatch):
    clock = [100.0]
    monkeypatch.setattr(engine.time, 'monotonic', lambda: clock[0])
    state = {'id': 'clock-fixture', 'config': {}, 'status': 'running',
             'activeElapsedSeconds': 0, 'history': []}
    run = engine._BenchmarkRun(state, {})
    clock[0] = 100.5
    state['lastUpdatedAt'] = '2999-01-01T00:00:00+00:00'
    assert run.snapshot()['activeElapsedSeconds'] == pytest.approx(0.5)
    run.reserved = 1
    state['status'] = 'paused'
    run.update_clock()
    clock[0] = 100.75
    assert run.elapsed() == pytest.approx(0.75)
    run.reserved = 0
    run.update_clock()
    clock[0] = 500
    assert run.snapshot()['activeElapsedSeconds'] == pytest.approx(0.75)
    state['status'] = 'running'
    run.update_clock()
    clock[0] = 500.25
    public = run.snapshot()
    assert public['activeElapsedSeconds'] == pytest.approx(1)
    assert 'elapsed_anchor' not in json.dumps(public)
    state['status'] = 'completed'
    run.update_clock()
    clock[0] = 1000
    assert run.snapshot()['activeElapsedSeconds'] == pytest.approx(1)


def test_threaded_benchmark_timeline_stays_within_measured_runtime(engine, monkeypatch, profile):
    import time
    client = Mock()
    def put(**_):
        time.sleep(0.002)
        return {'ResponseMetadata': {'RetryAttempts': 0}}
    client.put_object.side_effect = put
    monkeypatch.setattr(engine, '_build_client', lambda _: client)
    started = time.monotonic()
    result = engine._start_benchmark({'profile': profile, 'config': {
        'bucketName': 'fixture', 'testMode': 'operation-count', 'operationCount': 16,
        'concurrentThreads': 4, 'objectCount': 16, 'workloadType': 'write-only',
        'objectSizes': [8], 'randomData': False, 'reducedLogging': True}})
    run = engine._BENCHMARKS[result['id']]
    for thread in run.threads:
        thread.join(timeout=2)
    wall_seconds = time.monotonic() - started
    snapshot = run.snapshot()
    assert snapshot['status'] == 'completed'
    assert snapshot['processedCount'] == 16
    timeline = snapshot['resultSummary']['latencyTimeline']
    assert len(timeline) == 16
    assert [r['elapsedMs'] for r in timeline] == [r['elapsedMs'] for r in snapshot['history']]
    assert 0 < max(r['elapsedMs'] for r in timeline) <= snapshot['activeElapsedSeconds'] * 1000
    assert snapshot['activeElapsedSeconds'] <= wall_seconds
    expected_rate = round(16 / snapshot['activeElapsedSeconds'], 1)
    assert snapshot['resultSummary']['detailMetrics']['averageOpsPerSecond'] == expected_rate
    assert snapshot['throughputOpsPerSecond'] == expected_rate


def test_benchmark_bounded_history_full_csv_totals_and_restart(engine, monkeypatch, profile, tmp_path):
    state = {
        'id': 'bench-history', 'status': 'paused', 'profile': {}, 'history': [],
        'activeElapsedSeconds': 10.02, 'benchmarkPrefix': 'fixture/',
        'config': {'bucketName': 'fixture', 'testMode': 'operation-count',
                   'operationCount': 10026, 'concurrentThreads': 1,
                   'objectCount': 1, 'objectSizes': [8], 'workloadType': 'write-only',
                   'randomData': False, 'csvOutputPath': str(tmp_path / 'full.csv'),
                   'jsonOutputPath': str(tmp_path / 'summary.json'),
                   'logFilePath': str(tmp_path / 'run.log')},
    }
    def row(index):
        return {'timestamp': '2026-10-02T00:00:00+00:00', 'elapsedMs': float(index),
                'second': index // 1000 + 1, 'operation': 'PUT', 'operationCount': 1,
                'latencyMs': 0.5, 'sizeBytes': 8, 'bytesTransferred': 8,
                'success': index > 2, 'checksumState': 'validated_failure' if index <= 2 else 'not_used',
                'retryCount': 3 if index <= 2 else 0, 'key': f'exact,"key\n{index}'}
    engine._prepare_benchmark_history(state)
    engine._append_benchmark_history(state, [row(index) for index in range(1, 10021)])
    engine._refresh_benchmark_snapshot(state)
    engine._write_benchmark_state(state)
    engine._persist_benchmark_outputs(state)
    assert len(state['history']) == 10000
    assert state['history'][0]['sequence'] == 21
    metrics = state['resultSummary']['detailMetrics']
    assert metrics['errorCount'] == 2 and metrics['retryCount'] == 6
    assert metrics['historyRecordCount'] == 10020
    assert metrics['retainedHistoryRecords'] == 10000
    assert metrics['latencyPercentileScope'] == 'recent-records'
    assert state['resultSummary']['totalOperations'] == 10020
    assert state['resultSummary']['checksumStats']['validated_failure'] == 2
    assert metrics['totalBytesTransferred'] == 10020 * 8
    # Simulate a worker finishing after its last JSON checkpoint, then restarting.
    engine._append_benchmark_history(state, [row(index) for index in range(10021, 10026)])
    restored = engine._read_benchmark_state('bench-history')
    assert restored['processedCount'] == 10025
    assert len(restored['history']) == 10000
    assert restored['history'][0]['elapsedMs'] == 26
    assert restored['history'][-1]['elapsedMs'] == 10025
    assert restored['historyTotals']['errorCount'] == 2
    assert restored['historyTotals']['retryCount'] == 6
    assert restored['activeElapsedSeconds'] >= 10.025
    exported = (tmp_path / 'full.csv').read_bytes()
    engine._persist_benchmark_outputs(restored)
    assert (tmp_path / 'full.csv').read_bytes() == exported
    with (tmp_path / 'full.csv').open(newline='') as source:
        rows = list(csv.DictReader(source))
    assert len(rows) == 10025
    assert rows[0]['key'] == 'exact,"key\n1'
    assert [int(r['sequence']) for r in rows] == list(range(1, 10026))
    assert float(rows[-1]['elapsedMs']) == 10025
    # Explicit resume authorizes only the single remaining operation.
    client = Mock()
    client.put_object.return_value = {'ResponseMetadata': {'RetryAttempts': 1}}
    monkeypatch.setattr(engine, '_build_client', lambda _: client)
    engine._resume_benchmark({'runId': 'bench-history', 'profile': profile})
    run = engine._BENCHMARKS['bench-history']
    for thread in run.threads:
        thread.join(timeout=2)
    final = run.snapshot()
    assert final['status'] == 'completed'
    assert final['processedCount'] == 10026
    assert final['historyTotals']['retryCount'] == 7
    assert final['historyTotals']['operationsByType'] == {'PUT': 10026}
    assert len(final['history']) == 10000
    assert final['history'][-1]['sequence'] == 10026
    assert final['history'][-1]['elapsedMs'] <= final['activeElapsedSeconds'] * 1000
    assert client.put_object.call_count == 1
    with (tmp_path / 'full.csv').open(newline='') as source:
        assert sum(1 for _ in csv.DictReader(source)) == 10026
    saved = json.loads(engine._benchmark_state_path('bench-history').read_text())
    assert len(saved['history']) == 10000
    assert 'SECRET-' not in json.dumps(saved)


def test_benchmark_rejects_truncated_full_csv_after_restart(engine, tmp_path):
    state = {'id': 'bench-truncated', 'config': {'csvOutputPath': str(tmp_path / 'full.csv')},
             'history': [], 'activeElapsedSeconds': 0}
    engine._prepare_benchmark_history(state)
    engine._append_benchmark_history(state, [{'operation': 'PUT', 'operationCount': 1, 'elapsedMs': 1}])
    engine._write_benchmark_state(state)
    with (tmp_path / 'full.csv').open('a') as output:
        output.write('2,incomplete')
    with pytest.raises(engine.SidecarError, match='CSV history is incomplete'):
        engine._read_benchmark_state('bench-truncated')


def azure_block_client(engine, monkeypatch, payload):
    client = Mock()
    client.blob_path.side_effect = lambda bucket, key: '/' + bucket + '/' + key
    blocks, committed, heads = {}, [], {}
    def request(method, path, query=None, headers=None, body=None):
        query, headers = query or {}, headers or {}
        if method == 'HEAD':
            if not heads:
                raise engine.SidecarError('unknown', 'missing', {'httpStatus': 404})
            return 200, dict(heads), b''
        if method == 'GET' and query.get('comp') == 'blocklist':
            xml = '<BlockList><UncommittedBlocks>' + ''.join(f'<Block><Name>{key}</Name><Size>{len(value)}</Size></Block>' for key, value in blocks.items()) + '</UncommittedBlocks></BlockList>'
            return 200, {}, xml.encode()
        if query.get('comp') == 'block':
            data = body.read() if hasattr(body, 'read') else body
            assert headers['Content-MD5'] == base64.b64encode(hashlib.md5(data).digest()).decode()
            blocks[query['blockid']] = data
            return 201, {}, b''
        if query.get('comp') == 'blocklist':
            import xml.etree.ElementTree as ET
            import re
            assert all(re.fullmatch(r'[A-Za-z_][A-Za-z0-9_]*', name[10:])
                       for name in headers if name.lower().startswith('x-ms-meta-'))
            ids = [node.text for node in ET.fromstring(body)]
            committed.append(b''.join(blocks[key] for key in ids))
            assert headers.get('If-None-Match') == '*'
            heads.update({key: value for key, value in headers.items() if key.startswith('x-ms-meta-')})
            heads['Content-Length'] = str(len(committed[-1]))
            heads['x-ms-version-id'] = 'committed-version'
            return 201, {'x-ms-version-id': 'committed-version'}, b''
        raise AssertionError((method, path, query))
    client.request.side_effect = request
    monkeypatch.setattr(engine, '_build_azure_client', lambda _: client)
    return client, blocks, committed, heads


def test_azure_blocks_reconcile_and_resume_to_conditional_commit(engine, profile, monkeypatch, tmp_path):
    payload = azure_profile(profile)
    client, blocks, committed, heads = azure_block_client(engine, monkeypatch, payload)
    file = tmp_path / 'source.bin'
    data = b'A' * (8 * 1024**2) + b'last'
    file.write_bytes(data)
    state = engine._storage_action({'action': 'startResumableUpload', 'profile': payload, 'bucketName': 'container',
                                   'key': 'exact /blob ', 'filePath': str(file), 'maxParts': 1})
    assert state['status'] == 'paused' and state['completedBytes'] == 8 * 1024**2
    state = engine._storage_action({'action': 'resumeUpload', 'profile': payload, 'recoveryId': state['id']})
    assert state['status'] == 'completed' and committed == [data]
    assert len(blocks) == 2 and state['versionId'] == 'committed-version'
    uploads = [call for call in client.request.call_args_list if call.kwargs.get('query', {}).get('comp') == 'block']
    assert len(uploads) == 2
    checkpoint = (tmp_path / 'recovery' / (state['id'] + '.json')).read_text()
    assert payload['secretKey'] not in checkpoint and profile['sessionToken'] not in checkpoint


def test_azure_uncertain_commit_is_verified_never_reissued(engine, profile, monkeypatch, tmp_path):
    payload = azure_profile(profile)
    client, blocks, committed, heads = azure_block_client(engine, monkeypatch, payload)
    original = client.request.side_effect
    def request(*args, **kwargs):
        if kwargs.get('query', {}).get('comp') == 'blocklist' and args[0] == 'PUT':
            raise TimeoutError('ambiguous')
        return original(*args, **kwargs)
    client.request.side_effect = request
    file = tmp_path / 'source.bin'
    file.write_bytes(b'contents')
    state = engine._storage_action({'action': 'startResumableUpload', 'profile': payload, 'bucketName': 'container',
                                   'key': 'blob', 'filePath': str(file)})
    assert state['status'] == 'completionUnknown'
    calls = client.request.call_count
    result = engine._storage_action({'action': 'resumeUpload', 'profile': payload, 'recoveryId': state['id']})
    assert result['status'] == 'completionUnknown'
    assert client.request.call_count == calls + 1  # Only a HEAD verification.
    assert not committed


def test_azure_abort_keeps_committed_blob_and_other_uploads(engine, profile, monkeypatch, tmp_path):
    payload = azure_profile(profile)
    client, blocks, committed, heads = azure_block_client(engine, monkeypatch, payload)
    file = tmp_path / 'source.bin'
    file.write_bytes(b'A' * (8 * 1024**2 + 1))
    state = engine._storage_action({'action': 'startResumableUpload', 'profile': payload, 'bucketName': 'container',
                                   'key': 'blob', 'filePath': str(file), 'maxParts': 1})
    client.request.reset_mock()
    aborted = engine._storage_action({'action': 'abortUpload', 'profile': payload, 'recoveryId': state['id']})
    assert aborted['status'] == 'aborted' and not client.request.called
    assert len(blocks) == 1 and not committed


def test_management_policy_read_compare_write_and_identity_guard(engine, profile, monkeypatch):
    payload = azure_profile(profile, 'azureDefault')
    profile_model = engine._parse_profile(payload)
    responses = []
    current = {'rules': []}
    def request(method, url, **kwargs):
        assert url.startswith('https://management.azure.com/subscriptions/')
        assert kwargs['headers']['Authorization'] == 'Bearer SECRET-TOKEN'
        assert kwargs['redirect'] is False and kwargs['retries'] is False
        nonlocal current
        if method == 'PUT':
            current = json.loads(kwargs['body'])['properties']['policy']
        response = SimpleNamespace(status=200, data=json.dumps({'properties': {'policy': current}, 'etag': '"etag"'}).encode(),
                                   headers={}, release_conn=Mock())
        responses.append((method, response))
        return response
    client = SimpleNamespace(profile=profile_model, account='fixture', base_url=payload['endpointUrl'],
                             credential=SimpleNamespace(get_token=lambda _: SimpleNamespace(token='SECRET-TOKEN')),
                             pool=SimpleNamespace(request=request))
    monkeypatch.setattr(engine, '_build_azure_client', lambda _: client)
    params = {'profile': payload, 'accountResourceId': '/subscriptions/123/resourceGroups/rg/providers/Microsoft.Storage/storageAccounts/fixture'}
    desired = {'rules': [{'name': 'tier', 'enabled': True, 'type': 'Lifecycle', 'definition': {'filters': {'prefixMatch': ['container/'], 'blobTypes': ['blockBlob']},
                           'actions': {'baseBlob': {'tierToCool': {'daysAfterModificationGreaterThan': 30}}}}}]}
    result = engine._storage_action({**params, 'action': 'putAccountLifecycle', 'policy': desired, 'expectedPolicy': {'rules': []}})
    assert result['policy'] == desired
    assert [method for method, _ in responses] == ['GET', 'PUT', 'GET']
    assert all(response.release_conn.called for _, response in responses)
    with pytest.raises(engine.SidecarError, match='configured Azure storage account'):
        engine._storage_action({**params, 'action': 'getAccountLifecycle', 'accountResourceId': params['accountResourceId'].replace('/fixture', '/otheraccount')})


def test_adls_rename_preserves_exact_key_and_uses_conditional_no_overwrite(engine, profile, monkeypatch):
    payload = azure_profile(profile)
    blob, dfs = Mock(), Mock()
    blob.request.return_value = (200, {'x-ms-is-hns-enabled': 'true'}, b'')
    dfs.blob_path.side_effect = lambda bucket, key=None: '/' + bucket + ('/' + engine.quote(key, safe='/') if key is not None else '')
    dfs.request.return_value = (201, {'ETag': 'new'}, b'')
    monkeypatch.setattr(engine, '_build_azure_client', lambda p: dfs if '.dfs.' in p.endpoint_url else blob)
    result = engine._storage_action({'profile': payload, 'action': 'renameDirectory', 'bucketName': 'container',
                                    'key': 'directory with spaces', 'destinationKey': 'other exact ', 'expectedETag': '"old"'})
    assert result['renamed']
    request = dfs.request.call_args
    assert request.args[1] == '/container/other%20exact%20'
    assert request.kwargs['headers']['x-ms-source-if-match'] == '"old"'
    assert request.kwargs['headers']['If-None-Match'] == '*'
    assert request.kwargs['headers']['x-ms-rename-source'] == '/container/directory%20with%20spaces'


def test_azure_delegation_key_presign_is_scoped_and_not_persisted(engine, profile, monkeypatch, tmp_path):
    payload = azure_profile(profile, 'azureDefault')
    key = b'delegation secret'
    delegated = {'SignedOid': 'oid', 'SignedTid': 'tid', 'SignedStart': '2026-01-01T00:00:00Z',
                 'SignedExpiry': '2099-01-01T00:00:00Z', 'SignedService': 'b', 'SignedVersion': '2023-11-03',
                 'Value': base64.b64encode(key).decode()}
    xml = '<UserDelegationKey>' + ''.join(f'<{k}>{v}</{k}>' for k, v in delegated.items()) + '</UserDelegationKey>'
    client = SimpleNamespace(profile=engine._parse_profile(payload), credential=object(), key=b'', account='fixture', scheme='https',
                             base_url=payload['endpointUrl'], blob_path=lambda b, k: '/' + b + '/' + k,
                             request=Mock(return_value=(200, {}, xml.encode())))
    monkeypatch.setattr(engine, '_build_azure_client', lambda _: client)
    result = engine._storage_action({'action': 'presignVersion', 'profile': payload, 'bucketName': 'container', 'key': 'blob', 'versionId': 'version'})
    query = {k: v[0] for k, v in parse_qs(urlparse(result['url']).query).items()}
    fields = ['r', query['st'], query['se'], '/blob/fixture/container/blob', 'oid', 'tid', delegated['SignedStart'], delegated['SignedExpiry'],
              'b', '2023-11-03', '', '', '', '', 'https', '2023-11-03', 'bv', 'version', '', '', '', '', '', '']
    assert query['sig'] == base64.b64encode(hmac.new(key, '\n'.join(fields).encode(), hashlib.sha256).digest()).decode()
    assert query['sp'] == 'r' and query['sr'] == 'bv' and query['skoid'] == 'oid'
    assert not list(tmp_path.rglob('*.json'))
