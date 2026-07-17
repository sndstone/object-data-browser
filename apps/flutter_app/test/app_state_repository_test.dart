import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:s3_browser_crossplat/models/domain_models.dart';
import 'package:s3_browser_crossplat/services/app_state_repository.dart';
import 'package:s3_browser_crossplat/services/profile_secret_store.dart';

class ThrowingProfileSecretStore extends ProfileSecretStore {
  @override
  Future<void> saveSecret(String key, String value) async {
    throw const FileSystemException('secure storage unavailable');
  }

  @override
  Future<String?> readSecret(String key) async {
    throw const FileSystemException('secure storage unavailable');
  }

  @override
  Future<Map<String, String>> readAllSecrets() async {
    throw const FileSystemException('secure storage unavailable');
  }

  @override
  Future<String?> readFallbackMacSecret(String key) async {
    throw const FileSystemException('secure storage unavailable');
  }

  @override
  Future<Map<String, String>> readAllFallbackMacSecrets() async {
    throw const FileSystemException('secure storage unavailable');
  }

  @override
  Future<void> deleteSecret(String key) async {
    throw const FileSystemException('secure storage unavailable');
  }
}

class RecordingProfileSecretStore extends ProfileSecretStore {
  RecordingProfileSecretStore(
    this.values, {
    Map<String, String>? dataProtectionValues,
  }) : dataProtectionValues = dataProtectionValues ?? {};

  final Map<String, String> values;
  final Map<String, String> dataProtectionValues;
  final List<String> readCalls = [];
  final List<String> writeCalls = [];
  int readAllCalls = 0;
  int dataProtectionReadAllCalls = 0;

  @override
  bool get supportsPrimaryBulkRead => true;

  @override
  bool get supportsFallbackBulkRead => true;

  @override
  Future<String?> readSecret(String key) async {
    readCalls.add(key);
    return values[key];
  }

  @override
  Future<Map<String, String>> readAllSecrets() async {
    readAllCalls += 1;
    return Map<String, String>.from(values);
  }

  @override
  Future<String?> readFallbackMacSecret(String key) async {
    return dataProtectionValues[key];
  }

  @override
  Future<Map<String, String>> readAllFallbackMacSecrets() async {
    dataProtectionReadAllCalls += 1;
    return Map<String, String>.from(dataProtectionValues);
  }

  @override
  Future<void> saveSecret(String key, String value) async {
    writeCalls.add(key);
    values[key] = value;
  }

  @override
  Future<void> deleteSecret(String key) async {
    values.remove(key);
  }

  void resetCalls() {
    readCalls.clear();
    writeCalls.clear();
    readAllCalls = 0;
    dataProtectionReadAllCalls = 0;
  }
}

class ReadFailingWritableProfileSecretStore extends ProfileSecretStore {
  final Map<String, String> values = {};
  final List<String> writeCalls = [];

  @override
  Future<String?> readSecret(String key) async {
    throw const FileSystemException('keychain read denied');
  }

  @override
  Future<Map<String, String>> readAllSecrets() async {
    throw const FileSystemException('keychain read denied');
  }

  @override
  Future<String?> readFallbackMacSecret(String key) async => null;

  @override
  Future<Map<String, String>> readAllFallbackMacSecrets() async => {};

  @override
  Future<void> saveSecret(String key, String value) async {
    writeCalls.add(key);
    values[key] = value;
  }
}

class LegacyBulkUnsupportedProfileSecretStore
    extends RecordingProfileSecretStore {
  LegacyBulkUnsupportedProfileSecretStore(super.values);

  @override
  bool get supportsPrimaryBulkRead => false;
}

const _settings = AppSettings(
  darkMode: false,
  defaultEngineId: 'rust',
  downloadPath: '/tmp/downloads',
  tempPath: '/tmp',
  transferConcurrency: 8,
  multipartThresholdMiB: 32,
  multipartChunkMiB: 8,
  dynamicMultipartSizing: true,
  enableAnimations: true,
  enableDiagnostics: true,
  enableApiLogging: false,
  enableDebugLogging: false,
  safeRetries: 3,
  benchmarkChartSmoothing: true,
  retryBaseDelayMs: 250,
  retryMaxDelayMs: 4000,
  requestDelayMs: 0,
  connectTimeoutSeconds: 5,
  readTimeoutSeconds: 60,
  maxPoolConnections: 200,
  maxRequestsPerSecond: 0,
  enableCrashRecovery: true,
  defaultPresignMinutes: 60,
  benchmarkDataCacheMb: 0,
  benchmarkDebugMode: false,
  benchmarkLogPath: '/tmp/benchmark.log',
  browserInspectorLayout: BrowserInspectorLayout.bottom,
  browserInspectorSize: 360,
  relistObjectsAfterMutation: true,
  uiScalePercent: 70,
  logTextScalePercent: 80,
);

const _profile = EndpointProfile(
  id: 'test',
  name: 'Test',
  endpointUrl: 'http://localhost:9000',
  region: 'us-east-1',
  accessKey: 'key',
  secretKey: 'secret',
  sessionToken: 'token',
  pathStyle: true,
  verifyTls: false,
);

void main() {
  test(
      'repository refuses to write plaintext secrets when secure storage is unavailable',
      () async {
    final tempDir =
        await Directory.systemTemp.createTemp('app-state-repository-test');
    addTearDown(() => tempDir.delete(recursive: true));

    final repository = LocalAppStateRepository(
      secretStore: ThrowingProfileSecretStore(),
      applicationSupportDirectoryProvider: () async => tempDir,
    );

    expect(
      repository.saveState(
        settings: _settings,
        profiles: const [_profile],
        selectedProfileId: _profile.id,
      ),
      throwsStateError,
    );

    final storedFile = File(
      '${tempDir.path}${Platform.pathSeparator}object-data-browser-state.json',
    );
    expect(await storedFile.exists(), isFalse);
  });

  test('repository reports a credential hydration failure', () async {
    final tempDir =
        await Directory.systemTemp.createTemp('app-state-keychain-error');
    addTearDown(() => tempDir.delete(recursive: true));
    final stateFile = File(
      '${tempDir.path}${Platform.pathSeparator}object-data-browser-state.json',
    );
    final metadata = _profile.toJson()
      ..remove('accessKey')
      ..remove('secretKey')
      ..remove('sessionToken');
    await stateFile.writeAsString(jsonEncode({
      'settings': _settings.toJson(),
      'selectedProfileId': _profile.id,
      'profiles': [metadata],
    }));
    final repository = LocalAppStateRepository(
      secretStore: ThrowingProfileSecretStore(),
      applicationSupportDirectoryProvider: () async => tempDir,
    );

    final state = await repository.loadState();

    expect(state?.credentialStoreError, contains('Keychain access failed'));
    expect(state?.credentialStoreError, contains('FileSystemException'));
    expect(state?.profiles.single.accessKey, isEmpty);
  });

  test('explicit profile save repairs secure storage after a read failure',
      () async {
    final tempDir =
        await Directory.systemTemp.createTemp('app-state-keychain-recovery');
    addTearDown(() => tempDir.delete(recursive: true));
    final stateFile = File(
      '${tempDir.path}${Platform.pathSeparator}object-data-browser-state.json',
    );
    final metadata = _profile.toJson()
      ..remove('accessKey')
      ..remove('secretKey')
      ..remove('sessionToken');
    await stateFile.writeAsString(jsonEncode({
      'settings': _settings.toJson(),
      'selectedProfileId': _profile.id,
      'profiles': [metadata],
    }));
    final store = ReadFailingWritableProfileSecretStore();
    final repository = LocalAppStateRepository(
      secretStore: store,
      applicationSupportDirectoryProvider: () async => tempDir,
    );

    final state = await repository.loadState();
    expect(state?.credentialStoreError, isNotNull);

    expect(
      repository.saveState(
        settings: _settings,
        profiles: const [_profile],
        selectedProfileId: _profile.id,
      ),
      throwsStateError,
    );
    expect(store.writeCalls, isEmpty);

    await repository.saveState(
      settings: _settings,
      profiles: const [_profile],
      selectedProfileId: _profile.id,
      allowCredentialStoreRecovery: true,
    );

    expect(store.writeCalls, ['profiles.credentials.v2']);
    final bundle = jsonDecode(store.values['profiles.credentials.v2']!)
        as Map<String, Object?>;
    expect(
      ((bundle['profiles'] as Map)['test'] as Map)['accessKey'],
      _profile.accessKey,
    );
    expect(await stateFile.exists(), isTrue);
  });

  test('legacy credentials migrate with one bulk read and one bundle write',
      () async {
    final tempDir =
        await Directory.systemTemp.createTemp('app-state-keychain-migration');
    addTearDown(() => tempDir.delete(recursive: true));
    final stateFile = File(
      '${tempDir.path}${Platform.pathSeparator}object-data-browser-state.json',
    );
    final metadata = _profile.toJson()
      ..remove('accessKey')
      ..remove('secretKey')
      ..remove('sessionToken');
    await stateFile.writeAsString(jsonEncode({
      'settings': _settings.toJson(),
      'selectedProfileId': _profile.id,
      'profiles': [metadata],
    }));
    final store = RecordingProfileSecretStore({
      'profile.test.accessKey': 'legacy-key',
      'profile.test.secretKey': 'legacy-secret',
      'profile.test.sessionToken': 'legacy-token',
    });
    final repository = LocalAppStateRepository(
      secretStore: store,
      applicationSupportDirectoryProvider: () async => tempDir,
    );

    final state = await repository.loadState();

    expect(state?.profiles.single.accessKey, 'legacy-key');
    expect(state?.profiles.single.secretKey, 'legacy-secret');
    expect(state?.profiles.single.sessionToken, 'legacy-token');
    expect(store.readCalls, ['profiles.credentials.v2']);
    expect(store.readAllCalls, 1);
    expect(store.writeCalls, ['profiles.credentials.v2']);
  });

  test('legacy macOS bulk migration is skipped and requests one-time recovery',
      () async {
    final tempDir =
        await Directory.systemTemp.createTemp('app-state-legacy-recovery');
    addTearDown(() => tempDir.delete(recursive: true));
    final stateFile = File(
      '${tempDir.path}${Platform.pathSeparator}object-data-browser-state.json',
    );
    final metadata = _profile.toJson()
      ..remove('accessKey')
      ..remove('secretKey')
      ..remove('sessionToken');
    await stateFile.writeAsString(jsonEncode({
      'settings': _settings.toJson(),
      'selectedProfileId': _profile.id,
      'profiles': [metadata],
    }));
    final store = LegacyBulkUnsupportedProfileSecretStore({
      'profile.test.accessKey': 'legacy-key',
      'profile.test.secretKey': 'legacy-secret',
    });
    final repository = LocalAppStateRepository(
      secretStore: store,
      applicationSupportDirectoryProvider: () async => tempDir,
    );

    final state = await repository.loadState();

    expect(store.readAllCalls, 0);
    expect(state?.profiles.single.accessKey, isEmpty);
    expect(
        state?.credentialStoreError, contains('could not be migrated safely'));
    expect(state?.credentialStoreError, isNot(contains('Code: -50')));
  });

  test('Data Protection Keychain entries fall back into the primary bundle',
      () async {
    final tempDir =
        await Directory.systemTemp.createTemp('app-state-keychain-fallback');
    addTearDown(() => tempDir.delete(recursive: true));
    final stateFile = File(
      '${tempDir.path}${Platform.pathSeparator}object-data-browser-state.json',
    );
    final metadata = _profile.toJson()
      ..remove('accessKey')
      ..remove('secretKey')
      ..remove('sessionToken');
    await stateFile.writeAsString(jsonEncode({
      'settings': _settings.toJson(),
      'selectedProfileId': _profile.id,
      'profiles': [metadata],
    }));
    final store = RecordingProfileSecretStore(
      {},
      dataProtectionValues: {
        'profile.test.accessKey': 'protected-key',
        'profile.test.secretKey': 'protected-secret',
      },
    );
    final repository = LocalAppStateRepository(
      secretStore: store,
      applicationSupportDirectoryProvider: () async => tempDir,
    );

    final state = await repository.loadState();

    expect(state?.profiles.single.accessKey, 'protected-key');
    expect(state?.profiles.single.secretKey, 'protected-secret');
    expect(state?.credentialStoreError, isNull);
    expect(store.readAllCalls, 1);
    expect(store.dataProtectionReadAllCalls, 1);
    expect(store.writeCalls, ['profiles.credentials.v2']);
  });

  test('macOS loads the newest state across sandbox transitions', () async {
    final root =
        await Directory.systemTemp.createTemp('app-state-sandbox-transition');
    addTearDown(() => root.delete(recursive: true));
    final primaryDirectory = Directory(
      '${root.path}/Library/Application Support/com.example.s3BrowserCrossplat',
    );
    final sandboxDirectory = Directory(
      '${root.path}/Library/Containers/com.example.s3BrowserCrossplat/Data/Library/Application Support/com.example.s3BrowserCrossplat',
    );
    await primaryDirectory.create(recursive: true);
    await sandboxDirectory.create(recursive: true);
    final primaryFile = File(
      '${primaryDirectory.path}/object-data-browser-state.json',
    );
    final sandboxFile = File(
      '${sandboxDirectory.path}/object-data-browser-state.json',
    );
    await primaryFile.writeAsString(jsonEncode({
      'settings': _settings.toJson(),
      'selectedProfileId': null,
      'profiles': const [],
    }));
    final metadata = _profile.toJson()
      ..remove('accessKey')
      ..remove('secretKey')
      ..remove('sessionToken');
    await sandboxFile.writeAsString(jsonEncode({
      'settings': _settings.toJson(),
      'selectedProfileId': _profile.id,
      'profiles': [metadata],
    }));
    final now = DateTime.now();
    await primaryFile.setLastModified(now.subtract(const Duration(hours: 1)));
    await sandboxFile.setLastModified(now);
    final store = RecordingProfileSecretStore({
      'profile.test.accessKey': 'restored-key',
      'profile.test.secretKey': 'restored-secret',
    });
    final repository = LocalAppStateRepository(
      secretStore: store,
      applicationSupportDirectoryProvider: () async => primaryDirectory,
    );

    final state = await repository.loadState();

    expect(state?.selectedProfileId, _profile.id);
    expect(state?.profiles.single.accessKey, 'restored-key');
    expect(state?.profiles.single.secretKey, 'restored-secret');
  }, skip: !Platform.isMacOS);

  test('bundled credentials need one startup read and skip unchanged writes',
      () async {
    final tempDir =
        await Directory.systemTemp.createTemp('app-state-keychain-bundle');
    addTearDown(() => tempDir.delete(recursive: true));
    final stateFile = File(
      '${tempDir.path}${Platform.pathSeparator}object-data-browser-state.json',
    );
    final metadata = _profile.toJson()
      ..remove('accessKey')
      ..remove('secretKey')
      ..remove('sessionToken');
    await stateFile.writeAsString(jsonEncode({
      'settings': _settings.toJson(),
      'selectedProfileId': _profile.id,
      'profiles': [metadata],
    }));
    final store = RecordingProfileSecretStore({
      'profiles.credentials.v2': jsonEncode({
        'version': 2,
        'profiles': {
          'test': {
            'accessKey': 'bundled-key',
            'secretKey': 'bundled-secret',
            'sessionToken': null,
          },
        },
      }),
    });
    final repository = LocalAppStateRepository(
      secretStore: store,
      applicationSupportDirectoryProvider: () async => tempDir,
    );

    final state = await repository.loadState();
    expect(state?.profiles.single.accessKey, 'bundled-key');
    expect(store.readCalls, ['profiles.credentials.v2']);
    expect(store.readAllCalls, 0);

    store.resetCalls();
    await repository.saveState(
      settings: state!.settings,
      profiles: state.profiles,
      selectedProfileId: state.selectedProfileId,
    );
    expect(store.writeCalls, isEmpty);

    await repository.saveState(
      settings: state.settings,
      profiles: [state.profiles.single.copyWith(accessKey: 'updated-key')],
      selectedProfileId: state.selectedProfileId,
    );
    expect(store.writeCalls, ['profiles.credentials.v2']);
  });
}
