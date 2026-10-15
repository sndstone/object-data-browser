import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:s3_browser_crossplat/app/s3_browser_app.dart';
import 'package:s3_browser_crossplat/controllers/app_controller.dart';
import 'package:s3_browser_crossplat/models/domain_models.dart';
import 'package:s3_browser_crossplat/services/mock_engine_service.dart';
import 'package:s3_browser_crossplat/widgets/setting_fields.dart';

class SaveController extends AppController {
  SaveController()
      : super(
            engineService: MockEngineService(),
            initialSettings: AppSettings.fromJson({
              'defaultEngineId': 'rust',
              'enableAnimations': false,
              'uiScalePercent': 100,
            }),
            initialProfiles: const [
              EndpointProfile(
                  id: 'gui',
                  name: 'GUI test',
                  endpointUrl: 'http://localhost:9000',
                  region: 'us-east-1',
                  accessKey: 'test',
                  secretKey: 'secret',
                  pathStyle: true,
                  verifyTls: false)
            ]);
  Completer<bool>? pendingSave;
  String status = 'Saved';
  int saves = 0;
  @override
  String profilePersistenceStatusFor(String id) => status;
  @override
  Future<bool> saveProfile(EndpointProfile profile) async {
    saves++;
    updateProfile(profile);
    final persisted = await pendingSave!.future;
    status = persisted ? 'Saved' : 'Session only';
    notifyListeners();
    return persisted;
  }
}

Future<SaveController> openEditor(WidgetTester tester) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = const Size(1400, 1100);
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final c = SaveController();
  await c.initialize();
  addTearDown(c.dispose);
  await tester.pumpWidget(S3BrowserApp(controller: c));
  await tester.pumpAndSettle();
  c.selectTab(WorkspaceTab.settings);
  await tester.pumpAndSettle();
  await tester.tap(find.text('GUI test').last);
  await tester.pumpAndSettle();
  return c;
}

void main() {
  testWidgets(
      'profile save shows progress, blocks repeats and surfaces '
      'session-only failures', (tester) async {
    final c = await openEditor(tester);
    final name = find.widgetWithText(TextField, 'Profile name');
    await tester.enterText(name, 'Renamed');
    await tester.pump();
    c.pendingSave = Completer<bool>();
    final save = find.widgetWithText(FilledButton, 'Save');
    await tester.ensureVisible(save);
    await tester.pumpAndSettle();
    await tester.tap(save);
    await tester.pump();
    final saving = find.widgetWithText(FilledButton, 'Saving…');
    expect(saving, findsOneWidget);
    expect(tester.widget<FilledButton>(saving).onPressed, isNull);
    await tester.tap(saving, warnIfMissed: false);
    await tester.pump();
    expect(c.saves, 1);

    // Secure persistence failed: never claim success; offer a retry.
    c.pendingSave!.complete(false);
    await tester.pumpAndSettle();
    expect(find.text('Session only'), findsOneWidget);
    expect(find.byIcon(Icons.warning_amber_rounded), findsOneWidget);
    final retry = find.widgetWithText(FilledButton, 'Retry save');
    expect(tester.widget<FilledButton>(retry).onPressed, isNotNull);

    c.pendingSave = Completer<bool>()..complete(true);
    await tester.tap(retry);
    await tester.pumpAndSettle();
    expect(c.saves, 2);
    expect(find.text('Saved'), findsOneWidget);
    expect(find.byIcon(Icons.warning_amber_rounded), findsNothing);
    expect(
        tester
            .widget<FilledButton>(find.widgetWithText(FilledButton, 'Save'))
            .onPressed,
        isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('invalid timeouts explain why save is disabled', (tester) async {
    await openEditor(tester);
    final advanced = find.text('Advanced transport');
    await tester.ensureVisible(advanced);
    await tester.pumpAndSettle();
    await tester.tap(advanced);
    await tester.pumpAndSettle();
    final connect = find.widgetWithText(TextField, 'Connect timeout (s)');
    await tester.ensureVisible(connect);
    await tester.enterText(connect, '0');
    await tester.pump();
    expect(find.text('Fix the highlighted timeouts to save.'), findsOneWidget);
    expect(find.text('Enter a positive timeout in seconds.'), findsOneWidget);
    expect(
        tester
            .widget<FilledButton>(find.widgetWithText(FilledButton, 'Save'))
            .onPressed,
        isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('numeric settings reject non-digit input', (tester) async {
    int? committed;
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: SettingNumberField(
                label: 'Workers',
                value: 4,
                max: 64,
                onCommit: (v) => committed = v))));
    final field = find.widgetWithText(TextFormField, 'Workers');
    await tester.enterText(field, '1a2-');
    await tester.pump();
    expect(find.text('12'), findsOneWidget);
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pump();
    expect(committed, 12);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('profile timeouts accept digits only', (tester) async {
    await openEditor(tester);
    final advanced = find.text('Advanced transport');
    await tester.ensureVisible(advanced);
    await tester.pumpAndSettle();
    await tester.tap(advanced);
    await tester.pumpAndSettle();
    final read = find.widgetWithText(TextField, 'Read timeout (s)');
    await tester.ensureVisible(read);
    await tester.enterText(read, '4x5');
    await tester.pump();
    expect(tester.widget<TextField>(read).controller!.text, '45');
    await tester.pumpWidget(const SizedBox());
  });
}
