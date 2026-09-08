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
