import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:s3_browser_crossplat/models/domain_models.dart';
import 'package:s3_browser_crossplat/services/desktop_engine_host.dart';
import 'package:s3_browser_crossplat/services/desktop_sidecar_engine_service.dart';
import 'package:s3_browser_crossplat/services/listing_cancellation.dart';
import 'package:s3_browser_crossplat/services/object_encryption.dart';
import 'object_encryption_test.dart' show encryptionProfile;

class EncryptionHost extends DesktopEngineHost {
  final requests = <Map<String, Object?>>[];
  @override
  Future<DesktopEngineHostResponse> send(
      {required String executablePath,
      List<String> arguments = const [],
      String? workingDirectory,
      required Map<String, Object?> request,
      void Function(Map<String, Object?>)? onEvent,
      bool concurrentControls = false,
      Duration? timeout,
      ListingCancellation? listingCancellation}) async {
    requests.add(request);
    return const DesktopEngineHostResponse(
        payload: {'ok': true, 'result': {}},
        stdoutOutput: '',
        stderrOutput: '');
  }
}

void main() {
  late Directory root;
  late EncryptionHost host;
  late DesktopSidecarEngineService engine;
  setUp(() async {
    root = await Directory.systemTemp.createTemp('encryption-sidecar-');
    await File('${root.path}/manifest.json').writeAsString(jsonEncode({
      'engines': [
        {'id': 'python', 'executable': 'fixture'}
      ]
    }));
    host = EncryptionHost();
    engine = DesktopSidecarEngineService(host: host, engineRoot: root.path);
  });
  tearDown(() async {
    engine.shutdown();
    await root.delete(recursive: true);
  });

  Future<void> folder([ObjectEncryption? encryption]) => engine.createFolder(
      engineId: 'python',
      profile: encryptionProfile,
      bucketName: 'bucket',
      key: 'folder/',
      encryption: encryption);

  test('desktop omits optional encryption and keeps profile payload unchanged',
      () async {
    await folder();
    final plain =
        Map<String, Object?>.from(host.requests.last['params'] as Map);
    expect(plain.containsKey('encryption'), isFalse);
    await folder(const ObjectEncryption(
        mode: ObjectEncryptionMode.sseKms,
        kmsKeyId: 'kms-id',
        bucketKeyEnabled: false));
    final encrypted = host.requests.last['params'] as Map;
    expect(encrypted['profile'], plain['profile']);
    expect(
        (encrypted['profile'] as Map).containsKey('uploadEncryption'), isFalse);
    expect(encrypted['encryption'],
        {'mode': 'sse-kms', 'kmsKeyId': 'kms-id', 'bucketKeyEnabled': false});
  });

  test(
      'desktop resolves customer key only at dispatch and omits local identifiers',
      () async {
    engine.customerKeyResolver = (id) {
      expect(id, 'key-id');
      return Uint8List.fromList(List.filled(32, 7));
    };
    await folder(const ObjectEncryption(
        mode: ObjectEncryptionMode.sseC, customerKeyId: 'key-id'));
    final encryption = (host.requests.single['params'] as Map)['encryption'];
    expect(encryption,
        {'mode': 'sse-c', 'customerKey': base64Encode(List.filled(32, 7))});
  });

  test('unresolvable customer key sends no sidecar request', () async {
    engine.customerKeyResolver = (_) => throw StateError('locked');
    await expectLater(
        folder(const ObjectEncryption(
            mode: ObjectEncryptionMode.sseC, customerKeyId: 'missing')),
        throwsA(isA<EncryptionDispatchException>()));
    expect(host.requests, isEmpty);
  });

  test('copy carries distinct source and destination encryption', () async {
    engine.customerKeyResolver = (_) => Uint8List(32);
    await engine.copyObject(
        engineId: 'python',
        profile: encryptionProfile,
        sourceBucketName: 'bucket',
        sourceKey: 'source',
        destinationBucketName: 'bucket',
        destinationKey: 'target',
        encryption: const ObjectEncryption(mode: ObjectEncryptionMode.sseS3),
        sourceEncryption: const ObjectEncryption(
            mode: ObjectEncryptionMode.sseC, customerKeyId: 'key'));
    final params = host.requests.single['params'] as Map;
    expect(params['encryption'], {'mode': 'sse-s3'});
    expect(params['sourceEncryption'],
        {'mode': 'sse-c', 'customerKey': base64Encode(Uint8List(32))});
  });
}
