import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:s3_browser_crossplat/models/domain_models.dart';
import 'package:s3_browser_crossplat/tasks/tasks_workspace.dart';
import 'package:s3_browser_crossplat/theme/app_motion.dart';
import 'improvements_test.dart' as fixture;

void main() {
  testWidgets('Jobs filters push through one switcher, empty or not',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(1200, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final c = fixture.controller(fixture.TestingEngine(), fixture.Repository());
    addTearDown(c.dispose);
    c.settings = c.settings.copyWith(enableAnimations: true);
    final started = DateTime(2026, 11, 15, 14);
    c.browserTasks = [
      for (final id in ['a', 'b'])
        BrowserTaskRecord(
            id: id,
            kind: BrowserTaskKind.transfer,
            label: 'Upload $id',
            status: 'completed',
            startedAt: started,
            completedAt: started,
            progress: 1),
    ];
    c.selectedTaskId = 'a';
    c.taskView = BrowserTaskView.all;
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: AnimatedBuilder(
                animation: c,
                builder: (_, __) => TasksWorkspace(controller: c)))));
    await tester.pumpAndSettle();
    final allList = find.byKey(const ValueKey('jobs-list-all'));
    final settled = tester.getRect(allList);

    DirectionalSwitcher filterSwitcher() => tester
        .widget<DirectionalSwitcher>(find.byType(DirectionalSwitcher).first);
    expect(filterSwitcher().replaceContent, isTrue);
    expect(filterSwitcher().axis, Axis.horizontal);
    expect(filterSwitcher().duration, const Duration(milliseconds: 300));

    // All -> Running, with nothing running: the list must leave on stage
    // while the empty state enters, instead of being replaced at once.
    c.setTaskView(BrowserTaskView.running);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 120));
    expect(find.byType(DirectionalSwitcher), findsWidgets);
    expect(allList, findsOneWidget);
    expect(find.text('No running tasks.'), findsOneWidget);
    // Running sits before All, so the outgoing list travels to the right.
    expect(tester.getRect(allList).left, greaterThan(settled.left));
    await tester.pumpAndSettle();
    expect(allList, findsNothing);
    expect(find.text('No running tasks.'), findsOneWidget);

    // Empty -> populated pushes back the other way.
    c.setTaskView(BrowserTaskView.all);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 120));
    expect(find.text('No running tasks.'), findsOneWidget);
    expect(tester.getRect(allList).left, greaterThan(settled.left));
    await tester.pumpAndSettle();
    expect(find.text('No running tasks.'), findsNothing);
    expect(tester.getRect(allList), settled);

    // With motion disabled the destination is replaced immediately.
    c.settings = c.settings.copyWith(enableAnimations: false);
    c.setTaskView(BrowserTaskView.running);
    await tester.pump();
    expect(filterSwitcher().duration, Duration.zero);
    expect(allList, findsNothing);
    expect(find.text('No running tasks.'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
