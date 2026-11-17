import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:s3_browser_crossplat/services/client_encryption.dart';
import 'package:s3_browser_crossplat/models/domain_models.dart';
import 'package:s3_browser_crossplat/services/crypto/age.dart';
import 'package:s3_browser_crossplat/services/crypto/vault_names.dart';
import 'package:s3_browser_crossplat/services/diagnostic_safety.dart';
import 'package:s3_browser_crossplat/services/desktop_sidecar_engine_service.dart';
import 'package:s3_browser_crossplat/services/engine_service.dart';
import 'desktop_object_encryption_test.dart' show EncryptionHost;
import 'object_encryption_test.dart' show encryptionProfile;

void main() {
  test(
      'desktop dispatch carries client encryption only when set and never logs file keys',
      () async {
    final dir = await Directory.systemTemp.createTemp('desktop-vault-');
    final host = EncryptionHost();
    final service =
        DesktopSidecarEngineService(host: host, engineRoot: dir.path);
    addTearDown(() async {
      service.shutdown();
      await dir.delete(recursive: true);
    });
    await File('${dir.path}/manifest.json').writeAsString(jsonEncode({
      'engines': [
        {'id': 'python', 'executable': 'fixture'}
      ]
    }));
    final events = <EngineLogRecord>[];
    service.setLogSink(events.add);
    service.configureDiagnostics(const DiagnosticsOptions(
        enableApiLogging: true, enableDebugLogging: true));
    Future<void> upload({Map<String, Object?>? client}) => service.startUpload(
        engineId: 'python',
        profile: encryptionProfile,
        bucketName: 'bucket',
        prefix: '',
        filePaths: ['/fixture'],
        objectKeyByPath: const {},
        multipartThresholdMiB: 8,
        multipartChunkMiB: 8,
        clientEncryption: client);
    await upload();
    final plain = host.requests.last['params'] as Map;
    expect(plain.containsKey('clientEncryption'), isFalse);
    final identity = await AgeIdentity.generate();
    final rule = ClientEncryptionRule(
        bucket: 'bucket',
        keyId: 'vault',
        recipient: identity.recipient,
        label: 'Vault');
    await withClientUpload(rule, (payload, headerLength) async {
      await upload(client: payload);
      final encrypted = host.requests.last['params'] as Map;
      expect(encrypted['profile'], plain['profile']);
      expect((encrypted['profile'] as Map).containsKey('clientEncryptionRules'),
          isFalse);
      expect(encrypted['clientEncryption'], payload);
      final fileKey = payload['fileKey'] as String;
      expect(
          jsonEncode(events
              .map((e) => [e.message, e.traceHead, e.traceBody])
              .toList()),
          isNot(contains(fileKey)));
      await service.startDownload(
          engineId: 'python',
          profile: encryptionProfile,
          bucketName: 'bucket',
          keys: ['fixture.age'],
          destinationPath: dir.path,
          multipartThresholdMiB: 8,
          multipartChunkMiB: 8,
          clientEncryption: {
            'format': 'age-v1',
            'headerLength': headerLength,
            'fileKey': fileKey,
            'fileName': 'PRIVATE visible name.txt'
          });
      expect((host.requests.last['params'] as Map)['clientEncryption'], {
        'format': 'age-v1',
        'headerLength': headerLength,
        'fileKey': fileKey,
        'fileName': 'PRIVATE visible name.txt'
      });
      expect(
          jsonEncode(events
              .map((e) => [e.message, e.traceHead, e.traceBody])
              .toList()),
          isNot(contains(fileKey)));
      expect(
          jsonEncode(events
              .map((e) => [e.message, e.traceHead, e.traceBody])
              .toList()),
          isNot(contains('PRIVATE visible name.txt')));
    });
    final keys = identity.deriveNameKeys();
    try {
      const path = '/local/PRIVATE-upload-visible-name.txt';
      final token =
          '${sealVaultName('PRIVATE-upload-visible-name.txt', keys)}.age';
      await service.startUpload(
          engineId: 'python',
          profile: encryptionProfile,
          bucketName: 'bucket',
          prefix: 'vault/',
          filePaths: [path],
          objectKeyByPath: {path: token},
          multipartThresholdMiB: 8,
          multipartChunkMiB: 8);
      final actual = host.requests.last['params'] as Map;
      expect(actual['filePaths'], [path]); // Real request is untouched.
      expect((actual['objectKeyByPath'] as Map)[path], token);
      expect(
          jsonEncode(events
              .map((e) => [e.message, e.traceHead, e.traceBody])
              .toList()),
          isNot(contains('PRIVATE-upload-visible-name.txt')));
      final projected = DiagnosticSafety.forNameEncryptedRequest({
        'id': 'a',
        'direction': 'upload',
        'status': 'failed',
        'label': 'Upload a'
      }, {
        'objectKeyByPath': {'/local/a': token}
      }) as Map;
      expect(projected['id'], 'a');
      expect(projected['direction'], 'upload');
      expect(projected['status'], 'failed');
      expect(projected['label'], 'Upload $token');
      // A hidden name as short as "a" must not blank machine-readable codes.
      final failed = DiagnosticSafety.forNameEncryptedRequest({
        'error': {
          'code': 'invalid_config',
          'awsCode': 'AccessDenied',
          'message': 'Cannot write a.pdf',
          'details': {'encryptionHint': 'access_denied'}
        }
      }, {
        'clientEncryption': {'fileName': 'a.pdf'}
      }) as Map;
      final error = failed['error'] as Map;
      expect(error['code'], 'invalid_config');
      expect(error['awsCode'], 'AccessDenied');
      expect((error['details'] as Map)['encryptionHint'], 'access_denied');
      expect(error['message'], isNot(contains('a.pdf')));
    } finally {
      keys.wipe();
    }
  });
}
