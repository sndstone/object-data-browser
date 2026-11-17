import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:s3_browser_crossplat/models/domain_models.dart';
import 'package:s3_browser_crossplat/services/app_state_repository.dart';
import 'package:s3_browser_crossplat/services/client_encryption.dart';
import 'package:s3_browser_crossplat/services/crypto/age.dart';
import 'package:s3_browser_crossplat/services/diagnostic_safety.dart';
import 'package:s3_browser_crossplat/services/multipart_sizing.dart';
import 'app_state_repository_test.dart' show RecordingProfileSecretStore;
import 'object_encryption_test.dart' show encryptionProfile;
import 'client_encryption_fixture.dart';

void main() {
  late AgeIdentity identity;
  setUp(() async {
    identity = await AgeIdentity.generate();
  });
  ClientEncryptionRule rule(String prefix, {String bucket = 'bucket'}) =>
      ClientEncryptionRule(
          bucket: bucket,
          prefix: prefix,
          keyId: 'vault',
          recipient: identity.recipient,
          label: 'Vault');

  test('vault rules match bucket and longest literal prefix; default is off',
      () {
    final rules = [
      rule(''),
      rule('a/'),
      rule('a/b/'),
      rule('', bucket: 'other')
    ];
    expect(matchingClientEncryptionRule(rules, 'bucket', 'a/b/file'), rules[2]);
    expect(matchingClientEncryptionRule(rules, 'bucket', 'a/file'), rules[1]);
    expect(matchingClientEncryptionRule(rules, 'bucket', 'ab/file'), rules[0]);
    expect(matchingClientEncryptionRule(rules, 'unknown', 'a/file'), isNull);
    expect(matchingClientEncryptionRule([], 'bucket', 'a/file'), isNull);
    final old = encryptionProfile.toJson();
    expect(old.containsKey('clientEncryptionRules'), isFalse);
    expect(EndpointProfile.fromJson(old).toJson(), old);
    expect(encryptionProfile.copyWith(name: 'Renamed').clientEncryptionRules,
        isEmpty);
  });

  test(
      'vault metadata survives state export import and copyWith without secrets',
      () async {
    final dir = await Directory.systemTemp.createTemp('vault-metadata-');
    addTearDown(() => dir.delete(recursive: true));
    final repo = LocalAppStateRepository(
        secretStore: RecordingProfileSecretStore({}),
        applicationSupportDirectoryProvider: () async => dir);
    final profile =
        encryptionProfile.copyWith(clientEncryptionRules: [rule('a/')]);
    expect(EndpointProfile.fromJson(profile.toJson()), profile);
    expect(profile.copyWith(name: 'Name').clientEncryptionRules,
        profile.clientEncryptionRules);
    expect(profile.copyWith(clientEncryptionRules: []).clientEncryptionRules,
        isEmpty);
    await repo.saveState(
        settings: AppSettings.fromJson({}),
        profiles: [profile],
        selectedProfileId: profile.id);
    expect((await repo.loadState())!.profiles.single.clientEncryptionRules,
        profile.clientEncryptionRules);
    final export = await repo
        .exportProfiles(profiles: [profile], path: '${dir.path}/profiles.json');
    expect(
        (await repo.importProfiles(export.path)).single.clientEncryptionRules,
        profile.clientEncryptionRules);
    final text = await export.readAsString();
    expect(text, contains(identity.recipient));
    expect(text, isNot(contains(identity.secretKey)));
    expect(((jsonDecode(text) as Map)['profiles'] as List).single['secretKey'],
        anyOf(isNull, isEmpty));
  });

  test('ciphertext sizing enforces part boundaries and object ceiling', () {
    const header = 200;
    const mib = MultipartSizing.bytesPerMiB;
    for (final plaintext in [
      0,
      1,
      65535,
      65536,
      65537,
      1024 * mib,
      128 * mib * 10000,
      MultipartSizing.maximumObjectBytes - 14 * 1024 * mib
    ]) {
      final ciphertext =
          ageCiphertextLength(headerLength: header, plaintextLength: plaintext);
      final part = clientUploadPartSizeMiB(
          headerLength: header,
          plaintextLength: plaintext,
          automatic: true,
          manualMiB: 1);
      expect(part, inInclusiveRange(5, 5120));
      expect(
          MultipartSizing.partCount(
              fileSizeBytes: ciphertext, partSizeMiB: part),
          lessThanOrEqualTo(10000));
    }
    expect(
        clientUploadPartSizeMiB(
            headerLength: header,
            plaintextLength: 1,
            automatic: false,
            manualMiB: 1),
        5);
    expect(
        clientUploadPartSizeMiB(
            headerLength: header,
            plaintextLength: 1,
            automatic: false,
            manualMiB: 6000),
        5120);
    expect(
        () => clientUploadPartSizeMiB(
            headerLength: header,
            plaintextLength: 5 * mib * 10000,
            automatic: false,
            manualMiB: 5),
        throwsArgumentError);
    expect(
        () => clientUploadPartSizeMiB(
            headerLength: header,
            plaintextLength: MultipartSizing.maximumObjectBytes,
            automatic: true,
            manualMiB: 8),
        throwsArgumentError);
  });

  test(
      'the ciphertext object ceiling applies at the last admissible plaintext byte',
      () {
    var low = 0, high = MultipartSizing.maximumObjectBytes;
    while (low < high) {
      final mid = (low + high + 1) ~/ 2;
      if (ageCiphertextLength(headerLength: 200, plaintextLength: mid) <=
          MultipartSizing.maximumObjectBytes) {
        low = mid;
      } else {
        high = mid - 1;
      }
    }
    expect(
        clientUploadPartSizeMiB(
            headerLength: 200,
            plaintextLength: low,
            automatic: true,
            manualMiB: 8),
        5120);
    expect(
        () => clientUploadPartSizeMiB(
            headerLength: 200,
            plaintextLength: low + 1,
            automatic: true,
            manualMiB: 8),
        throwsArgumentError);
  });

  for (final length in [0, 1, 65535, 65536, 65537, 2 * 65536 + 1]) {
    for (final limit in [17, 65536, 65537, 200000]) {
      test('ranged text preview authenticates $length bytes with limit $limit',
          () async {
        final plaintext =
            Uint8List.fromList(List.generate(length, (i) => i % 251));
        final fixture = await clientFixture(plaintext, identity);
        final requests = <(int, int)>[];
        final reader = ClientObjectReader((url, start, end, size, etag) async {
          requests.add((start, end));
          return Uint8List.sublistView(fixture.bytes, start, end);
        });
        final header = await reader
            .open('fixture', fixture.bytes.length, null, [identity]);
        addTearDown(header.dispose);
        expect(header.plaintextLength, length);
        expect(
            await reader.preview(
                'fixture', fixture.bytes.length, null, header, limit),
            plaintext.take(limit).toList());
        final range = ageCiphertextRangeForPlaintext(
            headerLength: header.headerLength,
            plaintextLength: length,
            start: 0,
            endExclusive: length < limit ? length : limit);
        expect(requests.last, (range.start, range.endExclusive));
        expect(header.downloadParameters, {
          'format': 'age-v1',
          'headerLength': fixture.headerLength,
          'fileKey': base64Encode(fixture.fileKey)
        });
      });
    }
  }

  test('reader extends incomplete header up to the 64 KiB cap', () async {
    final fixture = await clientFixture(Uint8List(1), identity, recipients: 90);
    expect(fixture.headerLength, greaterThan(8192));
    final requested = <int>[];
    final reader = ClientObjectReader((_, start, end, size, etag) async {
      requested.add(end);
      return Uint8List.sublistView(fixture.bytes, start, end);
    });
    final header =
        await reader.open('fixture', fixture.bytes.length, null, [identity]);
    header.dispose();
    expect(requested.first, 8192);
    expect(requested.last, lessThanOrEqualTo(65536));
    expect(requested.length, greaterThan(1));
  });

  test('tampered chunk never releases a partial preview', () async {
    final fixture = await clientFixture(Uint8List(65537), identity);
    fixture.bytes[fixture.bytes.length - 1] ^= 1;
    final reader = ClientObjectReader((_, start, end, size, etag) async =>
        Uint8List.sublistView(fixture.bytes, start, end));
    final header =
        await reader.open('fixture', fixture.bytes.length, null, [identity]);
    addTearDown(header.dispose);
    await expectLater(
        reader.preview('fixture', fixture.bytes.length, null, header, 65537),
        throwsA(isA<AgeAuthenticationException>()));
  });

  test('file keys are redacted in nested traces and diagnostic text', () {
    const secret = 'U2VjcmV0ZmlsZWtleTEyMw==';
    final value = {
      'clientEncryption': {
        'format': 'age-v1',
        'fileKey': secret,
        'fileName': 'PRIVATE visible name.txt'
      }
    };
    expect(jsonEncode(DiagnosticSafety.trace(value)), isNot(contains(secret)));
    expect(
        jsonEncode(DiagnosticSafety.sanitize(value)), isNot(contains(secret)));
    expect(DiagnosticSafety.text(jsonEncode(value)), isNot(contains(secret)));
    expect(DiagnosticSafety.text('fileKey=$secret'), isNot(contains(secret)));
    for (final retained in [
      jsonEncode(DiagnosticSafety.trace(value)),
      jsonEncode(DiagnosticSafety.sanitize(value)),
      DiagnosticSafety.text(jsonEncode(value)),
      DiagnosticSafety.text('fileName=PRIVATE visible name.txt')
    ]) {
      expect(retained, isNot(contains('PRIVATE')));
    }
    for (final name in [
      'PRIVATE "quoted" name.txt',
      'PRIVATE\nsecond line.txt'
    ]) {
      final encoded = jsonEncode({
        'clientEncryption': {'fileName': name}
      });
      expect(DiagnosticSafety.text(encoded), isNot(contains('PRIVATE')));
      expect(DiagnosticSafety.text(encoded), isNot(contains('second line')));
      expect(DiagnosticSafety.text('fileName=$name'),
          isNot(contains('second line')));
    }
  });
}
