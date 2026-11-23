import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:s3_browser_crossplat/controllers/app_controller.dart';
import 'package:s3_browser_crossplat/models/domain_models.dart';
import 'package:s3_browser_crossplat/services/crypto/age.dart';
import 'package:s3_browser_crossplat/services/app_state_repository.dart';
import 'app_state_repository_test.dart' show RecordingProfileSecretStore;
import 'package:s3_browser_crossplat/services/encryption_key_store.dart';
import 'package:s3_browser_crossplat/services/mock_engine_service.dart';
import 'client_encryption_fixture.dart';
import 'object_encryption_test.dart' show encryptionProfile;

class VaultRecordingEngine extends MockEngineService {
  bool supported = true, fail = false;
  final uploads = <Map<String, Object?>>[],
      downloads = <Map<String, Object?>>[];
  TransferJob job(String direction) => TransferJob(
      id: '$direction-${uploads.length + downloads.length}',
      label: direction,
      direction: direction,
      progress: 1,
      status: fail ? 'failed' : 'completed',
      bytesTransferred: 1,
      totalBytes: 1,
      canCancel: false,
      canPause: false,
      canResume: false);
  @override
  Future<List<CapabilityDescriptor>> getCapabilities(
          {required String engineId, required EndpointProfile profile}) async =>
      [
        CapabilityDescriptor(
            key: 'object.clientEncryption',
            label: 'Client-side encryption',
            state: supported
                ? CapabilityState.supported
                : CapabilityState.unsupported),
        const CapabilityDescriptor(
            key: 'object.encryption.sse-s3',
            label: 'SSE-S3',
            state: CapabilityState.supported),
      ];
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
      ObjectEncryption? encryption,
      Map<String, Object?>? clientEncryption}) async {
    uploads.add({
      'paths': filePaths,
      'keys': objectKeyByPath,
      'threshold': multipartThresholdMiB,
      'chunk': multipartChunkMiB,
      if (encryption != null) 'encryption': encryption.toJson(),
      if (clientEncryption != null) 'clientEncryption': clientEncryption
    });
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
      ObjectEncryption? encryption,
      Map<String, Object?>? clientEncryption}) async {
    downloads.add({
      'keys': keys,
      if (clientEncryption != null) 'clientEncryption': clientEncryption
    });
    return job('download');
  }

  @override
  Future<String> generatePresignedUrl(
          {required String engineId,
          required EndpointProfile profile,
          required String bucketName,
          required String key,
          required Duration expiration,
          ObjectEncryption? encryption}) async =>
      'https://fixture.invalid/$key';
}

void main() {
  late Directory dir;
  late AgeIdentity identity;
  late EncryptionKeyStore store;
  late VaultRecordingEngine engine;
  late AppController controller;
  late LocalAppStateRepository repository;
  final ciphertext = <String, Uint8List>{};
  final requests = <(int, int)>[];
  setUp(() async {
    dir = await Directory.systemTemp.createTemp('controller-vault-');
    identity = await AgeIdentity.generate();
    store =
        EncryptionKeyStore(File('${dir.path}/keys.age'), scryptWorkFactor: 1);
    engine = VaultRecordingEngine();
    repository = LocalAppStateRepository(
        secretStore: RecordingProfileSecretStore({}),
        applicationSupportDirectoryProvider: () async => dir);
    ciphertext.clear();
    requests.clear();
    controller = AppController(
        engineService: engine,
        appStateRepository: repository,
        encryptionKeyStore: store,
        initialSettings: AppSettings.fromJson({
          'relistObjectsAfterMutation': false,
          'enableAnimations': false,
          'downloadPath': dir.path
        }),
        initialProfiles: const [encryptionProfile],
        previewRangeFetcher: (url, start, end, size, etag) async {
          requests.add((start, end));
          return Uint8List.sublistView(
              ciphertext[Uri.parse(url).path.substring(1)]!, start, end);
        });
    controller.selectedProfile = encryptionProfile;
    controller.selectedBucket = const BucketSummary(
        name: 'bucket',
        region: '',
        objectCountHint: 0,
        versioningEnabled: false);
  });
  tearDown(() async {
    controller.dispose();
    await dir.delete(recursive: true);
  });
  void vault({String prefix = '', bool provider = false}) {
    controller.selectedProfile = encryptionProfile.copyWith(
        clientEncryptionRules: [
          ClientEncryptionRule(
              bucket: 'bucket',
              prefix: prefix,
              keyId: 'vault',
              recipient: identity.recipient,
              label: 'Test vault')
        ],
        uploadEncryption: provider
            ? const ObjectEncryption(mode: ObjectEncryptionMode.sseS3)
            : null);
  }

  Future<String> file(String name) async =>
      (await File('${dir.path}/$name').writeAsBytes([1, 2, 3])).path;
  Future<ObjectEntry> object(String name, Uint8List plaintext,
      {AgeIdentity? to}) async {
    final fixture = await clientFixture(plaintext, to ?? identity);
    ciphertext[name] = fixture.bytes;
    return ObjectEntry(
        key: name,
        name: name,
        size: fixture.bytes.length,
        storageClass: 'STANDARD',
        modifiedAt: DateTime.utc(2026),
        isFolder: false,
        etag: 'etag');
  }

  Future<void> unlock() async {
    await store.create('test-passphrase');
    await store.importAgeIdentity('Vault', identity.secretKey);
  }

  String retainedData() => jsonEncode({
        'events': controller.eventLog.map((e) => e.toJson()).toList(),
        'tasks': controller.browserTasks
            .map((t) => [t.label, t.outputLines, t.currentItemLabel])
            .toList(),
        'jobs': controller.transferJobs
            .map((j) => [j.label, j.outputLines, j.currentItemLabel])
            .toList(),
        'profiles': controller.profiles.map((p) => p.toJson()).toList(),
      });

  test('no matching rule keeps the upload request shape unchanged', () async {
    final path = await file('plain.txt');
    await controller.startSampleUpload([path]);
    final original = engine.uploads.single;
    vault(prefix: 'other/');
    await controller.startSampleUpload([path]);
    expect(engine.uploads.last, original);
    expect(original.containsKey('clientEncryption'), isFalse);
    expect(await store.exists(), isFalse);
  });

  test(
      'vault upload while locked sends one file valid header fresh key and nonce per retry',
      () async {
    vault(provider: true);
    final a = await file('a.txt');
    final b = await file('b.txt');
    engine.fail = true;
    await controller.startSampleUpload([a, b]);
    // A definite failure does not stop queued files; both are attempted.
    expect(engine.uploads, hasLength(2));
    final failedTask = controller.browserTasks
        .firstWhere((t) => t.id.startsWith('upload-batch-'));
    expect(controller.canRetryTask(failedTask), isTrue);
    engine.fail = false;
    await controller.retryTask(failedTask);
    expect(engine.uploads, hasLength(4));
    final keys = <String>{}, nonces = <String>{};
    final expectedKeys = {a: 'a.txt.age', b: 'b.txt.age'};
    for (final request in engine.uploads) {
      expect(request['paths'], hasLength(1));
      final path = (request['paths'] as List<String>).single;
      expect(expectedKeys, contains(path));
      expect((request['keys'] as Map)[path], expectedKeys[path]);
      expect(request['encryption'], {'mode': 'sse-s3'});
      final params = request['clientEncryption'] as Map;
      final opened = await ageReadHeader(
          base64Decode(params['header'] as String),
          identities: [identity]);
      expect(params['fileKey'], base64Encode(opened.fileKey));
      keys.add(params['fileKey'] as String);
      nonces.add(params['payloadNonce'] as String);
      expect(base64Decode(params['payloadNonce'] as String), hasLength(16));
      expect(retainedData(), isNot(contains(params['fileKey'])));
      final exported = await repository.exportProfiles(
          profiles: controller.profiles, path: '${dir.path}/profiles.json');
      expect(await exported.readAsString(), isNot(contains(params['fileKey'])));
      await repository.saveState(
          settings: controller.settings,
          profiles: controller.profiles,
          selectedProfileId: controller.selectedProfile?.id);
      expect(
          await File('${dir.path}/object-data-browser-state.json')
              .readAsString(),
          isNot(contains(params['fileKey'])));
    }
    // Every attempt, including each retry, has its own file key and nonce.
    expect(keys, hasLength(4));
    expect(nonces, hasLength(4));
    expect(await store.exists(), isFalse);
  });

  test('unsupported engine refuses vault uploads without plaintext fallback',
      () async {
    vault();
    engine.supported = false;
    await controller.startSampleUpload([await file('file.txt')]);
    expect(engine.uploads, isEmpty);
    expect(controller.bannerMessage,
        contains('does not support client-side encryption'));
  });

  test('download unwraps header and sends only one encrypted key per request',
      () async {
    vault();
    await unlock();
    final a = await object('a.txt.age', Uint8List.fromList([65]));
    final b = await object('b.txt.age', Uint8List.fromList([66]));
    controller.objects = [a, b];
    await controller.startSampleDownload(keysOverride: [a.key, b.key]);
    expect(engine.downloads, hasLength(2));
    for (final request in engine.downloads) {
      expect(request['keys'], hasLength(1));
      final key = (request['keys'] as List<String>).single;
      final opened =
          await ageReadHeader(ciphertext[key]!, identities: [identity]);
      expect(request['clientEncryption'], {
        'format': 'age-v1',
        'headerLength': opened.headerLength,
        'fileKey': base64Encode(opened.fileKey)
      });
      expect(retainedData(), isNot(contains(base64Encode(opened.fileKey))));
    }
    expect(controller.transferJobs.single.itemCount, 2);
    expect(controller.transferJobs.single.itemsCompleted, 2);
    expect(controller.transferJobs.single.status, 'completed');
  });

  test(
      'locked and missing vault identities block decrypt but allow encrypted copy',
      () async {
    vault();
    final entry = await object('a.txt.age', Uint8List(1));
    controller.objects = [entry];
    await controller.startSampleDownload(key: entry.key);
    expect(engine.downloads, isEmpty);
    expect(requests, isEmpty);
    expect(
        controller.bannerMessage, contains('Unlock your encryption key file'));
    await controller.startSampleDownload(key: entry.key, encryptedCopy: true);
    expect(engine.downloads.single.containsKey('clientEncryption'), isFalse);
    await store.create('test-passphrase');
    await controller.startSampleDownload(key: entry.key);
    expect(engine.downloads, hasLength(1));
    expect(
        controller.bannerMessage,
        contains(
            'This object is encrypted to a vault key that is not in your key file.'));
  });

  test('controller previews text and image and clears decrypted bytes on lock',
      () async {
    vault();
    await unlock();
    final text =
        await object('a.txt.age', Uint8List.fromList(utf8.encode('hello')));
    final imageBytes = base64Decode(
        'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+a3ioAAAAASUVORK5CYII=');
    final image = await object('a.png.age', imageBytes);
    controller.objects = [text, image];
    Future<void> preview(ObjectEntry entry) async {
      await controller.setSelectedObject(entry, loadArtifacts: false);
      controller.refreshSelectedObjectPreview();
      for (var i = 0;
          i < 500 && controller.selectedObjectPreview?.loading == true;
          i++) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      expect(controller.selectedObjectPreview!.supported, isTrue);
    }

    await preview(text);
    expect(controller.selectedObjectPreview!.text, 'hello');
    await preview(image);
    expect(controller.selectedObjectPreview!.bytes, imageBytes);
    final decrypted = controller.selectedObjectPreview!.bytes!;
    controller.lockEncryptionKeyFile();
    expect(decrypted.every((b) => b == 0), isTrue);
    expect(controller.selectedObjectPreview!.bytes, isNull);
    expect(controller.selectedObjectPreview!.text, isNull);
  });

  test(
      'listing presentation strips suffix only in vault scope and retains identity',
      () async {
    vault(prefix: 'vault/');
    final encrypted = await object('vault/a.txt.age', Uint8List(1));
    final outside = await object('outside/a.txt.age', Uint8List(1));
    expect(controller.visibleObjectKey(encrypted), 'vault/a.txt');
    expect(controller.isClientEncrypted(encrypted), isTrue);
    expect(controller.visibleObjectKey(outside), outside.key);
    expect(controller.isClientEncrypted(outside), isFalse);
    expect(encrypted.key, 'vault/a.txt.age');
    expect(requests, isEmpty); // presentation performs no object reads
  });
  test('tampered preview exposes an integrity error and no plaintext',
      () async {
    vault();
    await unlock();
    final entry = await object(
        'bad.txt.age', Uint8List.fromList(utf8.encode('private text')));
    ciphertext[entry.key]![ciphertext[entry.key]!.length - 1] ^= 1;
    controller.objects = [entry];
    await controller.setSelectedObject(entry, loadArtifacts: false);
    controller.refreshSelectedObjectPreview();
    for (var i = 0;
        i < 500 && controller.selectedObjectPreview?.loading == true;
        i++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    expect(controller.selectedObjectPreview!.supported, isFalse);
    expect(controller.selectedObjectPreview!.message,
        contains('Integrity check failed'));
    expect(controller.selectedObjectPreview!.text, isNull);
    expect(controller.selectedObjectPreview!.bytes, isNull);
  });
}
