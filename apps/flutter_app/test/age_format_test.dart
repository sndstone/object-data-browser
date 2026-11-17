// Tests for the age v1 implementation in lib/services/crypto/age.dart.
//
// Fixtures in test/fixtures/age/ were produced by the reference
// implementation, age v1.3.2 (filippo.io/age), from the deterministic
// plaintext `pattern(n)` below:
//
//   age -r <recipient1> -o x25519_<n>.age                 n = 0, 1, 65535,
//                                                             65536, 65537
//   age -r <recipient1> -r <recipient2> -o x25519_two_recipients.age  (1000)
//   age -p -o passphrase_default.age    (interactive, work factor 18, 300)
//   AGE_PASSPHRASE=… AGE_PASSPHRASE_WORK_FACTOR=10 \
//     age -e -j batchpass -o passphrase_wf10.age                      (300)
//
// The identities and passphrase are throwaway test values.
//
// Opt-in suites:
//   AGE_BIN=/path/to/age        live interoperability, both directions
//   AGE_CCTV_DIR=/path/to/CCTV/age/testdata   C2SP CCTV vectors (0BSD/CC0)
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as digests;
import 'package:flutter_test/flutter_test.dart';
import 'package:s3_browser_crossplat/services/crypto/age.dart';
import 'package:s3_browser_crossplat/services/crypto/age_bech32.dart';

const identity1Text =
    'AGE-SECRET-KEY-1033L492W9NWEWSPU09LUJCAZZQZGTM7RXV8QMLTTH4YENQAYZ2TSAWU55M';
const recipient1 =
    'age1xj64lnj9z30e8ejj5lcf7cl3yks0eq94gr2dg8g88snuxylmmvgqy0q7c7';
const identity2Text =
    'AGE-SECRET-KEY-1W4Q2TPJT5N35PMQ43ZWGEYVPY0NDZ48L25QNPHTU5J2NETX3CCDQFX8R5P';
const recipient2 =
    'age1j43gsjvh75dahpwuyq7a0cmfxt56ngay9qskcmq20mle5ml99sxqye00ga';
const fixturePassphrase = 'correct horse battery staple 42';

// From the specification (c2sp.org/age, "The X25519 recipient type").
const specIdentity =
    'AGE-SECRET-KEY-1GFPYYSJZGFPYYSJZGFPYYSJZGFPYYSJZGFPYYSJZGFPYYSJZGFPQ4EGAEX';
const specRecipient =
    'age1zvkyg2lqzraa2lnjvqej32nkuu0ues2s82hzrye869xeexvn73equnujwj';

const sealedChunk = ageChunkSize + ageChunkOverhead;
const roundTripSizes = <int>[0, 1, 65535, 65536, 65537, 131072, 1048576 + 4321];

Uint8List pattern(int length) {
  final out = Uint8List(length);
  for (var i = 0; i < length; i++) {
    out[i] = (i * 31 + (i >> 8) * 7 + 3) & 0xff;
  }
  return out;
}

Uint8List fixture(String name) =>
    File('test/fixtures/age/$name').readAsBytesSync();

Uint8List concat(Iterable<List<int>> parts) {
  final builder = BytesBuilder(copy: false);
  for (final part in parts) {
    builder.add(part);
  }
  return builder.takeBytes();
}

Uint8List flipBit(Uint8List source, int offset, [int mask = 1]) {
  final copy = Uint8List.fromList(source);
  copy[offset] ^= mask;
  return copy;
}

String b64(List<int> bytes) => base64.encode(bytes).replaceAll('=', '');

/// An age file assembled through the chunk API, with every piece exposed so
/// tests can damage it precisely.
class Sample {
  Sample(this.header, this.fileKey, this.nonce, this.cipher, this.plaintext,
      this.chunks);

  final AgeHeader header;
  final Uint8List fileKey;
  final Uint8List nonce;
  final AgePayloadCipher cipher;
  final Uint8List plaintext;
  final List<Uint8List> chunks;

  Uint8List get bytes => concat([header.bytes, nonce, ...chunks]);

  Uint8List withChunks(List<Uint8List> replacement) =>
      concat([header.bytes, nonce, ...replacement]);

  int chunkOffset(int index) =>
      ageChunkOffset(headerLength: header.length, index: index);
}

Future<Sample> buildSample(AgeIdentity identity, int length) async {
  final created = await ageNewHeader(recipients: [identity.recipient]);
  final nonce = Uint8List.fromList(List<int>.generate(16, (i) => 0xa0 + i));
  final cipher = await AgePayloadCipher.create(created.fileKey, nonce);
  final plaintext = pattern(length);
  final count = ageChunkCount(length);
  final chunks = <Uint8List>[];
  for (var i = 0; i < count; i++) {
    final start = i * ageChunkSize;
    final end = min(start + ageChunkSize, length);
    chunks.add(await cipher.sealChunk(
      i,
      Uint8List.sublistView(plaintext, start, end),
      last: i == count - 1,
    ));
  }
  return Sample(
      created.header, created.fileKey, nonce, cipher, plaintext, chunks);
}

/// Decrypts through the header and chunk primitives only.
Future<Uint8List> decryptWithChunkApi(
  Uint8List file, {
  List<AgeIdentity> identities = const [],
  String? passphrase,
}) async {
  // Simulate a ranged first read that returns more than the header.
  final prefix = Uint8List.sublistView(file, 0, min(file.length, 8192));
  final opened = await ageReadHeader(prefix,
      identities: identities, passphrase: passphrase);
  final h = opened.headerLength;
  expect(h, opened.header.length);
  final plaintextLength =
      agePlaintextLength(headerLength: h, ciphertextLength: file.length);
  final cipher = await AgePayloadCipher.create(
    opened.fileKey,
    Uint8List.sublistView(file, h, h + agePayloadNonceLength),
  );
  final count = ageChunkCount(plaintextLength);
  final out = BytesBuilder(copy: false);
  for (var i = 0; i < count; i++) {
    final start = ageChunkOffset(headerLength: h, index: i);
    final end = min(start + sealedChunk, file.length);
    out.add(await cipher.openChunk(
      i,
      Uint8List.sublistView(file, start, end),
      last: i == count - 1,
    ));
  }
  return out.takeBytes();
}

Matcher throwsAge<T extends AgeException>([bool Function(T error)? check]) =>
    throwsA(isA<T>().having((e) => check == null || check(e), 'details', true));

Matcher authFailureAt(int? chunkIndex) =>
    throwsA(isA<AgeAuthenticationException>()
        .having((e) => e.chunkIndex, 'chunkIndex', chunkIndex));

void main() {
  late AgeIdentity identity1;
  late AgeIdentity identity2;

  setUpAll(() async {
    identity1 = await AgeIdentity.parse(identity1Text);
    identity2 = await AgeIdentity.parse(identity2Text);
  });

  group('identities and recipients', () {
    test('matches the specification example and the reference key pairs',
        () async {
      final spec = await AgeIdentity.parse(specIdentity);
      expect(spec.recipient, specRecipient);
      expect(spec.secretKey, specIdentity);
      expect(identity1.recipient, recipient1);
      expect(identity2.recipient, recipient2);
      expect(isAgeRecipient(specRecipient), isTrue);
      expect(isAgeRecipient('  $recipient1\n'), isTrue);
    });

    test('generate produces distinct, parseable, round-tripping identities',
        () async {
      final a = await AgeIdentity.generate();
      final b = await AgeIdentity.generate();
      expect(a.secretKey, isNot(b.secretKey));
      expect(a.secretKey, startsWith('AGE-SECRET-KEY-1'));
      expect(a.secretKey, a.secretKey.toUpperCase());
      expect(a.recipient, startsWith('age1'));
      expect(a.recipient, a.recipient.toLowerCase());
      expect(a.secretKey.length, 74);
      expect(a.recipient.length, 62);
      final parsed = await AgeIdentity.parse(' ${a.secretKey}\n');
      expect(parsed.secretKey, a.secretKey);
      expect(parsed.recipient, a.recipient);
      expect(isAgeRecipient(a.recipient), isTrue);
    });

    test('enforces case, checksum, prefix and length rules', () async {
      Future<void> rejected(String text) => expectLater(
          AgeIdentity.parse(text), throwsAge<AgeInvalidKeyException>());

      await rejected('');
      await rejected(specIdentity.toLowerCase());
      await rejected(specIdentity.substring(0, 20) +
          specIdentity.substring(20).toLowerCase());
      await rejected('${specIdentity.substring(0, specIdentity.length - 1)}Q');
      await rejected(specRecipient);
      await rejected(bech32Encode('AGE-SECRET-KEY-', Uint8List(31)));
      await rejected(bech32Encode('AGE-SECRET-KEY-', Uint8List(33)));
      await rejected(bech32Encode('AGE-SECRET-KEX-', Uint8List(32)));
      await expectLater(
          AgeIdentity.parse(bech32Encode('AGE-SECRET-KEY-PQ-', Uint8List(32))),
          throwsAge<AgeUnsupportedException>());

      expect(isAgeRecipient(specRecipient.toUpperCase()), isFalse);
      expect(isAgeRecipient(specIdentity), isFalse);
      expect(isAgeRecipient(''), isFalse);
      expect(isAgeRecipient('age1'), isFalse);
      expect(
          isAgeRecipient(
              '${specRecipient.substring(0, specRecipient.length - 1)}q'),
          isFalse);
      expect(isAgeRecipient(bech32Encode('age', Uint8List(31))), isFalse);
      expect(isAgeRecipient(bech32Encode('age', Uint8List(33))), isFalse);
      expect(isAgeRecipient(bech32Encode('agf', Uint8List(32))), isFalse);
      // Post-quantum, tagged and ssh recipients are recognised but refused.
      expect(isAgeRecipient(bech32Encode('age1pq', Uint8List(32))), isFalse);
      for (final unsupported in [
        bech32Encode('age1pq', Uint8List(1216)),
        bech32Encode('age1tag', Uint8List(33)),
        'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIFakeFakeFakeFakeFakeFakeFakeFakeFakeFakeFake',
      ]) {
        await expectLater(ageEncrypt(Uint8List(1), recipients: [unsupported]),
            throwsAge<AgeUnsupportedException>());
      }
      await expectLater(ageEncrypt(Uint8List(1), recipients: ['not a key']),
          throwsAge<AgeInvalidKeyException>());
    });

    test('bech32 rejects non-canonical padding and bad characters', () {
      final good = bech32Encode('age', Uint8List(32));
      expect(bech32Decode(good).data, Uint8List(32));
      expect(bech32Decode(good).hrp, 'age');
      expect(bech32Decode(good.toUpperCase()).hrp, 'AGE');
      expect(() => bech32Decode('age1b${good.substring(5)}'),
          throwsFormatException);
      expect(
          () => bech32Decode('1${good.substring(4)}'), throwsFormatException);
      expect(() => bech32Decode('age'), throwsFormatException);
    });

    test('never prints or reports the secret key', () async {
      final id = await AgeIdentity.generate();
      expect(id.toString(), isNot(contains('SECRET')));
      expect(id.toString(), contains(id.recipient));
      final damaged = '${id.secretKey.substring(0, id.secretKey.length - 2)}QQ';
      try {
        await AgeIdentity.parse(damaged);
        fail('expected a failure');
      } on AgeException catch (error) {
        expect(error.toString(), isNot(contains(damaged.substring(16, 40))));
        expect(error.message, isNot(contains('AGE-SECRET-KEY-1')));
      }
    });
  });

  group('round trips', () {
    for (final size in roundTripSizes) {
      test('$size bytes through the whole-buffer and chunk APIs', () async {
        final plaintext = pattern(size);

        final file = await ageEncrypt(plaintext, recipients: [recipient1]);
        final header = AgeHeader.parse(file);
        expect(
            file.length,
            ageCiphertextLength(
                headerLength: header.length, plaintextLength: size));
        expect(await ageDecrypt(file, identities: [identity1]), plaintext);
        expect(await decryptWithChunkApi(file, identities: [identity1]),
            plaintext);

        final sample = await buildSample(identity1, size);
        expect(sample.chunks.length, ageChunkCount(size));
        expect(
            sample.bytes.length,
            ageCiphertextLength(
                headerLength: sample.header.length, plaintextLength: size));
        expect(
            await ageDecrypt(sample.bytes, identities: [identity1]), plaintext);
      });
    }

    test('passphrase files round trip through both APIs', () async {
      for (final size in [0, 1, 65537]) {
        final plaintext = pattern(size);
        final file = await ageEncrypt(plaintext,
            passphrase: 'pässphrase ✓ 12345', scryptWorkFactor: 8);
        final header = AgeHeader.parse(file);
        expect(header.isPassphraseProtected, isTrue);
        expect(header.scryptWorkFactor, 8);
        expect(await ageDecrypt(file, passphrase: 'pässphrase ✓ 12345'),
            plaintext);
        expect(
            await decryptWithChunkApi(file, passphrase: 'pässphrase ✓ 12345'),
            plaintext);
      }
    });

    test('the default passphrase work factor is 15', () async {
      expect(ageDefaultScryptWorkFactor, 15);
      final file = await ageEncrypt(pattern(10), passphrase: 'default work');
      expect(AgeHeader.parse(file).scryptWorkFactor, 15);
      expect(await ageDecrypt(file, passphrase: 'default work'), pattern(10));
    });

    test('several recipients can each decrypt, and files are randomised',
        () async {
      final third = await AgeIdentity.generate();
      final plaintext = pattern(5000);
      final file = await ageEncrypt(plaintext,
          recipients: [recipient1, third.recipient]);
      expect(AgeHeader.parse(file).stanzas.map((s) => s.type),
          ['X25519', 'X25519']);
      expect(await ageDecrypt(file, identities: [identity1]), plaintext);
      expect(await ageDecrypt(file, identities: [third]), plaintext);
      expect(await ageDecrypt(file, identities: [identity2, third]), plaintext);
      await expectLater(ageDecrypt(file, identities: [identity2]),
          throwsAge<AgeNoMatchingIdentityException>());

      final again = await ageEncrypt(plaintext,
          recipients: [recipient1, third.recipient]);
      expect(again, isNot(file));
      final a = await ageNewHeader(recipients: [recipient1]);
      final b = await ageNewHeader(recipients: [recipient1]);
      expect(a.fileKey, hasLength(16));
      expect(a.fileKey, isNot(b.fileKey));
      expect(a.header.bytes, isNot(b.header.bytes));
    });

    test('argument combinations are validated', () async {
      await expectLater(ageEncrypt(Uint8List(1)), throwsArgumentError);
      await expectLater(
          ageEncrypt(Uint8List(1),
              recipients: [recipient1], passphrase: 'x' * 12),
          throwsArgumentError);
      await expectLater(
          ageEncrypt(Uint8List(1), passphrase: ''), throwsArgumentError);
      await expectLater(
          ageEncrypt(Uint8List(1), passphrase: 'x', scryptWorkFactor: 0),
          throwsRangeError);
      await expectLater(
          ageEncrypt(Uint8List(1), passphrase: 'x', scryptWorkFactor: 21),
          throwsRangeError);
    });
  });

  group('reference fixtures (age v1.3.2)', () {
    for (final size in [0, 1, 65535, 65536, 65537]) {
      test('decrypts x25519_$size.age', () async {
        final file = fixture('x25519_$size.age');
        expect(await ageDecrypt(file, identities: [identity1]), pattern(size));
        expect(await decryptWithChunkApi(file, identities: [identity1]),
            pattern(size));
        final header = AgeHeader.parse(file);
        expect(
            agePlaintextLength(
                headerLength: header.length, ciphertextLength: file.length),
            size);
      });
    }

    test('decrypts a two-recipient file with either identity', () async {
      final file = fixture('x25519_two_recipients.age');
      expect(await ageDecrypt(file, identities: [identity1]), pattern(1000));
      expect(await ageDecrypt(file, identities: [identity2]), pattern(1000));
      final other = await AgeIdentity.generate();
      expect(await ageDecrypt(file, identities: [other, identity2]),
          pattern(1000));
      await expectLater(ageDecrypt(file, identities: [other]),
          throwsAge<AgeNoMatchingIdentityException>());
    });

    test('decrypts passphrase files (work factor 10 and the default 18)',
        () async {
      for (final entry in {
        'passphrase_wf10.age': 10,
        'passphrase_default.age': 18
      }.entries) {
        final file = fixture(entry.key);
        expect(AgeHeader.parse(file).scryptWorkFactor, entry.value);
        expect(await ageDecrypt(file, passphrase: fixturePassphrase),
            pattern(300));
      }
      await expectLater(
          ageDecrypt(fixture('passphrase_wf10.age'),
              passphrase: '$fixturePassphrase '),
          throwsAge<AgeWrongPassphraseException>());
    });

    test('header text re-encodes byte for byte', () {
      for (final name in [
        'x25519_0.age',
        'x25519_two_recipients.age',
        'passphrase_wf10.age'
      ]) {
        final header = AgeHeader.parse(fixture(name));
        final text = latin1.decode(header.bytes);
        final rebuilt = StringBuffer('age-encryption.org/v1\n');
        for (final stanza in header.stanzas) {
          rebuilt.write(stanza.encode());
        }
        expect(text, startsWith(rebuilt.toString()));
        expect(text.substring(rebuilt.length),
            matches(r'^--- [A-Za-z0-9+/]{43}\n$'));
      }
    });
  });

  group('header framing', () {
    test('stanza bodies wrap at 64 columns and end with a short line', () {
      String encode(int length) =>
          AgeStanza('example.com/test', ['arg'], pattern(length)).encode();

      expect(encode(0), '-> example.com/test arg\n\n');
      expect(encode(1).split('\n'), hasLength(3));
      final b47 = encode(47).split('\n');
      expect(b47, hasLength(3));
      expect(b47[1], hasLength(63));
      final b48 = encode(48).split('\n');
      expect(b48, hasLength(4));
      expect(b48[1], hasLength(64));
      expect(b48[2], isEmpty);
      final b49 = encode(49).split('\n');
      expect(b49[1], hasLength(64));
      expect(b49[2], hasLength(2));
      final b96 = encode(96).split('\n');
      expect(b96, hasLength(5));
      expect(b96[1], hasLength(64));
      expect(b96[2], hasLength(64));
      expect(b96[3], isEmpty);
      expect(encode(100), isNot(contains('=')));
      expect(
          () => AgeStanza('bad type', [], Uint8List(0)), throwsArgumentError);
      expect(() => AgeStanza('t', [''], Uint8List(0)), throwsArgumentError);
    });

    test('parses stanzas of every body length and ignores unknown types',
        () async {
      final sample = await buildSample(identity1, 10);
      final own = sample.header.stanzas.single.encode();
      for (final length in [0, 1, 47, 48, 49, 95, 96, 97, 200]) {
        final grease = AgeStanza('grease-x', ['a', 'b'], pattern(length));
        final text = 'age-encryption.org/v1\n${grease.encode()}$own'
            '--- ${b64(Uint8List(32))}\n';
        final parsed = AgeHeader.parse(ascii.encode(text));
        expect(parsed.length, text.length);
        expect(parsed.stanzas, hasLength(2));
        expect(parsed.stanzas.first.type, 'grease-x');
        expect(parsed.stanzas.first.arguments, ['a', 'b']);
        expect(parsed.stanzas.first.body, pattern(length));
        // The unknown stanza is skipped, the key unwraps, and the forged
        // header then fails its MAC.
        await expectLater(
            ageReadHeader(ascii.encode(text), identities: [identity1]),
            authFailureAt(null));
      }
    });

    test('every strict prefix of a header is reported as incomplete', () async {
      final file = fixture('x25519_two_recipients.age');
      final header = AgeHeader.parse(file);
      for (var length = 0; length < header.length; length++) {
        expect(
          () => AgeHeader.parse(Uint8List.sublistView(file, 0, length)),
          throwsA(isA<AgeIncompleteHeader>()
              .having((e) => e.availableLength, 'availableLength', length)
              .having((e) => e.maxHeaderLength, 'maxHeaderLength', 65536)),
          reason: 'prefix of $length bytes',
        );
      }
      // The header alone is enough: no payload byte is needed to unwrap.
      final exact = Uint8List.sublistView(file, 0, header.length);
      final opened = await ageReadHeader(exact, identities: [identity2]);
      expect(opened.headerLength, header.length);
      expect(opened.fileKey, hasLength(16));
      await expectLater(
          ageReadHeader(Uint8List.sublistView(file, 0, header.length - 1),
              identities: [identity2]),
          throwsA(isA<AgeIncompleteHeaderException>()));
      // A whole file that ends inside its header is malformed, not pending.
      await expectLater(
          ageDecrypt(Uint8List.sublistView(file, 0, header.length - 1),
              identities: [identity2]),
          throwsAge<AgeMalformedException>());
    });

    test('caps the header at 64 KiB', () async {
      final own = (await buildSample(identity1, 1)).header.stanzas.single;
      final mac = '--- ${b64(Uint8List(32))}\n';

      String headerOfLength(int target) {
        const lead = 'age-encryption.org/v1\n';
        final fixed = lead.length + own.encode().length + mac.length;
        // "-> g <arg>\n\n" is 7 bytes plus the argument.
        final argument = 'x' * (target - fixed - 7);
        final text = '$lead${own.encode()}'
            '${AgeStanza('g', [argument], Uint8List(0)).encode()}$mac';
        expect(text.length, target);
        return text;
      }

      final atLimit = ascii.encode(headerOfLength(65536));
      expect(AgeHeader.parse(atLimit).length, 65536);
      expect(ageMaxHeaderLength, 65536);

      final overLimit = ascii.encode(headerOfLength(65537));
      expect(
          () => AgeHeader.parse(overLimit),
          throwsA(isA<AgeMalformedException>()
              .having((e) => e.message, 'message', contains('64 KiB'))));
      await expectLater(ageDecrypt(overLimit, identities: [identity1]),
          throwsAge<AgeMalformedException>());

      // A stanza body that never ends within the cap.
      final endless = concat([
        ascii.encode('age-encryption.org/v1\n-> X25519 abc\n'),
        for (var i = 0; i < 1100; i++) ascii.encode('${'A' * 64}\n'),
      ]);
      expect(endless.length, greaterThan(65536));
      expect(() => AgeHeader.parse(endless),
          throwsA(isA<AgeMalformedException>()));
      // The same data cut short of the cap just needs more bytes.
      expect(() => AgeHeader.parse(Uint8List.sublistView(endless, 0, 4096)),
          throwsA(isA<AgeIncompleteHeaderException>()));
    });

    test('rejects everything the grammar forbids', () async {
      final sample = await buildSample(identity1, 10);
      final text = latin1.decode(sample.header.bytes);
      final lines = text.split('\n'); // version, args, body, mac, ''
      expect(lines, hasLength(5));
      final version = lines[0],
          args = lines[1],
          body = lines[2],
          mac = lines[3];
      String build(List<String> parts) => '${parts.join('\n')}\n';

      // A character whose low bits are set makes the 43-character encoding
      // of 32 bytes non-canonical (its last two bits must be zero).
      String nonCanonical(String value) {
        const alphabet =
            'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/';
        final index = alphabet.indexOf(value[value.length - 1]);
        expect(index % 4, 0, reason: 'fixture is canonical');
        return value.substring(0, value.length - 1) + alphabet[index + 1];
      }

      final malformed = <String, String>{
        'empty file': '',
        'not age': 'PK\u0003\u0004 definitely a zip file\n',
        'missing version': build([args, body, mac]),
        'version with CRLF': build(['$version\r', args, body, mac]),
        'version trailing space': build(['$version ', args, body, mac]),
        'no stanza': build([version, mac]),
        'stanza without arguments': build([version, '->', body, mac]),
        'stanza with empty argument list': build([version, '-> ', body, mac]),
        'double space between arguments': build(
            [version, args.replaceFirst(' X25519 ', ' X25519  '), body, mac]),
        'trailing space after arguments': build([version, '$args ', body, mac]),
        'tab in arguments': build(
            [version, args.replaceFirst('X25519 ', 'X25519\t'), body, mac]),
        'non-ASCII argument': build([version, '$args é', body, mac]),
        'CRLF line endings': text.replaceAll('\n', '\r\n'),
        'padded body': build([version, args, '$body=', mac]),
        'non-canonical body': build([version, args, nonCanonical(body), mac]),
        'non-canonical share': build([
          version,
          '-> X25519 ${nonCanonical(args.substring(10))}',
          body,
          mac
        ]),
        'non-canonical MAC': build(
            [version, args, body, '--- ${nonCanonical(mac.substring(4))}']),
        'padded MAC': build([version, args, body, '$mac=']),
        'url-safe base64 body':
            build([version, args, '${body.substring(0, 42)}-', mac]),
        'body line of 65 columns': build([version, args, 'A' * 65, '', mac]),
        'full line without a short final line':
            build([version, '-> g', 'A' * 64, args, body, mac]),
        'body with a 1-character remainder': build([version, args, 'A', mac]),
        'short MAC':
            build([version, args, body, mac.substring(0, mac.length - 1)]),
        'long MAC': build([version, args, body, '${mac}A']),
        'MAC without space':
            build([version, args, body, '---${mac.substring(4)}']),
        'MAC with two spaces':
            build([version, args, body, '---  ${mac.substring(4)}']),
        'MAC with trailing space': build([version, args, body, '$mac ']),
        'missing MAC value': build([version, args, body, '---']),
        'garbage line': build([version, args, body, 'hello', mac]),
        'short X25519 share':
            build([version, '-> X25519 ${b64(Uint8List(31))}', body, mac]),
        'long X25519 share':
            build([version, '-> X25519 ${b64(Uint8List(33))}', body, mac]),
        'X25519 with an extra argument':
            build([version, '$args extra', body, mac]),
        'X25519 without a share': build([version, '-> X25519', body, mac]),
        'short X25519 body': build([version, args, b64(Uint8List(31)), mac]),
        'long X25519 body': build([version, args, b64(Uint8List(33)), mac]),
      };
      for (final entry in malformed.entries) {
        await expectLater(
          ageDecrypt(
              concat(
                  [latin1.encode(entry.value), sample.nonce, ...sample.chunks]),
              identities: [identity1]),
          throwsAge<AgeMalformedException>(),
          reason: entry.key,
        );
      }

      final unsupported = <String, String>{
        'future version': build(['age-encryption.org/v2', args, body, mac]),
        'ASCII armor': '-----BEGIN AGE ENCRYPTED FILE-----\n'
            'YWdlLWVuY3J5cHRpb24ub3JnL3YxCg==\n'
            '-----END AGE ENCRYPTED FILE-----\n',
      };
      for (final entry in unsupported.entries) {
        await expectLater(
          ageDecrypt(latin1.encode(entry.value), identities: [identity1]),
          throwsAge<AgeUnsupportedException>(),
          reason: entry.key,
        );
      }
    });

    test('a low-order X25519 share is rejected', () async {
      final sample = await buildSample(identity1, 10);
      final lines = latin1.decode(sample.header.bytes).split('\n');
      for (final point in [Uint8List(32), Uint8List(32)..[0] = 1]) {
        final text = '${lines[0]}\n-> X25519 ${b64(point)}\n${lines[2]}\n'
            '${lines[3]}\n';
        await expectLater(
            ageReadHeader(latin1.encode(text), identities: [identity1]),
            throwsAge<AgeMalformedException>());
      }
      await expectLater(
          ageEncrypt(Uint8List(1),
              recipients: [bech32Encode('age', Uint8List(32))]),
          throwsAge<AgeInvalidKeyException>());
    });

    test('files for unsupported recipient types report a typed error',
        () async {
      final text = 'age-encryption.org/v1\n'
          '${AgeStanza('ssh-ed25519', [
                'abcd',
                b64(Uint8List(32))
              ], Uint8List(32)).encode()}'
          '${AgeStanza('mlkem768x25519', [
                b64(Uint8List(8))
              ], Uint8List(32)).encode()}'
          '--- ${b64(Uint8List(32))}\n';
      await expectLater(
        ageDecrypt(ascii.encode(text), identities: [identity1]),
        throwsA(isA<AgeUnsupportedRecipientException>().having(
            (e) => e.stanzaTypes, 'types', ['ssh-ed25519', 'mlkem768x25519'])),
      );
      // It is also a "no matching identity" failure for callers that do not
      // distinguish.
      await expectLater(ageDecrypt(ascii.encode(text), identities: [identity1]),
          throwsAge<AgeNoMatchingIdentityException>());
    });
  });

  group('scrypt stanzas', () {
    String scryptHeader(String workFactor,
            {String? salt, String? body, String extra = ''}) =>
        'age-encryption.org/v1\n'
        '-> scrypt ${salt ?? b64(Uint8List(16))} $workFactor$extra\n'
        '${body ?? b64(Uint8List(32))}\n'
        '--- ${b64(Uint8List(32))}\n';

    test('work factor 21 is rejected without running scrypt', () async {
      final file = concat([ascii.encode(scryptHeader('21')), Uint8List(32)]);
      final watch = Stopwatch()..start();
      await expectLater(
          ageDecrypt(file, passphrase: 'anything'),
          throwsA(isA<AgeUnsupportedException>()
              .having((e) => e.message, 'message', contains('20'))));
      // scrypt at 2^21 needs 2 GiB and many seconds; rejection is immediate.
      expect(watch.elapsedMilliseconds, lessThan(500));

      for (final huge in ['22', '30', '64', '99999', '18446744073709551617']) {
        await expectLater(
            ageDecrypt(ascii.encode(scryptHeader(huge)), passphrase: 'x'),
            throwsAge<AgeUnsupportedException>(),
            reason: huge);
      }
      expect(ageMaxScryptWorkFactor, 20);
    });

    test('the reader limit can be lowered by the caller', () async {
      final file = await ageEncrypt(pattern(5),
          passphrase: 'twelve chars', scryptWorkFactor: 9);
      await expectLater(
          ageDecrypt(file, passphrase: 'twelve chars', maxScryptWorkFactor: 8),
          throwsAge<AgeUnsupportedException>());
      expect(
          await ageDecrypt(file,
              passphrase: 'twelve chars', maxScryptWorkFactor: 9),
          pattern(5));
      await expectLater(
          ageDecrypt(file, passphrase: 'twelve chars', maxScryptWorkFactor: 21),
          throwsRangeError);
    });

    test('malformed scrypt stanzas are rejected before any work', () async {
      final cases = <String, String>{
        'zero': scryptHeader('0'),
        'leading zero': scryptHeader('010'),
        'plus sign': scryptHeader('+10'),
        'negative': scryptHeader('-10'),
        'hex': scryptHeader('0xa'),
        'trailing garbage': scryptHeader('10a'),
        'exponent': scryptHeader('1e1'),
        'missing work factor':
            'age-encryption.org/v1\n-> scrypt ${b64(Uint8List(16))}\n'
                '${b64(Uint8List(32))}\n--- ${b64(Uint8List(32))}\n',
        'extra argument': scryptHeader('10', extra: ' 10'),
        'short salt': scryptHeader('10', salt: b64(Uint8List(15))),
        'long salt': scryptHeader('10', salt: b64(Uint8List(17))),
        'non-canonical salt':
            scryptHeader('10', salt: 'AAAAAAAAAAAAAAAAAAAAAB'),
        'short body': scryptHeader('10', body: b64(Uint8List(31))),
        'long body': scryptHeader('10', body: b64(Uint8List(33))),
      };
      for (final entry in cases.entries) {
        await expectLater(
          ageDecrypt(ascii.encode(entry.value), passphrase: 'x'),
          throwsAge<AgeMalformedException>(),
          reason: entry.key,
        );
      }
    });

    test('an scrypt stanza next to any other stanza is rejected', () async {
      final sample = await buildSample(identity1, 10);
      final x25519 = sample.header.stanzas.single.encode();
      final real = AgeHeader.parse(fixture('passphrase_wf10.age'));
      final scrypt = real.stanzas.single.encode();
      final mac = '--- ${b64(Uint8List(32))}\n';
      for (final stanzas in [
        '$x25519$scrypt',
        '$scrypt$x25519',
        '$scrypt$scrypt',
        '$scrypt${AgeStanza('grease', [], Uint8List(0)).encode()}',
      ]) {
        final file = ascii.encode('age-encryption.org/v1\n$stanzas$mac');
        expect(
            () => AgeHeader.parse(file), throwsA(isA<AgeMalformedException>()));
        await expectLater(ageDecrypt(file, identities: [identity1]),
            throwsAge<AgeMalformedException>());
        await expectLater(ageDecrypt(file, passphrase: fixturePassphrase),
            throwsAge<AgeMalformedException>());
      }
    });

    test('the wrong kind of secret is reported distinctly', () async {
      final passphraseFile = fixture('passphrase_wf10.age');
      await expectLater(
        ageDecrypt(passphraseFile, identities: [identity1]),
        throwsA(isA<AgeNoMatchingIdentityException>()
            .having((e) => e.passphraseRequired, 'passphraseRequired', true)),
      );
      await expectLater(
        ageDecrypt(fixture('x25519_1.age'), passphrase: fixturePassphrase),
        throwsA(isA<AgeNoMatchingIdentityException>()
            .having((e) => e.passphraseRequired, 'passphraseRequired', false)),
      );
      await expectLater(ageDecrypt(fixture('x25519_1.age')),
          throwsAge<AgeNoMatchingIdentityException>());
    });
  });

  group('tampering and truncation', () {
    // Two full chunks and a short final chunk.
    const size = 2 * ageChunkSize + 100;
    late Sample sample;
    // Exactly two full chunks: the final chunk is full length.
    late Sample full;

    setUpAll(() async {
      sample = await buildSample(identity1, size);
      full = await buildSample(identity1, 2 * ageChunkSize);
    });

    Future<Uint8List> open(Uint8List file) =>
        ageDecrypt(file, identities: [identity1]);

    test('the undamaged samples decrypt', () async {
      expect(await open(sample.bytes), sample.plaintext);
      expect(await open(full.bytes), full.plaintext);
    });

    test('a bit flip anywhere in the header is rejected', () async {
      final file = sample.bytes;
      for (var offset = 0; offset < sample.header.length; offset++) {
        for (final mask in [0x01, 0x80]) {
          await expectLater(
              open(flipBit(file, offset, mask)), throwsA(isA<AgeException>()),
              reason: 'offset $offset mask $mask');
        }
      }
    });

    test('a changed MAC or a header edit that keeps the key fails the MAC',
        () async {
      final text = latin1.decode(sample.header.bytes);
      final macStart = text.lastIndexOf('--- ') + 4;
      // Swap one MAC character for another canonical one.
      final current = text[macStart];
      final swapped =
          text.replaceRange(macStart, macStart + 1, current == 'A' ? 'B' : 'A');
      await expectLater(
          open(
              concat([latin1.encode(swapped), sample.nonce, ...sample.chunks])),
          authFailureAt(null));

      // Appending a stanza leaves the file key recoverable but changes the
      // MAC input.
      final extended = text.replaceFirst(
          '--- ', '${AgeStanza('grease', ['x'], Uint8List(3)).encode()}--- ');
      await expectLater(
          open(concat(
              [latin1.encode(extended), sample.nonce, ...sample.chunks])),
          authFailureAt(null));
    });

    test('a bit flip in the nonce or any payload chunk names the chunk',
        () async {
      final file = sample.bytes;
      final h = sample.header.length;
      await expectLater(open(flipBit(file, h)), authFailureAt(0));
      await expectLater(open(flipBit(file, h + 15, 0x80)), authFailureAt(0));
      await expectLater(
          open(flipBit(file, sample.chunkOffset(0))), authFailureAt(0));
      await expectLater(
          open(flipBit(file, sample.chunkOffset(1) - 1)), authFailureAt(0),
          reason: 'last tag byte of chunk 0');
      await expectLater(
          open(flipBit(file, sample.chunkOffset(1))), authFailureAt(1));
      await expectLater(
          open(flipBit(file, sample.chunkOffset(1) + 30000, 0x10)),
          authFailureAt(1));
      await expectLater(
          open(flipBit(file, sample.chunkOffset(2))), authFailureAt(2));
      await expectLater(
          open(flipBit(file, file.length - 1, 0x40)), authFailureAt(2));
    });

    test('truncation at a chunk boundary is rejected', () async {
      final file = sample.bytes;
      // Dropping the final chunk makes chunk 1 the apparent final chunk.
      await expectLater(
          open(Uint8List.sublistView(file, 0, sample.chunkOffset(2))),
          authFailureAt(1));
      await expectLater(
          open(Uint8List.sublistView(file, 0, sample.chunkOffset(1))),
          authFailureAt(0));
      await expectLater(
          open(sample.withChunks([sample.chunks[0]])), authFailureAt(0));
      // Nothing after the nonce, part of the nonce, nothing after the header.
      await expectLater(
          open(Uint8List.sublistView(file, 0, sample.chunkOffset(0))),
          throwsAge<AgeMalformedException>());
      await expectLater(
          open(Uint8List.sublistView(file, 0, sample.header.length + 7)),
          throwsAge<AgeMalformedException>());
      await expectLater(open(Uint8List.fromList(sample.header.bytes)),
          throwsAge<AgeMalformedException>());
    });

    test('truncation in the middle of a chunk is rejected', () async {
      final file = sample.bytes;
      await expectLater(
          open(Uint8List.sublistView(file, 0, sample.chunkOffset(1) + 1000)),
          authFailureAt(1));
      await expectLater(open(Uint8List.sublistView(file, 0, file.length - 1)),
          authFailureAt(2));
      await expectLater(
          open(Uint8List.sublistView(file, 0, sample.chunkOffset(0) + 40)),
          authFailureAt(0));
      // Fewer bytes than a tag cannot be a chunk at all.
      await expectLater(
          open(Uint8List.sublistView(file, 0, sample.chunkOffset(2) + 15)),
          throwsAge<AgeMalformedException>());
      // Exactly a tag after full chunks would be an empty final chunk.
      await expectLater(
          open(Uint8List.sublistView(file, 0, sample.chunkOffset(2) + 16)),
          throwsAge<AgeMalformedException>());
    });

    test('a missing final flag is rejected', () async {
      final cipher = full.cipher;
      final first = Uint8List.sublistView(full.plaintext, 0, ageChunkSize);
      final second = Uint8List.sublistView(full.plaintext, ageChunkSize);
      final unflagged = full.withChunks([
        await cipher.sealChunk(0, first, last: false),
        await cipher.sealChunk(1, second, last: false),
      ]);
      await expectLater(open(unflagged), authFailureAt(1));
      // A single full chunk without the flag.
      final single = full.withChunks([
        await cipher.sealChunk(0, first, last: false),
      ]);
      await expectLater(open(single), authFailureAt(0));
    });

    test('an extra trailing chunk or trailing bytes are rejected', () async {
      final extraFull =
          await full.cipher.sealChunk(2, pattern(ageChunkSize), last: true);
      await expectLater(
          open(full.withChunks([...full.chunks, extraFull])), authFailureAt(1));
      final extraShort = await full.cipher.sealChunk(2, pattern(5), last: true);
      await expectLater(open(full.withChunks([...full.chunks, extraShort])),
          authFailureAt(1));
      // An empty final chunk after a full final chunk.
      final emptyTail =
          await full.cipher.openChunk(0, full.chunks[0], last: false);
      expect(emptyTail, hasLength(ageChunkSize));
      await expectLater(open(concat([full.bytes, Uint8List(16)])),
          throwsAge<AgeMalformedException>());
      await expectLater(open(concat([full.bytes, Uint8List(1)])),
          throwsAge<AgeMalformedException>());
      await expectLater(
          open(concat([full.bytes, Uint8List(17)])), authFailureAt(1));
      // After a short final chunk the extra bytes are absorbed into it.
      final extra = await sample.cipher.sealChunk(3, pattern(50), last: true);
      await expectLater(
          open(sample.withChunks([...sample.chunks, extra])), authFailureAt(2));
      await expectLater(
          open(concat([sample.bytes, Uint8List(1)])), authFailureAt(2));
      // The final chunk repeated.
      await expectLater(
          open(sample.withChunks([...sample.chunks, sample.chunks[2]])),
          authFailureAt(2));
    });

    test('swapped, duplicated and dropped chunks are rejected', () async {
      final c = sample.chunks;
      await expectLater(
          open(sample.withChunks([c[1], c[0], c[2]])), authFailureAt(0));
      await expectLater(
          open(sample.withChunks([c[0], c[0], c[2]])), authFailureAt(1));
      await expectLater(
          open(sample.withChunks([c[1], c[2]])), authFailureAt(0));
      await expectLater(
          open(sample.withChunks([c[0], c[2]])), authFailureAt(1));
      final f = full.chunks;
      await expectLater(open(full.withChunks([f[1], f[0]])), authFailureAt(0));
    });

    test('chunks from another file with the same key do not transplant',
        () async {
      // Same file key, different payload nonce.
      final other =
          await AgePayloadCipher.create(sample.fileKey, Uint8List(16)..[0] = 1);
      final foreign = await other.sealChunk(
          1,
          Uint8List.sublistView(
              sample.plaintext, ageChunkSize, 2 * ageChunkSize),
          last: false);
      final c = sample.chunks;
      await expectLater(
          open(sample.withChunks([c[0], foreign, c[2]])), authFailureAt(1));
    });

    test('the wrong identity and the wrong passphrase are typed', () async {
      await expectLater(ageDecrypt(sample.bytes, identities: [identity2]),
          throwsAge<AgeNoMatchingIdentityException>());
      final file = await ageEncrypt(pattern(40),
          passphrase: 'the right passphrase', scryptWorkFactor: 8);
      await expectLater(ageDecrypt(file, passphrase: 'the wrong passphrase'),
          throwsAge<AgeWrongPassphraseException>());
      await expectLater(ageDecrypt(file, passphrase: ''),
          throwsAge<AgeWrongPassphraseException>());
    });

    test('error text never contains key material', () async {
      final secrets = [
        identity1Text,
        identity1Text.substring(16),
        b64(sample.fileKey),
        sample.fileKey.map((b) => b.toRadixString(16).padLeft(2, '0')).join(),
        'the right passphrase',
      ];
      final file = await ageEncrypt(pattern(40),
          passphrase: 'the right passphrase', scryptWorkFactor: 8);
      // Closures, so each failure is created only when it is awaited.
      final failures = <Future<Object?> Function()>[
        () => open(flipBit(sample.bytes, sample.chunkOffset(1))),
        () => open(flipBit(sample.bytes, 30)),
        () => ageDecrypt(sample.bytes, identities: [identity2]),
        () => ageDecrypt(file, passphrase: 'not the right passphrase'),
        () => ageDecrypt(flipBit(file, file.length - 1),
            passphrase: 'the right passphrase'),
        () => AgeIdentity.parse('${identity1Text}X'),
      ];
      for (final failure in failures) {
        try {
          await failure();
          fail('expected a failure');
        } on AgeException catch (error) {
          for (final secret in secrets) {
            expect(error.toString(), isNot(contains(secret)));
            expect(error.message, isNot(contains(secret)));
          }
        }
      }
      expect(sample.header.toString(), isNot(contains(b64(sample.fileKey))));
    });
  });

  group('chunk cipher', () {
    late Sample sample;

    setUpAll(() async {
      sample = await buildSample(identity1, ageChunkSize + 10);
    });

    test('seal enforces the chunk layout', () async {
      final c = sample.cipher;
      await expectLater(c.sealChunk(0, Uint8List(ageChunkSize + 1), last: true),
          throwsArgumentError);
      await expectLater(
          c.sealChunk(0, Uint8List(ageChunkSize - 1), last: false),
          throwsArgumentError);
      await expectLater(
          c.sealChunk(0, Uint8List(0), last: false), throwsArgumentError);
      await expectLater(
          c.sealChunk(1, Uint8List(0), last: true), throwsArgumentError);
      await expectLater(
          c.sealChunk(-1, Uint8List(1), last: true), throwsRangeError);
      expect(await c.sealChunk(0, Uint8List(0), last: true), hasLength(16));
      expect(await c.sealChunk(0, Uint8List(ageChunkSize), last: true),
          hasLength(sealedChunk));
      await expectLater(AgePayloadCipher.create(Uint8List(15), Uint8List(16)),
          throwsArgumentError);
      await expectLater(AgePayloadCipher.create(Uint8List(16), Uint8List(15)),
          throwsArgumentError);
    });

    test('sealing is deterministic per index and flag', () async {
      final c = sample.cipher;
      final data = pattern(ageChunkSize);
      final a = await c.sealChunk(5, data, last: false);
      expect(await c.sealChunk(5, data, last: false), a);
      expect(await c.sealChunk(6, data, last: false), isNot(a));
      expect(await c.sealChunk(5, data, last: true), isNot(a));
      // The counter is big-endian in the 11 bytes before the flag: indices
      // above 32 bits round trip.
      final high = await c.sealChunk(0x1234567890, data, last: false);
      expect(await c.openChunk(0x1234567890, high, last: false), data);
      await expectLater(c.openChunk(0x1234567891, high, last: false),
          authFailureAt(0x1234567891));
    });

    test('open requires the right index, flag and size', () async {
      final c = sample.cipher;
      final first = sample.chunks[0], last = sample.chunks[1];
      expect(await c.openChunk(0, first, last: false),
          Uint8List.sublistView(sample.plaintext, 0, ageChunkSize));
      expect(await c.openChunk(1, last, last: true),
          Uint8List.sublistView(sample.plaintext, ageChunkSize));
      await expectLater(c.openChunk(1, first, last: false), authFailureAt(1));
      await expectLater(c.openChunk(0, first, last: true), authFailureAt(0));
      await expectLater(c.openChunk(0, last, last: true), authFailureAt(0));
      // A short chunk that is not final.
      await expectLater(c.openChunk(1, last, last: false),
          throwsAge<AgeMalformedException>());
      await expectLater(c.openChunk(0, Uint8List(15), last: true),
          throwsAge<AgeMalformedException>());
      await expectLater(c.openChunk(0, Uint8List(sealedChunk + 1), last: true),
          throwsAge<AgeMalformedException>());
      await expectLater(c.openChunk(1, Uint8List(16), last: true),
          throwsAge<AgeMalformedException>());
      await expectLater(
          c.openChunk(0, Uint8List(16), last: true), authFailureAt(0));
    });
  });

  group('size and offset arithmetic', () {
    test('constants', () {
      expect(ageChunkSize, 65536);
      expect(ageChunkOverhead, 16);
      expect(agePayloadNonceLength, 16);
    });

    test('ciphertext length boundary table', () {
      // header, plaintext, expected file size, chunks
      const table = <List<int>>[
        [200, 0, 232, 1],
        [200, 1, 233, 1],
        [200, 2, 234, 1],
        [200, 65535, 65767, 1],
        [200, 65536, 65768, 1],
        [200, 65537, 65785, 2],
        [200, 131071, 131319, 2],
        [200, 131072, 131320, 2],
        [200, 131073, 131337, 3],
        [200, 196608, 196872, 3],
        [200, 196609, 196889, 4],
        [200, 1048576, 1049048, 16],
        [200, 1048577, 1049065, 17],
        [0, 0, 32, 1],
        [0, 65536, 65568, 1],
        [0, 65537, 65585, 2],
        [65536, 0, 65568, 1],
        [65536, 65537, 131121, 2],
        // 5 GiB and 50,000 GiB (the S3 object limit) of plaintext.
        [200, 5368709120, 5370020056, 81920],
        [200, 53687091200000, 53700198400216, 819200000],
      ];
      for (final row in table) {
        final h = row[0], p = row[1], c = row[2], n = row[3];
        expect(ageChunkCount(p), n, reason: 'chunks for $p');
        expect(ageCiphertextLength(headerLength: h, plaintextLength: p), c,
            reason: 'ciphertext for h=$h p=$p');
        expect(agePlaintextLength(headerLength: h, ciphertextLength: c), p,
            reason: 'plaintext for h=$h c=$c');
      }
      expect(() => ageChunkCount(-1), throwsRangeError);
      expect(() => ageCiphertextLength(headerLength: -1, plaintextLength: 0),
          throwsRangeError);
      expect(() => ageCiphertextLength(headerLength: 0, plaintextLength: -1),
          throwsRangeError);
      expect(() => agePlaintextLength(headerLength: -1, ciphertextLength: 0),
          throwsRangeError);
    });

    test('plaintext length is the exact inverse over every size', () {
      const h = 173;
      const maxPlain = 3 * ageChunkSize + 50;
      final valid = <int, int>{
        for (var p = 0; p <= maxPlain; p++)
          ageCiphertextLength(headerLength: h, plaintextLength: p): p,
      };
      expect(valid, hasLength(maxPlain + 1), reason: 'injective');
      final maxCipher =
          ageCiphertextLength(headerLength: h, plaintextLength: maxPlain);
      var impossible = 0;
      for (var c = 0; c <= maxCipher; c++) {
        final expected = valid[c];
        if (expected != null) {
          expect(agePlaintextLength(headerLength: h, ciphertextLength: c),
              expected);
        } else {
          impossible++;
          expect(() => agePlaintextLength(headerLength: h, ciphertextLength: c),
              throwsA(isA<AgeMalformedException>()),
              reason: 'ciphertext length $c');
        }
      }
      // Header + nonce + first tag (h + 32 sizes) and, per later chunk
      // boundary, the 16 sizes that would leave a tag-less or empty chunk.
      expect(impossible, h + 32 + 3 * 16);
    });

    test('named impossible sizes', () {
      const h = 200;
      for (final c in [
        0, h - 1, h, h + 15, h + 16, h + 31, // no room for nonce + tag
        h + 16 + sealedChunk + 1, // 1 byte of a second chunk
        h + 16 + sealedChunk + 15, // 15 bytes: shorter than a tag
        h + 16 + sealedChunk + 16, // empty final chunk after a full one
        h + 16 + 2 * sealedChunk + 16,
      ]) {
        expect(() => agePlaintextLength(headerLength: h, ciphertextLength: c),
            throwsA(isA<AgeMalformedException>()),
            reason: '$c');
      }
      expect(
          agePlaintextLength(
              headerLength: h, ciphertextLength: h + 16 + sealedChunk),
          65536);
      expect(
          agePlaintextLength(
              headerLength: h, ciphertextLength: h + 16 + sealedChunk + 17),
          65537);
    });

    test('plaintext ranges map to exact ciphertext ranges (literal table)', () {
      const h = 200;
      const p = 2 * ageChunkSize + 1000; // 3 chunks, total 132_320 bytes
      const base = h + 16;
      const total = 200 + 16 + p + 3 * 16;
      // start, end, first chunk, last chunk, ciphertext start, ciphertext end
      const table = <List<int>>[
        [0, 1, 0, 0, base, base + 65552],
        [0, 65536, 0, 0, base, base + 65552],
        [65535, 65536, 0, 0, base, base + 65552],
        [65535, 65537, 0, 1, base, base + 131104],
        [65536, 65537, 1, 1, base + 65552, base + 131104],
        [0, 65537, 0, 1, base, base + 131104],
        [65536, 131072, 1, 1, base + 65552, base + 131104],
        [131071, 131072, 1, 1, base + 65552, base + 131104],
        [131071, 131073, 1, 2, base + 65552, total],
        [131072, 131073, 2, 2, base + 131104, total],
        [131072, p, 2, 2, base + 131104, total],
        [p - 1, p, 2, 2, base + 131104, total],
        [0, p, 0, 2, base, total],
        [1, p - 1, 0, 2, base, total],
        [100, 200, 0, 0, base, base + 65552],
        [70000, 70001, 1, 1, base + 65552, base + 131104],
        // Empty ranges resolve to the chunk holding the position.
        [0, 0, 0, 0, base, base + 65552],
        [65536, 65536, 1, 1, base + 65552, base + 131104],
        [p, p, 2, 2, base + 131104, total],
      ];
      for (final row in table) {
        final r = ageCiphertextRangeForPlaintext(
            headerLength: h,
            plaintextLength: p,
            start: row[0],
            endExclusive: row[1]);
        expect([
          r.firstChunk,
          r.lastChunk,
          r.start,
          r.endExclusive
        ], row.sublist(2), reason: 'plaintext [${row[0]}, ${row[1]})');
      }

      // Payloads that end exactly on a chunk boundary, and tiny payloads.
      final exact = ageCiphertextRangeForPlaintext(
          headerLength: h,
          plaintextLength: 131072,
          start: 131071,
          endExclusive: 131072);
      expect(exact, (
        start: base + 65552,
        endExclusive: base + 131104,
        firstChunk: 1,
        lastChunk: 1
      ));
      final atEnd = ageCiphertextRangeForPlaintext(
          headerLength: h,
          plaintextLength: 131072,
          start: 131072,
          endExclusive: 131072);
      expect(atEnd.firstChunk, 1);
      expect(atEnd.endExclusive, base + 131104);
      final empty = ageCiphertextRangeForPlaintext(
          headerLength: h, plaintextLength: 0, start: 0, endExclusive: 0);
      expect(empty,
          (start: base, endExclusive: base + 16, firstChunk: 0, lastChunk: 0));
      final one = ageCiphertextRangeForPlaintext(
          headerLength: h, plaintextLength: 1, start: 0, endExclusive: 1);
      expect(one,
          (start: base, endExclusive: base + 17, firstChunk: 0, lastChunk: 0));

      for (final bad in [
        [-1, 1],
        [2, 1],
        [0, p + 1],
        [p + 1, p + 1],
      ]) {
        expect(
            () => ageCiphertextRangeForPlaintext(
                headerLength: h,
                plaintextLength: p,
                start: bad[0],
                endExclusive: bad[1]),
            throwsRangeError,
            reason: '$bad');
      }
    });

    for (final size in [0, 1, 65535, 65536, 65537, 131072, 131073 + 999]) {
      test('ranged reads of a $size-byte payload decrypt real ciphertext',
          () async {
        final sample = await buildSample(identity1, size);
        final file = sample.bytes;
        final h = sample.header.length;
        final chunkCount = ageChunkCount(size);
        final edges = <int>{
          0,
          1,
          2,
          100,
          65535,
          65536,
          65537,
          70000,
          131071,
          131072,
          131073,
          size - 1,
          size,
        }.where((v) => v >= 0 && v <= size).toList()
          ..sort();
        var checked = 0;
        for (final start in edges) {
          for (final end in edges.where((e) => e >= start)) {
            final r = ageCiphertextRangeForPlaintext(
                headerLength: h,
                plaintextLength: size,
                start: start,
                endExclusive: end);
            expect(r.start, sample.chunkOffset(r.firstChunk));
            expect(r.endExclusive, lessThanOrEqualTo(file.length));
            // "Fetch" exactly that byte range and decrypt it chunk by chunk.
            final fetched =
                Uint8List.sublistView(file, r.start, r.endExclusive);
            final clear = BytesBuilder(copy: false);
            for (var i = r.firstChunk; i <= r.lastChunk; i++) {
              final from = (i - r.firstChunk) * sealedChunk;
              final to = min(from + sealedChunk, fetched.length);
              clear.add(await sample.cipher.openChunk(
                i,
                Uint8List.sublistView(fetched, from, to),
                last: i == chunkCount - 1,
              ));
            }
            final decrypted = clear.takeBytes();
            final skip = start - r.firstChunk * ageChunkSize;
            expect(Uint8List.sublistView(decrypted, skip, skip + (end - start)),
                Uint8List.sublistView(sample.plaintext, start, end),
                reason: 'plaintext [$start, $end)');
            // The range is minimal: whole chunks, none beyond the last.
            if (end > start) {
              expect(r.firstChunk, start ~/ ageChunkSize);
              expect(r.lastChunk, (end - 1) ~/ ageChunkSize);
            }
            checked++;
          }
        }
        expect(checked, greaterThan(0));
      });
    }

    test('ciphertext parts map to the chunks a multipart worker must seal',
        () async {
      for (final size in [0, 1, 65536, 65537, 3 * ageChunkSize + 77]) {
        final sample = await buildSample(identity1, size);
        final file = sample.bytes;
        final h = sample.header.length;
        final count = ageChunkCount(size);
        for (final partSize in [1 << 20, 100000, 65552, 65551, 50000, 4096]) {
          final rebuilt = BytesBuilder(copy: false);
          for (var a = 0; a < file.length; a += partSize) {
            final b = min(a + partSize, file.length);
            // A worker produces ciphertext bytes [a, b) from its own chunks.
            final part = Uint8List(b - a);
            void place(int offset, List<int> bytes) {
              final from = max(a, offset);
              final to = min(b, offset + bytes.length);
              if (to > from) {
                part.setRange(from - a, to - a, bytes, from - offset);
              }
            }

            place(0, sample.header.bytes);
            place(h, sample.nonce);
            final chunks = ageChunksForCiphertextRange(
                headerLength: h,
                plaintextLength: size,
                start: a,
                endExclusive: b);
            if (chunks == null) {
              expect(b, lessThanOrEqualTo(h + 16));
            } else {
              expect(chunks.firstChunk, lessThanOrEqualTo(chunks.lastChunk));
              expect(chunks.lastChunk, lessThan(count));
              for (var i = chunks.firstChunk; i <= chunks.lastChunk; i++) {
                final from = i * ageChunkSize;
                final sealed = await sample.cipher.sealChunk(
                  i,
                  Uint8List.sublistView(
                      sample.plaintext, from, min(from + ageChunkSize, size)),
                  last: i == count - 1,
                );
                place(sample.chunkOffset(i), sealed);
              }
              // Minimal: the chunks before and after do not overlap [a, b).
              if (chunks.firstChunk > 0) {
                expect(sample.chunkOffset(chunks.firstChunk),
                    lessThanOrEqualTo(a));
              }
              expect(sample.chunkOffset(chunks.lastChunk), lessThan(b));
              if (chunks.lastChunk < count - 1) {
                expect(sample.chunkOffset(chunks.lastChunk + 1),
                    greaterThanOrEqualTo(b));
              }
            }
            rebuilt.add(part);
          }
          expect(rebuilt.takeBytes(), file,
              reason: 'size $size in parts of $partSize');
        }
      }

      expect(
          ageChunksForCiphertextRange(
              headerLength: 200,
              plaintextLength: 10,
              start: 0,
              endExclusive: 216),
          isNull);
      expect(
          ageChunksForCiphertextRange(
              headerLength: 200,
              plaintextLength: 10,
              start: 0,
              endExclusive: 217),
          (firstChunk: 0, lastChunk: 0));
      expect(
          () => ageChunksForCiphertextRange(
              headerLength: 200,
              plaintextLength: 10,
              start: 5,
              endExclusive: 5),
          throwsRangeError);
      expect(
          () => ageChunksForCiphertextRange(
              headerLength: 200,
              plaintextLength: 10,
              start: 0,
              endExclusive: 243),
          throwsRangeError);
    });
  });

  group('live interoperability with the reference binary', () {
    final ageBin = Platform.environment['AGE_BIN'];
    final skip = ageBin == null || ageBin.isEmpty
        ? 'set AGE_BIN to the reference age binary to run'
        : false;
    late Directory temp;
    late Map<String, String> environment;

    setUp(() {
      temp = Directory.systemTemp.createTempSync('age-interop-');
      environment = {
        ...Platform.environment,
        'PATH': '${File(ageBin ?? '.').parent.path}'
            '${Platform.isWindows ? ';' : ':'}'
            '${Platform.environment['PATH'] ?? ''}',
      };
    });
    tearDown(() => temp.deleteSync(recursive: true));

    Future<void> run(List<String> arguments,
        {Map<String, String> extra = const {}}) async {
      final result = await Process.run(ageBin!, arguments,
          environment: {...environment, ...extra});
      expect(result.exitCode, 0,
          reason: 'age ${arguments.join(' ')}\n${result.stderr}');
    }

    Uint8List randomBytes(Random random, int length) => Uint8List.fromList(
        List<int>.generate(length, (_) => random.nextInt(256)));

    final liveSizes = [0, 1, 65535, 65536, 65537, 131072];

    test('our X25519 files decrypt with age, and age files with ours',
        () async {
      final random = Random.secure();
      final identity = await AgeIdentity.generate();
      final identityFile = File('${temp.path}/identity.txt')
        ..writeAsStringSync('${identity.secretKey}\n');
      for (final size in [...liveSizes, 200000 + random.nextInt(400000)]) {
        final plaintext = randomBytes(random, size);
        final plainFile = File('${temp.path}/plain-$size')
          ..writeAsBytesSync(plaintext);

        // Ours (whole buffer) -> reference.
        final ours = File('${temp.path}/ours-$size.age')
          ..writeAsBytesSync(
              await ageEncrypt(plaintext, recipients: [identity.recipient]));
        final out = File('${temp.path}/out-$size');
        await run(['-d', '-i', identityFile.path, '-o', out.path, ours.path]);
        expect(out.readAsBytesSync(), plaintext, reason: 'ours -> age, $size');

        // Ours (chunk API) -> reference.
        final sample = await buildSample(identity, size);
        final chunked = File('${temp.path}/chunked-$size.age')
          ..writeAsBytesSync(sample.bytes);
        await run(
            ['-d', '-i', identityFile.path, '-o', out.path, chunked.path]);
        expect(out.readAsBytesSync(), sample.plaintext,
            reason: 'chunk API -> age, $size');

        // Reference -> ours, both APIs.
        final theirs = File('${temp.path}/theirs-$size.age');
        await run(
            ['-r', identity.recipient, '-o', theirs.path, plainFile.path]);
        final bytes = theirs.readAsBytesSync();
        expect(await ageDecrypt(bytes, identities: [identity]), plaintext,
            reason: 'age -> ours, $size');
        expect(await decryptWithChunkApi(bytes, identities: [identity]),
            plaintext);
      }
    }, skip: skip, timeout: const Timeout(Duration(minutes: 3)));

    test('age-keygen identities agree with ours', () async {
      final keygen = File('${File(ageBin!).parent.path}/age-keygen');
      if (!keygen.existsSync()) {
        markTestSkipped('age-keygen is not next to AGE_BIN');
        return;
      }
      final keyFile = '${temp.path}/key.txt';
      final result = await Process.run(keygen.path, ['-o', keyFile]);
      expect(result.exitCode, 0, reason: '${result.stderr}');
      final lines = File(keyFile).readAsLinesSync();
      final secret = lines.firstWhere((l) => l.startsWith('AGE-SECRET-KEY-1'));
      final public = lines
          .firstWhere((l) => l.startsWith('# public key: '))
          .substring('# public key: '.length);
      final parsed = await AgeIdentity.parse(secret);
      expect(parsed.recipient, public);
      expect(parsed.secretKey, secret);

      // And the reverse: age-keygen -y derives our recipient from our key.
      final ours = await AgeIdentity.generate();
      final oursFile = File('${temp.path}/ours.txt')
        ..writeAsStringSync('${ours.secretKey}\n');
      final derived = await Process.run(keygen.path, ['-y', oursFile.path]);
      expect(derived.exitCode, 0, reason: '${derived.stderr}');
      expect((derived.stdout as String).trim(), ours.recipient);
    }, skip: skip);

    test('passphrase files interoperate through age-plugin-batchpass',
        () async {
      final plugin = File('${File(ageBin!).parent.path}/age-plugin-batchpass');
      if (!plugin.existsSync()) {
        markTestSkipped('age-plugin-batchpass is not next to AGE_BIN');
        return;
      }
      const passphrase = 'interop passphrase ✓ 7';
      final plaintext = randomBytes(Random.secure(), 70000);
      final plainFile = File('${temp.path}/plain')..writeAsBytesSync(plaintext);
      final out = File('${temp.path}/out');

      for (final workFactor in [10, ageDefaultScryptWorkFactor]) {
        final ours = File('${temp.path}/ours-$workFactor.age')
          ..writeAsBytesSync(await ageEncrypt(plaintext,
              passphrase: passphrase, scryptWorkFactor: workFactor));
        await run(['-d', '-j', 'batchpass', '-o', out.path, ours.path],
            extra: {'AGE_PASSPHRASE': passphrase});
        expect(out.readAsBytesSync(), plaintext,
            reason: 'ours (work factor $workFactor) -> age');
      }

      final theirs = File('${temp.path}/theirs.age');
      await run([
        '-e',
        '-j',
        'batchpass',
        '-o',
        theirs.path,
        plainFile.path
      ], extra: {
        'AGE_PASSPHRASE': passphrase,
        'AGE_PASSPHRASE_WORK_FACTOR': '12'
      });
      final bytes = theirs.readAsBytesSync();
      expect(AgeHeader.parse(bytes).scryptWorkFactor, 12);
      expect(await ageDecrypt(bytes, passphrase: passphrase), plaintext);
      await expectLater(ageDecrypt(bytes, passphrase: '$passphrase!'),
          throwsAge<AgeWrongPassphraseException>());
    }, skip: skip, timeout: const Timeout(Duration(minutes: 2)));
  });

  group('C2SP CCTV age vectors', () {
    final directory = Platform.environment['AGE_CCTV_DIR'];
    final skip = directory == null || directory.isEmpty
        ? 'set AGE_CCTV_DIR to CCTV/age/testdata to run'
        : false;

    test('every applicable vector gives the expected outcome', () async {
      final files = Directory(directory!).listSync().whereType<File>().toList()
        ..sort((a, b) => a.path.compareTo(b.path));
      expect(files, isNotEmpty);
      var passed = 0;
      final skipped = <String>[];
      final failures = <String>[];
      final byExpectation = <String, int>{};

      for (final file in files) {
        final name = file.uri.pathSegments.last;
        final raw = file.readAsBytesSync();
        var split = -1;
        for (var i = 0; i + 1 < raw.length; i++) {
          if (raw[i] == 0x0a && raw[i + 1] == 0x0a) {
            split = i;
            break;
          }
        }
        expect(split, greaterThan(0), reason: name);
        final meta = <String, List<String>>{};
        for (final line in latin1.decode(raw.sublist(0, split)).split('\n')) {
          final colon = line.indexOf(': ');
          meta
              .putIfAbsent(line.substring(0, colon), () => [])
              .add(line.substring(colon + 2));
        }
        var body = Uint8List.sublistView(raw, split + 2);
        if (meta['compressed']?.single == 'zlib') {
          body = Uint8List.fromList(zlib.decode(body));
        }
        final expectation = meta['expect']!.single;
        if (meta['armored']?.single == 'yes') {
          skipped.add('$name (ASCII armor)');
          continue;
        }
        final identityTexts = meta['identity'] ?? const <String>[];
        if (identityTexts.any((t) => !t.startsWith('AGE-SECRET-KEY-1'))) {
          skipped.add('$name (post-quantum identity)');
          continue;
        }
        final identities = [
          for (final text in identityTexts) await AgeIdentity.parse(text),
        ];
        final passphrases = meta['passphrase'] ?? const <String>[];
        if (passphrases.length > 1) {
          skipped.add('$name (several passphrases)');
          continue;
        }
        final passphrase = passphrases.isEmpty ? null : passphrases.single;
        final payloadHash = meta['payload']?.single;

        // Whole-buffer API.
        String outcome;
        Uint8List? plaintext;
        try {
          plaintext = await ageDecrypt(body,
              identities: identities, passphrase: passphrase);
          outcome = 'success';
        } on AgeNoMatchingIdentityException {
          outcome = 'no match';
        } on AgeWrongPassphraseException {
          outcome = 'no match';
        } on AgeAuthenticationException catch (error) {
          outcome =
              error.chunkIndex == null ? 'HMAC failure' : 'payload failure';
        } on AgeMalformedException catch (error) {
          outcome = error.message.contains('payload') ||
                  error.message.contains('chunk') ||
                  error.message.contains('too short')
              ? 'payload failure'
              : 'header failure';
        } on AgeUnsupportedException {
          outcome = 'header failure';
        }

        var ok = outcome == expectation;
        var detail = 'expected "$expectation", got "$outcome"';
        if (ok && expectation == 'success') {
          ok = '${digests.sha256.convert(plaintext!)}' == payloadHash;
          detail = 'payload hash mismatch';
        }
        if (ok && expectation == 'payload failure' && payloadHash != null) {
          // The vectors define how much plaintext a streaming reader may
          // release before failing; check the chunk primitives against it.
          final released = await _streamUntilFailure(body,
              identities: identities, passphrase: passphrase);
          ok = '${digests.sha256.convert(released)}' == payloadHash;
          detail = 'streamed plaintext before the failure does not match';
        }
        byExpectation.update(expectation, (v) => v + 1, ifAbsent: () => 1);
        if (ok) {
          passed++;
        } else {
          failures.add('$name: $detail');
        }
      }

      // ignore: avoid_print
      print('CCTV age vectors: $passed passed, ${failures.length} failed, '
          '${skipped.length} skipped of ${files.length}; '
          'ran by expectation: $byExpectation');
      // ignore: avoid_print
      print('Skipped: ${skipped.join(', ')}');
      expect(failures, isEmpty);
      expect(passed, greaterThan(80));
    }, skip: skip, timeout: const Timeout(Duration(minutes: 5)));
  });
}

/// Streams a payload the way the reference reader does (a full chunk is
/// tried as non-final first, then as final) and returns the plaintext
/// released before the stream fails or ends.
Future<Uint8List> _streamUntilFailure(
  Uint8List file, {
  required List<AgeIdentity> identities,
  required String? passphrase,
}) async {
  final released = BytesBuilder(copy: false);
  final opened =
      await ageReadHeader(file, identities: identities, passphrase: passphrase);
  var position = opened.headerLength;
  if (file.length - position < agePayloadNonceLength) {
    return released.takeBytes();
  }
  final cipher = await AgePayloadCipher.create(opened.fileKey,
      Uint8List.sublistView(file, position, position + agePayloadNonceLength));
  position += agePayloadNonceLength;
  for (var index = 0;; index++) {
    final remaining = file.length - position;
    if (remaining == 0) break; // Ended without a final chunk.
    final take = min(remaining, sealedChunk);
    final chunk = Uint8List.sublistView(file, position, position + take);
    position += take;
    try {
      if (take < sealedChunk) {
        released.add(await cipher.openChunk(index, chunk, last: true));
        break;
      }
      try {
        released.add(await cipher.openChunk(index, chunk, last: false));
      } on AgeAuthenticationException {
        released.add(await cipher.openChunk(index, chunk, last: true));
        break; // Anything after a final chunk is trailing data.
      }
    } on AgeException {
      break;
    }
  }
  return released.takeBytes();
}
