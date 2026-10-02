"""Real emulator checks for the reference adapter's new durable workflows."""
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import sys


def qualify(root, folder, env):
    import boto3
    from botocore.config import Config
    source = root / 'engines/python/src/main.py'
    spec = importlib.util.spec_from_file_location('local_qualification_engine', source)
    engine = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = engine
    spec.loader.exec_module(engine)
    engine._runtime_dir = lambda: folder / 'runtime'
    engine._emit_transfer_event = lambda _: None
    os.environ['OBJECT_BROWSER_TRANSFER_DIR'] = str(folder / 'recovery')
    s3 = {'id': 'local-s3', 'endpointType': 's3Compatible', 'endpointUrl': env['LOCAL_STORAGE_S3_ENDPOINT'], 'region': 'us-east-1', 'accessKey': env['LOCAL_STORAGE_S3_ACCESS'], 'secretKey': env['LOCAL_STORAGE_S3_SECRET'], 'pathStyle': True}
    azure = {'id': 'local-azure', 'endpointType': 'azureBlob', 'endpointUrl': env['LOCAL_STORAGE_AZURE_ENDPOINT'], 'accessKey': env['LOCAL_STORAGE_AZURE_ACCOUNT'], 'secretKey': env['LOCAL_STORAGE_AZURE_KEY']}
    client = boto3.client('s3', endpoint_url=s3['endpointUrl'], aws_access_key_id=s3['accessKey'], aws_secret_access_key=s3['secretKey'], region_name='us-east-1', config=Config(s3={'addressing_style': 'path'}))
    for bucket in ['history-source', 'history-destination']:
        client.create_bucket(Bucket=bucket)
        client.put_bucket_versioning(Bucket=bucket, VersioningConfiguration={'Status': 'Enabled'})
    first = client.put_object(Bucket='history-source', Key='history/key', Body=b'first', Metadata={'source': 'preserved'})['VersionId']
    client.put_object_tagging(Bucket='history-source', Key='history/key', VersionId=first, Tagging={'TagSet': [{'Key': 'phase', 'Value': 'first'}]})
    client.put_object(Bucket='history-source', Key='history/key', Body=b'second')
    client.delete_object(Bucket='history-source', Key='history/key')
    client.put_object(Bucket='history-source', Key='live', Body=b'live')
    refs = {'sourceProfile': s3, 'destinationProfile': s3, 'sourceBucketName': 'history-source', 'destinationBucketName': 'history-destination'}
    call = lambda action, **args: engine._storage_action({'action': action, 'profile': s3, **args})
    plan = call('planHistoryCopy', **refs)
    assert plan['versionCount'] == 3 and plan['deleteMarkerCount'] == 1, plan
    run = plan
    for _ in range(20):
        run = call('resumeHistoryCopy', **refs, recoveryId=plan['recoveryId'], maxEntries=1)
        if run['status'] == 'completed':
            break
        assert run['status'] == 'running', run
    assert run['status'] == 'completed' and run['completedCount'] == 4, run
    versions = client.list_object_versions(Bucket='history-destination')
    assert len(versions['Versions']) == 3 and len(versions['DeleteMarkers']) == 1
    assert versions['DeleteMarkers'][0]['IsLatest']
    bodies = {client.get_object(Bucket='history-destination', Key=v['Key'], VersionId=v['VersionId'])['Body'].read() for v in versions['Versions']}
    assert bodies == {b'first', b'second', b'live'}
    # A lifecycle copy is reviewed as a plan and applied only after content.
    lifecycle = {'Rules': [{'ID': 'local-tier', 'Status': 'Enabled', 'Filter': {'Prefix': 'cold/'}, 'Expiration': {'Days': 365}}]}
    client.put_bucket_lifecycle_configuration(Bucket='history-source', LifecycleConfiguration=lifecycle)
    client.put_bucket_tagging(Bucket='history-source', Tagging={'TagSet': [{'Key': 'fixture', 'Value': 'local'}]})
    configuration = call('planBucketConfigurationCopy', **refs, sections=['lifecycle', 'tags'])
    assert not configuration['blocked'], configuration
    applied = call('applyBucketConfigurationCopy', **refs, planId=configuration['planId'])
    assert applied['status'] == 'completed', applied
    assert client.get_bucket_lifecycle_configuration(Bucket='history-destination')['Rules'] == lifecycle['Rules']
    payload = bytes(range(251)) * 15000
    client.put_object(Bucket='history-source', Key='download.bin', Body=payload)
    download = call('startResumableDownload', bucketName='history-source', key='download.bin', destinationDirectory=str(folder), multipartChunkMiB=1, maxRanges=1)
    assert download['status'] == 'paused', download
    while download['status'] == 'paused':
        download = call('resumeDownload', recoveryId=download['recoveryId'], maxRanges=1)
    assert download['status'] == 'completed', download
    assert Path(download['filePath']).read_bytes() == payload
    # Azure block upload recovery followed by a range-checkpointed download.
    call('ensureBucket', profile=azure, bucketName='recovery')
    local = folder / 'azure-source.bin'
    local.write_bytes(payload * 4)
    upload = call('startResumableUpload', profile=azure, bucketName='recovery', key='recovered.bin', filePath=str(local), multipartChunkMiB=5, maxParts=1, conflictPolicy='fail')
    assert upload['status'] == 'paused', upload
    while upload['status'] == 'paused':
        upload = call('resumeUpload', profile=azure, recoveryId=upload['recoveryId'], maxParts=1)
    assert upload['status'] == 'completed', upload
    retrieved = call('startResumableDownload', profile=azure, bucketName='recovery', key='recovered.bin', destinationDirectory=str(folder), multipartChunkMiB=1, maxRanges=1)
    while retrieved['status'] == 'paused':
        retrieved = call('resumeDownload', profile=azure, recoveryId=retrieved['recoveryId'], maxRanges=2)
    assert retrieved['status'] == 'completed', retrieved
    assert hashlib.sha256(Path(retrieved['filePath']).read_bytes()).digest() == hashlib.sha256(local.read_bytes()).digest()
    for path in (folder / 'recovery').rglob('*.json'):
        contents = path.read_text()
        for secret in (s3['accessKey'], s3['secretKey'], azure['secretKey']):
            assert secret not in contents, 'Credential persisted in recovery state'
    print('Local reference adapter: version history, configuration review, S3 download recovery and Azure block/range recovery passed.', flush=True)
