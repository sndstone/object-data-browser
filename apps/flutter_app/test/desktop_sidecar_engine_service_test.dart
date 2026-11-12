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

  test('does not silently substitute mock bucket data', () async {
    await expectLater(
      service.listBuckets(engineId: 'python', profile: profile),
      throwsA(
        isA<EngineException>()
            .having((error) => error.code, 'code', ErrorCode.engineUnavailable),
      ),
    );
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
