import 'package:flutter/material.dart';
import 'dart:ui' show Tristate, ImageByteFormat;
import 'dart:io';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:s3_browser_crossplat/app/s3_browser_app.dart';
import 'package:s3_browser_crossplat/browser/json_editor_dialog.dart';
import 'package:s3_browser_crossplat/browser/tag_editor_dialog.dart';
import 'package:s3_browser_crossplat/controllers/app_controller.dart';
import 'package:s3_browser_crossplat/models/domain_models.dart';
import 'package:s3_browser_crossplat/services/mock_engine_service.dart';
import 'package:s3_browser_crossplat/services/engine_service.dart';
import 'package:s3_browser_crossplat/utils/format.dart';
import 'package:s3_browser_crossplat/widgets/copyable_value.dart';
import 'package:s3_browser_crossplat/widgets/danger_button.dart';
import 'package:s3_browser_crossplat/widgets/setting_fields.dart';
import 'package:s3_browser_crossplat/widgets/compact_selector.dart';

class ProgressEngine extends MockEngineService {
  TransferJobCallback? sink;
  int attempts = 0;
  final List<(List<String>, String)> requests = [];
  @override
  void setTransferSink(TransferJobCallback? callback) {
    sink = callback;
    super.setTransferSink(callback);
  }

  @override
  Future<TransferJob> startDownload(
      {required String engineId,
      required EndpointProfile profile,
      required String bucketName,
      required List<String> keys,
      required String destinationPath,
      String conflictPolicy = 'keepBoth',
      required int multipartThresholdMiB,
      required int multipartChunkMiB}) async {
    requests.add((List.of(keys), destinationPath));
    return TransferJob(
        id: 'retry-${++attempts}',
        label: 'Download',
        direction: 'download',
        progress: .2,
        status: 'failed',
        bytesTransferred: 2000,
        totalBytes: 10000);
  }
}

class GuiController extends AppController {
  GuiController({bool profile = true, MockEngineService? engine})
      : super(
            engineService: engine ?? MockEngineService(),
            initialSettings: AppSettings.fromJson({
              'defaultEngineId': 'rust',
              'enableAnimations': false,
              'uiScalePercent': 100,
              'browserInspectorLayout': 'right'
            }),
            initialProfiles: profile
                ? const [
                    EndpointProfile(
                        id: 'gui',
                        name: 'GUI test',
                        endpointUrl: 'http://localhost:9000',
                        region: 'us-east-1',
                        accessKey: 'test',
                        secretKey: 'secret',
                        pathStyle: true,
                        verifyTls: false)
                  ]
                : const []);
  int deletes = 0, deleteAll = 0;
  @override
  Future<void> deleteObjectKeys(List<String> keys) async {
    deletes += keys.length;
  }

  @override
  Future<void> runDeleteAllTool() async {
    deleteAll++;
  }

  void changed() => notifyListeners();
}

Future<GuiController> frame(WidgetTester tester,
    {double width = 1500, bool profile = true}) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = Size(width, 1100);
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.binding.setSurfaceSize(Size(width, 1100));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  final c = GuiController(profile: profile);
  await c.initialize();
  await tester.pumpWidget(S3BrowserApp(controller: c));
  await tester.pumpAndSettle();
  addTearDown(c.dispose);
  return c;
}

Future<void> closeFrame(WidgetTester tester) async =>
    tester.pumpWidget(const SizedBox());
void main() {
  test('transfer rates, exact retry destination and cleanup', () async {
    final engine = ProgressEngine();
    final c = GuiController(engine: engine);
    await c.initialize();
    await c.setSelectedObject(c.objects.firstWhere((o) => !o.isFolder));
    await c.startSampleDownload();
    final original =
        c.browserTasks.firstWhere((t) => t.kind == BrowserTaskKind.transfer);
    expect(c.canRetryTask(original), isTrue);
    c.settings = c.settings.copyWith(downloadPath: '/different');
    await c.retryTask(original);
    expect(engine.requests.length, 2);
    expect(engine.requests.last.$1, engine.requests.first.$1);
    expect(engine.requests.last.$2, engine.requests.first.$2);
    var job = const TransferJob(
        id: 'rate',
        label: 'Rate test',
        direction: 'download',
        progress: .1,
        status: 'running',
        bytesTransferred: 1000,
        totalBytes: 100000);
    engine.sink!(job);
    await Future<void>.delayed(const Duration(milliseconds: 20));
    job = job.copyWith(bytesTransferred: 5000, progress: .05);
    engine.sink!(job);
    final rate = c.browserTasks.firstWhere((t) => t.id == 'rate');
    expect(rate.bytesPerSecond, greaterThan(0));
    expect(rate.eta, isNotNull);
    c.clearFinishedTasks();
    expect(c.browserTasks.map((t) => t.id), contains('rate'));
    expect(c.browserTasks.any((t) => t.isFailedLike), isFalse);
    c.dispose();
  });
  test('shared formatters use binary units and unambiguous dates', () {
    expect(formatBytes(1024), '1.0 KiB');
    expect(formatBytes(1099511627776), '1.0 TiB');
    expect(formatDateTime(DateTime(2026, 3, 7, 9, 2)), '2026-03-07 09:02');
    expect(formatRelative(DateTime(2026, 3, 7), now: DateTime(2026, 3, 9)),
        '2 days ago');
  });
  testWidgets('version delete confirms and cancel cannot dispatch',
      (tester) async {
    final c = await frame(tester);
    await c.setSelectedObject(c.objects.firstWhere((o) => !o.isFolder));
    c.setInspectorTab(BrowserInspectorTab.versions);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Delete selected'));
    await tester.pumpAndSettle();
    expect(c.deletes, 0);
    expect(find.byType(DangerButton), findsOneWidget);
    final button = tester.widget<FilledButton>(find.descendant(
        of: find.byType(DangerButton), matching: find.byType(FilledButton)));
    final context = tester.element(find.byType(DangerButton));
    expect(button.style!.backgroundColor!.resolve({}),
        Theme.of(context).colorScheme.error);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(c.deletes, 0);
    await tester.tap(find.text('Delete selected'));
    await tester.pumpAndSettle();
    await tester.tap(find.byType(DangerButton));
    await tester.pumpAndSettle();
    expect(c.deletes, 1);
    await closeFrame(tester);
  });
  testWidgets('delete all requires matching bucket and rejects changed context',
      (tester) async {
    final c = await frame(tester);
    c.setInspectorTab(BrowserInspectorTab.tools);
    await tester.pumpAndSettle();
    final run = find.text('Run delete all');
    await tester.scrollUntilVisible(run, 400,
        scrollable: find
            .descendant(
                of: find.byKey(const ValueKey('tools')),
                matching: find.byType(Scrollable))
            .first);
    await tester.tap(run);
    await tester.pumpAndSettle();
    expect(tester.widget<DangerButton>(find.byType(DangerButton)).onPressed,
        isNull);
    await tester.enterText(
        find.widgetWithText(TextField, 'Bucket name confirmation'), 'wrong');
    await tester.pump();
    expect(tester.widget<DangerButton>(find.byType(DangerButton)).onPressed,
        isNull);
    await tester.enterText(
        find.widgetWithText(TextField, 'Bucket name confirmation'),
        ' ${c.deleteAllConfig.bucketName} ');
    await tester.pump();
    expect(tester.widget<DangerButton>(find.byType(DangerButton)).onPressed,
        isNotNull);
    c.activeEngineId = 'go';
    await tester.tap(find.byType(DangerButton));
    await tester.pumpAndSettle();
    expect(c.deleteAll, 0);
    await closeFrame(tester);
  });
  testWidgets('error banner persists and Details filters Event Log',
      (tester) async {
    final c = await frame(tester);
    c.showBannerMessage('Connection refused', severity: BannerSeverity.error);
    await tester.pump();
    await tester.pump(const Duration(seconds: 10));
    expect(find.text('Connection refused'), findsOneWidget);
    await tester.tap(find.text('Details'));
    await tester.pumpAndSettle();
    expect(c.activeTab, WorkspaceTab.eventLog);
    expect(
        tester
            .widget<CompactSelector<String>>(
                find.byType(CompactSelector<String>))
            .selected,
        'ERROR');
    await closeFrame(tester);
  });
  testWidgets(
      'single search debounces and shortcut focuses from another workspace',
      (tester) async {
    final c = await frame(tester);
    c.setObjectFilterMode(BrowserFilterMode.text);
    await tester.pump();
    final search = find.byKey(const ValueKey('object-search'));
    final before = c.eventLog
        .where((e) => e.message.startsWith('Updated object filter'))
        .length;
    await tester.enterText(search, 'p');
    await tester.pump(const Duration(milliseconds: 60));
    await tester.enterText(search, 'ph');
    await tester.pump(const Duration(milliseconds: 60));
    await tester.enterText(search, 'photo');
    await tester.pump(const Duration(milliseconds: 251));
    await tester.pump();
    expect(
        c.eventLog
            .where((e) => e.message.startsWith('Updated object filter'))
            .length,
        before + 1);
    expect(
        tester
            .widget<TextField>(
                find.descendant(of: search, matching: find.byType(TextField)))
            .focusNode!
            .hasFocus,
        isTrue);
    c.selectTab(WorkspaceTab.tasks);
    await tester.pumpAndSettle();
    final platform =
        Theme.of(tester.element(find.byType(Scaffold).first)).platform;
    final modifier = platform == TargetPlatform.macOS
        ? LogicalKeyboardKey.metaLeft
        : LogicalKeyboardKey.controlLeft;
    await tester.sendKeyDownEvent(modifier);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyK);
    await tester.sendKeyUpEvent(modifier);
    await tester.pumpAndSettle();
    expect(c.activeTab, WorkspaceTab.browser);
    expect(
        tester
            .widget<TextField>(
                find.descendant(of: search, matching: find.byType(TextField)))
            .focusNode!
            .hasFocus,
        isTrue);
    await closeFrame(tester);
  });
  testWidgets('changing search mode cancels a pending query', (tester) async {
    final c = await frame(tester);
    c.setObjectFilterMode(BrowserFilterMode.text);
    await tester.pump();
    final initialPrefix = c.currentPrefix;
    await tester.enterText(
        find.byKey(const ValueKey('object-search')), 'uncommitted');
    c.setObjectFilterMode(BrowserFilterMode.prefix);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(c.currentPrefix, initialPrefix);
    expect(c.objectFilterValue, initialPrefix);
    await closeFrame(tester);
  });
  testWidgets('number field commits on blur and rejects out of range',
      (tester) async {
    var saved = 8;
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: Column(children: [
      SettingNumberField(
          label: 'Workers',
          value: 8,
          min: 1,
          max: 64,
          onCommit: (v) => saved = v),
      const TextField(decoration: InputDecoration(labelText: 'Other'))
    ]))));
    await tester.enterText(find.widgetWithText(TextFormField, 'Workers'), '12');
    await tester.tap(find.widgetWithText(TextField, 'Other'));
    await tester.pump();
    expect(saved, 12);
    await tester.enterText(find.widgetWithText(TextFormField, 'Workers'), '0');
    await tester.tap(find.widgetWithText(TextField, 'Other'));
    await tester.pump();
    expect(saved, 12);
    expect(find.text('Enter a value from 1 to 64.'), findsOneWidget);
    await tester.tap(find.widgetWithText(TextFormField, 'Workers'));
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    expect(find.text('12'), findsOneWidget);
    await closeFrame(tester);
  });
  testWidgets(
      'JSON validates positions and formats; duplicate tags cannot save',
      (tester) async {
    await tester.pumpWidget(const MaterialApp(
        home: JsonEditorDialog(title: 'Policy', initialValue: '{"a": ]')));
    expect(
        tester
            .widget<FilledButton>(find.widgetWithText(FilledButton, 'Save'))
            .onPressed,
        isNull);
    expect(find.textContaining('Line 1, column'), findsOneWidget);
    await tester.enterText(find.byType(TextField), '{"a":1}');
    await tester.pump();
    await tester.tap(find.text('Format'));
    await tester.pump();
    expect(find.text('{\n  "a": 1\n}'), findsOneWidget);
    await tester.pumpWidget(
        const MaterialApp(home: TagEditorDialog(initialTags: {'name': 'one'})));
    await tester.tap(find.text('Add tag'));
    await tester.pump();
    await tester.enterText(find.widgetWithText(TextField, 'Key').last, 'name');
    await tester.pump();
    expect(find.text('Duplicate tag key: name'), findsOneWidget);
    expect(
        tester
            .widget<FilledButton>(find.widgetWithText(FilledButton, 'Save'))
            .onPressed,
        isNull);
    await closeFrame(tester);
  });
  testWidgets('copy preserves exact payload', (tester) async {
    final c = GuiController();
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
        home: CopyableValue(
            label: 'Key', value: 'folder/a b+é.txt', controller: c)));
    await tester.tap(find.byTooltip('Copy Key'));
    await tester.pump();
    expect(copied, 'folder/a b+é.txt');
    expect(c.bannerSeverity, BannerSeverity.success);
    await closeFrame(tester);
    c.dispose();
  });
  testWidgets(
      'profile deletion confirms, reveal times out, drafts survive sections',
      (tester) async {
    final c = await frame(tester);
    c.selectTab(WorkspaceTab.settings);
    await tester.pumpAndSettle();
    await tester.tap(find.text('GUI test').last);
    await tester.pumpAndSettle();
    final field = find.widgetWithText(TextField, 'Secret key');
    await tester.ensureVisible(field);
    await tester.pumpAndSettle();
    expect(tester.widget<TextField>(field).obscureText, isTrue);
    await tester.tap(find.byTooltip('Reveal secret'));
    await tester.pump();
    expect(tester.widget<TextField>(field).obscureText, isFalse);
    await tester.pump(const Duration(seconds: 31));
    expect(tester.widget<TextField>(field).obscureText, isTrue);
    final name = find.widgetWithText(TextField, 'Profile name');
    await tester.ensureVisible(name);
    await tester.enterText(name, 'Unsaved connection');
    await tester.pump();
    expect(find.text('Unsaved edits'), findsOneWidget);
    await tester.tap(find.widgetWithText(ListTile, 'Appearance'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(ListTile, 'Connections'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('GUI test').last);
    await tester.pumpAndSettle();
    expect(
        tester
            .widget<TextField>(find.widgetWithText(TextField, 'Profile name'))
            .controller!
            .text,
        'Unsaved connection');
    final delete = find.text('Delete…');
    await tester.ensureVisible(delete);
    await tester.pumpAndSettle();
    await tester.ensureVisible(delete);
    await tester.pumpAndSettle();
    await tester.tap(delete);
    await tester.pumpAndSettle();
    expect(c.profiles.length, 1);
    expect(find.textContaining('saved credentials'), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(c.profiles.length, 1);
    await tester.tap(delete);
    await tester.pumpAndSettle();
    await tester.tap(find.byType(DangerButton));
    await tester.pumpAndSettle();
    expect(c.profiles, isEmpty);
    await closeFrame(tester);
  });
  testWidgets('1060 pixel settings shows exactly one navigator',
      (tester) async {
    final c = await frame(tester, width: 1060);
    c.selectTab(WorkspaceTab.settings);
    await tester.pumpAndSettle();
    final side = find.widgetWithText(ListTile, 'Connections').evaluate().length;
    final dropdown = find.text('Settings section').evaluate().length;
    expect(side + dropdown, 1);
    await closeFrame(tester);
  });
  testWidgets(
      'phone inspector scrolls and connection opens a sheet at 150 percent',
      (tester) async {
    final c = await frame(tester, width: 390);
    c.settings = c.settings.copyWith(uiScalePercent: 150);
    c.changed();
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(Icons.cloud_outlined));
    await tester.pumpAndSettle();
    expect(find.byType(BottomSheet), findsOneWidget);
    expect(find.text('Backend engine'), findsOneWidget);
    await tester.tap(find.text('Done'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Inspect'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Diagnostics'));
    await tester.pumpAndSettle();
    final run = find.text('Run delete all');
    await tester.scrollUntilVisible(run, 300,
        scrollable: find
            .descendant(
                of: find.byKey(const ValueKey('tools')),
                matching: find.byType(Scrollable))
            .first);
    expect(run, findsOneWidget);
    expect(tester.takeException(), isNull);
    await closeFrame(tester);
  });
  testWidgets(
      'empty connection leads to Settings and navigation reports selection',
      (tester) async {
    final c = await frame(tester, profile: false);
    final semantics = tester.ensureSemantics();
    final selected = find.bySemanticsLabel(RegExp(r'Buckets, tab 1 of [45]'));
    expect(selected, findsWidgets);
    expect(
        tester
            .getSemantics(selected.first)
            .getSemanticsData()
            .flagsCollection
            .isSelected,
        Tristate.isTrue);
    await tester.tap(find.text('Create profile').first);
    await tester.pumpAndSettle();
    expect(c.activeTab, WorkspaceTab.settings);
    semantics.dispose();
    await closeFrame(tester);
  });
  testWidgets('capture GUI review images', (tester) async {
    final icons = FontLoader('MaterialIcons')
      ..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'));
    await icons.load();
    for (final family in ['Inter', 'Sora']) {
      final loader = FontLoader(family)
        ..addFont(rootBundle.load('assets/fonts/$family.ttf'));
      await loader.load();
    }
    final c = await frame(tester);
    final boundaryKey = GlobalKey();
    await tester.pumpWidget(
        RepaintBoundary(key: boundaryKey, child: S3BrowserApp(controller: c)));
    await tester.pumpAndSettle();
    for (final (name, width, dark) in [
      ('desktop-light', 1500.0, false),
      ('desktop-dark', 1500.0, true),
      ('phone', 390.0, false)
    ]) {
      tester.view.physicalSize = Size(width, width < 700 ? 844 : 1100);
      await tester.binding
          .setSurfaceSize(Size(width, width < 700 ? 844 : 1100));
      c.settings = c.settings
          .copyWith(darkMode: dark, uiScalePercent: width < 700 ? 150 : 100);
      c.clearBanner();
      c.changed();
      await tester.pumpAndSettle();
      await tester.runAsync(() async {
        final image = await (boundaryKey.currentContext!.findRenderObject()
                as RenderRepaintBoundary)
            .toImage();
        final bytes = await image.toByteData(format: ImageByteFormat.png);
        final file = File('../../.tmp/gui-226/$name.png');
        await file.parent.create(recursive: true);
        await file.writeAsBytes(bytes!.buffer.asUint8List());
        image.dispose();
      });
    }
    await closeFrame(tester);
  }, skip: Platform.environment['GUI_CAPTURE'] != '1');
  for (final width in [700.0, 1000.0, 1360.0, 1500.0]) {
    for (final dark in [false, true]) {
      testWidgets('browser layout $width dark=$dark at 130 percent',
          (tester) async {
        final c = await frame(tester, width: width);
        c.settings = c.settings.copyWith(darkMode: dark, uiScalePercent: 130);
        c.changed();
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        for (final tab in [
          BrowserInspectorTab.objectDetails,
          BrowserInspectorTab.bucketAdmin,
          BrowserInspectorTab.tools
        ]) {
          c.setInspectorTab(tab);
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull);
        }
        await closeFrame(tester);
      });
    }
  }
}
