import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:s3_browser_crossplat/main.dart';
import 'package:s3_browser_crossplat/app/s3_browser_app.dart';
import 'package:s3_browser_crossplat/models/domain_models.dart';
import 'package:s3_browser_crossplat/services/app_state_repository.dart';
import 'package:s3_browser_crossplat/services/profile_secret_store.dart';
import 'improvements_test.dart' as fixture;

import 'package:flutter_test/flutter_test.dart';
import 'package:s3_browser_crossplat/services/app_bootstrap.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  for (final failHydration in [false, true]) {
    test(
        'bootstrap awaits one credential read and preserves ${failHydration ? 'failure' : 'success'} guards',
        () async {
      final directory =
          await Directory.systemTemp.createTemp('bootstrap-hydration-');
      addTearDown(() => directory.delete(recursive: true));
      final file = File('${directory.path}/object-data-browser-state.json');
      final settings = AppSettings.fromJson({
        'defaultEngineId': 'python',
        'enableAnimations': false,
        'downloadPath': directory.path,
        'tempPath': directory.path
      });
      final metadata = jsonEncode({
        'settings': settings.toJson(),
        'selectedProfileId': fixture.profile.id,
        'profiles': [
          fixture.profile.toJson()
            ..remove('accessKey')
            ..remove('secretKey')
            ..remove('sessionToken')
        ],
      });
      await file.writeAsString(metadata);
      final secrets = _DelayedSecretStore();
      final repository = LocalAppStateRepository(
          secretStore: secrets,
          applicationSupportDirectoryProvider: () async => directory);
      final engine = _ListingEngine();
      var ready = false;
      final initialization = AppBootstrap.initialize(
          appStateRepository: repository,
          engineService: engine,
          downloadPathProvider: () async => directory.path,
          temporaryDirectoryProvider: () async => directory).then((controller) {
        ready = true;
        return controller;
      });
      await secrets.started.future;
      expect(ready, false);
      expect(engine.bucketCalls, 0);
      if (failHydration) {
        secrets.pending.completeError(const FileSystemException('denied'));
      } else {
        secrets.pending.complete(jsonEncode({
          'version': 2,
          'profiles': {
            fixture.profile.id: {
              'accessKey': 'hydrated',
              'secretKey': 'hydrated-secret',
              'sessionToken': null
            }
          }
        }));
      }
      final controller = await initialization;
      addTearDown(controller.dispose);
      expect(engine.bucketCalls, 0);
      await controller.initialize();
      expect(secrets.readCalls, ['profiles.credentials.v2']);
      if (failHydration) {
        expect(engine.bucketCalls, 0);
        await controller
            .updateSettings(controller.settings.copyWith(darkMode: true));
        await expectLater(
            repository.saveState(
                settings: controller.settings,
                profiles: controller.profiles,
                selectedProfileId: fixture.profile.id),
            throwsA(isA<CredentialStoreException>()));
        expect(await file.readAsString(), metadata);
        expect(secrets.writes, 0);
      } else {
        expect(engine.bucketCalls, greaterThan(0));
        expect(engine.listedProfile?.accessKey, 'hydrated');
      }
    });

    testWidgets(
        'bootstrap paints before delayed ${failHydration ? 'denied' : 'successful'} hydration',
        (tester) async {
      final repository = _DelayedRepository();
      final engine = _ListingEngine();
      await tester.pumpWidget(BootstrapApp(initialize: () {
        expect(find.text('Loading…'), findsOneWidget,
            reason: 'bootstrap starts only after the loading frame');
        return AppBootstrap.initialize(
            appStateRepository: repository,
            engineService: engine,
            downloadPathProvider: () async => '/tmp',
            temporaryDirectoryProvider: () async => Directory('/tmp'));
      }));
      await tester.pump();
      expect(repository.loads, 1);
      expect(find.text('Loading…'), findsOneWidget);
      expect(find.byType(S3BrowserApp), findsNothing);
      expect(engine.bucketCalls, 0);
      repository.pending.complete(StoredAppState(
          settings: AppSettings.fromJson(
              {'defaultEngineId': 'python', 'enableAnimations': false}),
          profiles: [
            failHydration
                ? fixture.profile.copyWith(accessKey: '', secretKey: '')
                : fixture.profile
          ],
          selectedProfileId: fixture.profile.id,
          credentialStoreError:
              failHydration ? 'Keychain access failed' : null));
      await tester.pumpAndSettle();
      expect(find.byType(S3BrowserApp), findsOneWidget);
      expect(repository.loads, 1);
      expect(engine.bucketCalls, failHydration ? 0 : greaterThan(0));
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }

  testWidgets('bootstrap fatal errors retain the visible startup error path',
      (tester) async {
    await tester.pumpWidget(BootstrapApp(initialize: () async {
      throw StateError('bootstrap fixture failure');
    }));
    await tester.pumpAndSettle();
    expect(find.textContaining('Failed to start the app.'), findsOneWidget);
    expect(find.textContaining('bootstrap fixture failure'), findsOneWidget);
    expect(find.byType(S3BrowserApp), findsNothing);
  });

  test('iOS download path resolves to the app Documents directory', () async {
    final path = await AppBootstrap.resolveDownloadPath(
      isAndroid: false,
      isIOS: true,
      documentsDirectoryProvider: () async => Directory('/ios/Documents'),
    );

    expect(path, '/ios/Documents');
  });

  test('Android native Downloads path remains preferred', () async {
    final path = await AppBootstrap.resolveDownloadPath(
      isAndroid: true,
      isIOS: false,
      androidDownloadsPath: () async => '/storage/emulated/0/Download',
    );

    expect(path, '/storage/emulated/0/Download');
  });
}

class _DelayedSecretStore extends ProfileSecretStore {
  final started = Completer<void>();
  final pending = Completer<String?>();
  final readCalls = <String>[];
  int writes = 0;
  @override
  bool get supportsPrimaryBulkRead => false;
  @override
  bool get supportsFallbackBulkRead => false;
  @override
  Future<String?> readSecret(String key) {
    readCalls.add(key);
    started.complete();
    return pending.future;
  }

  @override
  Future<String?> readFallbackMacSecret(String key) async => null;
  @override
  Future<void> saveSecret(String key, String value) async {
    writes++;
  }
}

class _ListingEngine extends fixture.TestingEngine {
  int bucketCalls = 0;
  EndpointProfile? listedProfile;
  @override
  Future<List<BucketSummary>> listBuckets(
      {required String engineId, required EndpointProfile profile}) async {
    bucketCalls++;
    listedProfile = profile;
    return super.listBuckets(engineId: engineId, profile: profile);
  }
}

class _DelayedRepository extends fixture.Repository {
  final pending = Completer<StoredAppState?>();
  int loads = 0;
  @override
  Future<StoredAppState?> loadState() {
    loads++;
    return pending.future;
  }
}
