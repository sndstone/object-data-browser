import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:s3_browser_crossplat/app/s3_browser_app.dart';
import 'package:s3_browser_crossplat/benchmark/benchmark_workspace.dart';
import 'package:s3_browser_crossplat/browser/browser_workspace.dart';
import 'package:s3_browser_crossplat/models/domain_models.dart';
import 'package:s3_browser_crossplat/widgets/controller_content_frame.dart';
import 'improvements_test.dart' as fixture;
import 'workspace_rework_test.dart' show summary;

Future<void> viewport(WidgetTester tester, Size size) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = size;
  await tester.binding.setSurfaceSize(size);
  addTearDown(() async {
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
    await tester.binding.setSurfaceSize(null);
  });
}

void main() {
  testWidgets('inspector lazily builds only visible rows among 5000 events',
      (tester) async {
    await viewport(tester, const Size(1440, 900));
    final c = fixture.controller(fixture.TestingEngine(), fixture.Repository());
    addTearDown(c.dispose);
    await c.initialize();
    c.settings = c.settings
        .copyWith(enableAnimations: false, browserInspectorVisible: true);
    c.eventLog = List.generate(
        5000,
        (i) => EventLogEntry(
            timestamp: DateTime(2026).add(Duration(seconds: i)),
            level: 'INFO',
            category: 'Fixture',
            message: 'Lazy event $i',
            profileId: c.selectedProfile!.id,
            bucketName: c.selectedBucket!.name));
    c.setInspectorTab(BrowserInspectorTab.eventsAndDebug);
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(body: BrowserWorkspace(controller: c, compact: false))));
    await tester.pumpAndSettle();
    final scroll = find.byKey(const ValueKey('events-and-debug'));
    expect(tester.widget(scroll), isA<CustomScrollView>());
    int rowCount() => find
        .descendant(
            of: scroll,
            matching: find.byWidgetPredicate((w) =>
                w is SelectableText &&
                (w.data ?? '').startsWith('Lazy event ')))
        .evaluate()
        .length;
    expect(rowCount(), inExclusiveRange(0, 100));
    expect(find.text('Lazy event 4999'), findsNothing);
    await tester.drag(scroll, const Offset(0, -1000));
    await tester.pumpAndSettle();
    expect(rowCount(), inExclusiveRange(0, 100));
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  for (final modal in ['inspector', 'benchmark', 'connection']) {
    testWidgets(
        '$modal modal ignores unrelated notifications and rebuilds relevant data',
        (tester) async {
      await viewport(
          tester,
          modal == 'connection'
              ? const Size(390, 844)
              : modal == 'benchmark'
                  ? const Size(1440, 1100)
                  : const Size(900, 900));
      final c =
          fixture.controller(fixture.TestingEngine(), fixture.Repository());
      addTearDown(c.dispose);
      await c.initialize();
      c.settings = c.settings.copyWith(enableAnimations: false);
      if (modal == 'benchmark') {
        final run = BenchmarkRun(
            id: 'finished',
            config: c.benchmarkDraft,
            status: 'completed',
            processedCount: 100,
            startedAt: DateTime(2026),
            averageLatencyMs: 10,
            throughputOpsPerSecond: 25,
            liveLog: const [],
            resultSummary: summary);
        c.benchmarkRun = run;
        c.benchmarkHistory = [run];
        c.selectedBenchmarkRunId = run.id;
        await tester.pumpWidget(MaterialApp(
            home: Scaffold(body: BenchmarkWorkspace(controller: c))));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Open detailed view'));
      } else {
        await tester.pumpWidget(S3BrowserApp(controller: c));
        await tester.pumpAndSettle();
        c.clearBanner();
        await tester.pumpAndSettle();
        if (modal == 'inspector') {
          await c.requestInspectorToggle();
        } else {
          await tester
              .tap(find.widgetWithIcon(TextButton, Icons.cloud_outlined));
        }
      }
      await tester.pumpAndSettle();
      expect(find.byType(ControllerContentFrame), findsOneWidget);
      final content = tester.element(find.byType(ControllerContentFrame));
      var builds = 0;
      final previous = debugOnRebuildDirtyWidget;
      debugOnRebuildDirtyWidget = (element, builtOnce) {
        previous?.call(element, builtOnce);
        if (identical(element, content)) builds++;
      };
      addTearDown(() => debugOnRebuildDirtyWidget = previous);
      c.clearBanner();
      await tester.pumpAndSettle();
      expect(builds, 0,
          reason: 'unrelated notification must preserve modal content');
      switch (modal) {
        case 'inspector':
          c.setInspectorTab(BrowserInspectorTab.eventsAndDebug);
        case 'benchmark':
          c.benchmarkRun = c.benchmarkRun!.copyWith(processedCount: 101);
          c.clearBanner();
        case 'connection':
          c.selectedProfile =
              c.selectedProfile!.copyWith(name: 'Updated profile');
          c.clearBanner();
      }
      await tester.pumpAndSettle();
      expect(builds, greaterThan(0), reason: 'displayed data changed');
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }
}
