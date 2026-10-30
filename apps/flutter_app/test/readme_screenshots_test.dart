// Opt-in documentation capture; never connects to a storage endpoint.
import 'dart:io';
import 'dart:ui' show ImageByteFormat;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:s3_browser_crossplat/app/s3_browser_app.dart';
import 'package:s3_browser_crossplat/controllers/app_controller.dart';
import 'package:s3_browser_crossplat/models/domain_models.dart';
import 'package:s3_browser_crossplat/services/mock_engine_service.dart';

final _date = DateTime(2026, 10, 28, 14, 32);
const _source = '''{
  "release": "autumn-2026",
  "environment": "staging",
  "region": "eu-central-1",
  "assets": [
    {
      "key": "images/cover.webp",
      "contentType": "image/webp",
      "cacheControl": "public, max-age=86400"
    },
    {
      "key": "exports/catalog.parquet",
      "contentType": "application/octet-stream",
      "rows": 24800
    }
  ],
  "retention": {
    "archiveAfterDays": 90,
    "expireAfterDays": 365
  }
}
''';

ObjectEntry _object(String name, int size, {bool folder = false}) =>
    ObjectEntry(
      key: name,
      name: name,
      size: size,
      storageClass: folder ? 'FOLDER' : 'STANDARD',
      modifiedAt: _date,
      isFolder: folder,
      metadataCount: folder ? 0 : 2,
      etag: folder ? null : 'd41d8cd98f00b204e9800998ecf8427e',
    );

// Illustrative data for the UI, not measurements of an engine or provider.
BenchmarkRun _benchmark(BenchmarkConfig draft) {
  const rates = [104, 112, 118, 122, 126, 119, 124, 130, 121, 117, 125, 122];
  return BenchmarkRun(
    id: 'demo-mixed-workload',
    config: draft.copyWith(
      bucketName: 'studio-assets',
      prefix: 'benchmark-demo/',
      workloadType: 'custom',
      deleteMode: 'single',
      readPercent: 50,
      writePercent: 30,
      deletePercent: 20,
      objectSizes: [65536, 1048576, 8388608],
      concurrentThreads: 16,
      testMode: 'duration',
      durationSeconds: 60,
      objectCount: 512,
      validateChecksum: true,
      maxPoolConnections: 128,
      csvOutputPath: r'C:\Downloads\benchmark-demo.csv',
      jsonOutputPath: r'C:\Downloads\benchmark-demo.json',
    ),
    status: 'completed',
    processedCount: 7200,
    startedAt: _date.subtract(const Duration(minutes: 1)),
    completedAt: _date,
    activeElapsedSeconds: 60,
    averageLatencyMs: 11.76,
    throughputOpsPerSecond: 120,
    liveLog: const [
      'DEMO DATA - not measured performance',
      'Workload: 50% GET / 30% PUT / 20% DELETE',
      'Workers: 16 | object pool: 512',
      '00:15  1670 operations completed',
      '00:30  3505 operations completed',
      '01:00  7200 operations completed',
      'Checksums: 5760 passed | 0 failed',
      'Run completed. CSV export available.',
    ],
    resultSummary: BenchmarkResultSummary(
      totalOperations: 7200,
      operationsByType: const {'GET': 3600, 'PUT': 2160, 'DELETE': 1440},
      latencyPercentilesMs: const {
        'p50': 10.2,
        'p75': 14.5,
        'p90': 19.8,
        'p95': 24.6,
        'p99': 38.4,
        'p999': 52.1,
      },
      throughputSeries: [
        for (var i = 0; i < rates.length; i++)
          {
            'second': (i + 1) * 5,
            'label': '${(i + 1) * 5}s',
            'opsPerSecond': rates[i],
            'bytesPerSecond': rates[i] * 524288,
            'operations': {
              'GET': (rates[i] * .5).round(),
              'PUT': (rates[i] * .3).round(),
              'DELETE': (rates[i] * .2).round(),
            },
          },
      ],
      sizeLatencyBuckets: const [
        {'sizeBytes': 65536, 'avgLatencyMs': 4.8, 'count': 2400},
        {'sizeBytes': 1048576, 'avgLatencyMs': 10.4, 'count': 2400},
        {'sizeBytes': 8388608, 'avgLatencyMs': 20.08, 'count': 2400},
      ],
      checksumStats: const {
        'validated_success': 5760,
        'validated_failure': 0,
        'not_used': 1440,
      },
      detailMetrics: const {
        'sampleCount': 12,
        'sampleWindowSeconds': 5,
        'averageOpsPerSecond': 120.0,
        'peakOpsPerSecond': 130.0,
        'averageBytesPerSecond': 62914560.0,
        'peakBytesPerSecond': 68157440.0,
        'averageObjectSizeBytes': 524288,
        'checksumValidated': 5760,
        'errorCount': 0,
        'retryCount': 2,
      },
      latencyPercentilesByOperationMs: const {
        'GET': {'p50': 9.1, 'p95': 21.4, 'p99': 32.6},
        'PUT': {'p50': 14.2, 'p95': 29.3, 'p99': 45.8},
        'DELETE': {'p50': 6.4, 'p95': 14.1, 'p99': 22.5},
      },
      operationDetails: const [
        {
          'operation': 'GET',
          'count': 3600,
          'sharePct': 50.0,
          'avgOpsPerSecond': 60.0,
          'avgLatencyMs': 10.8,
          'p50LatencyMs': 9.1,
          'p95LatencyMs': 21.4,
          'p99LatencyMs': 32.6
        },
        {
          'operation': 'PUT',
          'count': 2160,
          'sharePct': 30.0,
          'avgOpsPerSecond': 36.0,
          'avgLatencyMs': 16.4,
          'p50LatencyMs': 14.2,
          'p95LatencyMs': 29.3,
          'p99LatencyMs': 45.8
        },
        {
          'operation': 'DELETE',
          'count': 1440,
          'sharePct': 20.0,
          'avgOpsPerSecond': 24.0,
          'avgLatencyMs': 7.2,
          'p50LatencyMs': 6.4,
          'p95LatencyMs': 14.1,
          'p99LatencyMs': 22.5
        },
      ],
    ),
  );
}

void _seedTasks(AppController controller) {
  const mib = 1024 * 1024;
  controller.transferJobs = const [
    TransferJob(
      id: 'demo-upload',
      label: 'Upload site-backup.tar.gz',
      direction: 'upload',
      progress: .625,
      status: 'running',
      bytesTransferred: 640 * mib,
      totalBytes: 1024 * mib,
      strategyLabel: 'Multipart upload',
      currentItemLabel: 'site-backup.tar.gz',
      itemCount: 1,
      itemsCompleted: 0,
      partSizeBytes: 8 * mib,
      partsCompleted: 80,
      partsTotal: 128,
      canResume: false,
    ),
  ];
  controller.browserTasks = [
    BrowserTaskRecord(
      id: 'demo-upload',
      kind: BrowserTaskKind.transfer,
      label: 'Upload site-backup.tar.gz',
      status: 'running',
      startedAt: _date.subtract(const Duration(seconds: 20)),
      sampledAt: _date,
      progress: .625,
      profileId: 'demo',
      bucketName: 'studio-assets',
      engineJobId: 'demo-upload',
      bytesTransferred: 640 * mib,
      totalBytes: 1024 * mib,
      bytesPerSecond: 32.0 * mib,
      strategyLabel: 'Multipart upload',
      currentItemLabel: 'site-backup.tar.gz',
      itemCount: 1,
      itemsCompleted: 0,
      partSizeBytes: 8 * mib,
      partsCompleted: 80,
      partsTotal: 128,
      canPause: true,
      canCancel: true,
      outputLines: const [
        'DEMO DATA - no live transfer',
        'Source: C:\\Downloads\\site-backup.tar.gz',
        'Destination: studio-assets/site-backup.tar.gz',
        'Automatic part size: 8 MiB | bounded parallel workers: 8',
        '80 of 128 parts uploaded | 640 MiB of 1 GiB',
      ],
    ),
    BrowserTaskRecord(
      id: 'demo-paused',
      kind: BrowserTaskKind.transfer,
      label: 'Download catalog.parquet',
      status: 'paused',
      startedAt: _date.subtract(const Duration(minutes: 2)),
      sampledAt: _date,
      progress: .4,
      profileId: 'demo',
      bucketName: 'studio-assets',
      bytesTransferred: 80 * mib,
      totalBytes: 200 * mib,
      canResume: true,
      canCancel: true,
      currentItemLabel: 'catalog.parquet',
      strategyLabel: 'Range download',
    ),
    BrowserTaskRecord(
      id: 'demo-completed',
      kind: BrowserTaskKind.transfer,
      label: 'Download brand-guidelines.pdf',
      status: 'completed',
      startedAt: _date.subtract(const Duration(minutes: 3)),
      completedAt: _date.subtract(const Duration(minutes: 2, seconds: 56)),
      progress: 1,
      profileId: 'demo',
      bucketName: 'studio-assets',
      bytesTransferred: 2457600,
      totalBytes: 2457600,
    ),
    BrowserTaskRecord(
      id: 'demo-failed',
      kind: BrowserTaskKind.action,
      label: 'Copy exports/weekly.csv',
      status: 'failed',
      startedAt: _date.subtract(const Duration(minutes: 4)),
      completedAt: _date.subtract(const Duration(minutes: 3, seconds: 58)),
      progress: 0,
      profileId: 'demo',
      bucketName: 'daily-backups',
      outputLines: const [
        'Demo failure: destination access denied. Source retained.'
      ],
    ),
    BrowserTaskRecord(
      id: 'demo-benchmark',
      kind: BrowserTaskKind.benchmark,
      label: 'Mixed workload benchmark',
      status: 'completed',
      startedAt: _date.subtract(const Duration(minutes: 1)),
      completedAt: _date,
      progress: 1,
      profileId: 'demo',
      bucketName: 'studio-assets',
    ),
  ];
  controller.selectedTaskId = 'demo-upload';
  controller.taskView = BrowserTaskView.all;
  controller.bannerMessage = 'Upload in progress';
  controller.bannerTaskId = 'demo-upload';
}

void _seedEvents(AppController controller) {
  final samples = [
    ('INFO', 'Profiles', 'Demo session: Studio storage selected.', null),
    ('API', 'Browser', 'Listed 3 buckets.', 'ListBuckets'),
    (
      'API',
      'Browser',
      'Loaded 12 objects from studio-assets.',
      'ListObjectsV2'
    ),
    ('API', 'Preview', 'Loaded release-manifest.json (432 B).', 'GetObject'),
    (
      'INFO',
      'Transfer',
      'Downloaded brand-guidelines.pdf. Size verified.',
      null
    ),
    (
      'WARN',
      'Transfer',
      'Retrying part 7 after a throttled response (attempt 2).',
      null
    ),
    ('API', 'Transfer', 'Uploaded part 7 after retry.', 'UploadPart'),
    ('INFO', 'Transfer', 'Paused download of catalog.parquet.', null),
    (
      'ERROR',
      'Copy',
      'Copy denied by destination policy. Source retained.',
      null
    ),
    ('INFO', 'Benchmark', 'Demo workload completed: 7200 operations.', null),
    (
      'DEBUG',
      'Transfer',
      'Multipart upload: 8 MiB parts, 8 workers, 128 parts.',
      null
    ),
    ('API', 'Transfer', 'Part 80 complete (8 MiB).', 'UploadPart'),
    ('INFO', 'Transfer', 'Upload in progress: 640 MiB / 1 GiB.', null),
  ];
  controller.eventLog = [
    for (var i = samples.length - 1; i >= 0; i--)
      EventLogEntry(
        timestamp:
            _date.subtract(Duration(seconds: (samples.length - 1 - i) * 5)),
        level: samples[i].$1,
        category: samples[i].$2,
        message: samples[i].$3,
        profileId: 'demo',
        bucketName: 'studio-assets',
        engineId: 'python',
        source: samples[i].$1 == 'API' ? 'API' : 'app',
        method: samples[i].$4,
        responseStatus: samples[i].$4 == null ? null : '200',
        latencyMs: samples[i].$4 == null ? null : 12 + i * 2,
      ),
  ];
}

class _ScreenshotEngine extends MockEngineService {
  @override
  Future<List<BucketSummary>> listBuckets({
    required String engineId,
    required EndpointProfile profile,
  }) async =>
      [
        for (final name in [
          'studio-assets',
          'daily-backups',
          'build-artifacts'
        ])
          BucketSummary(
            name: name,
            region: 'eu-central-1',
            objectCountHint: name == 'studio-assets' ? 12 : 48,
            versioningEnabled: true,
            createdAt: DateTime(2026, 8, 12),
          ),
      ];

  @override
  Future<ObjectListResult> listObjects({
    required String engineId,
    required EndpointProfile profile,
    required String bucketName,
    required String prefix,
    required bool flat,
    ListCursor? cursor,
  }) async =>
      ObjectListResult(items: [
        _object('exports/', 0, folder: true),
        _object('images/', 0, folder: true),
        _object('releases/', 0, folder: true),
        _object('release-manifest.json', _source.length),
        _object('asset-index.csv', 98304),
        _object('brand-guidelines.pdf', 2457600),
        _object('catalog.parquet', 184549376),
        _object('cover.webp', 458752),
        _object('deployment.yaml', 1840),
        _object('product-feed.json', 327680),
        _object('readme.txt', 2148),
        _object('site-backup.tar.gz', 734003200),
      ], cursor: const ListCursor(value: null, hasMore: false));
}

void main() {
  testWidgets('capture README screenshots', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1600, 1000);
    await tester.binding.setSurfaceSize(const Size(1600, 1000));
    addTearDown(() async {
      tester.view.resetDevicePixelRatio();
      tester.view.resetPhysicalSize();
      await tester.binding.setSurfaceSize(null);
    });
    for (final (family, path) in [
      ('MaterialIcons', 'fonts/MaterialIcons-Regular.otf'),
      ('Inter', 'assets/fonts/Inter.ttf'),
      ('Sora', 'assets/fonts/Sora.ttf'),
    ]) {
      await (FontLoader(family)..addFont(rootBundle.load(path))).load();
    }
    // Widget tests otherwise substitute Ahem's square glyphs for system fonts.
    final monoPath = Platform.environment['README_MONOSPACE_FONT'] ??
        (Platform.isWindows
            ? r'C:\Windows\Fonts\consola.ttf'
            : Platform.isMacOS
                ? '/System/Library/Fonts/Menlo.ttc'
                : '/usr/share/fonts/truetype/dejavu/DejaVuSansMono.ttf');
    final monoBytes = await tester.runAsync(() => File(monoPath).readAsBytes());
    for (final family in ['monospace', 'Menlo']) {
      await (FontLoader(family)
            ..addFont(Future.value(ByteData.sublistView(monoBytes!))))
          .load();
    }
    final controller = AppController(
      engineService: _ScreenshotEngine(),
      initialSettings: AppSettings.fromJson({
        'defaultEngineId': 'python',
        'darkMode': true,
        'enableAnimations': false,
        'uiScalePercent': 100,
        'browserInspectorLayout': 'right',
        'downloadPath': r'C:\Downloads',
      }),
      initialProfiles: const [
        EndpointProfile(
          id: 'demo',
          name: 'Studio storage',
          endpointUrl: 'https://s3.example.com',
          region: 'eu-central-1',
          accessKey: 'DEMO-ACCESS-KEY',
          secretKey: 'fictional-demo-secret',
          pathStyle: true,
          verifyTls: true,
        ),
      ],
    );
    addTearDown(controller.dispose);
    await controller.initialize();
    controller.selectedObject = controller.objects
        .singleWhere((o) => o.name == 'release-manifest.json');
    controller.selectedObjectDetails = const ObjectDetails(
      key: 'release-manifest.json',
      metadata: {'owner': 'studio', 'build': 'autumn-2026'},
      headers: {
        'Content-Type': 'application/json',
        'Cache-Control': 'public, max-age=3600',
      },
      tags: {'environment': 'staging', 'project': 'catalog'},
      debugEvents: [],
      apiCalls: [],
    );
    controller.selectedObjectPreview = ObjectPreview.ready(
      key: 'release-manifest.json',
      kind: ObjectPreviewKind.text,
      contentType: 'application/json',
      text: _source,
      loadedBytes: _source.length,
      message: 'Preview loaded.',
    );
    controller.inspectorTab = BrowserInspectorTab.objectDetails;
    controller.clearBanner();
    final boundaryKey = GlobalKey();
    await tester.pumpWidget(RepaintBoundary(
      key: boundaryKey,
      child: S3BrowserApp(controller: controller),
    ));
    await tester.pumpAndSettle();

    Future<void> capture(String name) async {
      expect(tester.takeException(), isNull);
      await tester.runAsync(() async {
        final image = await (boundaryKey.currentContext!.findRenderObject()
                as RenderRepaintBoundary)
            .toImage();
        try {
          final bytes = await image.toByteData(format: ImageByteFormat.png);
          final file = File('../../docs/screenshots/$name.png');
          await file.parent.create(recursive: true);
          await file.writeAsBytes(bytes!.buffer.asUint8List());
        } finally {
          image.dispose();
        }
      });
    }

    await capture('browser-dark');
    controller.settings = controller.settings.copyWith(darkMode: false);
    controller.clearBanner();
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Open preview'));
    await tester.pumpAndSettle();
    await capture('source-preview-light');
    await tester.tap(find.byTooltip('Close preview'));
    await tester.pumpAndSettle();
    controller.selectTab(WorkspaceTab.settings);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Studio storage').last);
    await tester.pumpAndSettle();
    await capture('settings-light');

    final run = _benchmark(controller.benchmarkDraft);
    controller.benchmarkRun = run;
    controller.benchmarkDraft = run.config;
    controller.benchmarkHistory = [run];
    controller.selectedBenchmarkRunId = run.id;
    controller.selectTab(WorkspaceTab.benchmark);
    await tester.pumpAndSettle();
    await capture('benchmark-results-light');
    await tester.tap(find.text('Configure').first);
    await tester.pumpAndSettle();
    await capture('benchmark-configure-light');

    _seedTasks(controller);
    controller.settings = controller.settings.copyWith(darkMode: true);
    controller.selectTab(WorkspaceTab.tasks);
    await tester.pumpAndSettle();
    await capture('jobs-status-dark');

    _seedEvents(controller);
    controller.clearBanner();
    controller.selectTab(WorkspaceTab.eventLog);
    await tester.pumpAndSettle();
    await capture('event-log-dark');
    await tester.pumpWidget(const SizedBox.shrink());
    debugDefaultTargetPlatformOverride = null;
  }, skip: Platform.environment['README_SCREENSHOTS'] != '1');
}
