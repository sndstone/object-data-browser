import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:s3_browser_crossplat/models/domain_models.dart';
import 'package:s3_browser_crossplat/models/storage_presets.dart';
import 'package:s3_browser_crossplat/controllers/app_controller.dart';
import 'package:s3_browser_crossplat/services/bucket_copy_journal.dart';
import 'package:s3_browser_crossplat/services/app_state_repository.dart';
import 'app_state_repository_test.dart' show RecordingProfileSecretStore;

const profile = EndpointProfile(
    id: 'p',
    name: 'Example',
    endpointUrl: 'https://s3.amazonaws.com',
    region: 'us-east-1',
    accessKey: '',
    secretKey: '',
    pathStyle: false,
    verifyTls: true,
    endpointType: EndpointProfileType.awsS3);
void main() {
  test(
      'access presets use partition, preserve custom statements, replace own grants',
      () {
    final p = profile.copyWith(region: 'cn-north-1');
    final raw = StoragePresets.access(
        profile: p,
        bucket: 'reports',
        preset: 'read',
        principal: 'arn:aws-cn:iam::123456789012:role/Reader',
        prefix: 'team/',
        existing:
            '{"Version":"2012-10-17","Statement":[{"Sid":"CustomDeny","Effect":"Deny","Action":"s3:DeleteObject","Resource":"*","Principal":"*"}]}');
    final doc = jsonDecode(raw) as Map;
    expect(doc['Statement'], hasLength(3));
    expect(doc['Statement'][1]['Resource'], 'arn:aws-cn:s3:::reports/team/*');
    expect(doc['Statement'][2]['Condition']['StringLike']['s3:prefix'],
        ['team/*']);
    final private = jsonDecode(StoragePresets.access(
        profile: p, bucket: 'reports', preset: 'private', existing: raw));
    expect(private['Statement'], hasLength(1));
    expect(private['Statement'][0]['Sid'], 'CustomDeny');
    expect(awsEndpointForRegion('cn-north-1'), endsWith('amazonaws.com.cn'));
  });
  test('preset rejects unintentional wildcard principals and bucket resources',
      () {
    expect(
        () => StoragePresets.access(
            profile: profile,
            bucket: 'reports',
            preset: 'readWrite',
            principal: '*'),
        throwsFormatException);
    expect(
        () => StoragePresets.access(
            profile: profile, bucket: '*', preset: 'publicRead'),
        throwsFormatException);
  });
  test(
      'lifecycle merge retains complex filters, dates and newer-version retention',
      () {
    final rule = {
      'ID': 'existing',
      'Status': 'Enabled',
      'Filter': {
        'And': {
          'Prefix': 'logs/',
          'Tags': [
            {'Key': 'keep', 'Value': 'yes'}
          ],
          'ObjectSizeGreaterThan': 1024
        }
      },
      'Expiration': {'Date': '2030-01-01T00:00:00Z'},
      'NoncurrentVersionExpiration': {
        'NoncurrentDays': 90,
        'NewerNoncurrentVersions': 5
      }
    };
    final raw = StoragePresets.lifecycle(
        profile: profile,
        preset: 'multipart',
        existing: jsonEncode({
          'Rules': [rule],
          'custom': 'preserve'
        }));
    final doc = jsonDecode(raw);
    expect(doc['Rules'][0], rule);
    expect(doc['custom'], 'preserve');
    expect(
        jsonDecode(StoragePresets.lifecycle(
            profile: profile, preset: 'multipart', existing: raw))['Rules'],
        hasLength(2));
    expect(() => StoragePresets.lifecycle(profile: profile, preset: 'history'),
        throwsFormatException);
  });
  test('compatible tiering requires explicitly configured storage classes', () {
    final p = profile.copyWith(
        endpointType: EndpointProfileType.s3Compatible,
        connection: const ConnectionOptions(storageClasses: ['COLD']));
    expect(() => StoragePresets.lifecycle(profile: p, preset: 'archive'),
        throwsFormatException);
    expect(
        jsonDecode(StoragePresets.lifecycle(
            profile: p,
            preset: 'custom',
            storageClass: 'COLD',
            days: 10))['Rules'][0]['Transitions'][0]['StorageClass'],
        'COLD');
    expect(
        () => StoragePresets.lifecycle(
            profile: p, preset: 'custom', storageClass: 'UNKNOWN'),
        throwsFormatException);
  });
  test('embedded SAS is secured and absent from metadata and exports',
      () async {
    final dir = await Directory.systemTemp.createTemp('sas-persistence-');
    addTearDown(() => dir.delete(recursive: true));
    final store = RecordingProfileSecretStore({});
    final repo = LocalAppStateRepository(
        secretStore: store,
        applicationSupportDirectoryProvider: () async => dir);
    const token = 'sv=2025-01-05&sig=fictional-test-signature&sp=rl';
    final p = profile.copyWith(
        endpointType: EndpointProfileType.azureBlob,
        endpointUrl: 'https://account.blob.core.windows.net?$token');
    await repo.saveState(
        settings: AppSettings.fromJson({}),
        profiles: [p],
        selectedProfileId: 'p',
        allowCredentialStoreRecovery: true);
    final exported = await repo
        .exportProfiles(profiles: [p], path: '${dir.path}/export.json');
    expect(await exported.readAsString(),
        isNot(contains('fictional-test-signature')));
    final loaded = await repo.loadState();
    expect(loaded!.profiles.single.sessionToken, token);
    expect(loaded.profiles.single.connection.authMode, 'azureSas');
    expect(loaded.profiles.single.endpointUrl, isNot(contains('?')));
    expect(store.values['profiles.credentials.v2'],
        contains('fictional-test-signature'));
    for (final entry in dir.listSync(recursive: true).whereType<File>()) {
      expect(await entry.readAsString(),
          isNot(contains('fictional-test-signature')));
    }
  });
  test(
      'bucket checkpoint is atomic, bounded to current page and rejects mismatched jobs',
      () async {
    final dir = await Directory.systemTemp.createTemp('copy-journal-');
    addTearDown(() => dir.delete(recursive: true));
    final journal = BucketCopyJournal(File('${dir.path}/job.json'));
    final config = {'sourceProfileId': 'a', 'destinationProfileId': 'b'};
    await journal.write({
      'configuration': config,
      'cursor': {'value': 'next', 'hasMore': true},
      'completed': ['exact key/'],
      'inFlight': 'pending'
    });
    expect((await journal.read(config))!['completed'], ['exact key/']);
    await expectLater(
        journal.read({'sourceProfileId': 'other'}), throwsStateError);
    await journal.clear();
    expect(await journal.read(config), isNull);
  });
  test(
      'lifecycle rejects expiration before tiering and preserves scopes when disabled',
      () {
    expect(
        () => StoragePresets.lifecycle(
            profile: profile, preset: 'tier', expirationDays: 20),
        throwsFormatException);
    final raw = StoragePresets.lifecycle(
        profile: profile,
        preset: 'tier',
        prefix: 'images/',
        tags: {'keep': 'no'},
        minimumBytes: 1024,
        maximumBytes: 1048576);
    final original = jsonDecode(raw)['Rules'][0] as Map;
    expect(original['Filter']['And']['Tags'], [
      {'Key': 'keep', 'Value': 'no'}
    ]);
    final disabled = jsonDecode(StoragePresets.lifecycle(
        profile: profile,
        preset: 'tier',
        existing: raw,
        enabled: false))['Rules'][0];
    expect(disabled, {...original, 'Status': 'Disabled'});
    expect(
        () => StoragePresets.lifecycle(
            profile: profile, preset: 'multipart', tags: {'x': 'y'}),
        throwsFormatException);
  });
}
