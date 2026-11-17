import 'google_cloud_storage_fixture.dart';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:s3_browser_crossplat/controllers/app_controller.dart';
import 'package:s3_browser_crossplat/models/domain_models.dart';
import 'package:s3_browser_crossplat/models/google_service_account.dart';
import 'package:s3_browser_crossplat/models/provider_templates.dart';
import 'package:s3_browser_crossplat/services/android_engine_service.dart';
import 'package:s3_browser_crossplat/services/ios_engine_service.dart';
import 'package:s3_browser_crossplat/services/mock_engine_service.dart';
import 'package:s3_browser_crossplat/services/mobile_storage_admin.dart';
import 'package:s3_browser_crossplat/services/object_encryption.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('native Cloud Storage round trips strictly and old state stays S3', () {
    final profile = googleProfile();
    expect(profile.toJson()['endpointType'], 'googleCloudStorage');
    expect(EndpointProfile.fromJson(profile.toJson()), profile);
    expect(profile.endpointType.displayLabel, 'Google Cloud Storage');
    for (final value in [
      null,
      'futureProvider',
      'GoogleCloudStorage',
      'googlecloudstorage'
    ]) {
      expect(EndpointProfile.fromJson({'endpointType': value}).endpointType,
          EndpointProfileType.s3Compatible);
    }
    for (final type in [
      EndpointProfileType.awsS3,
      EndpointProfileType.azureBlob,
      EndpointProfileType.s3Compatible
    ]) {
      expect(
          EndpointProfile.fromJson(
                  profile.copyWith(endpointType: type).toJson())
              .endpointType,
          type);
    }
  });

  test('service-account validation reports fields without echoing key material',
      () {
    final identity = GoogleServiceAccount.parse(dummyServiceAccountJson());
    expect(identity.email, 'throwaway@example.invalid');
    expect(identity.projectId, 'throwaway-project');
    for (final entry in <String, String>{
      'not JSON with secret text': 'Enter a valid JSON service-account key.',
      '[]': 'The key must have type "service_account".',
      '{"type":"authorized_user"}': 'The key must have type "service_account".',
      '{"type":"service_account"}':
          'The service-account key is missing client_email.',
    }.entries) {
      expect(
          () => GoogleServiceAccount.parse(entry.key),
          throwsA(isA<FormatException>()
              .having((e) => e.message, 'safe error', entry.value)));
    }
    for (final field in ['client_email', 'private_key', 'project_id']) {
      for (final invalid in [null, '', '  ', 42]) {
        final key = jsonDecode(dummyServiceAccountJson()) as Map;
        key[field] = invalid;
        expect(
            () => GoogleServiceAccount.parse(jsonEncode(key)),
            throwsA(isA<FormatException>().having(
                (e) => e.message,
                'missing field',
                'The service-account key is missing $field.')));
      }
    }
  });

  test('native normalization preserves JSON and optional endpoint and location',
      () {
    final normalized = normalizeEndpointProfile(googleProfile().copyWith(
      pathStyle: true,
      signerOverride: 's3',
      sessionToken: 'old-token',
      connection: const ConnectionOptions(
          authMode: 'assumeRole',
          roleArn: 'old-role',
          requesterPays: true,
          knownBucket: 'known'),
      uploadEncryption:
          const ObjectEncryption(mode: ObjectEncryptionMode.sseS3),
    ));
    expect(normalized.endpointUrl, isEmpty);
    expect(normalized.region, isEmpty);
    expect(normalized.secretKey, dummyServiceAccountJson());
    expect(normalized.pathStyle, isFalse);
    expect(normalized.signerOverride, isNull);
    expect(normalized.sessionToken, isNull);
    expect(normalized.uploadEncryption, isNull);
    expect(normalized.connection.authMode, 'static');
    expect(normalized.connection.requesterPays, isFalse);
    expect(normalized.connection.knownBucket, 'known');
    final custom = normalizeEndpointProfile(googleProfile()
        .copyWith(endpointUrl: 'http://localhost:4443/', region: ' EU '));
    expect(custom.endpointUrl, 'http://localhost:4443');
    expect(custom.verifyTls, isFalse);
    expect(custom.region, 'EU');
  });

  test('Cloud Storage eligibility uses provider list and Python or Go fallback',
      () {
    final controller = AppController(
        engineService: MockEngineService(),
        initialSettings: AppSettings.fromJson({}),
        initialProfiles: const []);
    addTearDown(controller.dispose);
    for (final id in ['python', 'go', 'rust', 'java']) {
      expect(controller.supportsProfile(googleProfile(), engineId: id),
          ['python', 'go'].contains(id));
    }
    controller.engines = const [
      EngineDescriptor(
          id: 'python',
          label: 'Old Python',
          language: 'Python',
          version: 'old',
          available: true,
          desktopSupported: true,
          mobileSupported: false,
          endpointTypes: ['s3Compatible'])
    ];
    expect(controller.supportsProfile(googleProfile(), engineId: 'python'),
        isFalse);
  });

  test(
      'mobile-only controller never lists or probes a native Cloud Storage profile',
      () async {
    final engine = _MobileOnlyEngine();
    final controller = AppController(
        engineService: engine,
        initialSettings: AppSettings.fromJson({'defaultEngineId': 'go'}),
        initialProfiles: [googleProfile()]);
    addTearDown(controller.dispose);
    await controller.initialize();
    expect(controller.bannerMessage,
        'Google Cloud Storage profiles are available on desktop in this version');
    await controller.setSelectedProfileById('gcs');
    await controller.testProfileDraft(googleProfile());
    expect(engine.requests, 0);
  });

  test('native capability gates honor reports and default conservatively',
      () async {
    final controller = AppController(
        engineService: MockEngineService(),
        initialSettings: AppSettings.fromJson({}),
        initialProfiles: const []);
    addTearDown(controller.dispose);
    controller.selectedProfile = googleProfile();
    for (final key in [
      'bucket.lifecycle',
      'bucket.policy',
      'bucket.cors',
      'bucket.encryption',
      'bucket.tagging',
      'object.tags',
      'storage.admin',
      'tools',
      'benchmark',
      'object.encryption.sse-s3'
    ]) {
      expect(controller.profileCapability(key), isFalse, reason: key);
    }
    for (final key in [
      'bucket.versioning',
      'object.versions',
      'object.presign',
      'object.copy_move',
      'transfers'
    ]) {
      expect(controller.profileCapability(key), isTrue, reason: key);
    }
    controller.capabilities = const [
      CapabilityDescriptor(
          key: 'bucket.lifecycle',
          label: 'Lifecycle',
          state: CapabilityState.supported),
      CapabilityDescriptor(
          key: 'object.presign',
          label: 'Signed links',
          state: CapabilityState.unsupported,
          reason: 'No signing support')
    ];
    expect(controller.profileCapability('bucket.lifecycle'), isTrue);
    expect(controller.profileCapability('object.presign'), isFalse);
    expect(controller.profileCapabilityReason('object.presign'),
        'No signing support');
    await controller.startBenchmark();
    expect(controller.benchmarkRun, isNull);
    await controller.runPutTestDataTool();
    await controller.runDeleteAllTool();
    expect(controller.browserTasks, isEmpty);
    expect(() => validateObjectEncryption(googleProfile(), {'mode': 'sse-s3'}),
        throwsA(isA<EngineException>()));
  });

  test('native capability gates leave existing S3 and Azure behavior intact',
      () {
    final controller = AppController(
        engineService: MockEngineService(),
        initialSettings: AppSettings.fromJson({}),
        initialProfiles: const []);
    addTearDown(controller.dispose);
    controller.capabilities = const [
      CapabilityDescriptor(
          key: 'storage.admin',
          label: 'Admin',
          state: CapabilityState.unsupported)
    ];
    for (final type in [
      EndpointProfileType.s3Compatible,
      EndpointProfileType.awsS3,
      EndpointProfileType.azureBlob
    ]) {
      controller.selectedProfile = googleProfile().copyWith(endpointType: type);
      expect(controller.profileCapability('storage.admin'), isTrue);
    }
  });

  test('generation deletion uses the exact-version core operation', () async {
    final engine = _GenerationEngine();
    final controller = AppController(
        engineService: engine,
        initialSettings: AppSettings.fromJson({}),
        initialProfiles: [googleProfile()]);
    addTearDown(controller.dispose);
    controller.activeEngineId = 'go';
    controller.selectedProfile = googleProfile();
    controller.selectedBucket = const BucketSummary(
        name: 'fixture',
        region: 'EU',
        objectCountHint: 0,
        versioningEnabled: true);
    await controller.deleteGeneration(ObjectVersionEntry(
        key: 'object',
        versionId: '123456789',
        modifiedAt: DateTime(2026),
        latest: false,
        deleteMarker: false,
        size: 1));
    expect(engine.deleted.single.key, 'object');
    expect(engine.deleted.single.versionId, '123456789');
    expect(engine.engine, 'go');
  });

  test('native and HMAC templates remain distinct', () {
    final native = providerTemplateById('google-cloud-storage-native')!;
    final hmac = providerTemplateById('google-cloud-storage')!;
    expect(
        native.displayName, 'Google Cloud Storage (native, service account)');
    expect(native.endpointType, EndpointProfileType.googleCloudStorage);
    expect(hmac.displayName, 'Google Cloud Storage (S3-compatible, HMAC keys)');
    expect(hmac.endpointType, EndpointProfileType.s3Compatible);
  });

  test('mobile adapters reject native GCS before any platform request',
      () async {
    final android = AndroidEngineService();
    final ios = IosEngineService();
    final rest = MobileStorageAdmin();
    addTearDown(android.shutdown);
    addTearDown(ios.shutdown);
    addTearDown(rest.close);
    final unsupported = throwsA(isA<EngineException>()
        .having((e) => e.code, 'code', ErrorCode.unsupportedFeature)
        .having((e) => e.message, 'desktop reason',
            'Google Cloud Storage profiles are available on desktop in this version'));
    await expectLater(
        android.listBuckets(engineId: 'go', profile: googleProfile()),
        unsupported);
    await expectLater(
        ios.listBuckets(engineId: 'go', profile: googleProfile()), unsupported);
    await expectLater(
        rest.dispatch('getCapabilities', {'profile': googleProfile().toJson()}),
        unsupported);
    await expectLater(
        rest.action(profile: googleProfile(), action: 'providerInfo'),
        unsupported);
  });
}

class _MobileOnlyEngine extends MockEngineService {
  int requests = 0;
  @override
  Future<List<EngineDescriptor>> listEngines() async => const [
        EngineDescriptor(
            id: 'go',
            label: 'Go mobile',
            language: 'Go',
            version: 'fixture',
            available: true,
            desktopSupported: false,
            mobileSupported: true)
      ];
  @override
  Future<List<BucketSummary>> listBuckets(
      {required String engineId, required EndpointProfile profile}) async {
    requests++;
    return [];
  }

  @override
  Future<List<CapabilityDescriptor>> getCapabilities(
      {required String engineId, required EndpointProfile profile}) async {
    requests++;
    return [];
  }

  @override
  Future<void> testProfile(
      {required String engineId, required EndpointProfile profile}) async {
    requests++;
  }
}

class _GenerationEngine extends MockEngineService {
  List<ObjectVersionRef> deleted = [];
  String? engine;
  @override
  Future<BatchOperationResult> deleteObjectVersions(
      {required String engineId,
      required EndpointProfile profile,
      required String bucketName,
      required List<ObjectVersionRef> versions}) async {
    deleted = versions;
    engine = engineId;
    return const BatchOperationResult(
        successCount: 1, failureCount: 0, failures: []);
  }

  @override
  Future<ObjectListResult> listObjects(
          {required String engineId,
          required EndpointProfile profile,
          required String bucketName,
          required String prefix,
          required bool flat,
          ListCursor? cursor}) async =>
      const ObjectListResult(
          items: [], cursor: ListCursor(value: null, hasMore: false));
}
