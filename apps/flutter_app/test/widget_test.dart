import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:s3_browser_crossplat/app/s3_browser_app.dart';
import 'package:s3_browser_crossplat/benchmark/benchmark_workspace.dart';
import 'package:s3_browser_crossplat/browser/browser_workspace.dart';
import 'package:s3_browser_crossplat/controllers/app_controller.dart';
import 'package:s3_browser_crossplat/models/domain_models.dart';
import 'package:s3_browser_crossplat/services/mock_engine_service.dart';
import 'package:s3_browser_crossplat/theme/breakpoints.dart';
import 'package:s3_browser_crossplat/theme/app_motion.dart';
import 'package:s3_browser_crossplat/logs/structured_log_list.dart';

class TestAppController extends AppController {
  TestAppController({
    required super.engineService,
    required super.initialSettings,
    required super.initialProfiles,
  });

  BenchmarkConfig? capturedBenchmarkStartConfig;

  void emitChange() {
    notifyListeners();
  }

  @override
  Future<void> startBenchmark() async {
    capturedBenchmarkStartConfig = benchmarkDraft;
    benchmarkRun = BenchmarkRun(
      id: 'bench-test',
      config: benchmarkDraft,
      status: 'running',
      processedCount: 0,
      startedAt: DateTime(2026, 3, 22, 16),
      averageLatencyMs: 0,
      throughputOpsPerSecond: 0,
      liveLog: const [],
    );
    selectedBenchmarkRunId = benchmarkRun!.id;
    benchmarkHistory = [benchmarkRun!, ...benchmarkHistory];
    notifyListeners();
  }
}

Future<TestAppController> _buildController({AppSettings? settings}) async {
  final controller = TestAppController(
    engineService: MockEngineService(),
    initialSettings: settings ??
        const AppSettings(
          darkMode: false,
          defaultEngineId: 'rust',
          downloadPath: r'C:\Temp\downloads',
          tempPath: r'C:\Temp',
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
          benchmarkLogPath: r'C:\Temp\benchmark.log',
          browserInspectorLayout: BrowserInspectorLayout.bottom,
          browserInspectorSize: 360,
          relistObjectsAfterMutation: true,
          uiScalePercent: 70,
          logTextScalePercent: 80,
        ),
    initialProfiles: const [
      EndpointProfile(
        id: 'test',
        name: 'Test',
        endpointUrl: 'http://localhost:9000',
        region: 'us-east-1',
        accessKey: 'key',
        secretKey: 'secret',
        pathStyle: true,
        verifyTls: false,
      ),
    ],
  );
  await controller.initialize();
  return controller;
}

BucketSummary _bucket(int index) {
  return BucketSummary(
    name: 'bucket-$index',
    region: 'us-east-1',
    objectCountHint: index * 10,
    versioningEnabled: index.isEven,
  );
}

void _seedBuckets(TestAppController controller, {required int count}) {
  final buckets = List.generate(count, _bucket);
  controller.buckets = buckets;
  controller.selectedBucket = buckets.first;
  controller.emitChange();
}

Widget _bucketPanelApp(TestAppController controller, {required Size size}) {
  return MaterialApp(
    home: MediaQuery(
      data: MediaQueryData(size: size),
      child: Scaffold(
        body: Padding(
          padding: const EdgeInsets.all(16),
          child: SizedBox(
            width: size.width > 700 ? 320 : size.width - 32,
            height: size.height - 32,
            child: BrowserBucketPanel(
              controller: controller,
              compact: size.width < 700,
              onCreateBucket: () {},
              onDeleteBucket: (_, {force = false}) async {},
              onEditBucketLifecycle: (_) async {},
              onEditBucketPolicy: (_) async {},
              onEditBucketEncryption: (_) async {},
              onEditBucketTags: (_) async {},
              onToggleBucketVersioning: (_, __) async {},
              onOpenBucket: (_) async {},
              onCopyBucket: (_) async {},
              inlineSpinnerBuilder: () => const SizedBox.shrink(),
              inlineStatBuilder: (label, value) => Text('$label: $value'),
            ),
          ),
        ),
      ),
    ),
  );
}

Widget _benchmarkApp(TestAppController controller) {
  return MaterialApp(
    home: Scaffold(
      body: BenchmarkWorkspace(controller: controller),
    ),
  );
}

Widget _browserApp(
  TestAppController controller, {
  required Size size,
  required bool compact,
}) {
  return MaterialApp(
    home: MediaQuery(
      data: MediaQueryData(size: size),
      child: Scaffold(
        body: BrowserWorkspace(
          controller: controller,
          compact: compact,
        ),
      ),
    ),
  );
}

Finder _debugSwitchFinder() {
  return find.byWidgetPredicate((widget) {
    if (widget is! SwitchListTile) {
      return false;
    }
    final title = widget.title;
    return title is Text && (title.data ?? '').toLowerCase().contains('debug');
  });
}

EventLogEntry _apiTraceEntry({
  required String phase,
  required String requestId,
  required DateTime timestamp,
  String? objectKey,
  int? latencyMs,
}) {
  return EventLogEntry(
    timestamp: timestamp,
    level: 'API',
    category: phase == 'send' ? 'EngineRequest' : 'EngineResponse',
    message: '$phase trace',
    profileId: 'test',
    bucketName: 'bucket-0',
    objectKey: objectKey,
    source: 'api',
    requestId: requestId,
    tracePhase: phase,
    engineId: 'rust',
    method: 'HeadObject',
    responseStatus: phase == 'response' ? 'ok' : null,
    latencyMs: latencyMs,
    traceHead: {
      'requestId': requestId,
      'phase': phase,
    },
    traceBody: {
      'bucket': 'bucket-0',
      if (objectKey != null) 'key': objectKey,
      'phase': phase,
    },
  );
}

void main() {
  for (final axis in Axis.values) {
    testWidgets('ordered $axis transitions reverse incoming and outgoing edges',
        (tester) async {
      Widget frame(int position) => MaterialApp(
          home: DirectionalSwitcher(
              position: position,
              axis: axis,
              duration: const Duration(milliseconds: 240),
              child: SizedBox(
                  key: ValueKey('motion-panel-$position'),
                  width: 400,
                  height: 400,
                  child: Text('$position'))));
      double offset(int position, {bool incoming = true}) {
        final slide = tester
            .widgetList<SlideTransition>(find.ancestor(
                of: find.byKey(ValueKey('motion-panel-$position')),
                matching: find.byKey(const ValueKey('directional-slide'))))
            .firstWhere((slide) =>
                slide.child is IgnorePointer &&
                (slide.child as IgnorePointer).ignoring != incoming);
        return axis == Axis.horizontal
            ? slide.position.value.dx
            : slide.position.value.dy;
      }

      await tester.pumpWidget(frame(0));
      await tester.pumpWidget(frame(1));
      await tester.pump(const Duration(milliseconds: 60));
      expect(offset(1), greaterThan(0));
      expect(offset(0, incoming: false), lessThan(0));
      // Reverse before the first transition finishes.
      await tester.pumpWidget(frame(0));
      await tester.pump(const Duration(milliseconds: 60));
      expect(offset(0), lessThan(0));
      expect(offset(1, incoming: false), greaterThan(0));
      await tester.pumpAndSettle();
    });
  }

  testWidgets('column sorting toggles and inspector actions remain visible',
      (tester) async {
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.binding.setSurfaceSize(const Size(1440, 1024));
    final controller = await _buildController();
    await tester.pumpWidget(S3BrowserApp(controller: controller));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Sort by Size'));
    await tester.pumpAndSettle();
    expect(controller.objectSortField, BrowserObjectSortField.size);
    expect(controller.objectSortDescending, false);
    await tester
        .tap(find.byTooltip('Sort by Size · ascending; switch to descending'));
    await tester.pumpAndSettle();
    expect(controller.objectSortDescending, true);
    expect(find.text('Bucket config'), findsOneWidget);
    await tester.tap(find.text('Diagnostics'));
    await tester.pumpAndSettle();
    expect(find.text('Events & Debug'), findsOneWidget);
    expect(find.byTooltip('Advanced inspector tools'), findsNothing);
    await tester.tap(find.widgetWithText(OutlinedButton, 'View tools'));
    await tester.pumpAndSettle();
    expect(find.byIcon(Icons.create_new_folder_outlined), findsWidgets);
    expect(find.text('Select all loaded objects'), findsOneWidget);
    expect(find.text('Show loaded rows'), findsOneWidget);
  });

  testWidgets('event log nests independent files beneath one parent upload',
      (tester) async {
    final time = DateTime(2026);
    final entries = [
      EventLogEntry(
          timestamp: time,
          level: 'INFO',
          category: 'Transfers',
          message: 'Upload two files',
          source: 'upload-batch',
          requestId: 'batch',
          responseStatus: 'completed'),
      for (final file in ['first.txt', 'second.txt'])
        EventLogEntry(
            timestamp: time,
            level: 'INFO',
            category: 'Transfers',
            message: 'Uploaded $file',
            source: 'upload-file',
            requestId: file,
            parentRequestId: 'batch',
            objectKey: file,
            responseStatus: 'completed'),
    ];
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: StructuredLogList(
                entries: entries,
                textScalePercent: 100,
                emptyMessage: 'Empty'))));
    expect(find.text('first.txt'), findsNothing);
    await tester.tap(find.text('Upload two files'));
    await tester.pumpAndSettle();
    expect(find.text('first.txt'), findsOneWidget);
    expect(find.text('second.txt'), findsOneWidget);
    await tester.tap(find.text('first.txt'));
    await tester.pumpAndSettle();
    expect(find.text('Uploaded first.txt'), findsOneWidget);
  });
  testWidgets('browser and settings remain usable at enlarged text on phone',
      (tester) async {
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.binding.setSurfaceSize(const Size(390, 844));
    final controller = await _buildController();
    controller.settings = controller.settings.copyWith(uiScalePercent: 150);
    await tester.pumpWidget(S3BrowserApp(controller: controller));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    controller.selectTab(WorkspaceTab.settings);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    controller.dispose();
  });
  testWidgets(
      'text scaling respects OS accessibility over legacy compact preference',
      (tester) async {
    expect(const PreferenceTextScaler(TextScaler.linear(2), .7).scale(16), 32);
    expect(
        const PreferenceTextScaler(TextScaler.noScaling, .7).scale(16), 11.2);
  });

  testWidgets('browser subtree is reused on unrelated job progress',
      (tester) async {
    final controller = await _buildController();
    await tester.pumpWidget(S3BrowserApp(controller: controller));
    await tester.pumpAndSettle();
    final before =
        tester.widget<BrowserWorkspace>(find.byType(BrowserWorkspace));
    controller.showBannerMessage('Background job updated');
    await tester.pump();
    final after =
        tester.widget<BrowserWorkspace>(find.byType(BrowserWorkspace));
    expect(identical(before, after), isTrue);
    await tester.pumpWidget(const SizedBox());
    controller.dispose();
  });

  testWidgets('reduced motion disables workspace and preview movement',
      (tester) async {
    late Duration duration;
    await tester.pumpWidget(MaterialApp(
        home: MediaQuery(
            data: const MediaQueryData(disableAnimations: true),
            child: Builder(builder: (context) {
              duration = AppMotion.duration(context);
              return const SizedBox();
            }))));
    expect(duration, Duration.zero);
  });
  test('window sizes use one shared four-class breakpoint model', () {
    expect(Breakpoints.sizeClass(699), WindowSizeClass.phone);
    expect(Breakpoints.sizeClass(700), WindowSizeClass.tablet);
    expect(Breakpoints.sizeClass(999), WindowSizeClass.tablet);
    expect(Breakpoints.sizeClass(1000), WindowSizeClass.smallDesktop);
    expect(Breakpoints.sizeClass(1359), WindowSizeClass.smallDesktop);
    expect(Breakpoints.sizeClass(1360), WindowSizeClass.desktop);
  });

  testWidgets('app shell renders before deferred initialization completes', (
    WidgetTester tester,
  ) async {
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.binding.setSurfaceSize(const Size(1440, 1024));

    final controller = TestAppController(
      engineService: MockEngineService(),
      initialSettings: const AppSettings(
        darkMode: false,
        defaultEngineId: 'rust',
        downloadPath: r'C:\Temp\downloads',
        tempPath: r'C:\Temp',
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
        benchmarkLogPath: r'C:\Temp\benchmark.log',
        browserInspectorLayout: BrowserInspectorLayout.bottom,
        browserInspectorSize: 360,
        relistObjectsAfterMutation: true,
        uiScalePercent: 70,
        logTextScalePercent: 80,
      ),
      initialProfiles: const [
        EndpointProfile(
          id: 'test',
          name: 'Test',
          endpointUrl: 'http://localhost:9000',
          region: 'us-east-1',
          accessKey: 'key',
          secretKey: 'secret',
          pathStyle: true,
          verifyTls: false,
        ),
      ],
    );

    expect(controller.engines, isEmpty);

    await tester.pumpWidget(S3BrowserApp(controller: controller));

    expect(find.text('Object Data Browser'), findsOneWidget);
  });

  testWidgets('app renders top-level workspaces', (WidgetTester tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.binding.setSurfaceSize(const Size(1600, 1200));
    final controller = await _buildController();
    controller.activeTab = WorkspaceTab.settings;
    controller.emitChange();

    await tester.pumpWidget(S3BrowserApp(controller: controller));
    await tester.pumpAndSettle();
    debugDefaultTargetPlatformOverride = null;

    expect(find.text('Object Data Browser'), findsOneWidget);
    expect(find.text('Buckets'), findsWidgets);
    expect(find.text('Benchmark'), findsWidgets);
    expect(find.text('Jobs'), findsWidgets);
    expect(find.text('Settings'), findsWidgets);
    expect(find.text('Event Log'), findsWidgets);
  });

  testWidgets('bucket list fills the desktop bucket panel', (
    WidgetTester tester,
  ) async {
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.binding.setSurfaceSize(const Size(1440, 1024));

    final controller = await _buildController();
    _seedBuckets(controller, count: 24);
    await tester.pumpWidget(
      _bucketPanelApp(controller, size: const Size(320, 900)),
    );
    await tester.pumpAndSettle();

    final createButton = find.widgetWithText(FilledButton, 'New bucket');
    final firstBucket = find.text('bucket-0');

    expect(firstBucket, findsOneWidget);
    expect(find.text('Selected profile'), findsNothing);
    expect(find.text('http://localhost:9000'), findsNothing);
    expect(
      tester.getTopLeft(firstBucket).dy,
      greaterThan(tester.getBottomLeft(createButton).dy),
    );
  });

  testWidgets('bucket list scroll reaches the last bucket in desktop layout', (
    WidgetTester tester,
  ) async {
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.binding.setSurfaceSize(const Size(1440, 1024));

    final controller = await _buildController();
    _seedBuckets(controller, count: 40);
    await tester.pumpWidget(
      _bucketPanelApp(controller, size: const Size(320, 900)),
    );
    await tester.pumpAndSettle();

    final bucketList = find.byKey(const ValueKey('bucket-panel-scroll'));
    final bucketListCenter = tester.getTopLeft(bucketList) +
        tester.getSize(bucketList).center(Offset.zero);
    for (var index = 0;
        index < 15 && find.text('bucket-39').evaluate().isEmpty;
        index++) {
      await tester.dragFrom(bucketListCenter, const Offset(0, -700));
      await tester.pumpAndSettle();
    }
    await tester.pumpAndSettle();

    expect(find.text('bucket-39'), findsOneWidget);
  });

  testWidgets('bucket row secondary click opens bucket context menu', (
    WidgetTester tester,
  ) async {
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.binding.setSurfaceSize(const Size(1440, 1024));

    final controller = await _buildController();
    _seedBuckets(controller, count: 4);
    await tester.pumpWidget(
      _bucketPanelApp(controller, size: const Size(320, 900)),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('bucket-0'), buttons: kSecondaryButton);
    await tester.pumpAndSettle();

    expect(find.text('Open bucket'), findsOneWidget);
    expect(find.text('Delete bucket'), findsOneWidget);
  });

  testWidgets('bucket list scroll reaches the last bucket in compact layout', (
    WidgetTester tester,
  ) async {
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.binding.setSurfaceSize(const Size(680, 1280));

    final controller = await _buildController();
    _seedBuckets(controller, count: 40);
    await tester.pumpWidget(
      _bucketPanelApp(controller, size: const Size(680, 1280)),
    );
    await tester.pumpAndSettle();

    final bucketList = find.byKey(const ValueKey('bucket-panel-scroll'));
    final bucketListCenter = tester.getTopLeft(bucketList) +
        tester.getSize(bucketList).center(Offset.zero);
    for (var index = 0;
        index < 8 && find.text('bucket-39').evaluate().isEmpty;
        index++) {
      await tester.dragFrom(bucketListCenter, const Offset(0, -520));
      await tester.pumpAndSettle();
    }
    await tester.pumpAndSettle();

    expect(find.text('bucket-39'), findsOneWidget);
  });

  testWidgets(
      'compact browser starts on buckets and opens objects after bucket tap',
      (WidgetTester tester) async {
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.binding.setSurfaceSize(const Size(680, 1280));

    final controller = await _buildController();
    _seedBuckets(controller, count: 4);

    await tester.pumpWidget(
      _browserApp(
        controller,
        size: const Size(680, 1280),
        compact: true,
      ),
    );
    await tester.pumpAndSettle();

    expect(find.widgetWithText(FilledButton, 'New bucket'), findsOneWidget);
    expect(find.widgetWithText(OutlinedButton, 'Create prefix'), findsNothing);

    await tester.tap(find.text('bucket-1'));
    await tester.pumpAndSettle();

    expect(
      controller.selectedBucket?.name,
      'bucket-1',
    );
    expect(find.text('Objects'), findsWidgets);
    expect(find.widgetWithText(OutlinedButton, 'View tools'), findsOneWidget);
  });

  testWidgets('compact desktop browser opens inspector from nested action', (
    WidgetTester tester,
  ) async {
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.binding.setSurfaceSize(const Size(960, 900));

    final controller = await _buildController();
    await controller.updateSettings(
      controller.settings.copyWith(browserInspectorSize: 560),
    );

    await tester.pumpWidget(
      _browserApp(
        controller,
        size: const Size(960, 900),
        compact: true,
      ),
    );
    await tester.pumpAndSettle();

    // Tablet-width windows keep the inspector available on demand instead of
    // docking it below the object list.
    expect(find.text('Inspector'), findsNothing);
    expect(
      find.text(
        'Drag and drop files here to upload them into the current bucket prefix.',
      ),
      findsNothing,
    );
    expect(find.widgetWithText(OutlinedButton, 'Create prefix'), findsNothing);
    expect(find.widgetWithText(FilterChip, 'List all'), findsNothing);

    final objectListSize =
        tester.getSize(find.byKey(const ValueKey('object-panel-list')));
    expect(objectListSize.height, greaterThan(240));

    // The on-demand inspector dialog opens the inspector for this view.
    await tester.tap(find.byTooltip('Inspector'));
    await tester.pumpAndSettle();

    expect(find.text('Bucket inspector'), findsOneWidget);
    expect(find.text('Bucket info'), findsOneWidget);
  });

  testWidgets('tablet browser exposes lesser actions in menu', (
    WidgetTester tester,
  ) async {
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.binding.setSurfaceSize(const Size(999, 800));

    final controller = await _buildController();
    await tester.pumpWidget(
      _browserApp(
        controller,
        size: const Size(999, 800),
        compact: true,
      ),
    );
    await tester.pumpAndSettle();

    expect(find.widgetWithText(OutlinedButton, 'Delete'), findsNothing);
    expect(find.widgetWithText(OutlinedButton, 'Create prefix'), findsNothing);
    await tester.tap(find.widgetWithText(OutlinedButton, 'View tools'));
    await tester.pumpAndSettle();

    expect(find.text('Name'), findsOneWidget);
    expect(find.text('Create prefix'), findsOneWidget);
    expect(find.text('List all'), findsOneWidget);
    expect(find.text('Flat view'), findsOneWidget);
  });

  testWidgets('object row secondary click opens object context menu', (
    WidgetTester tester,
  ) async {
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.binding.setSurfaceSize(const Size(1440, 1024));

    final controller = await _buildController();
    await tester.pumpWidget(
      _browserApp(
        controller,
        size: const Size(1440, 1024),
        compact: false,
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('object-0001.bin'), buttons: kSecondaryButton);
    await tester.pumpAndSettle();

    expect(controller.selectedObject?.key, 'archive/object-0001.bin');
    expect(find.text('Inspect object'), findsOneWidget);
    expect(
        find.widgetWithText(PopupMenuItem<String>, 'Download'), findsOneWidget);
    expect(find.text('Generate presigned URL'), findsOneWidget);
    expect(find.text('Delete object'), findsOneWidget);
  });

  testWidgets('narrow object rows expose a touch actions button', (
    WidgetTester tester,
  ) async {
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.binding.setSurfaceSize(const Size(390, 844));

    final controller = await _buildController();
    await tester.pumpWidget(
      _browserApp(
        controller,
        size: const Size(390, 844),
        compact: true,
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text(controller.buckets.first.name));
    await tester.pumpAndSettle();

    final actions = find.byTooltip('Object actions for object-0001.bin');
    expect(actions, findsOneWidget);

    await tester.tap(actions);
    await tester.pumpAndSettle();

    expect(controller.selectedObject?.key, 'archive/object-0001.bin');
    expect(find.text('Inspect object'), findsOneWidget);
  });

  testWidgets(
      'wide desktop browser keeps inspector and hides idle drop guidance', (
    WidgetTester tester,
  ) async {
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.binding.setSurfaceSize(const Size(1440, 1024));

    final controller = await _buildController();
    await tester.pumpWidget(
      _browserApp(
        controller,
        size: const Size(1440, 1024),
        compact: false,
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Bucket inspector'), findsOneWidget);
    expect(
      find.text(
        'Drag and drop files here to upload them into the current bucket prefix.',
      ),
      findsNothing,
    );
    expect(find.widgetWithText(OutlinedButton, 'Create prefix'), findsNothing);
  });

  testWidgets('text preview opens in an expanded selectable dialog', (
    WidgetTester tester,
  ) async {
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.binding.setSurfaceSize(const Size(1440, 1024));
    final controller = await _buildController();
    final object = ObjectEntry(
      key: 'reports/output.txt',
      name: 'output.txt',
      size: 24,
      storageClass: 'STANDARD',
      modifiedAt: DateTime(2026, 7, 16),
      isFolder: false,
    );
    controller.selectedObject = object;
    controller.inspectorTab = BrowserInspectorTab.objectPreview;
    controller.selectedObjectDetails = const ObjectDetails(
      key: 'reports/output.txt',
      metadata: {},
      headers: {},
      tags: {},
      debugEvents: [],
      apiCalls: [],
    );
    controller.selectedObjectPreview = ObjectPreview.ready(
      key: object.key,
      kind: ObjectPreviewKind.text,
      contentType: 'text/plain',
      text: 'Expanded preview contents',
      message: 'Preview loaded.',
    );
    controller.emitChange();

    await tester.pumpWidget(
      _browserApp(
        controller,
        size: const Size(1440, 1024),
        compact: false,
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Open preview'));
    await tester.pumpAndSettle();

    expect(find.byTooltip('Close preview'), findsOneWidget);
    expect(find.text('reports/output.txt'), findsOneWidget);
    expect(find.text('Expanded preview contents'), findsNWidgets(2));
    expect(find.byType(SelectableText), findsWidgets);
  });

  testWidgets(
      'HTML preview defaults to highlighted source and renders on demand', (
    WidgetTester tester,
  ) async {
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.binding.setSurfaceSize(const Size(1440, 1024));
    final controller = await _buildController();
    final object = ObjectEntry(
      key: 'site/index.html',
      name: 'index.html',
      size: 64,
      storageClass: 'STANDARD',
      modifiedAt: DateTime(2026, 7, 16),
      isFolder: false,
    );
    controller.selectedObject = object;
    controller.inspectorTab = BrowserInspectorTab.objectPreview;
    controller.selectedObjectDetails = const ObjectDetails(
      key: 'site/index.html',
      metadata: {},
      headers: {},
      tags: {},
      debugEvents: [],
      apiCalls: [],
    );
    controller.selectedObjectPreview = ObjectPreview.ready(
      key: object.key,
      kind: ObjectPreviewKind.text,
      contentType: 'text/html',
      text: '<h1>Rendered heading</h1><p>Preview body</p>',
      message: 'Preview loaded.',
    );
    controller.emitChange();

    await tester.pumpWidget(
      _browserApp(
        controller,
        size: const Size(1440, 1024),
        compact: false,
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Render page'), findsNothing);
    expect(find.byKey(const ValueKey('source-code-xml')), findsOneWidget);

    await tester.tap(find.byTooltip('Open preview'));
    await tester.pumpAndSettle();

    expect(find.text('Render page'), findsOneWidget);
    expect(
        find.byKey(const ValueKey('expanded-source-preview')), findsOneWidget);
    expect(find.byKey(const ValueKey('rendered-html-page')), findsNothing);

    await tester.tap(find.text('Render page'));
    await tester.pumpAndSettle();

    expect(find.text('View source'), findsOneWidget);
    expect(find.byKey(const ValueKey('rendered-html-page')), findsOneWidget);
    expect(
      find.byWidgetPredicate(
        (widget) =>
            widget is RichText &&
            widget.text.toPlainText().contains('Rendered heading'),
      ),
      findsOneWidget,
    );

    await tester.tap(find.text('View source'));
    await tester.pumpAndSettle();
    expect(
        find.byKey(const ValueKey('expanded-source-preview')), findsOneWidget);
  });

  testWidgets('tasks workspace renders top-level running task details', (
    WidgetTester tester,
  ) async {
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.binding.setSurfaceSize(const Size(1440, 1024));

    final controller = await _buildController();
    controller.browserTasks = [
      BrowserTaskRecord(
        id: 'upload-1',
        kind: BrowserTaskKind.transfer,
        label: 'Upload 1 file',
        status: 'running',
        startedAt: DateTime(2026, 3, 11, 10, 0),
        progress: 0.4,
        bucketName: 'bucket-0',
        strategyLabel: 'Multipart upload',
        itemCount: 2,
        itemsCompleted: 1,
        partsTotal: 4,
        partsCompleted: 2,
      ),
    ];
    controller.activeTab = WorkspaceTab.tasks;
    controller.emitChange();

    await tester.pumpWidget(S3BrowserApp(controller: controller));
    await tester.pumpAndSettle();

    expect(find.text('Jobs'), findsWidgets);
    expect(find.text('Running'), findsWidgets);
    expect(find.text('Upload 1 file'), findsOneWidget);
    await tester.tap(find.text('Upload 1 file'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Multipart upload'), findsOneWidget);
    expect(find.textContaining('Items: 1/2'), findsOneWidget);
    expect(find.textContaining('Parts: 2/4'), findsOneWidget);
  });

  testWidgets('tasks workspace can cancel a running listing task', (
    WidgetTester tester,
  ) async {
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.binding.setSurfaceSize(const Size(1440, 1024));

    final controller = await _buildController();
    controller.browserTasks = [
      BrowserTaskRecord(
        id: 'refresh-objects-1',
        kind: BrowserTaskKind.action,
        label: 'Listing objects for bucket-0...',
        status: 'running',
        startedAt: DateTime(2026, 3, 11, 10, 0),
        progress: 0,
        bucketName: 'bucket-0',
        actionKey: 'refresh-objects',
        canCancel: true,
      ),
    ];
    controller.activeTab = WorkspaceTab.tasks;
    controller.emitChange();

    await tester.pumpWidget(S3BrowserApp(controller: controller));
    await tester.pump();

    await tester.tap(find.text('Listing objects for bucket-0...'));
    await tester.pump(const Duration(milliseconds: 600));
    final cancelButton = tester
        .widget<OutlinedButton>(find.widgetWithText(OutlinedButton, 'Cancel'));
    cancelButton.onPressed!();
    await tester.pump();

    expect(controller.browserTasks.single.status, 'cancelling');
    expect(controller.browserTasks.single.canCancel, isFalse);
    expect(
      controller.browserTasks.single.outputLines.last,
      contains('Cancellation requested'),
    );
  });

  testWidgets('info banner clears after three and a half seconds', (
    WidgetTester tester,
  ) async {
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.binding.setSurfaceSize(const Size(1440, 1024));

    final controller = await _buildController();
    controller.showBannerMessage('Listing objects for bucket-0...');

    await tester.pumpWidget(S3BrowserApp(controller: controller));
    await tester.pump();
    expect(find.text('Listing objects for bucket-0...'), findsOneWidget);

    await tester.pump(const Duration(milliseconds: 3499));
    expect(find.text('Listing objects for bucket-0...'), findsOneWidget);

    await tester.pump(const Duration(milliseconds: 2));
    await tester.pump(const Duration(milliseconds: 260));
    expect(find.text('Listing objects for bucket-0...'), findsNothing);
  });

  testWidgets('completed listing banner clears after two seconds', (
    WidgetTester tester,
  ) async {
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.binding.setSurfaceSize(const Size(1440, 1024));

    final controller = await _buildController();
    controller.showBannerMessage('Listed first 1000 objects in bucket-0.',
        severity: BannerSeverity.success);

    await tester.pumpWidget(S3BrowserApp(controller: controller));
    await tester.pump();
    expect(find.text('Listed first 1000 objects in bucket-0.'), findsOneWidget);

    await tester.pump(const Duration(milliseconds: 1999));
    expect(find.text('Listed first 1000 objects in bucket-0.'), findsOneWidget);

    await tester.pump(const Duration(milliseconds: 2));
    await tester.pump(const Duration(milliseconds: 260));
    expect(find.text('Listed first 1000 objects in bucket-0.'), findsNothing);
  });

  testWidgets('listing banner opens the matching task', (
    WidgetTester tester,
  ) async {
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.binding.setSurfaceSize(const Size(1440, 1024));

    final controller = await _buildController();
    controller.browserTasks = [
      BrowserTaskRecord(
        id: 'refresh-objects-1',
        kind: BrowserTaskKind.action,
        label: 'Listing objects for bucket-0...',
        status: 'completed',
        startedAt: DateTime(2026, 3, 11, 10, 0),
        completedAt: DateTime(2026, 3, 11, 10, 1),
        progress: 1,
        bucketName: 'bucket-0',
        actionKey: 'refresh-objects',
        outputLines: const ['Listed first 1000 objects.', 'Completed.'],
      ),
    ];
    controller.bannerMessage = 'Listed first 1000 objects in bucket-0.';
    controller.bannerTaskId = 'refresh-objects-1';
    controller.emitChange();

    await tester.pumpWidget(S3BrowserApp(controller: controller));
    await tester.pump();

    await tester.tap(find.text('Listed first 1000 objects in bucket-0.'));
    await tester.pumpAndSettle();

    expect(controller.activeTab, WorkspaceTab.tasks);
    expect(controller.taskView, BrowserTaskView.all);
    expect(controller.selectedTaskId, 'refresh-objects-1');
    expect(find.text('Listing objects for bucket-0...'), findsOneWidget);
    expect(
      find.byWidgetPredicate(
        (widget) =>
            widget is SelectableText &&
            (widget.data ?? '').contains('Listed first 1000 objects.'),
      ),
      findsOneWidget,
    );
  });

  testWidgets('transfer banner shows progress and opens jobs', (
    WidgetTester tester,
  ) async {
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.binding.setSurfaceSize(const Size(1440, 1024));

    final controller = await _buildController();
    controller.browserTasks = [
      BrowserTaskRecord(
        id: 'upload-1',
        kind: BrowserTaskKind.transfer,
        label: 'Upload 1 file',
        status: 'running',
        startedAt: DateTime(2026, 3, 11, 10, 0),
        progress: 0.4,
        bucketName: 'bucket-0',
        strategyLabel: 'Multipart upload',
        itemCount: 1,
        itemsCompleted: 0,
      ),
    ];
    controller.bannerMessage = 'Upload in progress - 40%';
    controller.bannerTaskId = 'upload-1';
    controller.emitChange();

    await tester.pumpWidget(S3BrowserApp(controller: controller));
    await tester.pump();

    expect(find.text('40%'), findsOneWidget);
    expect(find.byKey(const ValueKey('banner-upload-1')), findsOneWidget);
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('banner-upload-1')),
        matching: find.byType(CircularProgressIndicator),
      ),
      findsNothing,
    );

    controller.browserTasks = [
      controller.browserTasks.first.copyWith(progress: 0.76),
    ];
    controller.bannerMessage = 'Upload in progress - 76%';
    controller.emitChange();
    await tester.pump();

    expect(find.byKey(const ValueKey('banner-upload-1')), findsOneWidget);
    expect(find.text('76%'), findsOneWidget);

    await tester.tap(find.text('Upload in progress - 76%'));
    await tester.pumpAndSettle();

    expect(controller.activeTab, WorkspaceTab.tasks);
    expect(controller.taskView, BrowserTaskView.running);
    expect(controller.selectedTaskId, 'upload-1');
    expect(find.text('Jobs'), findsWidgets);
  });

  testWidgets('benchmark engine switch does not trigger browser listing status',
      (
    WidgetTester tester,
  ) async {
    final controller = await _buildController();
    controller.activeTab = WorkspaceTab.benchmark;
    controller.browserTasks = const [];
    controller.emitChange();

    await controller.setEngine('go');

    expect(controller.activeEngineId, 'go');
    expect(controller.benchmarkDraft.engineId, 'go');
    expect(
      controller.browserTasks
          .where((task) =>
              task.actionKey == 'refresh-buckets' ||
              task.actionKey == 'refresh-objects')
          .toList(),
      isEmpty,
    );
    expect(controller.bannerMessage, isNot(contains('Listing')));
  });

  testWidgets(
      'browser create prefix flow requires a name and updates the action label',
      (
    WidgetTester tester,
  ) async {
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.binding.setSurfaceSize(const Size(1440, 1024));
    final controller = await _buildController();

    await tester.pumpWidget(
      _browserApp(
        controller,
        size: const Size(1440, 1024),
        compact: false,
      ),
    );
    await tester.pumpAndSettle();

    expect(find.widgetWithText(OutlinedButton, 'Create prefix'), findsNothing);
    expect(find.text('Create folder'), findsNothing);
    await tester.tap(find.widgetWithText(OutlinedButton, 'View tools'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Create prefix'));
    await tester.pumpAndSettle();

    expect(find.text('Create prefix'), findsWidgets);
    await tester.tap(find.widgetWithText(FilledButton, 'Create').last);
    await tester.pump(const Duration(milliseconds: 120));

    expect(find.byType(AlertDialog), findsOneWidget);

    await tester.enterText(
        find.widgetWithText(TextField, 'Prefix name'), 'reports/2026');
    await tester.tap(find.widgetWithText(FilledButton, 'Create').last);
    await tester.pumpAndSettle();

    expect(find.byType(AlertDialog), findsNothing);
  });

  testWidgets('settings workspace renders guided endpoint onboarding controls',
      (
    WidgetTester tester,
  ) async {
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.binding.setSurfaceSize(const Size(1600, 1200));

    final controller = await _buildController();
    controller.activeTab = WorkspaceTab.settings;
    controller.emitChange();

    await tester.pumpWidget(S3BrowserApp(controller: controller));
    await tester.pumpAndSettle();

    await tester.tap(find.widgetWithText(ListTile, 'General'));
    await tester.pumpAndSettle();
    expect(find.text('Default engine'), findsOneWidget);
    expect(find.text('Default endpoint'), findsOneWidget);
    await tester.tap(find.widgetWithText(ListTile, 'Connections'));
    await tester.pumpAndSettle();
    await tester.tap(find.byType(ExpansionTile).first);
    await tester.pumpAndSettle();

    expect(find.text('Endpoint type'), findsOneWidget);
    expect(find.text('Use HTTPS'), findsOneWidget);
    expect(find.text('Normalized endpoint'), findsOneWidget);
    await tester.tap(find.widgetWithText(ListTile, 'Transfers'));
    await tester.pumpAndSettle();
    expect(find.text('Automatically size upload parts'), findsOneWidget);
  });

  testWidgets(
      'browser workspace renders merged object filter and versions without object selection',
      (
    WidgetTester tester,
  ) async {
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.binding.setSurfaceSize(const Size(1440, 1024));

    final controller = await _buildController();
    controller.selectedObject = null;
    controller.inspectorTab = BrowserInspectorTab.versions;
    controller.emitChange();

    await tester.pumpWidget(S3BrowserApp(controller: controller));
    await tester.pumpAndSettle();

    expect(find.text('Filter mode'), findsAtLeastNWidgets(1));
    expect(find.text('Prefix'), findsWidgets);
    expect(find.text('Show all versions'), findsOneWidget);
    expect(find.text('Showing all versioned objects in the selected bucket.'),
        findsOneWidget);
  });

  testWidgets('object browser can list all backend pages on demand', (
    WidgetTester tester,
  ) async {
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.binding.setSurfaceSize(const Size(1440, 1024));

    final controller = await _buildController();

    await tester.pumpWidget(
      _browserApp(
        controller,
        size: const Size(1440, 1024),
        compact: false,
      ),
    );
    await tester.pumpAndSettle();

    expect(controller.objects.length, 1000);
    expect(controller.objectCursor.hasMore, isTrue);
    await tester.tap(find.widgetWithText(OutlinedButton, 'View tools'));
    await tester.pumpAndSettle();
    expect(find.text('List all'), findsOneWidget);

    await tester.tap(find.text('List all'));
    await tester.pumpAndSettle();
    expect(find.text('List all object keys?'), findsOneWidget);
    await tester.tap(find.widgetWithText(FilledButton, 'List all'));
    await tester.pumpAndSettle();
    await tester.pumpWidget(
      _browserApp(
        controller,
        size: const Size(1440, 1024),
        compact: false,
      ),
    );
    await tester.pumpAndSettle();

    expect(controller.objects.length, 2354);
    expect(controller.objectCursor.hasMore, isFalse);
    expect(find.textContaining('2354 loaded'), findsOneWidget);
  });

  testWidgets(
      'header bucket search filters the open bucket and hides elsewhere', (
    WidgetTester tester,
  ) async {
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.binding.setSurfaceSize(const Size(1600, 1200));
    final controller = await _buildController();

    await tester.pumpWidget(S3BrowserApp(controller: controller));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('object-search')), findsOneWidget);
    controller.setObjectFilterMode(BrowserFilterMode.text);
    await tester.pump();
    expect(
      controller.visibleObjects.map((object) => object.name),
      containsAll(['photo-001.jpg', 'report-2026-03.csv']),
    );

    await tester.enterText(
      find.byKey(const ValueKey('object-search')),
      'photo',
    );
    await tester.pump(const Duration(milliseconds: 251));
    await tester.pumpAndSettle();

    expect(controller.objectFilterMode, BrowserFilterMode.text);
    expect(controller.objectFilterValue, 'photo');
    expect(controller.visibleObjects.map((object) => object.name), [
      'photo-001.jpg',
    ]);

    controller.activeTab = WorkspaceTab.settings;
    controller.emitChange();
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('object-search')), findsNothing);
  });

  testWidgets('header theme toggle switches dark and light modes', (
    WidgetTester tester,
  ) async {
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.binding.setSurfaceSize(const Size(1600, 1200));
    final controller = await _buildController();

    await tester.pumpWidget(S3BrowserApp(controller: controller));
    await tester.pumpAndSettle();

    expect(controller.settings.darkMode, isFalse);
    await tester.tap(find.byTooltip('Switch to dark mode'));
    await tester.pumpAndSettle();

    expect(controller.settings.darkMode, isTrue);
    await tester.tap(find.byTooltip('Switch to light mode'));
    await tester.pumpAndSettle();

    expect(controller.settings.darkMode, isFalse);
  });

  testWidgets(
      'benchmark start honors typed duration without submitting the field', (
    WidgetTester tester,
  ) async {
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.binding.setSurfaceSize(const Size(1600, 1200));
    final controller = await _buildController();

    await tester.pumpWidget(_benchmarkApp(controller));
    await tester.pumpAndSettle();

    final durationField =
        find.byKey(const ValueKey('benchmark-field-durationSeconds'));
    await tester.scrollUntilVisible(
      durationField,
      220,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.enterText(durationField, '60');
    final startButton = find.widgetWithText(FilledButton, 'Start benchmark');
    await tester.scrollUntilVisible(
      startButton,
      -220,
      scrollable: find.byType(Scrollable).first,
    );
    tester.widget<FilledButton>(startButton).onPressed!();
    await tester.pumpAndSettle();

    expect(controller.benchmarkRun, isNotNull);
    expect(controller.capturedBenchmarkStartConfig?.durationSeconds, 60);
  });

  testWidgets('benchmark duration progress shows elapsed seconds of total', (
    WidgetTester tester,
  ) async {
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.binding.setSurfaceSize(const Size(1600, 1200));
    final controller = await _buildController();
    final run = BenchmarkRun(
      id: 'bench-test',
      config: controller.benchmarkDraft,
      status: 'running',
      processedCount: 12,
      startedAt: DateTime(2026, 3, 22, 16),
      averageLatencyMs: 3.4,
      throughputOpsPerSecond: 20,
      liveLog: const [],
      activeElapsedSeconds: 42,
    );
    controller.benchmarkRun = run;
    controller.selectedBenchmarkRunId = run.id;
    controller.benchmarkHistory = [run];
    controller.emitChange();

    await tester.pumpWidget(_benchmarkApp(controller));
    await tester.pumpAndSettle();

    expect(find.text('42s of 60s'), findsOneWidget);
  });

  testWidgets('browser and benchmark screens no longer expose debug switches', (
    WidgetTester tester,
  ) async {
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.binding.setSurfaceSize(const Size(1440, 1024));
    final controller = await _buildController();
    controller.inspectorTab = BrowserInspectorTab.tools;
    controller.emitChange();

    await tester.pumpWidget(
      _browserApp(
        controller,
        size: const Size(1440, 1024),
        compact: false,
      ),
    );
    await tester.pumpAndSettle();
    expect(_debugSwitchFinder(), findsNothing);

    await tester.pumpWidget(_benchmarkApp(controller));
    await tester.pumpAndSettle();
    expect(_debugSwitchFinder(), findsNothing);
  });

  testWidgets('profile selector remains in the header after summary removal', (
    WidgetTester tester,
  ) async {
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final controller = await _buildController();

    await tester.binding.setSurfaceSize(const Size(1440, 1024));
    await tester.pumpWidget(S3BrowserApp(controller: controller));
    await tester.pumpAndSettle();

    expect(find.text('Endpoint profile'), findsOneWidget);
    expect(find.text('Selected profile'), findsNothing);
    expect(find.text('http://localhost:9000'), findsNothing);

    await tester.binding.setSurfaceSize(const Size(960, 1280));
    await tester.pumpWidget(S3BrowserApp(controller: controller));
    await tester.pumpAndSettle();

    expect(find.text('Endpoint profile'), findsOneWidget);
    expect(find.text('Selected profile'), findsNothing);
    expect(find.text('http://localhost:9000'), findsNothing);
  });

  testWidgets('event log groups API traces into expandable cards', (
    WidgetTester tester,
  ) async {
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.binding.setSurfaceSize(const Size(1440, 1024));
    final controller = await _buildController();
    controller.activeTab = WorkspaceTab.eventLog;
    controller.eventLog = [
      _apiTraceEntry(
        phase: 'response',
        requestId: 'req-1',
        timestamp: DateTime(2026, 3, 22, 16, 0, 2),
        objectKey: 'backup-tool-v1.2.zip',
        latencyMs: 42,
      ),
      _apiTraceEntry(
        phase: 'send',
        requestId: 'req-1',
        timestamp: DateTime(2026, 3, 22, 16, 0, 1),
        objectKey: 'backup-tool-v1.2.zip',
      ),
      EventLogEntry(
        timestamp: DateTime(2026, 3, 22, 15, 59, 59),
        level: 'INFO',
        category: 'Settings',
        message: 'Updated application settings.',
      ),
    ];
    controller.emitChange();

    await tester.pumpWidget(S3BrowserApp(controller: controller));
    await tester.pumpAndSettle();

    expect(find.text('HeadObject'), findsOneWidget);
    expect(find.text('Updated application settings.'), findsOneWidget);
    expect(find.text('Raw event text'), findsNothing);

    await tester.tap(find.text('HeadObject'));
    await tester.pumpAndSettle();

    expect(find.text('Send'), findsOneWidget);
    expect(find.text('Response'), findsOneWidget);
    expect(find.text('Raw event text'), findsOneWidget);
  });

  testWidgets('events and debug inspector renders grouped trace cards', (
    WidgetTester tester,
  ) async {
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.binding.setSurfaceSize(const Size(1440, 1600));
    final controller = await _buildController();
    controller.inspectorTab = BrowserInspectorTab.eventsAndDebug;
    controller.selectedBucket = _bucket(0);
    controller.selectedObjectDetails = const ObjectDetails(
      key: 'backup-tool-v1.2.zip',
      metadata: {},
      headers: {},
      tags: {},
      debugEvents: [],
      apiCalls: [],
      debugLogExcerpt: ['Resolved endpoint'],
    );
    controller.eventLog = [
      _apiTraceEntry(
        phase: 'response',
        requestId: 'req-2',
        timestamp: DateTime(2026, 3, 22, 16, 10, 2),
        objectKey: 'backup-tool-v1.2.zip',
        latencyMs: 31,
      ),
      _apiTraceEntry(
        phase: 'send',
        requestId: 'req-2',
        timestamp: DateTime(2026, 3, 22, 16, 10, 1),
        objectKey: 'backup-tool-v1.2.zip',
      ),
    ];
    controller.emitChange();

    await tester.pumpWidget(
      _browserApp(
        controller,
        size: const Size(1440, 1600),
        compact: false,
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Trace log'), findsOneWidget);
    expect(find.text('HeadObject'), findsOneWidget);
    await tester.scrollUntilVisible(
      find.text('Debug excerpt'),
      240,
      scrollable: find
          .descendant(
            of: find.byKey(const ValueKey('events-and-debug')),
            matching: find.byType(Scrollable),
          )
          .first,
    );
    expect(find.text('Debug excerpt'), findsOneWidget);
  });

  testWidgets('phone shell uses bottom navigation instead of top tabs', (
    WidgetTester tester,
  ) async {
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.binding.setSurfaceSize(const Size(390, 844));
    final controller = await _buildController();

    await tester.pumpWidget(S3BrowserApp(controller: controller));
    await tester.pumpAndSettle();

    expect(find.byType(NavigationBar), findsOneWidget);
    expect(find.byType(SegmentedButton<WorkspaceTab>), findsNothing);
  });

  testWidgets('shell moves smoothly through tablet and desktop navigation', (
    WidgetTester tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    addTearDown(() {
      debugDefaultTargetPlatformOverride = null;
      tester.binding.setSurfaceSize(null);
    });
    final controller = await _buildController();

    await tester.binding.setSurfaceSize(const Size(900, 900));
    await tester.pumpWidget(S3BrowserApp(controller: controller));
    await tester.pumpAndSettle();
    expect(find.byType(NavigationBar), findsNothing);
    final tabletTabs = find.byKey(const ValueKey('workspace-top-tabs'));
    expect(tabletTabs, findsOneWidget);
    expect(
      tester.getSize(tabletTabs).width,
      greaterThan(850),
    );
    expect(
      tester
          .getSize(find.byKey(const ValueKey('workspace-navigation-rail')))
          .width,
      0,
    );

    await tester.binding.setSurfaceSize(const Size(1100, 900));
    await tester.pumpAndSettle();
    expect(
      tester
          .getSize(find.byKey(const ValueKey('workspace-navigation-rail')))
          .width,
      72,
    );

    await tester.binding.setSurfaceSize(const Size(1440, 900));
    await tester.pumpAndSettle();
    expect(
      tester
          .getSize(find.byKey(const ValueKey('workspace-navigation-rail')))
          .width,
      126,
    );
    debugDefaultTargetPlatformOverride = null;
  });
}
