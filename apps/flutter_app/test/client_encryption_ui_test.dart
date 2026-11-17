import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:s3_browser_crossplat/browser/object_table.dart';
import 'package:s3_browser_crossplat/controllers/app_controller.dart';
import 'package:s3_browser_crossplat/models/domain_models.dart';
import 'package:s3_browser_crossplat/services/encryption_key_store.dart';
import 'package:s3_browser_crossplat/services/mock_engine_service.dart';
import 'package:s3_browser_crossplat/settings/client_encryption_editor.dart';
import 'package:s3_browser_crossplat/settings/encryption_settings.dart';
import 'package:s3_browser_crossplat/widgets/copyable_value.dart';
import 'package:s3_browser_crossplat/widgets/app_select_field.dart';
import 'package:s3_browser_crossplat/widgets/app_form_dialog.dart';
import 'package:s3_browser_crossplat/theme/app_theme.dart';
import 'package:s3_browser_crossplat/theme/app_motion.dart';
import 'object_encryption_test.dart' show encryptionProfile;
import 'support/raw_dropdowns.dart';

void main() {
  late Directory dir;
  late EncryptionKeyStore store;
  late AppController controller;
  setUp(() async {
    dir = await Directory.systemTemp.createTemp('vault-ui-');
    store =
        EncryptionKeyStore(File('${dir.path}/keys.age'), scryptWorkFactor: 1);
    await store.create('test-passphrase');
    await store.generateAgeIdentity('Vault');
    controller = AppController(
        engineService: MockEngineService(),
        encryptionKeyStore: store,
        initialSettings: AppSettings.fromJson({'enableAnimations': false}),
        initialProfiles: const [encryptionProfile]);
  });
  tearDown(() async {
    controller.dispose();
    await dir.delete(recursive: true);
  });

  for (final platform in [TargetPlatform.android, TargetPlatform.iOS]) {
    testWidgets('vault rule controls are enabled on $platform', (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(390, 844);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPhysicalSize);
      debugDefaultTargetPlatformOverride = platform;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      final rules = [
        ClientEncryptionRule(
            bucket: 'bucket',
            keyId: store.records.single.id,
            recipient: store.records.single.fingerprint,
            label: 'Vault')
      ];
      await tester.pumpWidget(MaterialApp(
          theme: AppTheme.dark(scalePercent: 100, desktopCompact: false),
          builder: (context, child) => MediaQuery(
              data: MediaQuery.of(context).copyWith(
                  textScaler: const TextScaler.linear(1.3),
                  disableAnimations: true),
              child: child!),
          home: Scaffold(
              body: SingleChildScrollView(
                  child: ClientEncryptionEditor(
                      controller: controller,
                      rules: rules,
                      onChanged: (_) {})))));
      await tester.tap(find.text('Client-side encryption'));
      await tester.pumpAndSettle();
      expect(
          tester
              .widget<ListTile>(find.widgetWithText(ListTile, 'bucket/'))
              .onTap,
          isNotNull);
      expect(
          tester
              // byTooltip finds the tooltip the button builds, not the button.
              .widget<IconButton>(find
                  .ancestor(
                      of: find.byTooltip('Remove vault rule'),
                      matching: find.byType(IconButton))
                  .first)
              .onPressed,
          isNotNull);
      final add = find.ancestor(
          of: find.text('Add vault rule'),
          matching: find.byWidgetPredicate((w) => w is FilledButton));
      expect(tester.widget<FilledButton>(add).onPressed, isNotNull);
      await tester.ensureVisible(find.text('Add vault rule'));
      await tester.tap(find.text('Add vault rule'));
      await tester.pumpAndSettle();
      expect(find.text('Bucket'), findsOneWidget);
      expect(find.byWidgetPredicate((widget) => widget is AppFormDialog),
          findsOneWidget);
      expect(find.byType(AlertDialog), findsNothing);
      expect(find.byType(SimpleDialog), findsNothing);
      expect(rawDropdowns(), findsNothing);
      expect(tester.takeException(), isNull);
      // Reset before the body returns: the binding checks debug overrides
      // before tear-downs run.
      debugDefaultTargetPlatformOverride = null;
    });
  }

  testWidgets('mixed listing keeps two rows and labels encrypted contents',
      (tester) async {
    final entries = [
      for (final key in ['a.txt', 'a.txt.age'])
        ObjectEntry(
            key: key,
            name: key,
            size: key.endsWith('.age') ? 250 : 1,
            storageClass: 'STANDARD',
            modifiedAt: DateTime.utc(2026),
            isFolder: false)
    ];
    controller.selectedProfile =
        encryptionProfile.copyWith(clientEncryptionRules: [
      ClientEncryptionRule(
          bucket: 'bucket',
          keyId: 'id',
          recipient: store.records.single.fingerprint,
          label: 'Vault')
    ]);
    controller.selectedBucket = const BucketSummary(
        name: 'bucket',
        region: '',
        objectCountHint: 2,
        versioningEnabled: false);
    await tester.pumpWidget(MaterialApp(
        theme: AppTheme.dark(scalePercent: 100, desktopCompact: false),
        builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context).copyWith(
                textScaler: const TextScaler.linear(1.3),
                disableAnimations: true),
            child: child!),
        home: Scaffold(
            body: ObjectTable(
                objects: entries,
                selectedKey: null,
                selectedKeys: const {},
                compactRows: false,
                sortField: BrowserObjectSortField.name,
                descending: false,
                onSort: (_) {},
                onToggle: (_, range) {},
                onSelect: (_) {},
                contentTypeFor: controller.objectContentType,
                onShowContextMenu: (_, rect) async {},
                visibleNameFor: controller.visibleObjectName,
                isClientEncrypted: controller.isClientEncrypted))));
    expect(find.text('a.txt'), findsNWidgets(2));
    expect(find.byTooltip('Client-side encrypted'), findsOneWidget);
    final lock = tester.widget<Icon>(find.byIcon(Icons.lock_outline));
    expect(lock.size, 18);
    expect(
        lock.color,
        Theme.of(tester.element(find.byType(ObjectTable)))
            .colorScheme
            .onSurfaceVariant);
    expect(lock.semanticLabel, 'Client-side encrypted');
    expect(tester.takeException(), isNull);
    expect(find.text('250 B'), findsOneWidget);
    expect(entries[1].key, 'a.txt.age');
  });

  testWidgets('vault rules are collapsed and optional with add edit remove',
      (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(390, 844);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    var rules = <ClientEncryptionRule>[];
    await tester.pumpWidget(MaterialApp(
        theme: AppTheme.dark(scalePercent: 100, desktopCompact: false),
        builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context).copyWith(
                textScaler: const TextScaler.linear(1.3),
                disableAnimations: true),
            child: child!),
        home: Scaffold(
            body: SingleChildScrollView(
                child: StatefulBuilder(
                    builder: (context, setState) => ClientEncryptionEditor(
                        controller: controller,
                        rules: rules,
                        onChanged: (value) =>
                            setState(() => rules = value)))))));
    expect(find.text('Off · no vault rules'), findsOneWidget);
    await tester.tap(find.text('Client-side encryption'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('Add vault rule'));
    await tester.tap(find.text('Add vault rule'));
    await tester.pumpAndSettle();
    await tester.enterText(find.widgetWithText(TextField, 'Bucket'), 'bucket');
    await tester.enterText(
        find.widgetWithText(TextField, 'Prefix (optional)'), 'private/');
    final picker = tester
        .widget<AppSelectField<String>>(find.byType(AppSelectField<String>));
    picker.onChanged!(store.records.single.id);
    await tester.pump();
    expect(
        tester
            .widgetList<MotionSize>(find.byType(MotionSize))
            .every((motion) => motion.duration == Duration.zero),
        isTrue);
    expect(
        find.descendant(
            of: find.byType(MotionSize), matching: find.byType(AnimatedSize)),
        findsNothing);
    expect(find.byType(CopyableValue), findsOneWidget);
    final copy = find
        .ancestor(
            of: find.byTooltip('Copy Recipient'),
            matching: find.byType(IconButton))
        .first;
    // Sized by the shared copy control, which this screen reuses unchanged.
    expect(copy, findsOneWidget);
    expect(find.byWidgetPredicate((widget) => widget is AppFormDialog),
        findsOneWidget);
    expect(find.byType(AlertDialog), findsNothing);
    expect(find.byType(SimpleDialog), findsNothing);
    expect(rawDropdowns(), findsNothing);
    await tester.ensureVisible(find.text('Save rule'));
    await tester.tap(find.text('Save rule'));
    await tester.pumpAndSettle();
    expect(rules.single.prefix, 'private/');
    expect(rules.single.recipient, store.records.single.fingerprint);
    await tester.ensureVisible(find.text('bucket/private/'));
    await tester.tap(find.text('bucket/private/'));
    await tester.pumpAndSettle();
    await tester.enterText(
        find.widgetWithText(TextField, 'Prefix (optional)'), 'more/');
    await tester.ensureVisible(find.text('Save rule'));
    await tester.tap(find.text('Save rule'));
    await tester.pumpAndSettle();
    expect(rules.single.prefix, 'more/');
    final removeButton = find.ancestor(
        of: find.byTooltip('Remove vault rule'),
        matching: find.byType(IconButton));
    await tester.ensureVisible(removeButton);
    await tester.tap(removeButton);
    await tester.pumpAndSettle();
    expect(rules, hasLength(1));
    expect(find.textContaining('Existing .age objects stay encrypted'),
        findsOneWidget);
    await tester.tap(find.text('Remove rule'));
    await tester.pumpAndSettle();
    expect(rules, isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'vault create flow states protection limits recovery and age portability',
      (tester) async {
    await tester.pumpWidget(MaterialApp(
        theme: AppTheme.dark(scalePercent: 100, desktopCompact: false),
        builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context).copyWith(
                textScaler: const TextScaler.linear(1.3),
                disableAnimations: true),
            child: child!),
        home: Scaffold(
            body: SingleChildScrollView(
                child: EncryptionSettings(controller: controller)))));
    for (var i = 0; i < 10; i++) {
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 10)));
      await tester.pump();
    }
    final recipient = tester
        .widgetList<CopyableValue>(find.byType(CopyableValue))
        .singleWhere((value) => value.label == 'Recipient');
    expect(recipient.value, store.records.single.fingerprint);
    final generate = find.text('Generate vault key…');
    await tester.ensureVisible(generate);
    await tester.tap(generate);
    await tester.pumpAndSettle();
    expect(
        find.textContaining(
            'Sizes, counts, timestamps and deletion remain visible.'),
        findsOneWidget);
    expect(find.textContaining('data cannot be recovered'), findsOneWidget);
    expect(find.textContaining('standard age tool'), findsOneWidget);
  });
}
