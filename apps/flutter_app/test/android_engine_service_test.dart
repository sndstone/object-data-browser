import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:s3_browser_crossplat/models/domain_models.dart';
import 'package:s3_browser_crossplat/services/android_engine_service.dart';
import 'package:s3_browser_crossplat/services/engine_service.dart';

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
        return {
          'key': 'docs/readme.txt',
          'metadata': {'owner': 'qa'},
          'headers': {'Content-Length': '32'},
          'tags': {'env': 'test'},
          'debugEvents': const [],
          'apiCalls': const [],
          'debugLogExcerpt': const ['bridge ok'],
          'rawDiagnostics': const {'engineState': 'healthy'},
        };
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

    await service.getObjectDetails(
      engineId: 'rust',
      profile: profile(),
      bucketName: 'docs',
      key: 'docs/readme.txt',
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
    expect(records.last.method, 'getObjectDetails');
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
