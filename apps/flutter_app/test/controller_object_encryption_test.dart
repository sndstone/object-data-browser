import 'dart:io';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:s3_browser_crossplat/controllers/app_controller.dart';
import 'package:s3_browser_crossplat/models/domain_models.dart';
import 'package:s3_browser_crossplat/services/encryption_key_store.dart';
import 'package:s3_browser_crossplat/services/mock_engine_service.dart';
import 'package:s3_browser_crossplat/services/object_encryption.dart';
import 'object_encryption_test.dart' show encryptionProfile;

class EncryptionRecordingEngine extends MockEngineService {
  final uploads = <ObjectEncryption?>[];
  final downloads = <ObjectEncryption?>[];
  final reads = <ObjectEncryption?>[];
  final copies = <Map<String, Object?>>[];
  ObjectEncryptionInfo? info;
  bool requiresKey = false, supportsEncryption = true;
  @override
  Future<List<CapabilityDescriptor>> getCapabilities(
          {required String engineId, required EndpointProfile profile}) async =>
      [
        for (final mode in ObjectEncryptionMode.values)
          CapabilityDescriptor(
              key: 'object.encryption.${mode.wireName}',
              label: mode.label,
              state: supportsEncryption
                  ? CapabilityState.supported
                  : CapabilityState.unsupported),
      ];
  TransferJob job(String direction) => TransferJob(
      id: '$direction-${uploads.length + downloads.length}',
      label: direction,
      direction: direction,
      progress: 1,
      status: 'completed',
      bytesTransferred: 1,
      totalBytes: 1);
  @override
  Future<TransferJob> startUpload(
      {required String engineId,
      required EndpointProfile profile,
      required String bucketName,
      required String prefix,
      required List<String> filePaths,
      required Map<String, String> objectKeyByPath,
      required int multipartThresholdMiB,
      required int multipartChunkMiB,
      Map<String, Object?>? clientEncryption,
      ObjectEncryption? encryption}) async {
    uploads.add(encryption);
    return job('upload');
  }

  @override
  Future<TransferJob> startDownload(
      {required String engineId,
      required EndpointProfile profile,
      required String bucketName,
      required List<String> keys,
      required String destinationPath,
      String conflictPolicy = 'keepBoth',
      required int multipartThresholdMiB,
      required int multipartChunkMiB,
      Map<String, Object?>? clientEncryption,
      ObjectEncryption? encryption}) async {
    downloads.add(encryption);
    return job('download');
  }

  @override
  Future<ObjectDetails> getObjectDetails(
      {required String engineId,
      required EndpointProfile profile,
      required String bucketName,
      required String key,
      ObjectEncryption? encryption}) async {
    reads.add(encryption);
    if (requiresKey && encryption == null) {
      throw const EngineException(
          code: ErrorCode.unknown,
          message: 'HTTP 400',
          details: {'encryptionHint': 'sse_c_key_required'});
    }
    return ObjectDetails(
        key: key,
        metadata: const {},
        headers: const {},
        tags: const {},
        debugEvents: const [],
        apiCalls: const [],
        encryption: info);
  }

  @override
  Future<ObjectVersionListResult> listObjectVersions(
          {required String engineId,
          required EndpointProfile profile,
          required String bucketName,
          String? key,
          VersionBrowserOptions? options,
          ListCursor? cursor}) async =>
      const ObjectVersionListResult(
          items: [],
          cursor: ListCursor(value: null, hasMore: false),
          totalCount: 0,
          versionCount: 0,
          deleteMarkerCount: 0);
  @override
  Future<Map<String, Object?>> storageAction(
      {required EndpointProfile profile,
      required String action,
      Map<String, Object?> arguments = const {},
      EndpointProfile? destinationProfile}) async {
    copies.add(arguments);
    return {'successCount': 1, 'failureCount': 0};
  }
}

final _object = ObjectEntry(
    key: 'object.bin',
    name: 'object.bin',
    size: 1,
    storageClass: 'STANDARD',
    modifiedAt: DateTime.utc(2026),
    isFolder: false);

void main() {
  late Directory directory;
  late EncryptionRecordingEngine engine;
  late EncryptionKeyStore store;
  late AppController controller;
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('controller-encryption-');
    engine = EncryptionRecordingEngine();
    store = EncryptionKeyStore(File('${directory.path}/keys.age'),
        scryptWorkFactor: 1);
    controller = AppController(
        engineService: engine,
        initialSettings: AppSettings.fromJson({
          'relistObjectsAfterMutation': false,
          'enableAnimations': false,
          'downloadPath': directory.path
        }),
        initialProfiles: const [encryptionProfile],
        encryptionKeyStore: store);
    controller.selectedProfile = encryptionProfile;
    controller.selectedBucket = const BucketSummary(
        name: 'bucket',
        region: '',
        objectCountHint: 0,
        versioningEnabled: false);
  });
  tearDown(() async {
    controller.dispose();
    await directory.delete(recursive: true);
  });
  Future<void> upload() async {
    final file = await File('${directory.path}/upload.bin').writeAsBytes([1]);
    await controller.startSampleUpload([file.path]);
  }

  Future<void> copy() => controller.storageAction('copyObject', arguments: {
        'sourceBucketName': 'bucket',
        'sourceKey': 'object.bin',
        'destinationBucketName': 'bucket',
        'destinationKey': 'copy.bin',
      });

  test(
      'existing profile leaves upload copy download and details encryption absent',
      () async {
    await upload();
    await controller.setSelectedObject(_object);
    await copy();
    await controller.startSampleDownload();
    expect(engine.uploads, [null]);
    expect(engine.reads, [null]);
    expect(engine.downloads, [null]);
    expect(engine.copies.single.containsKey('encryption'), isFalse);
    expect(engine.copies.single.containsKey('sourceEncryption'), isFalse);
    expect(await store.exists(), isFalse);
  });
  test('upload refuses a mode that the engine does not advertise supported',
      () async {
    engine.supportsEncryption = false;
    controller.selectedProfile = encryptionProfile.copyWith(
        uploadEncryption:
            const ObjectEncryption(mode: ObjectEncryptionMode.sseS3));
    await upload();
    expect(engine.uploads, isEmpty);
    expect(controller.bannerMessage, contains('does not support'));
  });
  test('copy preserves reported KMS mode key id and bucket key flag', () async {
    engine.info = const ObjectEncryptionInfo(
        mode: 'sse-kms', kmsKeyId: 'key-arn', bucketKeyEnabled: true);
    await controller.setSelectedObject(_object);
    await copy();
    expect((engine.copies.single['encryption'] as ObjectEncryption).toJson(),
        {'mode': 'sse-kms', 'kmsKeyId': 'key-arn', 'bucketKeyEnabled': true});
  });
  test(
      'customer fingerprints resolve copy source destination and download keys',
      () async {
    await store.create('passphrase-for-tests');
    final record = await store.importCustomerKey('Fixture key', Uint8List(32));
    engine.info =
        ObjectEncryptionInfo(mode: 'sse-c', customerKeyMd5: record.md5Base64);
    await controller.setSelectedObject(_object);
    expect(controller.selectedObjectPreview!.message,
        contains('Download to view'));
    await copy();
    await controller.startSampleDownload();
    expect(
        (engine.copies.single['sourceEncryption'] as ObjectEncryption)
            .customerKeyId,
        record.id);
    expect(
        (engine.copies.single['encryption'] as ObjectEncryption).customerKeyId,
        record.id);
    expect(engine.downloads.single!.customerKeyId, record.id);
    expect(
        controller
            .matchingEncryptionKey(ObjectEncryptionInfo(
                mode: 'azure-cpk', customerKeySha256: record.fingerprint))
            ?.id,
        record.id);
  });
  test('S3 key-required detail read retries once using configured customer key',
      () async {
    await store.create('passphrase-for-tests');
    final record = await store.generateCustomerKey('Read key');
    final setting = ObjectEncryption(
        mode: ObjectEncryptionMode.sseC,
        customerKeyId: record.id,
        customerKeyFingerprint: record.fingerprint);
    controller.selectedProfile =
        encryptionProfile.copyWith(uploadEncryption: setting);
    engine.requiresKey = true;
    engine.info =
        ObjectEncryptionInfo(mode: 'sse-c', customerKeyMd5: record.md5Base64);
    await controller.setSelectedObject(_object);
    expect(engine.reads, hasLength(2));
    expect(engine.reads.first, isNull);
    expect(engine.reads.last!.customerKeyId, record.id);
  });
  test(
      'missing configured key surfaces required-key instruction without a retry',
      () async {
    engine.requiresKey = true;
    await controller.setSelectedObject(_object);
    expect(engine.reads, [null]);
    expect(controller.bannerMessage, contains('choose or unlock a key'));
  });
  test('customer-key objects refuse share links while the key file is locked',
      () async {
    engine.info = const ObjectEncryptionInfo(
        mode: 'azure-cpk', customerKeySha256: 'unknown');
    await controller.setSelectedObject(_object);
    await controller.generateSelectedPresignedUrl();
    expect(controller.bannerMessage, contains('cannot be shared'));
  });
  test('locked key file refuses a customer-key copy before dispatch', () async {
    await store.create('passphrase-for-tests');
    final key = await store.generateCustomerKey('Locked key');
    engine.info =
        ObjectEncryptionInfo(mode: 'sse-c', customerKeyMd5: key.md5Base64);
    await controller.setSelectedObject(_object);
    store.lock();
    await expectLater(copy(), throwsA(isA<EncryptionDispatchException>()));
    expect(engine.copies, isEmpty);
  });
  test(
      'missing customer fingerprint refuses copy with the key-file instruction',
      () async {
    await store.create('passphrase-for-tests');
    engine.info =
        const ObjectEncryptionInfo(mode: 'sse-c', customerKeyMd5: 'missing');
    await controller.setSelectedObject(_object);
    await expectLater(
        copy(),
        throwsA(isA<EngineException>().having(
            (e) => e.message, 'message', contains('not in your key file'))));
    expect(engine.copies, isEmpty);
  });
}
