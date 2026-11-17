import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:s3_browser_crossplat/browser/bucket_encryption_dialog.dart';
import 'package:s3_browser_crossplat/browser/json_editor_dialog.dart';
import 'package:s3_browser_crossplat/controllers/app_controller.dart';
import 'package:s3_browser_crossplat/models/domain_models.dart';
import 'package:s3_browser_crossplat/services/encryption_key_store.dart';
import 'package:s3_browser_crossplat/services/mock_engine_service.dart';
import 'package:s3_browser_crossplat/settings/encryption_settings.dart';
import 'package:s3_browser_crossplat/settings/encryption_setup_guide.dart';
import 'package:s3_browser_crossplat/settings/encryption_connection_editor.dart';
import 'package:s3_browser_crossplat/theme/app_theme.dart';
import 'package:s3_browser_crossplat/widgets/app_select_field.dart';
import 'package:s3_browser_crossplat/widgets/app_switch.dart';
import 'app_controller_test.dart' show MemoryAppStateRepository;
import 'object_encryption_test.dart' show encryptionProfile;
import 'support/raw_dropdowns.dart';

class _EncryptionEngine extends MockEngineService {
  final writes = <String>[];
  int deletes = 0, reads = 0;
  bool deny = false, failRead = false;

  /// What the server holds. By default it is whatever the controller last
  /// loaded or wrote, i.e. nobody else changed it.
  BucketAdminState? Function()? live;

  /// Set to simulate another client changing the configuration.
  String? remoteJson;

  @override
  Future<BucketAdminState> putBucketEncryption(
      {required String engineId,
      required EndpointProfile profile,
      required String bucketName,
      required String encryptionJson}) async {
    writes.add(encryptionJson);
    if (deny) {
      throw const EngineException(
          code: ErrorCode.authFailed, message: 'Denied by policy');
    }
    return super.putBucketEncryption(
        engineId: engineId,
        profile: profile,
        bucketName: bucketName,
        encryptionJson: encryptionJson);
  }

  @override
  Future<BucketAdminState> deleteBucketEncryption(
      {required String engineId,
      required EndpointProfile profile,
      required String bucketName}) async {
    deletes++;
    return super.deleteBucketEncryption(
        engineId: engineId, profile: profile, bucketName: bucketName);
  }

  @override
  Future<BucketAdminState> getBucketAdminState(
      {required String engineId,
      required EndpointProfile profile,
      required String bucketName}) async {
    reads++;
    if (failRead) {
      throw const EngineException(
          code: ErrorCode.timeout, message: 'Read timed out');
    }
    final state = live?.call() ??
        await super.getBucketAdminState(
            engineId: engineId, profile: profile, bucketName: bucketName);
    return remoteJson == null
        ? state
        : state.copyWith(encryptionJson: remoteJson, encryptionEnabled: true);
  }

  @override
  Future<List<CapabilityDescriptor>> getCapabilities(
      {required String engineId, required EndpointProfile profile}) async {
    reads++;
    return super.getCapabilities(engineId: engineId, profile: profile);
  }

  @override
  Future<List<BucketSummary>> listBuckets(
      {required String engineId, required EndpointProfile profile}) async {
    reads++;
    return super.listBuckets(engineId: engineId, profile: profile);
  }
}

Future<void> _tap(WidgetTester tester, String label) async {
  final target = find.text(label).last;
  await tester.ensureVisible(target);
  await tester.pump(const Duration(milliseconds: 300));
  await tester.tap(target);
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 300));
}

Future<void> _wait(WidgetTester tester, bool Function() ready) async {
  for (var i = 0; i < 500 && !ready(); i++) {
    await tester
        .runAsync(() => Future<void>.delayed(const Duration(milliseconds: 10)));
    await tester.pump(const Duration(milliseconds: 10));
  }
  expect(ready(), isTrue);
  await tester.pump(const Duration(milliseconds: 300));
}

void main() {
  late Directory directory;
  late EncryptionKeyStore store;
  late _EncryptionEngine engine;
  late AppController controller;
  late MemoryAppStateRepository repository;

  setUp(() async {
    directory =
        await Directory.systemTemp.createTemp('bucket-encryption-form-');
    store = EncryptionKeyStore(File('${directory.path}/keys.age'),
        scryptWorkFactor: 1);
    engine = _EncryptionEngine();
    repository = MemoryAppStateRepository();
    controller = AppController(
        engineService: engine,
        initialSettings: AppSettings.fromJson({'enableAnimations': false}),
        initialProfiles: const [encryptionProfile],
        encryptionKeyStore: store,
        appStateRepository: repository);
    controller.selectedProfile = controller.profiles.single;
    controller.selectedBucket = const BucketSummary(
        name: 'bucket',
        region: 'us-east-1',
        objectCountHint: 0,
        versioningEnabled: false);
    controller.buckets = [controller.selectedBucket!];
    controller.capabilities = const [
      CapabilityDescriptor(
          key: 'object.clientEncryption',
          label: 'Vault',
          state: CapabilityState.supported),
      CapabilityDescriptor(
          key: 'bucket.encryption',
          label: 'Bucket encryption',
          state: CapabilityState.supported),
    ];
    controller.adminState = (await engine.getBucketAdminState(
            engineId: 'rust', profile: encryptionProfile, bucketName: 'bucket'))
        .copyWith(encryptionJson: '{}', encryptionEnabled: false);
    engine.live = () => controller.adminState;
    engine.reads = 0;
  });
  tearDown(() async {
    controller.dispose();
    await directory.delete(recursive: true);
  });

  Future<void> open(WidgetTester tester, double width) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = Size(width, 1000);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(MaterialApp(
        theme: AppTheme.dark(scalePercent: 100, desktopCompact: false),
        home: Scaffold(
            body: Builder(
                builder: (context) => TextButton(
                    onPressed: () =>
                        showBucketEncryptionDialog(context, controller),
                    child: const Text('Open'))))));
    await _tap(tester, 'Open');
  }

  for (final width in [390.0, 1280.0]) {
    testWidgets('SSE-KMS form dispatches key and bucket key at width $width',
        (tester) async {
      await open(tester, width);
      expect(engine.writes, isEmpty);
      final select = tester.widget<AppSelectField<String>>(
          find.byKey(const ValueKey('bucket-encryption-mode')));
      select.onChanged!('aws:kms');
      await tester.pump();
      await tester.enterText(
          find.widgetWithText(TextField, 'KMS key ID or ARN'),
          'arn:fixture:key');
      final toggle = tester.widget<AppSwitchTile>(
          find.byKey(const ValueKey('bucket-encryption-bucket-key')));
      toggle.onChanged!(true);
      await tester.pump();
      await _tap(tester, 'Save');
      expect(engine.writes, hasLength(1));
      expect(jsonDecode(engine.writes.single), {
        'Rules': [
          {
            'ApplyServerSideEncryptionByDefault': {
              'SSEAlgorithm': 'aws:kms',
              'KMSMasterKeyID': 'arn:fixture:key'
            },
            'BucketKeyEnabled': true
          }
        ]
      });
      expect(engine.deletes, 0);
      expect(rawDropdowns(), findsNothing);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('an engine reporting the capability as unknown keeps the form',
      (tester) async {
    // Go reports "unknown" for S3-compatible endpoints until a call is tried.
    controller.capabilities = const [
      CapabilityDescriptor(
          key: 'bucket.encryption',
          label: 'Bucket encryption',
          state: CapabilityState.unknown),
    ];
    await open(tester, 1280);
    expect(
        find.byKey(const ValueKey('bucket-encryption-mode')), findsOneWidget);
    expect(find.text('Edit as JSON…'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('an explicitly unsupported capability hides the server form',
      (tester) async {
    controller.capabilities = const [
      CapabilityDescriptor(
          key: 'bucket.encryption',
          label: 'Bucket encryption',
          state: CapabilityState.unsupported),
    ];
    await open(tester, 1280);
    expect(find.byKey(const ValueKey('bucket-encryption-mode')), findsNothing);
    expect(find.text('Edit as JSON…'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('unloaded configuration is loaded on request, never assumed',
      (tester) async {
    controller.adminState = null;
    await open(tester, 1280);
    expect(find.byKey(const ValueKey('bucket-encryption-mode')), findsNothing);
    expect(engine.reads, 0);
    await _tap(tester, 'Load configuration');
    await _wait(
        tester,
        () => find
            .byKey(const ValueKey('bucket-encryption-mode'))
            .evaluate()
            .isNotEmpty);
    expect(engine.reads, greaterThan(0));
    expect(engine.writes, isEmpty);
    expect(engine.deletes, 0);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a configuration changed by another client is not overwritten',
      (tester) async {
    await open(tester, 1280);
    engine.remoteJson = jsonEncode({
      'Rules': [
        {
          'ApplyServerSideEncryptionByDefault': {'SSEAlgorithm': 'aws:kms'},
          'BlockedEncryptionTypes': {
            'EncryptionType': ['SSE-C']
          }
        }
      ]
    });
    final select = tester.widget<AppSelectField<String>>(
        find.byKey(const ValueKey('bucket-encryption-mode')));
    select.onChanged!('AES256');
    await tester.pump();
    await _tap(tester, 'Save');
    await tester.pump(const Duration(milliseconds: 300));
    expect(engine.writes, isEmpty);
    expect(engine.deletes, 0);
    expect(find.textContaining('configuration changed'), findsWidgets);
  });

  testWidgets('a failed freshness read blocks the save', (tester) async {
    await open(tester, 1280);
    // Another client changed the document, and the read that would show it
    // fails: the stale copy must not pass for the live one.
    engine.remoteJson = jsonEncode({
      'Rules': [
        {
          'ApplyServerSideEncryptionByDefault': {'SSEAlgorithm': 'aws:kms'},
          'BlockedEncryptionTypes': {
            'EncryptionType': ['SSE-C']
          }
        }
      ]
    });
    engine.failRead = true;
    final select = tester.widget<AppSelectField<String>>(
        find.byKey(const ValueKey('bucket-encryption-mode')));
    select.onChanged!('AES256');
    await tester.pump();
    await _tap(tester, 'Save');
    await tester.pump(const Duration(milliseconds: 300));
    expect(engine.writes, isEmpty);
    expect(engine.deletes, 0);
    expect(
        find.byKey(const ValueKey('bucket-encryption-mode')), findsOneWidget);
    // A read that was skipped because another one is in flight is no proof
    // either.
    engine.failRead = false;
    engine.remoteJson = null;
    final reads = controller.bucketAdminReads;
    await controller.refreshBucketAdminState();
    expect(controller.bucketAdminReads, reads + 1);
  });

  testWidgets('a second rule for the same bucket and prefix is refused',
      (tester) async {
    await tester.runAsync(() async {
      await store.create('test-passphrase');
      await store.generateAgeIdentity('Bucket vault');
    });
    await open(tester, 1280);
    await _tap(tester, 'Encrypt new uploads to this bucket');
    await _tap(tester, 'Add vault rule');
    await _wait(tester, () => find.text('Save rule').evaluate().isNotEmpty);
    final keySelect = find.byWidgetPredicate((w) =>
        w is AppSelectField<String> && w.decoration?.labelText == 'Vault key');
    tester
        .widget<AppSelectField<String>>(keySelect.last)
        .onChanged!(store.records.single.id);
    await tester.pump();
    await _tap(tester, 'Save rule');
    expect(find.textContaining('already exists'), findsOneWidget);
    expect(find.text('Save rule'), findsOneWidget);
  });

  test('saving encryption elsewhere is carried into an open profile draft',
      () async {
    const rule = ClientEncryptionRule(
        bucket: 'bucket',
        keyId: 'key-1',
        recipient: 'age1examplerecipient',
        label: 'Bucket vault');
    const other = ClientEncryptionRule(
        bucket: 'other',
        keyId: 'key-2',
        recipient: 'age1otherrecipient',
        label: 'Other vault');
    final saved = controller.profiles.single;
    // The Connections editor holds an unsaved Notes edit.
    controller.profileDraftBases[saved.id] = saved;
    controller.profileDrafts[saved.id] = saved.copyWith(notes: 'draft note');
    await controller
        .saveProfile(saved.copyWith(clientEncryptionRules: const [rule]));
    final draft = controller.profileDrafts[saved.id]!;
    expect(draft.notes, 'draft note');
    expect(draft.clientEncryptionRules, const [rule]);
    expect(controller.profileDraftBases[saved.id]!.clientEncryptionRules,
        const [rule]);

    // A draft that edited the rules itself keeps its own edit.
    controller.profileDrafts[saved.id] =
        draft.copyWith(clientEncryptionRules: const [other]);
    await controller.saveProfile(
        controller.profiles.single.copyWith(clientEncryptionRules: const []));
    expect(controller.profileDrafts[saved.id]!.clientEncryptionRules,
        const [other]);
  });

  testWidgets('unchanged default form makes no request', (tester) async {
    await open(tester, 390);
    await _tap(tester, 'Save');
    expect(engine.reads, 0);
    expect(engine.writes, isEmpty);
    expect(engine.deletes, 0);
    expect(repository.storedState, isNull);
  });

  testWidgets('selection changes cannot redirect a bucket save',
      (tester) async {
    await open(tester, 1280);
    tester
        .widget<AppSelectField<String>>(
            find.byKey(const ValueKey('bucket-encryption-mode')))
        .onChanged!('AES256');
    await tester.pump();
    controller.activeEngineId = 'go';
    await _tap(tester, 'Save');
    expect(engine.writes, isEmpty);
    expect(find.textContaining('The target changed.'), findsOneWidget);
  });

  testWidgets('unknown fields survive a form save', (tester) async {
    controller.adminState = controller.adminState!.copyWith(
        encryptionJson:
            '{"Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"aws:kms","FutureDefault":42},"BlockedEncryptionTypes":{"EncryptionType":["SSE-C"]}}]}');
    await open(tester, 1280);
    await tester.enterText(
        find.widgetWithText(TextField, 'KMS key ID or ARN'), 'new-key');
    await _tap(tester, 'Save');
    final rule = jsonDecode(engine.writes.single)['Rules'][0];
    expect(rule['BlockedEncryptionTypes'], {
      'EncryptionType': ['SSE-C']
    });
    expect(rule['ApplyServerSideEncryptionByDefault']['FutureDefault'], 42);
  });

  testWidgets('Edit as JSON keeps the existing editor and save path',
      (tester) async {
    await open(tester, 1280);
    await _tap(tester, 'Edit as JSON…');
    expect(find.byType(JsonEditorDialog), findsOneWidget);
    await tester.enterText(
        find.descendant(
            of: find.byType(JsonEditorDialog),
            matching: find.byType(TextField)),
        '{"Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"AES256"}}]}');
    await _tap(tester, 'Save');
    expect(
        jsonDecode(engine.writes.single)['Rules'][0]
            ['ApplyServerSideEncryptionByDefault']['SSEAlgorithm'],
        'AES256');
    expect(find.byType(JsonEditorDialog), findsNothing);
  });

  testWidgets('multiple rules offer JSON only for server settings',
      (tester) async {
    controller.adminState =
        controller.adminState!.copyWith(encryptionJson: '{"Rules":[{},{}]}');
    await open(tester, 1280);
    expect(find.byKey(const ValueKey('bucket-encryption-mode')), findsNothing);
    expect(find.textContaining('cannot be safely represented'), findsOneWidget);
    await _tap(tester, 'Edit as JSON…');
    expect(find.byType(JsonEditorDialog), findsOneWidget);
    expect(engine.writes, isEmpty);
  });

  testWidgets('provider default requires confirmation before DELETE',
      (tester) async {
    controller.adminState = controller.adminState!.copyWith(
        encryptionEnabled: true,
        encryptionJson:
            '{"Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"AES256"}}]}');
    await open(tester, 1280);
    tester
        .widget<AppSelectField<String>>(
            find.byKey(const ValueKey('bucket-encryption-mode')))
        .onChanged!('');
    await tester.pump();
    await _tap(tester, 'Save');
    expect(engine.deletes, 0);
    await _tap(tester, 'Remove rule');
    expect(engine.deletes, 1);
    expect(engine.writes, isEmpty);
  });

  testWidgets('denied form save stays open without a fallback request',
      (tester) async {
    engine.deny = true;
    await open(tester, 1280);
    tester
        .widget<AppSelectField<String>>(
            find.byKey(const ValueKey('bucket-encryption-mode')))
        .onChanged!('AES256');
    await tester.pump();
    await _tap(tester, 'Save');
    expect(engine.writes, hasLength(1));
    expect(engine.deletes, 0);
    expect(find.byType(BucketEncryptionDialog), findsOneWidget);
    expect(find.textContaining('Denied by policy'), findsOneWidget);
  });

  testWidgets('vault form adds and securely persists an active-profile rule',
      (tester) async {
    await tester.runAsync(() async {
      await store.create('test-passphrase');
      await store.generateAgeIdentity('Bucket vault');
    });
    await open(tester, 1280);
    await _tap(tester, 'Add vault rule');
    await _wait(tester, () => find.text('Save rule').evaluate().isNotEmpty);
    await tester.enterText(
        find.widgetWithText(TextField, 'Prefix (optional)'), 'private/');
    final keySelect = find.byWidgetPredicate((w) =>
        w is AppSelectField<String> && w.decoration?.labelText == 'Vault key');
    // The rule dialog sits above the bucket dialog's own quick-setup select.
    tester
        .widget<AppSelectField<String>>(keySelect.last)
        .onChanged!(store.records.single.id);
    await tester.pump();
    await _tap(tester, 'Save rule');
    expect(controller.selectedProfile!.clientEncryptionRules, isEmpty);
    await _tap(tester, 'Save');
    final rule = controller.selectedProfile!.clientEncryptionRules.single;
    expect(rule.bucket, 'bucket');
    expect(rule.prefix, 'private/');
    expect(rule.label, 'Bucket vault');
    expect(
        repository.storedState!.profiles.single.clientEncryptionRules, [rule]);
    expect(repository.lastAllowCredentialStoreRecovery, isTrue);
    expect(engine.writes, isEmpty);
    expect(engine.deletes, 0);
  });

  testWidgets('one step encrypts the whole bucket with the only vault key',
      (tester) async {
    await tester.runAsync(() async {
      await store.create('test-passphrase');
      await store.generateAgeIdentity('Bucket vault');
    });
    await open(tester, 1280);
    expect(find.text('Off for this bucket.'), findsOneWidget);
    await _tap(tester, 'Encrypt new uploads to this bucket');
    // Staged only: nothing is written until the dialog is saved.
    expect(controller.selectedProfile!.clientEncryptionRules, isEmpty);
    expect(find.byKey(const ValueKey('bucket-vault-enable')), findsNothing);
    await _tap(tester, 'Save');
    final rule = controller.selectedProfile!.clientEncryptionRules.single;
    expect(rule.bucket, 'bucket');
    expect(rule.prefix, isEmpty);
    expect(rule.keyId, store.records.single.id);
    expect(rule.recipient, store.records.single.fingerprint);
    expect(
        rule,
        ClientEncryptionRule(
            bucket: 'bucket',
            keyId: store.records.single.id,
            recipient: store.records.single.fingerprint,
            label: store.records.single.label));
    expect(rule.toJson().containsKey('policy'), isFalse);
    expect(rule.toJson().containsKey('encryptNames'), isFalse);
    expect(
        repository.storedState!.profiles.single.clientEncryptionRules, [rule]);
    expect(engine.writes, isEmpty);
    expect(engine.deletes, 0);
    expect(tester.takeException(), isNull);
  });

  for (final strict in [false, true]) {
    testWidgets('one-step protection stages names, strict=$strict',
        (tester) async {
      await tester.runAsync(() async {
        await store.create('test-passphrase');
        await store.generateAgeIdentity('Bucket vault');
      });
      await open(tester, 1280);
      if (strict) {
        tester
            .widget<AppSelectField<ClientEncryptionPolicy>>(
                find.byKey(const ValueKey('bucket-vault-policy')))
            .onChanged!(ClientEncryptionPolicy.strict);
      } else {
        tester
            .widget<AppSwitchTile>(
                find.byKey(const ValueKey('bucket-vault-encrypt-names')))
            .onChanged!(true);
      }
      await tester.pump();
      expect(find.byKey(const ValueKey('bucket-vault-encrypt-names')),
          strict ? findsNothing : findsOneWidget);
      await _tap(tester, 'Encrypt new uploads to this bucket');
      expect(controller.selectedProfile!.clientEncryptionRules, isEmpty);
      await _tap(tester, 'Save');
      final rule = controller.selectedProfile!.clientEncryptionRules.single;
      expect(
          rule.policy,
          strict
              ? ClientEncryptionPolicy.strict
              : ClientEncryptionPolicy.standard);
      expect(rule.encryptNames, !strict);
      expect(engine.writes, isEmpty);
    });
  }

  testWidgets('existing whole-bucket protection changes only on Save',
      (tester) async {
    const original = ClientEncryptionRule(
        bucket: 'bucket',
        keyId: 'vault',
        recipient: 'age1existing',
        label: 'Existing');
    controller.profiles = [
      encryptionProfile.copyWith(clientEncryptionRules: const [original])
    ];
    controller.selectedProfile = controller.profiles.single;
    await open(tester, 1280);
    tester
        .widget<AppSelectField<ClientEncryptionPolicy>>(
            find.byKey(const ValueKey('bucket-vault-policy')))
        .onChanged!(ClientEncryptionPolicy.strict);
    await tester.pump();
    expect(controller.selectedProfile!.clientEncryptionRules, const [original]);
    expect(
        find.byKey(const ValueKey('bucket-vault-encrypt-names')), findsNothing);
    await _tap(tester, 'Save');
    expect(controller.selectedProfile!.clientEncryptionRules,
        [original.copyWith(policy: ClientEncryptionPolicy.strict)]);
    expect(engine.writes, isEmpty);
    expect(engine.reads, 0);
  });

  testWidgets('one-step vault setup stays disabled without a vault key',
      (tester) async {
    await open(tester, 390);
    final enable = tester.widget<FilledButton>(
        find.byKey(const ValueKey('bucket-vault-enable')));
    expect(enable.onPressed, isNull);
    expect(controller.selectedProfile!.clientEncryptionRules, isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets('vault rule offers the shared key generation flow',
      (tester) async {
    await tester.runAsync(() => store.create('test-passphrase'));
    await open(tester, 1280);
    await _tap(tester, 'Add vault rule');
    await _tap(tester, 'Generate vault key…');
    expect(find.text('Generate vault key'), findsOneWidget);
    await _wait(tester, () {
      final field = find.byKey(const ValueKey('generated-encryption-key'));
      return field.evaluate().isNotEmpty &&
          tester.widget<TextField>(field).controller!.text.isNotEmpty;
    });
    await tester.enterText(
        find.widgetWithText(TextField, 'Key label'), 'New vault');
    await _tap(tester, 'Generate key');
    await _wait(
        tester,
        () =>
            store.records.isNotEmpty &&
            find.text('Generate vault key').evaluate().isEmpty);
    expect(store.records.single.type, EncryptionKeyType.ageIdentity);
    // Both the rule dialog and the bucket dialog's one-step setup pick up the
    // new key without reopening.
    final pickers = tester.widgetList<AppSelectField<String>>(
        find.byWidgetPredicate((w) =>
            w is AppSelectField<String> &&
            w.decoration?.labelText == 'Vault key'));
    expect(pickers, hasLength(2));
    for (final picker in pickers) {
      expect(picker.items.single.label, 'New vault');
    }
    expect(engine.writes, isEmpty);
  });

  testWidgets(
      'opening Encryption settings makes no engine call and shows six guide entries',
      (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1280, 1200);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: SingleChildScrollView(
                child: EncryptionSettings(controller: controller)))));
    await _wait(tester, () {
      final button = find.ancestor(
          of: find.text('Create key file…'),
          matching: find.byWidgetPredicate((w) => w is FilledButton));
      return button.evaluate().isNotEmpty &&
          tester.widget<FilledButton>(button).onPressed != null;
    });
    expect(engine.reads, 0);
    expect(engine.writes, isEmpty);
    expect(engine.deletes, 0);
    expect(controller.profiles.single.uploadEncryption, isNull);
    expect(controller.profiles.single.clientEncryptionRules, isEmpty);
    final guide = find.byType(EncryptionSetupGuide);
    expect(guide, findsOneWidget);
    expect(find.descendant(of: guide, matching: find.byType(ExpansionTile)),
        findsNWidgets(6));
    for (final label in EncryptionSetupGuide.entries.keys) {
      expect(find.descendant(of: guide, matching: find.text(label)),
          findsOneWidget);
    }
    expect(find.byType(EncryptionByConnection), findsOneWidget);
    await _tap(tester, 'Edit…');
    expect(engine.reads, 0);
    expect(engine.writes, isEmpty);
    expect(tester.takeException(), isNull);
  });
}
