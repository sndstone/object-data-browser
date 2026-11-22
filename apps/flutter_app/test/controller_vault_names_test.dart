import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:s3_browser_crossplat/controllers/app_controller.dart';
import 'package:s3_browser_crossplat/models/domain_models.dart';
import 'package:s3_browser_crossplat/services/app_state_repository.dart';
import 'package:s3_browser_crossplat/services/crypto/age.dart';
import 'package:s3_browser_crossplat/services/crypto/age_bech32.dart';
import 'package:s3_browser_crossplat/services/crypto/vault_names.dart';
import 'package:s3_browser_crossplat/services/encryption_key_store.dart';
import 'package:s3_browser_crossplat/services/engine_service.dart';
import 'package:s3_browser_crossplat/services/bucket_copy_journal.dart';
import 'package:s3_browser_crossplat/services/diagnostic_safety.dart';
import 'package:s3_browser_crossplat/services/vault_name_codec.dart';
import 'app_state_repository_test.dart' show RecordingProfileSecretStore;
import 'controller_client_encryption_test.dart' show VaultRecordingEngine;
import 'client_encryption_fixture.dart';
import 'object_encryption_test.dart' show encryptionProfile;
import 'vault_names_test.dart' show hex;

class NameRecordingEngine extends VaultRecordingEngine
    implements NativeProviderActions, EngineLogSinkRegistrant {
  final folders = <String>[], prefixes = <String>[];
  final moves = <Map<String, Object?>>[];
  List<ObjectEntry> listing = [];
  final actions = <String>[];
  final versionOptions = <VersionBrowserOptions>[];
  List<ObjectVersionEntry> versionListing = [];
  bool moreVersions = false, noisyDownload = false, throwDownload = false;
  TransferJobCallback? transferSink;
  EngineLogCallback? logSink;
  void Function()? afterDownloadProgress;

  @override
  void setLogSink(EngineLogCallback? sink) => logSink = sink;

  @override
  void setTransferSink(TransferJobCallback? sink) => transferSink = sink;

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
    final result = await super.startDownload(
        engineId: engineId,
        profile: profile,
        bucketName: bucketName,
        keys: keys,
        destinationPath: destinationPath,
        conflictPolicy: conflictPolicy,
        multipartThresholdMiB: multipartThresholdMiB,
        multipartChunkMiB: multipartChunkMiB,
        encryption: encryption,
        clientEncryption: clientEncryption);
    final name = clientEncryption?['fileName'];
    if (!noisyDownload || name is! String) return result;
    final sanitized = name.replaceAll(':', '_');
    final dot = sanitized.lastIndexOf('.');
    final collision =
        '${sanitized.substring(0, dot)} (1)${sanitized.substring(dot)}';
    TransferJob noisy(TransferJob job) => job.copyWith(
            label: 'Downloading $name',
            currentItemLabel: sanitized,
            outputLines: [
              '$destinationPath/$name',
              sanitized,
              collision,
              'Unrelated transfer line survives.'
            ]);
    final progress = noisy(result.copyWith(progress: 0.5, status: 'running'));
    final params = {'keys': keys, 'clientEncryption': clientEncryption};
    void trace(TransferJob job) {
      // Use the same projection boundary as the desktop and mobile services.
      final body = DiagnosticSafety.forNameEncryptedRequest({
        'label': job.label,
        'currentItemLabel': job.currentItemLabel,
        'outputLines': job.outputLines
      }, params);
      logSink?.call(EngineLogRecord(
          level: 'API',
          category: 'DownloadTrace',
          message: jsonEncode(body),
          source: 'api',
          tracePhase: 'response',
          traceBody: body));
    }

    transferSink?.call(progress);
    trace(progress);
    afterDownloadProgress?.call();
    if (throwDownload) {
      throw FileSystemException(
          'Cannot publish $collision', '$destinationPath/$sanitized');
    }
    final completed = noisy(result);
    trace(completed);
    return completed;
  }

  @override
  Future<ObjectVersionListResult> listObjectVersions(
      {required String engineId,
      required EndpointProfile profile,
      required String bucketName,
      String? key,
      VersionBrowserOptions? options,
      ListCursor? cursor}) async {
    final effective = options ?? const VersionBrowserOptions();
    versionOptions.add(effective);
    final items = versionListing
        .where((v) =>
            v.key.startsWith(effective.filterValue) &&
            (key == null || key == v.key))
        .toList();
    return ObjectVersionListResult(
        items: items,
        cursor: ListCursor(
            value: moreVersions && cursor == null ? 'page-2' : null,
            hasMore: moreVersions && cursor == null),
        totalCount: items.length,
        versionCount: items.length,
        deleteMarkerCount: 0);
  }

  @override
  Future<Map<String, Object?>> nativeProviderAction(
          {required String engineId,
          required EndpointProfile profile,
          required String action,
          required Map<String, Object?> arguments,
          EndpointProfile? destinationProfile}) =>
      storageAction(
          profile: profile,
          action: action,
          arguments: arguments,
          destinationProfile: destinationProfile);

  @override
  Future<void> createFolder(
      {required String engineId,
      required EndpointProfile profile,
      required String bucketName,
      required String key,
      ObjectEncryption? encryption}) async {
    folders.add(key);
  }

  @override
  Future<ObjectListResult> listObjects(
      {required String engineId,
      required EndpointProfile profile,
      required String bucketName,
      required String prefix,
      required bool flat,
      ListCursor? cursor}) async {
    prefixes.add(prefix);
    return ObjectListResult(
        items: listing.where((o) => o.key.startsWith(prefix)).toList(),
        cursor: const ListCursor(value: null, hasMore: false));
  }

  @override
  Future<Map<String, Object?>> storageAction(
      {required EndpointProfile profile,
      required String action,
      Map<String, Object?> arguments = const {},
      EndpointProfile? destinationProfile}) async {
    actions.add(action);
    if (action == 'copyObject') moves.add(arguments);
    if (action == 'listObjects') {
      return {
        'items': listing
            .map((o) => {
                  'key': o.key,
                  'size': o.size,
                  'etag': o.etag,
                  'isFolder': o.isFolder
                })
            .toList(),
        'nextCursor': {'hasMore': false, 'value': null}
      };
    }
    if (action == 'listDirectories') return {'items': directoryItems};
    return {'successCount': 1, 'failureCount': 0, 'bytesCopied': 1};
  }

  List<Map<String, Object?>> directoryItems = [];
}

void main() {
  final vectors = jsonDecode(
          File('../../contracts/vectors/vault-names.json').readAsStringSync())
      as Map;
  late Directory dir;
  late EncryptionKeyStore store;
  late AgeIdentity identity;
  late VaultNameKeys nameKeys;
  late AppController c;
  late NameRecordingEngine engine;
  late LocalAppStateRepository repository;
  String keyId = '';
  final ciphertext = <String, Uint8List>{};
  setUp(() async {
    dir = await Directory.systemTemp.createTemp('controller-vault-names-');
    identity = await AgeIdentity.parse(bech32Encode(
        'AGE-SECRET-KEY-', hex(vectors['identitySecretHex'] as String)));
    nameKeys = identity.deriveNameKeys();
    store =
        EncryptionKeyStore(File('${dir.path}/keys.age'), scryptWorkFactor: 1);
    engine = NameRecordingEngine();
    ciphertext.clear();
    repository = LocalAppStateRepository(
        secretStore: RecordingProfileSecretStore({}),
        applicationSupportDirectoryProvider: () async => dir);
    c = AppController(
        engineService: engine,
        bucketCopyJournalProvider: () async =>
            BucketCopyJournal(File('${dir.path}/copy.json')),
        encryptionKeyStore: store,
        appStateRepository: repository,
        initialSettings: AppSettings.fromJson({
          'relistObjectsAfterMutation': false,
          'enableAnimations': false,
          'enableApiLogging': true,
          'downloadPath': dir.path
        }),
        initialProfiles: const [encryptionProfile],
        previewRangeFetcher: (url, start, end, size, etag) async =>
            Uint8List.sublistView(
                ciphertext[Uri.parse(url).path.substring(1)]!, start, end));
    c.selectedProfile = encryptionProfile;
    c.selectedBucket = const BucketSummary(
        name: 'bucket',
        region: '',
        objectCountHint: 0,
        versioningEnabled: false);
    await c.updateEncryptionKeys((s) async {
      await s.create('test-passphrase');
      final record = await s.importAgeIdentity('Vault', identity.secretKey);
      keyId = record.id;
    });
  });
  tearDown(() async {
    c.dispose();
    nameKeys.wipe();
    await dir.delete(recursive: true);
  });
  ClientEncryptionRule vault(
      {bool names = true,
      String prefix = 'vault/',
      ClientEncryptionPolicy policy = ClientEncryptionPolicy.standard}) {
    final r = ClientEncryptionRule(
        bucket: 'bucket',
        prefix: prefix,
        keyId: keyId,
        recipient: identity.recipient,
        label: 'Vault',
        encryptNames: names,
        policy: policy);
    c.selectedProfile = encryptionProfile.copyWith(clientEncryptionRules: [r]);
    c.currentPrefix = prefix;
    return r;
  }

  Future<String> file(String name) async =>
      (await File('${dir.path}/$name').writeAsBytes([1, 2, 3])).path;
  String uploadedKey([int index = 0]) =>
      'vault/${(engine.uploads[index]['keys'] as Map).values.single}';
  ObjectEntry object(String key, {bool folder = false, int size = 10}) =>
      ObjectEntry(
          key: key,
          name: key.substring(key.lastIndexOf(
                  '/', key.endsWith('/') ? key.length - 2 : key.length - 1) +
              1),
          size: size,
          storageClass: 'STANDARD',
          modifiedAt: DateTime.utc(2026),
          isFolder: folder,
          etag: 'etag');
  String retainedData() => jsonEncode({
        'events': c.eventLog.map((e) => e.toJson()).toList(),
        'tasks': c.browserTasks
            .map((t) => [t.label, t.outputLines, t.currentItemLabel])
            .toList(),
        'jobs': c.transferJobs
            .map((j) => [j.label, j.outputLines, j.currentItemLabel])
            .toList()
      });

  test('names off preserves baseline keys and engine request shape', () async {
    vault(names: false);
    final path = await file('a.jpg');
    await c.startSampleUpload([path]);
    expect((engine.uploads.single['keys'] as Map)[path], 'a.jpg.age');
    expect((engine.uploads.single['clientEncryption'] as Map).keys,
        unorderedEquals(['format', 'header', 'fileKey', 'payloadNonce']));
  });
  test(
      'single and tree uploads match deterministic vectors; same folder reuses prefix',
      () async {
    vault();
    final a = await file('a.jpg'), b = await file('b.jpg');
    await c.startSampleUpload([a]);
    expect(uploadedKey(),
        'vault/${(vectors['storedKeys'] as List).first['stored']}');
    await c.startSampleUpload([a, b],
        objectKeyByPath: {a: 'photos/2024/a.jpg', b: 'photos/2024/b.jpg'});
    expect(uploadedKey(1), (vectors['storedKeys'] as List)[1]['stored']);
    expect(
        uploadedKey(1).split('/').take(3), uploadedKey(2).split('/').take(3));
  });
  test(
      'strict uploads are flat, fresh on retry, and preserve duplicate visible names',
      () async {
    vault(policy: ClientEncryptionPolicy.strict);
    final path = await file('a.jpg');
    await c.startSampleUpload([path], objectKeyByPath: {path: 'photos/a.jpg'});
    await c.startSampleUpload([path], objectKeyByPath: {path: 'photos/a.jpg'});
    final a = uploadedKey(), b = uploadedKey(1);
    expect(a, isNot(b));
    expect(a.split('/'), hasLength(2));
    c.objects = [object(a), object(b)];
    expect(c.objects.map(c.visibleObjectKey),
        ['vault/photos/a.jpg', 'vault/photos/a.jpg']);
    expect(c.visibleObjects, hasLength(2));
    c.toggleObjectSelection(c.objects[0]);
    c.toggleObjectSelection(c.objects[1]);
    expect(c.objectSelection.keys, unorderedEquals([a, b]));
  });
  test('an existing plaintext destination folder stays plaintext', () async {
    vault();
    c.currentPrefix = 'vault/plain/';
    final path = await file('a.jpg');
    await c.startSampleUpload([path]);
    expect((engine.uploads.single['keys'] as Map)[path],
        '${sealVaultName('a.jpg', nameKeys)}.age');
    final event = c.eventLog.where((e) => e.source == 'upload-file').first;
    expect(
        event.objectKey, 'vault/plain/${sealVaultName('a.jpg', nameKeys)}.age');
  });
  test('locked, unsupported and oversized uploads fail before upload',
      () async {
    vault();
    final path = await file('a.jpg');
    store.lock();
    await c.startSampleUpload([path]);
    expect(engine.uploads, isEmpty);
    expect(c.bannerMessage, contains(vaultNamesLocked));
    await c.updateEncryptionKeys((s) => s.unlock('test-passphrase'));
    vault(policy: ClientEncryptionPolicy.unsupported);
    await c.startSampleUpload([path]);
    expect(engine.uploads, isEmpty);
    expect(c.bannerMessage, contains(vaultPolicyUnsupported));
    vault();
    await c.startSampleUpload([path],
        objectKeyByPath: {path: List.filled(1000, 'x').join()});
    expect(engine.uploads, isEmpty);
    expect(c.bannerMessage, contains('1,024'));
  });
  test(
      'batch preparation refuses a late invalid file before uploading any file',
      () async {
    vault();
    final a = await file('a.jpg'), b = await file('b.jpg');
    await c.startSampleUpload([a, b],
        objectKeyByPath: {b: List.filled(1000, 'x').join()});
    expect(engine.uploads, isEmpty);
  });
  test('folder markers encode and strict folders refuse', () async {
    vault();
    await c.createFolderMarker('photos/2024');
    expect(engine.folders.single, (vectors['storedKeys'] as List)[2]['stored']);
    vault(policy: ClientEncryptionPolicy.strict);
    await c.createFolderMarker('photos');
    expect(engine.folders, hasLength(1));
    expect(c.bannerMessage, contains(vaultStrictFolders));
    vault();
    store.lock();
    await c.createFolderMarker('locked');
    expect(engine.folders, hasLength(1));
    expect(c.bannerMessage, contains(vaultNamesLocked));
  });
  test('rename accepts visible names and preserves the stored parent',
      () async {
    final r = vault();
    final source = encodeVaultObjectKey(
        rule: r,
        keys: nameKeys,
        destinationPrefix: 'vault/plain/',
        relativeName: 'photos/a.jpg');
    await c.renameObject(source, 'vault/plain/photos/b.jpg');
    final dest = engine.moves.single['destinationKey'] as String;
    expect(dest.split('/').take(3), source.split('/').take(3));
    expect(
        decodeVaultKey(dest, r, {keyId: nameKeys}), 'vault/plain/photos/b.jpg');
  });
  test(
      'administrative vault writes are refused before either provider dispatch',
      () async {
    vault();
    for (final native in [false, true]) {
      final destination = c.selectedProfile!;
      final source = encryptionProfile.copyWith(
          endpointType: native
              ? EndpointProfileType.googleCloudStorage
              : EndpointProfileType.s3Compatible);
      for (final action in [
        'startResumableUpload',
        'createDirectory',
        'renameDirectory',
        'copyObject',
        'resumeUpload',
        'resumeHistoryCopy'
      ]) {
        final arguments = <String, Object?>{
          'bucketName': 'bucket',
          'key': 'vault/plain',
          'destinationBucketName': 'bucket',
          'destinationKey': 'vault/plain',
          'recoveryId': 'old-session'
        };
        await expectLater(
            c.storageAction(action,
                profile: source,
                destinationProfile: destination,
                arguments: arguments),
            throwsA(isA<EngineException>()
                .having((e) => e.code, 'code', ErrorCode.unsupportedFeature)));
        expect(engine.actions, isEmpty, reason: action);
      }
    }
    // A bare token is not an encrypted object payload.
    await expectLater(
        c.storageAction('copyObject', arguments: {
          'destinationBucketName': 'bucket',
          'destinationKey': 'vault/${sealVaultName('a', nameKeys)}'
        }),
        throwsA(isA<EngineException>()));
    expect(engine.actions, isEmpty);
    vault(policy: ClientEncryptionPolicy.unsupported);
    for (final action in ['createDirectory', 'renameDirectory', 'copyObject']) {
      await expectLater(
          c.storageAction(action, arguments: {
            'bucketName': 'bucket',
            'key': 'vault/plain',
            'destinationBucketName': 'bucket',
            'destinationKey': 'vault/${sealVaultName('a', nameKeys)}.age'
          }),
          throwsA(isA<EngineException>()));
      expect(engine.actions, isEmpty, reason: action);
    }
    vault(names: false);
    await expectLater(
        c.storageAction('startResumableUpload',
            arguments: {'bucketName': 'bucket', 'key': 'vault/a'}),
        throwsA(isA<EngineException>()));
    expect(engine.actions, isEmpty);
    // Names off keeps administrative names unchanged.
    await c.storageAction('createDirectory',
        arguments: {'bucketName': 'bucket', 'key': 'vault/plain'});
    // A copy transfers stored bytes as they are, so plaintext may not enter
    // a vault location that way, whatever the rule does to names.
    for (final arguments in <Map<String, Object?>>[
      {
        'sourceBucketName': 'source',
        'sourceKey': 'a',
        'destinationKey': 'vault/plain'
      },
      {
        'sourceBucketName': 'source',
        'sourceKey': 'a',
        'destinationKey': 'vault/a.age'
      },
      {
        'sourceBucketName': 'source',
        'sourceKey': 'a.age',
        'destinationKey': 'vault/a'
      },
      {
        'sourceBucketName': 'bucket',
        'sourceKey': 'outside/a',
        'destinationKey': 'vault/a'
      },
    ]) {
      await expectLater(
          c.storageAction('copyObject',
              arguments: {'destinationBucketName': 'bucket', ...arguments}),
          throwsA(isA<EngineException>().having((e) => e.message, 'message',
              contains('Copies from outside this vault'))),
          reason: '$arguments');
    }
    for (final action in ['planHistoryCopy', 'resumeHistoryCopy']) {
      await expectLater(
          c.storageAction(action, arguments: {
            'sourceBucketName': 'source',
            'destinationBucketName': 'bucket',
            'prefix': ''
          }),
          throwsA(isA<EngineException>()),
          reason: action);
    }
    await expectLater(
        c.storageAction('renameDirectory', arguments: {
          'bucketName': 'bucket',
          'key': 'outside/dir',
          'destinationKey': 'vault/dir'
        }),
        throwsA(isA<EngineException>()));
    expect(engine.moves, isEmpty);
    expect(engine.actions.where((a) => a != 'createDirectory'), isEmpty);
    // A suffix alone cannot authorize ingress into a vault.
    await expectLater(
        c.storageAction('copyObject', arguments: {
          'sourceBucketName': 'source',
          'sourceKey': 'x/a.age',
          'destinationBucketName': 'bucket',
          'destinationKey': 'vault/a.age',
        }),
        throwsA(isA<EngineException>()));
    await expectLater(
        c.storageAction('copyObject', arguments: {
          'sourceBucketName': 'bucket',
          'sourceKey': 'vault/../x/a.age',
          'destinationBucketName': 'bucket',
          'destinationKey': 'vault/a.age',
        }),
        throwsA(isA<EngineException>()));
    // What the location already holds may move inside it.
    for (final arguments in <Map<String, Object?>>[
      {
        'sourceBucketName': 'bucket',
        'sourceKey': 'vault/old.txt',
        'destinationKey': 'vault/new.txt'
      },
      {
        'sourceBucketName': 'bucket',
        'sourceKey': 'vault/old.txt',
        'destinationKey': 'vault/old.txt'
      },
      {
        'sourceBucketName': 'source',
        'sourceKey': 'x/',
        'destinationKey': 'vault/x/'
      },
    ]) {
      await c.storageAction('copyObject',
          arguments: {'destinationBucketName': 'bucket', ...arguments});
    }
    expect(engine.moves.map((m) => m['destinationKey']),
        ['vault/new.txt', 'vault/old.txt', 'vault/x/']);
    expect(engine.moves.last['requireEmptySource'], isTrue);
    await c.storageAction('renameDirectory', arguments: {
      'bucketName': 'bucket',
      'key': 'vault/dir',
      'destinationKey': 'vault/other'
    });
    // A directory move carries its subtree: it may not land on an ancestor
    // of a vault location either.
    c.selectedProfile = c.selectedProfile!.copyWith(clientEncryptionRules: [
      c.selectedProfile!.clientEncryptionRules.single
          .copyWith(prefix: 'archive/private/')
    ]);
    for (final target in ['archive', 'archive/']) {
      final sent = engine.actions.length;
      await expectLater(
          c.storageAction('renameDirectory', arguments: {
            'bucketName': 'bucket',
            'key': 'incoming',
            'destinationKey': target
          }),
          throwsA(isA<EngineException>()
              .having((e) => e.message, 'message', contains('vault'))));
      expect(engine.actions, hasLength(sent));
    }
    await c.storageAction('renameDirectory', arguments: {
      'bucketName': 'bucket',
      'key': 'incoming',
      'destinationKey': 'elsewhere'
    });
    // The rule's own folder marker is never encrypted: a bucket copy and
    // Azure directory creation may write it under every supported policy.
    for (final policy in [
      ClientEncryptionPolicy.standard,
      ClientEncryptionPolicy.strict
    ]) {
      vault(policy: policy);
      await c.storageAction('copyObject', arguments: {
        'sourceBucketName': 'source',
        'sourceKey': 'vault/',
        'destinationBucketName': 'bucket',
        'destinationKey': 'vault/'
      });
      expect(engine.moves.last['destinationKey'], 'vault/');
      await c.storageAction('createDirectory',
          arguments: {'bucketName': 'bucket', 'key': 'vault'});
    }
    // With names on, a version restored onto its own key creates no new name.
    vault();
    await c.storageAction('copyObject', arguments: {
      'sourceBucketName': 'bucket',
      'sourceKey': 'vault/report.pdf.age',
      'sourceVersionId': 'v1',
      'destinationBucketName': 'bucket',
      'destinationKey': 'vault/report.pdf.age'
    });
    expect(engine.moves.last['destinationKey'], 'vault/report.pdf.age');
  });
  test('plaintext objects cannot be renamed into encrypted names', () async {
    vault();
    await expectLater(
        c.renameObject('outside/plain.txt', 'vault/renamed.txt'),
        throwsA(isA<EngineException>().having((e) => e.message, 'message',
            'This object is not vault-encrypted, so it cannot be renamed inside a location that encrypts names. Download it and upload it again.')));
    expect(engine.actions, isEmpty);
    vault(names: false);
    await c.renameObject('vault/plain.txt', 'vault/renamed.txt');
    expect(engine.moves.single['destinationKey'], 'vault/renamed.txt');
  });
  test(
      'bucket copy accepts an empty root marker and rejects unverified ciphertext',
      () async {
    final rule = vault();
    final key = encodeVaultObjectKey(
        rule: rule,
        keys: nameKeys,
        destinationPrefix: 'vault/',
        relativeName: 'photos/a.jpg');
    // The listing starts with the location's own folder marker.
    engine.listing = [object('vault/', folder: true, size: 0), object(key)];
    await c.copyBucketContents(
        sourceBucketName: 'source', destinationBucketName: 'bucket');
    expect(engine.moves.first['destinationKey'], 'vault/');
    expect(engine.moves.single['requireEmptySource'], isTrue);
    expect(c.bannerMessage, contains('Copies from outside this vault'));
  });
  test('bucket copy refuses a visible source prefix below encrypted names',
      () async {
    final rule = vault();
    final token = sealVaultName('photos', nameKeys);
    final key = encodeVaultObjectKey(
        rule: rule,
        keys: nameKeys,
        destinationPrefix: 'vault/',
        relativeName: 'photos/a.jpg');
    engine.listing = [object(key)];
    for (final typed in ['vault/photos/', 'vault/pho', 'vault/$token/x']) {
      await c.copyBucketContents(
          sourceBucketName: 'bucket',
          destinationBucketName: 'copy',
          prefix: typed);
      expect(engine.actions, isEmpty, reason: typed);
      expect(c.bannerMessage, contains('encrypted names'), reason: typed);
    }
    // The location itself and a stored folder name are sent as they are.
    for (final stored in ['vault/', 'vault/$token/']) {
      engine.actions.clear();
      await c.copyBucketContents(
          sourceBucketName: 'bucket',
          destinationBucketName: 'copy',
          prefix: stored);
      expect(engine.actions, contains('listObjects'), reason: stored);
    }
  });
  test('the rule prefix itself is created as typed under every policy',
      () async {
    for (final policy in ClientEncryptionPolicy.values
        .where((p) => p != ClientEncryptionPolicy.unsupported)) {
      // A rule prefix is stored as typed, with or without its slash.
      for (final prefix in ['vault/', 'vault']) {
        vault(policy: policy, prefix: prefix);
        c.currentPrefix = '';
        engine.folders.clear();
        await c.createFolderMarker('vault');
        expect(engine.folders, ['vault/'], reason: '$policy $prefix');
        await c.storageAction('copyObject', arguments: {
          'sourceBucketName': 'source',
          'sourceKey': 'vault/',
          'destinationBucketName': 'bucket',
          'destinationKey': 'vault/'
        });
        expect(engine.moves.last['destinationKey'], 'vault/');
      }
    }
  });
  test('a version prefix that cannot be a name falls back without an error',
      () async {
    vault();
    for (final typed in ['vault/../x', 'vault/./x']) {
      c.updateVersionBrowserOptions(VersionBrowserOptions(filterValue: typed));
      await c.refreshObjects();
      expect(engine.versionOptions.last.filterValue, 'vault/');
      expect(c.bannerMessage ?? '', isNot(contains('FormatException')));
    }
  });
  test('a version prefix outside the vault is sent as typed from inside it',
      () async {
    vault();
    c.currentPrefix = 'vault/${sealVaultName('photos', nameKeys)}/';
    c.updateVersionBrowserOptions(
        const VersionBrowserOptions(filterValue: 'other/'));
    await c.refreshObjects();
    expect(engine.versionOptions.last.filterValue, 'other/');
    // Locked, a typed vault name is neither sent nor replaced by plaintext.
    store.lock();
    c.updateVersionBrowserOptions(
        const VersionBrowserOptions(filterValue: 'vault/secret/a'));
    await c.refreshObjects();
    expect(engine.versionOptions.last.filterValue, 'vault/');
    expect(engine.versionOptions.map((o) => o.filterValue).join('\n'),
        isNot(contains('secret')));
  });
  test('text and regex version filters stay out of engine requests', () async {
    final rule = vault();
    final key = encodeVaultObjectKey(
        rule: rule,
        keys: nameKeys,
        destinationPrefix: 'vault/',
        relativeName: 'secret-report.pdf');
    engine.versionListing = [
      ObjectVersionEntry(
          key: key,
          versionId: 'v1',
          modifiedAt: DateTime.utc(2026),
          latest: true,
          deleteMarker: false,
          size: 10)
    ];
    engine.moreVersions = true;
    for (final mode in [BrowserFilterMode.text, BrowserFilterMode.regex]) {
      c.updateVersionBrowserOptions(
          VersionBrowserOptions(filterValue: 'secret', filterMode: mode));
      await c.refreshObjects();
      await c.loadMoreVersions();
      expect(c.versionBrowserOptions.filterValue, 'secret');
      // The text still filters the visible names here. (Regex results are
      // computed asynchronously and are not awaited by this test.)
      if (mode == BrowserFilterMode.text) {
        expect(c.visibleVersions.single.key, key);
      }
    }
    expect(engine.versionOptions, hasLength(4));
    expect(engine.versionOptions.map((o) => o.filterValue).toSet(), {''});
    // Without a vault rule in the bucket the request is what it always was.
    c.selectedProfile =
        c.selectedProfile!.copyWith(clientEncryptionRules: const []);
    c.updateVersionBrowserOptions(const VersionBrowserOptions(
        filterValue: 'plain', filterMode: BrowserFilterMode.text));
    await c.refreshObjects();
    expect(engine.versionOptions.last.filterValue, 'plain');
  });
  test('a locked or unknown rule never sends a typed name below known tokens',
      () async {
    // Names were encrypted once and are now off; the browser is inside an
    // encoded folder, so a typed name here may be a hidden one.
    vault(names: false);
    final token = sealVaultName('photos', nameKeys);
    c.currentPrefix = 'vault/$token/';
    c.objects = [];
    store.lock();
    final sent = engine.prefixes.length;
    await c.applyObjectFilter('vault/photos/a');
    expect(engine.prefixes, hasLength(sent));
    expect(c.objectFilterError, vaultNamesLockedFilter);
    c.updateVersionBrowserOptions(
        const VersionBrowserOptions(filterValue: 'vault/photos/a'));
    await c.refreshObjects();
    expect(engine.versionOptions.last.filterValue, 'vault/');
    // A rule this version cannot read may hide names in a way it cannot
    // reproduce, locked or not.
    await c.updateEncryptionKeys((s) => s.unlock('test-passphrase'));
    vault(policy: ClientEncryptionPolicy.unsupported, names: false);
    c.currentPrefix = 'vault/';
    c.objects = [];
    await c.applyObjectFilter('vault/photos/a');
    expect(c.objectFilterError, vaultPolicyUnsupportedFilter);
    expect(engine.prefixes.join('\n'), isNot(contains('photos')));
  });
  test('an unknown policy keeps a typed partial name out of every request',
      () async {
    vault(policy: ClientEncryptionPolicy.unsupported, names: false);
    c.objects = [];
    for (final typed in ['vault/secret', 'vault/secret/', 'vault/secret/x']) {
      await c.applyObjectFilter(typed);
      c.updateVersionBrowserOptions(VersionBrowserOptions(filterValue: typed));
      await c.refreshObjects();
      await c.copyBucketContents(
          sourceBucketName: 'bucket',
          destinationBucketName: 'copy',
          prefix: typed);
    }
    expect(engine.prefixes.join('\n'), isNot(contains('secret')));
    expect(engine.versionOptions.map((o) => o.filterValue).toSet(),
        {'', 'vault/'});
    expect(engine.actions, isEmpty);
    expect(retainedData(), isNot(contains('secret')));
  });
  test('encoded names in another location do not change a plain one', () async {
    final sealed = vault(prefix: 'sealed/');
    c.selectedProfile = c.selectedProfile!.copyWith(clientEncryptionRules: [
      sealed,
      sealed.copyWith(prefix: 'plain/', encryptNames: false)
    ]);
    final token = sealVaultName('photos', nameKeys);
    c.currentPrefix = 'sealed/$token/';
    c.objects = [object('sealed/$token/$token/', folder: true)];
    store.lock();
    await c.applyObjectFilter('plain/photos/a');
    expect(c.objectFilterError, isNull);
    expect(engine.prefixes.last, 'plain/photos/a');
    // A plain folder whose name happens to decode like a token is no parent
    // of encoded names when it is the rule's own prefix.
    c.selectedProfile = c.selectedProfile!.copyWith(clientEncryptionRules: [
      sealed.copyWith(
          prefix: 'AgencyContractsScannedCopies/', encryptNames: false)
    ]);
    c.currentPrefix = 'AgencyContractsScannedCopies/';
    c.objects = [];
    await c.applyObjectFilter('AgencyContractsScannedCopies/2024/a');
    expect(c.objectFilterError, isNull);
    expect(engine.prefixes.last, 'AgencyContractsScannedCopies/2024/a');
  });
  test('a legacy encoded tree guards the bucket copy prefix with names off',
      () async {
    vault(names: false);
    final token = sealVaultName('photos', nameKeys);
    c.selectedBucket = const BucketSummary(
        name: 'bucket',
        region: 'us-east-1',
        objectCountHint: 0,
        versioningEnabled: false);
    c.objects = [
      object('vault/$token/', folder: true),
      object('vault/plain/', folder: true)
    ];
    engine.listing = c.objects;
    store.lock();
    await c.copyBucketContents(
        sourceBucketName: 'bucket',
        destinationBucketName: 'copy',
        prefix: 'vault/photos/');
    expect(engine.actions, isEmpty);
    expect(c.bannerMessage, contains('encrypted names'));
    // Stored names, and a folder the listing shows under this very name.
    for (final stored in ['vault/$token/', 'vault/plain/']) {
      engine.actions.clear();
      await c.copyBucketContents(
          sourceBucketName: 'bucket',
          destinationBucketName: 'copy',
          prefix: stored);
      expect(engine.actions, contains('listObjects'), reason: stored);
    }
    // Nothing encoded is known: names are plaintext by the rule's setting.
    c.objects = [];
    engine.actions.clear();
    await c.copyBucketContents(
        sourceBucketName: 'bucket',
        destinationBucketName: 'copy',
        prefix: 'vault/reports/');
    expect(engine.actions, contains('listObjects'));
  });
  test('typed directory paths below hidden names are refused', () async {
    final token = sealVaultName('photos', nameKeys);
    for (final policy in [
      ClientEncryptionPolicy.standard,
      ClientEncryptionPolicy.strict,
      ClientEncryptionPolicy.unsupported
    ]) {
      vault(policy: policy);
      for (final action in [
        'listDirectories',
        'getDirectoryAccess',
        'setDirectoryAccess',
        'deleteDirectory'
      ]) {
        await expectLater(
            c.storageAction(action,
                arguments: {'bucketName': 'bucket', 'key': 'vault/photos'}),
            throwsA(isA<EngineException>()
                .having((e) => e.message, 'message', contains('stored'))),
            reason: '$policy $action');
      }
      expect(engine.actions, isEmpty);
      // The location itself and stored names are sent.
      for (final path in ['vault', 'vault/$token', 'vault/$token/$token/']) {
        await c.storageAction('listDirectories',
            arguments: {'bucketName': 'bucket', 'key': path});
      }
      expect(engine.actions, hasLength(3));
      engine.actions.clear();
    }
    vault(names: false);
    await c.storageAction('listDirectories',
        arguments: {'bucketName': 'bucket', 'key': 'vault/photos'});
    expect(engine.actions, ['listDirectories']);
  });
  test('generated test and benchmark data cannot reach a vault location',
      () async {
    vault();
    c.capabilities = [
      ...c.capabilities,
      for (final key in ['tools', 'benchmark'])
        CapabilityDescriptor(
            key: key, label: key, state: CapabilityState.supported)
    ];
    // Engines trim the benchmark prefix and add a slash, so the check uses
    // the keys they will write, not the text as typed.
    for (final prefix in ['vault/', 'vault/bench/', 'vault']) {
      c.updateTestDataConfig(
          c.testDataConfig.copyWith(bucketName: 'bucket', prefix: prefix));
      await c.runPutTestDataTool();
      expect(c.bannerMessage, contains('Generated data is not encrypted'),
          reason: 'test data "$prefix"');
      c.bannerMessage = null;
      c.updateBenchmarkDraft(
          c.benchmarkDraft.copyWith(bucketName: 'bucket', prefix: prefix));
      await c.startBenchmark();
      expect(c.bannerMessage, contains('Generated data is not encrypted'),
          reason: 'benchmark "$prefix"');
      c.bannerMessage = null;
    }
    expect(c.putTestDataState.running, isFalse);
    expect(c.benchmarkRun, isNull);
    // A rule prefix without a slash can also cover generated names.
    vault(prefix: 'b');
    c.updateBenchmarkDraft(
        c.benchmarkDraft.copyWith(bucketName: 'bucket', prefix: ''));
    await c.startBenchmark();
    expect(c.bannerMessage, contains('Generated data is not encrypted'));
    expect(c.benchmarkRun, isNull);
    c.bannerMessage = null;
    // Data that cannot reach the location is not refused: the default empty
    // prefix, a neighbouring prefix, and a bucket without a rule.
    vault();
    for (final prefix in ['', 'va', 'bench/']) {
      c.updateTestDataConfig(
          c.testDataConfig.copyWith(bucketName: 'bucket', prefix: prefix));
      await c.runPutTestDataTool();
      expect(c.bannerMessage ?? '', isNot(contains('Generated data')),
          reason: 'test data "$prefix"');
    }
    c.updateBenchmarkDraft(
        c.benchmarkDraft.copyWith(bucketName: 'other', prefix: 'vault/'));
    await c.startBenchmark();
    expect(c.bannerMessage ?? '', isNot(contains('Generated data')));
  });
  test('the benchmark with its default prefix runs beside a vault location',
      () async {
    vault(names: false);
    c.capabilities = [
      ...c.capabilities,
      const CapabilityDescriptor(
          key: 'benchmark',
          label: 'benchmark',
          state: CapabilityState.supported)
    ];
    c.updateBenchmarkDraft(
        c.benchmarkDraft.copyWith(bucketName: 'bucket', prefix: ''));
    await c.startBenchmark();
    expect(c.bannerMessage ?? '', isNot(contains('Generated data')));
  });
  test('a directory rename target is a typed path too', () async {
    final token = sealVaultName('photos', nameKeys);
    vault(names: false);
    c.selectedBucket = const BucketSummary(
        name: 'bucket',
        region: 'us-east-1',
        objectCountHint: 0,
        versioningEnabled: false);
    c.currentPrefix = 'vault/$token/';
    c.objects = [];
    // The source is a stored name; the new name is typed below known tokens.
    await expectLater(
        c.storageAction('renameDirectory', arguments: {
          'bucketName': 'bucket',
          'key': 'vault/$token',
          'destinationKey': 'vault/payroll'
        }),
        throwsA(isA<EngineException>()
            .having((e) => e.message, 'message', contains('stored'))));
    expect(engine.actions, isEmpty);
    // Nothing encoded is known: a plain vault renames directories as before.
    c.currentPrefix = 'vault/';
    await c.storageAction('renameDirectory', arguments: {
      'bucketName': 'bucket',
      'key': 'vault/reports',
      'destinationKey': 'vault/payroll'
    });
    expect(engine.actions, ['renameDirectory']);
  });
  test('a nested rule\'s encoded names say nothing about the rule around it',
      () async {
    final sealed = vault(prefix: 'sealed/');
    c.selectedProfile = c.selectedProfile!.copyWith(clientEncryptionRules: [
      sealed.copyWith(prefix: '', encryptNames: false),
      sealed
    ]);
    c.selectedBucket = const BucketSummary(
        name: 'bucket',
        region: 'us-east-1',
        objectCountHint: 0,
        versioningEnabled: false);
    final token = sealVaultName('photos', nameKeys);
    c.currentPrefix = '';
    c.objects = [object('sealed/$token/', folder: true)];
    for (final locked in [false, true]) {
      if (locked) store.lock();
      await c.applyObjectFilter('plain/photos/a');
      expect(c.objectFilterError, isNull, reason: 'locked=$locked');
      expect(engine.prefixes.last, 'plain/photos/a');
      c.objects = [object('sealed/$token/', folder: true)];
    }
    await c.storageAction('listDirectories',
        arguments: {'bucketName': 'bucket', 'key': 'plain/photos'});
    expect(engine.actions, ['listDirectories']);
  });
  test('whitespace the engines trim does not hide a vault prefix', () async {
    vault();
    c.capabilities = [
      ...c.capabilities,
      for (final key in ['tools', 'benchmark'])
        CapabilityDescriptor(
            key: key, label: key, state: CapabilityState.supported)
    ];
    // Engines do not agree on what they trim, so beside a vault location a
    // prefix with a blank at either end is refused whatever follows it.
    for (final prefix in [
      ' vault/',
      '\x1fvault/',
      '\x01vault',
      'vault/\x1f',
      '\u00a0vault/',
      '\x1f\ufeffvault/',
      '\ufeff\x1fvault/',
      ' elsewhere/',
      '   '
    ]) {
      c.updateBenchmarkDraft(
          c.benchmarkDraft.copyWith(bucketName: 'bucket', prefix: prefix));
      await c.startBenchmark();
      expect(c.bannerMessage, contains('generated data is not encrypted'),
          reason: 'benchmark ${prefix.codeUnits}');
      c.bannerMessage = null;
      c.updateTestDataConfig(
          c.testDataConfig.copyWith(bucketName: 'bucket', prefix: prefix));
      await c.runPutTestDataTool();
      expect(c.bannerMessage, contains('generated data is not encrypted'),
          reason: 'test data ${prefix.codeUnits}');
      c.bannerMessage = null;
    }
    // A dot segment may be resolved on the way, even into another bucket of
    // the connection, so it is refused wherever a vault rule exists.
    for (final target in [
      ('bucket', 'notes/../vault/'),
      ('bucket', './bench'),
      ('public', '../bucket/vault/'),
      ('public', '../..//bucket/vault/'),
    ]) {
      c.updateBenchmarkDraft(
          c.benchmarkDraft.copyWith(bucketName: target.$1, prefix: target.$2));
      await c.startBenchmark();
      expect(c.bannerMessage, contains('generated data is not encrypted'),
          reason: 'benchmark $target');
      c.bannerMessage = null;
      c.updateTestDataConfig(
          c.testDataConfig.copyWith(bucketName: target.$1, prefix: target.$2));
      await c.runPutTestDataTool();
      expect(c.bannerMessage, contains('generated data is not encrypted'),
          reason: 'test data $target');
      c.bannerMessage = null;
    }
    // A bucket name is one path segment: with a slash it could address the
    // vault's keys from outside.
    for (final bucket in [
      'bucket/vault',
      r'bucket\vault',
      '..',
      '.',
      '\x1f..\x1f',
      '..\x1c',
      'BUCKET',
      'Bucket',
      'b%75cket'
    ]) {
      c.updateBenchmarkDraft(
          c.benchmarkDraft.copyWith(bucketName: bucket, prefix: ''));
      await c.startBenchmark();
      expect(c.bannerMessage, contains('generated data is not encrypted'),
          reason: 'benchmark $bucket');
      c.bannerMessage = null;
      c.updateTestDataConfig(
          c.testDataConfig.copyWith(bucketName: bucket, prefix: ''));
      await c.runPutTestDataTool();
      expect(c.bannerMessage, contains('generated data is not encrypted'),
          reason: 'test data $bucket');
      c.bannerMessage = null;
      await expectLater(
          c.storageAction('copyObject', arguments: {
            'sourceBucketName': 'source',
            'sourceKey': 'payroll.txt',
            'destinationBucketName': bucket,
            'destinationKey': 'payroll.txt'
          }),
          throwsA(isA<EngineException>()),
          reason: 'copy $bucket');
      for (final action in ['planHistoryCopy', 'resumeHistoryCopy']) {
        await expectLater(
            c.storageAction(action, arguments: {
              'sourceBucketName': 'source',
              'destinationBucketName': bucket,
              'prefix': 'x/'
            }),
            throwsA(isA<EngineException>()),
            reason: '$action $bucket');
      }
    }
    expect(engine.actions, isEmpty);
    expect(c.benchmarkRun, isNull);
    // Every valid bucket name stays usable beside a vault location.
    final rules = c.selectedProfile!.clientEncryptionRules;
    for (final name in [
      'bucket',
      'my-bucket.example.com',
      'logs_2024',
      r'$root',
      r'$web',
      r'$logs',
      'Legacy_US_East',
      '0numbers'
    ]) {
      expect(vaultBucketIsCertain(rules, name), isTrue, reason: name);
    }
    expect(vaultBucketIsCertain(const [], '../x y'), isTrue);
    // A bucket name an engine would trim into the vault's bucket counts too.
    c.updateBenchmarkDraft(
        c.benchmarkDraft.copyWith(bucketName: '\x1fbucket', prefix: 'vault/'));
    await c.startBenchmark();
    expect(c.bannerMessage, contains('generated data is not encrypted'));
    expect(c.benchmarkRun, isNull);
    c.bannerMessage = null;
    // Without a vault rule in the bucket the same prefixes are left alone.
    c.updateBenchmarkDraft(
        c.benchmarkDraft.copyWith(bucketName: 'other', prefix: ' vault/'));
    await c.startBenchmark();
    expect(c.bannerMessage ?? '', isNot(contains('enerated data')));
  });
  test('a name that reaches a vault location only once trimmed is refused',
      () async {
    vault(names: false);
    for (final arguments in <Map<String, Object?>>[
      {'destinationBucketName': 'bucket', 'destinationKey': ' vault/a.txt'},
      {'destinationBucketName': 'bucket', 'destinationKey': '\x1fvault/a'},
      {'destinationBucketName': ' bucket', 'destinationKey': 'vault/a.txt'},
      {'destinationBucketName': 'bucket\u00a0', 'destinationKey': ' vault/a'},
    ]) {
      await expectLater(
          c.storageAction('copyObject', arguments: {
            'sourceBucketName': 'source',
            'sourceKey': 'a.txt',
            ...arguments
          }),
          throwsA(isA<EngineException>()
              .having((e) => e.message, 'message', contains('vault location'))),
          reason: '$arguments');
    }
    for (final action in ['planHistoryCopy', 'resumeHistoryCopy']) {
      await expectLater(
          c.storageAction(action, arguments: {
            'sourceBucketName': 'source',
            'destinationBucketName': ' bucket',
            'prefix': ' vault/'
          }),
          throwsA(isA<EngineException>()),
          reason: action);
    }
    expect(engine.actions, isEmpty);
    // Engines trim different sets, so one may stop where another goes on: a
    // rule prefix that itself starts with a blank is reached by a partial
    // trim only.
    final plain = c.selectedProfile!.clientEncryptionRules.single;
    c.selectedProfile = c.selectedProfile!.copyWith(clientEncryptionRules: [
      plain.copyWith(prefix: '\ufeffvault/', encryptNames: true)
    ]);
    c.currentPrefix = '';
    await c.createFolderMarker('\x1f\ufeffvault/payroll');
    expect(engine.folders, isEmpty);
    expect(c.bannerMessage, contains('vault location'));
    await expectLater(
        c.storageAction('copyObject', arguments: {
          'sourceBucketName': 'source',
          'sourceKey': 'a.txt',
          'destinationBucketName': 'bucket',
          'destinationKey': '\x1f\ufeffvault/a.txt'
        }),
        throwsA(isA<EngineException>()));
    // A trimmed reading may not move the target under a nested rule either.
    c.selectedProfile = c.selectedProfile!.copyWith(clientEncryptionRules: [
      plain.copyWith(prefix: ''),
      plain.copyWith(prefix: 'secret/', encryptNames: true)
    ]);
    await expectLater(
        c.storageAction('copyObject', arguments: {
          'sourceBucketName': 'source',
          'sourceKey': 'a.age',
          'destinationBucketName': 'bucket',
          'destinationKey': ' secret/x.age'
        }),
        throwsA(isA<EngineException>()
            .having((e) => e.message, 'message', contains('vault location'))));
    c.currentPrefix = '';
    c.bannerMessage = null;
    await c.createFolderMarker(' secret/new');
    expect(engine.folders, isEmpty);
    expect(c.bannerMessage, contains('vault location'));
    vault(names: false);
    c.currentPrefix = '';
    await c.createFolderMarker(' vault/new');
    expect(engine.folders, isEmpty);
    expect(c.bannerMessage, contains('vault location'));
    // Blanks that lead nowhere near a vault are ordinary names.
    await c.storageAction('copyObject', arguments: {
      'sourceBucketName': 'source',
      'sourceKey': 'a.txt',
      'destinationBucketName': 'bucket',
      'destinationKey': ' notes/a.txt'
    });
    expect(engine.moves.single['destinationKey'], ' notes/a.txt');
    await c.createFolderMarker(' notes');
    expect(engine.folders, [' notes/']);
    // With no rule at all nothing is examined.
    c.selectedProfile =
        c.selectedProfile!.copyWith(clientEncryptionRules: const []);
    await c.storageAction('copyObject', arguments: {
      'sourceBucketName': 'source',
      'sourceKey': 'a.txt',
      'destinationBucketName': 'bucket',
      'destinationKey': ' vault/a.txt'
    });
    expect(engine.moves.last['destinationKey'], ' vault/a.txt');
  });
  test('without the rule\'s key a token-shaped name still counts as hidden',
      () async {
    const lookalike = 'Accounts_receivable_2024';
    final rule = vault(names: false);
    // The key file is unlocked, but this rule's key is not in it.
    c.selectedProfile = c.selectedProfile!
        .copyWith(clientEncryptionRules: [rule.copyWith(keyId: 'missing-key')]);
    c.objects = [object('vault/$lookalike/', folder: true)];
    final sent = engine.prefixes.length;
    await c.applyObjectFilter('vault/reports/2024/');
    expect(engine.prefixes, hasLength(sent));
    expect(c.objectFilterError, vaultNamesKeyMissingFilter);
  });
  test('an upload an engine could read into a vault location is refused',
      () async {
    // Upload handlers turn backslashes into slashes and drop leading
    // slashes, and one drops a blank prefix.
    final rule = vault(names: false);
    final plain = await file('payroll.csv');
    c.currentPrefix = '';
    // On Windows a backslash is a directory separator. The mapped names
    // below exercise the same guard on every platform.
    if (!Platform.isWindows) {
      final backslash = await file(r'vault\payroll.txt');
      await c.startSampleUpload([backslash]);
      expect(engine.uploads, isEmpty);
      expect(c.bannerMessage, contains('backslash'));
    }
    for (final mapped in [r'vault\payroll.csv', '/vault/payroll.csv']) {
      c.bannerMessage = null;
      await c.startSampleUpload([plain], objectKeyByPath: {plain: mapped});
      expect(engine.uploads, isEmpty, reason: mapped);
      expect(c.bannerMessage, contains('backslash'), reason: mapped);
    }
    // A rule prefix without a slash, reached when a blank prefix is dropped.
    c.selectedProfile = c.selectedProfile!
        .copyWith(clientEncryptionRules: [rule.copyWith(prefix: 'payroll')]);
    c.currentPrefix = ' ';
    c.bannerMessage = null;
    await c.startSampleUpload([plain]);
    expect(engine.uploads, isEmpty);
    expect(c.bannerMessage, contains('backslash'));
    // An HTTP client may resolve dot segments, even out of the bucket.
    vault(names: false);
    c.currentPrefix = '';
    for (final mapped in [
      'notes/../vault/payroll.txt',
      './vault/payroll.txt',
      r'notes/..\vault\payroll.txt',
      'a/b/../../vault/x/../payroll.txt',
    ]) {
      c.bannerMessage = null;
      await c.startSampleUpload([plain], objectKeyByPath: {plain: mapped});
      expect(engine.uploads, isEmpty, reason: mapped);
      expect(c.bannerMessage, contains('dot segment'), reason: mapped);
    }
    // What lies above a key in the request path depends on the endpoint
    // (the bucket, an endpoint path such as an emulator's account name), so
    // a key that climbs out of its own root is refused wherever it points.
    final rules = c.selectedProfile!.clientEncryptionRules;
    for (final climbing in [
      '../..//bucket/vault/payroll.txt',
      '../bucket/vault/x',
      '../../devstoreaccount1/bucket/vault/x',
      '../vault/x',
      'a/../../x'
    ]) {
      expect(vaultTargetIsAmbiguous(rules, 'other', climbing), isTrue,
          reason: climbing);
    }
    for (final ordinary in [
      '.gitignore',
      '...',
      'a..b',
      'v1.2/',
      './file',
      'x/./y',
      'a/b/../c',
      ''
    ]) {
      expect(vaultTargetIsAmbiguous(rules, 'other', ordinary), isFalse,
          reason: ordinary);
    }
    expect(vaultTargetIsAmbiguous(const [], 'other', '../../x'), isFalse);
    expect(
        vaultTargetIsAmbiguous(c.selectedProfile!.clientEncryptionRules,
            'bucket', 'notes/../reports/x'),
        isFalse);
    await expectLater(
        c.storageAction('copyObject', arguments: {
          'sourceBucketName': 'source',
          'sourceKey': 'a.txt',
          'destinationBucketName': 'bucket',
          'destinationKey': 'notes/../vault/a.txt'
        }),
        throwsA(isA<EngineException>()));
    // Two engines trim a mapped name before adding the prefix, and Java's
    // trim removes control characters that Dart's keeps.
    c.selectedProfile = c.selectedProfile!.copyWith(
        clientEncryptionRules: [rule.copyWith(prefix: 'docs/secret')]);
    c.currentPrefix = 'docs/';
    for (final mapped in ['\x01secret/a.txt', ' secret/a.txt']) {
      c.bannerMessage = null;
      await c.startSampleUpload([plain], objectKeyByPath: {plain: mapped});
      expect(engine.uploads, isEmpty, reason: mapped.codeUnits.toString());
      expect(c.bannerMessage, contains('backslash'));
    }
    // A name that trims from one rule into a nested one.
    c.selectedProfile = c.selectedProfile!.copyWith(clientEncryptionRules: [
      rule,
      rule.copyWith(
          prefix: 'vault/secret', policy: ClientEncryptionPolicy.strict)
    ]);
    c.currentPrefix = 'vault/';
    final spaced = await file(' secret.txt');
    c.bannerMessage = null;
    await c.startSampleUpload([spaced]);
    expect(engine.uploads, isEmpty);
    expect(c.bannerMessage, contains('backslash'));
    // Names that every engine reads the same way upload as before, inside
    // and outside the location, and so does anything without a vault rule.
    vault(names: false);
    c.currentPrefix = '';
    final leading = await file(' notes.txt');
    await c.startSampleUpload([plain],
        objectKeyByPath: {plain: r'notes\today.txt'});
    await c.startSampleUpload([leading]);
    await c.startSampleUpload([plain],
        objectKeyByPath: {plain: 'photos/2024/a.jpg'});
    expect(engine.uploads, hasLength(3));
    c.selectedProfile =
        c.selectedProfile!.copyWith(clientEncryptionRules: const []);
    await c.startSampleUpload([plain],
        objectKeyByPath: {plain: r'vault\payroll.txt'});
    expect(engine.uploads, hasLength(4));
  });
  test('an ordinary name shaped like a token is no evidence once unlocked',
      () async {
    // Canonical base64url, long enough, first byte 1: the shape of a token.
    const lookalike = 'Accounts_receivable_2024';
    expect(looksLikeVaultToken(lookalike), isTrue);
    vault(names: false);
    c.objects = [object('vault/$lookalike/', folder: true)];
    await c.applyObjectFilter('vault/reports/2024/');
    expect(c.objectFilterError, isNull);
    expect(engine.prefixes.last, 'vault/reports/2024/');
    await c.storageAction('listDirectories',
        arguments: {'bucketName': 'bucket', 'key': 'vault/reports'});
    expect(engine.actions, ['listDirectories']);
  });
  test('typed paths below a legacy encoded tree, and listed paths', () async {
    final token = sealVaultName('photos', nameKeys);
    // Names off, but the listing shows an encoded folder below the rule.
    vault(names: false);
    c.selectedBucket = const BucketSummary(
        name: 'bucket',
        region: 'us-east-1',
        objectCountHint: 0,
        versioningEnabled: false);
    c.objects = [object('vault/$token/', folder: true)];
    await expectLater(
        c.storageAction('listDirectories',
            arguments: {'bucketName': 'bucket', 'key': 'vault/payroll'}),
        throwsA(isA<EngineException>()));
    expect(engine.actions, isEmpty);
    // Unlocked, an unresolved name at the rule root is sealed, not sent.
    await c.applyObjectFilter('vault/payroll/x');
    expect(
        engine.prefixes.last, 'vault/${sealVaultName('payroll', nameKeys)}/');
    expect(engine.prefixes.join('\n'), isNot(contains('payroll')));
    // With names on, a plaintext directory the provider listed is a stored
    // name and stays usable; one nobody listed is not.
    vault();
    c.objects = [];
    engine.directoryItems = [
      {'name': 'vault/plain', 'isDirectory': true}
    ];
    await c.storageAction('listDirectories',
        arguments: {'bucketName': 'bucket', 'key': 'vault'});
    for (final action in ['listDirectories', 'getDirectoryAccess']) {
      await c.storageAction(action,
          arguments: {'bucketName': 'bucket', 'key': 'vault/plain'});
    }
    await expectLater(
        c.storageAction('listDirectories',
            arguments: {'bucketName': 'bucket', 'key': 'vault/other'}),
        throwsA(isA<EngineException>()));
    // A stored copy prefix needs no trailing slash.
    engine.listing = [];
    for (final stored in ['vault/$token', 'vault/$token/$token.age']) {
      engine.actions.clear();
      await c.copyBucketContents(
          sourceBucketName: 'bucket',
          destinationBucketName: 'copy',
          prefix: stored);
      expect(engine.actions, contains('listObjects'), reason: stored);
    }
  });
  test(
      'versions send stored prefixes on both pages and filter visible names locally',
      () async {
    final rule = vault();
    String stored(String name) => encodeVaultObjectKey(
        rule: rule,
        keys: nameKeys,
        destinationPrefix: 'vault/',
        relativeName: 'photos/$name.jpg');
    final a = stored('aaa'), z = stored('zzz');
    ObjectVersionEntry version(String key) => ObjectVersionEntry(
        key: key,
        versionId: key,
        modifiedAt: DateTime.utc(2026),
        latest: true,
        deleteMarker: false,
        size: 10);
    engine.versionListing = [version(a), version(z)];
    engine.moreVersions = true;
    c.updateVersionBrowserOptions(
        const VersionBrowserOptions(filterValue: 'vault/photos/a'));
    await c.refreshObjects();
    final prefix = 'vault/${sealVaultName('photos', nameKeys)}/';
    expect(engine.versionOptions.last.filterValue, prefix);
    expect(c.versions, hasLength(2));
    expect(c.visibleVersions.single.key, a);
    await c.loadMoreVersions();
    expect(engine.versionOptions, hasLength(2));
    expect(engine.versionOptions.last.filterValue, prefix);
    expect(c.versionBrowserOptions.filterValue, 'vault/photos/a');
    expect(c.visibleVersions.single.key, a);
    // Disabling uploads does not stop browsing an encoded current prefix.
    vault(names: false);
    c.currentPrefix = prefix;
    c.versionCursor = const ListCursor(value: 'another', hasMore: true);
    await c.loadMoreVersions();
    expect(engine.versionOptions.last.filterValue, prefix);
  });
  test(
      'prefix reads reuse loaded encoded folders with names off and tolerate a locked or unsupported rule',
      () async {
    vault(names: false);
    final token = sealVaultName('photos', nameKeys);
    final folder = object('vault/$token/', folder: true);
    c.objects = [folder];
    engine.listing = [folder];
    await c.applyObjectFilter('vault/photos/a');
    expect(engine.prefixes.last, folder.key);
    vault(policy: ClientEncryptionPolicy.unsupported, names: false);
    c.objects = [folder];
    await c.applyObjectFilter('vault/photos/a');
    expect(engine.prefixes.last, folder.key);
    expect(c.objectFilterError, isNull);
    vault();
    store.lock();
    // Locked, the typed folder name cannot be translated. It must never be
    // sent in its place: nothing is listed and the filter says why.
    final sent = engine.prefixes.length;
    await c.applyObjectFilter('vault/photos/a');
    expect(engine.prefixes, hasLength(sent));
    expect(engine.prefixes.join('\n'), isNot(contains('photos')));
    expect(c.objectFilterError, vaultNamesLockedFilter);
    // A folder already in the listing needs no key.
    c.objects = [folder];
    await c.applyObjectFilter('vault/$token/a');
    expect(engine.prefixes.last, folder.key);
    expect(c.objectFilterError, isNull);
    vault(names: false);
    store.lock();
    c.objects = [];
    await c.applyObjectFilter('vault/plain/a');
    // Nothing here is encoded and the rule leaves names alone, so the server
    // filters on the partial segment exactly as it did before name encryption.
    expect(engine.prefixes.last, 'vault/plain/a');
    expect(c.objectFilterError, isNull);
  });
  test(
      'prefix reads prefer loaded plaintext folders and derive descendants of stored tokens',
      () async {
    vault();
    final plain = object('vault/plain/', folder: true);
    c.objects = [plain];
    engine.listing = [plain];
    await c.applyObjectFilter('vault/plain/a');
    expect(engine.prefixes.last, plain.key);
    vault(names: false);
    final photos = sealVaultName('photos', nameKeys);
    c.currentPrefix = 'vault/$photos/';
    c.objects = [];
    await c.applyObjectFilter('vault/photos/2024/a');
    expect(engine.prefixes.last,
        'vault/$photos/${sealVaultName('2024', nameKeys)}/');
    store.lock();
    // Below a stored token a typed name is taken for a hidden one. Locked, it
    // is refused instead of being sent as typed.
    final sent = engine.prefixes.length;
    await c.applyObjectFilter('vault/$photos/plain/a');
    expect(engine.prefixes, hasLength(sent));
    expect(c.objectFilterError, vaultNamesLockedFilter);
  });
  test(
      'unconfigured listing options and administrative requests remain unchanged',
      () async {
    c.currentPrefix = 'plain/';
    const options = VersionBrowserOptions(filterValue: 'plain/partial');
    c.updateVersionBrowserOptions(options);
    await c.applyObjectFilter('plain/partial');
    expect(engine.prefixes.last, 'plain/partial');
    expect(identical(engine.versionOptions.last, options), isTrue);
    await c.storageAction('startResumableUpload',
        arguments: {'bucketName': 'bucket', 'key': 'plain/upload'});
    expect(engine.actions, ['startResumableUpload']);
  });
  test(
      'listing sorts and filters decoded names; lock falls back and unlock rebuilds',
      () async {
    final r = vault();
    String stored(String name) => encodeVaultObjectKey(
        rule: r,
        keys: nameKeys,
        destinationPrefix: 'vault/',
        relativeName: name);
    final a = object(stored('aaa.txt')), z = object(stored('zzz.txt'));
    c.objects = [z, a];
    c.setObjectFilterMode(BrowserFilterMode.text);
    expect(c.visibleObjects, [a, z]);
    await c.applyObjectFilter('aaa');
    expect(c.visibleObjects, [a]);
    store.lock();
    expect(c.visibleObjectKey(a), a.key.substring(0, a.key.length - 4));
    expect(c.clientKeyUnlockRequired, isTrue);
    expect(c.visibleObjects, isEmpty);
    await c.updateEncryptionKeys((s) => s.unlock('test-passphrase'));
    expect(c.visibleObjectName(a), 'aaa.txt');
    expect(c.visibleObjects, [a]);
    c.setObjectFilterMode(BrowserFilterMode.regex);
    await c.applyObjectFilter(r'aaa\.txt$');
    c.visibleObjects; // Launch the bounded regex worker.
    for (var i = 0; i < 100 && c.filteringObjects; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    expect(c.visibleObjects, [a]);
  });
  test(
      'prefix filter lists complete stored segments and filters a visible partial',
      () async {
    final r = vault();
    final key = encodeVaultObjectKey(
        rule: r,
        keys: nameKeys,
        destinationPrefix: 'vault/',
        relativeName: 'photos/a.jpg');
    engine.listing = [object(key)];
    await c.applyObjectFilter('vault/photos/a');
    expect(engine.prefixes.last, 'vault/${sealVaultName('photos', nameKeys)}/');
    expect(c.currentPrefix, engine.prefixes.last);
    expect(c.objectFilterValue, 'vault/photos/a');
    expect(c.visibleObjects.single.key, key);
    await c.applyObjectFilter('vault/photos/z');
    expect(c.visibleObjects, isEmpty);
  });
  test(
      'strict prefix filtering stays on its location and treats slashes as visible text',
      () async {
    final r = vault(policy: ClientEncryptionPolicy.strict);
    final a = encodeVaultObjectKey(
        rule: r,
        keys: nameKeys,
        destinationPrefix: 'vault/',
        relativeName: 'photos/a.jpg');
    final b = encodeVaultObjectKey(
        rule: r,
        keys: nameKeys,
        destinationPrefix: 'vault/',
        relativeName: 'reports/a.jpg');
    engine.listing = [object(a), object(b)];
    await c.applyObjectFilter('vault/photos/a');
    expect(engine.prefixes.last, 'vault/');
    expect(c.objectFilterValue, 'vault/photos/a');
    expect(c.visibleObjects.single.key, a);
    await c.renameObject(a, 'vault/photos/b.jpg');
    final dest = engine.moves.last['destinationKey'] as String;
    expect(dest, isNot(a));
    expect(dest.split('/'), hasLength(2));
    expect(decodeVaultKey(dest, r, {keyId: nameKeys}), 'vault/photos/b.jpg');
  });
  test('the current encoded prefix displays and navigates with stored segments',
      () async {
    vault();
    final photos = sealVaultName('photos', nameKeys);
    final year = sealVaultName('2024', nameKeys);
    c.currentPrefix = 'vault/$photos/$year/';
    expect(c.visiblePrefix(c.currentPrefix), 'vault/photos/2024/');
    await c.navigateUp();
    expect(c.currentPrefix, 'vault/$photos/');
    expect(c.objectFilterValue, 'vault/photos/');
    await c.applyObjectFilter('');
    expect(c.currentPrefix, '');
  });
  test(
      'decrypted download receives only visible basename; encrypted copy gets no fileName; no diagnostic leaks',
      () async {
    const distinctive = 'PRIVATE:name-EXACT-8429.txt';
    const sanitized = 'PRIVATE_name-EXACT-8429.txt';
    const collision = 'PRIVATE_name-EXACT-8429 (1).txt';
    engine.noisyDownload = true;
    final bucket = c.selectedBucket;
    await c.initialize();
    c.selectedBucket = bucket;
    final r = vault();
    final path = await file('upload.txt');
    await c.startSampleUpload([path], objectKeyByPath: {path: distinctive});
    final stored = uploadedKey();
    var progressUpdates = 0;
    engine.afterDownloadProgress = () {
      progressUpdates++;
      for (final hidden in [distinctive, sanitized, collision, path]) {
        expect(retainedData(), isNot(contains(hidden)));
      }
      expect(retainedData(), contains('Unrelated transfer line survives.'));
    };
    final fixture =
        await clientFixture(Uint8List.fromList([1, 2, 3]), identity);
    ciphertext[stored] = fixture.bytes;
    c.objects = [object(stored, size: fixture.bytes.length)];
    await c.startSampleDownload(key: stored);
    expect((engine.downloads.single['clientEncryption'] as Map)['fileName'],
        distinctive);
    engine.throwDownload = true;
    await c.startSampleDownload(key: stored);
    engine.throwDownload = false;
    await c.startSampleDownload(key: stored, encryptedCopy: true);
    expect(engine.downloads.last.containsKey('clientEncryption'), isFalse);
    expect(progressUpdates, 2);
    expect(
        c.eventLog
            .any((e) => e.category == 'DownloadTrace' && e.traceBody != null),
        isTrue);
    for (final hidden in [distinctive, sanitized, collision, path]) {
      expect(retainedData(), isNot(contains(hidden)));
    }
    expect(retainedData(), contains('Unrelated transfer line survives.'));
    expect(retainedData(), isNot(contains(identity.secretKey)));
    expect(
        retainedData(), isNot(contains(base64Encode(nameKeys.deterministic))));
    await c.retrySaveSettings();
    final exported = await repository.exportProfiles(
        profiles: [c.selectedProfile!], path: '${dir.path}/profiles.json');
    expect(await exported.readAsString(), isNot(contains(distinctive)));
    await for (final entry in dir.list()) {
      if (entry is File && entry.path.endsWith('.json')) {
        final persisted = await entry.readAsString();
        for (final hidden in [distinctive, sanitized, collision, path]) {
          expect(persisted, isNot(contains(hidden)));
        }
      }
    }
    expect(decodeVaultKey(stored, r, {keyId: nameKeys}), 'vault/$distinctive');
  });
}
