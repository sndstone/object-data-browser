import 'dart:async';
import 'dart:convert';

import 'package:flutter/services.dart';

import '../models/domain_models.dart';
import 'engine_service.dart';
import 'mock_engine_service.dart';

class AndroidEngineService
    implements
        EngineService,
        EngineLogSinkRegistrant,
        TransferJobSinkRegistrant {
  AndroidEngineService({
    MethodChannel? channel,
    EngineService? fallback,
  })  : _channel = channel ??
            const MethodChannel('s3_browser_crossplat/android_engine'),
        _fallback = fallback ?? MockEngineService();

  final MethodChannel _channel;
  final EngineService _fallback;

  DiagnosticsOptions _diagnosticsOptions = const DiagnosticsOptions(
    enableApiLogging: false,
    enableDebugLogging: false,
  );
  EngineLogCallback? _logSink;

  @override
  void configureDiagnostics(DiagnosticsOptions options) {
    _diagnosticsOptions = options;
    _fallback.configureDiagnostics(options);
  }

  @override
  bool get isMock => false;

  @override
  void shutdown() {
    _fallback.shutdown();
  }

  @override
  void setLogSink(EngineLogCallback? sink) {
    _logSink = sink;
  }

  @override
  void setTransferSink(TransferJobCallback? sink) {
    if (_fallback is TransferJobSinkRegistrant) {
      (_fallback as TransferJobSinkRegistrant).setTransferSink(sink);
    }
  }

  @override
  Future<List<EngineDescriptor>> listEngines() async {
    try {
      final items =
          await _channel.invokeListMethod<Map<dynamic, dynamic>>('listEngines');
      if (items == null || items.isEmpty) {
        return _fallback.listEngines();
      }
      return items.map((entry) {
        final value = Map<String, Object?>.from(entry.cast<String, Object?>());
        return EngineDescriptor(
          id: value['id'] as String? ?? 'android',
          label: value['label'] as String? ?? 'Android Engine',
          language: value['language'] as String? ?? 'native',
          version: value['version'] as String? ?? '2.2.2',
          available: value['available'] as bool? ?? true,
          desktopSupported: false,
          androidSupported: true,
        );
      }).toList(growable: false);
    } on PlatformException {
      return _fallback.listEngines();
    } on MissingPluginException {
      return _fallback.listEngines();
    }
  }

  @override
  Future<List<CapabilityDescriptor>> getCapabilities({
    required String engineId,
    required EndpointProfile profile,
  }) async {
    final result = await _dispatch(
      engineId: engineId,
      method: 'getCapabilities',
      params: {'profile': _profileToJson(profile)},
    );
    final items = (result['items'] as List<Object?>? ?? const <Object?>[]);
    return items.map((item) {
      final value = Map<String, Object?>.from(item as Map);
      return CapabilityDescriptor(
        key: value['key'] as String? ?? '',
        label: value['label'] as String? ?? '',
        state: switch (value['state']) {
          'supported' => CapabilityState.supported,
          'unsupported' => CapabilityState.unsupported,
          _ => CapabilityState.unknown,
        },
        reason: value['reason'] as String?,
      );
    }).toList(growable: false);
  }

  @override
  Future<void> testProfile({
    required String engineId,
    required EndpointProfile profile,
  }) async {
    await _dispatch(
      engineId: engineId,
      method: 'testProfile',
      params: {'profile': _profileToJson(profile)},
    );
  }

  @override
  Future<List<BucketSummary>> listBuckets({
    required String engineId,
    required EndpointProfile profile,
  }) async {
    final result = await _dispatch(
      engineId: engineId,
      method: 'listBuckets',
      params: {'profile': _profileToJson(profile)},
    );
    final items = (result['items'] as List<Object?>? ?? const <Object?>[]);
    return items
        .map(
          (item) => _bucketFromJson(Map<String, Object?>.from(item as Map)),
        )
        .toList(growable: false);
  }

  @override
  Future<BucketSummary> createBucket({
    required String engineId,
    required EndpointProfile profile,
    required String bucketName,
    required bool enableVersioning,
    required bool enableObjectLock,
  }) async {
    final result = await _dispatch(
      engineId: engineId,
      method: 'createBucket',
      params: {
        'profile': _profileToJson(profile),
        'bucketName': bucketName,
        'enableVersioning': enableVersioning,
        'enableObjectLock': enableObjectLock,
      },
    );
    return _bucketFromJson(result);
  }

  @override
  Future<void> deleteBucket({
    required String engineId,
    required EndpointProfile profile,
    required String bucketName,
  }) async {
    await _dispatch(
      engineId: engineId,
      method: 'deleteBucket',
      params: {
        'profile': _profileToJson(profile),
        'bucketName': bucketName,
      },
    );
  }

  @override
  Future<BucketAdminState> getBucketAdminState({
    required String engineId,
    required EndpointProfile profile,
    required String bucketName,
  }) async {
    final result = await _dispatch(
      engineId: engineId,
      method: 'getBucketAdminState',
      params: {
        'profile': _profileToJson(profile),
        'bucketName': bucketName,
      },
    );
    return _bucketAdminStateFromJson(result);
  }

  @override
  Future<BucketAdminState> setBucketVersioning({
    required String engineId,
    required EndpointProfile profile,
    required String bucketName,
    required bool enabled,
  }) async {
    final result = await _dispatch(
      engineId: engineId,
      method: 'setBucketVersioning',
      params: {
        'profile': _profileToJson(profile),
        'bucketName': bucketName,
        'enabled': enabled,
      },
    );
    return _bucketAdminStateFromJson(result);
  }

  @override
  Future<BucketAdminState> putBucketLifecycle({
    required String engineId,
    required EndpointProfile profile,
    required String bucketName,
    required String lifecycleJson,
  }) async {
    final result = await _dispatch(
      engineId: engineId,
      method: 'putBucketLifecycle',
      params: {
        'profile': _profileToJson(profile),
        'bucketName': bucketName,
        'lifecycleJson': lifecycleJson,
      },
    );
    return _bucketAdminStateFromJson(result);
  }

  @override
  Future<BucketAdminState> deleteBucketLifecycle({
    required String engineId,
    required EndpointProfile profile,
    required String bucketName,
  }) async {
    final result = await _dispatch(
      engineId: engineId,
      method: 'deleteBucketLifecycle',
      params: {
        'profile': _profileToJson(profile),
        'bucketName': bucketName,
      },
    );
    return _bucketAdminStateFromJson(result);
  }

  @override
  Future<BucketAdminState> putBucketPolicy({
    required String engineId,
    required EndpointProfile profile,
    required String bucketName,
    required String policyJson,
  }) async {
    final result = await _dispatch(
      engineId: engineId,
      method: 'putBucketPolicy',
      params: {
        'profile': _profileToJson(profile),
        'bucketName': bucketName,
        'policyJson': policyJson,
      },
    );
    return _bucketAdminStateFromJson(result);
  }

  @override
  Future<BucketAdminState> deleteBucketPolicy({
    required String engineId,
    required EndpointProfile profile,
    required String bucketName,
  }) async {
    final result = await _dispatch(
      engineId: engineId,
      method: 'deleteBucketPolicy',
      params: {
        'profile': _profileToJson(profile),
        'bucketName': bucketName,
      },
    );
    return _bucketAdminStateFromJson(result);
  }

  @override
  Future<BucketAdminState> putBucketCors({
    required String engineId,
    required EndpointProfile profile,
    required String bucketName,
    required String corsJson,
  }) async {
    final result = await _dispatch(
      engineId: engineId,
      method: 'putBucketCors',
      params: {
        'profile': _profileToJson(profile),
        'bucketName': bucketName,
        'corsJson': corsJson,
      },
    );
    return _bucketAdminStateFromJson(result);
  }

  @override
  Future<BucketAdminState> deleteBucketCors({
    required String engineId,
    required EndpointProfile profile,
    required String bucketName,
  }) async {
    final result = await _dispatch(
      engineId: engineId,
      method: 'deleteBucketCors',
      params: {
        'profile': _profileToJson(profile),
        'bucketName': bucketName,
      },
    );
    return _bucketAdminStateFromJson(result);
  }

  @override
  Future<BucketAdminState> putBucketEncryption({
    required String engineId,
    required EndpointProfile profile,
    required String bucketName,
    required String encryptionJson,
  }) async {
    final result = await _dispatch(
      engineId: engineId,
      method: 'putBucketEncryption',
      params: {
        'profile': _profileToJson(profile),
        'bucketName': bucketName,
        'encryptionJson': encryptionJson,
      },
    );
    return _bucketAdminStateFromJson(result);
  }

  @override
  Future<BucketAdminState> deleteBucketEncryption({
    required String engineId,
    required EndpointProfile profile,
    required String bucketName,
  }) async {
    final result = await _dispatch(
      engineId: engineId,
      method: 'deleteBucketEncryption',
      params: {
        'profile': _profileToJson(profile),
        'bucketName': bucketName,
      },
    );
    return _bucketAdminStateFromJson(result);
  }

  @override
  Future<BucketAdminState> putBucketTagging({
    required String engineId,
    required EndpointProfile profile,
    required String bucketName,
    required Map<String, String> tags,
  }) async {
    final result = await _dispatch(
      engineId: engineId,
      method: 'putBucketTagging',
      params: {
        'profile': _profileToJson(profile),
        'bucketName': bucketName,
        'tags': tags,
      },
    );
    return _bucketAdminStateFromJson(result);
  }

  @override
  Future<BucketAdminState> deleteBucketTagging({
    required String engineId,
    required EndpointProfile profile,
    required String bucketName,
  }) async {
    final result = await _dispatch(
      engineId: engineId,
      method: 'deleteBucketTagging',
      params: {
        'profile': _profileToJson(profile),
        'bucketName': bucketName,
      },
    );
    return _bucketAdminStateFromJson(result);
  }

  @override
  Future<ObjectListResult> listObjects({
    required String engineId,
    required EndpointProfile profile,
    required String bucketName,
    required String prefix,
    required bool flat,
    ListCursor? cursor,
  }) async {
    final result = await _dispatch(
      engineId: engineId,
      method: 'listObjects',
      params: {
        'profile': _profileToJson(profile),
        'bucketName': bucketName,
        'prefix': prefix,
        'flat': flat,
        if (cursor != null)
          'cursor': {
            'value': cursor.value,
            'hasMore': cursor.hasMore,
          },
      },
    );
    return _objectListResultFromJson(result);
  }

  @override
  Future<ObjectVersionListResult> listObjectVersions({
    required String engineId,
    required EndpointProfile profile,
    required String bucketName,
    String? key,
    VersionBrowserOptions? options,
    ListCursor? cursor,
  }) async {
    final result = await _dispatch(
      engineId: engineId,
      method: 'listObjectVersions',
      params: {
        'profile': _profileToJson(profile),
        'bucketName': bucketName,
        if (key != null) 'key': key,
        if (options != null)
          'options': {
            'filterValue': options.filterValue,
            'filterMode': options.filterMode.name,
            'showVersions': options.showVersions,
            'showDeleteMarkers': options.showDeleteMarkers,
          },
        if (cursor != null)
          'cursor': {
            'value': cursor.value,
            'hasMore': cursor.hasMore,
          },
      },
    );
    return _objectVersionListResultFromJson(result);
  }

  @override
  Future<ObjectDetails> getObjectDetails({
    required String engineId,
    required EndpointProfile profile,
    required String bucketName,
    required String key,
  }) async {
    final result = await _dispatch(
      engineId: engineId,
      method: 'getObjectDetails',
      params: {
        'profile': _profileToJson(profile),
        'bucketName': bucketName,
        'key': key,
      },
    );
    return _objectDetailsFromJson(result);
  }

  @override
  Future<void> createFolder({
    required String engineId,
    required EndpointProfile profile,
    required String bucketName,
    required String key,
  }) async {
    await _dispatch(
      engineId: engineId,
      method: 'createFolder',
      params: {
        'profile': _profileToJson(profile),
        'bucketName': bucketName,
        'key': key,
      },
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
  }) async {
    final result = await _dispatch(
      engineId: engineId,
      method: 'copyObject',
      params: {
        'profile': _profileToJson(profile),
        'sourceBucketName': sourceBucketName,
        'sourceKey': sourceKey,
        'destinationBucketName': destinationBucketName,
        'destinationKey': destinationKey,
      },
    );
    return _batchOperationResultFromJson(result);
  }

  @override
  Future<BatchOperationResult> moveObject({
    required String engineId,
    required EndpointProfile profile,
    required String sourceBucketName,
    required String sourceKey,
    required String destinationBucketName,
    required String destinationKey,
  }) async {
    final result = await _dispatch(
      engineId: engineId,
      method: 'moveObject',
      params: {
        'profile': _profileToJson(profile),
        'sourceBucketName': sourceBucketName,
        'sourceKey': sourceKey,
        'destinationBucketName': destinationBucketName,
        'destinationKey': destinationKey,
      },
    );
    return _batchOperationResultFromJson(result);
  }

  @override
  Future<BatchOperationResult> deleteObjects({
    required String engineId,
    required EndpointProfile profile,
    required String bucketName,
    required List<String> keys,
  }) async {
    final result = await _dispatch(
      engineId: engineId,
      method: 'deleteObjects',
      params: {
        'profile': _profileToJson(profile),
        'bucketName': bucketName,
        'keys': keys,
      },
    );
    return _batchOperationResultFromJson(result);
  }

  @override
  Future<BatchOperationResult> deleteObjectVersions({
    required String engineId,
    required EndpointProfile profile,
    required String bucketName,
    required List<ObjectVersionRef> versions,
  }) async {
    final result = await _dispatch(
      engineId: engineId,
      method: 'deleteObjectVersions',
      params: {
        'profile': _profileToJson(profile),
        'bucketName': bucketName,
        'versions': versions
            .map((version) => {
                  'key': version.key,
                  'versionId': version.versionId,
                })
            .toList(growable: false),
      },
    );
    return _batchOperationResultFromJson(result);
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
  }) async {
    final result = await _dispatch(
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
    );
    return _transferJobFromJson(result);
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
  }) async {
    final result = await _dispatch(
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
    );
    return _transferJobFromJson(result);
  }

  @override
  Future<TransferJob> pauseTransfer({
    required String engineId,
    required String jobId,
  }) async {
    final result = await _dispatch(
      engineId: engineId,
      method: 'pauseTransfer',
      params: {'jobId': jobId},
    );
    return _transferJobFromJson(result);
  }

  @override
  Future<TransferJob> resumeTransfer({
    required String engineId,
    required String jobId,
  }) async {
    final result = await _dispatch(
      engineId: engineId,
      method: 'resumeTransfer',
      params: {'jobId': jobId},
    );
    return _transferJobFromJson(result);
  }

  @override
  Future<TransferJob> cancelTransfer({
    required String engineId,
    required String jobId,
  }) async {
    final result = await _dispatch(
      engineId: engineId,
      method: 'cancelTransfer',
      params: {'jobId': jobId},
    );
    return _transferJobFromJson(result);
  }

  @override
  Future<String> generatePresignedUrl({
    required String engineId,
    required EndpointProfile profile,
    required String bucketName,
    required String key,
    required Duration expiration,
  }) async {
    final result = await _dispatch(
      engineId: engineId,
      method: 'generatePresignedUrl',
      params: {
        'profile': _profileToJson(profile),
        'bucketName': bucketName,
        'key': key,
        'expirationSeconds': expiration.inSeconds,
      },
    );
    return result['url'] as String? ?? '';
  }

  @override
  Future<ToolExecutionState> runPutTestData({
    required String engineId,
    required EndpointProfile profile,
    required TestDataToolConfig config,
  }) async {
    final result = await _dispatch(
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
    );
    return _toolExecutionStateFromJson(result);
  }

  @override
  Future<ToolExecutionState> runDeleteAll({
    required String engineId,
    required EndpointProfile profile,
    required DeleteAllToolConfig config,
  }) async {
    final result = await _dispatch(
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
    );
    return _toolExecutionStateFromJson(result);
  }

  @override
  Future<ToolExecutionState> cancelToolExecution({
    required String engineId,
    required String jobId,
  }) async {
    final result = await _dispatch(
      engineId: engineId,
      method: 'cancelToolExecution',
      params: {'jobId': jobId},
    );
    return _toolExecutionStateFromJson(result);
  }

  @override
  Future<BenchmarkRun> startBenchmark({
    required BenchmarkConfig config,
    required EndpointProfile profile,
  }) async {
    final result = await _dispatch(
      engineId: config.engineId,
      method: 'startBenchmark',
      params: {
        'profile': _profileToJson(profile),
        'config': {
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
        },
      },
    );
    return _benchmarkRunFromJson(result);
  }

  @override
  Future<BenchmarkRun> getBenchmarkStatus(String runId) async {
    final result = await _dispatch(
      engineId: 'android',
      method: 'getBenchmarkStatus',
      params: {'runId': runId},
    );
    return _benchmarkRunFromJson(result);
  }

  @override
  Future<void> pauseBenchmark(String runId) async {
    await _dispatch(
      engineId: 'android',
      method: 'pauseBenchmark',
      params: {'runId': runId},
    );
  }

  @override
  Future<void> resumeBenchmark(String runId) async {
    await _dispatch(
      engineId: 'android',
      method: 'resumeBenchmark',
      params: {'runId': runId},
    );
  }

  @override
  Future<void> stopBenchmark(String runId) async {
    await _dispatch(
      engineId: 'android',
      method: 'stopBenchmark',
      params: {'runId': runId},
    );
  }

  @override
  Future<BenchmarkExportBundle> exportBenchmarkResults({
    required String runId,
    required String format,
  }) async {
    final result = await _dispatch(
      engineId: 'android',
      method: 'exportBenchmarkResults',
      params: {
        'runId': runId,
        'format': format,
      },
    );
    return _benchmarkExportBundleFromJson(result);
  }

  Future<Map<String, Object?>> _dispatch({
    required String engineId,
    required String method,
    required Map<String, Object?> params,
  }) async {
    final requestId =
        'android-${DateTime.now().microsecondsSinceEpoch}-$method-$engineId';
    final startedAt = DateTime.now();
    // Building sanitized trace bodies + jsonEncode is expensive; only do it
    // when API logging is enabled (the app drops API events otherwise).
    final apiLoggingEnabled = _diagnosticsOptions.enableApiLogging;

    _emitLog(
      level: 'DEBUG',
      category: 'EngineDispatch',
      message: 'Dispatching $method via Android adapter for engine $engineId.',
      source: 'debug',
      params: params,
      requestId: requestId,
      engineId: engineId,
      method: method,
    );

    if (apiLoggingEnabled) {
      final requestHead = {
        'engineId': engineId,
        'method': method,
      };
      final requestBody = _sanitizeForLogging(params);
      _emitLog(
        level: 'API',
        category: 'HttpSend',
        message: _stringifyForLogging({
          'engineId': engineId,
          'method': method,
          'params': requestBody,
        }),
        source: 'api',
        params: params,
        requestId: requestId,
        tracePhase: 'send',
        engineId: engineId,
        method: method,
        traceHead: requestHead,
        traceBody: requestBody,
      );
    }

    try {
      final result = await _channel.invokeMethod<Object?>(
        'dispatch',
        <String, Object?>{
          'engineId': engineId,
          'method': method,
          'params': params,
        },
      );
      final payload = _stringKeyedMap(result);
      final latencyMs = DateTime.now().difference(startedAt).inMilliseconds;

      if (apiLoggingEnabled) {
        final responseHead = {
          'engineId': engineId,
          'method': method,
          'status': payload.containsKey('error') ? 'error' : 'ok',
        };
        final responseBody = _sanitizeForLogging(payload);
        _emitLog(
          level: 'API',
          category: 'HttpReceive',
          message: _stringifyForLogging(payload),
          source: 'api',
          params: params,
          requestId: requestId,
          tracePhase: 'response',
          engineId: engineId,
          method: method,
          responseStatus: payload.containsKey('error') ? 'error' : 'ok',
          latencyMs: latencyMs,
          traceHead: responseHead,
          traceBody: responseBody,
        );
      }

      _emitLog(
        level: 'DEBUG',
        category: 'EngineDispatch',
        message:
            'Android adapter completed $method via $engineId in ${latencyMs}ms.',
        source: 'debug',
        params: params,
        requestId: requestId,
        engineId: engineId,
        method: method,
        responseStatus: payload.containsKey('error') ? 'error' : 'ok',
        latencyMs: latencyMs,
      );

      final error = payload['error'];
      if (error != null) {
        // Any non-null error value is a failure. Structured (Map) errors carry
        // a code/message/details; a non-Map value is coerced to a message with
        // an unknown code so it can never be swallowed as success.
        if (error is Map) {
          final mappedError = _stringKeyedMap(error);
          throw EngineException(
            code: _parseErrorCode(mappedError['code'] as String?),
            message:
                (mappedError['message'] as String?) ?? 'Unknown engine error.',
            details: mappedError['details'] is Map
                ? _stringKeyedMap(mappedError['details'])
                : null,
          );
        }
        throw EngineException(
          code: ErrorCode.unknown,
          message: error.toString(),
        );
      }

      return payload;
    } on MissingPluginException {
      return _missingPluginFallback(
        engineId: engineId,
        method: method,
        params: params,
      );
    } on PlatformException catch (error) {
      final latencyMs = DateTime.now().difference(startedAt).inMilliseconds;
      _emitLog(
        level: 'ERROR',
        category: 'PlatformChannel',
        message: error.message ?? error.code,
        source: 'engine-error',
        params: params,
        requestId: requestId,
        tracePhase: 'response',
        engineId: engineId,
        method: method,
        responseStatus: error.code,
        latencyMs: latencyMs,
      );
      throw EngineException(
        code: _parseErrorCode(error.code),
        message: error.message ?? 'Android engine bridge failed.',
        details: error.details is Map ? _stringKeyedMap(error.details) : null,
      );
    }
  }

  static Map<String, Object?> _stringKeyedMap(Object? value) {
    if (value is! Map) {
      return <String, Object?>{};
    }
    return value.map(
      (key, mapValue) =>
          MapEntry(key.toString(), _normalizeChannelValue(mapValue)),
    );
  }

  static Object? _normalizeChannelValue(Object? value) {
    if (value is Map) {
      return _stringKeyedMap(value);
    }
    if (value is List) {
      return value.map(_normalizeChannelValue).toList(growable: false);
    }
    return value;
  }

  Future<Map<String, Object?>> _missingPluginFallback({
    required String engineId,
    required String method,
    required Map<String, Object?> params,
  }) async {
    switch (method) {
      case 'getCapabilities':
        final profile = EndpointProfile.fromJson(
          Map<String, Object?>.from(params['profile'] as Map),
        );
        final items = await _fallback.getCapabilities(
          engineId: engineId,
          profile: profile,
        );
        return {
          'items': items
              .map(
                (item) => {
                  'key': item.key,
                  'label': item.label,
                  'state': item.state.name,
                  'reason': item.reason,
                },
              )
              .toList(growable: false),
        };
      default:
        throw const EngineException(
          code: ErrorCode.engineUnavailable,
          message: 'Android engine plugin is unavailable.',
        );
    }
  }

  void _emitLog({
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
    if (level == 'API' && !_diagnosticsOptions.enableApiLogging) {
      return;
    }
    if (level == 'DEBUG' && !_diagnosticsOptions.enableDebugLogging) {
      return;
    }
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
      return value.map(_sanitizeForLogging).toList(growable: false);
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

  static Map<String, Object?> _profileToJson(EndpointProfile profile) {
    return profile.toJson();
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
    Map<String, Object?> json,
  ) {
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
      format: (json['format'] as String?) ?? 'json',
      path: (json['path'] as String?) ?? '',
      summary: json['summary'] == null
          ? null
          : _benchmarkResultSummaryFromJson(
              Map<String, Object?>.from(json['summary'] as Map),
            ),
    );
  }

  static ErrorCode _parseErrorCode(String? code) {
    return switch (code) {
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
