import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:s3_browser_crossplat/controllers/app_controller.dart';
import 'package:s3_browser_crossplat/models/domain_models.dart';
import 'package:s3_browser_crossplat/services/mock_engine_service.dart';
import 'package:s3_browser_crossplat/widgets/banner_activity/banner_activity_indicator.dart';
import 'package:s3_browser_crossplat/widgets/banner_activity/banner_activity_spec.dart';
import 'package:s3_browser_crossplat/widgets/banner_activity/living_glyph_indicator.dart';
import 'package:s3_browser_crossplat/widgets/banner_activity/trace_tile_indicator.dart';

/// Bucket creation waits for [gate], like a slow endpoint.
class _GatedEngine extends MockEngineService {
  final gate = Completer<void>();
  @override
  Future<BucketSummary> createBucket({
    required String engineId,
    required EndpointProfile profile,
    required String bucketName,
    required bool enableVersioning,
    required bool enableObjectLock,
  }) async {
    await gate.future;
    return super.createBucket(
        engineId: engineId,
        profile: profile,
        bucketName: bucketName,
        enableVersioning: enableVersioning,
        enableObjectLock: enableObjectLock);
  }
}

const _settings = AppSettings(
  darkMode: false,
  defaultEngineId: 'rust',
  downloadPath: '/tmp/downloads',
  tempPath: '/tmp',
  transferConcurrency: 8,
  multipartThresholdMiB: 32,
  multipartChunkMiB: 8,
  dynamicMultipartSizing: true,
  enableAnimations: true,
  enableDiagnostics: true,
  enableApiLogging: false,
  enableDebugLogging: false,
  safeRetries: 3,
  benchmarkChartSmoothing: true,
  retryBaseDelayMs: 250,
  retryMaxDelayMs: 4000,
  requestDelayMs: 0,
  connectTimeoutSeconds: 5,
  readTimeoutSeconds: 60,
  maxPoolConnections: 200,
  maxRequestsPerSecond: 0,
  enableCrashRecovery: true,
  defaultPresignMinutes: 60,
  benchmarkDataCacheMb: 0,
  benchmarkDebugMode: false,
  benchmarkLogPath: '/tmp/benchmark.log',
  browserInspectorLayout: BrowserInspectorLayout.bottom,
  browserInspectorSize: 360,
  relistObjectsAfterMutation: true,
  uiScalePercent: 70,
  logTextScalePercent: 80,
);

const _profile = EndpointProfile(
  id: 'test',
  name: 'Test',
  endpointUrl: 'http://localhost:9000',
  region: 'us-east-1',
  accessKey: 'key',
  secretKey: 'secret',
  pathStyle: true,
  verifyTls: false,
);

Future<AppController> _controller(MockEngineService engine) async {
  final c = AppController(
      engineService: engine,
      initialSettings: _settings,
      initialProfiles: const [_profile]);
  await c.initialize();
  return c;
}

void main() {
  test('a quick action works in place, then shows its result', () async {
    final engine = _GatedEngine();
    final c = await _controller(engine);
    final create = c.createBucket(
        bucketName: 'new-bucket',
        enableVersioning: false,
        enableObjectLock: false);
    await Future<void>.delayed(Duration.zero);
    expect(c.bannerActivity?.kind, BannerActivityKind.action);
    expect(c.bannerActivity?.phase, BannerActivityPhase.working);
    engine.gate.complete();
    await create;

    // A profile test keeps its result message, so the glyph morphs in place.
    await c.testProfileById(_profile.id);
    expect(c.bannerMessage, contains('Connection test succeeded'));
    expect(c.bannerActivity?.kind, BannerActivityKind.action);
    expect(c.bannerActivity?.phase, BannerActivityPhase.succeeded);
  });

  test('deleting reports its object count', () async {
    final c = await _controller(MockEngineService());
    final keys = c.objects.take(2).map((o) => o.key).toList();
    expect(keys, hasLength(2));
    final delete = c.deleteObjectKeys(keys);
    expect(c.bannerActivity?.kind, BannerActivityKind.deleting);
    expect(c.bannerActivity?.count, 2);
    await delete;
    expect(c.bannerActivity?.kind,
        anyOf(BannerActivityKind.deleting, BannerActivityKind.listing));
  });

  test('plain and later messages are not mistaken for the last activity',
      () async {
    final c = await _controller(MockEngineService());
    c.showBannerMessage('Open the original connection first.',
        severity: BannerSeverity.warning);
    expect(c.bannerActivity?.kind, BannerActivityKind.message);
    expect(c.bannerActivity?.phase, BannerActivityPhase.warning);

    await c.testProfileById(_profile.id);
    expect(c.bannerActivity?.kind, BannerActivityKind.action);
    c.bannerMessage = 'Something unrelated.';
    expect(c.bannerActivity?.kind, BannerActivityKind.message);
    expect(c.bannerActivity?.phase, BannerActivityPhase.info);
    c.clearBanner();
    expect(c.bannerActivity, isNull);
  });

  Widget host(BannerActivitySpec spec) => MaterialApp(
      home: Scaffold(body: Center(child: BannerActivityIndicator(spec: spec))));

  BannerActivitySpec spec(BannerActivityKind kind, BannerActivityPhase phase,
          {bool animate = true}) =>
      BannerActivitySpec(
          kind: kind,
          phase: phase,
          progress: kind == BannerActivityKind.benchmark ? .4 : null,
          count: kind == BannerActivityKind.listing ? 3200 : null,
          animate: animate,
          foreground: Colors.white,
          background: Colors.black);

  testWidgets('benchmarks and exports use trace tiles, the rest glyphs',
      (tester) async {
    for (final kind in BannerActivityKind.values) {
      await tester.pumpWidget(host(spec(kind, BannerActivityPhase.working)));
      final tile = kind == BannerActivityKind.benchmark ||
          kind == BannerActivityKind.exporting;
      expect(find.byType(TraceTileIndicator),
          tile ? findsOneWidget : findsNothing);
      expect(find.byType(LivingGlyphIndicator),
          tile ? findsNothing : findsOneWidget);
    }
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('activity indicators settle without motion or once finished',
      (tester) async {
    for (final kind in BannerActivityKind.values) {
      await tester.pumpWidget(
          host(spec(kind, BannerActivityPhase.working, animate: false)));
      await tester.pumpAndSettle();
      for (final phase in [
        BannerActivityPhase.paused,
        BannerActivityPhase.succeeded,
        BannerActivityPhase.info,
        BannerActivityPhase.warning,
        BannerActivityPhase.failed,
        BannerActivityPhase.cancelled,
      ]) {
        await tester.pumpWidget(host(spec(kind, phase)));
        await tester.pumpAndSettle();
      }
      await tester.pumpWidget(const SizedBox.shrink());
    }
  });
}
