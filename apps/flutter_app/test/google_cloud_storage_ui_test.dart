import 'package:flutter/gestures.dart' show kSecondaryButton;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:s3_browser_crossplat/app/s3_browser_app.dart';
import 'package:s3_browser_crossplat/browser/browser_workspace.dart';
import 'package:s3_browser_crossplat/controllers/app_controller.dart';
import 'package:s3_browser_crossplat/models/domain_models.dart';
import 'package:s3_browser_crossplat/services/mock_engine_service.dart';
import 'package:s3_browser_crossplat/settings/upload_encryption_editor.dart';
import 'package:s3_browser_crossplat/widgets/app_form_dialog.dart';
import 'package:s3_browser_crossplat/widgets/app_select_field.dart';

import 'google_cloud_storage_fixture.dart' show googleProfile;
import 'settings_ui_test.dart' show openEditor;
import 'support/raw_dropdowns.dart';

void main() {
  testWidgets(
      'native provider template selects the JSON editor and hides S3 controls',
      (tester) async {
    final controller =
        await openEditor(tester, width: 390, scalePercent: 130, dark: true);
    final provider = tester.widget<AppSelectField<String>>(
        find.byKey(const ValueKey('provider-gui')));
    provider.onChanged!('google-cloud-storage-native');
    await tester.pumpAndSettle();
    expect(controller.profileDrafts['gui']!.endpointType,
        EndpointProfileType.googleCloudStorage);
    expect(find.text('Service account key (JSON)'), findsOneWidget);
    expect(find.text('Bucket location'), findsOneWidget);
    expect(find.byType(UploadEncryptionEditor), findsNothing);
    for (final label in [
      'Access key',
      'Secret key',
      'Authentication',
      'Session token',
      'Force path-style requests',
      'AWS region'
    ]) {
      expect(find.text(label), findsNothing, reason: label);
    }
    expect(
        find.text(
            'Google Cloud Storage requires a compatible desktop engine (Python or Go).'),
        findsOneWidget);
    await tester.ensureVisible(find.text('Paste JSON'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Paste JSON'));
    await tester.pumpAndSettle();
    expect(find.byWidgetPredicate((widget) => widget is AppFormDialog),
        findsOneWidget);
    expect(find.byType(AlertDialog), findsNothing);
    expect(find.byType(SimpleDialog), findsNothing);
    expect(rawDropdowns(), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('native bucket admin hides S3 panels and retains versioning',
      (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1500, 1100);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    final engine = MockEngineService();
    final controller = AppController(
        engineService: engine,
        initialSettings: AppSettings.fromJson(
            {'enableAnimations': false, 'uiScalePercent': 100}),
        initialProfiles: const []);
    addTearDown(controller.dispose);
    controller.selectedProfile = googleProfile();
    controller.selectedBucket = const BucketSummary(
        name: 'fixture',
        region: 'EU',
        objectCountHint: 0,
        versioningEnabled: true);
    controller.buckets = [controller.selectedBucket!];
    controller.capabilities =
        await engine.getCapabilities(engineId: 'go', profile: googleProfile());
    controller.adminState = await engine.getBucketAdminState(
        engineId: 'go', profile: googleProfile(), bucketName: 'fixture');
    controller.setInspectorTab(BrowserInspectorTab.bucketAdmin);
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: BrowserWorkspace(controller: controller, compact: false))));
    await tester.pumpAndSettle();
    expect(
        find.text(
            'Cloud Storage bucket administration is limited to versioning in this version.'),
        findsOneWidget);
    expect(find.text('Enable versioning'), findsOneWidget);
    for (final label in [
      'Access presets',
      'Lifecycle presets',
      'Advanced administration',
      'Edit lifecycle',
      'Edit policy',
      'Edit encryption',
      'Lifecycle JSON',
      'Policy JSON',
      'CORS JSON',
      'Encryption JSON'
    ]) {
      expect(find.text(label), findsNothing, reason: label);
    }
    controller.objects = [
      ObjectEntry(
          key: 'fixture.txt',
          name: 'fixture.txt',
          size: 1,
          storageClass: 'STANDARD',
          modifiedAt: DateTime(2026),
          isFolder: false)
    ];
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: BrowserWorkspace(
                key: const ValueKey('context'),
                controller: controller,
                compact: false))));
    await tester.pumpAndSettle();
    final object = find.text('fixture.txt');
    await tester.ensureVisible(object);
    // Desktop object menus open on secondary click.
    await tester.tap(object, buttons: kSecondaryButton);
    await tester.pumpAndSettle();
    expect(find.text('Copy gs:// URI'), findsOneWidget);
    expect(find.text('Copy s3:// URI'), findsNothing);
    expect(find.text('Rename object'), findsOneWidget);
    await tester.tapAt(const Offset(5, 5));
    await tester.pumpAndSettle();
    controller.setInspectorTab(BrowserInspectorTab.versions);
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: BrowserWorkspace(
                key: const ValueKey('generations'),
                controller: controller,
                compact: false))));
    await tester.pumpAndSettle();
    expect(find.text('Show generations'), findsOneWidget);
    expect(find.text('Show delete markers'), findsNothing);
    expect(find.textContaining('Delete markers:'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('engine picker disables engines without the native provider',
      (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1500, 1000);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    final controller = AppController(
        engineService: MockEngineService(),
        initialSettings: AppSettings.fromJson(
            {'defaultEngineId': 'python', 'enableAnimations': false}),
        initialProfiles: [googleProfile()]);
    addTearDown(controller.dispose);
    await controller.initialize();
    await tester.pumpWidget(S3BrowserApp(controller: controller));
    await tester.pumpAndSettle();
    final selectors = tester.widgetList<AppSelectField<String>>(
        find.byType(AppSelectField<String>));
    final picker = selectors.firstWhere(
        (selector) => selector.items.any((item) => item.value == 'python'));
    expect(picker.items.singleWhere((item) => item.value == 'python').enabled,
        isTrue);
    expect(
        picker.items.singleWhere((item) => item.value == 'go').enabled, isTrue);
    for (final id in ['rust', 'java']) {
      final item = picker.items.singleWhere((item) => item.value == id);
      expect(item.enabled, isFalse);
      expect(item.label, contains('requires a compatible desktop engine'));
    }
    expect(find.text('Benchmark'), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
