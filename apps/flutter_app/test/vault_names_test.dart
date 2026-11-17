import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:s3_browser_crossplat/services/crypto/age.dart';
import 'package:s3_browser_crossplat/services/crypto/age_bech32.dart';
import 'package:s3_browser_crossplat/services/crypto/vault_names.dart';
import 'package:s3_browser_crossplat/services/vault_name_codec.dart';
import 'package:s3_browser_crossplat/models/client_encryption.dart';

Uint8List hex(String s) => Uint8List.fromList([
      for (var i = 0; i < s.length; i += 2)
        int.parse(s.substring(i, i + 2), radix: 16)
    ]);
String hexText(List<int> bytes) =>
    bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

void main() {
  final vectors = jsonDecode(
          File('../../contracts/vectors/vault-names.json').readAsStringSync())
      as Map;
  late VaultNameKeys keys;
  setUp(() => keys = VaultNameKeys.fromIdentitySecret(
      hex(vectors['identitySecretHex'] as String)));
  tearDown(() => keys.wipe());
  ClientEncryptionRule rule(
          {String prefix = '',
          bool names = true,
          ClientEncryptionPolicy policy = ClientEncryptionPolicy.standard}) =>
      ClientEncryptionRule(
          bucket: 'bucket',
          prefix: prefix,
          keyId: 'vault',
          recipient: '',
          label: '',
          encryptNames: names,
          policy: policy);

  // https://www.rfc-editor.org/rfc/rfc5297#appendix-A
  test('RFC 5297 appendix A.1 (short plaintext, one AD string)', () {
    final key =
        hex('fffefdfcfbfaf9f8f7f6f5f4f3f2f1f0f0f1f2f3f4f5f6f7f8f9fafbfcfdfeff');
    final ad = [hex('101112131415161718191a1b1c1d1e1f2021222324252627')];
    final clear = hex('112233445566778899aabbccddee');
    final sealed =
        hex('85632d07c6e8f37f950acd320a2ecc9340c02b9690c4dc04daef7f6afe5c');
    expect(vaultSivSeal(key, clear, associatedData: ad), sealed);
    expect(vaultSivOpen(key, sealed, associatedData: ad), clear);
    expect(vaultSivOpen(key, sealed), isNull);
  });
  test('RFC 5297 appendix A.2 (long plaintext, multiple AD strings)', () {
    final key =
        hex('7f7e7d7c7b7a79787776757473727170404142434445464748494a4b4c4d4e4f');
    final ad = [
      hex('00112233445566778899aabbccddeeffdeaddadadeaddadaffeeddccbbaa99887766554433221100'),
      hex('102030405060708090a0'),
      hex('09f911029d74e35bd84156c5635688c0')
    ];
    final clear = hex(
        '7468697320697320736f6d6520706c61696e7465787420746f20656e6372797074207573696e67205349562d414553');
    final sealed = hex(
        '7bdb6e3b432667eb06f4d14bff2fbd0fcb900f2fddbe404326601965c889bf17dba77ceb094fa663b7a3f748ba8af829ea64ad544a272e9c485b62a3fd5c0d');
    expect(vaultSivSeal(key, clear, associatedData: ad), sealed);
    expect(vaultSivOpen(key, sealed, associatedData: ad), clear);
  });
  test('identity derives contract keys without exporting its secret bytes',
      () async {
    final identity = await AgeIdentity.parse(bech32Encode(
        'AGE-SECRET-KEY-', hex(vectors['identitySecretHex'] as String)));
    final derived = identity.deriveNameKeys();
    expect(hexText(derived.deterministic), vectors['deterministicKeyHex']);
    expect(hexText(derived.random), vectors['randomKeyHex']);
    derived.wipe();
    expect(derived.deterministic, everyElement(0));
    expect(derived.random, everyElement(0));
  });
  for (final v in vectors['deterministic'] as List) {
    test('deterministic vector ${v['name']}', () {
      expect(sealVaultName(v['name'] as String, keys), v['token']);
      expect(keys.open(v['token'] as String), v['name']);
    });
  }
  for (final v in vectors['random'] as List) {
    test('random vector ${v['path']}', () {
      expect(
          sealVaultName(v['path'] as String, keys,
              random: true, salt: hex(v['saltHex'] as String)),
          v['token']);
      expect(keys.open(v['token'] as String), v['path']);
    });
  }
  for (final v in vectors['invalid'] as List) {
    test('reject ${v['why']}',
        () => expect(keys.open(v['token'] as String), isNull));
  }
  for (final v in vectors['storedKeys'] as List) {
    test('stored key ${v['relative']} below ${v['ruleOrParentPrefix']}', () {
      final prefix = v['ruleOrParentPrefix'] as String;
      final r = rule(prefix: prefix);
      final stored = encodeVaultObjectKey(
          rule: r,
          keys: keys,
          destinationPrefix: prefix,
          relativeName: v['relative'] as String,
          folder: v['folder'] as bool);
      expect(stored, v['stored']);
      expect(
          decodeVaultKey(stored, r, {'vault': keys},
              file: !(v['folder'] as bool)),
          '$prefix${v['relative']}');
    });
  }
  test('random salts differ and the wrong key opens no contract token', () {
    final a = sealVaultName('photos/2024/a.jpg', keys, random: true);
    final b = sealVaultName('photos/2024/a.jpg', keys, random: true);
    expect(a, isNot(b));
    expect(keys.open(a), 'photos/2024/a.jpg');
    expect(keys.open(b), 'photos/2024/a.jpg');
    final wrong = VaultNameKeys.fromIdentitySecret(Uint8List(32));
    addTearDown(wrong.wipe);
    for (final v in [
      ...(vectors['deterministic'] as List),
      ...(vectors['random'] as List)
    ]) {
      expect(wrong.open(v['token'] as String), isNull);
    }
  });
  test('canonical base64, strict UTF8, NUL, and segment rules', () {
    for (final name in ['', '.', '..', 'a/b', 'a\u0000b']) {
      final token = base64Url.encode([
        1,
        ...vaultSivSeal(
            keys.deterministic, Uint8List.fromList(utf8.encode(name)))
      ]).replaceAll('=', '');
      expect(keys.open(token), isNull);
      expect(() => sealVaultName(name, keys), throwsFormatException);
    }
    for (final name in ['', '/a', 'a/', 'a//b', './a', 'a/../b', 'a\u0000b']) {
      expect(
          () => sealVaultName(name, keys, random: true), throwsFormatException);
    }
    final token = sealVaultName('a', keys);
    expect(keys.open('$token='), isNull);
    expect(keys.open(' $token'), isNull);
    // Same decoded bytes, nonzero unused base64 bits.
    const alphabet =
        'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_';
    final last = alphabet.indexOf(token[token.length - 1]);
    expect(
        keys.open(
            '${token.substring(0, token.length - 1)}${alphabet[last + 1]}'),
        isNull);
    keys.wipe();
    expect(keys.open(token), isNull); // Cached cleartext is gone too.
    expect(() => sealVaultName('a', keys), throwsStateError);
  });
  test('legacy names, mixed folders, rotation and current rule switches', () {
    final encoded = encodeVaultObjectKey(
        rule: rule(prefix: 'vault/'),
        keys: keys,
        destinationPrefix: 'vault/plain/',
        relativeName: 'new/file.txt');
    expect(encoded, startsWith('vault/plain/'));
    final decoded = decodeVaultKey(
        encoded, rule(prefix: 'vault/', names: false), {'old': keys});
    expect(decoded, 'vault/plain/new/file.txt');
    final renamed = translateVaultKey(
        visible: 'vault/plain/new/renamed.txt',
        reference: encoded,
        rule: rule(prefix: 'vault/'),
        keys: {'vault': keys});
    expect(renamed.split('/').take(3), encoded.split('/').take(3));
    expect(decodeVaultKey(renamed, rule(prefix: 'vault/'), {'vault': keys}),
        'vault/plain/new/renamed.txt');
    expect(decodeVaultKey(encoded, rule(prefix: 'vault/'), {}),
        encoded.substring(0, encoded.length - 4));
    expect(
        encodeVaultObjectKey(
            rule: rule(names: false),
            keys: null,
            destinationPrefix: 'folder/',
            relativeName: 'name.age'),
        'folder/name.age.age');
  });
  test('strict flat keys, folder refusal, lock, policy, UTF8 size limit', () {
    final r = rule(prefix: 'vault/', policy: ClientEncryptionPolicy.strict);
    final a = encodeVaultObjectKey(
        rule: r,
        keys: keys,
        destinationPrefix: 'vault/',
        relativeName: 'a/b.txt');
    final b = translateVaultKey(
        visible: 'vault/a/c.txt', reference: a, rule: r, keys: {'vault': keys});
    expect(a.split('/'), hasLength(2));
    expect(decodeVaultKey(b, r, {'vault': keys}), 'vault/a/c.txt');
    expect(
        () => encodeVaultObjectKey(
            rule: r,
            keys: keys,
            destinationPrefix: 'vault/',
            relativeName: 'a/',
            folder: true),
        throwsFormatException);
    expect(
        () => encodeVaultObjectKey(
            rule: r,
            keys: null,
            destinationPrefix: 'vault/',
            relativeName: 'a'),
        throwsFormatException);
    expect(
        () => encodeVaultObjectKey(
            rule: rule(policy: ClientEncryptionPolicy.unsupported),
            keys: keys,
            destinationPrefix: '',
            relativeName: 'a'),
        throwsFormatException);
    expect(
        () => encodeVaultObjectKey(
            rule: rule(),
            keys: keys,
            destinationPrefix: '',
            relativeName: List.filled(800, 'é').join()),
        throwsFormatException);
    expect(validateStoredKey(List.filled(512, 'é').join()), hasLength(512));
    expect(() => validateStoredKey('${List.filled(512, 'é').join()}a'),
        throwsFormatException);
  });
}
