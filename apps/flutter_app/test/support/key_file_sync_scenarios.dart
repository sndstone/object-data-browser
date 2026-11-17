// Runnable with plain Dart as well as through key_file_sync_test.dart.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';
import 'package:s3_browser_crossplat/models/domain_models.dart';
import 'package:s3_browser_crossplat/services/crypto/age.dart';
import 'package:s3_browser_crossplat/services/encryption_key_store.dart';
import 'package:s3_browser_crossplat/services/key_file_merge.dart';
import 'package:s3_browser_crossplat/services/key_file_sync.dart';
import 'package:s3_browser_crossplat/services/key_file_sync_transport.dart';

const passphrase = 'sync fixture passphrase';
const nextPassphrase = 'another sync passphrase';
const config = KeyFileSyncConfig(profileId: 'p', bucket: 'keys');
void check(bool value, String message) {
  if (!value) throw StateError(message);
}

Future<void> fails<T>(Future<void> Function() run) async {
  try {
    await run();
  } catch (error) {
    check(error is T, 'Unexpected failure type');
    return;
  }
  throw StateError('Expected $T');
}

Future<Map<String, Object?>> document(EncryptionKeyStore store,
        {String password = passphrase}) async =>
    jsonDecode(utf8.decode(await ageDecrypt(await store.encryptedBytes(),
        passphrase: password))) as Map<String, Object?>;
Future<Uint8List> encrypt(Map<String, Object?> document,
        {String password = passphrase}) =>
    ageEncrypt(Uint8List.fromList(utf8.encode(jsonEncode(document))),
        passphrase: password, scryptWorkFactor: 1);
Map<String, Object?> doc(List<Object?> keys,
        {List<Object?> removed = const [], int clock = 0}) =>
    {
      'format': EncryptionKeyStore.formatName,
      'version': 1,
      'clock': clock,
      'keys': keys,
      'removed': removed,
    };
Map<String, Object?> live(String id, int rev, String by,
        {String label = 'Key'}) =>
    {
      'id': id,
      'rev': rev,
      'by': by,
      'label': label,
      'type': 'futureType',
      'secret': 'opaque',
      'extension': {'kept': true},
    };
Map<String, Object?> tomb(String id, int rev, String by) => {
      'id': id,
      'rev': rev,
      'by': by,
      'removedAt': '2026-11-15T00:00:00Z',
    };

class MemoryS3 {
  Uint8List? bytes;
  int version = 0, requests = 0, puts = 0, active = 0, maxActive = 0;
  bool versioning = true, unsupported = false, ignored = false;
  int? failStatus;
  Future<void> Function()? beforePut;
  Future<void> Function(String)? beforeRequest;
  final versions = <String, Uint8List>{};
  final requestBodies = <List<int>>[];
  String get etag => '"generation-$version"';
  void write(Uint8List value) {
    bytes = Uint8List.fromList(value);
    version++;
    if (versioning) versions['$version'] = bytes!;
  }

  KeyFileSyncTransport client() => MemoryTransport(this);
  Future<KeyFileSyncResponse> request(String method, String bucket,
      {String? key,
      Map<String, String> query = const {},
      Map<String, String> headers = const {},
      List<int> body = const []}) async {
    requests++;
    active++;
    maxActive = max(maxActive, active);
    requestBodies.add(List.of(body));
    try {
      await beforeRequest?.call(method);
      KeyFileSyncResponse response(int status, [List<int> value = const []]) =>
          KeyFileSyncResponse(
              status,
              {'etag': etag, 'x-amz-version-id': '$version'},
              Uint8List.fromList(value));
      if (failStatus != null) return response(failStatus!);
      if (query.containsKey('versioning')) {
        if (method == 'PUT') versioning = true;
        return response(
            200,
            utf8.encode(
                '<VersioningConfiguration>${versioning ? '<Status>Enabled</Status>' : ''}</VersioningConfiguration>'));
      }
      if (query.containsKey('versions')) {
        return response(
            200,
            utf8.encode(
                '<ListVersionsResult><IsTruncated>false</IsTruncated>${versions.entries.map((e) => '<Version><Key>${config.objectKey}</Key><VersionId>${e.key}</VersionId><LastModified>2026-11-15T00:00:00Z</LastModified><Size>${e.value.length}</Size></Version>').join()}</ListVersionsResult>'));
      }
      if (method == 'GET' || method == 'HEAD') {
        final value = query.containsKey('versionId')
            ? versions[query['versionId']]
            : bytes;
        return value == null
            ? response(404)
            : response(200, method == 'HEAD' ? [] : value);
      }
      if (method == 'PUT') {
        puts++;
        final callback = beforePut;
        beforePut = null;
        await callback?.call();
        if (unsupported && headers.keys.any((h) => h.startsWith('if-'))) {
          return response(501);
        }
        if (!ignored &&
            ((headers['if-none-match'] == '*' && bytes != null) ||
                (headers['if-match'] != null && headers['if-match'] != etag))) {
          return response(412);
        }
        write(Uint8List.fromList(body));
        return response(200);
      }
      return response(400);
    } finally {
      active--;
    }
  }
}

class MemoryTransport implements KeyFileSyncSetupTransport {
  MemoryTransport(this.server);
  final MemoryS3 server;
  @override
  Future<KeyFileSyncResponse> request(String method, String bucket,
          {String? key,
          Map<String, String> query = const {},
          Map<String, String> headers = const {},
          List<int> body = const []}) =>
      server.request(method, bucket,
          key: key, query: query, headers: headers, body: body);
  @override
  Future<List<String>> buckets() async => ['keys'];
  @override
  Future<void> createBucket(String bucket) async {
    server.versioning = true;
  }

  @override
  void close() {}
}

class Pair {
  Pair(this.directory, this.a, this.b);
  final Directory directory;
  final EncryptionKeyStore a, b;
  final server = MemoryS3();
  final syncs = <KeyFileSync>[];
  KeyFileSyncTransport Function()? transportFactory;
  KeyFileSync sync(EncryptionKeyStore store,
      {Duration debounce = const Duration(days: 1)}) {
    final result = KeyFileSync(
        store: store,
        config: config,
        transport: transportFactory?.call() ?? server.client(),
        debounce: debounce);
    syncs.add(result);
    return result;
  }

  Future<void> converge(KeyFileSync aSync, KeyFileSync bSync,
      {bool reverse = false, String password = passphrase}) async {
    for (var i = 0; i < 2; i++) {
      await (reverse ? bSync : aSync).syncNow();
      await (reverse ? aSync : bSync).syncNow();
    }
    check(
        ![aSync, bSync].any((s) =>
            s.status == KeyFileSyncStatus.error ||
            s.status == KeyFileSyncStatus.passphraseMismatch),
        'Sync did not succeed');
    final left = normalizedKeyFileJson(await document(a, password: password));
    final right = normalizedKeyFileJson(await document(b, password: password));
    final remote = normalizedKeyFileJson(jsonDecode(
            utf8.decode(await ageDecrypt(server.bytes!, passphrase: password)))
        as Map<String, Object?>);
    check(
        left == right && left == remote, 'Devices and bucket did not converge');
  }
}

typedef TransportHarness = ({
  KeyFileSyncTransport Function() create,
  Future<void> Function() close
});
Future<TransportHarness> Function(MemoryS3)? transportHarness;

Future<void> pair(Future<void> Function(Pair) run,
    {String password = passphrase}) async {
  final directory = await Directory.systemTemp.createTemp('key-sync-check-');
  final fixture = Pair(
      directory,
      EncryptionKeyStore(File('${directory.path}/a.age'),
          deviceId: 'aaaaaaaaaaaaaaaa', scryptWorkFactor: 1),
      EncryptionKeyStore(File('${directory.path}/b.age'),
          deviceId: 'bbbbbbbbbbbbbbbb', scryptWorkFactor: 1));
  TransportHarness? harness;
  try {
    harness = await transportHarness?.call(fixture.server);
    fixture.transportFactory = harness?.create;
    await fixture.a.create(password);
    await fixture.b.create(password);
    await run(fixture);
  } finally {
    for (final sync in fixture.syncs) {
      sync.dispose();
    }
    await harness?.close();
    fixture.a.lock();
    fixture.b.lock();
    await directory.delete(recursive: true);
  }
}

final scenarios = <String, Future<void> Function()>{
  'merge algebra: 250 fixed-seed random documents in every order': () async {
    final random = Random(73921);
    var documentId = 0;
    Map<String, Object?> randomDoc() {
      final keys = <Object?>[], removed = <Object?>[];
      for (var i = 0; i < 12; i++) {
        if (random.nextBool()) continue;
        final rev = random.nextInt(8), by = ['a', 'b', ''][random.nextInt(3)];
        if (random.nextBool()) {
          keys.add(live('$i', rev, by, label: '${random.nextInt(4)}'));
        } else {
          removed.add(tomb('$i', rev, by));
        }
      }
      return {
        ...doc(keys, removed: removed, clock: random.nextInt(12)),
        'future-${documentId++}': {
          'opaque': [true, 7, 'retained']
        }
      };
    }

    for (var i = 0; i < 250; i++) {
      final a = randomDoc(), b = randomDoc(), c = randomDoc();
      final ab = mergeKeyFileDocuments(a, b), ba = mergeKeyFileDocuments(b, a);
      check(canonicalKeyFileJson(ab) == canonicalKeyFileJson(ba),
          'Commutativity');
      check(
          canonicalKeyFileJson(mergeKeyFileDocuments(ab, c)) ==
              canonicalKeyFileJson(
                  mergeKeyFileDocuments(a, mergeKeyFileDocuments(b, c))),
          'Associativity');
      check(
          canonicalKeyFileJson(mergeKeyFileDocuments(a, a)) ==
              normalizedKeyFileJson(a),
          'Idempotence');
      final expected = canonicalKeyFileJson(mergeKeyFileDocuments(ab, c));
      for (final order in [
        [a, b, c],
        [a, c, b],
        [b, a, c],
        [b, c, a],
        [c, a, b],
        [c, b, a]
      ]) {
        check(
            canonicalKeyFileJson(mergeKeyFileDocuments(
                    mergeKeyFileDocuments(order[0], order[1]), order[2])) ==
                expected,
            'Permutation convergence');
      }
    }
  },
  'merge tombstones, legacy stamps, ties, opaque records and duplicate secrets':
      () async {
    final legacy = live('legacy', 0, '')
      ..remove('rev')
      ..remove('by');
    final a = doc([
      live('x', 3, 'a'),
      legacy,
      live('duplicate1', 2, 'a'),
      live('duplicate2', 2, 'a')
    ], removed: [
      tomb('y', 2, 'a')
    ]);
    final b = doc([live('y', 3, 'a')], removed: [tomb('x', 4, 'b')]);
    final merged = mergeKeyFileDocuments(a, b);
    check((merged['keys'] as List).length == 4, 'Live key count');
    check((merged['removed'] as List).length == 1 && merged['clock'] == 4,
        'Tombstone/clock');
    final tie = mergeKeyFileDocuments(doc([live('x', 1, 'a', label: 'z')]),
        doc([live('x', 1, 'a', label: 'a')], removed: [tomb('x', 1, 'a')]));
    check(((tie['keys'] as List).single as Map)['label'] == 'a',
        'Canonical tie/live preference');
    check(
        (((tie['keys'] as List).single as Map)['extension'] as Map)['kept'] ==
            true,
        'Unknown entry fields');
    final top = mergeKeyFileDocuments({...a, 'local': 42, 'clash': 'local'},
        {...b, 'remote': 43, 'clash': 'remote'});
    final reversed = mergeKeyFileDocuments(
        {...b, 'remote': 43, 'clash': 'remote'},
        {...a, 'local': 42, 'clash': 'local'});
    // A clash is settled by value, not by side, so both orders agree.
    check(
        top['local'] == 42 &&
            top['remote'] == 43 &&
            top['clash'] == 'remote' &&
            reversed['clash'] == 'remote',
        'Top-level fields kept from both sides with a side-independent clash');
  },
  'store stamps mutations, deletes, restores by additive import and keeps passphrase clock':
      () => pair((p) async {
            check(p.a.clock == 0 && p.a.passphraseMeetsSyncPolicy,
                'Initial clock/policy');
            final key = await p.a.generateCustomerKey('one');
            final backup = await p.a.encryptedBytes();
            check(p.a.clock == 1, 'Generate clock');
            await p.a.rename(key.id, 'renamed');
            check(p.a.clock == 2, 'Rename clock');
            final renamed =
                ((await document(p.a))['keys'] as List).single as Map;
            check(renamed['rev'] == 2 && renamed['by'] == p.a.deviceId,
                'Revision stamp');
            await p.a.delete(key.id);
            check(p.a.clock == 3, 'Delete clock');
            final deleted = await document(p.a);
            check(
                (deleted['removed'] as List).length == 1, 'Deletion tombstone');
            await p.a.importEncrypted(backup, passphrase);
            check(p.a.records.single.id == key.id && p.a.clock == 4,
                'Additive restoration');
            await p.a.mergeEncrypted(await encrypt(deleted), passphrase);
            check(p.a.records.length == 1,
                'Old tombstone cannot remove restored key');
            await p.a.changePassphrase(passphrase, nextPassphrase);
            check(p.a.clock == 4, 'Passphrase changes clock');
          }),
  'store merge reports counts, no-op keeps bytes, errors leave ciphertext unchanged':
      () => pair((p) async {
            final one = await p.a.generateCustomerKey('one');
            await p.b.mergeEncrypted(await p.a.encryptedBytes(), passphrase);
            await p.b.rename(one.id, 'new');
            await p.b.generateCustomerKey('two');
            final result = await p.a
                .mergeEncrypted(await p.b.encryptedBytes(), passphrase);
            check(
                result.added == 1 &&
                    result.updated == 1 &&
                    result.removed == 0 &&
                    result.localChanged &&
                    !result.remoteDiffers,
                'Merge counts');
            final before = await p.a.encryptedBytes();
            final noop = await p.a
                .mergeEncrypted(await p.b.encryptedBytes(), passphrase);
            check(
                !noop.localChanged &&
                    !noop.remoteDiffers &&
                    base64Encode(await p.a.encryptedBytes()) ==
                        base64Encode(before),
                'No-op rewrite');
            await fails<EncryptionKeyStoreWrongPassphraseException>(() async {
              await p.a.mergeEncrypted(await p.b.encryptedBytes(), 'wrong');
            });
            await fails<EncryptionKeyStoreCorruptException>(() async {
              await p.a
                  .mergeEncrypted(Uint8List.fromList([1, 2, 3]), passphrase);
            });
            await fails<EncryptionKeyStoreUnsupportedVersionException>(
                () async {
              await p.a.mergeEncrypted(
                  await encrypt({...doc([]), 'version': 2}), passphrase);
            });
            check(
                base64Encode(await p.a.encryptedBytes()) ==
                    base64Encode(before),
                'Failed merge changed file');
            await p.b.delete(one.id);
            final deleted = await p.a
                .mergeEncrypted(await p.b.encryptedBytes(), passphrase);
            check(deleted.removed == 1, 'Merge removed count');
          }),
  'store merge keeps the same customer secret under different ids and opaque fields':
      () => pair((p) async {
            await p.a.importCustomerKey(
                'a', Uint8List.fromList(List.filled(32, 17)));
            final local = await document(p.a);
            final copy =
                Map<String, Object?>.from((local['keys'] as List).single as Map)
                  ..['id'] = 'different-id'
                  ..['extension'] = {'kept': true};
            final incoming = {
              ...doc([copy, live('opaque', 9, 'future')]),
              'futureTop': {'x': true}
            };
            final result =
                await p.a.mergeEncrypted(await encrypt(incoming), passphrase);
            check(
                result.added == 2 &&
                    p.a.records.length == 2 &&
                    p.a.unsupportedKeyCount == 1,
                'Merge deduplicated key material');
            final merged = await document(p.a);
            check((merged['futureTop'] as Map)['x'] == true && p.a.clock == 9,
                'Unknown fields/highest seen clock');
            await p.a.generateCustomerKey('new');
            check(p.a.clock == 10, 'Local clock after merge');
          }),
  'legacy files still open and retain opaque fields': () => pair((p) async {
        final old = {
          'format': EncryptionKeyStore.formatName,
          'version': 1,
          'keys': [
            live('opaque', 0, '')
              ..remove('rev')
              ..remove('by')
          ],
          'future': {'x': true}
        };
        p.a.lock();
        await p.a.file.writeAsBytes(await encrypt(old));
        await p.a.unlock(passphrase);
        check(p.a.clock == 0 && p.a.unsupportedKeyCount == 1, 'Legacy opening');
        await p.a.generateCustomerKey('new');
        final now = await document(p.a);
        check(
            (now['future'] as Map)['x'] == true &&
                (now['keys'] as List).length == 2,
            'Opaque retention');
      }),
  'sync first push, fresh pull, versioning state and encrypted request/versions scan':
      () => pair((p) async {
            final secret = Uint8List.fromList(List.generate(32, (i) => i + 1));
            await p.a.importCustomerKey('secret', secret);
            const identity =
                'AGE-SECRET-KEY-1033L492W9NWEWSPU09LUJCAZZQZGTM7RXV8QMLTTH4YENQAYZ2TSAWU55M';
            await p.a.importAgeIdentity('vault', identity);
            final a = p.sync(p.a), b = p.sync(p.b);
            await a.refreshVersioning();
            check(a.state.versioningEnabled == true, 'Versioning read');
            await p.converge(a, b);
            check(p.b.records.length == 2 && a.state.lastSyncedAt != null,
                'First push/pull');
            final secrets = [
              secret,
              utf8.encode(base64Encode(secret)),
              utf8.encode(passphrase),
              utf8.encode(identity),
              utf8.encode('AGE-SECRET-KEY-1'),
              utf8.encode('"format":"object-data-browser-keys"')
            ];
            for (final body in [
              ...p.server.requestBodies,
              ...p.server.versions.values
            ]) {
              for (final needle in secrets) {
                check(
                    !contains(body, needle), 'Request/version leaked a secret');
              }
            }
          }),
  for (final reverse in [false, true])
    for (final mutation in [
      'add/add',
      'rename/delete',
      'delete/rename',
      'delete/delete',
      'offline edits'
    ])
      'two devices $mutation converge, reverse=$reverse': () => pair((p) async {
            final initial = await p.a.generateCustomerKey('initial');
            final a = p.sync(p.a), b = p.sync(p.b);
            await p.converge(a, b);
            if (mutation == 'add/add' || mutation == 'offline edits') {
              await p.a.generateCustomerKey('from a');
              await p.b.generateCustomerKey('from b');
            }
            if (mutation == 'offline edits') {
              await p.a.rename(initial.id, 'a1');
              await p.a.rename(initial.id, 'a2');
              await p.b.delete(initial.id);
              await p.b.generateCustomerKey('b2');
            } else if (mutation == 'rename/delete') {
              await p.a.rename(initial.id, 'rename');
              await p.b.delete(initial.id);
            } else if (mutation == 'delete/rename') {
              await p.a.delete(initial.id);
              await p.b.rename(initial.id, 'rename');
            } else if (mutation == 'delete/delete') {
              await p.a.delete(initial.id);
              await p.b.delete(initial.id);
            }
            await p.converge(a, b, reverse: reverse);
            check(p.server.maxActive == 1, 'Unexpected overlap');
          }),
  for (final mode in ['strict', 'unsupported', 'ignored'])
    'sync interleaved writer with $mode conditionals converges': () =>
        pair((p) async {
          await p.a.generateCustomerKey('a');
          await p.b.generateCustomerKey('b');
          final a = p.sync(p.a), b = p.sync(p.b);
          p.server.unsupported = mode == 'unsupported';
          p.server.ignored = mode == 'ignored';
          p.server.beforePut = () async {
            p.server.write(await p.b.encryptedBytes());
          };
          await p.converge(a, b);
          check(p.a.records.length == 2, 'Race lost a key');
          if (mode == 'strict') {
            check(a.state.conditionalWrites == true,
                'Honoured conditional not recorded');
          }
          if (mode == 'unsupported') {
            check(a.state.conditionalWrites == false,
                'Unsupported conditional not recorded');
          }
        }),
  'sync stops after five racing rounds and keeps local keys': () =>
      pair((p) async {
        await p.a.generateCustomerKey('a');
        await p.b.generateCustomerKey('b');
        final a = p.sync(p.a);
        Future<void> race() async {
          p.server.write(await p.b.encryptedBytes());
          p.server.beforePut = race;
        }

        p.server.beforePut = race;
        await a.syncNow();
        check(
            a.status == KeyFileSyncStatus.error &&
                p.server.puts == 5 &&
                a.localChangesPending,
            'Retry bound/pending');
        check(
            p.a.records.any((r) => r.label == 'a'), 'Failure lost local keys');
        p.server.beforePut = null;
      }),
  'unlock automatically syncs pending local changes': () => pair((p) async {
        await p.a.generateCustomerKey('offline');
        p.a.lock();
        final a = p.sync(p.a, debounce: const Duration(milliseconds: 1));
        a.requestSync();
        check(p.server.requests == 0, 'Locked trigger requested');
        await p.a.unlock(passphrase);
        for (var i = 0; i < 200 && a.state.lastSyncedAt == null; i++) {
          await Future<void>.delayed(const Duration(milliseconds: 10));
        }
        check(a.state.lastSyncedAt != null && !a.localChangesPending,
            'Unlock did not sync');
      }),
  'passphrase change pushes, mismatch prompts, supplied passphrase adopts and converges':
      () => pair((p) async {
            await p.a.generateCustomerKey('a');
            final a = p.sync(p.a), b = p.sync(p.b);
            await p.converge(a, b);
            await p.a.changePassphrase(passphrase, nextPassphrase);
            await a.syncNow();
            await b.syncNow();
            check(b.status == KeyFileSyncStatus.passphraseMismatch,
                'Mismatch status');
            await b.syncNow(remotePassphrase: 'wrong password long');
            check(b.status == KeyFileSyncStatus.passphraseMismatch,
                'Wrong supplied passphrase');
            await b.syncNow(remotePassphrase: nextPassphrase);
            await p.converge(a, b, password: nextPassphrase);
            p.b.lock();
            await p.b.unlock(nextPassphrase);
          }),
  'unknown top-level fields that differ merge the same in both orders':
      () async {
    final left = <String, Object?>{
      'format': 'object-data-browser-keys',
      'version': 1,
      'clock': 0,
      'keys': <Object?>[],
      'removed': <Object?>[],
      'future': {'a': 1},
    };
    final right = <String, Object?>{
      ...left,
      'future': {'b': 2},
      'other': 'x',
    };
    final one = mergeKeyFileDocuments(left, right);
    final two = mergeKeyFileDocuments(right, left);
    check(canonicalKeyFileJson(one) == canonicalKeyFileJson(two),
        'Top-level merge depends on the side');
    check(one['other'] == 'x', 'Unknown field from one side was dropped');
    check(
        canonicalKeyFileJson(mergeKeyFileDocuments(one, right)) ==
            canonicalKeyFileJson(one),
        'Top-level merge is not idempotent');
  },
  'passphrase changed here survives a restart and re-encrypts the bucket copy':
      () => pair((p) async {
            await p.a.generateCustomerKey('a');
            final a = p.sync(p.a), b = p.sync(p.b);
            await p.converge(a, b);
            // The change is not pushed: the debounce is a day in this harness.
            await p.a.changePassphrase(passphrase, nextPassphrase);
            await Future<void>.delayed(Duration.zero);
            check(a.state.passphraseChangePending, 'Pending flag not set');
            final saved = KeyFileSyncState.fromJson(a.state.toJson());
            a.dispose();
            p.a.lock();
            // A restart: a fresh store that no longer remembers the old one.
            final restarted = EncryptionKeyStore(
                File('${p.directory.path}/a.age'),
                deviceId: 'aaaaaaaaaaaaaaaa',
                scryptWorkFactor: 1);
            await restarted.unlock(nextPassphrase);
            final again = KeyFileSync(
                store: restarted,
                config: config,
                transport: p.transportFactory?.call() ?? p.server.client(),
                state: saved,
                debounce: const Duration(days: 1));
            p.syncs.add(again);
            await again.syncNow();
            check(again.status == KeyFileSyncStatus.passphraseMismatch,
                'Old bucket copy should need the previous passphrase');
            check(again.statusText.contains('previous passphrase'),
                'Status should ask for the previous passphrase');
            await again.syncNow(remotePassphrase: passphrase);
            check(
                again.status == KeyFileSyncStatus.upToDate ||
                    again.status == KeyFileSyncStatus.merged,
                'Sync after supplying the previous passphrase failed');
            check(!again.state.passphraseChangePending, 'Flag not cleared');
            await ageDecrypt(p.server.bytes!, passphrase: nextPassphrase);
            restarted.lock();
            await restarted.unlock(nextPassphrase);
            await b.syncNow();
            check(b.status == KeyFileSyncStatus.passphraseMismatch,
                'Other device should be asked for the new passphrase');
            await b.syncNow(remotePassphrase: nextPassphrase);
            check(
                normalizedKeyFileJson(
                        await document(restarted, password: nextPassphrase)) ==
                    normalizedKeyFileJson(
                        await document(p.b, password: nextPassphrase)),
                'Devices did not converge on the new passphrase');
            restarted.lock();
          }),
  'earlier version additive import restores a deleted key and turns versioning on':
      () => pair((p) async {
            final key = await p.a.generateCustomerKey('keep');
            final a = p.sync(p.a), b = p.sync(p.b);
            p.server.versioning = false;
            await a.refreshVersioning();
            check(a.state.versioningEnabled == false, 'Versioning off');
            await a.refreshVersioning(enable: true);
            check(a.state.versioningEnabled == true, 'Enable versioning');
            await p.converge(a, b);
            final versions = await a.earlierVersions();
            check(versions.isNotEmpty, 'Version list');
            await p.a.delete(key.id);
            await p.converge(a, b);
            check(p.a.records.isEmpty, 'Delete propagated');
            await a.importVersion(versions.first.id, passphrase);
            await p.converge(a, b);
            check(p.a.records.single.id == key.id,
                'Version import did not restore');
          }),
  'short passphrases, locked stores and sync off make no requests': () =>
      pair((p) async {
        final a = p.sync(p.a);
        await a.syncNow();
        final requests = p.server.requests;
        a.dispose();
        await p.a.generateCustomerKey('off');
        await a.syncNow();
        check(p.server.requests == requests, 'Off sync requested');
        final b = p.sync(p.b);
        p.b.lock();
        await b.syncNow();
        check(p.server.requests == requests, 'Locked sync requested');
        await p.b.unlock(passphrase);
        await p.b.changePassphrase(passphrase, 'short phrase!');
        await b.syncNow();
        check(
            b.status == KeyFileSyncStatus.error &&
                p.server.requests == requests,
            'Short passphrase sync requested');
      }),
  'sync errors are sanitized and local changes remain pending': () =>
      pair((p) async {
        final a = p.sync(p.a);
        await p.a.generateCustomerKey('local');
        p.server.failStatus = 403;
        await a.syncNow();
        check(
            a.status == KeyFileSyncStatus.error &&
                a.statusText == 'Sync access denied.' &&
                a.localChangesPending,
            'Access status/pending');
        p.server.failStatus = null;
        await a.syncNow();
        check(!a.localChangesPending, 'Retry did not recover');
      }),
  'sync triggers coalesce without overlap and follow-up includes a local edit':
      () => pair((p) async {
            await p.a.generateCustomerKey('first');
            final a = p.sync(p.a);
            final entered = Completer<void>(), release = Completer<void>();
            p.server.beforeRequest = (method) async {
              if (!entered.isCompleted) {
                entered.complete();
                await release.future;
              }
            };
            final run = a.syncNow();
            await entered.future;
            for (var i = 0; i < 5; i++) {
              a.requestSync();
            }
            await p.a.generateCustomerKey('during sync');
            release.complete();
            await run;
            check(
                p.server.maxActive == 1 &&
                    !a.localChangesPending &&
                    p.server.requests <= 7,
                'Coalescing/follow-up');
          }),
  'eligible profiles and sync settings round trip without key material':
      () async {
    const profile = EndpointProfile(
        id: 'p',
        name: 'S3',
        endpointUrl: 'https://example.test',
        region: 'us-east-1',
        accessKey: 'access',
        secretKey: 'secret',
        pathStyle: true,
        verifyTls: true);
    check(
        keyFileSyncProfileIneligibility(profile) == null, 'Static S3 rejected');
    for (final type in [
      EndpointProfileType.azureBlob,
      EndpointProfileType.googleCloudStorage
    ]) {
      check(
          keyFileSyncProfileIneligibility(
                  profile.copyWith(endpointType: type)) !=
              null,
          'Ineligible provider accepted');
    }
    check(
        keyFileSyncProfileIneligibility(profile.copyWith(
                connection:
                    const ConnectionOptions(authMode: 'environment'))) !=
            null,
        'Chain auth accepted');
    check(AppSettings.fromJson({}).keyFileSync == null,
        'Old settings enable sync');
    final state = KeyFileSyncState(
        etag: 'etag',
        versionId: 'v1',
        lastSyncedAt: DateTime.utc(2026, 11, 15),
        syncedClock: 12,
        conditionalWrites: false,
        versioningEnabled: true);
    final settings = AppSettings.fromJson({}).copyWith(
        keyFileDeviceId: '0123456789abcdef',
        keyFileSync: config,
        keyFileSyncState: state);
    final loaded = AppSettings.fromJson(settings.toJson());
    check(
        jsonEncode(loaded.keyFileSync!.toJson()) ==
                jsonEncode(config.toJson()) &&
            jsonEncode(loaded.keyFileSyncState.toJson()) ==
                jsonEncode(state.toJson()),
        'Settings round trip');
    check(
        !jsonEncode(settings.toJson()).contains(passphrase) &&
            !jsonEncode(settings.toJson()).contains('"secret"'),
        'State leaked key material');
    check(settings.copyWith(clearKeyFileSync: true).keyFileSync == null,
        'Disable config');
  },
};
bool contains(List<int> bytes, List<int> needle) {
  for (var i = 0; i <= bytes.length - needle.length; i++) {
    var same = true;
    for (var j = 0; j < needle.length; j++) {
      if (bytes[i + j] != needle[j]) {
        same = false;
        break;
      }
    }
    if (same) return true;
  }
  return false;
}

Future<void> main() async {
  for (final entry in scenarios.entries) {
    await entry.value();
    stdout.writeln('PASS ${entry.key}');
  }
  stdout.writeln('PASS ${scenarios.length} scenarios');
}
