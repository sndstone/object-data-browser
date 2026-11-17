import 'dart:io';
import 'dart:convert';
import 'dart:typed_data';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:s3_browser_crossplat/controllers/app_controller.dart';
import 'package:s3_browser_crossplat/models/domain_models.dart';
import 'package:s3_browser_crossplat/services/encryption_key_store.dart';
import 'package:s3_browser_crossplat/services/mock_engine_service.dart';
import 'package:s3_browser_crossplat/settings/encryption_settings.dart';
import 'package:s3_browser_crossplat/widgets/app_select_field.dart';
import 'package:s3_browser_crossplat/widgets/app_form_dialog.dart';
import 'package:s3_browser_crossplat/widgets/danger_button.dart';
import 'package:s3_browser_crossplat/theme/app_motion.dart';
import 'package:s3_browser_crossplat/theme/app_theme.dart';
import 'package:s3_browser_crossplat/settings/upload_encryption_editor.dart';
import 'object_encryption_test.dart' show encryptionProfile;
import 'support/raw_dropdowns.dart';

class EncryptionPicker extends FilePicker {
  String? savePath, importPath;
  @override
  Future<String?> saveFile(
          {String? dialogTitle,
          String? fileName,
          String? initialDirectory,
          FileType type = FileType.any,
          List<String>? allowedExtensions,
          Uint8List? bytes,
          bool lockParentWindow = false}) async =>
      savePath;
  @override
  Future<FilePickerResult?> pickFiles(
          {String? dialogTitle,
          String? initialDirectory,
          FileType type = FileType.any,
          List<String>? allowedExtensions,
          Function(FilePickerStatus)? onFileLoading,
          bool allowCompression = true,
          int compressionQuality = 30,
          bool allowMultiple = false,
          bool withData = false,
          bool withReadStream = false,
          bool lockParentWindow = false,
          bool readSequential = false}) async =>
      importPath == null
          ? null
          : FilePickerResult(
              [PlatformFile(name: 'keys.age', path: importPath, size: 0)]);
}

Future<void> _tap(WidgetTester tester, String text) async {
  final finder = find.text(text).last;
  await tester.ensureVisible(finder);
  await tester.tap(finder);
  await tester.pump();
  if (find.byType(CircularProgressIndicator).evaluate().isEmpty) {
    await tester.pumpAndSettle();
  }
}

// Key-file work is real file and isolate I/O whose continuations run in the
// test zone, so alternate real time with frame pumps until it lands.
Future<void> _wait(WidgetTester tester, bool Function() ready) async {
  for (var i = 0; i < 500 && !ready(); i++) {
    await tester.pump(const Duration(milliseconds: 10));
    await tester
        .runAsync(() => Future<void>.delayed(const Duration(milliseconds: 10)));
  }
  if (!ready()) throw StateError('Key file operation did not complete.');
  // The observed effect can land before its action returns and re-enables
  // the buttons, so keep both clocks moving a little longer.
  for (var i = 0; i < 12; i++) {
    await tester.pump(const Duration(milliseconds: 50));
    await tester
        .runAsync(() => Future<void>.delayed(const Duration(milliseconds: 10)));
  }
  await tester.pump(const Duration(milliseconds: 300));
}

void _expectForm(WidgetTester tester) {
  expect(find.byWidgetPredicate((widget) => widget is AppFormDialog),
      findsOneWidget);
  expect(find.byType(AlertDialog), findsNothing);
  expect(find.byType(SimpleDialog), findsNothing);
  expect(rawDropdowns(), findsNothing);
  expect(tester.takeException(), isNull);
}

void main() {
  for (final vault in [false, true]) {
    testWidgets('generated key shown is saved exactly, vault=$vault',
        (tester) async {
      final directory = (await tester
          .runAsync(() => Directory.systemTemp.createTemp('shown-key-')))!;
      final store = EncryptionKeyStore(File('${directory.path}/keys.age'),
          scryptWorkFactor: 1);
      await tester.runAsync(() => store.create('test-passphrase'));
      final controller = AppController(
        engineService: MockEngineService(),
        initialSettings: AppSettings.fromJson({'enableAnimations': false}),
        initialProfiles: const [],
        encryptionKeyStore: store,
      );
      addTearDown(() async {
        controller.dispose();
        await directory.delete(recursive: true);
      });
      await tester.pumpWidget(MaterialApp(
          home: Scaffold(
              body: Builder(
        builder: (context) => TextButton(
          onPressed: () =>
              showEncryptionKeyDialog(context, controller, vault: vault),
          child: const Text('Open'),
        ),
      ))));
      await _tap(tester, 'Open');
      final field = find.byKey(const ValueKey('generated-encryption-key'));
      await _wait(
          tester,
          () =>
              field.evaluate().isNotEmpty &&
              tester.widget<TextField>(field).controller!.text.isNotEmpty);
      final first = tester.widget<TextField>(field).controller!.text;
      expect(tester.widget<TextField>(field).readOnly, isTrue);
      expect(tester.widget<TextField>(field).maxLines, isNull);
      await _tap(tester, 'Generate another');
      await _wait(tester,
          () => tester.widget<TextField>(field).controller!.text.isNotEmpty);
      final shown = tester.widget<TextField>(field).controller!.text;
      expect(shown != first, isTrue);
      await tester.enterText(
          find.widgetWithText(TextField, 'Key label'), 'Shown key');
      await _tap(tester, 'Generate key');
      await _wait(
          tester, () => store.records.isNotEmpty && field.evaluate().isEmpty);
      final id = store.records.single.id;
      if (vault) {
        final identity = await tester.runAsync(() => store.ageIdentity(id));
        expect(identity!.secretKey == shown, isTrue);
      } else {
        final bytes = store.customerKey(id);
        try {
          expect(base64Encode(bytes) == shown, isTrue);
        } finally {
          bytes.fillRange(0, bytes.length, 0);
        }
      }
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }

  for (final vault in [false, true]) {
    testWidgets('import secrets toggle visibility, vault=$vault',
        (tester) async {
      final controller = AppController(
          engineService: MockEngineService(),
          initialSettings: AppSettings.fromJson({'enableAnimations': false}),
          initialProfiles: const []);
      addTearDown(controller.dispose);
      await tester.pumpWidget(MaterialApp(
          home: Scaffold(
              body: Builder(
        builder: (context) => TextButton(
          onPressed: () => showEncryptionKeyDialog(context, controller,
              importing: true, vault: vault),
          child: const Text('Open'),
        ),
      ))));
      await _tap(tester, 'Open');
      final field = find.widgetWithText(
          TextField,
          vault
              ? 'Vault identity (AGE-SECRET-KEY-1…)'
              : 'Customer key (base64 or hex)');
      expect(tester.widget<TextField>(field).obscureText, isTrue);
      await tester.tap(find.byTooltip('Show secret'));
      await tester.pump();
      expect(tester.widget<TextField>(field).obscureText, isFalse);
      await tester.tap(find.byTooltip('Hide secret'));
      await tester.pump();
      expect(tester.widget<TextField>(field).obscureText, isTrue);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }

  for (final changing in [false, true]) {
    testWidgets('generated passphrase fills both fields, changing=$changing',
        (tester) async {
      final controller = AppController(
          engineService: MockEngineService(),
          initialSettings: AppSettings.fromJson({'enableAnimations': false}),
          initialProfiles: const []);
      addTearDown(controller.dispose);
      await tester.pumpWidget(MaterialApp(
          home: Scaffold(
              body: Builder(
        builder: (context) => TextButton(
          onPressed: () => showEncryptionKeyFileDialog(context, controller,
              action: changing ? 'Change passphrase' : 'Create key file'),
          child: const Text('Open'),
        ),
      ))));
      await _tap(tester, 'Open');
      final pass = find.widgetWithText(
          TextField, 'New passphrase (at least 12 characters)');
      final confirm = find.widgetWithText(TextField, 'Confirm passphrase');
      expect(tester.widget<TextField>(pass).obscureText, isTrue);
      await _tap(tester, 'Generate passphrase');
      final value = tester.widget<TextField>(pass).controller!.text;
      expect(
          RegExp(r'^[a-km-np-z2-9]{5}(-[a-km-np-z2-9]{5}){4}$').hasMatch(value),
          isTrue);
      expect(
          tester.widget<TextField>(confirm).controller!.text == value, isTrue);
      expect(tester.widget<TextField>(pass).obscureText, isFalse);
      expect(tester.widget<TextField>(confirm).obscureText, isFalse);
      await tester.tap(find.byTooltip('Hide secret'));
      await tester.pump();
      expect(tester.widget<TextField>(pass).obscureText, isTrue);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }

  for (final width in [390.0, 1200.0]) {
    testWidgets(
        'Encryption settings create generate lock unlock backup import at width $width',
        (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = Size(width, 844);
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final directory = await tester.runAsync(
          () => Directory.systemTemp.createTemp('encryption-widget-'));
      final store = EncryptionKeyStore(File('${directory!.path}/keys.age'),
          scryptWorkFactor: 1);
      final controller = AppController(
          engineService: MockEngineService(),
          initialSettings: AppSettings.fromJson({'enableAnimations': false}),
          initialProfiles: const [],
          encryptionKeyStore: store);
      final picker = EncryptionPicker()
        ..savePath = '${directory.path}/backup.age';
      // The platform instance is unset in tests, so it cannot be read first.
      FilePicker.platform = picker;
      addTearDown(() async {
        controller.dispose();
        FilePicker.platform = FilePickerIO();
        await directory.delete(recursive: true);
      });
      await tester.pumpWidget(MaterialApp(
          theme: AppTheme.dark(scalePercent: 100, desktopCompact: false),
          builder: (context, child) => MediaQuery(
              data: MediaQuery.of(context)
                  .copyWith(textScaler: const TextScaler.linear(1.3)),
              child: child!),
          home: Scaffold(
              body: SingleChildScrollView(
                  child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: EncryptionSettings(controller: controller))))));
      await _wait(
          tester, () => find.text('Create key file…').evaluate().isNotEmpty);
      await _tap(tester, 'Create key file…');
      _expectForm(tester);
      expect(find.textContaining('Losing the passphrase'), findsOneWidget);
      await tester.enterText(
          find.byType(TextField).at(0), 'test-passphrase-123');
      await tester.enterText(
          find.byType(TextField).at(1), 'test-passphrase-123');
      await _tap(tester, 'Create');
      await _wait(
          tester, () => store.isUnlocked && controller.encryptionKeyFileExists);
      await _tap(tester, 'Generate customer key…');
      _expectForm(tester);
      await tester.enterText(
          find.widgetWithText(TextField, 'Key label'), 'Portable key');
      await _tap(tester, 'Generate key');
      await _wait(tester, () => store.records.length == 1);
      expect(find.text('Portable key'), findsOneWidget);
      controller.lockEncryptionKeyFile();
      await tester.pump();
      // With motion off the reveal is laid out directly, with no size
      // animation. Stock button feedback may still tick, so the binding's
      // callback count is not a usable signal here.
      expect(find.byType(AnimatedSize), findsNothing);
      expect(store.isUnlocked, isFalse);
      expect(find.text('Portable key'), findsNothing);
      await _tap(tester, 'Unlock key file…');
      await tester.enterText(
          find.byType(TextField).last, 'test-passphrase-123');
      await _tap(tester, 'Unlock');
      await _wait(tester, () => store.isUnlocked);
      await _tap(tester, 'Back up key file…');
      await _wait(tester, () => File(picker.savePath!).existsSync());
      final incoming = EncryptionKeyStore(
          File('${directory.path}/incoming.age'),
          scryptWorkFactor: 1);
      await tester.runAsync(() async {
        await incoming.create('incoming-passphrase');
        await incoming.generateCustomerKey('Imported key');
        incoming.lock();
      });
      picker.importPath = incoming.file.path;
      await _tap(tester, 'Import keys from file…');
      await _wait(tester, () => find.text('Merge keys').evaluate().isNotEmpty);
      await tester.enterText(
          find.byType(TextField).last, 'incoming-passphrase');
      await _tap(tester, 'Merge keys');
      await _wait(tester, () => store.records.length == 2);
      expect(find.text('Imported key'), findsOneWidget);
      // The row button reads "Delete"; the key name is in its tooltip.
      final deleteRow = find.byTooltip('Delete Portable key');
      await tester.ensureVisible(deleteRow);
      await tester.pumpAndSettle();
      await tester.tap(deleteRow);
      await tester.pump();
      if (find.byType(CircularProgressIndicator).evaluate().isEmpty) {
        await tester.pumpAndSettle();
      }
      _expectForm(tester);
      expect(find.byType(DangerButton), findsOneWidget);
      await tester.enterText(
          find.widgetWithText(TextField, 'Type the key name'), 'Portable key');
      await _tap(tester, 'Delete key');
      await _wait(tester, () => store.records.length == 1);
      expect(store.records.single.label, 'Imported key');
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    });

    testWidgets(
        'Upload encryption defaults collapsed and selects provider modes at width $width',
        (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = Size(width, 844);
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final controller = AppController(
          engineService: MockEngineService(),
          initialSettings: AppSettings.fromJson({'enableAnimations': false}),
          initialProfiles: const []);
      addTearDown(controller.dispose);
      ObjectEncryption? value;
      await tester.pumpWidget(MaterialApp(
          theme: AppTheme.dark(scalePercent: 100, desktopCompact: false),
          builder: (context, child) => MediaQuery(
              data: MediaQuery.of(context)
                  .copyWith(textScaler: const TextScaler.linear(1.3)),
              child: child!),
          home: Scaffold(
              body: SingleChildScrollView(
                  child: StatefulBuilder(
                      builder: (context, setState) => UploadEncryptionEditor(
                          controller: controller,
                          profile: encryptionProfile,
                          value: value,
                          onChanged: (next) =>
                              setState(() => value = next)))))));
      expect(value, isNull);
      expect(find.text('Bucket default'), findsOneWidget);
      expect(find.text('Upload encryption mode'), findsNothing);
      await _tap(tester, 'Upload encryption');
      final mode = tester.widget<AppSelectField<ObjectEncryptionMode>>(
          find.byType(AppSelectField<ObjectEncryptionMode>));
      mode.onChanged!(ObjectEncryptionMode.sseKms);
      await tester.pump();
      // With motion off the reveal is laid out directly, with no size
      // animation. Stock button feedback may still tick, so the binding's
      // callback count is not a usable signal here.
      expect(find.byType(AnimatedSize), findsNothing);
      expect(
          tester
              .widgetList<MotionSize>(find.byType(MotionSize))
              .every((motion) => motion.duration == Duration.zero),
          isTrue);
      expect(value!.mode, ObjectEncryptionMode.sseKms);
      expect(find.text('KMS key ID or ARN (optional)'), findsOneWidget);
      expect(find.text('Use S3 bucket key'), findsOneWidget);
      await _tap(tester, 'Add encryption context pair');
      _expectForm(tester);
      await _tap(tester, 'Add');
      expect(find.text('Enter a context key.'), findsOneWidget);
      await tester.enterText(
          find.widgetWithText(TextField, 'Context key'), 'purpose');
      await tester.enterText(
          find.widgetWithText(TextField, 'Context value'), 'backup');
      await _tap(tester, 'Add');
      expect(value!.kmsEncryptionContext, {'purpose': 'backup'});
      expect(find.text('purpose'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    });
    testWidgets(
        'Azure encryption picker limits modes and disables customer keys on HTTP at width $width',
        (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = Size(width, 844);
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final controller = AppController(
          engineService: MockEngineService(),
          initialSettings: AppSettings.fromJson({'enableAnimations': false}),
          initialProfiles: const []);
      addTearDown(controller.dispose);
      await tester.pumpWidget(MaterialApp(
          theme: AppTheme.dark(scalePercent: 100, desktopCompact: false),
          builder: (context, child) => MediaQuery(
              data: MediaQuery.of(context)
                  .copyWith(textScaler: const TextScaler.linear(1.3)),
              child: child!),
          home: Scaffold(
              body: SingleChildScrollView(
                  child: UploadEncryptionEditor(
                      controller: controller,
                      profile: encryptionProfile.copyWith(
                          endpointType: EndpointProfileType.azureBlob,
                          endpointUrl: 'http://example.com'),
                      value: null,
                      onChanged: (_) {})))));
      await _tap(tester, 'Upload encryption');
      final picker = tester.widget<AppSelectField<ObjectEncryptionMode>>(
          find.byWidgetPredicate(
              (widget) => widget is AppSelectField<ObjectEncryptionMode>));
      expect(picker.items.map((item) => item.value), [
        ObjectEncryptionMode.bucketDefault,
        ObjectEncryptionMode.azureScope,
        ObjectEncryptionMode.azureCpk
      ]);
      expect(picker.items.last.enabled, isFalse);
      expect(find.textContaining('require an HTTPS endpoint'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }
}
