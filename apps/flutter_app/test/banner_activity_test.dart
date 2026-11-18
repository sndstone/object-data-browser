import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:s3_browser_crossplat/controllers/app_controller.dart';
import 'package:s3_browser_crossplat/models/domain_models.dart';
import 'package:s3_browser_crossplat/services/app_state_repository.dart';
import 'package:s3_browser_crossplat/services/bucket_copy_journal.dart';
import 'package:s3_browser_crossplat/services/mock_engine_service.dart';
import 'package:s3_browser_crossplat/widgets/banner_activity/banner_activity_indicator.dart';
import 'package:s3_browser_crossplat/widgets/banner_activity/banner_activity_spec.dart';
import 'package:s3_browser_crossplat/widgets/banner_activity/bucket_activity_indicator.dart';
import 'package:s3_browser_crossplat/widgets/banner_activity/living_glyph_indicator.dart';
import 'package:s3_browser_crossplat/widgets/banner_activity/trace_tile_indicator.dart';

import 'app_controller_test.dart' show MemoryAppStateRepository;

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

class _BucketCopyEngine extends MockEngineService {
  final copyingSecondObject = Completer<void>();
  final finish = Completer<void>();

  @override
  Future<Map<String, Object?>> storageAction({
    required EndpointProfile profile,
    required String action,
    Map<String, Object?> arguments = const {},
    EndpointProfile? destinationProfile,
  }) async {
    switch (action) {
      case 'listObjects':
        return {
          'items': [
            {'key': 'first', 'size': 1},
            {'key': 'second', 'size': 1},
          ],
          'nextCursor': {'hasMore': false},
        };
      case 'copyObject':
        if (arguments['sourceKey'] == 'second') {
          copyingSecondObject.complete();
          await finish.future;
        }
        return {'status': 'completed', 'successCount': 1, 'bytesCopied': 1};
      default:
        return super.storageAction(
          profile: profile,
          action: action,
          arguments: arguments,
          destinationProfile: destinationProfile,
        );
    }
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

Future<AppController> _controller(
  MockEngineService engine, {
  AppStateRepository? repository,
  Future<BucketCopyJournal> Function()? journal,
}) async {
  final c = AppController(
      engineService: engine,
      initialSettings: _settings,
      initialProfiles: const [_profile],
      appStateRepository: repository,
      bucketCopyJournalProvider: journal);
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

  test('approved bucket settings keep their animation through confirmation',
      () async {
    final c = await _controller(MockEngineService());
    addTearDown(c.dispose);
    for (final (save, animation, message) in [
      (
        () => c.saveBucketLifecycle('{"Rules":[]}'),
        BucketActivityAnimation.clockSet,
        'Lifecycle policy saved.',
      ),
      (
        () => c.saveBucketPolicy('{}'),
        BucketActivityAnimation.shieldScan,
        'Bucket policy saved.',
      ),
      (
        () => c.saveBucketTags({'team': 'storage'}),
        BucketActivityAnimation.hangTag,
        'Bucket tags saved.',
      ),
    ]) {
      final pending = save();
      expect(c.bannerActivity?.bucketAnimation, animation);
      expect(c.bannerActivity?.phase, BannerActivityPhase.working);
      await pending;
      expect(c.bannerActivity?.bucketAnimation, animation);
      expect(c.bannerActivity?.phase, BannerActivityPhase.succeeded);
      expect(c.bannerMessage, message);
    }
    await c.setBucketVersioning(true);
    expect(c.bannerActivity?.bucketAnimation, isNull);
  });

  test('Level Match follows actual copied objects and the final outcome',
      () async {
    final engine = _BucketCopyEngine();
    final directory = await Directory.systemTemp.createTemp('bucket-status-');
    addTearDown(() => directory.delete(recursive: true));
    final c = await _controller(engine,
        journal: () async =>
            BucketCopyJournal(File('${directory.path}/copy.json')));
    addTearDown(c.dispose);
    final copy = c.copyBucketContents(
        sourceBucketName: 'source', destinationBucketName: 'destination');
    expect(
        c.bannerActivity?.bucketAnimation, BucketActivityAnimation.levelMatch);
    expect(c.bannerActivity?.count, 0);
    await engine.copyingSecondObject.future;
    expect(c.bannerActivity?.phase, BannerActivityPhase.working);
    expect(c.bannerActivity?.count, 1);
    expect(c.bannerActivity?.progress, isNull);
    expect(c.bannerTransferStatus, isNull);
    engine.finish.complete();
    await copy;
    expect(
        c.bannerActivity?.bucketAnimation, BucketActivityAnimation.levelMatch);
    expect(c.bannerActivity?.phase, BannerActivityPhase.succeeded);
    expect(c.bannerActivity?.count, 2);
  });

  test('Bolt Throw confirms only a durably saved vault rule', () async {
    const rule = ClientEncryptionRule(
      bucket: 'bucket',
      keyId: 'key-id',
      recipient: 'age1example',
      label: 'Example vault',
    );
    for (final durable in [true, false]) {
      final c = await _controller(MockEngineService(),
          repository: durable ? MemoryAppStateRepository() : null);
      addTearDown(c.dispose);
      final save = c.saveVaultRules(
          _profile.copyWith(clientEncryptionRules: const [rule]));
      expect(
          c.bannerActivity?.bucketAnimation, BucketActivityAnimation.boltThrow);
      expect(c.bannerActivity?.phase, BannerActivityPhase.working);
      expect(await save, durable);
      expect(
          c.bannerActivity?.bucketAnimation, BucketActivityAnimation.boltThrow);
      expect(
          c.bannerActivity?.phase,
          durable
              ? BannerActivityPhase.succeeded
              : BannerActivityPhase.warning);
    }
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

  testWidgets(
      'approved glyphs complete their handoff and respect reduced motion',
      (tester) async {
    Widget host(BucketActivityAnimation animation, BannerActivityPhase phase,
            {bool animate = true}) =>
        MaterialApp(
          home: Scaffold(
            body: Center(
              child: BannerActivityIndicator(
                bucketAnimation: animation,
                spec: spec(BannerActivityKind.action, phase, animate: animate),
              ),
            ),
          ),
        );
    BucketActivityPainter painter() => tester
        .widget<CustomPaint>(find.descendant(
          of: find.byType(BucketActivityIndicator),
          matching: find.byType(CustomPaint),
        ))
        .painter! as BucketActivityPainter;

    for (final animation in BucketActivityAnimation.values) {
      await tester.pumpWidget(host(animation, BannerActivityPhase.working));
      await tester.pump(const Duration(milliseconds: 130));
      expect(painter().waiting, isTrue);
      expect(painter().clock.isAnimating, isTrue);
      await tester.pumpWidget(host(animation, BannerActivityPhase.succeeded));
      await tester.pumpAndSettle();
      expect(painter().phase, BannerActivityPhase.succeeded);
      expect(painter().clock.value, 1);
      await tester.pumpWidget(
          host(animation, BannerActivityPhase.working, animate: false));
      await tester.pumpAndSettle();
      expect(painter().clock.isAnimating, isFalse);
      await tester.pumpWidget(
          host(animation, BannerActivityPhase.failed, animate: false));
      expect(painter().phase, BannerActivityPhase.failed);
      expect(painter().clock.value, 1);
      await tester.pumpWidget(const SizedBox.shrink());
    }
  });
}
