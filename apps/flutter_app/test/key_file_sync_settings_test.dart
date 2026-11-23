import 'dart:io';
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:s3_browser_crossplat/controllers/app_controller.dart';
import 'package:s3_browser_crossplat/models/domain_models.dart';
import 'package:s3_browser_crossplat/services/encryption_key_store.dart';
import 'package:s3_browser_crossplat/services/mock_engine_service.dart';
import 'package:s3_browser_crossplat/settings/key_file_sync_settings.dart';
import 'support/key_file_sync_scenarios.dart' as fixture;
import 'package:s3_browser_crossplat/widgets/app_select_field.dart';
import 'package:s3_browser_crossplat/widgets/app_form_dialog.dart';
import 'package:s3_browser_crossplat/widgets/empty_state.dart';
import 'package:s3_browser_crossplat/theme/app_theme.dart';
import 'package:s3_browser_crossplat/theme/app_motion.dart';
import 'package:s3_browser_crossplat/utils/format.dart';
import 'package:s3_browser_crossplat/services/key_file_sync.dart';
import 'support/raw_dropdowns.dart';
import 'app_controller_test.dart' show MemoryAppStateRepository;

const profile = EndpointProfile(
    id: 'p',
    name: 'Sync S3',
    endpointUrl: 'https://example.test',
    region: 'us-east-1',
    accessKey: 'access',
    secretKey: 'secret',
    pathStyle: true,
    verifyTls: true);

Future<void> until(WidgetTester tester, bool Function() ready) async {
  for (var i = 0; i < 300 && !ready(); i++) {
    await tester.pump(const Duration(milliseconds: 20));
    await tester
        .runAsync(() => Future<void>.delayed(const Duration(milliseconds: 10)));
  }
  expect(ready(), isTrue);
  await tester.pump(const Duration(milliseconds: 300));
}

Future<void> tap(WidgetTester tester, String label) async {
  final target = find.text(label).last;
  await tester.ensureVisible(target);
  await tester.tap(target);
  await tester.pump();
}

class SetupTransport extends fixture.MemoryTransport {
  SetupTransport(super.server, this.load);
  final Future<List<String>> Function() load;
  final created = <String>[];
  @override
  Future<List<String>> buckets() => load();
  @override
  Future<void> createBucket(String bucket) async {
    created.add(bucket);
    await super.createBucket(bucket);
  }
}

void expectAppForm(WidgetTester tester) {
  expect(find.byWidgetPredicate((widget) => widget is AppFormDialog),
      findsOneWidget);
  expect(find.byType(SimpleDialog), findsNothing);
  expect(find.byType(AlertDialog), findsNothing);
  expect(rawDropdowns(), findsNothing);
  expect(tester.takeException(), isNull);
}

AppSelectField<String> select(WidgetTester tester, String label) => tester
    .widgetList<AppSelectField<String>>(find.byType(AppSelectField<String>))
    .singleWhere((field) => field.decoration?.labelText == label);

void main() {
  for (final width in [390.0, 1200.0]) {
    Future<
            ({
              AppController controller,
              EncryptionKeyStore store,
              fixture.MemoryS3 server
            })>
        mount(WidgetTester tester,
            {bool configured = false,
            String password = fixture.passphrase,
            VoidCallback? changePassphrase,
            KeyFileSyncTransport Function(fixture.MemoryS3)?
                setupTransport}) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = Size(width, 844);
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final directory = (await tester.runAsync(
          () => Directory.systemTemp.createTemp('key-sync-widget-')))!;
      final store = EncryptionKeyStore(File('${directory.path}/keys.age'),
          scryptWorkFactor: 1, deviceId: 'aaaaaaaaaaaaaaaa');
      await tester.runAsync(() => store.create(password));
      final server = fixture.MemoryS3();
      final controller = AppController(
          engineService: MockEngineService(),
          initialSettings: AppSettings.fromJson({'enableAnimations': false})
              .copyWith(keyFileSync: configured ? fixture.config : null),
          initialProfiles: [
            profile,
            const EndpointProfile(
                id: 'azure',
                name: 'Azure',
                endpointUrl: 'https://example.test',
                region: '',
                accessKey: 'access',
                secretKey: 'secret',
                pathStyle: true,
                verifyTls: true,
                endpointType: EndpointProfileType.azureBlob)
          ],
          encryptionKeyStore: store,
          appStateRepository: MemoryAppStateRepository(),
          keyFileSyncTransportFactory: (_) =>
              setupTransport?.call(server) ?? server.client());
      if (configured) {
        await tester.runAsync(() async {
          await controller.ensureEncryptionKeyStore();
          await controller.keyFileSync!.syncNow();
        });
      }
      addTearDown(() async {
        controller.dispose();
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
                      child: KeyFileSyncSettings(
                          controller: controller,
                          onChangePassphrase: () async {
                            changePassphrase?.call();
                          }))))));
      await tester.pump();
      return (controller: controller, store: store, server: server);
    }

    testWidgets('sync setup, status, manual sync and turn off at width $width',
        (tester) async {
      final state = await mount(tester);
      expect(find.text('Off'), findsOneWidget);
      expect(state.server.requests, 0);
      await tap(tester, 'Set up sync…');
      await until(tester,
          () => find.text('Set up key file sync').evaluate().isNotEmpty);
      expectAppForm(tester);
      final profiles = select(tester, 'Sync profile');
      expect(
          profiles.items.singleWhere((item) => item.value == 'azure').enabled,
          isFalse);
      expect(
          find.textContaining('Azure: Key file sync requires an S3 profile.'),
          findsOneWidget);
      profiles.onChanged!('p');
      await until(tester, () => select(tester, 'Sync bucket').items.isNotEmpty);
      select(tester, 'Sync bucket').onChanged!('keys');
      await tester.pump();
      await tap(tester, 'Turn on sync');
      await until(
          tester,
          () =>
              state.controller.settings.keyFileSync != null &&
              find.text('Set up key file sync').evaluate().isEmpty);
      await tap(tester, 'Sync now');
      await until(
          tester,
          () =>
              state.controller.keyFileSync!.state.lastSyncedAt != null &&
              state.controller.keyFileSync!.status !=
                  KeyFileSyncStatus.syncing);
      expect(find.text('Up to date'), findsOneWidget);
      expect(find.textContaining('Bucket versioning: on'), findsOneWidget);
      final bytes = state.server.bytes;
      await tap(tester, 'Turn off sync');
      await until(tester, () => state.controller.settings.keyFileSync == null);
      expect(find.text('Off'), findsOneWidget);
      expect(state.server.bytes, same(bytes));
      expect(find.textContaining('copy remains in the bucket'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    if (width == 390) {
      testWidgets('an earlier local rotation does not block joining a bucket',
          (tester) async {
        final state = await mount(tester);
        await tester.runAsync(() async {
          await state.store
              .changePassphrase(fixture.passphrase, fixture.nextPassphrase);
          state.server.write(await fixture.encrypt(fixture.doc([]),
              password: fixture.passphrase));
          await state.controller.configureKeyFileSync(fixture.config);
          await state.controller.keyFileSync!.syncNow();
        });
        await tester.pump();
        expect(state.controller.keyFileSync!.passphraseChangePending, isFalse);
        expect(state.server.puts, 0);
        expect(state.controller.keyFileSync!.status,
            KeyFileSyncStatus.passphraseMismatch);
        expect(find.text('Use bucket passphrase…'), findsOneWidget);
      });
    }

    testWidgets('sync mismatch prompt adopts remote passphrase at width $width',
        (tester) async {
      final state = await mount(tester, configured: true);
      await tester.runAsync(() async {
        state.server.write(await fixture.encrypt(fixture.doc([]),
            password: fixture.nextPassphrase));
        await state.controller.keyFileSync!.syncNow();
      });
      await tester.pump();
      expect(
          find.textContaining('uses a different passphrase'), findsOneWidget);
      await tap(tester, 'Use bucket passphrase…');
      await until(tester,
          () => find.text('Sync bucket passphrase').evaluate().isNotEmpty);
      expectAppForm(tester);
      await tester.enterText(find.byType(TextField), fixture.nextPassphrase);
      await tap(tester, 'Merge and adopt passphrase');
      await until(
          tester, () => find.text('Sync bucket passphrase').evaluate().isEmpty);
      expect(state.controller.keyFileSync!.status, KeyFileSyncStatus.upToDate);
      await tester.runAsync(() async {
        state.store.lock();
        await state.store.unlock(fixture.nextPassphrase);
      });
      expect(tester.takeException(), isNull);
    });

    testWidgets('sync setup requires longer passphrase at width $width',
        (tester) async {
      var changes = 0;
      final state = await mount(tester,
          password: 'short phrase!', changePassphrase: () => changes++);
      await tap(tester, 'Set up sync…');
      await until(tester,
          () => find.text('Longer passphrase required').evaluate().isNotEmpty);
      expectAppForm(tester);
      expect(find.textContaining('at least 16 characters to turn on sync'),
          findsOneWidget);
      await tap(tester, 'Change passphrase…');
      await until(tester, () => changes == 1);
      expect(state.server.requests, 0);
      expect(state.controller.settings.keyFileSync, isNull);
      expect(tester.takeException(), isNull);
    });
    testWidgets(
        'sync creates a versioned bucket on submit with motion disabled at width $width',
        (tester) async {
      final transports = <SetupTransport>[];
      final state = await mount(tester, setupTransport: (server) {
        final transport = SetupTransport(server, () async => ['keys']);
        transports.add(transport);
        return transport;
      });
      state.server.versioning = false;
      await tap(tester, 'Set up sync…');
      await until(tester,
          () => find.text('Set up key file sync').evaluate().isNotEmpty);
      select(tester, 'Sync profile').onChanged!('p');
      await until(tester, () => select(tester, 'Sync bucket').items.isNotEmpty);
      final create = tester.widget<TextButton>(find.ancestor(
          of: find.text('Create bucket…'),
          matching: find.byWidgetPredicate((widget) => widget is TextButton)));
      create.onPressed!();
      await tester.pump();
      expect(find.text('Bucket name'), findsOneWidget);
      // With motion off the reveal is laid out directly, with no size
      // animation. Stock button feedback may still tick, so the binding's
      // callback count is not a usable signal here.
      expect(find.byType(AnimatedSize), findsNothing);
      expect(
          tester
              .widgetList<MotionSize>(find.byType(MotionSize))
              .every((motion) => motion.duration == Duration.zero),
          isTrue);
      expect(transports.expand((transport) => transport.created), isEmpty);
      expectAppForm(tester);
      final name = find.widgetWithText(TextField, 'Bucket name');
      await tester.ensureVisible(name);
      await tester.enterText(name, 'new-keys');
      final object = find.widgetWithText(TextField, 'Object key');
      await tester.ensureVisible(object);
      await tester.enterText(object, '');
      await tap(tester, 'Turn on sync');
      await until(
          tester,
          () =>
              state.controller.settings.keyFileSync != null &&
              find.text('Set up key file sync').evaluate().isEmpty);
      expect(transports.expand((transport) => transport.created), ['new-keys']);
      expect(state.controller.settings.keyFileSync!.bucket, 'new-keys');
      expect(state.controller.settings.keyFileSync!.objectKey,
          defaultKeyFileSyncObjectKey);
      expect(state.server.versioning, isTrue);
      await until(
          tester,
          () =>
              state.controller.keyFileSync!.status ==
              KeyFileSyncStatus.upToDate);
      expect(tester.takeException(), isNull);
    });

    testWidgets('sync bucket loading and errors stay inline at width $width',
        (tester) async {
      final pending = Completer<List<String>>();
      var calls = 0;
      await mount(tester,
          setupTransport: (server) => SetupTransport(server, () {
                calls++;
                return calls == 1 ? pending.future : Future.value(['keys']);
              }));
      await tap(tester, 'Set up sync…');
      await until(tester,
          () => find.text('Set up key file sync').evaluate().isNotEmpty);
      select(tester, 'Sync profile').onChanged!('p');
      await tester.pump();
      expect(find.byType(LinearProgressIndicator), findsOneWidget);
      expectAppForm(tester);
      // Complete only after the screen has attached its error handler.
      pending.completeError(StateError('private transport details'));
      await tester.pump();
      expect(find.text('Could not load buckets. Check access and try again.'),
          findsOneWidget);
      expect(find.textContaining('private transport details'), findsNothing);
      await tap(tester, 'Retry');
      await until(tester, () => select(tester, 'Sync bucket').items.isNotEmpty);
      expect(find.text('Could not load buckets. Check access and try again.'),
          findsNothing);
      expectAppForm(tester);
    });

    testWidgets(
        'earlier versions selects and imports in one form at width $width',
        (tester) async {
      final state = await mount(tester, configured: true);
      await tap(tester, 'Earlier versions…');
      await until(
          tester,
          () =>
              find.text('Version passphrase').evaluate().isNotEmpty &&
              find.byType(LinearProgressIndicator).evaluate().isEmpty);
      expectAppForm(tester);
      expect(find.text(formatDateTime(DateTime.utc(2026, 11, 15).toLocal())),
          findsOneWidget);
      final row = find.byWidgetPredicate(
          (widget) => widget is ListTile && widget.onTap != null);
      await tester.ensureVisible(row);
      await tester.tap(row);
      await tester.pump();
      final password = find.widgetWithText(TextField, 'Version passphrase');
      await tester.ensureVisible(password);
      await tester.enterText(password, fixture.passphrase);
      // Let the form rebuild so its submit button enables.
      await tester.pump();
      await tap(tester, 'Import keys');
      await until(
          tester, () => find.text('Version passphrase').evaluate().isEmpty);
      expect(state.store.isUnlocked, isTrue);
      expect(tester.takeException(), isNull);
    });

    testWidgets(
        'earlier versions loading and retry stay inside the form at width $width',
        (tester) async {
      final state = await mount(tester, configured: true);
      final pending = Completer<void>();
      state.server.beforeRequest = (method) async {
        if (method == 'GET') await pending.future;
      };
      await tap(tester, 'Earlier versions…');
      expect(find.text('Version passphrase'), findsOneWidget);
      expect(find.byType(LinearProgressIndicator), findsOneWidget);
      expectAppForm(tester);
      state.server.beforeRequest = null;
      pending.completeError(StateError('private version response'));
      await until(
          tester,
          () => find
              .text(
                  'Could not load earlier versions. Check access and try again.')
              .evaluate()
              .isNotEmpty);
      expect(find.byType(EmptyState), findsOneWidget);
      expect(find.textContaining('private version response'), findsNothing);
      await tap(tester, 'Retry');
      await until(
          tester,
          () =>
              find.byType(EmptyState).evaluate().isEmpty &&
              find.byType(LinearProgressIndicator).evaluate().isEmpty);
      expectAppForm(tester);
    });

    testWidgets('earlier versions uses empty state at width $width',
        (tester) async {
      final state = await mount(tester, configured: true);
      state.server.versions.clear();
      await tap(tester, 'Earlier versions…');
      await until(tester, () => find.byType(EmptyState).evaluate().isNotEmpty);
      expect(find.text('No earlier versions are available.'), findsOneWidget);
      expectAppForm(tester);
    });
  }
}
