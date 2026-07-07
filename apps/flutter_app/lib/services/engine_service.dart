import '../models/domain_models.dart';

typedef EngineLogCallback = void Function(EngineLogRecord entry);
typedef TransferJobCallback = void Function(TransferJob job);

class DiagnosticsOptions {
  const DiagnosticsOptions({
    required this.enableApiLogging,
    required this.enableDebugLogging,
  });

  final bool enableApiLogging;
  final bool enableDebugLogging;

  Map<String, Object?> toJson() {
    return {
      'enableApiLogging': enableApiLogging,
      'enableDebugLogging': enableDebugLogging,
    };
  }
}

class EngineLogRecord {
  const EngineLogRecord({
    required this.level,
    required this.category,
    required this.message,
    this.profileId,
    this.bucketName,
    this.objectKey,
    this.source,
    this.requestId,
    this.tracePhase,
    this.engineId,
    this.method,
    this.responseStatus,
    this.latencyMs,
    this.traceHead,
    this.traceBody,
  });

  final String level;
  final String category;
  final String message;
  final String? profileId;
  final String? bucketName;
  final String? objectKey;
  final String? source;
  final String? requestId;
  final String? tracePhase;
  final String? engineId;
  final String? method;
  final String? responseStatus;
  final int? latencyMs;
  final Object? traceHead;
  final Object? traceBody;
}

abstract interface class EngineLogSinkRegistrant {
  void setLogSink(EngineLogCallback? sink);
}

abstract interface class TransferJobSinkRegistrant {
  void setTransferSink(TransferJobCallback? sink);
}

abstract class EngineService {
  void configureDiagnostics(DiagnosticsOptions options) {}

  /// Whether this is the in-process mock service (no real backend wired).
  bool get isMock => false;

  /// Releases long-lived engine resources (e.g. desktop sidecar processes).
  /// Safe to call multiple times; the default implementation is a no-op.
  void shutdown() {}

  Future<List<EngineDescriptor>> listEngines();
  Future<List<CapabilityDescriptor>> getCapabilities({
    required String engineId,
    required EndpointProfile profile,
  });
  Future<void> testProfile({
    required String engineId,
    required EndpointProfile profile,
  });
  Future<List<BucketSummary>> listBuckets({
    required String engineId,
    required EndpointProfile profile,
  });
  Future<BucketSummary> createBucket({
    required String engineId,
    required EndpointProfile profile,
    required String bucketName,
    required bool enableVersioning,
    required bool enableObjectLock,
  });
  Future<void> deleteBucket({
    required String engineId,
    required EndpointProfile profile,
    required String bucketName,
  });
  Future<BucketAdminState> getBucketAdminState({
    required String engineId,
    required EndpointProfile profile,
    required String bucketName,
  });
  Future<BucketAdminState> setBucketVersioning({
    required String engineId,
    required EndpointProfile profile,
    required String bucketName,
    required bool enabled,
  });
  Future<BucketAdminState> putBucketLifecycle({
    required String engineId,
    required EndpointProfile profile,
    required String bucketName,
    required String lifecycleJson,
  });
  Future<BucketAdminState> deleteBucketLifecycle({
    required String engineId,
    required EndpointProfile profile,
    required String bucketName,
  });
  Future<BucketAdminState> putBucketPolicy({
    required String engineId,
    required EndpointProfile profile,
    required String bucketName,
    required String policyJson,
  });
  Future<BucketAdminState> deleteBucketPolicy({
    required String engineId,
    required EndpointProfile profile,
    required String bucketName,
  });
  Future<BucketAdminState> putBucketCors({
    required String engineId,
    required EndpointProfile profile,
    required String bucketName,
    required String corsJson,
  });
  Future<BucketAdminState> deleteBucketCors({
    required String engineId,
    required EndpointProfile profile,
    required String bucketName,
  });
  Future<BucketAdminState> putBucketEncryption({
    required String engineId,
    required EndpointProfile profile,
    required String bucketName,
    required String encryptionJson,
  });
  Future<BucketAdminState> deleteBucketEncryption({
    required String engineId,
    required EndpointProfile profile,
    required String bucketName,
  });
  Future<BucketAdminState> putBucketTagging({
    required String engineId,
    required EndpointProfile profile,
    required String bucketName,
    required Map<String, String> tags,
  });
  Future<BucketAdminState> deleteBucketTagging({
    required String engineId,
    required EndpointProfile profile,
    required String bucketName,
  });
  Future<ObjectListResult> listObjects({
    required String engineId,
    required EndpointProfile profile,
    required String bucketName,
    required String prefix,
    required bool flat,
    ListCursor? cursor,
  });
  Future<ObjectVersionListResult> listObjectVersions({
    required String engineId,
    required EndpointProfile profile,
    required String bucketName,
    String? key,
    VersionBrowserOptions? options,
    ListCursor? cursor,
  });
  Future<ObjectDetails> getObjectDetails({
    required String engineId,
    required EndpointProfile profile,
    required String bucketName,
    required String key,
  });
  Future<void> createFolder({
    required String engineId,
    required EndpointProfile profile,
    required String bucketName,
    required String key,
  });
  Future<BatchOperationResult> copyObject({
    required String engineId,
    required EndpointProfile profile,
    required String sourceBucketName,
    required String sourceKey,
    required String destinationBucketName,
    required String destinationKey,
  });
  Future<BatchOperationResult> moveObject({
    required String engineId,
    required EndpointProfile profile,
    required String sourceBucketName,
    required String sourceKey,
    required String destinationBucketName,
    required String destinationKey,
  });
  Future<BatchOperationResult> deleteObjects({
    required String engineId,
    required EndpointProfile profile,
    required String bucketName,
    required List<String> keys,
  });
  Future<BatchOperationResult> deleteObjectVersions({
    required String engineId,
    required EndpointProfile profile,
    required String bucketName,
    required List<ObjectVersionRef> versions,
  });
  Future<TransferJob> startUpload({
    required String engineId,
    required EndpointProfile profile,
    required String bucketName,
    required String prefix,
    required List<String> filePaths,
    required Map<String, String> objectKeyByPath,
    required int multipartThresholdMiB,
    required int multipartChunkMiB,
  });
  Future<TransferJob> startDownload({
    required String engineId,
    required EndpointProfile profile,
    required String bucketName,
    required List<String> keys,
    required String destinationPath,
    required int multipartThresholdMiB,
    required int multipartChunkMiB,
  });
  Future<TransferJob> pauseTransfer({
    required String engineId,
    required String jobId,
  });
  Future<TransferJob> resumeTransfer({
    required String engineId,
    required String jobId,
  });
  Future<TransferJob> cancelTransfer({
    required String engineId,
    required String jobId,
  });
  Future<String> generatePresignedUrl({
    required String engineId,
    required EndpointProfile profile,
    required String bucketName,
    required String key,
    required Duration expiration,
  });
  Future<ToolExecutionState> runPutTestData({
    required String engineId,
    required EndpointProfile profile,
    required TestDataToolConfig config,
  });
  Future<ToolExecutionState> runDeleteAll({
    required String engineId,
    required EndpointProfile profile,
    required DeleteAllToolConfig config,
  });
  Future<ToolExecutionState> cancelToolExecution({
    required String engineId,
    required String jobId,
  });
  Future<BenchmarkRun> startBenchmark({
    required BenchmarkConfig config,
    required EndpointProfile profile,
  });
  Future<BenchmarkRun> getBenchmarkStatus(String runId);
  Future<void> pauseBenchmark(String runId);
  Future<void> resumeBenchmark(String runId);
  Future<void> stopBenchmark(String runId);
  Future<BenchmarkExportBundle> exportBenchmarkResults({
    required String runId,
    required String format,
  });
}
