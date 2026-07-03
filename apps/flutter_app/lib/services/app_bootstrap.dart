import 'dart:io';

import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

import '../controllers/app_controller.dart';
import '../models/domain_models.dart';
import 'android_engine_service.dart';
import 'app_state_repository.dart';
import 'desktop_sidecar_engine_service.dart';
import 'engine_service.dart';
import 'mock_engine_service.dart';

class AppBootstrap {
  static const MethodChannel _androidChannel =
      MethodChannel('s3_browser_crossplat/android_engine');

  static Future<AppController> initialize({
    AppStateRepository? appStateRepository,
    EngineService? engineService,
  }) async {
    final downloadPath = await _resolveDownloadPath();
    final tempDir = await getTemporaryDirectory();
    final repository = appStateRepository ?? LocalAppStateRepository();

    final defaultSettings = AppSettings(
      darkMode: false,
      defaultEngineId: 'python',
      downloadPath: downloadPath,
      tempPath: tempDir.path,
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
      benchmarkLogPath: '${tempDir.path}${Platform.pathSeparator}benchmark.log',
      browserInspectorLayout: BrowserInspectorLayout.bottom,
      browserInspectorSize: 360,
      relistObjectsAfterMutation: true,
      uiScalePercent: 70,
      logTextScalePercent: 80,
    );
    final storedState = await repository.loadState();
    final settings = storedState?.settings.copyWith(
          downloadPath: storedState.settings.downloadPath.isEmpty
              ? downloadPath
              : storedState.settings.downloadPath,
          tempPath: storedState.settings.tempPath.isEmpty
              ? tempDir.path
              : storedState.settings.tempPath,
          benchmarkLogPath: storedState.settings.benchmarkLogPath.isEmpty
              ? '${tempDir.path}${Platform.pathSeparator}benchmark.log'
              : storedState.settings.benchmarkLogPath,
        ) ??
        defaultSettings;

    final EngineService resolvedEngineService;
    if (engineService != null) {
      resolvedEngineService = engineService;
    } else if (Platform.isWindows || Platform.isLinux || Platform.isMacOS) {
      resolvedEngineService = DesktopSidecarEngineService();
    } else if (Platform.isAndroid) {
      resolvedEngineService = AndroidEngineService();
    } else {
      resolvedEngineService = MockEngineService();
    }

    final controller = AppController(
      engineService: resolvedEngineService,
      initialSettings: settings,
      initialProfiles: storedState?.profiles ?? const [],
      initialSelectedProfileId: storedState?.selectedProfileId,
      appStateRepository: repository,
    );
    return controller;
  }

  static Future<String> _resolveDownloadPath() async {
    if (Platform.isAndroid) {
      try {
        final nativePath =
            await _androidChannel.invokeMethod<String>('getUserDownloadsPath');
        if (nativePath != null && nativePath.trim().isNotEmpty) {
          return nativePath;
        }
      } on PlatformException {
        // Fall back to path_provider when the native channel is unavailable.
      } on MissingPluginException {
        // Fall back to path_provider during tests and unsupported platforms.
      }
    }

    final downloadDir = await getDownloadsDirectory();
    if (downloadDir != null) {
      return downloadDir.path;
    }

    if (Platform.isAndroid) {
      final temp = await getTemporaryDirectory();
      return temp.path;
    }

    return Directory.current.path;
  }
}
