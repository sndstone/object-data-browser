import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:s3_browser_crossplat/app/s3_browser_app.dart';
import 'package:s3_browser_crossplat/controllers/app_controller.dart';
import 'package:s3_browser_crossplat/models/domain_models.dart';
import 'package:s3_browser_crossplat/services/mock_engine_service.dart';
import 'package:s3_browser_crossplat/widgets/setting_fields.dart';
import 'package:s3_browser_crossplat/widgets/app_select_field.dart';
import 'package:s3_browser_crossplat/settings/upload_encryption_editor.dart';
import 'package:s3_browser_crossplat/settings/client_encryption_editor.dart';
import 'package:s3_browser_crossplat/theme/app_motion.dart';
import 'support/raw_dropdowns.dart';

class SaveController extends AppController {
  SaveController({int scalePercent = 100, bool dark = false})
      : super(
            engineService: MockEngineService(),
            initialSettings: AppSettings.fromJson({
              'defaultEngineId': 'rust',
              'enableAnimations': false,
              'uiScalePercent': scalePercent,
              'darkMode': dark,
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

Future<SaveController> openEditor(WidgetTester tester,
    {double width = 1400,
    int scalePercent = 100,
    bool dark = false,
    bool expandProvider = true}) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = Size(width, width < 700 ? 844 : 1100);
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final c = SaveController(scalePercent: scalePercent, dark: dark);
  await c.initialize();
  addTearDown(c.dispose);
  await tester.pumpWidget(S3BrowserApp(controller: c));
  await tester.pumpAndSettle();
  c.selectTab(WorkspaceTab.settings);
  await tester.pumpAndSettle();
  // On a phone-width layout the profile tile starts below the fold.
  await tester.ensureVisible(find.text('GUI test').last);
  await tester.pumpAndSettle();
  await tester.tap(find.text('GUI test').last);
  await tester.pumpAndSettle();
  return c;
}

void main() {
  testWidgets(
      'profile groups match connection options at phone width and large dark text',
      (tester) async {
    await openEditor(tester,
        width: 390, scalePercent: 130, dark: true, expandProvider: false);
    Finder group(String title) => find.byWidgetPredicate((widget) =>
        widget is ExpansionTile &&
        widget.title is Text &&
        (widget.title as Text).data == title);
    final upload = find.byType(UploadEncryptionEditor);
    final client = find.byType(ClientEncryptionEditor);
    // The provider selector stays in view: it drives the fields below it.
    expect(find.byKey(const ValueKey('provider-gui')), findsOneWidget);
    expect(group('Provider template'), findsNothing);
    expect(upload, findsOneWidget);
    expect(client, findsOneWidget);
    expect(Theme.of(tester.element(upload)).brightness, Brightness.dark);
    expect(MediaQuery.textScalerOf(tester.element(upload)).scale(10), 13);
    expect(find.text('Upload encryption mode'), findsNothing);
    expect(find.text('Add vault rule'), findsNothing);
    for (final title in ['Upload encryption', 'Client-side encryption']) {
      final tile = tester.widget<ExpansionTile>(group(title));
      expect(tile.tilePadding, EdgeInsets.zero);
      expect(tile.expandedCrossAxisAlignment, CrossAxisAlignment.stretch);
      expect(tile.expansionAnimationStyle!.duration, Duration.zero);
      await tester.ensureVisible(find.text(title));
      await tester.tap(find.text(title));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull, reason: title);
    }
    final field = tester.widget<AppSelectField<String>>(
        find.byKey(const ValueKey('provider-gui')));
    field.onChanged!('cloudflare-r2');
    await tester.pump();
    expect(find.byKey(const ValueKey('provider-cloudflare-r2-accountId')),
        findsOneWidget);
    expect(find.byType(SimpleDialog), findsNothing);
    expect(find.byType(AlertDialog), findsNothing);
    expect(rawDropdowns(), findsNothing);
    expect(
        tester
            .widgetList<MotionSize>(find.byType(MotionSize))
            .every((motion) => motion.duration == Duration.zero),
        isTrue);
    expect(
        find.descendant(
            of: find.byType(MotionSize), matching: find.byType(AnimatedSize)),
        findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('provider templates fill fields and Custom preserves the draft', (
    tester,
  ) async {
    final c = await openEditor(tester);
    // The selector's own menu is covered by app_select_field_test; here the
    // choice is applied directly so long-menu scrolling cannot pick a
    // neighbouring provider.
    Future<void> choose(String label) async {
      final provider = find.byKey(const ValueKey('provider-gui'));
      final field = tester.widget<AppSelectField<String>>(provider);
      field.onChanged!(
          field.items.singleWhere((item) => item.label == label).value);
      await tester.pumpAndSettle();
    }

    await choose('Cloudflare R2');
    final endpoint = find.widgetWithText(TextField, 'Endpoint host or URL');
    expect(tester.widget<TextField>(endpoint).controller!.text, isEmpty);
    final account = find.byKey(
      const ValueKey('provider-cloudflare-r2-accountId'),
    );
    await tester.ensureVisible(account);
    await tester.enterText(account, 'account123');
    await tester.pumpAndSettle();
    expect(
      tester.widget<TextField>(endpoint).controller!.text,
      'https://account123.r2.cloudflarestorage.com',
    );
    expect(c.profileDrafts['gui']!.region, 'auto');
    expect(c.profileDrafts['gui']!.pathStyle, isTrue);
    expect(c.profileDrafts['gui']!.providerTemplateId, 'cloudflare-r2');
    expect(c.profileDrafts['gui']!.accessKey, 'test');
    expect(c.profileDrafts['gui']!.secretKey, 'secret');
    expect(c.profiles.single.endpointUrl, 'http://localhost:9000');
    expect(
      find.textContaining(
        "Check these values against your provider's documentation",
      ),
      findsOneWidget,
    );

    await tester.ensureVisible(endpoint);
    await tester.enterText(
      endpoint,
      'https://account123.eu.r2.cloudflarestorage.com',
    );
    await tester.pumpAndSettle();
    expect(c.profileDrafts['gui']!.providerTemplateId, 'cloudflare-r2');
    expect(
      c.profileDrafts['gui']!.endpointUrl,
      'https://account123.eu.r2.cloudflarestorage.com',
    );
    final r2Draft = c.profileDrafts['gui']!;
    await choose('Custom');
    // Compare serialized values: rebuilt drafts hold fresh option lists.
    expect(c.profileDrafts['gui']!.providerTemplateId, isNull);
    expect(c.profileDrafts['gui']!.toJson(),
        r2Draft.copyWith(providerTemplateId: null).toJson());

    await choose('Azure Blob Storage');
    expect(c.profileDrafts['gui']!.endpointType, EndpointProfileType.azureBlob);
    final type = tester.widget<AppSelectField<EndpointProfileType>>(
      find.byWidgetPredicate(
        (widget) => widget is AppSelectField<EndpointProfileType>,
      ),
    );
    expect(type.value, EndpointProfileType.azureBlob);
    final azureAccount = find.byKey(
      const ValueKey('provider-azure-blob-account'),
    );
    await tester.ensureVisible(azureAccount);
    await tester.enterText(azureAccount, 'mystorageaccount');
    await tester.pumpAndSettle();
    final azureDraft = c.profileDrafts['gui']!;
    expect(
      azureDraft.endpointUrl,
      'https://mystorageaccount.blob.core.windows.net',
    );
    expect(azureDraft.pathStyle, isFalse);
    await choose('Custom');
    expect(c.profileDrafts['gui']!.providerTemplateId, isNull);
    expect(c.profileDrafts['gui']!.toJson(),
        azureDraft.copyWith(providerTemplateId: null).toJson());
    expect(
      find.byKey(const ValueKey('provider-azure-blob-account')),
      findsNothing,
    );
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('Amazon template endpoint remains editable after choosing Custom',
      (tester) async {
    final c = await openEditor(tester);
    final provider = find.byKey(const ValueKey('provider-gui'));
    tester.widget<AppSelectField<String>>(provider).onChanged!('amazon-s3');
    await tester.pumpAndSettle();
    final region = find.byKey(const ValueKey('provider-amazon-s3-region'));
    await tester.ensureVisible(region);
    await tester.enterText(region, 'eu-west-1');
    await tester.pumpAndSettle();
    final endpoint = find.widgetWithText(TextField, 'Endpoint host or URL');
    expect(tester.widget<TextField>(endpoint).controller!.text,
        'https://s3.eu-west-1.amazonaws.com');
    await tester.ensureVisible(endpoint);
    await tester.enterText(
        endpoint, 'https://s3.dualstack.eu-west-1.amazonaws.com');
    await tester.pumpAndSettle();
    final draft = c.profileDrafts['gui']!;
    expect(draft.endpointUrl, 'https://s3.dualstack.eu-west-1.amazonaws.com');
    tester.widget<AppSelectField<String>>(provider).onChanged!('');
    await tester.pumpAndSettle();
    expect(c.profileDrafts['gui'], draft.copyWith(providerTemplateId: null));
    expect(
        tester.widget<TextField>(endpoint).controller!.text, draft.endpointUrl);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('provider helper text wraps at phone width in dark theme', (
    tester,
  ) async {
    final c = await openEditor(tester);
    await c.updateSettings(c.settings.copyWith(darkMode: true));
    tester.view.physicalSize = const Size(390, 844);
    await tester.pumpAndSettle();
    final provider = find.byKey(const ValueKey('provider-gui'));
    if (provider.evaluate().isEmpty) {
      // The phone layout rebuilds the list with the profile tile collapsed
      // and below the fold.
      await tester.ensureVisible(find.text('GUI test').last);
      await tester.pumpAndSettle();
      await tester.tap(find.text('GUI test').last);
      await tester.pumpAndSettle();
    }
    await tester.ensureVisible(provider);
    await tester.pumpAndSettle();
    tester.widget<AppSelectField<String>>(provider).onChanged!(
      'google-cloud-storage',
    );
    await tester.pumpAndSettle();
    final guidance = find.textContaining('HMAC key (access ID and secret)');
    await tester.ensureVisible(guidance);
    await tester.pumpAndSettle();
    expect(tester.getSize(guidance).width, lessThanOrEqualTo(390));
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

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

  testWidgets('profile actions align with the form edge', (tester) async {
    await openEditor(tester);
    final save = find.widgetWithText(FilledButton, 'Save');
    await tester.ensureVisible(save);
    await tester.pumpAndSettle();
    final name = find.widgetWithText(TextField, 'Profile name');
    expect(tester.getTopLeft(save).dx,
        moreOrLessEquals(tester.getTopLeft(name).dx, epsilon: 1));
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });
}
