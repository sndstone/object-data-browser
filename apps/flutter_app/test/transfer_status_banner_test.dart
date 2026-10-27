import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:s3_browser_crossplat/controllers/app_controller.dart';
import 'package:s3_browser_crossplat/controllers/transfer_presentation.dart';
import 'package:s3_browser_crossplat/models/domain_models.dart';
import 'package:s3_browser_crossplat/services/mock_engine_service.dart';
import 'package:s3_browser_crossplat/widgets/transfer_status/file_scan_indicator.dart';
import 'package:s3_browser_crossplat/widgets/transfer_status/segments_indicator.dart';
import 'package:s3_browser_crossplat/widgets/transfer_status/transfer_status_indicator.dart';
import 'package:s3_browser_crossplat/widgets/transfer_status/transfer_status_spec.dart';

/// Holds every upload until [gate] completes, like a slow engine start.
class _GatedEngine extends MockEngineService {
  final gate = Completer<void>();
  @override
  Future<TransferJob> startUpload({
    required String engineId,
    required EndpointProfile profile,
    required String bucketName,
    required String prefix,
    required List<String> filePaths,
    required Map<String, String> objectKeyByPath,
    required int multipartThresholdMiB,
    required int multipartChunkMiB,
  }) async {
    await gate.future;
    return super.startUpload(
        engineId: engineId,
        profile: profile,
        bucketName: bucketName,
        prefix: prefix,
        filePaths: filePaths,
        objectKeyByPath: objectKeyByPath,
        multipartThresholdMiB: multipartThresholdMiB,
        multipartChunkMiB: multipartChunkMiB);
  }
}

/// Pause requests wait for [gate], then report the job as paused.
class _ControlEngine extends MockEngineService {
  final gate = Completer<void>();
  TransferJob? job;
  @override
  Future<TransferJob> pauseTransfer(
      {required String engineId, required String jobId}) async {
    await gate.future;
    return job!.copyWith(status: 'paused', canPause: false, canResume: true);
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

TransferJob _job(String status, double progress, int bytes,
        {String direction = 'upload', int? itemCount}) =>
    TransferJob(
        id: 'job',
        label: 'job',
        direction: direction,
        progress: progress,
        status: status,
        bytesTransferred: bytes,
        totalBytes: 100,
        itemCount: itemCount,
        outputLines: const []);

void main() {
  test('running jobs stay preparing until bytes or progress move', () {
    expect(transferStatusPhase('queued', 0, 0), TransferStatusPhase.preparing);
    expect(
        transferStatusPhase('running', 0, null), TransferStatusPhase.preparing);
    expect(
        transferStatusPhase('running', 0, 1), TransferStatusPhase.transferring);
    expect(transferStatusPhase('running', .01, 0),
        TransferStatusPhase.transferring);
    expect(transferStatusPhase('paused', 0, 0), TransferStatusPhase.paused);
    expect(transferStatusPhase('cancelling', .5, 9),
        TransferStatusPhase.cancelling);
    expect(
        transferStatusPhase('canceled', .5, 9), TransferStatusPhase.cancelled);
    expect(
        transferStatusPhase('completed', 1, 9), TransferStatusPhase.completed);
    expect(transferStatusPhase('error', .2, 9), TransferStatusPhase.failed);
  });

  test('banner copy leaves the percent to the indicator', () {
    expect(transferBannerMessage(_job('running', 0, 0)), 'Preparing upload…');
    expect(transferBannerMessage(_job('running', 0, 0, itemCount: 3)),
        'Preparing upload of 3 files…');
    expect(
        transferBannerMessage(_job('running', .4, 40)), 'Upload in progress');
    expect(
        transferBannerMessage(
            _job('running', .4, 40, direction: 'download', itemCount: 2)),
        'Downloading 2 objects');
    expect(transferBannerMessage(_job('paused', .63, 63)), 'Upload paused');
    expect(transferBannerMessage(_job('completed', 1, 99, itemCount: 3)),
        'Upload complete · 3 files');
    expect(transferBannerMessage(_job('failed', .18, 18)), 'Upload failed');
  });

  test('banner shows a preparing upload before the engine reports a job',
      () async {
    final dir = await Directory.systemTemp.createTemp('preparing-upload');
    addTearDown(() => dir.delete(recursive: true));
    final files = [
      for (final name in ['a.bin', 'b.bin', 'c.bin'])
        (File('${dir.path}/$name')..writeAsBytesSync(List.filled(16, 0))).path
    ];
    final engine = _GatedEngine();
    final c = AppController(
        engineService: engine,
        initialSettings: _settings,
        initialProfiles: const [_profile]);
    await c.initialize();

    final single = c.startSampleUpload([files.first]);
    await Future<void>.delayed(const Duration(milliseconds: 10));
    expect(c.bannerMessage, 'Preparing upload…');
    expect(c.bannerTransferStatus?.phase, TransferStatusPhase.preparing);
    expect(c.bannerTransferStatus?.itemCount, 1);
    expect(c.bannerTransferStatus?.progress, isNull);
    engine.gate.complete();
    await single;
    expect(c.bannerTransferStatus?.phase, TransferStatusPhase.completed);

    final gated = _GatedEngine();
    final batch = AppController(
        engineService: gated,
        initialSettings: _settings,
        initialProfiles: const [_profile]);
    await batch.initialize();
    final multi = batch.startSampleUpload(files);
    await Future<void>.delayed(const Duration(milliseconds: 10));
    expect(batch.bannerTransferStatus?.phase, TransferStatusPhase.preparing);
    expect(batch.bannerTransferStatus?.itemCount, 3);
    expect(batch.bannerMessage, 'Preparing upload of 3 files…');
    gated.gate.complete();
    await multi;
    // The automatic relist finishes after the batch; the banner then returns
    // to the completed transfer.
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(batch.bannerTransferStatus?.phase, TransferStatusPhase.completed);
    expect(batch.bannerMessage,
        'Upload complete · 3 files · object list refreshed');
  });

  test('pausing keeps the banner attached to the transfer indicator', () async {
    final engine = _ControlEngine();
    final c = AppController(
        engineService: engine,
        initialSettings: _settings,
        initialProfiles: const [_profile]);
    await c.initialize();
    final job = _job('running', .4, 40).copyWith(canPause: true);
    engine.job = job;
    c.transferJobs = [job];
    c.browserTasks = [
      BrowserTaskRecord(
          id: job.id,
          kind: BrowserTaskKind.transfer,
          label: job.label,
          status: 'running',
          startedAt: DateTime(2026),
          progress: .4,
          bytesTransferred: 40),
    ];
    c.bannerTaskId = job.id;
    c.bannerMessage = transferBannerMessage(job);

    final pause = c.pauseTransfer(job.id);
    await Future<void>.delayed(Duration.zero);
    expect(c.bannerMessage, 'Pausing upload…');
    expect(c.bannerTransferStatus?.phase, TransferStatusPhase.transferring);
    engine.gate.complete();
    await pause;
    expect(c.bannerTaskId, job.id);
    expect(c.bannerMessage, 'Upload paused');
    expect(c.bannerSeverity, BannerSeverity.info);
    expect(c.bannerTransferStatus?.phase, TransferStatusPhase.paused);
  });

  Widget host(TransferStatusSpec spec) => MaterialApp(
      home: Scaffold(body: Center(child: TransferStatusIndicator(spec: spec))));

  TransferStatusSpec spec(TransferStatusPhase phase,
          {int itemCount = 1,
          bool animate = true,
          TransferStatusDirection direction = TransferStatusDirection.upload,
          double? progress}) =>
      TransferStatusSpec(
          phase: phase,
          direction: direction,
          progress: progress,
          animate: animate,
          itemCount: itemCount,
          foreground: Colors.white,
          background: Colors.black);

  testWidgets('single transfers use file scan, batches use segments',
      (tester) async {
    for (final direction in TransferStatusDirection.values) {
      await tester.pumpWidget(host(spec(TransferStatusPhase.transferring,
          direction: direction, progress: .4)));
      expect(find.byType(FileScanIndicator), findsOneWidget);
      expect(find.text('40%'), findsOneWidget);
      await tester.pumpWidget(host(spec(TransferStatusPhase.transferring,
          direction: direction, progress: .4, itemCount: 3)));
      expect(find.byType(SegmentsIndicator), findsOneWidget);
    }
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('indicators settle when motion is off or the transfer ended',
      (tester) async {
    for (final itemCount in [1, 3]) {
      for (final direction in TransferStatusDirection.values) {
        await tester.pumpWidget(host(spec(TransferStatusPhase.preparing,
            itemCount: itemCount, direction: direction, animate: false)));
        await tester.pumpAndSettle();
        for (final phase in [
          TransferStatusPhase.paused,
          TransferStatusPhase.completed,
          TransferStatusPhase.failed,
          TransferStatusPhase.cancelled,
        ]) {
          await tester.pumpWidget(host(spec(phase,
              itemCount: itemCount, direction: direction, progress: .5)));
          await tester.pumpAndSettle();
        }
        // An animated preparing state keeps running until the phase changes.
        await tester.pumpWidget(host(spec(TransferStatusPhase.preparing,
            itemCount: itemCount, direction: direction)));
        await tester.pump(const Duration(milliseconds: 100));
        expect(tester.binding.hasScheduledFrame, isTrue);
        await tester.pumpWidget(const SizedBox.shrink());
      }
    }
  });
}
