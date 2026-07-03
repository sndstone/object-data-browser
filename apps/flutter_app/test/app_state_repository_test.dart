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
  Future<void> deleteSecret(String key) async {
    throw const FileSystemException('secure storage unavailable');
  }
}

const _settings = AppSettings(
  darkMode: false,
  defaultEngineId: 'rust',
  downloadPath: '/tmp/downloads',
  tempPath: '/tmp',
  transferConcurrency: 8,
  multipartThresholdMiB: 32,
  multipartChunkMiB: 8,
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
}
