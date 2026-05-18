import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:s3_browser_crossplat/controllers/app_controller.dart';
import 'package:s3_browser_crossplat/models/domain_models.dart';
import 'package:s3_browser_crossplat/services/app_state_repository.dart';
import 'package:s3_browser_crossplat/services/engine_service.dart';
import 'package:s3_browser_crossplat/services/mock_engine_service.dart';

class MemoryAppStateRepository implements AppStateRepository {
  StoredAppState? storedState;

  @override
  Future<StoredAppState?> loadState() async => storedState;

  @override
  Future<void> saveState({
    required AppSettings settings,
    required List<EndpointProfile> profiles,
    required String? selectedProfileId,
  }) async {
    storedState = StoredAppState(
      settings: settings,
      profiles: profiles,
      selectedProfileId: selectedProfileId,
    );
  }

  @override
  Future<File> exportProfiles({
    required List<EndpointProfile> profiles,
    required String path,
  }) async {
    final file = File(path);
    await file.parent.create(recursive: true);
    await file.writeAsString('[]');
    return file;
  }

  @override
  Future<List<EndpointProfile>> importProfiles(String path) async {
    return const [
      EndpointProfile(
        id: 'imported',
        name: 'Imported',
        endpointUrl: 'http://localhost:9001',
        region: 'eu-west-1',
        accessKey: 'import-key',
        secretKey: 'import-secret',
        pathStyle: true,
        verifyTls: false,
      ),
    ];
  }
}

class RecordingMockEngineService extends MockEngineService {
  DiagnosticsOptions? lastDiagnostics;

  @override
  void configureDiagnostics(DiagnosticsOptions options) {
    lastDiagnostics = options;
    super.configureDiagnostics(options);
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
  pathStyle: true,
  verifyTls: false,
);

void main() {
  test(
      'controller initializes with parity-shaped mock data and exports benchmark results',
      () async {
    final controller = AppController(
      engineService: MockEngineService(),
      initialSettings: _settings,
      initialProfiles: const [_profile],
    );

    await controller.initialize();

    expect(controller.engines, isNotEmpty);
    expect(controller.buckets, isNotEmpty);
    expect(controller.objects.length, 1000);
    expect(controller.objectCursor.hasMore, isTrue);
    expect(controller.adminState, isNotNull);
    expect(controller.eventLog, isNotEmpty);

    await controller.startBenchmark();
    expect(controller.benchmarkRun, isNotNull);

    await controller.exportBenchmarkResults('json');
    expect(controller.bannerMessage, contains('benchmark-results.json'));
  });

  test('controller lists all object pages only when requested', () async {
    final controller = AppController(
      engineService: MockEngineService(),
      initialSettings: _settings,
      initialProfiles: const [_profile],
    );

    await controller.initialize();

    expect(controller.objects.length, 1000);
    expect(controller.objectCursor.hasMore, isTrue);
    expect(controller.listAllKeys, isFalse);

    await controller.listAllObjectsForCurrentBucket();

    expect(controller.objects.length, 2354);
    expect(controller.objectCursor.hasMore, isFalse);
    expect(controller.listAllKeys, isTrue);

    await controller.setSelectedBucket(controller.buckets.last);

    expect(controller.objects.length, 1000);
    expect(controller.objectCursor.hasMore, isTrue);
    expect(controller.listAllKeys, isFalse);
  });

  test(
      'controller persists settings and profiles and restores bucket-wide versions without selected object',
      () async {
    final repository = MemoryAppStateRepository();
    final controller = AppController(
      engineService: MockEngineService(),
      initialSettings: _settings,
      initialProfiles: const [_profile],
      appStateRepository: repository,
    );

    await controller.initialize();
    await controller.updateSettings(
      controller.settings.copyWith(defaultPresignMinutes: 15),
    );
    await controller.saveProfile(_profile.copyWith(name: 'Updated profile'));

    expect(repository.storedState, isNotNull);
    expect(repository.storedState!.settings.defaultPresignMinutes, 15);
    expect(repository.storedState!.profiles.first.name, 'Updated profile');
    expect(controller.selectedObject, isNull);
    expect(controller.visibleVersions, isNotEmpty);

    final restored = AppController(
      engineService: MockEngineService(),
      initialSettings: repository.storedState!.settings,
      initialProfiles: repository.storedState!.profiles,
      initialSelectedProfileId: repository.storedState!.selectedProfileId,
      appStateRepository: repository,
    );
    await restored.initialize();

    expect(restored.settings.defaultPresignMinutes, 15);
    expect(restored.profiles.first.name, 'Updated profile');
    expect(restored.visibleVersions, isNotEmpty);
  });

  test(
      'controller applies object and version filter modes and scopes bucket events',
      () async {
    final controller = AppController(
      engineService: MockEngineService(),
      initialSettings: _settings,
      initialProfiles: const [_profile],
    );
    await controller.initialize();

    controller.setObjectFilterMode(BrowserFilterMode.text);
    await controller.applyObjectFilter('report');
    expect(controller.visibleObjects.length, 1);
    expect(controller.visibleObjects.first.key, contains('report'));

    controller.updateVersionBrowserOptions(
      controller.versionBrowserOptions.copyWith(
        filterMode: BrowserFilterMode.text,
        filterValue: 'docs/',
      ),
    );
    expect(
      controller.visibleVersions.every((item) => item.key.contains('docs/')),
      isTrue,
    );

    final firstBucket = controller.selectedBucket!;
    await controller.setSelectedBucket(controller.buckets.last);
    expect(
      controller.bucketScopedEvents.every(
        (entry) => entry.bucketName == controller.selectedBucket!.name,
      ),
      isTrue,
    );
    expect(
      controller.bucketScopedEvents.any(
        (entry) => entry.bucketName == firstBucket.name,
      ),
      isFalse,
    );
  });

  test(
      'controller normalizes endpoint profiles for scheme, TLS, port, and AWS endpoints',
      () async {
    final controller = AppController(
      engineService: MockEngineService(),
      initialSettings: _settings,
      initialProfiles: const [_profile],
    );

    await controller.saveProfile(
      const EndpointProfile(
        id: 'minio',
        name: 'MinIO',
        endpointUrl: '192.168.9.240:10444',
        region: 'us-east-1',
        accessKey: 'key',
        secretKey: 'secret',
        pathStyle: true,
        verifyTls: false,
      ),
    );
    await controller.saveProfile(
      const EndpointProfile(
        id: 'aws',
        name: 'AWS',
        endpointUrl: '',
        region: 'eu-west-1',
        accessKey: 'aws-key',
        secretKey: 'aws-secret',
        pathStyle: true,
        verifyTls: false,
        endpointType: EndpointProfileType.awsS3,
      ),
    );

    final minio =
        controller.profiles.firstWhere((profile) => profile.id == 'minio');
    final aws =
        controller.profiles.firstWhere((profile) => profile.id == 'aws');

    expect(minio.endpointUrl, 'http://192.168.9.240:10444');
    expect(minio.verifyTls, isFalse);
    expect(aws.endpointUrl, 'https://s3.eu-west-1.amazonaws.com');
    expect(aws.verifyTls, isTrue);
    expect(aws.pathStyle, isFalse);
  });

  test('controller syncs settings-driven diagnostics and benchmark debug mode',
      () async {
    final engineService = RecordingMockEngineService();
    final controller = AppController(
      engineService: engineService,
      initialSettings: _settings,
      initialProfiles: const [_profile],
    );

    expect(engineService.lastDiagnostics, isNotNull);
    expect(engineService.lastDiagnostics!.enableApiLogging, isFalse);
    expect(engineService.lastDiagnostics!.enableDebugLogging, isFalse);

    await controller.initialize();
    await controller.updateSettings(
      controller.settings.copyWith(
        enableApiLogging: true,
        enableDebugLogging: true,
        benchmarkDebugMode: true,
      ),
    );

    expect(engineService.lastDiagnostics!.enableApiLogging, isTrue);
    expect(engineService.lastDiagnostics!.enableDebugLogging, isTrue);
    expect(controller.benchmarkDraft.debugMode, isTrue);

    await controller.startBenchmark();

    expect(controller.benchmarkRun, isNotNull);
    expect(controller.benchmarkRun!.config.debugMode, isTrue);
  });

  test('controller receives streamed transfer updates before upload completion',
      () async {
    final controller = AppController(
      engineService: MockEngineService(),
      initialSettings: _settings,
      initialProfiles: const [_profile],
    );
    await controller.initialize();

    final uploadFuture =
        controller.startSampleUpload(const ['missing-large-file.bin']);
    await Future<void>.delayed(const Duration(milliseconds: 25));

    final runningTransfer = controller.browserTasks.firstWhere(
      (task) => task.kind == BrowserTaskKind.transfer,
    );
    expect(runningTransfer.status, anyOf('queued', 'running'));
    expect(runningTransfer.strategyLabel, isNotNull);
    expect(runningTransfer.outputLines, isNotEmpty);
    expect(controller.bannerTaskId, runningTransfer.id);
    expect(controller.bannerMessage, contains('%'));

    await uploadFuture;

    final completedTransfer = controller.browserTasks.firstWhere(
      (task) => task.kind == BrowserTaskKind.transfer,
    );
    expect(completedTransfer.status, 'completed');
    expect(completedTransfer.progress, 1);
    expect(controller.bannerTaskId, completedTransfer.id);
    expect(controller.bannerMessage, 'Upload complete - 100%');
  });

  test('controller cancels running listing action tasks', () async {
    final controller = AppController(
      engineService: MockEngineService(),
      initialSettings: _settings,
      initialProfiles: const [_profile],
    );
    controller.browserTasks = [
      BrowserTaskRecord(
        id: 'refresh-buckets-1',
        kind: BrowserTaskKind.action,
        label: 'Listing buckets for Test...',
        status: 'running',
        startedAt: DateTime(2026, 4, 27, 10),
        progress: 0,
        actionKey: 'refresh-buckets',
        canCancel: true,
      ),
    ];

    await controller.cancelTask(controller.browserTasks.single);

    expect(controller.browserTasks.single.status, 'cancelling');
    expect(controller.browserTasks.single.canCancel, isFalse);
    expect(
      controller.browserTasks.single.outputLines.last,
      contains('Cancellation requested'),
    );
  });
}
