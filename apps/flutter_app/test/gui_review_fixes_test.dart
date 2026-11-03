import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:s3_browser_crossplat/app/s3_browser_app.dart';
import 'package:s3_browser_crossplat/controllers/app_controller.dart';
import 'package:s3_browser_crossplat/browser/browser_workspace_frame.dart';
import 'package:s3_browser_crossplat/theme/app_theme.dart';
import 'package:s3_browser_crossplat/logs/structured_log_list.dart';
import 'package:s3_browser_crossplat/models/domain_models.dart';
import 'package:s3_browser_crossplat/widgets/app_slider.dart';
import 'package:s3_browser_crossplat/widgets/compact_selector.dart';
import 'package:s3_browser_crossplat/widgets/setting_fields.dart';
import 'improvements_test.dart' as fixture;

class _SlowBucketEngine extends fixture.TestingEngine {
  Completer<void>? listing;
  @override
  Future<List<BucketSummary>> listBuckets(
      {required String engineId, required EndpointProfile profile}) async {
    await listing?.future;
    return super.listBuckets(engineId: engineId, profile: profile);
  }
}

Future<AppController> _app(WidgetTester tester,
    {double width = 1500,
    fixture.TestingEngine? engine,
    fixture.Repository? repository}) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = Size(width, 1100);
  await tester.binding.setSurfaceSize(Size(width, 1100));
  addTearDown(() async {
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
    await tester.binding.setSurfaceSize(null);
  });
  final c = fixture.controller(
      engine ?? fixture.TestingEngine(), repository ?? fixture.Repository());
  c.settings =
      c.settings.copyWith(enableAnimations: false, uiScalePercent: 100);
  await c.initialize();
  c.clearBanner();
  await tester.pumpWidget(S3BrowserApp(controller: c));
  await tester.pumpAndSettle();
  addTearDown(c.dispose);
  return c;
}

Future<void> _openProfile(WidgetTester tester, AppController c) async {
  await c.selectTab(WorkspaceTab.settings);
  await tester.pumpAndSettle();
  await tester.tap(find.text(c.profiles.first.name).last);
  await tester.pumpAndSettle();
}

Future<void> _editName(WidgetTester tester) async {
  final field = find.widgetWithText(TextField, 'Profile name');
  await tester.ensureVisible(field);
  await tester.enterText(field, 'Unsaved connection');
  await tester.pump();
}

Future<void> _browser(WidgetTester tester) async {
  await tester.tap(find.byTooltip('Buckets').first);
  await tester.pumpAndSettle();
}

EventLogEntry _trace(String id) => EventLogEntry(
    timestamp: DateTime(2026),
    level: 'API',
    source: 'api',
    category: 'Requests',
    message: 'Request $id',
    method: 'GET $id',
    requestId: id,
    tracePhase: 'send',
    traceBody: 'Payload $id');
Widget _logs(List<EventLogEntry> entries, {double scale = 1}) => MaterialApp(
    home: MediaQuery(
        data: MediaQueryData(textScaler: TextScaler.linear(scale)),
        child: Scaffold(
            body: StructuredLogList(
                entries: entries,
                textScalePercent: 100,
                emptyMessage: 'Empty'))));

void main() {
  testWidgets('bucket refresh updates cached browser before listing completes',
      (tester) async {
    final engine = _SlowBucketEngine();
    final c = await _app(tester, engine: engine);
    // Keep inherited theme/scaling stable so this specifically exercises the
    // frame cache rather than an unrelated inherited-widget invalidation.
    await tester.pumpWidget(MaterialApp(
        theme: AppTheme.light(scalePercent: 100, desktopCompact: true),
        home: Scaffold(
            body: AnimatedBuilder(
                animation: c,
                builder: (_, __) =>
                    BrowserWorkspaceFrame(controller: c, compact: false)))));
    await tester.pumpAndSettle();
    final before = c.busyVersion;
    engine.listing = Completer<void>();
    await tester.tap(find.byTooltip('Refresh buckets'));
    await tester.pump();
    expect(c.isBusy('refresh-buckets'), isTrue);
    expect(c.busyVersion, greaterThan(before));
    expect(find.byTooltip('Cancel bucket listing'), findsOneWidget);
    expect(find.byTooltip('Refresh buckets'), findsNothing);
    engine.listing!.complete();
    await tester.pumpAndSettle();
    expect(find.byTooltip('Refresh buckets'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });
  testWidgets('1050px inspector button and shortcut open tablet dialog',
      (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    final c = await _app(tester, width: 1050);
    final docked = c.settings.browserInspectorVisible;
    await tester.tap(find.byTooltip('Inspector'));
    await tester.pumpAndSettle();
    expect(find.byType(Dialog), findsOneWidget);
    expect(c.settings.browserInspectorVisible, docked);
    Navigator.of(tester.element(find.byType(Dialog))).pop();
    await tester.pumpAndSettle();
    await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyI);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
    await tester.pumpAndSettle();
    expect(find.byType(Dialog), findsOneWidget);
    expect(c.settings.browserInspectorVisible, docked);
    await tester.pumpWidget(const SizedBox());
    debugDefaultTargetPlatformOverride = null;
  });
  testWidgets('profile maximum attempts reports Draft and unsaved count',
      (tester) async {
    final c = await _app(tester);
    await _openProfile(tester, c);
    await tester.ensureVisible(find.text('Advanced transport'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Advanced transport'));
    await tester.pumpAndSettle();
    final field = find.widgetWithText(TextFormField, 'Maximum attempts');
    await tester.ensureVisible(field);
    await tester.enterText(field, '9');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pump();
    expect(find.descendant(of: field, matching: find.text('Draft')),
        findsOneWidget);
    expect(
        find.descendant(of: field, matching: find.text('Saved')), findsNothing);
    expect(find.text('1 unsaved changes'), findsOneWidget);
    expect(c.profiles.single.maxAttempts, isNot(9));
    expect(c.profileDrafts.values.single.maxAttempts, 9);
    await tester.pumpWidget(const SizedBox());
  });
  testWidgets(
      'leaving Settings commits focused numeric draft before confirming',
      (tester) async {
    final c = await _app(tester);
    await _openProfile(tester, c);
    await tester.ensureVisible(find.text('Advanced transport'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Advanced transport'));
    await tester.pumpAndSettle();
    final field = find.widgetWithText(TextFormField, 'Maximum attempts');
    await tester.ensureVisible(field);
    await tester.enterText(field, '9');
    await _browser(tester);
    expect(find.text('Unsaved profile changes'), findsOneWidget);
    expect(c.activeTab, WorkspaceTab.settings);
    expect(c.profileDrafts.values.single.maxAttempts, 9);
    await tester.tap(find.text('Keep editing'));
    await tester.pumpAndSettle();
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('setting feedback awaits persistence and rejects failed writes',
      (tester) async {
    var pending = Completer<bool>();
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: SettingTextField(
                label: 'Immediate setting',
                value: 'old',
                onCommit: (_) => pending.future))));
    await tester.enterText(find.byType(TextFormField), 'new');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pump();
    expect(find.text('Saved'), findsNothing);
    pending.complete(false);
    await tester.pump();
    expect(find.text('Saved'), findsNothing);
    expect(find.text('Could not save. Please retry.'), findsOneWidget);
    pending = Completer<bool>();
    await tester.showKeyboard(find.byType(TextFormField));
    await tester.testTextInput.receiveAction(TextInputAction.done);
    pending.complete(true);
    await tester.pump();
    expect(find.text('Saved'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });
  testWidgets('successful profile Save clears drafts after an immediate write',
      (tester) async {
    final c = await _app(tester);
    await _openProfile(tester, c);
    await _editName(tester);
    final save = find.widgetWithText(FilledButton, 'Save');
    await tester.ensureVisible(save);
    await tester.pumpAndSettle();
    await tester.tap(save);
    await tester.pumpAndSettle();
    expect(c.profiles.single.name, 'Unsaved connection');
    expect(c.profileDrafts, isEmpty);
    expect(find.text('Unsaved edits'), findsNothing);
    expect(find.text('1 unsaved changes'), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('profile drafts survive workspace replacement in memory',
      (tester) async {
    final c = await _app(tester);
    await _openProfile(tester, c);
    await _editName(tester);
    expect(c.profileDrafts.values.single.name, 'Unsaved connection');
    // Exercise ownership independently of the shell's confirmation guard.
    await tester.pumpWidget(const SizedBox());
    await c.selectTab(WorkspaceTab.browser);
    await tester.pumpWidget(S3BrowserApp(controller: c));
    await tester.pumpAndSettle();
    await _openProfile(tester, c);
    expect(
        tester
            .widget<TextField>(find.widgetWithText(TextField, 'Profile name'))
            .controller!
            .text,
        'Unsaved connection');
    await tester.pumpWidget(const SizedBox());
  });
  testWidgets('leaving Settings offers Discard Keep editing Save and saves',
      (tester) async {
    final repository = fixture.Repository();
    final c = await _app(tester, repository: repository);
    await _openProfile(tester, c);
    await _editName(tester);
    await _browser(tester);
    for (final label in ['Discard', 'Keep editing', 'Save']) {
      expect(
          find.descendant(
              of: find.byType(AlertDialog), matching: find.text(label)),
          findsOneWidget);
    }
    await tester.tap(find.text('Keep editing'));
    await tester.pumpAndSettle();
    expect(c.activeTab, WorkspaceTab.settings);
    expect(c.profileDrafts, isNotEmpty);
    await _browser(tester);
    await tester.tap(find.descendant(
        of: find.byType(AlertDialog), matching: find.text('Save')));
    await tester.pumpAndSettle();
    expect(c.activeTab, WorkspaceTab.browser);
    expect(repository.profiles.single.name, 'Unsaved connection');
    expect(c.profileDrafts, isEmpty);
    await _openProfile(tester, c);
    expect(
        tester
            .widget<TextField>(find.widgetWithText(TextField, 'Profile name'))
            .controller!
            .text,
        'Unsaved connection');
    await tester.pumpWidget(const SizedBox());
  });
  testWidgets('failed leave save retains draft and Discard clears it',
      (tester) async {
    final repository = fixture.Repository();
    final c = await _app(tester, repository: repository);
    await _openProfile(tester, c);
    await _editName(tester);
    repository.fail = true;
    await _browser(tester);
    await tester.tap(find.descendant(
        of: find.byType(AlertDialog), matching: find.text('Save')));
    await tester.pumpAndSettle();
    expect(c.activeTab, WorkspaceTab.settings);
    expect(c.profileDrafts.values.single.name, 'Unsaved connection');
    expect(find.text('Session only'), findsOneWidget);
    await _browser(tester);
    await tester.tap(find.text('Discard'));
    await tester.pumpAndSettle();
    expect(c.profiles.single.name, 'A');
    expect(c.activeTab, WorkspaceTab.browser);
    expect(c.profileDrafts, isEmpty);
    await tester.pumpWidget(const SizedBox());
  });
  testWidgets('log preference preserves OS text enlargement', (tester) async {
    await tester.pumpWidget(_logs([_trace('A')], scale: 1.5));
    final title = find.text('GET A');
    final fontSize = tester.widget<Text>(title).style!.fontSize!;
    expect(MediaQuery.textScalerOf(tester.element(title)).scale(fontSize),
        closeTo(fontSize * 1.5, .001));
  });
  testWidgets('expanded trace stays with request A when B is prepended',
      (tester) async {
    final semantics = tester.ensureSemantics();
    final a = _trace('A');
    await tester.pumpWidget(_logs([a]));
    await tester.tap(find.text('GET A'));
    await tester.pumpAndSettle();
    expect(tester.getSemantics(find.text('GET A')),
        isSemantics(isButton: true, isExpanded: true));
    await tester.pumpWidget(_logs([_trace('B'), a]));
    await tester.pumpAndSettle();
    expect(tester.getSemantics(find.text('GET A')),
        isSemantics(isButton: true, isExpanded: true));
    expect(tester.getSemantics(find.text('GET B')),
        isSemantics(isButton: true, hasExpandedState: true, isExpanded: false));
    semantics.dispose();
  });
  testWidgets('iOS phone selector and slider meet touch target guidelines',
      (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(390, 844);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final semantics = tester.ensureSemantics();
    var selected = 'Objects';
    var value = 50.0;
    await tester.pumpWidget(MaterialApp(
        theme: ThemeData(platform: TargetPlatform.iOS),
        home: Scaffold(
            body: Column(children: [
          CompactSelector<String>(
              dense: true,
              expand: true,
              selected: selected,
              onChanged: (v) => selected = v,
              options: const [
                CompactSelectorOption(value: 'Objects', label: 'Objects'),
                CompactSelectorOption(value: 'Inspector', label: 'Inspector')
              ]),
          AppRulerSlider(
              value: value,
              min: 0,
              max: 100,
              step: 10,
              semanticLabel: 'Log text size',
              onChanged: (v) => value = v)
        ]))));
    await expectLater(tester, meetsGuideline(androidTapTargetGuideline));
    await expectLater(tester, meetsGuideline(iOSTapTargetGuideline));
    final target = find.ancestor(
        of: find.text('Inspector'), matching: find.byType(InkWell));
    final rect = tester.getRect(target);
    expect(rect.height, greaterThanOrEqualTo(48));
    await tester.tapAt(Offset(rect.center.dx, rect.top + 1));
    expect(selected, 'Inspector');
    final slider = find.byType(Slider);
    expect(tester.getSize(slider).height, greaterThanOrEqualTo(48));
    final sliderRect = tester.getRect(slider);
    await tester.tapAt(
        Offset(sliderRect.left + sliderRect.width * .8, sliderRect.top + 1));
    expect(value, greaterThan(50));
    semantics.dispose();
    await tester.pumpWidget(const SizedBox());
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('declined Settings exit leaves no pending shortcut requests',
      (tester) async {
    final c = await _app(tester);
    await _openProfile(tester, c);
    await _editName(tester);
    c.requestInspectorToggle();
    await tester.pumpAndSettle();
    await tester.tap(find.text('Keep editing'));
    await tester.pumpAndSettle();
    expect(c.activeTab, WorkspaceTab.settings);
    expect(c.pendingInspectorToggle, isFalse);
    c.requestObjectSearchFocus();
    await tester.pumpAndSettle();
    await tester.tap(find.text('Keep editing'));
    await tester.pumpAndSettle();
    expect(c.pendingObjectSearchFocus, isFalse);
    c.openErrorDetails();
    await tester.pumpAndSettle();
    await tester.tap(find.text('Keep editing'));
    await tester.pumpAndSettle();
    expect(c.pendingEventLogFilter, isNull);
    expect(c.activeTab, WorkspaceTab.settings);
  });
}
