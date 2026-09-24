import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:s3_browser_crossplat/app/s3_browser_app.dart';
import 'package:s3_browser_crossplat/models/domain_models.dart';
import 'package:s3_browser_crossplat/utils/format.dart';
import 'improvements_test.dart' as fixture;

Future<void> _pumpApp(WidgetTester tester, dynamic controller,
    {Size size = const Size(1440, 900)}) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = size;
  await tester.binding.setSurfaceSize(size);
  addTearDown(() async {
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
    await tester.binding.setSurfaceSize(null);
  });
  await tester.pumpWidget(S3BrowserApp(controller: controller));
  await tester.pumpAndSettle();
}

void main() {
  group('inspector layout migration', () {
    test('settings without a layout default to the right-docked inspector', () {
      expect(AppSettings.fromJson({}).browserInspectorLayout,
          BrowserInspectorLayout.right);
    });

    test('the old implicit bottom default moves to the right once', () {
      expect(
          AppSettings.fromJson({'browserInspectorLayout': 'bottom'})
              .browserInspectorLayout,
          BrowserInspectorLayout.right);
    });

    test('an explicit bottom choice saved after the change is kept', () {
      final saved = AppSettings.fromJson({})
          .copyWith(browserInspectorLayout: BrowserInspectorLayout.bottom)
          .toJson();
      expect(AppSettings.fromJson(saved).browserInspectorLayout,
          BrowserInspectorLayout.bottom);
    });
  });

  test('formatCount groups thousands', () {
    expect(formatCount(0), '0');
    expect(formatCount(94), '94');
    expect(formatCount(1284), '1,284');
    expect(formatCount(1234567), '1,234,567');
    expect(formatCount(-1000), '-1,000');
  });

  test('selecting an object does not show a generic completion banner',
      () async {
    final c = fixture.controller(fixture.TestingEngine(), fixture.Repository());
    addTearDown(c.dispose);
    await c.initialize();
    c.clearBanner();
    final file = c.objects.firstWhere((o) => !o.isFolder);
    await c.setSelectedObject(file);
    expect(c.bannerMessage, isNull);
  });

  test('opening Jobs on an empty filter falls back to a non-empty view',
      () async {
    final c = fixture.controller(fixture.TestingEngine(), fixture.Repository());
    addTearDown(c.dispose);
    await c.initialize();
    expect(c.tasksForView(BrowserTaskView.running), isEmpty);
    expect(c.tasksForView(BrowserTaskView.all), isNotEmpty);
    c.setTaskView(BrowserTaskView.running);
    c.selectTab(WorkspaceTab.tasks);
    expect(c.taskView, BrowserTaskView.all);
  });

  testWidgets('wide browser docks the inspector right and aligns columns',
      (tester) async {
    final c = fixture.controller(fixture.TestingEngine(), fixture.Repository());
    await c.initialize();
    c.clearBanner();
    await _pumpApp(tester, c);

    final list = find.byKey(const ValueKey('object-panel-list'));
    // Rows in display order, so both are on screen.
    final folder = c.pagedVisibleObjects.firstWhere((o) => o.isFolder);
    final file = c.pagedVisibleObjects.firstWhere((o) => !o.isFolder);
    expect(tester.getTopLeft(find.text(folder.name)).dx,
        tester.getTopLeft(find.text(file.name)).dx,
        reason: 'folder and file names start in the same column');

    final listTop = tester.getTopLeft(list).dy;
    await tester.tap(find.text(file.name));
    await tester.pumpAndSettle();
    expect(c.selectedObject?.key, file.key);
    expect(tester.getTopLeft(list).dy, listTop,
        reason: 'selection actions replace toolbar actions in place');
    expect(find.text('Details'), findsOneWidget);
    expect(tester.getTopLeft(find.text('Details')).dx,
        greaterThan(tester.getTopRight(list).dx),
        reason: 'inspector sits to the right of the object list');

    c.toggleObjectSelection(file);
    await tester.pumpAndSettle();
    expect(find.textContaining('1 selected'), findsOneWidget);
    expect(tester.getTopLeft(list).dy, listTop);
    expect(tester.takeException(), isNull);

    await tester.pumpWidget(const SizedBox.shrink());
    c.dispose();
  });
}
