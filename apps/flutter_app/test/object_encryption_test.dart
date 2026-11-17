import 'dart:convert';
import 'dart:io';
import 'app_state_repository_test.dart' show RecordingProfileSecretStore;
import 'package:flutter_test/flutter_test.dart';
import 'package:s3_browser_crossplat/models/domain_models.dart';
import 'package:s3_browser_crossplat/services/app_state_repository.dart';
import 'package:s3_browser_crossplat/services/diagnostic_safety.dart';
import 'package:s3_browser_crossplat/services/object_encryption.dart';

const encryptionProfile = EndpointProfile(
    id: 'encryption-test',
    name: 'Fixture',
    endpointUrl: 'https://storage.example',
    region: 'us-east-1',
    accessKey: 'access',
    secretKey: 'secret',
    pathStyle: true,
    verifyTls: true);

void main() {
  test('old profiles omit upload encryption and keep engine metadata unchanged',
      () {
    final old = encryptionProfile.toJson();
    expect(old.containsKey('uploadEncryption'), isFalse);
    final loaded = EndpointProfile.fromJson(old);
    expect(loaded.uploadEncryption, isNull);
    expect(loaded.toJson(), old);
    expect(loaded.copyWith(name: 'Renamed').uploadEncryption, isNull);
  });

  test('all encryption modes round trip only non-secret settings', () {
    for (final mode in ObjectEncryptionMode.values) {
      final setting = ObjectEncryption(
          mode: mode,
          kmsKeyId: 'kms-id',
          kmsEncryptionContext: const {'purpose': 'test'},
          bucketKeyEnabled: false,
          encryptionScope: 'scope',
          customerKeyId: 'key-reference',
          customerKeyFingerprint: 'fingerprint');
      expect(ObjectEncryption.fromJson(setting.toJson()).toJson(),
          setting.toJson());
      final profile = encryptionProfile.copyWith(uploadEncryption: setting);
      expect(
          EndpointProfile.fromJson(profile.toJson()).uploadEncryption!.toJson(),
          setting.toJson());
      expect(jsonEncode(profile.toJson()), isNot(contains('customerKey"')));
      expect(profile.copyWith(uploadEncryption: null).uploadEncryption, isNull);
    }
  });

  test('object encryption information round trips provider fingerprints', () {
    const info = ObjectEncryptionInfo(mode: 'sse-c', customerKeyMd5: 'md5');
    expect(
        ObjectEncryptionInfo.fromJson(info.toJson()).toJson(), info.toJson());
    const azure = ObjectEncryptionInfo(
        mode: 'azure-cpk', customerKeySha256: 'sha256', serverEncrypted: true);
    expect(
        ObjectEncryptionInfo.fromJson(azure.toJson()).toJson(), azure.toJson());
  });

  test(
      'state loads legacy profiles and persists encryption metadata outside Keychain',
      () async {
    final directory =
        await Directory.systemTemp.createTemp('encryption-state-');
    addTearDown(() => directory.delete(recursive: true));
    final secrets = RecordingProfileSecretStore({});
    final repository = LocalAppStateRepository(
        secretStore: secrets,
        applicationSupportDirectoryProvider: () async => directory);
    final settings = AppSettings.fromJson({});
    await repository.saveState(
        settings: settings,
        profiles: const [encryptionProfile],
        selectedProfileId: encryptionProfile.id);
    final old = await repository.loadState();
    expect(old!.profiles.single.uploadEncryption, isNull);
    final encrypted = encryptionProfile.copyWith(
        uploadEncryption: const ObjectEncryption(
            mode: ObjectEncryptionMode.sseC,
            customerKeyId: 'key-reference',
            customerKeyFingerprint: 'hash'));
    await repository.saveState(
        settings: settings,
        profiles: [encrypted],
        selectedProfileId: encrypted.id);
    final output =
        await File('${directory.path}/object-data-browser-state.json')
            .readAsString();
    expect(output, contains('key-reference'));
    expect(output, isNot(contains('"customerKey"')));
    expect(output, isNot(contains('"secretKey"')));
    expect(jsonEncode(secrets.values), isNot(contains('key-reference')));
    final loaded = await repository.loadState();
    expect(
        loaded!.profiles.single.uploadEncryption, encrypted.uploadEncryption);
    expect(await repository.encryptionKeyFile(), isA<File>());
    expect(
        await File('${directory.path}/encryption-keys.age').exists(), isFalse);
  });

  test('metadata export retains key references and excludes secrets', () async {
    final directory =
        await Directory.systemTemp.createTemp('encryption-export-');
    addTearDown(() => directory.delete(recursive: true));
    final profile = encryptionProfile.copyWith(
        uploadEncryption: const ObjectEncryption(
            mode: ObjectEncryptionMode.sseC,
            customerKeyId: 'reference',
            customerKeyFingerprint: 'hash'));
    final file = await LocalAppStateRepository().exportProfiles(
        profiles: [profile], path: '${directory.path}/profiles.json');
    final output = await file.readAsString();
    expect(output, contains('reference'));
    expect(output, contains('uploadEncryption'));
    expect(output, isNot(contains('"customerKey"')));
    // Exports keep the credential fields but always blank their values.
    final exported = (jsonDecode(output) as Map)['profiles'] as List;
    expect((exported.single as Map)['secretKey'], anyOf(isNull, isEmpty));
    expect((exported.single as Map)['accessKey'], anyOf(isNull, isEmpty));
  });

  test('diagnostics redact customer keys in objects headers and text', () {
    const fields = [
      'customerKey',
      'CUSTOMERKEY',
      'x-amz-server-side-encryption-customer-key',
      'x-amz-copy-source-server-side-encryption-customer-key',
      'x-ms-encryption-key'
    ];
    for (final field in fields) {
      final value = {
        'nested': [
          {field: 'secret-material'}
        ]
      };
      expect(jsonEncode(DiagnosticSafety.sanitize(value)),
          isNot(contains('secret-material')));
      expect(jsonEncode(DiagnosticSafety.trace(value)),
          isNot(contains('secret-material')));
      expect(DiagnosticSafety.text('$field=secret-material'),
          isNot(contains('secret-material')));
      expect(DiagnosticSafety.text(jsonEncode({field: 'secret-material'})),
          isNot(contains('secret-material')));
    }
    expect(DiagnosticSafety.sanitize({'customerKeyId': 'reference'}),
        {'customerKeyId': 'reference'});
  });

  test(
      'mobile encryption validates mode fields key length and secure endpoints',
      () {
    final key = base64Encode(List.filled(32, 1));
    expect(
        () => objectEncryptionHeaders(
            encryptionProfile, {'mode': 'sse-c', 'customerKey': key}),
        returnsNormally);
    expect(
        () => objectEncryptionHeaders(
            encryptionProfile.copyWith(endpointUrl: 'http://example.com'),
            {'mode': 'sse-c', 'customerKey': key}),
        throwsA(isA<EngineException>()));
    for (final host in ['localhost', '127.0.0.2', '[::1]']) {
      expect(
          customerKeyEndpointAllowed(
              encryptionProfile.copyWith(endpointUrl: 'http://$host:9000')),
          isTrue);
    }
    for (final value in [
      {
        'mode': 'sse-c',
        'customerKey': base64Encode([1, 2])
      },
      {'mode': 'azure-scope', 'encryptionScope': 'scope'},
      {'mode': 'dsse-kms', 'bucketKeyEnabled': true},
      {'mode': 'sse-s3', 'kmsKeyId': 'unexpected'},
      {'mode': 'bucketDefault', 'customerKey': key},
    ]) {
      expect(() => objectEncryptionHeaders(encryptionProfile, value),
          throwsA(isA<EngineException>()));
    }
    expect(objectEncryptionHeaders(encryptionProfile, null), isEmpty);
    expect(
        objectEncryptionHeaders(encryptionProfile, {'mode': 'bucketDefault'}),
        isEmpty);
  });
}
