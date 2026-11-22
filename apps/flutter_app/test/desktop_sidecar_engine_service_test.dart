import 'google_cloud_storage_fixture.dart' show googleProfile;
import 'dart:io';
import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:s3_browser_crossplat/models/domain_models.dart';
import 'package:s3_browser_crossplat/services/desktop_sidecar_engine_service.dart';
import 'package:s3_browser_crossplat/services/desktop_engine_host.dart';
import 'package:s3_browser_crossplat/services/listing_cancellation.dart';
import 'package:s3_browser_crossplat/services/mock_engine_service.dart';

void main() {
  late Directory emptyEngineRoot;
  late DesktopSidecarEngineService service;

  setUp(() async {
    emptyEngineRoot =
        await Directory.systemTemp.createTemp('empty_engine_root_test');
    service = DesktopSidecarEngineService(engineRoot: emptyEngineRoot.path);
  });

  tearDown(() async {
    service.shutdown();
    await emptyEngineRoot.delete(recursive: true);
  });

  test('reports engines unavailable when sidecars are not installed', () async {
    final engines = await service.listEngines();
    expect(engines, isNotEmpty);
    expect(engines, everyElement(hasUnavailableStatus));
  });

  test('discovers and routes versioned raw S3 protection on desktop', () async {
    await File('${emptyEngineRoot.path}/manifest.json')
        .writeAsString(jsonEncode({
      'engines': [
        {'id': 'rust', 'executable': 'sdk-fixture'},
        {'id': 'rust-raw', 'executable': 'fixture'}
      ]
    }));
    final host = ProfilePayloadHost();
    service.shutdown();
    service = DesktopSidecarEngineService(
        host: host, engineRoot: emptyEngineRoot.path);
    final engines = await service.listEngines();
    final sdk = engines.singleWhere((e) => e.id == 'rust');
    final raw = engines.singleWhere((e) => e.id == 'rust-raw');
    expect(sdk.label, 'Rust AWS SDK Engine');
    expect(sdk.available, isTrue);
    expect(raw.label, 'Rust Raw HTTP Engine');
    expect(raw.available, isTrue);
    expect(raw.desktopSupported, isTrue);
    expect(raw.mobileSupported, isFalse);
    expect(raw.endpointTypes, ['s3Compatible', 'awsS3']);

    await service.nativeProviderAction(
      engineId: raw.id,
      profile: profile,
      action: 'getObjectProtection',
      arguments: {'bucketName': 'bucket', 'key': '+%雪', 'versionId': 'null'},
    );
    expect(host.profiles.single['endpointType'], 's3Compatible');
  });

  test('does not silently substitute mock bucket data', () async {
    await expectLater(
      service.listBuckets(engineId: 'python', profile: profile),
      throwsA(
        isA<EngineException>()
            .having((error) => error.code, 'code', ErrorCode.engineUnavailable),
      ),
    );
  });

  test('S3 AWS and Azure retain their exact sidecar profile payloads',
      () async {
    await File('${emptyEngineRoot.path}/manifest.json')
        .writeAsString(jsonEncode({
      'engines': [
        {'id': 'python', 'executable': 'fixture'}
      ]
    }));
    final host = ProfilePayloadHost();
    service.shutdown();
    service = DesktopSidecarEngineService(
        host: host, engineRoot: emptyEngineRoot.path);
    for (final type in [
      EndpointProfileType.s3Compatible,
      EndpointProfileType.awsS3,
      EndpointProfileType.azureBlob
    ]) {
      final value = profile.copyWith(endpointType: type);
      await service.listBuckets(engineId: 'python', profile: value);
      expect(host.profiles.last, {
        'id': 'test',
        'name': 'Test',
        'endpointUrl': 'http://localhost:9000',
        'region': 'us-east-1',
        'endpointType': type.name,
        'accessKey': 'access',
        'secretKey': 'secret',
        'sessionToken': null,
        'pathStyle': true,
        'verifyTls': false,
        'signerOverride': null,
        'connectTimeoutSeconds': 5,
        'readTimeoutSeconds': 60,
        'maxConcurrentRequests': 10,
        'maxAttempts': 5,
        'maxRequestsPerSecond': 0,
        'authMode': 'static',
        'awsProfileName': '',
        'roleArn': '',
        'externalId': '',
        'roleSessionName': 'object-browser',
        'knownBucket': '',
        'requesterPays': false,
        'expectedBucketOwner': '',
        'caBundlePath': '',
        'storageClasses': <String>[],
        'diagnostics': {'enableApiLogging': false, 'enableDebugLogging': false},
      });
    }
    final sas = profile.copyWith(
        endpointType: EndpointProfileType.azureBlob,
        sessionToken: 'sas',
        connection: const ConnectionOptions(authMode: 'azureSas'));
    await service.listBuckets(engineId: 'python', profile: sas);
    expect(host.profiles.last['azureSasToken'], 'sas');
    expect(host.profiles.last['sessionToken'], 'sas');
  });

  test('native copy workflows use the selected engine core methods', () async {
    await File('${emptyEngineRoot.path}/manifest.json')
        .writeAsString(jsonEncode({
      'engines': [
        {'id': 'go', 'executable': 'fixture'}
      ]
    }));
    final host = ProfilePayloadHost();
    service.shutdown();
    service = DesktopSidecarEngineService(
        host: host, engineRoot: emptyEngineRoot.path);
    final actions = <String, Map<String, Object?>>{
      'listObjects': {'bucketName': 'source', 'prefix': '', 'flat': true},
      'ensureBucket': {'bucketName': 'target', 'versioningEnabled': true},
      'copyObject': {
        'sourceBucketName': 'source',
        'sourceKey': 'file',
        'destinationBucketName': 'target',
        'destinationKey': 'file',
        'conflictPolicy': 'fail'
      },
    };
    for (final action in actions.entries) {
      await service.nativeProviderAction(
          engineId: 'go',
          profile: googleProfile(),
          action: action.key,
          arguments: action.value);
    }
    await service.nativeProviderAction(
        engineId: 'go',
        profile: googleProfile(),
        action: 'copyObject',
        arguments: {...actions['copyObject']!, 'move': true});
    expect(host.parameters[1]['enableVersioning'], isTrue);
    expect(host.parameters.last['conflictPolicy'], 'fail');
    expect(host.parameters.last['sourceKey'], 'file');
    expect(host.methods,
        ['listObjects', 'createBucket', 'copyObject', 'moveObject']);
    expect(
        host.profiles.every((p) => p['endpointType'] == 'googleCloudStorage'),
        isTrue);
    expect(host.profiles.last['secretKey'], googleProfile().secretKey);
  });

  test('provider template metadata never changes the sidecar engine payload',
      () async {
    await File('${emptyEngineRoot.path}/manifest.json').writeAsString(
      jsonEncode({
        'engines': [
          {'id': 'python', 'executable': 'fixture'},
        ],
      }),
    );
    final host = ProfilePayloadHost();
    service.shutdown();
    service = DesktopSidecarEngineService(
      host: host,
      engineRoot: emptyEngineRoot.path,
    );
    await service.listBuckets(engineId: 'python', profile: profile);
    await service.listBuckets(
      engineId: 'python',
      profile: profile.copyWith(
          providerTemplateId: 'minio', useCustomAwsEndpoint: true),
    );
    expect(host.profiles, hasLength(2));
    expect(host.profiles.last, host.profiles.first);
    expect(host.profiles.last, isNot(contains('providerTemplateId')));
    expect(host.profiles.last, isNot(contains('useCustomAwsEndpoint')));
    expect(host.profiles.last['endpointUrl'], profile.endpointUrl);
    expect(host.profiles.last['accessKey'], profile.accessKey);
  });
  test('cancel during manifest lookup prevents later dispatch or fallback',
      () async {
    final host = BlockedListingHost();
    final fallback = CountingBucketFallback();
    service.shutdown();
    service = DesktopSidecarEngineService(
        host: host, fallback: fallback, engineRoot: emptyEngineRoot.path);
    final request = service.listBuckets(engineId: 'python', profile: profile);
    final cancelled = expectLater(request, throwsA(isA<ListingCancelled>()));
    service.cancelListings();
    await cancelled.timeout(const Duration(seconds: 1));
    // Drain manifest resolution before checking that nothing was dispatched.
    await service.listEngines();
    expect(host.started.isCompleted, false);
    expect(fallback.calls, 0);
  });

  test('active cancellation stays typed and never falls back to mock data',
      () async {
    await File('${emptyEngineRoot.path}/manifest.json')
        .writeAsString(jsonEncode({
      'engines': [
        {'id': 'python', 'executable': 'fixture'}
      ]
    }));
    final host = BlockedListingHost();
    final fallback = CountingBucketFallback();
    service.shutdown();
    service = DesktopSidecarEngineService(
        host: host, fallback: fallback, engineRoot: emptyEngineRoot.path);
    final request = service.listBuckets(engineId: 'python', profile: profile);
    final cancelled = expectLater(request, throwsA(isA<ListingCancelled>()));
    await host.started.future.timeout(const Duration(seconds: 1));
    service.cancelListings();
    await cancelled.timeout(const Duration(seconds: 1));
    expect(host.cancelCalls, 1);
    expect(fallback.calls, 0);
  });

  test('lost history responses invalidate mappings before explicit resume',
      () async {
    await File('${emptyEngineRoot.path}/manifest.json')
        .writeAsString(jsonEncode({
      'engines': [
        {'id': 'python', 'executable': 'fixture'}
      ]
    }));
    final host = ResourceRegressionHost();
    service.shutdown();
    service = DesktopSidecarEngineService(
        host: host, engineRoot: emptyEngineRoot.path);
    Future<Map<String, Object?>> resume() => service.storageAction(
        profile: profile,
        destinationProfile: profile,
        action: 'resumeHistoryCopy',
        arguments: {'recoveryId': 'history-run'});
    await expectLater(resume(), throwsA(isA<TimeoutException>()));
    final state = await resume();
    expect(host.inspections, 2);
    expect(host.completed, 50);
    expect((state['mappings'] as List).length, 50);
  });
  test('failed transfer requests release buffers but retain UI snapshots',
      () async {
    await File('${emptyEngineRoot.path}/manifest.json')
        .writeAsString(jsonEncode({
      'engines': [
        {'id': 'python', 'executable': 'fixture'}
      ]
    }));
    final host = ResourceRegressionHost()..failTransfer = true;
    service.shutdown();
    service = DesktopSidecarEngineService(
        host: host, engineRoot: emptyEngineRoot.path);
    TransferJob? snapshot;
    service.setTransferSink((job) => snapshot = job);
    await expectLater(
        service.storageAction(profile: profile, action: 'copyObject'),
        throwsA(isA<TimeoutException>()));
    expect(service.retainedTransferLogCount, 0);
    expect(snapshot!.outputLines, ['started']);
  });
}

const profile = EndpointProfile(
  id: 'test',
  name: 'Test',
  endpointUrl: 'http://localhost:9000',
  region: 'us-east-1',
  accessKey: 'access',
  secretKey: 'secret',
  pathStyle: true,
  verifyTls: false,
);

Matcher get hasUnavailableStatus => isA<EngineDescriptor>()
    .having((engine) => engine.available, 'available', false);

class CountingBucketFallback extends MockEngineService {
  int calls = 0;
  @override
  Future<List<BucketSummary>> listBuckets(
      {required String engineId, required EndpointProfile profile}) async {
    calls++;
    return [];
  }
}

class ProfilePayloadHost extends DesktopEngineHost {
  final methods = <String>[];
  final parameters = <Map<String, Object?>>[];
  final profiles = <Map<String, Object?>>[];
  @override
  Future<DesktopEngineHostResponse> send({
    required String executablePath,
    List<String> arguments = const [],
    String? workingDirectory,
    required Map<String, Object?> request,
    void Function(Map<String, Object?>)? onEvent,
    bool concurrentControls = false,
    Duration? timeout,
    ListingCancellation? listingCancellation,
  }) async {
    methods.add(request['method'] as String);
    parameters.add(Map<String, Object?>.from(request['params'] as Map));
    profiles.add(
      Map<String, Object?>.from((request['params'] as Map)['profile'] as Map),
    );
    return const DesktopEngineHostResponse(
      payload: {
        'ok': true,
        'result': {'items': []},
      },
      stdoutOutput: '',
      stderrOutput: '',
    );
  }
}

class BlockedListingHost extends DesktopEngineHost {
  final started = Completer<void>();
  final pending = Completer<DesktopEngineHostResponse>();
  int cancelCalls = 0;
  @override
  Future<DesktopEngineHostResponse> send(
      {required String executablePath,
      List<String> arguments = const [],
      String? workingDirectory,
      required Map<String, Object?> request,
      void Function(Map<String, Object?>)? onEvent,
      bool concurrentControls = false,
      Duration? timeout,
      ListingCancellation? listingCancellation}) {
    started.complete();
    return pending.future;
  }

  @override
  void cancelListings() {
    cancelCalls++;
    if (started.isCompleted && !pending.isCompleted) {
      pending.completeError(const ListingCancelled());
    }
  }
}

class ResourceRegressionHost extends DesktopEngineHost {
  int inspections = 0, completed = 0;
  bool failTransfer = false;
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
    final params = request['params'] as Map;
    if (failTransfer) {
      onEvent?.call({
        'event': 'transferProgress',
        'job': {
          'id': 'failed-job',
          'status': 'running',
          'outputStartLine': 0,
          'outputLineCount': 1,
          'outputLines': ['started']
        }
      });
      throw TimeoutException('lost response');
    }
    Map<String, Object?> result;
    if (params['action'] == 'inspectHistoryCopy') {
      inspections++;
      result = {
        'id': 'history-run',
        'status': 'running',
        'mappings': List.generate(completed, (i) => {'sequence': i})
      };
    } else {
      final start = completed;
      completed += 25;
      if (start == 0) throw TimeoutException('committed batch response lost');
      result = {
        'id': 'history-run',
        'status': 'running',
        'mappingStart': start,
        'mappingCount': completed,
        'mappings': List.generate(25, (i) => {'sequence': start + i})
      };
    }
    return DesktopEngineHostResponse(
        payload: {'ok': true, 'result': result},
        stdoutOutput: '',
        stderrOutput: '');
  }
}
