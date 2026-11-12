import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:s3_browser_crossplat/app/s3_browser_app.dart';
import 'package:s3_browser_crossplat/browser/create_bucket_dialog.dart';
import 'package:s3_browser_crossplat/browser/json_editor_dialog.dart';
import 'package:s3_browser_crossplat/browser/rename_dialog.dart';
import 'package:s3_browser_crossplat/browser/tag_editor_dialog.dart';
import 'package:s3_browser_crossplat/controllers/app_controller.dart';
import 'package:s3_browser_crossplat/models/domain_models.dart';
import 'package:s3_browser_crossplat/services/mock_engine_service.dart';
import 'package:s3_browser_crossplat/settings/settings_workspace.dart';

void main() {
  for (final size in [const Size(390, 844), const Size(844, 390)]) {
    testWidgets('bucket form fits keyboard at $size', (tester) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      tester.view.viewInsets =
          FakeViewPadding(bottom: size.height > 500 ? 300 : 150);
      addTearDown(tester.view.reset);
      await tester.pumpWidget(MaterialApp(
          builder: (context, child) => MediaQuery(
              data: MediaQuery.of(context)
                  .copyWith(textScaler: const TextScaler.linear(1.5)),
              child: child!),
          home: CreateBucketDialog(
              provider: EndpointProfileType.awsS3,
              onSave: (_, __, ___) async {})));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      final create = find.widgetWithText(FilledButton, 'Create');
      expect(tester.getBottomRight(create).dy,
          lessThanOrEqualTo(size.height - tester.view.viewInsets.bottom));
    });
  }

  testWidgets('failed JSON save retains draft and dirty dismissal asks first',
      (tester) async {
    await tester.pumpWidget(MaterialApp(
        home: Builder(
            builder: (context) => Scaffold(
                body: TextButton(
                    onPressed: () => showDialog<String>(
                        context: context,
                        builder: (_) => JsonEditorDialog(
                            title: 'Policy',
                            initialValue: '{}',
                            onSave: (_) async =>
                                throw StateError('fixture permission denied'))),
                    child: const Text('Open'))))));
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), '{"draft":true}');
    await tester.tap(find.widgetWithText(FilledButton, 'Save'));
    await tester.pumpAndSettle();
    expect(find.textContaining('fixture permission denied'), findsOneWidget);
    expect(tester.widget<TextField>(find.byType(TextField)).controller!.text,
        '{"draft":true}');
    await tester.tap(find.widgetWithText(TextButton, 'Cancel'));
    await tester.pumpAndSettle();
    expect(find.text('Discard changes?'), findsOneWidget);
    await tester.tap(find.text('Keep editing'));
    await tester.pumpAndSettle();
    expect(find.byType(JsonEditorDialog), findsOneWidget);
  });

  testWidgets('tag fields stack at phone width', (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(const MaterialApp(
        home: TagEditorDialog(initialTags: {'owner': 'team'})));
    await tester.pumpAndSettle();
    final key = find.widgetWithText(TextField, 'Key'),
        value = find.widgetWithText(TextField, 'Value');
    expect(
        tester.getTopLeft(value).dy, greaterThan(tester.getBottomLeft(key).dy));
    expect(tester.getSize(key).width, greaterThan(200));
    expect(tester.takeException(), isNull);
  });

  testWidgets('rename selects basename and preserves dotfile names',
      (tester) async {
    for (final path in ['parent/report.csv', 'parent/.env']) {
      await tester.pumpWidget(MaterialApp(
          home: RenameDialog(
              key: ValueKey(path), path: path, onSave: (_) async {})));
      await tester.pumpAndSettle();
      final field = tester.widget<TextField>(find.byType(TextField));
      expect(field.controller!.selection.textInside(field.controller!.text),
          path.endsWith('.env') ? '.env' : 'report');
    }
  });

  testWidgets('navigator dialogs inherit app text scale and motion preferences',
      (tester) async {
    final controller = AppController(
        engineService: MockEngineService(),
        initialSettings: AppSettings.fromJson(
            {'uiScalePercent': 150, 'enableAnimations': false}),
        initialProfiles: const []);
    addTearDown(controller.dispose);
    await tester.pumpWidget(S3BrowserApp(controller: controller));
    await tester.pumpAndSettle();
    final navigator =
        tester.state<NavigatorState>(find.byType(Navigator).first);
    navigator.push(DialogRoute<void>(
        context: navigator.context,
        builder: (context) => AlertDialog(
            content: Text(
                'scale=${MediaQuery.textScalerOf(context).scale(10)},motion=${MediaQuery.disableAnimationsOf(context)}'))));
    await tester.pumpAndSettle();
    expect(find.text('scale=15.0,motion=true'), findsOneWidget);
  });
  testWidgets(
      'unrelated notifications preserve settings content; section edits invalidate it',
      (tester) async {
    tester.view.physicalSize = const Size(1440, 1100);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final controller = AppController(
        engineService: MockEngineService(),
        initialSettings: AppSettings.fromJson({'enableAnimations': false}),
        initialProfiles: const []);
    addTearDown(controller.dispose);
    await controller.initialize();
    controller.activeTab = WorkspaceTab.settings;
    await tester.pumpWidget(S3BrowserApp(controller: controller));
    await tester.pumpAndSettle();
    final before =
        tester.widget<SettingsWorkspace>(find.byType(SettingsWorkspace));
    controller.showBannerMessage('Transfer progress fixture');
    await tester.pumpAndSettle();
    expect(
        identical(before,
            tester.widget<SettingsWorkspace>(find.byType(SettingsWorkspace))),
        isTrue);
    controller.setSettingsSection('Appearance');
    await tester.pumpAndSettle();
    expect(
        identical(before,
            tester.widget<SettingsWorkspace>(find.byType(SettingsWorkspace))),
        isFalse);
    expect(find.byKey(const ValueKey('settings-content-Appearance')),
        findsOneWidget);
  });
}
