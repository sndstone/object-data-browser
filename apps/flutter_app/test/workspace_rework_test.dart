import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:s3_browser_crossplat/app/s3_browser_app.dart';
import 'package:s3_browser_crossplat/benchmark/benchmark_workspace.dart';
import 'package:s3_browser_crossplat/models/domain_models.dart';
import 'package:s3_browser_crossplat/theme/app_motion.dart';
import 'package:s3_browser_crossplat/widgets/copyable_value.dart';
import 'improvements_test.dart' as fixture;

Future<void> viewport(WidgetTester tester, double width) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = Size(width, 900);
  await tester.binding.setSurfaceSize(Size(width, 900));
  addTearDown(() async {
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
    await tester.binding.setSurfaceSize(null);
  });
}

const summary = BenchmarkResultSummary(totalOperations: 100, operationsByType: {
  'PUT': 100
}, latencyPercentilesMs: {
  'p50': 10,
  'p99': 20
}, throughputSeries: [
  {'second': 1, 'opsPerSecond': 20},
  {'second': 2, 'opsPerSecond': 30},
], sizeLatencyBuckets: [], checksumStats: {}, detailMetrics: {
  'averageBytesPerSecond': 1048576
});

void main() {
  for (final width in [390.0, 1440.0]) {
    testWidgets('job filter changes preserve explicit selection at $width',
        (tester) async {
      await viewport(tester, width);
      final c =
          fixture.controller(fixture.TestingEngine(), fixture.Repository());
      addTearDown(c.dispose);
      await c.initialize();
      c.settings = c.settings.copyWith(enableAnimations: false);
      c.browserTasks = [
        BrowserTaskRecord(
            id: 'running',
            kind: BrowserTaskKind.transfer,
            label: 'Synthetic upload',
            status: 'running',
            startedAt: DateTime(2026),
            progress: .5,
            canCancel: true,
            totalBytes: 100,
            profileId: fixture.profile.id),
        BrowserTaskRecord(
            id: 'failed',
            kind: BrowserTaskKind.transfer,
            label: 'Synthetic download',
            status: 'failed',
            startedAt: DateTime(2026),
            progress: .2,
            outputLines: const ['Synthetic failure']),
      ];
      c.activeTab = WorkspaceTab.tasks;
      c.setTaskView(BrowserTaskView.all);
      c.clearBanner();
      await tester.pumpWidget(S3BrowserApp(controller: c));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Synthetic upload').first);
      await tester.pumpAndSettle();
      expect(find.widgetWithText(OutlinedButton, 'Cancel'), findsOneWidget);
      expect(find.widgetWithText(OutlinedButton, 'Resume'), findsNothing);
      c.setTaskView(BrowserTaskView.failed);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Synthetic download').first);
      await tester.pumpAndSettle();
      c.setTaskView(BrowserTaskView.all);
      await tester.pumpAndSettle();
      expect(c.selectedTaskId, 'failed');
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    });

    testWidgets(
        'finished benchmark exposes results and safe controls at $width',
        (tester) async {
      await viewport(tester, width);
      final c =
          fixture.controller(fixture.TestingEngine(), fixture.Repository());
      addTearDown(c.dispose);
      await c.initialize();
      c.settings = c.settings.copyWith(enableAnimations: false);
      final run = BenchmarkRun(
          id: 'finished',
          config: c.benchmarkDraft,
          status: 'completed',
          processedCount: 100,
          startedAt: DateTime(2026),
          averageLatencyMs: 10,
          throughputOpsPerSecond: 25,
          liveLog: const ['Completed'],
          resultSummary: summary);
      c.benchmarkRun = run;
      c.benchmarkHistory = [run];
      c.selectedBenchmarkRunId = run.id;
      c.activeTab = WorkspaceTab.benchmark;
      c.clearBanner();
      await tester.pumpWidget(
          MaterialApp(home: Scaffold(body: BenchmarkWorkspace(controller: c))));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('benchmark-section-results')),
          findsOneWidget);
      expect(find.widgetWithText(OutlinedButton, 'Pause'), findsNothing);
      expect(find.widgetWithText(OutlinedButton, 'Resume'), findsNothing);
      expect(find.widgetWithText(OutlinedButton, 'Stop'), findsNothing);
      expect(find.text('Average bandwidth · measured'), findsOneWidget);
      await c.pauseBenchmark();
      await c.resumeBenchmark();
      await c.stopBenchmark();
      expect(identical(c.benchmarkRun, run), isTrue);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }

  testWidgets(
      'copy appears over text without moving the row and copies literal value',
      (tester) async {
    final c = fixture.controller(fixture.TestingEngine(), fixture.Repository());
    addTearDown(c.dispose);
    String? copied;
    tester.binding.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') {
        copied = (call.arguments as Map)['text'] as String;
      }
      return null;
    });
    addTearDown(() => tester.binding.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null));
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: Center(
                child: SizedBox(
                    width: 360,
                    child: CopyableValue(
                        label: 'ETag',
                        value: 'synthetic-value',
                        controller: c))))));
    final copy = find.byTooltip('Copy ETag');
    final opacity =
        find.ancestor(of: copy, matching: find.byType(AnimatedOpacity)).first;
    expect(tester.widget<AnimatedOpacity>(opacity).opacity, 0);
    final before = tester.getRect(find.byType(CopyableValue));
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: Offset.zero);
    await mouse.moveTo(tester.getCenter(find.text('synthetic-value')));
    await tester.pumpAndSettle();
    expect(tester.widget<AnimatedOpacity>(opacity).opacity, 1);
    expect(tester.getRect(find.byType(CopyableValue)), before);
    await tester.tap(copy);
    expect(copied, 'synthetic-value');
    await mouse.removePointer();
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pumpAndSettle();
    expect(tester.widget<AnimatedOpacity>(opacity).opacity, 1,
        reason: 'Copy remains discoverable with a keyboard');
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('legacy empty notes do not imply unsaved profile edits',
      (tester) async {
    await viewport(tester, 1440);
    final c = fixture.controller(fixture.TestingEngine(), fixture.Repository());
    addTearDown(c.dispose);
    await c.initialize();
    c.settings = c.settings.copyWith(enableAnimations: false);
    c.activeTab = WorkspaceTab.settings;
    c.clearBanner();
    await tester.pumpWidget(S3BrowserApp(controller: c));
    await tester.pumpAndSettle();
    expect(find.text('Startup defaults'), findsOneWidget);
    expect(find.text('Unsaved edits'), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('benchmark view transitions follow reduced motion preference',
      (tester) async {
    final c = fixture.controller(fixture.TestingEngine(), fixture.Repository());
    addTearDown(c.dispose);
    c.settings = c.settings.copyWith(enableAnimations: true);
    for (final reduced in [false, true]) {
      await tester.pumpWidget(MaterialApp(
          home: MediaQuery(
              data: MediaQueryData(
                  size: const Size(800, 900), disableAnimations: reduced),
              child: BenchmarkWorkspace(controller: c))));
      await tester.pumpAndSettle();
      final switcher = find
          .descendant(
              of: find.byType(BenchmarkWorkspace),
              matching: find.byType(DirectionalSwitcher))
          .first;
      expect(tester.widget<DirectionalSwitcher>(switcher).duration,
          reduced ? Duration.zero : const Duration(milliseconds: 200));
      await tester.tap(find.text('History'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    }
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
