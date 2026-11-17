import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:s3_browser_crossplat/controllers/app_controller.dart';
import 'package:s3_browser_crossplat/models/domain_models.dart';
import 'package:s3_browser_crossplat/services/encryption_key_store.dart';
import 'package:s3_browser_crossplat/services/mock_engine_service.dart';
import 'package:s3_browser_crossplat/settings/client_encryption_editor.dart';
import 'package:s3_browser_crossplat/theme/app_theme.dart';
import 'package:s3_browser_crossplat/widgets/app_select_field.dart';
import 'package:s3_browser_crossplat/widgets/app_switch.dart';

Future<void> _tap(WidgetTester tester, String label) async {
  final target = find.text(label).last;
  await tester.ensureVisible(target);
  await tester.tap(target);
  await tester.pumpAndSettle();
}

void main() {
  for (final mode in ['default', 'names', 'strict', 'unsupported']) {
    testWidgets('vault rule editor preserves and stages $mode', (tester) async {
      final directory = (await tester
          .runAsync(() => Directory.systemTemp.createTemp('vault-editor-')))!;
      final store = EncryptionKeyStore(File('${directory.path}/keys.age'),
          scryptWorkFactor: 1);
      await tester.runAsync(() async {
        await store.create('test-passphrase');
        await store.generateAgeIdentity('Vault');
      });
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
      final key = store.records.single;
      final baseline = ClientEncryptionRule(
          bucket: 'bucket',
          keyId: key.id,
          recipient: key.fingerprint,
          label: key.label);
      final future = ClientEncryptionRule.fromJson({
        ...baseline.toJson(),
        'prefix': 'future/',
        'policy': 'future-v3',
        'encryptNames': true,
      });
      var rules = mode == 'unsupported' ? [future, baseline] : [baseline];
      await tester.pumpWidget(MaterialApp(
        theme: AppTheme.dark(scalePercent: 100, desktopCompact: false),
        home: Scaffold(
            body: SingleChildScrollView(
                child: StatefulBuilder(
          builder: (context, update) => ClientEncryptionEditor(
            controller: controller,
            bucketName: 'bucket',
            initiallyExpanded: true,
            rules: rules,
            onChanged: (value) => update(() => rules = value),
          ),
        ))),
      ));
      if (mode == 'unsupported') {
        expect(
            find.textContaining(unsupportedVaultPolicyNotice), findsOneWidget);
        final row = tester.widget<ListTile>(find.ancestor(
            of: find.text('bucket/future/'), matching: find.byType(ListTile)));
        expect(row.onTap, isNull);
      }
      await _tap(tester, 'bucket/');
      final picker = tester.widget<AppSelectField<ClientEncryptionPolicy>>(
          find.byKey(const ValueKey('vault-policy')));
      expect(picker.value, ClientEncryptionPolicy.standard);
      expect(
          tester
              .widget<AppSwitchTile>(
                  find.byKey(const ValueKey('vault-encrypt-names')))
              .value,
          isFalse);
      if (mode == 'names' || mode == 'unsupported') {
        tester
            .widget<AppSwitchTile>(
                find.byKey(const ValueKey('vault-encrypt-names')))
            .onChanged!(true);
        await tester.pump();
      } else if (mode == 'strict') {
        picker.onChanged!(ClientEncryptionPolicy.strict);
        await tester.pump();
        expect(find.byKey(const ValueKey('vault-encrypt-names')), findsNothing);
        expect(
            find.textContaining(
                'Uploading the same name again keeps both objects.'),
            findsOneWidget);
      }
      await _tap(tester, 'Save rule');
      if (mode == 'default') {
        expect(rules.single, baseline);
        expect(rules.single.toJson(), baseline.toJson());
        expect(rules.single.toJson().containsKey('policy'), isFalse);
        expect(rules.single.toJson().containsKey('encryptNames'), isFalse);
      } else if (mode == 'strict') {
        expect(rules.single,
            baseline.copyWith(policy: ClientEncryptionPolicy.strict));
      } else {
        expect(rules.last, baseline.copyWith(encryptNames: true));
        if (mode == 'unsupported') {
          expect(identical(rules.first, future), isTrue);
          expect(rules.first.toJson(), future.toJson());
        }
      }
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }
}
