// The key file is encrypted even in fixtures: no test writes plaintext secrets.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as digests;
import 'package:flutter_test/flutter_test.dart';
import 'package:s3_browser_crossplat/services/crypto/age.dart';
import 'package:s3_browser_crossplat/services/encryption_key_store.dart';

const _passphrase = 'test key file passphrase';
const _nextPassphrase = 'replacement passphrase';
const _identityText =
    'AGE-SECRET-KEY-1033L492W9NWEWSPU09LUJCAZZQZGTM7RXV8QMLTTH4YENQAYZ2TSAWU55M';
const _recipient =
    'age1xj64lnj9z30e8ejj5lcf7cl3yks0eq94gr2dg8g88snuxylmmvgqy0q7c7';

Uint8List _key(int seed) =>
    Uint8List.fromList(List.generate(32, (i) => (i * 31 + seed) & 255));

Matcher _throwsStore<T extends EncryptionKeyStoreException>() =>
    throwsA(isA<T>());

Map<String, Object?> _document(List<Object?> keys) => {
      'format': EncryptionKeyStore.formatName,
      'version': 1,
      'keys': keys,
    };

Map<String, Object?> _customerEntry(String id, Uint8List key) => {
      'id': id,
      'label': 'Imported customer key',
      'type': 'customerKey',
      'createdAt': '2026-11-15T12:00:00Z',
      'secret': base64.encode(key),
    };

Future<void> _writeDocument(File file, Object? document,
    {String passphrase = _passphrase}) async {
  await file.writeAsBytes(
      await ageEncrypt(Uint8List.fromList(utf8.encode(jsonEncode(document))),
          passphrase: passphrase, scryptWorkFactor: 8),
      flush: true);
}

Future<Map<String, Object?>> _readDocument(File file,
    {String passphrase = _passphrase}) async {
  final clear =
      await ageDecrypt(await file.readAsBytes(), passphrase: passphrase);
  return jsonDecode(utf8.decode(clear)) as Map<String, Object?>;
}

// Compare bytes directly, including non-UTF-8 raw customer keys.
bool _contains(List<int> haystack, List<int> needle) {
  for (var start = 0; start <= haystack.length - needle.length; start++) {
    var matches = true;
    for (var i = 0; i < needle.length; i++) {
      if (haystack[start + i] != needle[i]) {
        matches = false;
        break;
      }
    }
    if (matches) return true;
  }
  return false;
}

Future<void> _expectEncrypted(Directory directory,
    {Iterable<Uint8List> customerKeys = const [],
    Iterable<String> identities = const []}) async {
  final forbidden = <List<int>>[
    utf8.encode('AGE-SECRET-KEY-1'),
    utf8.encode(_passphrase),
    utf8.encode(_nextPassphrase),
    for (final key in customerKeys) ...[key, utf8.encode(base64.encode(key))],
    for (final identity in identities) utf8.encode(identity),
  ];
  await for (final entity in directory.list(recursive: true)) {
    if (entity is! File) continue;
    final bytes = await entity.readAsBytes();
    for (final secret in forbidden) {
      expect(_contains(bytes, secret), isFalse,
          reason: 'Plaintext secret in ${entity.path}');
    }
  }
}

// A deterministic barrier for lock() while unlock() is reading the file.
class _GatedReadFile implements File {
  _GatedReadFile(this.delegate);
  final File delegate;
  final started = Completer<void>();
  final resume = Completer<void>();

  @override
  Future<bool> exists() => delegate.exists();
  @override
  Future<int> length() => delegate.length();
  @override
  Future<Uint8List> readAsBytes() async {
    final bytes = await delegate.readAsBytes();
    started.complete();
    await resume.future;
    return bytes;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FailingReadFile extends _GatedReadFile {
  _FailingReadFile(super.delegate);

  @override
  Future<Uint8List> readAsBytes() async =>
      throw const FileSystemException(_identityText);
}

void main() {
  late Directory directory;
  late File file;
  late EncryptionKeyStore store;

  EncryptionKeyStore open(File target,
          {void Function(EncryptionKeyStoreWriteStage)? fault}) =>
      EncryptionKeyStore(target, scryptWorkFactor: 8, debugWriteFault: fault);

  Future<EncryptionKeyStore> reopen({String passphrase = _passphrase}) async {
    final fresh = open(file);
    await fresh.unlock(passphrase);
    return fresh;
  }

  setUp(() {
    directory = Directory.systemTemp.createTempSync('encryption-key-store-');
    file = File('${directory.path}/keys.age');
    store = open(file);
  });
  tearDown(() async {
    store.lock();
    await directory.delete(recursive: true);
  });

  test('create, unlock and lock expose only typed locked accessors', () async {
    expect(await store.exists(), isFalse);
    await expectLater(store.unlock(_passphrase),
        _throwsStore<EncryptionKeyStoreMissingException>());
    await store.create(_passphrase);
    expect(await store.exists(), isTrue);
    expect(store.isUnlocked, isTrue);
    final customer = await store.importCustomerKey('Customer', _key(3));
    final identity = await store.importAgeIdentity('Identity', _identityText);
    store.lock();
    expect(store.isUnlocked, isFalse);
    expect(
        () => store.records, _throwsStore<EncryptionKeyStoreLockedException>());
    expect(() => store.unsupportedKeyCount,
        _throwsStore<EncryptionKeyStoreLockedException>());
    expect(() => store.customerKey(customer.id),
        _throwsStore<EncryptionKeyStoreLockedException>());
    await expectLater(store.ageIdentity(identity.id),
        _throwsStore<EncryptionKeyStoreLockedException>());
    await expectLater(store.rename(customer.id, 'Locked'),
        _throwsStore<EncryptionKeyStoreLockedException>());
    await store.unlock(_passphrase);
    expect(store.records, [customer, identity]);
    await _expectEncrypted(directory, customerKeys: [_key(3)]);
  });

  test('create refuses existing files and counts passphrase Unicode runes',
      () async {
    for (final weak in ['short', '😀' * 11]) {
      await expectLater(store.create(weak),
          _throwsStore<EncryptionKeyStoreWeakPassphraseException>());
      expect(await file.exists(), isFalse);
    }
    await store.create('😀' * 12);
    final before = await file.readAsBytes();
    await expectLater(store.create(_passphrase),
        _throwsStore<EncryptionKeyStoreAlreadyExistsException>());
    expect(await file.readAsBytes(), before);
    store.lock();
    await store.unlock('😀' * 12);
    expect(store.records, isEmpty);
  });

  test('every mutation survives a fresh store and secrets stay encrypted',
      () async {
    await store.create(_passphrase);
    await _expectEncrypted(directory);
    final generated = await store.generateCustomerKey('Generated');
    final generatedKey = store.customerKey(generated.id);
    final secrets = [generatedKey, _key(7)];
    expect((await reopen()).customerKey(generated.id), generatedKey);
    await _expectEncrypted(directory, customerKeys: secrets);
    final imported = await store.importCustomerKey('Imported', _key(7));
    expect((await reopen()).customerKey(imported.id), _key(7));
    await _expectEncrypted(directory, customerKeys: secrets);
    final generatedAge = await store.generateAgeIdentity('Generated identity');
    final identity = await store.ageIdentity(generatedAge.id);
    expect((await (await reopen()).ageIdentity(generatedAge.id)).secretKey,
        identity.secretKey);
    await _expectEncrypted(directory,
        customerKeys: secrets, identities: [identity.secretKey]);
    final importedAge =
        await store.importAgeIdentity('Imported identity', _identityText);
    expect((await (await reopen()).ageIdentity(importedAge.id)).secretKey,
        _identityText);
    await _expectEncrypted(directory, customerKeys: secrets);
    await store.rename(imported.id, ' Renamed ');
    expect(
        (await reopen()).records.singleWhere((r) => r.id == imported.id).label,
        'Renamed');
    await _expectEncrypted(directory, customerKeys: secrets);
    await store.delete(generated.id);
    expect((await reopen()).records.map((r) => r.id),
        isNot(contains(generated.id)));
    await _expectEncrypted(directory, customerKeys: secrets);
    await store.changePassphrase(_passphrase, _nextPassphrase);
    expect((await reopen(passphrase: _nextPassphrase)).records, store.records);
    await expectLater(
        reopen(), _throwsStore<EncryptionKeyStoreWrongPassphraseException>());
    await _expectEncrypted(directory, customerKeys: secrets);
    final document = await _readDocument(file, passphrase: _nextPassphrase);
    expect(document['format'], 'object-data-browser-keys');
    expect(document['version'], 1);
    expect((document['keys'] as List).length, 3);
    final raw = (document['keys'] as List).cast<Map<String, Object?>>();
    expect(raw.singleWhere((r) => r['id'] == imported.id)['secret'],
        base64.encode(_key(7)));
    expect(raw.singleWhere((r) => r['id'] == importedAge.id)['secret'],
        _identityText);
  });

  test('fingerprints and record JSON contain public metadata only', () async {
    await store.create(_passphrase);
    final key = _key(11);
    final customer = await store.importCustomerKey('Customer', key);
    expect(
        customer.fingerprint, base64.encode(digests.sha256.convert(key).bytes));
    expect(customer.md5Base64, base64.encode(digests.md5.convert(key).bytes));
    final age = await store.importAgeIdentity('Identity', _identityText);
    expect(age.fingerprint, _recipient);
    expect(age.md5Base64, isNull);
    for (final record in store.records) {
      expect(EncryptionKeyRecord.fromJson(record.toJson()), record);
      expect(EncryptionKeyRecord.fromJson(record.toJson()).hashCode,
          record.hashCode);
      final public =
          '${record.toString()} ${jsonEncode(record.toJson())} $store';
      expect(public, isNot(contains(base64.encode(key))));
      expect(public, isNot(contains(_identityText)));
      expect(record.toJson().containsKey('secret'), isFalse);
    }
    expect(
        () => EncryptionKeyRecord.fromJson({'secret': _identityText}),
        throwsA(isA<FormatException>().having(
            (e) => e.toString(), 'redacted', isNot(contains(_identityText)))));
  });

  test('customer imports require 32 bytes, copy input, and reject duplicates',
      () async {
    await store.create(_passphrase);
    final before = await file.readAsBytes();
    for (final size in [0, 1, 31, 33, 64]) {
      await expectLater(store.importCustomerKey('Bad', Uint8List(size)),
          _throwsStore<EncryptionKeyInvalidException>());
      expect(await file.readAsBytes(), before);
    }
    final original = _key(12);
    final input = Uint8List.fromList(original);
    final pending = store.importCustomerKey('Copy', input);
    input.fillRange(0, input.length, 0);
    final record = await pending;
    expect(store.customerKey(record.id), original);
    final returned = store.customerKey(record.id)..fillRange(0, 32, 0);
    expect(returned, Uint8List(32));
    expect(store.customerKey(record.id), original);
    final saved = await file.readAsBytes();
    await expectLater(
        store.importCustomerKey('Duplicate', original),
        throwsA(isA<EncryptionKeyDuplicateException>()
            .having((e) => e.existing, 'existing', record)));
    expect(await file.readAsBytes(), saved);
    final age = await store.importAgeIdentity('Identity', _identityText);
    await expectLater(
        store.importAgeIdentity('Duplicate', ' $_identityText\n'),
        throwsA(isA<EncryptionKeyDuplicateException>()
            .having((e) => e.existing, 'existing', age)));
    expect((await reopen()).records.length, 2);
    await _expectEncrypted(directory, customerKeys: [original]);
  });

  test('invalid input exceptions never echo key material', () async {
    await store.create(_passphrase);
    final customer = await store.importCustomerKey('Customer', _key(13));
    for (final invalid in [
      _identityText.replaceFirst('1', '2'),
      base64.encode(_key(13))
    ]) {
      await expectLater(
          store.importAgeIdentity('Bad', invalid),
          throwsA(isA<EncryptionKeyInvalidException>()
              .having((e) => e.toString(), 'redacted input',
                  isNot(contains(invalid)))
              .having((e) => e.message, 'no secret key text',
                  isNot(contains('AGE-SECRET-KEY-1')))));
      expect(
          () => store.customerKey(invalid),
          throwsA(isA<EncryptionKeyNotFoundException>().having(
              (e) => e.message, 'redacted id', isNot(contains(invalid)))));
    }
    await expectLater(store.ageIdentity(customer.id),
        _throwsStore<EncryptionKeyInvalidException>());
    await expectLater(store.rename(customer.id, '  '),
        _throwsStore<EncryptionKeyInvalidException>());
    await expectLater(store.rename(customer.id, 'x' * 257),
        _throwsStore<EncryptionKeyInvalidException>());
  });

  test('unlock and import accept old short passphrases; changes require 12',
      () async {
    final source = File('${directory.path}/short.age');
    await _writeDocument(source, _document([_customerEntry('old', _key(20))]),
        passphrase: 'old');
    final legacy = open(source);
    await legacy.unlock('old');
    expect(legacy.records.length, 1);
    await store.create(_passphrase);
    expect(await store.importFrom(source, 'old'), (added: 1, skipped: 0));
    final before = await source.readAsBytes();
    await expectLater(legacy.changePassphrase('wrong', _nextPassphrase),
        _throwsStore<EncryptionKeyStoreWrongPassphraseException>());
    await expectLater(legacy.changePassphrase('old', '😀' * 11),
        _throwsStore<EncryptionKeyStoreWeakPassphraseException>());
    expect(await source.readAsBytes(), before);
    await legacy.changePassphrase('old', _nextPassphrase);
    await open(source).unlock(_nextPassphrase);
    await _expectEncrypted(directory, customerKeys: [_key(20)]);
  });

  test(
      'wrong passphrase, corrupt payload and unsupported age have typed errors',
      () async {
    await store.create(_passphrase);
    final encrypted = await file.readAsBytes();
    store.lock();
    await expectLater(store.unlock('incorrect'),
        _throwsStore<EncryptionKeyStoreWrongPassphraseException>());
    final damaged = Uint8List.fromList(encrypted);
    damaged[damaged.length - 1] ^= 1;
    await file.writeAsBytes(damaged);
    await expectLater(store.unlock(_passphrase),
        _throwsStore<EncryptionKeyStoreCorruptException>());
    await file.writeAsString('not an age file');
    await expectLater(store.unlock(_passphrase),
        _throwsStore<EncryptionKeyStoreCorruptException>());
    await file.writeAsString('age-encryption.org/v2\n');
    await expectLater(store.unlock(_passphrase),
        _throwsStore<EncryptionKeyStoreUnsupportedException>());
    expect(store.isUnlocked, isFalse);
  });

  test('invalid plaintext encoding and JSON do not expose their contents',
      () async {
    for (final clear in [
      Uint8List.fromList([0xff, 0xfe]),
      Uint8List.fromList(utf8.encode('not JSON: $_identityText')),
    ]) {
      await file.writeAsBytes(await ageEncrypt(clear,
          passphrase: _passphrase, scryptWorkFactor: 8));
      await expectLater(
          store.unlock(_passphrase),
          throwsA(isA<EncryptionKeyStoreCorruptException>().having(
              (e) => e.message,
              'redacted contents',
              isNot(contains(_identityText)))));
    }
  });

  test('filesystem read and export exceptions redact underlying messages',
      () async {
    await store.create(_passphrase);
    final failing = open(_FailingReadFile(file));
    await expectLater(
        failing.unlock(_passphrase),
        throwsA(isA<EncryptionKeyStoreCorruptException>().having(
            (e) => e.message,
            'redacted read',
            isNot(contains(_identityText)))));
    await expectLater(
        failing.exportTo(File('${directory.path}/export.age')),
        throwsA(isA<EncryptionKeyStoreWriteException>().having((e) => e.message,
            'redacted export', isNot(contains(_identityText)))));
  });

  test('mutation cannot write a key file too large to reopen', () async {
    const limit = 8 * 1024 * 1024;
    // Measure the container overhead at this chunk count, then leave less
    // space than a new key entry needs. The extension remains opaque data.
    const initialLength = limit - 4096;
    await _writeDocument(
        file, {..._document([]), 'extension': 'x' * initialLength});
    final overhead = await file.length() - initialLength;
    await _writeDocument(
        file, {..._document([]), 'extension': 'x' * (limit - overhead - 50)});
    await store.unlock(_passphrase);
    final before = await file.readAsBytes();
    await expectLater(store.generateCustomerKey('Too large'),
        _throwsStore<EncryptionKeyStoreWriteException>());
    expect(await file.readAsBytes(), before);
    expect(store.records, isEmpty);
    expect((await reopen()).records, isEmpty);
    expect(
        directory.listSync().whereType<File>().map((e) => e.path), [file.path]);
  }, timeout: const Timeout(Duration(minutes: 1)));

  final malformed = <String, Object?>{
    'non-object': [],
    'wrong format': {..._document([]), 'format': 'other'},
    'missing version': {'format': EncryptionKeyStore.formatName, 'keys': []},
    'zero version': {..._document([]), 'version': 0},
    'non-integer version': {..._document([]), 'version': '1'},
    'missing keys': {'format': EncryptionKeyStore.formatName, 'version': 1},
    'non-object entry': _document([12]),
    'incomplete entry': _document([
      {'type': 'customerKey'}
    ]),
    'invalid date': _document([
      {..._customerEntry('one', _key(21)), 'createdAt': 'bad'}
    ]),
    'invalid base64': _document([
      {..._customerEntry('one', _key(21)), 'secret': '!'}
    ]),
    'wrong key length': _document([
      {..._customerEntry('one', _key(21)), 'secret': 'AA=='}
    ]),
    'invalid identity': _document([
      {..._customerEntry('one', _key(21)), 'type': 'ageIdentity'}
    ]),
    'duplicate id': _document(
        [_customerEntry('one', _key(21)), _customerEntry('one', _key(22))]),
  };
  for (final fixture in malformed.entries) {
    test('corrupt JSON contents: ${fixture.key}', () async {
      await _writeDocument(file, fixture.value);
      final before = await file.readAsBytes();
      await expectLater(store.unlock(_passphrase),
          _throwsStore<EncryptionKeyStoreCorruptException>());
      expect(store.isUnlocked, isFalse);
      expect(await file.readAsBytes(), before);
    });
  }

  test('future JSON versions are refused and never rewritten or merged',
      () async {
    await _writeDocument(file, {..._document([]), 'version': 2});
    final before = await file.readAsBytes();
    await expectLater(
        store.unlock(_passphrase),
        throwsA(isA<EncryptionKeyStoreUnsupportedVersionException>()
            .having((e) => e.version, 'version', 2)));
    expect(await file.readAsBytes(), before);
    await expectLater(store.generateCustomerKey('Locked'),
        _throwsStore<EncryptionKeyStoreLockedException>());
    final target = open(File('${directory.path}/target.age'));
    await target.create(_passphrase);
    final targetBefore = await target.file.readAsBytes();
    await expectLater(target.importFrom(file, _passphrase),
        _throwsStore<EncryptionKeyStoreUnsupportedVersionException>());
    expect(await target.file.readAsBytes(), targetBefore);
    expect(target.records, isEmpty);
  });

  test('unknown document fields, entry fields and key types survive rewrites',
      () async {
    final extension = {
      'nested': [null, true, 1.25, 9007199254740993, '☃'],
      'data': {'x': 'y'}
    };
    final unknown = {
      'id': 'future',
      'type': 'futureKey',
      'secret': {
        'opaque': [1, 2, 3]
      },
      'extension': extension
    };
    final known = {
      ..._customerEntry('known', _key(23)),
      'extension': extension
    };
    await _writeDocument(file, {
      ..._document([known, unknown]),
      'extension': extension
    });
    await store.unlock(_passphrase);
    expect(store.unsupportedKeyCount, 1);
    expect(store.records.length, 1);
    await store.rename('known', 'Renamed');
    await store.generateCustomerKey('New key');
    await store.changePassphrase(_passphrase, _nextPassphrase);
    final document = await _readDocument(file, passphrase: _nextPassphrase);
    expect(document['extension'], extension);
    final keys = (document['keys'] as List).cast<Map<String, Object?>>();
    expect(keys.singleWhere((e) => e['id'] == 'future'), unknown);
    expect(keys.singleWhere((e) => e['id'] == 'known'),
        {...known, 'label': 'Renamed', 'rev': 1, 'by': store.deviceId});
    expect((await reopen(passphrase: _nextPassphrase)).unsupportedKeyCount, 1);
    await _expectEncrypted(directory, customerKeys: [_key(23)]);
  });

  test('export copies exact ciphertext while locked and rejects aliases',
      () async {
    await store.create(_passphrase);
    await store.importCustomerKey('Customer', _key(24));
    final before = await file.readAsBytes();
    store.lock();
    final destination = File('${directory.path}/export.age');
    await store.exportTo(destination);
    expect(await destination.readAsBytes(), before);
    for (final alias in [file, File('${directory.path}/./keys.age')]) {
      await expectLater(
          store.exportTo(alias), _throwsStore<EncryptionKeyInvalidException>());
      expect(await file.readAsBytes(), before);
    }
    if (!Platform.isWindows) {
      final link = Link('${directory.path}/alias.age');
      await link.create(file.path);
      await expectLater(store.exportTo(File(link.path)),
          _throwsStore<EncryptionKeyInvalidException>());
      expect(await file.readAsBytes(), before);
    }
    await _expectEncrypted(directory, customerKeys: [_key(24)]);
  });

  test('merge skips identical secrets and remaps different secrets sharing ids',
      () async {
    await store.create(_passphrase);
    final customer = await store.importCustomerKey('Existing', _key(30));
    final identity =
        await store.importAgeIdentity('Existing age', _identityText);
    final source = File('${directory.path}/source.age');
    final sourceDocument = _document([
      _customerEntry('duplicate', _key(30)),
      {
        ..._customerEntry('duplicate-age', _key(30)),
        'type': 'ageIdentity',
        'secret': _identityText
      },
      _customerEntry(customer.id, _key(31)),
      {
        ..._customerEntry(identity.id, _key(32)),
        'extension': {'keep': true}
      },
    ]);
    await _writeDocument(source, sourceDocument, passphrase: _nextPassphrase);
    final before = await file.readAsBytes();
    await expectLater(store.importFrom(source, 'wrong'),
        _throwsStore<EncryptionKeyStoreWrongPassphraseException>());
    expect(await file.readAsBytes(), before);
    expect(store.records, [customer, identity]);
    expect(await store.importFrom(source, _nextPassphrase),
        (added: 2, skipped: 2));
    final fresh = await reopen();
    expect(fresh.records, store.records);
    expect(fresh.records.map((r) => r.id).toSet().length, 4);
    expect(fresh.customerKey(customer.id), _key(30));
    final added =
        fresh.records.where((r) => r != customer && r != identity).toList();
    expect(added.map((r) => base64.encode(fresh.customerKey(r.id))),
        unorderedEquals([base64.encode(_key(31)), base64.encode(_key(32))]));
    final document = await _readDocument(file);
    expect(
        (document['keys'] as List)
            .where((e) => (e as Map)['extension'] != null)
            .single['extension'],
        {'keep': true});
    final merged = await file.readAsBytes();
    expect(await store.importFrom(source, _nextPassphrase),
        (added: 0, skipped: 4));
    expect(await file.readAsBytes(), merged);
    await _expectEncrypted(directory,
        customerKeys: [_key(30), _key(31), _key(32)]);
  });

  for (final stage in EncryptionKeyStoreWriteStage.values) {
    for (final changePassphrase in [false, true]) {
      test(
          'rollback at ${stage.name} preserves ${changePassphrase ? 'passphrase' : 'keys'} and disk state',
          () async {
        await store.create(_passphrase);
        final existing = await store.importCustomerKey('Existing', _key(40));
        final before = await file.readAsBytes();
        final stages = <EncryptionKeyStoreWriteStage>[];
        Object? hookFailure;
        final failing = open(file, fault: (current) {
          stages.add(current);
          try {
            final files = directory.listSync().whereType<File>().toList();
            final temps =
                files.where((f) => f.path.startsWith('${file.path}.tmp-'));
            expect(temps.length,
                current == EncryptionKeyStoreWriteStage.replaced ? 0 : 1);
            for (final candidate in files) {
              final bytes = candidate.readAsBytesSync();
              expect(_contains(bytes, _key(40)), isFalse);
              expect(_contains(bytes, _key(41)), isFalse);
              expect(_contains(bytes, utf8.encode(base64.encode(_key(40)))),
                  isFalse);
              expect(_contains(bytes, utf8.encode(base64.encode(_key(41)))),
                  isFalse);
              expect(
                  _contains(bytes, utf8.encode('AGE-SECRET-KEY-1')), isFalse);
            }
            if (current == stage &&
                current != EncryptionKeyStoreWriteStage.tempWritten) {
              expect(File('${file.path}.bak').readAsBytesSync(), before);
            }
          } catch (error) {
            // The store sanitizes hook errors too. Keep assertion failures
            // visible outside its write-error boundary.
            hookFailure = error;
            rethrow;
          }
          if (current != stage) return;
          // Exercise redaction even when the underlying error contains secrets.
          throw FileSystemException(
              '$_identityText ${base64.encode(_key(40))}');
        });
        await failing.unlock(_passphrase);
        final operation = changePassphrase
            ? failing.changePassphrase(_passphrase, _nextPassphrase)
            : failing.importCustomerKey('New', _key(41));
        await expectLater(
            operation,
            throwsA(isA<EncryptionKeyStoreWriteException>().having(
                (e) => e.toString(),
                'redacted',
                allOf(isNot(contains(_identityText)),
                    isNot(contains(base64.encode(_key(40))))))));
        expect(hookFailure, isNull);
        expect(stages,
            EncryptionKeyStoreWriteStage.values.take(stage.index + 1).toList());
        expect(await file.readAsBytes(), before);
        expect(failing.records, [existing]);
        expect(failing.customerKey(existing.id), _key(40));
        expect((await reopen()).records, [existing]);
        expect(directory.listSync().whereType<File>().map((e) => e.path),
            [file.path]);
        await _expectEncrypted(directory, customerKeys: [_key(40), _key(41)]);
        failing.lock();
      });
    }

    test('create failure at ${stage.name} leaves no file or unlocked state',
        () async {
      final failing = open(file, fault: (current) {
        if (current == stage) throw StateError(_identityText);
      });
      await expectLater(failing.create(_passphrase),
          _throwsStore<EncryptionKeyStoreWriteException>());
      expect(failing.isUnlocked, isFalse);
      expect(await file.exists(), isFalse);
      expect(directory.listSync(), isEmpty);
      await store.create(_passphrase);
      expect((await reopen()).records, isEmpty);
    });
  }

  test('post-rename verification detects damage and restores previous file',
      () async {
    await store.create(_passphrase);
    final existing = await store.generateCustomerKey('Existing');
    final before = await file.readAsBytes();
    final failing = open(file, fault: (stage) {
      if (stage == EncryptionKeyStoreWriteStage.replaced) {
        final bytes = file.readAsBytesSync();
        bytes[bytes.length - 1] ^= 1;
        file.writeAsBytesSync(bytes, flush: true);
      }
    });
    await failing.unlock(_passphrase);
    await expectLater(failing.rename(existing.id, 'Changed'),
        _throwsStore<EncryptionKeyStoreWriteException>());
    expect(await file.readAsBytes(), before);
    expect(failing.records, [existing]);
    expect((await reopen()).records, [existing]);
  });

  test('failed rollback locks stale state and retains readable backup',
      () async {
    await store.create(_passphrase);
    final existing = await store.importCustomerKey('Existing', _key(42));
    final before = await file.readAsBytes();
    final failing = open(file, fault: (stage) {
      if (stage == EncryptionKeyStoreWriteStage.replaced) {
        file.deleteSync();
        Directory(file.path).createSync();
        throw const FileSystemException('Injected failure');
      }
    });
    await failing.unlock(_passphrase);
    await expectLater(failing.rename(existing.id, 'Changed'),
        _throwsStore<EncryptionKeyStoreWriteException>());
    expect(failing.isUnlocked, isFalse);
    expect(() => failing.records,
        _throwsStore<EncryptionKeyStoreLockedException>());
    final backup = File('${file.path}.bak');
    expect(await backup.readAsBytes(), before);
    final recovered = open(backup);
    await recovered.unlock(_passphrase);
    expect(recovered.records, [existing]);
    await _expectEncrypted(directory, customerKeys: [_key(42)]);
  });

  test('overlapping mutations both persist and errors do not poison the queue',
      () async {
    await store.create(_passphrase);
    final results = await Future.wait([
      store.importCustomerKey('First', _key(50)),
      store.importCustomerKey('Second', _key(51)),
    ]);
    expect(store.records, results);
    expect((await reopen()).records, results);
    await expectLater(store.rename(results.first.id, ''),
        _throwsStore<EncryptionKeyInvalidException>());
    await Future.wait([
      store.rename(results.first.id, 'Renamed'),
      store.delete(results.last.id),
    ]);
    final fresh = await reopen();
    expect(fresh.records.single.label, 'Renamed');
    expect(fresh.customerKey(results.first.id), _key(50));
    await _expectEncrypted(directory, customerKeys: [_key(50), _key(51)]);
  });

  test('lock during create or a mutation cannot restore unlocked state',
      () async {
    late EncryptionKeyStore creating;
    creating = open(file, fault: (stage) {
      if (stage == EncryptionKeyStoreWriteStage.tempWritten) creating.lock();
    });
    await creating.create(_passphrase);
    expect(creating.isUnlocked, isFalse);
    expect((await reopen()).records, isEmpty);
    late EncryptionKeyStore mutating;
    mutating = open(file, fault: (stage) {
      if (stage == EncryptionKeyStoreWriteStage.tempWritten) mutating.lock();
    });
    await mutating.unlock(_passphrase);
    final record =
        await mutating.importCustomerKey('Committed while locking', _key(52));
    expect(mutating.isUnlocked, isFalse);
    expect((await reopen()).customerKey(record.id), _key(52));
    await _expectEncrypted(directory, customerKeys: [_key(52)]);
  });

  test('lock cancels queued and in-flight unlocks', () async {
    await store.create(_passphrase);
    store.lock();
    final pending = store.unlock(_passphrase);
    store.lock();
    await expectLater(
        pending, _throwsStore<EncryptionKeyStoreLockedException>());
    final gated = _GatedReadFile(file);
    final unlocking = open(gated);
    final inFlight = unlocking.unlock(_passphrase);
    await gated.started.future;
    unlocking.lock();
    gated.resume.complete();
    await expectLater(
        inFlight, _throwsStore<EncryptionKeyStoreLockedException>());
    expect(unlocking.isUnlocked, isFalse);
    await store.unlock(_passphrase);
    expect(store.isUnlocked, isTrue);
  });

  group('live interoperability with the reference binary', () {
    final ageBin = Platform.environment['AGE_BIN'];
    final skip = ageBin == null || ageBin.isEmpty
        ? 'set AGE_BIN to the reference age binary to run'
        : false;

    test('reference age decrypts a key file through age-plugin-batchpass',
        () async {
      final plugin = File('${File(ageBin!).parent.path}/age-plugin-batchpass');
      if (!plugin.existsSync()) {
        markTestSkipped('age-plugin-batchpass is not next to AGE_BIN');
        return;
      }
      await store.create(_passphrase);
      final record = await store.importCustomerKey('Customer', _key(60));
      await store.importAgeIdentity('Identity', _identityText);
      // Capture stdout in memory: the reference tool never writes plaintext.
      final result = await Process.run(ageBin, [
        '-d',
        '-j',
        'batchpass',
        file.path
      ], environment: {
        ...Platform.environment,
        'PATH': '${File(ageBin).parent.path}'
            '${Platform.isWindows ? ';' : ':'}'
            '${Platform.environment['PATH'] ?? ''}',
        'AGE_PASSPHRASE': _passphrase,
      });
      expect(result.exitCode, 0, reason: '${result.stderr}');
      final document =
          jsonDecode(result.stdout as String) as Map<String, Object?>;
      expect(document, await _readDocument(file));
      expect(document['format'], EncryptionKeyStore.formatName);
      final keys = (document['keys'] as List).cast<Map<String, Object?>>();
      expect(keys.singleWhere((e) => e['id'] == record.id)['secret'],
          base64.encode(_key(60)));
      await _expectEncrypted(directory, customerKeys: [_key(60)]);
    }, skip: skip, timeout: const Timeout(Duration(minutes: 2)));
  });
}
