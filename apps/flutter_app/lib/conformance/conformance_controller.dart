import 'package:flutter/foundation.dart';

import '../models/domain_models.dart';
import 'conformance_models.dart';
import 'conformance_suite.dart';
import 'sidecar_s3_op_executor.dart';

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

  bool get available => isDesktop && transport != null;
  bool get running => _cancellation != null;
  bool get stopping => _cancellation?.isCancelled ?? false;

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
    final selected = config.engineIds.where((id) => engines.any((e) => e.id == id && e.available));
    if (selected.isEmpty) return 'Select at least one installed desktop engine.';
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
        if (engines.any((e) => e.id == id && e.available)) id
    ];
    final report = ConformanceReport(
      id: DateTime.now().toUtc().millisecondsSinceEpoch.toRadixString(36),
      config: config.copyWith(engineIds: engineIds),
      profileName: profile.name,
      startedAt: DateTime.now(),
    );
    current = report;
    _notify();
    final endpoint = ConformanceEndpoint(
      endpointUrl: profile.endpointUrl,
      region: profile.region,
      pathStyle: profile.pathStyle,
      endpointType: profile.endpointType == EndpointProfileType.awsS3 ? 'awsS3' : 's3Compatible',
    );
    try {
      for (final engineId in engineIds) {
        if (cancellation.isCancelled) break;
        liveEngine = engineId;
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
