import 'package:flutter/foundation.dart';

import '../models/domain_models.dart';
import 'conformance_models.dart';
import 'conformance_suite.dart';
import 'sidecar_s3_op_executor.dart';

enum ConformanceEngineQueueState {
  queued,
  running,
  completed,
  cancelled,
  failed,
}

/// Desktop-only state for the Benchmark workspace's S3 API conformance view.
///
/// Runs the selected engines one after another against the active profile.
/// Results hold bounded records only; reports never contain credentials,
/// customer keys, bodies or presigned URLs.
class ConformanceController extends ChangeNotifier {
  ConformanceController({
    required this.transport,
    required this.isDesktop,
    S3ConformanceSuite Function({
      required SidecarS3OpExecutor executor,
      required ConformanceConfig config,
      required ConformanceEndpoint endpoint,
      required ConformanceCancellation cancellation,
      required void Function(ConformanceProgress) onProgress,
    })? suiteFactory,
  }) : _suiteFactory = suiteFactory ?? _defaultSuite;

  /// Null when the engine service cannot run conformance (mobile, mock).
  final S3ConformanceTransport? transport;
  final bool isDesktop;
  final S3ConformanceSuite Function({
    required SidecarS3OpExecutor executor,
    required ConformanceConfig config,
    required ConformanceEndpoint endpoint,
    required ConformanceCancellation cancellation,
    required void Function(ConformanceProgress) onProgress,
  }) _suiteFactory;

  static const int maxHistory = 5;

  /// Desktop engines that do not implement the `s3ConformanceOp` SDK harness.
  static const Set<String> unsupportedEngineIds = {'rust-raw'};

  static bool supportsEngine(EngineDescriptor engine) =>
      engine.desktopSupported && !unsupportedEngineIds.contains(engine.id);

  ConformanceConfig config = const ConformanceConfig(baseBucketName: 'odb-conformance');
  ConformanceReport? current;
  final List<ConformanceReport> history = <ConformanceReport>[];
  ConformanceProgress? progress;
  ConformanceCancellation? _cancellation;
  String? lastError;
  bool _disposed = false;

  /// Live results of the engine being run.
  final List<ConformanceCheckResult> liveChecks = <ConformanceCheckResult>[];
  String? liveEngine;
  DateTime? liveEngineStartedAt;
  ConformanceEndpoint? _liveEndpoint;
  String? _liveEngineLabel;

  bool get available => isDesktop && transport != null;
  bool get running => _cancellation != null;
  bool get stopping => _cancellation?.isCancelled ?? false;

  /// In-progress snapshot for the currently running engine, or null when idle.
  ConformanceEngineRun? get liveEngineRun {
    final engineId = liveEngine;
    if (!running || engineId == null) return null;
    if (current?.engines.any((e) => e.engineId == engineId) ?? false) {
      return null;
    }
    return ConformanceEngineRun(
      engineId: engineId,
      runId: current?.id ?? 'live',
      startedAt: liveEngineStartedAt ?? current?.startedAt ?? DateTime.now(),
      sdk: _liveEngineLabel ?? 'running…',
      endpoint: _liveEndpoint?.displayHost ?? '',
      region: _liveEndpoint?.region ?? '',
      pathStyle: _liveEndpoint?.pathStyle ?? false,
      checks: List<ConformanceCheckResult>.unmodifiable(liveChecks),
      status: ConformanceRunStatus.running,
    );
  }

  /// Completed engine runs plus the active live engine run (when running).
  List<ConformanceEngineRun> get displayEngines {
    final report = current;
    if (report == null) return const [];
    final live = liveEngineRun;
    return [
      ...report.engines,
      if (live != null) live,
    ];
  }

  /// Report view that includes live streaming checks during an active run.
  ConformanceReport? get displayReport {
    final report = current;
    if (report == null) return null;
    final live = liveEngineRun;
    if (live == null) return report;
    return ConformanceReport(
      id: report.id,
      config: report.config,
      profileName: report.profileName,
      startedAt: report.startedAt,
      finishedAt: report.finishedAt,
      engines: [...report.engines, live],
    );
  }

  /// Aggregate progress across all queued engines (0.0..1.0), or null if idle.
  double? get overallProgress {
    if (!running) return null;
    final totalEngines = current?.config.engineIds.length ?? 0;
    if (totalEngines <= 0) return null;
    final completedEngines = current?.engines.length ?? 0;
    final currentFraction = progress == null
        ? 0.0
        : (progress!.completed / conformanceEstimatedChecks).clamp(0.0, 0.99);
    return ((completedEngines + currentFraction) / totalEngines).clamp(0.0, 1.0);
  }

  ConformanceEngineQueueState engineQueueState(String engineId) {
    final finished =
        current?.engines.where((e) => e.engineId == engineId).firstOrNull;
    if (finished != null) {
      return switch (finished.status) {
        ConformanceRunStatus.completed => ConformanceEngineQueueState.completed,
        ConformanceRunStatus.cancelled => ConformanceEngineQueueState.cancelled,
        ConformanceRunStatus.failed => ConformanceEngineQueueState.failed,
        ConformanceRunStatus.running => ConformanceEngineQueueState.running,
      };
    }
    if (running && liveEngine == engineId) {
      return ConformanceEngineQueueState.running;
    }
    if (!running && current != null) {
      return ConformanceEngineQueueState.cancelled;
    }
    return ConformanceEngineQueueState.queued;
  }

  void updateConfig(ConformanceConfig value) {
    config = value;
    _notify();
  }

  /// Why [profile] cannot be tested, or null.
  String? blockedReason(EndpointProfile? profile, List<EngineDescriptor> engines) {
    if (!available) return 'S3 API conformance runs only in the desktop app.';
    if (profile == null) return 'Select an endpoint profile first.';
    if (profile.endpointType != EndpointProfileType.s3Compatible &&
        profile.endpointType != EndpointProfileType.awsS3) {
      return 'S3 API conformance needs an S3 or S3-compatible profile.';
    }
    final invalid = ConformanceConfig.validateBaseName(config.baseBucketName);
    if (invalid != null) return invalid;
    final prefix = '${config.baseBucketName}-';
    final vault = profile.clientEncryptionRules
        .where((rule) => rule.bucket.startsWith(prefix))
        .firstOrNull;
    if (vault != null) {
      return 'A client-encryption rule covers bucket "${vault.bucket}"; choose another base bucket name.';
    }
    final selected = config.engineIds.where(
      (id) => engines.any((e) => e.id == id && e.available && supportsEngine(e)),
    );
    if (selected.isEmpty) {
      return 'Select at least one installed SDK engine (Python, Go, Rust or Java).';
    }
    return null;
  }

  Future<ConformanceReport?> start({
    required EndpointProfile profile,
    required List<EngineDescriptor> engines,
  }) async {
    final reason = blockedReason(profile, engines);
    if (reason != null) {
      lastError = reason;
      _notify();
      return null;
    }
    if (running) return null;
    final cancellation = ConformanceCancellation();
    _cancellation = cancellation;
    lastError = null;
    final engineIds = [
      for (final id in config.engineIds)
        if (engines.any((e) => e.id == id && e.available && supportsEngine(e))) id
    ];
    final report = ConformanceReport(
      id: DateTime.now().toUtc().millisecondsSinceEpoch.toRadixString(36),
      config: config.copyWith(engineIds: engineIds),
      profileName: profile.name,
      startedAt: DateTime.now(),
    );
    current = report;
    final endpoint = ConformanceEndpoint(
      endpointUrl: profile.endpointUrl,
      region: profile.region,
      pathStyle: profile.pathStyle,
      endpointType: profile.endpointType == EndpointProfileType.awsS3 ? 'awsS3' : 's3Compatible',
    );
    _liveEndpoint = endpoint;
    _notify();
    try {
      for (final engineId in engineIds) {
        if (cancellation.isCancelled) break;
        final descriptor = engines.where((e) => e.id == engineId).firstOrNull;
        liveEngine = engineId;
        liveEngineStartedAt = DateTime.now();
        _liveEngineLabel = descriptor == null
            ? 'running…'
            : '${descriptor.label} (running…)';
        liveChecks.clear();
        progress = null;
        _notify();
        final suite = _suiteFactory(
          executor: SidecarS3OpExecutor(engineId: engineId, transport: transport!, profile: profile),
          config: report.config,
          endpoint: endpoint,
          cancellation: cancellation,
          onProgress: (value) {
            progress = value;
            final result = value.lastResult;
            if (result != null) liveChecks.add(result);
            _notify();
          },
        );
        final run = await suite.run();
        report.engines.add(run);
        _notify();
      }
    } catch (error) {
      lastError = 'Conformance run stopped: $error';
    } finally {
      report.finishedAt = DateTime.now();
      history.insert(0, report);
      while (history.length > maxHistory) {
        history.removeLast();
      }
      _cancellation = null;
      liveEngine = null;
      liveEngineStartedAt = null;
      _liveEndpoint = null;
      _liveEngineLabel = null;
      liveChecks.clear();
      progress = null;
      _notify();
    }
    return report;
  }

  /// Stops after the in-flight call; teardown still runs.
  void stop() {
    _cancellation?.cancel();
    _notify();
  }

  /// Stops without teardown; created buckets are reported as retained.
  void forceStop() {
    _cancellation?.cancel(skipTeardown: true);
    _notify();
  }

  void select(ConformanceReport report) {
    if (running) return; // the live report stays current until the run ends
    current = report;
    _notify();
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _cancellation?.cancel();
    super.dispose();
  }

  static S3ConformanceSuite _defaultSuite({
    required SidecarS3OpExecutor executor,
    required ConformanceConfig config,
    required ConformanceEndpoint endpoint,
    required ConformanceCancellation cancellation,
    required void Function(ConformanceProgress) onProgress,
  }) =>
      S3ConformanceSuite(
        executor: executor,
        config: config,
        endpoint: endpoint,
        cancellation: cancellation,
        onProgress: onProgress,
      );
}
