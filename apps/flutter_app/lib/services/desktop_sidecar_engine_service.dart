import 'dart:convert';
import 'dart:io';

import '../models/domain_models.dart';
import 'desktop_engine_host.dart';
import 'engine_service.dart';
import 'mock_engine_service.dart';

class DesktopSidecarEngineService
    implements
        EngineService,
        EngineLogSinkRegistrant,
        TransferJobSinkRegistrant {
  DesktopSidecarEngineService({
    DesktopEngineHost host = const DesktopEngineHost(),
    EngineService? fallback,
  })  : _host = host,
        _fallback = fallback ?? MockEngineService();

  final DesktopEngineHost _host;
  final EngineService _fallback;
  EngineLogCallback? _logSink;
  TransferJobCallback? _transferSink;
  DiagnosticsOptions _diagnosticsOptions = const DiagnosticsOptions(
    enableApiLogging: false,
    enableDebugLogging: false,
  );

  Map<String, _EngineManifestEntry>? _cachedManifest;
  String? _cachedEngineRoot;
  final Map<String, String> _benchmarkEngines = <String, String>{};

  @override
  void setLogSink(EngineLogCallback? sink) {
    _logSink = sink;
  }

  @override
  void setTransferSink(TransferJobCallback? sink) {
    _transferSink = sink;
    if (_fallback is TransferJobSinkRegistrant) {
      (_fallback as TransferJobSinkRegistrant).setTransferSink(sink);
    }
  }

  @override
  void configureDiagnostics(DiagnosticsOptions options) {
    _diagnosticsOptions = options;
    _fallback.configureDiagnostics(options);
  }

  @override
  Future<List<EngineDescriptor>> listEngines() async {
    final fallbackEngines = await _fallback.listEngines();
    final manifest = await _loadManifest();
    return fallbackEngines.map((engine) {
      final entry = manifest[engine.id];
      return EngineDescriptor(
        id: engine.id,
        label: engine.label,
        language: engine.language,
        version: entry?.version ?? engine.version,
        available: entry != null || engine.available,
        desktopSupported: engine.desktopSupported,
        androidSupported: engine.androidSupported,
      );
    }).toList(growable: false);
  }

  @override
  Future<List<CapabilityDescriptor>> getCapabilities({
    required String engineId,
    required EndpointProfile profile,
  }) async {
    final entry = await _tryGetEngine(engineId);
    if (entry == null) {
      return _fallback.getCapabilities(engineId: engineId, profile: profile);
    }

    try {
      final result = await _sendSidecarRequest(
        entry,
        method: 'getCapabilities',
        params: {'profile': _profileToJson(profile)},
      );
      final items = (result['items'] as List<Object?>? ?? const []);
      return items
          .map((item) =>
              _capabilityFromJson(Map<String, Object?>.from(item as Map)))
          .toList();
    } on EngineException catch (error) {
      if (error.code != ErrorCode.unsupportedFeature) {
        rethrow;
      }
      return _fallback.getCapabilities(engineId: engineId, profile: profile);
    }
  }

  @override
  Future<void> testProfile({
    required String engineId,
    required EndpointProfile profile,
  }) async {
    await _sendWithFallback<void>(
      engineId: engineId,
      method: 'testProfile',
      params: {'profile': _profileToJson(profile)},
      onSuccess: (_) {},
      onFallback: () =>
          _fallback.testProfile(engineId: engineId, profile: profile),
    );
  }

  @override
  Future<List<BucketSummary>> listBuckets({
    required String engineId,
    required EndpointProfile profile,
  }) async {
    return _sendWithFallback(
      engineId: engineId,
      method: 'listBuckets',
      params: {'profile': _profileToJson(profile)},
      onSuccess: (result) {
        final items = (result['items'] as List<Object?>? ?? const []);
        return items
            .map((item) =>
                _bucketFromJson(Map<String, Object?>.from(item as Map)))
            .toList();
      },
      onFallback: () =>
          _fallback.listBuckets(engineId: engineId, profile: profile),
    );
  }

  @override
  Future<BucketSummary> createBucket({
    required String engineId,
    required EndpointProfile profile,
    required String bucketName,
    required bool enableVersioning,
    required bool enableObjectLock,
  }) async {
    return _sendWithFallback(
      engineId: engineId,
      method: 'createBucket',
      params: {
        'profile': _profileToJson(profile),
        'bucketName': bucketName,
        'enableVersioning': enableVersioning,
        'enableObjectLock': enableObjectLock,
      },
      onSuccess: _bucketFromJson,
      onFallback: () => _fallback.createBucket(
        engineId: engineId,
        profile: profile,
        bucketName: bucketName,
        enableVersioning: enableVersioning,
        enableObjectLock: enableObjectLock,
      ),
    );
  }

  @override
  Future<void> deleteBucket({
    required String engineId,
    required EndpointProfile profile,
    required String bucketName,
  }) async {
    await _sendWithFallback<void>(
      engineId: engineId,
      method: 'deleteBucket',
      params: {
        'profile': _profileToJson(profile),
        'bucketName': bucketName,
      },
      onSuccess: (_) {},
      onFallback: () => _fallback.deleteBucket(
        engineId: engineId,
        profile: profile,
        bucketName: bucketName,
      ),
    );
  }

  @override
  Future<BucketAdminState> getBucketAdminState({
    required String engineId,
    required EndpointProfile profile,
    required String bucketName,
  }) {
    return _sendWithFallback(
      engineId: engineId,
      method: 'getBucketAdminState',
      params: {
        'profile': _profileToJson(profile),
        'bucketName': bucketName,
      },
      onSuccess: _bucketAdminStateFromJson,
      onFallback: () => _fallback.getBucketAdminState(
        engineId: engineId,
        profile: profile,
        bucketName: bucketName,
      ),
    );
  }

  @override
  Future<BucketAdminState> setBucketVersioning({
    required String engineId,
    required EndpointProfile profile,
    required String bucketName,
    required bool enabled,
  }) {
    return _sendWithFallback(
      engineId: engineId,
      method: 'setBucketVersioning',
      params: {
        'profile': _profileToJson(profile),
        'bucketName': bucketName,
        'enabled': enabled,
      },
      onSuccess: _bucketAdminStateFromJson,
      onFallback: () => _fallback.setBucketVersioning(
        engineId: engineId,
        profile: profile,
        bucketName: bucketName,
        enabled: enabled,
      ),
    );
  }

  @override
  Future<BucketAdminState> putBucketLifecycle({
    required String engineId,
    required EndpointProfile profile,
    required String bucketName,
    required String lifecycleJson,
  }) {
    return _bucketAdminWrite(
      engineId: engineId,
      method: 'putBucketLifecycle',
      profile: profile,
      bucketName: bucketName,
      payloadKey: 'lifecycleJson',
      payloadValue: lifecycleJson,
      onFallback: () => _fallback.putBucketLifecycle(
        engineId: engineId,
        profile: profile,
        bucketName: bucketName,
        lifecycleJson: lifecycleJson,
      ),
    );
  }

  @override
  Future<BucketAdminState> deleteBucketLifecycle({
    required String engineId,
    required EndpointProfile profile,
    required String bucketName,
  }) {
    return _bucketAdminWrite(
      engineId: engineId,
      method: 'deleteBucketLifecycle',
      profile: profile,
      bucketName: bucketName,
      onFallback: () => _fallback.deleteBucketLifecycle(
        engineId: engineId,
        profile: profile,
        bucketName: bucketName,
      ),
    );
  }

  @override
  Future<BucketAdminState> putBucketPolicy({
    required String engineId,
    required EndpointProfile profile,
    required String bucketName,
    required String policyJson,
  }) {
    return _bucketAdminWrite(
      engineId: engineId,
      method: 'putBucketPolicy',
      profile: profile,
      bucketName: bucketName,
      payloadKey: 'policyJson',
      payloadValue: policyJson,
      onFallback: () => _fallback.putBucketPolicy(
        engineId: engineId,
        profile: profile,
        bucketName: bucketName,
        policyJson: policyJson,
      ),
    );
  }

  @override
  Future<BucketAdminState> deleteBucketPolicy({
    required String engineId,
    required EndpointProfile profile,
    required String bucketName,
  }) {
    return _bucketAdminWrite(
      engineId: engineId,
      method: 'deleteBucketPolicy',
      profile: profile,
      bucketName: bucketName,
      onFallback: () => _fallback.deleteBucketPolicy(
        engineId: engineId,
        profile: profile,
        bucketName: bucketName,
      ),
    );
  }

  @override
  Future<BucketAdminState> putBucketCors({
    required String engineId,
    required EndpointProfile profile,
    required String bucketName,
    required String corsJson,
  }) {
    return _bucketAdminWrite(
      engineId: engineId,
      method: 'putBucketCors',
      profile: profile,
      bucketName: bucketName,
      payloadKey: 'corsJson',
      payloadValue: corsJson,
      onFallback: () => _fallback.putBucketCors(
        engineId: engineId,
        profile: profile,
        bucketName: bucketName,
        corsJson: corsJson,
      ),
    );
  }

  @override
  Future<BucketAdminState> deleteBucketCors({
    required String engineId,
    required EndpointProfile profile,
    required String bucketName,
  }) {
    return _bucketAdminWrite(
      engineId: engineId,
      method: 'deleteBucketCors',
      profile: profile,
      bucketName: bucketName,
      onFallback: () => _fallback.deleteBucketCors(
        engineId: engineId,
        profile: profile,
        bucketName: bucketName,
      ),
    );
  }

  @override
  Future<BucketAdminState> putBucketEncryption({
    required String engineId,
    required EndpointProfile profile,
    required String bucketName,
    required String encryptionJson,
  }) {
    return _bucketAdminWrite(
      engineId: engineId,
      method: 'putBucketEncryption',
      profile: profile,
      bucketName: bucketName,
      payloadKey: 'encryptionJson',
      payloadValue: encryptionJson,
      onFallback: () => _fallback.putBucketEncryption(
        engineId: engineId,
        profile: profile,
        bucketName: bucketName,
        encryptionJson: encryptionJson,
      ),
    );
  }

  @override
  Future<BucketAdminState> deleteBucketEncryption({
    required String engineId,
    required EndpointProfile profile,
    required String bucketName,
  }) {
    return _bucketAdminWrite(
      engineId: engineId,
      method: 'deleteBucketEncryption',
      profile: profile,
      bucketName: bucketName,
      onFallback: () => _fallback.deleteBucketEncryption(
        engineId: engineId,
        profile: profile,
        bucketName: bucketName,
      ),
    );
  }

  @override
  Future<BucketAdminState> putBucketTagging({
    required String engineId,
    required EndpointProfile profile,
    required String bucketName,
    required Map<String, String> tags,
  }) {
    return _bucketAdminWrite(
      engineId: engineId,
      method: 'putBucketTagging',
      profile: profile,
      bucketName: bucketName,
      payloadKey: 'tags',
      payloadValue: tags,
      onFallback: () => _fallback.putBucketTagging(
        engineId: engineId,
        profile: profile,
        bucketName: bucketName,
        tags: tags,
      ),
    );
  }

  @override
  Future<BucketAdminState> deleteBucketTagging({
    required String engineId,
    required EndpointProfile profile,
    required String bucketName,
  }) {
    return _bucketAdminWrite(
      engineId: engineId,
      method: 'deleteBucketTagging',
      profile: profile,
      bucketName: bucketName,
      onFallback: () => _fallback.deleteBucketTagging(
        engineId: engineId,
        profile: profile,
        bucketName: bucketName,
      ),
    );
  }

  @override
  Future<ObjectListResult> listObjects({
    required String engineId,
    required EndpointProfile profile,
    required String bucketName,
    required String prefix,
    required bool flat,
    ListCursor? cursor,
  }) {
    return _sendWithFallback(
      engineId: engineId,
      method: 'listObjects',
      params: {
        'profile': _profileToJson(profile),
        'bucketName': bucketName,
        'prefix': prefix,
        'flat': flat,
        'cursor': cursor == null
            ? null
            : {
                'value': cursor.value,
                'hasMore': cursor.hasMore,
              },
      },
      onSuccess: _objectListResultFromJson,
      onFallback: () => _fallback.listObjects(
        engineId: engineId,
        profile: profile,
        bucketName: bucketName,
        prefix: prefix,
        flat: flat,
        cursor: cursor,
      ),
    );
  }

  @override
  Future<ObjectVersionListResult> listObjectVersions({
    required String engineId,
    required EndpointProfile profile,
    required String bucketName,
    String? key,
    VersionBrowserOptions? options,
    ListCursor? cursor,
  }) {
    return _sendWithFallback(
      engineId: engineId,
      method: 'listObjectVersions',
      params: {
        'profile': _profileToJson(profile),
        'bucketName': bucketName,
        'key': key,
        'options': _versionOptionsToJson(options),
        'cursor': cursor == null
            ? null
            : {
                'value': cursor.value,
                'hasMore': cursor.hasMore,
              },
      },
      onSuccess: _objectVersionListResultFromJson,
      onFallback: () => _fallback.listObjectVersions(
        engineId: engineId,
        profile: profile,
        bucketName: bucketName,
        key: key,
        options: options,
        cursor: cursor,
      ),
    );
  }

  @override
  Future<ObjectDetails> getObjectDetails({
    required String engineId,
    required EndpointProfile profile,
    required String bucketName,
    required String key,
  }) {
    return _sendWithFallback(
      engineId: engineId,
      method: 'getObjectDetails',
      params: {
        'profile': _profileToJson(profile),
        'bucketName': bucketName,
        'key': key,
      },
      onSuccess: _objectDetailsFromJson,
      onFallback: () => _fallback.getObjectDetails(
        engineId: engineId,
        profile: profile,
        bucketName: bucketName,
        key: key,
      ),
    );
  }

  @override
  Future<void> createFolder({
    required String engineId,
    required EndpointProfile profile,
    required String bucketName,
    required String key,
  }) async {
    await _sendWithFallback<void>(
      engineId: engineId,
      method: 'createFolder',
      params: {
        'profile': _profileToJson(profile),
        'bucketName': bucketName,
        'key': key,
      },
      onSuccess: (_) {},
      onFallback: () => _fallback.createFolder(
        engineId: engineId,
        profile: profile,
        bucketName: bucketName,
        key: key,
      ),
    );
  }

  @override
  Future<BatchOperationResult> copyObject({
    required String engineId,
    required EndpointProfile profile,
    required String sourceBucketName,
    required String sourceKey,
    required String destinationBucketName,
    required String destinationKey,
  }) {
    return _objectWrite(
      engineId: engineId,
      method: 'copyObject',
      params: {
        'profile': _profileToJson(profile),
        'sourceBucketName': sourceBucketName,
        'sourceKey': sourceKey,
        'destinationBucketName': destinationBucketName,
        'destinationKey': destinationKey,
      },
      onFallback: () => _fallback.copyObject(
        engineId: engineId,
        profile: profile,
        sourceBucketName: sourceBucketName,
        sourceKey: sourceKey,
        destinationBucketName: destinationBucketName,
        destinationKey: destinationKey,
      ),
    );
  }

  @override
  Future<BatchOperationResult> moveObject({
    required String engineId,
    required EndpointProfile profile,
    required String sourceBucketName,
    required String sourceKey,
    required String destinationBucketName,
    required String destinationKey,
  }) {
    return _objectWrite(
      engineId: engineId,
      method: 'moveObject',
      params: {
        'profile': _profileToJson(profile),
        'sourceBucketName': sourceBucketName,
        'sourceKey': sourceKey,
        'destinationBucketName': destinationBucketName,
        'destinationKey': destinationKey,
      },
      onFallback: () => _fallback.moveObject(
        engineId: engineId,
        profile: profile,
        sourceBucketName: sourceBucketName,
        sourceKey: sourceKey,
        destinationBucketName: destinationBucketName,
        destinationKey: destinationKey,
      ),
    );
  }

  @override
  Future<BatchOperationResult> deleteObjects({
    required String engineId,
    required EndpointProfile profile,
    required String bucketName,
    required List<String> keys,
  }) {
    return _objectWrite(
      engineId: engineId,
      method: 'deleteObjects',
      params: {
        'profile': _profileToJson(profile),
        'bucketName': bucketName,
        'keys': keys,
      },
      onFallback: () => _fallback.deleteObjects(
        engineId: engineId,
        profile: profile,
        bucketName: bucketName,
        keys: keys,
      ),
    );
  }

  @override
  Future<BatchOperationResult> deleteObjectVersions({
    required String engineId,
    required EndpointProfile profile,
    required String bucketName,
    required List<ObjectVersionRef> versions,
  }) {
    return _objectWrite(
      engineId: engineId,
      method: 'deleteObjectVersions',
      params: {
        'profile': _profileToJson(profile),
        'bucketName': bucketName,
        'versions': versions
            .map((item) => {'key': item.key, 'versionId': item.versionId})
            .toList(),
      },
      onFallback: () => _fallback.deleteObjectVersions(
        engineId: engineId,
        profile: profile,
        bucketName: bucketName,
        versions: versions,
      ),
    );
  }

  @override
  Future<TransferJob> startUpload({
    required String engineId,
    required EndpointProfile profile,
    required String bucketName,
    required String prefix,
    required List<String> filePaths,
    required Map<String, String> objectKeyByPath,
    required int multipartThresholdMiB,
    required int multipartChunkMiB,
  }) {
    return _sendWithFallback(
      engineId: engineId,
      method: 'startUpload',
      params: {
        'profile': _profileToJson(profile),
        'bucketName': bucketName,
        'prefix': prefix,
        'filePaths': filePaths,
        'objectKeyByPath': objectKeyByPath,
        'multipartThresholdMiB': multipartThresholdMiB,
        'multipartChunkMiB': multipartChunkMiB,
      },
      onSuccess: _transferJobFromJson,
      onEvent: _handleSidecarEvent,
      onFallback: () => _fallback.startUpload(
        engineId: engineId,
        profile: profile,
        bucketName: bucketName,
        prefix: prefix,
        filePaths: filePaths,
        objectKeyByPath: objectKeyByPath,
        multipartThresholdMiB: multipartThresholdMiB,
        multipartChunkMiB: multipartChunkMiB,
      ),
    );
  }

  @override
  Future<TransferJob> startDownload({
    required String engineId,
    required EndpointProfile profile,
    required String bucketName,
    required List<String> keys,
    required String destinationPath,
    required int multipartThresholdMiB,
    required int multipartChunkMiB,
  }) {
    return _sendWithFallback(
      engineId: engineId,
      method: 'startDownload',
      params: {
        'profile': _profileToJson(profile),
        'bucketName': bucketName,
        'keys': keys,
        'destinationPath': destinationPath,
        'multipartThresholdMiB': multipartThresholdMiB,
        'multipartChunkMiB': multipartChunkMiB,
      },
      onSuccess: _transferJobFromJson,
      onEvent: _handleSidecarEvent,
      onFallback: () => _fallback.startDownload(
        engineId: engineId,
        profile: profile,
        bucketName: bucketName,
        keys: keys,
        destinationPath: destinationPath,
        multipartThresholdMiB: multipartThresholdMiB,
        multipartChunkMiB: multipartChunkMiB,
      ),
    );
  }

  @override
  Future<TransferJob> pauseTransfer({
    required String engineId,
    required String jobId,
  }) {
    return _sendWithFallback(
      engineId: engineId,
      method: 'pauseTransfer',
      params: {'jobId': jobId},
      onSuccess: _transferJobFromJson,
      onFallback: () =>
          _fallback.pauseTransfer(engineId: engineId, jobId: jobId),
    );
  }

  @override
  Future<TransferJob> resumeTransfer({
    required String engineId,
    required String jobId,
  }) {
    return _sendWithFallback(
      engineId: engineId,
      method: 'resumeTransfer',
      params: {'jobId': jobId},
      onSuccess: _transferJobFromJson,
      onFallback: () =>
          _fallback.resumeTransfer(engineId: engineId, jobId: jobId),
    );
  }

  @override
  Future<TransferJob> cancelTransfer({
    required String engineId,
    required String jobId,
  }) {
    return _sendWithFallback(
      engineId: engineId,
      method: 'cancelTransfer',
      params: {'jobId': jobId},
      onSuccess: _transferJobFromJson,
      onFallback: () =>
          _fallback.cancelTransfer(engineId: engineId, jobId: jobId),
    );
  }

  @override
  Future<String> generatePresignedUrl({
    required String engineId,
    required EndpointProfile profile,
    required String bucketName,
    required String key,
    required Duration expiration,
  }) async {
    return _sendWithFallback(
      engineId: engineId,
      method: 'generatePresignedUrl',
      params: {
        'profile': _profileToJson(profile),
        'bucketName': bucketName,
        'key': key,
        'expirationSeconds': expiration.inSeconds,
      },
      onSuccess: (result) => (result['url'] as String?) ?? '',
      onFallback: () => _fallback.generatePresignedUrl(
        engineId: engineId,
        profile: profile,
        bucketName: bucketName,
        key: key,
        expiration: expiration,
      ),
    );
  }

  @override
  Future<ToolExecutionState> runPutTestData({
    required String engineId,
    required EndpointProfile profile,
    required TestDataToolConfig config,
  }) {
    return _sendWithFallback(
      engineId: engineId,
      method: 'runPutTestData',
      params: {
        'profile': _profileToJson(profile),
        'config': {
          'bucketName': config.bucketName,
          'endpointUrl': config.endpointUrl,
          'accessKey': config.accessKey,
          'secretKey': config.secretKey,
          'objectSizeBytes': config.objectSizeBytes,
          'versions': config.versions,
          'objectCount': config.objectCount,
          'prefix': config.prefix,
          'threads': config.threads,
          'checksumAlgorithm': config.checksumAlgorithm,
        },
      },
      onSuccess: _toolExecutionStateFromJson,
      onFallback: () => _fallback.runPutTestData(
        engineId: engineId,
        profile: profile,
        config: config,
      ),
    );
  }

  @override
  Future<ToolExecutionState> runDeleteAll({
    required String engineId,
    required EndpointProfile profile,
    required DeleteAllToolConfig config,
  }) {
    return _sendWithFallback(
      engineId: engineId,
      method: 'runDeleteAll',
      params: {
        'profile': _profileToJson(profile),
        'config': {
          'bucketName': config.bucketName,
          'endpointUrl': config.endpointUrl,
          'accessKey': config.accessKey,
          'secretKey': config.secretKey,
          'checksumAlgorithm': config.checksumAlgorithm,
          'batchSize': config.batchSize,
          'maxWorkers': config.maxWorkers,
          'maxRetries': config.maxRetries,
          'retryMode': config.retryMode,
          'maxRequestsPerSecond': config.maxRequestsPerSecond,
          'maxConnections': config.maxConnections,
          'pipelineSize': config.pipelineSize,
          'listMaxKeys': config.listMaxKeys,
          'deletionDelayMs': config.deletionDelayMs,
          'immediateDeletion': config.immediateDeletion,
        },
      },
      onSuccess: _toolExecutionStateFromJson,
      onFallback: () => _fallback.runDeleteAll(
        engineId: engineId,
        profile: profile,
        config: config,
      ),
    );
  }

  @override
  Future<ToolExecutionState> cancelToolExecution({
    required String engineId,
    required String jobId,
  }) {
    return _sendWithFallback(
      engineId: engineId,
      method: 'cancelToolExecution',
      params: {'jobId': jobId},
      onSuccess: _toolExecutionStateFromJson,
      onFallback: () =>
          _fallback.cancelToolExecution(engineId: engineId, jobId: jobId),
    );
  }

  @override
  Future<BenchmarkRun> startBenchmark({
    required BenchmarkConfig config,
    required EndpointProfile profile,
  }) async {
    final run = await _sendWithFallback(
      engineId: config.engineId,
      method: 'startBenchmark',
      params: {
        'config': _benchmarkConfigToJson(config),
        'profile': _profileToJson(profile),
      },
      onSuccess: _benchmarkRunFromJson,
      onFallback: () => _fallback.startBenchmark(
        config: config,
        profile: profile,
      ),
    );
    _benchmarkEngines[run.id] = run.config.engineId;
    return run;
  }

  @override
  Future<BenchmarkRun> getBenchmarkStatus(String runId) {
    final engineId = _benchmarkEngines[runId] ?? 'rust';
    return _sendWithFallback(
      engineId: engineId,
      method: 'getBenchmarkStatus',
      params: {'runId': runId},
      onSuccess: (json) {
        final run = _benchmarkRunFromJson(json);
        _benchmarkEngines[run.id] = run.config.engineId;
        return run;
      },
      onFallback: () => _fallback.getBenchmarkStatus(runId),
    );
  }

  @override
  Future<void> pauseBenchmark(String runId) {
    final engineId = _benchmarkEngines[runId] ?? 'rust';
    return _sendWithFallback<void>(
      engineId: engineId,
      method: 'pauseBenchmark',
      params: {'runId': runId},
      onSuccess: (_) {},
      onFallback: () => _fallback.pauseBenchmark(runId),
    );
  }

  @override
  Future<void> resumeBenchmark(String runId) {
    final engineId = _benchmarkEngines[runId] ?? 'rust';
    return _sendWithFallback<void>(
      engineId: engineId,
      method: 'resumeBenchmark',
      params: {'runId': runId},
      onSuccess: (_) {},
      onFallback: () => _fallback.resumeBenchmark(runId),
    );
  }

  @override
  Future<void> stopBenchmark(String runId) {
    final engineId = _benchmarkEngines[runId] ?? 'rust';
    return _sendWithFallback<void>(
      engineId: engineId,
      method: 'stopBenchmark',
      params: {'runId': runId},
      onSuccess: (_) {},
      onFallback: () => _fallback.stopBenchmark(runId),
    );
  }

  @override
  Future<BenchmarkExportBundle> exportBenchmarkResults({
    required String runId,
    required String format,
  }) {
    final engineId = _benchmarkEngines[runId] ?? 'rust';
    return _sendWithFallback(
      engineId: engineId,
      method: 'exportBenchmarkResults',
      params: {
        'runId': runId,
        'format': format,
      },
      onSuccess: _benchmarkExportBundleFromJson,
      onFallback: () =>
          _fallback.exportBenchmarkResults(runId: runId, format: format),
    );
  }

  Future<BucketAdminState> _bucketAdminWrite({
    required String engineId,
    required String method,
    required EndpointProfile profile,
    required String bucketName,
    String? payloadKey,
    Object? payloadValue,
    required Future<BucketAdminState> Function() onFallback,
  }) {
    final params = <String, Object?>{
      'profile': _profileToJson(profile),
      'bucketName': bucketName,
    };
    if (payloadKey != null) {
      params[payloadKey] = payloadValue;
    }
    return _sendWithFallback(
      engineId: engineId,
      method: method,
      params: params,
      onSuccess: _bucketAdminStateFromJson,
      onFallback: onFallback,
    );
  }

  Future<BatchOperationResult> _objectWrite({
    required String engineId,
    required String method,
    required Map<String, Object?> params,
    required Future<BatchOperationResult> Function() onFallback,
  }) {
    return _sendWithFallback(
      engineId: engineId,
      method: method,
      params: params,
      onSuccess: _batchOperationResultFromJson,
      onFallback: onFallback,
    );
  }

  Future<T> _sendWithFallback<T>({
    required String engineId,
    required String method,
    required T Function(Map<String, Object?> result) onSuccess,
    required Future<T> Function() onFallback,
    Map<String, Object?>? params,
    void Function(Map<String, Object?> event)? onEvent,
  }) async {
    final entry = await _tryGetEngine(engineId);
    if (entry == null) {
      _log(
        level: 'DEBUG',
        category: 'EngineFallback',
        message:
            'No sidecar manifest entry for $engineId.$method. Using fallback service.',
        source: 'debug',
        params: params,
      );
      return onFallback();
    }

    try {
      final result = await _sendSidecarRequest(
        entry,
        method: method,
        params: params,
        onEvent: onEvent,
      );
      return onSuccess(result);
    } on EngineException catch (error) {
      if (error.code == ErrorCode.unsupportedFeature ||
          error.code == ErrorCode.engineUnavailable) {
        _log(
          level: 'DEBUG',
          category: 'EngineFallback',
          message:
              'Sidecar returned ${error.code.name} for $engineId.$method. Using fallback service.',
          source: 'debug',
          params: params,
        );
        return onFallback();
      }
      rethrow;
    } on ProcessException catch (error) {
      _log(
        level: 'ERROR',
        category: 'EngineHost',
        message: 'Host process failed for $engineId.$method: ${error.message}',
        source: 'engine-host',
        params: params,
      );
      return onFallback();
    }
  }

  Future<_EngineManifestEntry?> _tryGetEngine(String engineId) async {
    final manifest = await _loadManifest();
    return manifest[engineId];
  }

  Future<Map<String, Object?>> _sendSidecarRequest(
    _EngineManifestEntry entry, {
    required String method,
    Map<String, Object?>? params,
    void Function(Map<String, Object?> event)? onEvent,
  }) async {
    final engineRoot = await _resolveEngineRoot();
    final requestId = DateTime.now().microsecondsSinceEpoch.toString();
    final request = <String, Object?>{
      'requestId': requestId,
      'method': method,
      'params': params ?? const <String, Object?>{},
    };
    final requestHead = <String, Object?>{
      'engine': entry.id,
      'method': method,
      'requestId': requestId,
    };
    final requestBody = _sanitizeForLogging(request['params']);
    _log(
      level: 'API',
      category: 'EngineRequest',
      message:
          'REQUEST ${entry.id}.$method HEAD=${_stringifyForLogging(requestHead)} BODY=${_stringifyForLogging(requestBody)}',
      source: 'api',
      params: params,
      requestId: requestId,
      tracePhase: 'send',
      engineId: entry.id,
      method: method,
      traceHead: requestHead,
      traceBody: requestBody,
    );
    final startedAt = DateTime.now();
    final response = await _host.send(
      executablePath: _join(engineRoot, entry.executable),
      arguments: entry.arguments,
      workingDirectory: entry.workingDirectory == null
          ? engineRoot
          : _join(engineRoot, entry.workingDirectory!),
      request: request,
      onEvent: onEvent,
    );
    final latencyMs = DateTime.now().difference(startedAt).inMilliseconds;
    _handleStructuredLogs(response.stderrOutput, params: params);
    final responseHead = <String, Object?>{
      'ok': response.payload['ok'],
      'requestId': requestId,
    };
    final responseBody = _sanitizeForLogging(response.payload);
    _log(
      level: 'API',
      category: 'EngineResponse',
      message:
          'RESPONSE ${entry.id}.$method HEAD=${_stringifyForLogging(responseHead)} BODY=${_stringifyForLogging(responseBody)}',
      source: 'api',
      params: params,
      requestId: requestId,
      tracePhase: 'response',
      engineId: entry.id,
      method: method,
      responseStatus: _responseStatusLabel(response.payload),
      latencyMs: latencyMs,
      traceHead: responseHead,
      traceBody: responseBody,
    );

    final payload = response.payload;
    final ok = payload['ok'] as bool? ?? false;
    if (!ok) {
      final error = Map<String, Object?>.from(
        payload['error'] as Map? ?? const <String, Object?>{},
      );
      final details = error['details'] == null
          ? null
          : Map<String, Object?>.from(error['details'] as Map);
      final detailSuffix = details == null || details.isEmpty
          ? ''
          : ' ${_stringifyForLogging(_sanitizeForLogging(details))}';
      _log(
        level: 'ERROR',
        category: 'EngineError',
        message:
            '${entry.id}.$method ${(error['message'] as String?) ?? 'Unknown engine error.'}$detailSuffix',
        source: 'engine-error',
        params: params,
      );
      throw EngineException(
        code: _parseErrorCode(error['code'] as String?),
        message: (error['message'] as String?) ?? 'Unknown engine error.',
        details: details,
      );
    }

    return Map<String, Object?>.from(
      payload['result'] as Map? ?? const <String, Object?>{},
    );
  }

  void _log({
    required String level,
    required String category,
    required String message,
    required String source,
    Map<String, Object?>? params,
    String? requestId,
    String? tracePhase,
    String? engineId,
    String? method,
    String? responseStatus,
    int? latencyMs,
    Object? traceHead,
    Object? traceBody,
  }) {
    final sink = _logSink;
    if (sink == null) {
      return;
    }
    sink(
      EngineLogRecord(
        level: level,
        category: category,
        message: message,
        profileId: _profileIdFromParams(params),
        bucketName: _bucketNameFromParams(params),
        objectKey: _objectKeyFromParams(params),
        source: source,
        requestId: requestId,
        tracePhase: tracePhase,
        engineId: engineId,
        method: method,
        responseStatus: responseStatus,
        latencyMs: latencyMs,
        traceHead: traceHead,
        traceBody: traceBody,
      ),
    );
  }

  void _handleSidecarEvent(Map<String, Object?> event) {
    if (event['event'] != 'transferProgress') {
      return;
    }
    final job = event['job'];
    if (job is! Map) {
      return;
    }
    _transferSink?.call(_transferJobFromJson(Map<String, Object?>.from(job)));
  }

  void _handleStructuredLogs(
    String stderrOutput, {
    required Map<String, Object?>? params,
  }) {
    if (stderrOutput.trim().isEmpty) {
      return;
    }
    final passthrough = <String>[];
    for (final rawLine in const LineSplitter().convert(stderrOutput)) {
      final line = rawLine.trim();
      if (line.isEmpty) {
        continue;
      }
      if (!line.startsWith('S3_BROWSER_LOG ')) {
        passthrough.add(line);
        continue;
      }
      try {
        final payload = Map<String, Object?>.from(
          jsonDecode(line.substring('S3_BROWSER_LOG '.length)) as Map,
        );
        _log(
          level: (payload['level'] as String?) ?? 'DEBUG',
          category: (payload['category'] as String?) ?? 'EngineLog',
          message: (payload['message'] as String?) ?? '',
          source: (payload['source'] as String?) ?? 'debug',
          params: params,
        );
      } catch (_) {
        passthrough.add(line);
      }
    }
    if (passthrough.isNotEmpty) {
      _log(
        level: 'DEBUG',
        category: 'EngineStderr',
        message: passthrough.join('\n'),
        source: 'debug',
        params: params,
      );
    }
  }

  String? _profileIdFromParams(Map<String, Object?>? params) {
    final profile =
        Map<String, Object?>.from(params?['profile'] as Map? ?? const {});
    return profile['id'] as String?;
  }

  String? _bucketNameFromParams(Map<String, Object?>? params) {
    return (params?['bucketName'] as String?) ??
        (params?['sourceBucketName'] as String?) ??
        (params?['destinationBucketName'] as String?);
  }

  String? _objectKeyFromParams(Map<String, Object?>? params) {
    return (params?['key'] as String?) ??
        (params?['sourceKey'] as String?) ??
        (params?['destinationKey'] as String?);
  }

  Object? _sanitizeForLogging(Object? value) {
    if (value is Map) {
      return value.map(
        (key, entry) => MapEntry(
          key.toString(),
          switch (key.toString()) {
            'accessKey' || 'secretKey' || 'sessionToken' => '[redacted]',
            _ => _sanitizeForLogging(entry),
          },
        ),
      );
    }
    if (value is List) {
      return value.map(_sanitizeForLogging).toList();
    }
    return value;
  }

  String _stringifyForLogging(Object? value) {
    const maxLength = 2000;
    final encoded = jsonEncode(value);
    if (encoded.length <= maxLength) {
      return encoded;
    }
    return '${encoded.substring(0, maxLength)}...';
  }

  String _responseStatusLabel(Map<String, Object?> payload) {
    if (payload['ok'] == true) {
      return 'ok';
    }
    final error = Map<String, Object?>.from(
      payload['error'] as Map? ?? const <String, Object?>{},
    );
    final code = error['code'] as String?;
    if (code != null && code.isNotEmpty) {
      return code;
    }
    return 'error';
  }

  Future<Map<String, _EngineManifestEntry>> _loadManifest() async {
    if (_cachedManifest != null) {
      return _cachedManifest!;
    }

    final engineRoot = await _resolveEngineRoot();
    final manifestPath = _join(engineRoot, 'manifest.json');
    final manifestFile = File(manifestPath);
    if (!manifestFile.existsSync()) {
      _cachedManifest = <String, _EngineManifestEntry>{};
      return _cachedManifest!;
    }

    final decoded = jsonDecode(await manifestFile.readAsString()) as Map;
    final engines = (decoded['engines'] as List<Object?>? ?? const []);
    final manifest = <String, _EngineManifestEntry>{};
    for (final entry in engines) {
      final value = Map<String, Object?>.from(entry as Map);
      final manifestEntry = _EngineManifestEntry.fromJson(value);
      manifest[manifestEntry.id] = manifestEntry;
    }

    _cachedManifest = manifest;
    return manifest;
  }

  Future<String> _resolveEngineRoot() async {
    if (_cachedEngineRoot != null) {
      return _cachedEngineRoot!;
    }

    final candidates = <String>[
      _join(File(Platform.resolvedExecutable).parent.parent.path, 'Resources',
          'engines'),
      _join(File(Platform.resolvedExecutable).parent.path, 'engines'),
      _join(Directory.current.path, 'engines'),
      _join(Directory.current.path, '..', '..', 'engines'),
      _join(_join(Directory.current.path, '..', '..', '..'), 'engines'),
    ];

    for (final candidate in candidates) {
      if (File(_join(candidate, 'manifest.json')).existsSync()) {
        _cachedEngineRoot = candidate;
        return candidate;
      }
    }

    for (final candidate in candidates) {
      if (Directory(candidate).existsSync()) {
        _cachedEngineRoot = candidate;
        return candidate;
      }
    }

    _cachedEngineRoot = candidates.first;
    return _cachedEngineRoot!;
  }

  static String _join(String base,
      [String? segment1, String? segment2, String? segment3]) {
    final parts = <String>[
      base,
      if (segment1 != null) segment1,
      if (segment2 != null) segment2,
      if (segment3 != null) segment3,
    ];
    return parts
        .join(Platform.pathSeparator)
        .replaceAll(RegExp(r'[\\/]+'), Platform.pathSeparator);
  }

  Map<String, Object?> _profileToJson(EndpointProfile profile) {
    return {
      'id': profile.id,
      'name': profile.name,
      'endpointUrl': profile.endpointUrl,
      'region': profile.region,
      'endpointType': profile.endpointType.name,
      'accessKey': profile.accessKey,
      'secretKey': profile.secretKey,
      'sessionToken': profile.sessionToken,
      'pathStyle': profile.pathStyle,
      'verifyTls': profile.verifyTls,
      'signerOverride': profile.signerOverride,
      'connectTimeoutSeconds': profile.connectTimeoutSeconds,
      'readTimeoutSeconds': profile.readTimeoutSeconds,
      'maxConcurrentRequests': profile.maxConcurrentRequests,
      'maxAttempts': profile.maxAttempts,
      'maxRequestsPerSecond': profile.maxRequestsPerSecond,
      'diagnostics': _diagnosticsOptions.toJson(),
    };
  }

  static Map<String, Object?>? _versionOptionsToJson(
      VersionBrowserOptions? value) {
    if (value == null) {
      return null;
    }
    return {
      'filterValue': value.filterValue,
      'filterMode': value.filterMode.name,
      'showVersions': value.showVersions,
      'showDeleteMarkers': value.showDeleteMarkers,
    };
  }

  static Map<String, Object?> _benchmarkConfigToJson(BenchmarkConfig config) {
    return {
      'profileId': config.profileId,
      'engineId': config.engineId,
      'bucketName': config.bucketName,
      'prefix': config.prefix,
      'workloadType': config.workloadType,
      'deleteMode': config.deleteMode,
      'objectSizes': config.objectSizes,
      'concurrentThreads': config.concurrentThreads,
      'testMode': config.testMode,
      'operationCount': config.operationCount,
      'durationSeconds': config.durationSeconds,
      'validateChecksum': config.validateChecksum,
      'checksumAlgorithm': config.checksumAlgorithm,
      'randomData': config.randomData,
      'inMemoryData': config.inMemoryData,
      'objectCount': config.objectCount,
      'connectTimeoutSeconds': config.connectTimeoutSeconds,
      'readTimeoutSeconds': config.readTimeoutSeconds,
      'maxAttempts': config.maxAttempts,
      'maxPoolConnections': config.maxPoolConnections,
      'dataCacheMb': config.dataCacheMb,
      'csvOutputPath': config.csvOutputPath,
      'jsonOutputPath': config.jsonOutputPath,
      'logFilePath': config.logFilePath,
      'debugMode': config.debugMode,
      'readPercent': config.readPercent,
      'writePercent': config.writePercent,
      'deletePercent': config.deletePercent,
      'reducedLogging': config.reducedLogging,
    };
  }

  static CapabilityDescriptor _capabilityFromJson(Map<String, Object?> json) {
    return CapabilityDescriptor(
      key: (json['key'] as String?) ?? '',
      label: (json['label'] as String?) ?? '',
      state: switch (json['state']) {
        'supported' => CapabilityState.supported,
        'unsupported' => CapabilityState.unsupported,
        _ => CapabilityState.unknown,
      },
      reason: json['reason'] as String?,
    );
  }

  static BucketSummary _bucketFromJson(Map<String, Object?> json) {
    return BucketSummary(
      name: (json['name'] as String?) ?? '',
      region: (json['region'] as String?) ?? '',
      objectCountHint: (json['objectCountHint'] as num?)?.toInt() ?? 0,
      versioningEnabled: json['versioningEnabled'] as bool? ?? false,
      createdAt: json['createdAt'] == null
          ? null
          : DateTime.tryParse(json['createdAt'] as String),
    );
  }

  static ObjectListResult _objectListResultFromJson(Map<String, Object?> json) {
    final items = (json['items'] as List<Object?>? ?? const [])
        .map((item) => _objectFromJson(Map<String, Object?>.from(item as Map)))
        .toList();
    final cursor = Map<String, Object?>.from(
      (json['nextCursor'] as Map?) ??
          (json['cursor'] as Map?) ??
          const {'value': null, 'hasMore': false},
    );
    return ObjectListResult(
      items: items,
      cursor: ListCursor(
        value: cursor['value'] as String?,
        hasMore: cursor['hasMore'] as bool? ?? false,
      ),
    );
  }

  static ObjectEntry _objectFromJson(Map<String, Object?> json) {
    return ObjectEntry(
      key: (json['key'] as String?) ?? '',
      name: (json['name'] as String?) ?? '',
      size: (json['size'] as num?)?.toInt() ?? 0,
      storageClass: (json['storageClass'] as String?) ?? 'STANDARD',
      modifiedAt: DateTime.tryParse((json['modifiedAt'] as String?) ?? '') ??
          DateTime.fromMillisecondsSinceEpoch(0),
      isFolder: json['isFolder'] as bool? ?? false,
      etag: json['etag'] as String?,
      metadataCount: (json['metadataCount'] as num?)?.toInt() ?? 0,
    );
  }

  static ObjectVersionListResult _objectVersionListResultFromJson(
    Map<String, Object?> json,
  ) {
    final items = (json['items'] as List<Object?>? ?? const [])
        .map(
          (item) => _objectVersionFromJson(
            Map<String, Object?>.from(item as Map),
          ),
        )
        .toList();
    final cursor = Map<String, Object?>.from(
      (json['nextCursor'] as Map?) ??
          (json['cursor'] as Map?) ??
          const {'value': null, 'hasMore': false},
    );
    return ObjectVersionListResult(
      items: items,
      cursor: ListCursor(
        value: cursor['value'] as String?,
        hasMore: cursor['hasMore'] as bool? ?? false,
      ),
      totalCount: (json['totalCount'] as num?)?.toInt() ?? items.length,
      versionCount: (json['versionCount'] as num?)?.toInt() ??
          items.where((item) => !item.deleteMarker).length,
      deleteMarkerCount: (json['deleteMarkerCount'] as num?)?.toInt() ??
          items.where((item) => item.deleteMarker).length,
    );
  }

  static ObjectVersionEntry _objectVersionFromJson(Map<String, Object?> json) {
    return ObjectVersionEntry(
      key: (json['key'] as String?) ?? '',
      versionId: (json['versionId'] as String?) ?? '',
      modifiedAt: DateTime.tryParse((json['modifiedAt'] as String?) ?? '') ??
          DateTime.fromMillisecondsSinceEpoch(0),
      latest: json['latest'] as bool? ?? false,
      deleteMarker: json['deleteMarker'] as bool? ?? false,
      size: (json['size'] as num?)?.toInt() ?? 0,
      storageClass: (json['storageClass'] as String?) ?? 'STANDARD',
    );
  }

  static BucketAdminState _bucketAdminStateFromJson(Map<String, Object?> json) {
    final tags = Map<String, String>.from(
      (json['tags'] as Map?)?.map(
            (key, value) => MapEntry(key.toString(), value.toString()),
          ) ??
          const <String, String>{},
    );
    final rules = (json['lifecycleRules'] as List<Object?>? ?? const [])
        .map(
          (item) =>
              _lifecycleRuleFromJson(Map<String, Object?>.from(item as Map)),
        )
        .toList();
    final apiCalls = (json['apiCalls'] as List<Object?>? ?? const [])
        .map((item) =>
            _apiCallRecordFromJson(Map<String, Object?>.from(item as Map)))
        .toList();

    return BucketAdminState(
      bucketName: (json['bucketName'] as String?) ?? '',
      versioningEnabled: json['versioningEnabled'] as bool? ?? false,
      versioningStatus: (json['versioningStatus'] as String?) ?? 'Unknown',
      objectLockEnabled: json['objectLockEnabled'] as bool? ?? false,
      lifecycleEnabled: json['lifecycleEnabled'] as bool? ?? false,
      policyAttached: json['policyAttached'] as bool? ?? false,
      corsEnabled: json['corsEnabled'] as bool? ?? false,
      encryptionEnabled: json['encryptionEnabled'] as bool? ?? false,
      encryptionSummary:
          (json['encryptionSummary'] as String?) ?? 'Not configured',
      objectLockMode: json['objectLockMode'] as String?,
      objectLockRetentionDays:
          (json['objectLockRetentionDays'] as num?)?.toInt(),
      tags: tags,
      lifecycleRules: rules,
      policyJson: (json['policyJson'] as String?) ?? '{}',
      corsJson: (json['corsJson'] as String?) ?? '[]',
      lifecycleJson:
          (json['lifecycleJson'] as String?) ?? '{\n  "Rules": []\n}',
      encryptionJson: (json['encryptionJson'] as String?) ?? '{}',
      apiCalls: apiCalls,
    );
  }

  static LifecycleRule _lifecycleRuleFromJson(Map<String, Object?> json) {
    return LifecycleRule(
      id: (json['id'] as String?) ?? '',
      enabled: json['enabled'] as bool? ?? false,
      prefix: (json['prefix'] as String?) ?? '',
      expirationDays: (json['expirationDays'] as num?)?.toInt(),
      deleteExpiredObjectDeleteMarkers:
          json['deleteExpiredObjectDeleteMarkers'] as bool? ?? false,
      transitionStorageClass: json['transitionStorageClass'] as String?,
      transitionDays: (json['transitionDays'] as num?)?.toInt(),
      nonCurrentExpirationDays:
          (json['nonCurrentExpirationDays'] as num?)?.toInt(),
      nonCurrentTransitionStorageClass:
          json['nonCurrentTransitionStorageClass'] as String?,
      nonCurrentTransitionDays:
          (json['nonCurrentTransitionDays'] as num?)?.toInt(),
      abortIncompleteMultipartUploadDays:
          (json['abortIncompleteMultipartUploadDays'] as num?)?.toInt(),
    );
  }

  static ObjectDetails _objectDetailsFromJson(Map<String, Object?> json) {
    final metadata = Map<String, String>.from(
      (json['metadata'] as Map?)?.map(
            (key, value) => MapEntry(key.toString(), value.toString()),
          ) ??
          const <String, String>{},
    );
    final headers = Map<String, String>.from(
      (json['headers'] as Map?)?.map(
            (key, value) => MapEntry(key.toString(), value.toString()),
          ) ??
          const <String, String>{},
    );
    final tags = Map<String, String>.from(
      (json['tags'] as Map?)?.map(
            (key, value) => MapEntry(key.toString(), value.toString()),
          ) ??
          const <String, String>{},
    );
    final debugEvents = (json['debugEvents'] as List<Object?>? ?? const [])
        .map(
          (item) =>
              _diagnosticEventFromJson(Map<String, Object?>.from(item as Map)),
        )
        .toList();
    final apiCalls = (json['apiCalls'] as List<Object?>? ?? const [])
        .map((item) =>
            _apiCallRecordFromJson(Map<String, Object?>.from(item as Map)))
        .toList();
    final debugLogExcerpt =
        (json['debugLogExcerpt'] as List<Object?>? ?? const [])
            .map((item) => item.toString())
            .toList();

    return ObjectDetails(
      key: (json['key'] as String?) ?? '',
      metadata: metadata,
      headers: headers,
      tags: tags,
      debugEvents: debugEvents,
      apiCalls: apiCalls,
      presignedUrl: null,
      debugLogExcerpt: debugLogExcerpt,
      rawDiagnostics: Map<String, Object?>.from(
        json['rawDiagnostics'] as Map? ?? const <String, Object?>{},
      ),
    );
  }

  static DiagnosticEvent _diagnosticEventFromJson(Map<String, Object?> json) {
    return DiagnosticEvent(
      timestamp: DateTime.tryParse((json['timestamp'] as String?) ?? '') ??
          DateTime.fromMillisecondsSinceEpoch(0),
      level: (json['level'] as String?) ?? 'INFO',
      message: (json['message'] as String?) ?? '',
    );
  }

  static ApiCallRecord _apiCallRecordFromJson(Map<String, Object?> json) {
    return ApiCallRecord(
      timestamp: DateTime.tryParse((json['timestamp'] as String?) ?? '') ??
          DateTime.fromMillisecondsSinceEpoch(0),
      operation: (json['operation'] as String?) ?? '',
      status: (json['status'] as String?) ?? '',
      latencyMs: (json['latencyMs'] as num?)?.toInt() ?? 0,
    );
  }

  static BatchOperationResult _batchOperationResultFromJson(
    Map<String, Object?> json,
  ) {
    final failures = (json['failures'] as List<Object?>? ?? const [])
        .map(
          (item) => _batchOperationFailureFromJson(
            Map<String, Object?>.from(item as Map),
          ),
        )
        .toList();
    return BatchOperationResult(
      successCount: (json['successCount'] as num?)?.toInt() ?? 0,
      failureCount: (json['failureCount'] as num?)?.toInt() ?? failures.length,
      failures: failures,
    );
  }

  static BatchOperationFailure _batchOperationFailureFromJson(
    Map<String, Object?> json,
  ) {
    return BatchOperationFailure(
      target: (json['target'] as String?) ?? '',
      code: (json['code'] as String?) ?? 'unknown',
      message: (json['message'] as String?) ?? 'Unknown error.',
      versionId: json['versionId'] as String?,
    );
  }

  static TransferJob _transferJobFromJson(Map<String, Object?> json) {
    return TransferJob(
      id: (json['id'] as String?) ?? '',
      label: (json['label'] as String?) ?? '',
      direction: (json['direction'] as String?) ?? 'transfer',
      progress: (json['progress'] as num?)?.toDouble() ?? 0,
      status: (json['status'] as String?) ?? 'unknown',
      bytesTransferred: (json['bytesTransferred'] as num?)?.toInt() ?? 0,
      totalBytes: (json['totalBytes'] as num?)?.toInt() ?? 0,
      strategyLabel: json['strategyLabel'] as String?,
      currentItemLabel: json['currentItemLabel'] as String?,
      itemCount: (json['itemCount'] as num?)?.toInt(),
      itemsCompleted: (json['itemsCompleted'] as num?)?.toInt(),
      partSizeBytes: (json['partSizeBytes'] as num?)?.toInt(),
      partsCompleted: (json['partsCompleted'] as num?)?.toInt(),
      partsTotal: (json['partsTotal'] as num?)?.toInt(),
      canPause: json['canPause'] as bool? ?? true,
      canResume: json['canResume'] as bool? ?? true,
      canCancel: json['canCancel'] as bool? ?? true,
      outputLines: (json['outputLines'] as List<Object?>? ?? const [])
          .map((item) => item.toString())
          .toList(),
    );
  }

  static ToolExecutionState _toolExecutionStateFromJson(
      Map<String, Object?> json) {
    return ToolExecutionState(
      label: (json['label'] as String?) ?? '',
      running: json['running'] as bool? ?? false,
      lastStatus: (json['lastStatus'] as String?) ?? '',
      jobId: json['jobId'] as String?,
      cancellable: json['cancellable'] as bool? ?? false,
      outputLines: (json['outputLines'] as List<Object?>? ?? const [])
          .map((item) => item.toString())
          .toList(),
      exitCode: (json['exitCode'] as num?)?.toInt(),
    );
  }

  static BenchmarkRun _benchmarkRunFromJson(Map<String, Object?> json) {
    return BenchmarkRun(
      id: (json['id'] as String?) ?? '',
      config: BenchmarkConfig(
        profileId: ((json['config'] as Map?)?['profileId'] as String?) ?? '',
        engineId: ((json['config'] as Map?)?['engineId'] as String?) ?? '',
        bucketName: ((json['config'] as Map?)?['bucketName'] as String?) ?? '',
        prefix: ((json['config'] as Map?)?['prefix'] as String?) ?? '',
        workloadType:
            ((json['config'] as Map?)?['workloadType'] as String?) ?? 'mixed',
        deleteMode:
            ((json['config'] as Map?)?['deleteMode'] as String?) ?? 'single',
        objectSizes:
            (((json['config'] as Map?)?['objectSizes'] as List<Object?>?) ??
                    const [])
                .map((item) => (item as num).toInt())
                .toList(),
        concurrentThreads:
            (((json['config'] as Map?)?['concurrentThreads'] as num?)
                    ?.toInt()) ??
                1,
        testMode:
            ((json['config'] as Map?)?['testMode'] as String?) ?? 'duration',
        operationCount:
            (((json['config'] as Map?)?['operationCount'] as num?)?.toInt()) ??
                0,
        durationSeconds:
            (((json['config'] as Map?)?['durationSeconds'] as num?)?.toInt()) ??
                0,
        validateChecksum:
            ((json['config'] as Map?)?['validateChecksum'] as bool?) ?? true,
        checksumAlgorithm:
            ((json['config'] as Map?)?['checksumAlgorithm'] as String?) ??
                'crc32c',
        randomData: ((json['config'] as Map?)?['randomData'] as bool?) ?? true,
        inMemoryData:
            ((json['config'] as Map?)?['inMemoryData'] as bool?) ?? false,
        objectCount:
            (((json['config'] as Map?)?['objectCount'] as num?)?.toInt()) ?? 0,
        connectTimeoutSeconds:
            (((json['config'] as Map?)?['connectTimeoutSeconds'] as num?)
                    ?.toInt()) ??
                5,
        readTimeoutSeconds:
            (((json['config'] as Map?)?['readTimeoutSeconds'] as num?)
                    ?.toInt()) ??
                60,
        maxAttempts:
            (((json['config'] as Map?)?['maxAttempts'] as num?)?.toInt()) ?? 5,
        maxPoolConnections:
            (((json['config'] as Map?)?['maxPoolConnections'] as num?)
                    ?.toInt()) ??
                200,
        dataCacheMb:
            (((json['config'] as Map?)?['dataCacheMb'] as num?)?.toInt()) ?? 0,
        csvOutputPath:
            ((json['config'] as Map?)?['csvOutputPath'] as String?) ??
                'results.csv',
        jsonOutputPath:
            ((json['config'] as Map?)?['jsonOutputPath'] as String?) ??
                'results.json',
        logFilePath: ((json['config'] as Map?)?['logFilePath'] as String?) ??
            'benchmark.log',
        debugMode: ((json['config'] as Map?)?['debugMode'] as bool?) ?? false,
        readPercent:
            (((json['config'] as Map?)?['readPercent'] as num?)?.toInt()) ?? 34,
        writePercent:
            (((json['config'] as Map?)?['writePercent'] as num?)?.toInt()) ??
                33,
        deletePercent:
            (((json['config'] as Map?)?['deletePercent'] as num?)?.toInt()) ??
                33,
        reducedLogging:
            ((json['config'] as Map?)?['reducedLogging'] as bool?) ?? false,
      ),
      status: (json['status'] as String?) ?? 'unknown',
      processedCount: (json['processedCount'] as num?)?.toInt() ?? 0,
      startedAt: DateTime.tryParse((json['startedAt'] as String?) ?? '') ??
          DateTime.fromMillisecondsSinceEpoch(0),
      completedAt: json['completedAt'] == null
          ? null
          : DateTime.tryParse(json['completedAt'] as String),
      averageLatencyMs: (json['averageLatencyMs'] as num?)?.toDouble() ?? 0,
      throughputOpsPerSecond:
          (json['throughputOpsPerSecond'] as num?)?.toDouble() ?? 0,
      liveLog: (json['liveLog'] as List<Object?>? ?? const [])
          .map((item) => item.toString())
          .toList(),
      activeElapsedSeconds: (json['activeElapsedSeconds'] as num?)?.toDouble(),
      resultSummary: json['resultSummary'] == null
          ? null
          : _benchmarkResultSummaryFromJson(
              Map<String, Object?>.from(json['resultSummary'] as Map),
            ),
    );
  }

  static BenchmarkResultSummary _benchmarkResultSummaryFromJson(
    Map<String, Object?> json,
  ) {
    return BenchmarkResultSummary(
      totalOperations: (json['totalOperations'] as num?)?.toInt() ?? 0,
      operationsByType: Map<String, int>.from(
        (json['operationsByType'] as Map?)?.map(
              (key, value) => MapEntry(key.toString(), (value as num).toInt()),
            ) ??
            const <String, int>{},
      ),
      latencyPercentilesMs: Map<String, double>.from(
        (json['latencyPercentilesMs'] as Map?)?.map(
              (key, value) =>
                  MapEntry(key.toString(), (value as num).toDouble()),
            ) ??
            const <String, double>{},
      ),
      throughputSeries: (json['throughputSeries'] as List<Object?>? ?? const [])
          .map((item) => Map<String, Object?>.from(item as Map))
          .toList(),
      sizeLatencyBuckets:
          (json['sizeLatencyBuckets'] as List<Object?>? ?? const [])
              .map((item) => Map<String, Object?>.from(item as Map))
              .toList(),
      checksumStats: Map<String, int>.from(
        (json['checksumStats'] as Map?)?.map(
              (key, value) => MapEntry(key.toString(), (value as num).toInt()),
            ) ??
            const <String, int>{},
      ),
      detailMetrics: Map<String, Object?>.from(
        (json['detailMetrics'] as Map?)?.map(
              (key, value) => MapEntry(key.toString(), value),
            ) ??
            const <String, Object?>{},
      ),
      latencyPercentilesByOperationMs: Map<String, Map<String, double>>.from(
        (json['latencyPercentilesByOperationMs'] as Map?)?.map(
              (operation, value) => MapEntry(
                operation.toString(),
                Map<String, double>.from(
                  (value as Map?)?.map(
                        (percentile, latency) => MapEntry(
                          percentile.toString(),
                          (latency as num).toDouble(),
                        ),
                      ) ??
                      const <String, double>{},
                ),
              ),
            ) ??
            const <String, Map<String, double>>{},
      ),
      operationDetails: (json['operationDetails'] as List<Object?>? ?? const [])
          .map((item) => Map<String, Object?>.from(item as Map))
          .toList(),
      latencyTimeline: (json['latencyTimeline'] as List<Object?>? ?? const [])
          .map((item) => Map<String, Object?>.from(item as Map))
          .toList(),
    );
  }

  static BenchmarkExportBundle _benchmarkExportBundleFromJson(
    Map<String, Object?> json,
  ) {
    return BenchmarkExportBundle(
      format: (json['format'] as String?) ?? 'csv',
      path: (json['path'] as String?) ?? '',
      summary: json['summary'] == null
          ? null
          : _benchmarkResultSummaryFromJson(
              Map<String, Object?>.from(json['summary'] as Map),
            ),
    );
  }

  static ErrorCode _parseErrorCode(String? value) {
    return switch (value) {
      'auth_failed' => ErrorCode.authFailed,
      'tls_error' => ErrorCode.tlsError,
      'timeout' => ErrorCode.timeout,
      'throttled' => ErrorCode.throttled,
      'unsupported_feature' => ErrorCode.unsupportedFeature,
      'invalid_config' => ErrorCode.invalidConfig,
      'object_conflict' => ErrorCode.objectConflict,
      'partial_batch_failure' => ErrorCode.partialBatchFailure,
      'engine_unavailable' => ErrorCode.engineUnavailable,
      _ => ErrorCode.unknown,
    };
  }
}

class _EngineManifestEntry {
  const _EngineManifestEntry({
    required this.id,
    required this.version,
    required this.executable,
    required this.arguments,
    this.workingDirectory,
  });

  final String id;
  final String version;
  final String executable;
  final List<String> arguments;
  final String? workingDirectory;

  factory _EngineManifestEntry.fromJson(Map<String, Object?> json) {
    return _EngineManifestEntry(
      id: json['id'] as String? ?? '',
      version: json['version'] as String? ?? '2.0.17',
      executable: json['executable'] as String? ?? '',
      arguments: (json['arguments'] as List<Object?>? ?? const [])
          .map((item) => item.toString())
          .toList(),
      workingDirectory: json['workingDirectory'] as String?,
    );
  }
}
