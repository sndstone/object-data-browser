import 'dart:convert';
import 'dart:io';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:s3_browser_crossplat/models/domain_models.dart';
import 'package:s3_browser_crossplat/services/android_engine_service.dart';
import 'package:s3_browser_crossplat/services/engine_service.dart';

import 'mobile_client_encryption_fixture.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('s3_browser_crossplat/android_engine');

  EndpointProfile profile() => const EndpointProfile(
        id: 'profile-1',
        name: 'Test profile',
        endpointUrl: 'http://127.0.0.1:9000',
        region: 'us-east-1',
        accessKey: 'access-key',
        secretKey: 'secret-key',
        pathStyle: true,
        verifyTls: true,
      );

  tearDown(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  test('provider template metadata never changes the native engine payload',
      () async {
    final payloads = <Map<String, Object?>>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'dispatch') {
        final arguments = Map<String, Object?>.from(
          call.arguments as Map,
        );
        final params = Map<String, Object?>.from(
          arguments['params'] as Map,
        );
        payloads.add(Map<String, Object?>.from(params['profile'] as Map));
        return {'items': <Map<String, Object?>>[]};
      }
      return null;
    });
    final service = AndroidEngineService(channel: channel);
    addTearDown(service.shutdown);
    await service.listBuckets(engineId: 'android', profile: profile());
    await service.listBuckets(
      engineId: 'android',
      profile: profile()
          .copyWith(providerTemplateId: 'minio', useCustomAwsEndpoint: true),
    );
    expect(payloads, hasLength(2));
    expect(payloads.first, profile().toJson());
    expect(payloads.last, payloads.first);
    expect(payloads.last, isNot(contains('providerTemplateId')));
    expect(payloads.last, isNot(contains('useCustomAwsEndpoint')));
  });

  test('listBuckets returns platform data instead of placeholder fallback',
      () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'dispatch') {
        final args = Map<String, Object?>.from(call.arguments as Map);
        expect(args['method'], 'listBuckets');
        return {
          'items': [
            {
              'name': 'real-bucket',
              'region': 'us-east-1',
              'objectCountHint': 12,
              'versioningEnabled': true,
              'createdAt': '2026-03-22T20:15:00Z',
            },
          ],
        };
      }
      return null;
    });

    final service = AndroidEngineService(channel: channel);
    final buckets =
        await service.listBuckets(engineId: 'go', profile: profile());

    expect(buckets, hasLength(1));
    expect(buckets.single.name, 'real-bucket');
    expect(buckets.single.objectCountHint, 12);
    expect(buckets.single.versioningEnabled, isTrue);
  });

  test('listBuckets accepts Android object-keyed platform maps', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'dispatch') {
        return <Object?, Object?>{
          'items': <Object?>[
            <Object?, Object?>{
              'name': 'typed-map-bucket',
              'region': 'eu-central-1',
              'objectCountHint': 3,
              'versioningEnabled': false,
              'createdAt': '2026-05-16T10:30:00Z',
            },
          ],
        };
      }
      return null;
    });

    final service = AndroidEngineService(channel: channel);
    final buckets =
        await service.listBuckets(engineId: 'android', profile: profile());

    expect(buckets, hasLength(1));
    expect(buckets.single.name, 'typed-map-bucket');
    expect(buckets.single.region, 'eu-central-1');
    expect(buckets.single.objectCountHint, 3);
  });

  test('emits structured Android API traces when diagnostics are enabled',
      () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'dispatch') {
        return {'items': <Map<String, Object?>>[]};
      }
      return null;
    });

    final service = AndroidEngineService(channel: channel);
    final records = <EngineLogRecord>[];
    service.setLogSink(records.add);
    service.configureDiagnostics(
      const DiagnosticsOptions(
        enableApiLogging: true,
        enableDebugLogging: false,
      ),
    );

    await service.listBuckets(
      engineId: 'rust',
      profile: profile(),
    );

    expect(
      records.map((record) => record.category).toList(),
      ['HttpSend', 'HttpReceive'],
    );
    expect(records.first.tracePhase, 'send');
    expect(records.last.tracePhase, 'response');
    expect(records.first.requestId, isNotEmpty);
    expect(records.first.requestId, records.last.requestId);
    expect(records.first.engineId, 'rust');
    expect(records.last.method, 'listBuckets');
  });

  test(
      'name-encrypted uploads sanitize mobile request response and error diagnostics',
      () async {
    // The widget test binding replaces HttpClient with a stub that answers
    // 400; this test talks to a local fixture.
    HttpOverrides.global = null;
    final fixture = MobileAgeFixture(false);
    await fixture.start();
    addTearDown(fixture.close);
    final service = AndroidEngineService(channel: channel);
    addTearDown(service.shutdown);
    final records = <EngineLogRecord>[];
    service.setLogSink(records.add);
    service.configureDiagnostics(const DiagnosticsOptions(
        enableApiLogging: true, enableDebugLogging: true));
    final vector = mobileAgeVectors().first;
    final source = File('${fixture.directory.path}/PRIVATE-mobile-report.txt');
    await source.writeAsBytes(vectorPlaintext(vector));
    final token =
        base64Url.encode([1, ...List.filled(17, 7)]).replaceAll('=', '');
    Future<TransferJob> upload({bool names = true}) => service.startUpload(
        engineId: 'android',
        profile: fixture.profile,
        bucketName: 'bucket',
        prefix: 'vault/',
        filePaths: [source.path],
        objectKeyByPath: {source.path: names ? '$token.age' : 'plain.age'},
        multipartThresholdMiB: 32,
        multipartChunkMiB: 5,
        clientEncryption: names
            ? {
                'format': 'age-v1',
                'header': vector['header'],
                'fileKey': vector['fileKey'],
                'payloadNonce': vector['payloadNonce']
              }
            : null);
    await upload();
    expect(fixture.objects['vault/$token.age'], isNotNull);
    expect(records.any((r) => r.tracePhase == 'response'), isTrue);
    final request =
        records.firstWhere((r) => r.tracePhase == 'send').traceBody as Map;
    expect(request['filePaths'], ['$token.age']);
    expect((request['objectKeyByPath'] as Map).keys, ['$token.age']);
    await source.delete();
    Object? failure;
    try {
      await upload();
    } catch (error) {
      failure = error;
    }
    expect(failure, isA<EngineException>());
    final retained = jsonEncode({
      'error': '$failure',
      'logs': records.map((r) => [r.message, r.traceHead, r.traceBody]).toList()
    });
    expect(retained, isNot(contains(source.path)));
    expect(retained, isNot(contains('PRIVATE-mobile-report.txt')));
    expect(retained, isNot(contains(vector['fileKey'])));
    // Ordinary uploads retain their original path and request shape.
    records.clear();
    await source.writeAsBytes([1, 2, 3]);
    await upload(names: false);
    final ordinary =
        records.firstWhere((r) => r.tracePhase == 'send').traceBody as Map;
    expect(ordinary['filePaths'], [source.path]);
    expect((ordinary['objectKeyByPath'] as Map)[source.path], 'plain.age');
    expect(ordinary.containsKey('clientEncryption'), isFalse);
  });

  test('native unsupported errors surface instead of mock data', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'dispatch') {
        return {
          'error': {
            'code': 'unsupported_feature',
            'message': 'Not implemented on Android.',
          },
        };
      }
      return null;
    });

    final service = AndroidEngineService(channel: channel);

    await expectLater(
      () => service.listBuckets(engineId: 'go', profile: profile()),
      throwsA(
        isA<EngineException>()
            .having((error) => error.code, 'code', ErrorCode.unsupportedFeature)
            .having((error) => error.message, 'message',
                'Not implemented on Android.'),
      ),
    );
  });
}
