enum WorkspaceTab {
  browser,
  benchmark,
  tasks,
  settings,
  eventLog,
}

enum ErrorCode {
  authFailed,
  tlsError,
  timeout,
  throttled,
  unsupportedFeature,
  invalidConfig,
  objectConflict,
  partialBatchFailure,
  engineUnavailable,
  unknown,
}

enum CapabilityState {
  supported,
  unsupported,
  unknown,
}

enum EndpointProfileType {
  s3Compatible,
  awsS3,
  azureBlob,
}

extension EndpointProfileTypeInfo on EndpointProfileType {
  bool get isAzure => this == EndpointProfileType.azureBlob;

  String get displayLabel => switch (this) {
        EndpointProfileType.s3Compatible => 'S3 compatible',
        EndpointProfileType.awsS3 => 'AWS S3',
        EndpointProfileType.azureBlob => 'Azure Blob Storage',
      };

  /// Label for the field stored in [EndpointProfile.accessKey].
  String get accessKeyLabel => switch (this) {
        EndpointProfileType.azureBlob => 'Storage account name',
        _ => 'Access key',
      };

  /// Label for the field stored in [EndpointProfile.secretKey].
  String get secretKeyLabel => switch (this) {
        EndpointProfileType.azureBlob => 'Account access key',
        _ => 'Secret key',
      };
}

enum BrowserInspectorTab {
  bucketAdmin,
  bucketInfo,
  objectDetails,
  versions,
  presign,
  tools,
  eventsAndDebug,
}

enum BrowserFilterMode {
  prefix,
  text,
  regex,
}

enum BrowserInspectorLayout {
  bottom,
  right,
}

enum ObjectPreviewKind {
  image,
  video,
  text,
  unsupported,
}

enum BrowserObjectSortField {
  lastModified,
  name,
  size,
  contentType,
}

enum BrowserTaskKind {
  action,
  transfer,
  tool,
  benchmark,
}

enum BrowserTaskView {
  running,
  failed,
  all,
}

class EventLogEntry {
  const EventLogEntry({
    required this.timestamp,
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

  final DateTime timestamp;
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

  Map<String, Object?> toJson() {
    return {
      'timestamp': timestamp.toIso8601String(),
      'level': level,
      'category': category,
      'message': message,
      'profileId': profileId,
      'bucketName': bucketName,
      'objectKey': objectKey,
      'source': source,
      'requestId': requestId,
      'tracePhase': tracePhase,
      'engineId': engineId,
      'method': method,
      'responseStatus': responseStatus,
      'latencyMs': latencyMs,
      'traceHead': traceHead,
      'traceBody': traceBody,
    };
  }
}

class EndpointProfile {
  const EndpointProfile({
    required this.id,
    required this.name,
    required this.endpointUrl,
    required this.region,
    required this.accessKey,
    required this.secretKey,
    required this.pathStyle,
    required this.verifyTls,
    this.endpointType = EndpointProfileType.s3Compatible,
    this.sessionToken,
    this.signerOverride,
    this.notes,
    this.connectTimeoutSeconds = 5,
    this.readTimeoutSeconds = 60,
    this.maxConcurrentRequests = 10,
    this.maxAttempts = 5,
    this.maxRequestsPerSecond = 0,
  });

  final String id;
  final String name;
  final String endpointUrl;
  final String region;
  final String accessKey;
  final String secretKey;
  final bool pathStyle;
  final bool verifyTls;
  final EndpointProfileType endpointType;
  final String? sessionToken;
  final String? signerOverride;
  final String? notes;
  final int connectTimeoutSeconds;
  final int readTimeoutSeconds;
  final int maxConcurrentRequests;
  final int maxAttempts;
  final int maxRequestsPerSecond;

  Map<String, Object?> toJson() {
    return {
      'id': id,
      'name': name,
      'endpointUrl': endpointUrl,
      'region': region,
      'accessKey': accessKey,
      'secretKey': secretKey,
      'sessionToken': sessionToken,
      'pathStyle': pathStyle,
      'verifyTls': verifyTls,
      'endpointType': endpointType.name,
      'signerOverride': signerOverride,
      'notes': notes,
      'connectTimeoutSeconds': connectTimeoutSeconds,
      'readTimeoutSeconds': readTimeoutSeconds,
      'maxConcurrentRequests': maxConcurrentRequests,
      'maxAttempts': maxAttempts,
      'maxRequestsPerSecond': maxRequestsPerSecond,
    };
  }

  factory EndpointProfile.fromJson(Map<String, Object?> json) {
    return EndpointProfile(
      id: (json['id'] as String?) ?? '',
      name: (json['name'] as String?) ?? '',
      endpointUrl: (json['endpointUrl'] as String?) ?? '',
      region: (json['region'] as String?) ?? '',
      accessKey: (json['accessKey'] as String?) ?? '',
      secretKey: (json['secretKey'] as String?) ?? '',
      sessionToken: json['sessionToken'] as String?,
      pathStyle: json['pathStyle'] as bool? ?? true,
      verifyTls: json['verifyTls'] as bool? ?? true,
      endpointType: switch (json['endpointType'] as String? ?? 's3Compatible') {
        'awsS3' => EndpointProfileType.awsS3,
        'azureBlob' => EndpointProfileType.azureBlob,
        _ => EndpointProfileType.s3Compatible,
      },
      signerOverride: json['signerOverride'] as String?,
      notes: json['notes'] as String?,
      connectTimeoutSeconds:
          (json['connectTimeoutSeconds'] as num?)?.toInt() ?? 5,
      readTimeoutSeconds: (json['readTimeoutSeconds'] as num?)?.toInt() ?? 60,
      maxConcurrentRequests:
          (json['maxConcurrentRequests'] as num?)?.toInt() ?? 10,
      maxAttempts: (json['maxAttempts'] as num?)?.toInt() ?? 5,
      maxRequestsPerSecond:
          (json['maxRequestsPerSecond'] as num?)?.toInt() ?? 0,
    );
  }

  EndpointProfile copyWith({
    String? name,
    String? endpointUrl,
    String? region,
    String? accessKey,
    String? secretKey,
    bool? pathStyle,
    bool? verifyTls,
    EndpointProfileType? endpointType,
    String? sessionToken,
    String? signerOverride,
    String? notes,
    int? connectTimeoutSeconds,
    int? readTimeoutSeconds,
    int? maxConcurrentRequests,
    int? maxAttempts,
    int? maxRequestsPerSecond,
  }) {
    return EndpointProfile(
      id: id,
      name: name ?? this.name,
      endpointUrl: endpointUrl ?? this.endpointUrl,
      region: region ?? this.region,
      accessKey: accessKey ?? this.accessKey,
      secretKey: secretKey ?? this.secretKey,
      pathStyle: pathStyle ?? this.pathStyle,
      verifyTls: verifyTls ?? this.verifyTls,
      endpointType: endpointType ?? this.endpointType,
      sessionToken: sessionToken ?? this.sessionToken,
      signerOverride: signerOverride ?? this.signerOverride,
      notes: notes ?? this.notes,
      connectTimeoutSeconds:
          connectTimeoutSeconds ?? this.connectTimeoutSeconds,
      readTimeoutSeconds: readTimeoutSeconds ?? this.readTimeoutSeconds,
      maxConcurrentRequests:
          maxConcurrentRequests ?? this.maxConcurrentRequests,
      maxAttempts: maxAttempts ?? this.maxAttempts,
      maxRequestsPerSecond: maxRequestsPerSecond ?? this.maxRequestsPerSecond,
    );
  }
}

class EngineDescriptor {
  const EngineDescriptor({
    required this.id,
    required this.label,
    required this.language,
    required this.version,
    required this.available,
    required this.desktopSupported,
    required this.androidSupported,
  });

  final String id;
  final String label;
  final String language;
  final String version;
  final bool available;
  final bool desktopSupported;
  final bool androidSupported;
}

class CapabilityDescriptor {
  const CapabilityDescriptor({
    required this.key,
    required this.label,
    required this.state,
    this.reason,
  });

  final String key;
  final String label;
  final CapabilityState state;
  final String? reason;
}

class BucketSummary {
  const BucketSummary({
    required this.name,
    required this.region,
    required this.objectCountHint,
    required this.versioningEnabled,
    this.createdAt,
  });

  final String name;
  final String region;
  final int objectCountHint;
  final bool versioningEnabled;
  final DateTime? createdAt;
}

class LifecycleRule {
  const LifecycleRule({
    required this.id,
    required this.enabled,
    required this.prefix,
    this.expirationDays,
    this.deleteExpiredObjectDeleteMarkers = false,
    this.transitionStorageClass,
    this.transitionDays,
    this.nonCurrentExpirationDays,
    this.nonCurrentTransitionStorageClass,
    this.nonCurrentTransitionDays,
    this.abortIncompleteMultipartUploadDays,
  });

  final String id;
  final bool enabled;
  final String prefix;
  final int? expirationDays;
  final bool deleteExpiredObjectDeleteMarkers;
  final String? transitionStorageClass;
  final int? transitionDays;
  final int? nonCurrentExpirationDays;
  final String? nonCurrentTransitionStorageClass;
  final int? nonCurrentTransitionDays;
  final int? abortIncompleteMultipartUploadDays;
}

class BucketAdminState {
  const BucketAdminState({
    required this.bucketName,
    required this.versioningEnabled,
    required this.versioningStatus,
    required this.objectLockEnabled,
    required this.lifecycleEnabled,
    required this.policyAttached,
    required this.corsEnabled,
    required this.encryptionEnabled,
    required this.encryptionSummary,
    required this.objectLockMode,
    required this.objectLockRetentionDays,
    required this.tags,
    required this.lifecycleRules,
    required this.policyJson,
    required this.corsJson,
    this.lifecycleJson = '{\n  "Rules": []\n}',
    this.encryptionJson = '{}',
    this.apiCalls = const [],
  });

  final String bucketName;
  final bool versioningEnabled;
  final String versioningStatus;
  final bool objectLockEnabled;
  final bool lifecycleEnabled;
  final bool policyAttached;
  final bool corsEnabled;
  final bool encryptionEnabled;
  final String encryptionSummary;
  final String? objectLockMode;
  final int? objectLockRetentionDays;
  final Map<String, String> tags;
  final List<LifecycleRule> lifecycleRules;
  final String policyJson;
  final String corsJson;
  final String lifecycleJson;
  final String encryptionJson;
  final List<ApiCallRecord> apiCalls;

  BucketAdminState copyWith({
    bool? versioningEnabled,
    String? versioningStatus,
    bool? objectLockEnabled,
    bool? lifecycleEnabled,
    bool? policyAttached,
    bool? corsEnabled,
    bool? encryptionEnabled,
    String? encryptionSummary,
    String? objectLockMode,
    int? objectLockRetentionDays,
    Map<String, String>? tags,
    List<LifecycleRule>? lifecycleRules,
    String? policyJson,
    String? corsJson,
    String? lifecycleJson,
    String? encryptionJson,
    List<ApiCallRecord>? apiCalls,
  }) {
    return BucketAdminState(
      bucketName: bucketName,
      versioningEnabled: versioningEnabled ?? this.versioningEnabled,
      versioningStatus: versioningStatus ?? this.versioningStatus,
      objectLockEnabled: objectLockEnabled ?? this.objectLockEnabled,
      lifecycleEnabled: lifecycleEnabled ?? this.lifecycleEnabled,
      policyAttached: policyAttached ?? this.policyAttached,
      corsEnabled: corsEnabled ?? this.corsEnabled,
      encryptionEnabled: encryptionEnabled ?? this.encryptionEnabled,
      encryptionSummary: encryptionSummary ?? this.encryptionSummary,
      objectLockMode: objectLockMode ?? this.objectLockMode,
      objectLockRetentionDays:
          objectLockRetentionDays ?? this.objectLockRetentionDays,
      tags: tags ?? this.tags,
      lifecycleRules: lifecycleRules ?? this.lifecycleRules,
      policyJson: policyJson ?? this.policyJson,
      corsJson: corsJson ?? this.corsJson,
      lifecycleJson: lifecycleJson ?? this.lifecycleJson,
      encryptionJson: encryptionJson ?? this.encryptionJson,
      apiCalls: apiCalls ?? this.apiCalls,
    );
  }
}

class ObjectEntry {
  const ObjectEntry({
    required this.key,
    required this.name,
    required this.size,
    required this.storageClass,
    required this.modifiedAt,
    required this.isFolder,
    this.etag,
    this.metadataCount = 0,
  });

  final String key;
  final String name;
  final int size;
  final String storageClass;
  final DateTime modifiedAt;
  final bool isFolder;
  final String? etag;
  final int metadataCount;
}

class ListCursor {
  const ListCursor({
    required this.value,
    required this.hasMore,
  });

  final String? value;
  final bool hasMore;
}

class ObjectListResult {
  const ObjectListResult({
    required this.items,
    required this.cursor,
  });

  final List<ObjectEntry> items;
  final ListCursor cursor;
}

class ObjectVersionEntry {
  const ObjectVersionEntry({
    required this.key,
    required this.versionId,
    required this.modifiedAt,
    required this.latest,
    required this.deleteMarker,
    required this.size,
    this.storageClass = 'STANDARD',
  });

  final String key;
  final String versionId;
  final DateTime modifiedAt;
  final bool latest;
  final bool deleteMarker;
  final int size;
  final String storageClass;
}

class ObjectVersionRef {
  const ObjectVersionRef({
    required this.key,
    required this.versionId,
  });

  final String key;
  final String versionId;
}

class ObjectVersionListResult {
  const ObjectVersionListResult({
    required this.items,
    required this.cursor,
    required this.totalCount,
    required this.versionCount,
    required this.deleteMarkerCount,
  });

  final List<ObjectVersionEntry> items;
  final ListCursor cursor;
  final int totalCount;
  final int versionCount;
  final int deleteMarkerCount;
}

class BatchOperationFailure {
  const BatchOperationFailure({
    required this.target,
    required this.code,
    required this.message,
    this.versionId,
  });

  final String target;
  final String code;
  final String message;
  final String? versionId;
}

class BatchOperationResult {
  const BatchOperationResult({
    required this.successCount,
    required this.failureCount,
    required this.failures,
  });

  final int successCount;
  final int failureCount;
  final List<BatchOperationFailure> failures;
}

class PresignedUrlBundle {
  const PresignedUrlBundle({
    required this.url,
    required this.expirationMinutes,
    required this.curlCommand,
  });

  final String url;
  final int expirationMinutes;
  final String curlCommand;
}

class DiagnosticEvent {
  const DiagnosticEvent({
    required this.timestamp,
    required this.level,
    required this.message,
  });

  final DateTime timestamp;
  final String level;
  final String message;
}

class ApiCallRecord {
  const ApiCallRecord({
    required this.timestamp,
    required this.operation,
    required this.status,
    required this.latencyMs,
  });

  final DateTime timestamp;
  final String operation;
  final String status;
  final int latencyMs;
}

class ObjectDetails {
  const ObjectDetails({
    required this.key,
    required this.metadata,
    required this.headers,
    required this.tags,
    required this.debugEvents,
    required this.apiCalls,
    this.presignedUrl,
    this.debugLogExcerpt = const [],
    this.rawDiagnostics = const {},
  });

  final String key;
  final Map<String, String> metadata;
  final Map<String, String> headers;
  final Map<String, String> tags;
  final List<DiagnosticEvent> debugEvents;
  final List<ApiCallRecord> apiCalls;
  final PresignedUrlBundle? presignedUrl;
  final List<String> debugLogExcerpt;
  final Map<String, Object?> rawDiagnostics;

  ObjectDetails copyWith({
    Map<String, String>? metadata,
    Map<String, String>? headers,
    Map<String, String>? tags,
    List<DiagnosticEvent>? debugEvents,
    List<ApiCallRecord>? apiCalls,
    PresignedUrlBundle? presignedUrl,
    List<String>? debugLogExcerpt,
    Map<String, Object?>? rawDiagnostics,
  }) {
    return ObjectDetails(
      key: key,
      metadata: metadata ?? this.metadata,
      headers: headers ?? this.headers,
      tags: tags ?? this.tags,
      debugEvents: debugEvents ?? this.debugEvents,
      apiCalls: apiCalls ?? this.apiCalls,
      presignedUrl: presignedUrl ?? this.presignedUrl,
      debugLogExcerpt: debugLogExcerpt ?? this.debugLogExcerpt,
      rawDiagnostics: rawDiagnostics ?? this.rawDiagnostics,
    );
  }
}

class ObjectPreview {
  const ObjectPreview({
    required this.key,
    required this.kind,
    required this.loading,
    required this.supported,
    required this.message,
    this.contentType,
    this.url,
    this.text,
    this.truncated = false,
    this.loadedBytes = 0,
  });

  final String key;
  final ObjectPreviewKind kind;
  final bool loading;
  final bool supported;
  final String message;
  final String? contentType;
  final String? url;
  final String? text;
  final bool truncated;
  final int loadedBytes;

  factory ObjectPreview.loading({
    required String key,
    required ObjectPreviewKind kind,
    String? contentType,
  }) {
    return ObjectPreview(
      key: key,
      kind: kind,
      loading: true,
      supported: true,
      message: 'Loading preview...',
      contentType: contentType,
    );
  }

  factory ObjectPreview.ready({
    required String key,
    required ObjectPreviewKind kind,
    required String message,
    String? contentType,
    String? url,
    String? text,
    bool truncated = false,
    int loadedBytes = 0,
  }) {
    return ObjectPreview(
      key: key,
      kind: kind,
      loading: false,
      supported: true,
      message: message,
      contentType: contentType,
      url: url,
      text: text,
      truncated: truncated,
      loadedBytes: loadedBytes,
    );
  }

  factory ObjectPreview.unsupported({
    required String key,
    String? contentType,
    String message = 'Not supported.',
  }) {
    return ObjectPreview(
      key: key,
      kind: ObjectPreviewKind.unsupported,
      loading: false,
      supported: false,
      message: message,
      contentType: contentType,
    );
  }
}

class VersionBrowserOptions {
  const VersionBrowserOptions({
    this.filterValue = '',
    this.filterMode = BrowserFilterMode.prefix,
    this.showVersions = true,
    this.showDeleteMarkers = true,
  });

  final String filterValue;
  final BrowserFilterMode filterMode;
  final bool showVersions;
  final bool showDeleteMarkers;

  VersionBrowserOptions copyWith({
    String? filterValue,
    BrowserFilterMode? filterMode,
    bool? showVersions,
    bool? showDeleteMarkers,
  }) {
    return VersionBrowserOptions(
      filterValue: filterValue ?? this.filterValue,
      filterMode: filterMode ?? this.filterMode,
      showVersions: showVersions ?? this.showVersions,
      showDeleteMarkers: showDeleteMarkers ?? this.showDeleteMarkers,
    );
  }
}

class ToolExecutionState {
  const ToolExecutionState({
    required this.label,
    required this.running,
    required this.lastStatus,
    this.jobId,
    this.cancellable = false,
    this.outputLines = const [],
    this.exitCode,
  });

  final String label;
  final bool running;
  final String lastStatus;
  final String? jobId;
  final bool cancellable;
  final List<String> outputLines;
  final int? exitCode;

  ToolExecutionState copyWith({
    String? label,
    bool? running,
    String? lastStatus,
    String? jobId,
    bool? cancellable,
    List<String>? outputLines,
    int? exitCode,
  }) {
    return ToolExecutionState(
      label: label ?? this.label,
      running: running ?? this.running,
      lastStatus: lastStatus ?? this.lastStatus,
      jobId: jobId ?? this.jobId,
      cancellable: cancellable ?? this.cancellable,
      outputLines: outputLines ?? this.outputLines,
      exitCode: exitCode ?? this.exitCode,
    );
  }
}

class TestDataToolConfig {
  const TestDataToolConfig({
    required this.bucketName,
    required this.endpointUrl,
    required this.accessKey,
    required this.secretKey,
    required this.objectSizeBytes,
    required this.versions,
    required this.objectCount,
    required this.prefix,
    required this.threads,
    required this.checksumAlgorithm,
  });

  final String bucketName;
  final String endpointUrl;
  final String accessKey;
  final String secretKey;
  final int objectSizeBytes;
  final int versions;
  final int objectCount;
  final String prefix;
  final int threads;
  final String checksumAlgorithm;

  TestDataToolConfig copyWith({
    String? bucketName,
    String? endpointUrl,
    String? accessKey,
    String? secretKey,
    int? objectSizeBytes,
    int? versions,
    int? objectCount,
    String? prefix,
    int? threads,
    String? checksumAlgorithm,
  }) {
    return TestDataToolConfig(
      bucketName: bucketName ?? this.bucketName,
      endpointUrl: endpointUrl ?? this.endpointUrl,
      accessKey: accessKey ?? this.accessKey,
      secretKey: secretKey ?? this.secretKey,
      objectSizeBytes: objectSizeBytes ?? this.objectSizeBytes,
      versions: versions ?? this.versions,
      objectCount: objectCount ?? this.objectCount,
      prefix: prefix ?? this.prefix,
      threads: threads ?? this.threads,
      checksumAlgorithm: checksumAlgorithm ?? this.checksumAlgorithm,
    );
  }
}

class DeleteAllToolConfig {
  const DeleteAllToolConfig({
    required this.bucketName,
    required this.endpointUrl,
    required this.accessKey,
    required this.secretKey,
    required this.checksumAlgorithm,
    required this.batchSize,
    required this.maxWorkers,
    required this.maxRetries,
    required this.retryMode,
    required this.maxRequestsPerSecond,
    required this.maxConnections,
    required this.pipelineSize,
    required this.listMaxKeys,
    required this.deletionDelayMs,
    required this.immediateDeletion,
  });

  final String bucketName;
  final String endpointUrl;
  final String accessKey;
  final String secretKey;
  final String checksumAlgorithm;
  final int batchSize;
  final int maxWorkers;
  final int maxRetries;
  final String retryMode;
  final int maxRequestsPerSecond;
  final int maxConnections;
  final int pipelineSize;
  final int listMaxKeys;
  final int deletionDelayMs;
  final bool immediateDeletion;

  DeleteAllToolConfig copyWith({
    String? bucketName,
    String? endpointUrl,
    String? accessKey,
    String? secretKey,
    String? checksumAlgorithm,
    int? batchSize,
    int? maxWorkers,
    int? maxRetries,
    String? retryMode,
    int? maxRequestsPerSecond,
    int? maxConnections,
    int? pipelineSize,
    int? listMaxKeys,
    int? deletionDelayMs,
    bool? immediateDeletion,
  }) {
    return DeleteAllToolConfig(
      bucketName: bucketName ?? this.bucketName,
      endpointUrl: endpointUrl ?? this.endpointUrl,
      accessKey: accessKey ?? this.accessKey,
      secretKey: secretKey ?? this.secretKey,
      checksumAlgorithm: checksumAlgorithm ?? this.checksumAlgorithm,
      batchSize: batchSize ?? this.batchSize,
      maxWorkers: maxWorkers ?? this.maxWorkers,
      maxRetries: maxRetries ?? this.maxRetries,
      retryMode: retryMode ?? this.retryMode,
      maxRequestsPerSecond: maxRequestsPerSecond ?? this.maxRequestsPerSecond,
      maxConnections: maxConnections ?? this.maxConnections,
      pipelineSize: pipelineSize ?? this.pipelineSize,
      listMaxKeys: listMaxKeys ?? this.listMaxKeys,
      deletionDelayMs: deletionDelayMs ?? this.deletionDelayMs,
      immediateDeletion: immediateDeletion ?? this.immediateDeletion,
    );
  }
}

class BenchmarkConfig {
  const BenchmarkConfig({
    required this.profileId,
    required this.engineId,
    required this.bucketName,
    required this.prefix,
    required this.workloadType,
    required this.deleteMode,
    required this.objectSizes,
    required this.concurrentThreads,
    required this.testMode,
    required this.operationCount,
    required this.durationSeconds,
    required this.validateChecksum,
    required this.checksumAlgorithm,
    required this.randomData,
    required this.inMemoryData,
    required this.objectCount,
    required this.connectTimeoutSeconds,
    required this.readTimeoutSeconds,
    required this.maxAttempts,
    required this.maxPoolConnections,
    required this.dataCacheMb,
    required this.csvOutputPath,
    required this.jsonOutputPath,
    required this.logFilePath,
    required this.debugMode,
    this.readPercent = 34,
    this.writePercent = 33,
    this.deletePercent = 33,
    this.reducedLogging = false,
  });

  final String profileId;
  final String engineId;
  final String bucketName;
  final String prefix;
  final String workloadType;
  final String deleteMode;
  final List<int> objectSizes;
  final int concurrentThreads;
  final String testMode;
  final int operationCount;
  final int durationSeconds;
  final bool validateChecksum;
  final String checksumAlgorithm;
  final bool randomData;
  final bool inMemoryData;
  final int objectCount;
  final int connectTimeoutSeconds;
  final int readTimeoutSeconds;
  final int maxAttempts;
  final int maxPoolConnections;
  final int dataCacheMb;
  final String csvOutputPath;
  final String jsonOutputPath;
  final String logFilePath;
  final bool debugMode;

  /// Used only when [workloadType] == 'custom'. Percentage of GET operations.
  final int readPercent;

  /// Used only when [workloadType] == 'custom'. Percentage of PUT operations.
  final int writePercent;

  /// Used only when [workloadType] == 'custom'. Percentage of DELETE operations.
  final int deletePercent;

  /// When true, per-object request timing logs are suppressed for maximum
  /// throughput. Summary stats are still recorded. Use as a last resort after
  /// tuning Threads and Pool Connections first.
  final bool reducedLogging;

  BenchmarkConfig copyWith({
    String? profileId,
    String? engineId,
    String? bucketName,
    String? prefix,
    String? workloadType,
    String? deleteMode,
    List<int>? objectSizes,
    int? concurrentThreads,
    String? testMode,
    int? operationCount,
    int? durationSeconds,
    bool? validateChecksum,
    String? checksumAlgorithm,
    bool? randomData,
    bool? inMemoryData,
    int? objectCount,
    int? connectTimeoutSeconds,
    int? readTimeoutSeconds,
    int? maxAttempts,
    int? maxPoolConnections,
    int? dataCacheMb,
    String? csvOutputPath,
    String? jsonOutputPath,
    String? logFilePath,
    bool? debugMode,
    int? readPercent,
    int? writePercent,
    int? deletePercent,
    bool? reducedLogging,
  }) {
    return BenchmarkConfig(
      profileId: profileId ?? this.profileId,
      engineId: engineId ?? this.engineId,
      bucketName: bucketName ?? this.bucketName,
      prefix: prefix ?? this.prefix,
      workloadType: workloadType ?? this.workloadType,
      deleteMode: deleteMode ?? this.deleteMode,
      objectSizes: objectSizes ?? this.objectSizes,
      concurrentThreads: concurrentThreads ?? this.concurrentThreads,
      testMode: testMode ?? this.testMode,
      operationCount: operationCount ?? this.operationCount,
      durationSeconds: durationSeconds ?? this.durationSeconds,
      validateChecksum: validateChecksum ?? this.validateChecksum,
      checksumAlgorithm: checksumAlgorithm ?? this.checksumAlgorithm,
      randomData: randomData ?? this.randomData,
      inMemoryData: inMemoryData ?? this.inMemoryData,
      objectCount: objectCount ?? this.objectCount,
      connectTimeoutSeconds:
          connectTimeoutSeconds ?? this.connectTimeoutSeconds,
      readTimeoutSeconds: readTimeoutSeconds ?? this.readTimeoutSeconds,
      maxAttempts: maxAttempts ?? this.maxAttempts,
      maxPoolConnections: maxPoolConnections ?? this.maxPoolConnections,
      dataCacheMb: dataCacheMb ?? this.dataCacheMb,
      csvOutputPath: csvOutputPath ?? this.csvOutputPath,
      jsonOutputPath: jsonOutputPath ?? this.jsonOutputPath,
      logFilePath: logFilePath ?? this.logFilePath,
      debugMode: debugMode ?? this.debugMode,
      readPercent: readPercent ?? this.readPercent,
      writePercent: writePercent ?? this.writePercent,
      deletePercent: deletePercent ?? this.deletePercent,
      reducedLogging: reducedLogging ?? this.reducedLogging,
    );
  }
}

class BenchmarkResultSummary {
  const BenchmarkResultSummary({
    required this.totalOperations,
    required this.operationsByType,
    required this.latencyPercentilesMs,
    required this.throughputSeries,
    required this.sizeLatencyBuckets,
    required this.checksumStats,
    this.detailMetrics = const <String, Object?>{},
    this.latencyPercentilesByOperationMs =
        const <String, Map<String, double>>{},
    this.operationDetails = const <Map<String, Object?>>[],
    this.latencyTimeline = const <Map<String, Object?>>[],
  });

  final int totalOperations;
  final Map<String, int> operationsByType;
  final Map<String, double> latencyPercentilesMs;
  final List<Map<String, Object?>> throughputSeries;
  final List<Map<String, Object?>> sizeLatencyBuckets;
  final Map<String, int> checksumStats;
  final Map<String, Object?> detailMetrics;
  final Map<String, Map<String, double>> latencyPercentilesByOperationMs;
  final List<Map<String, Object?>> operationDetails;
  final List<Map<String, Object?>> latencyTimeline;
}

class BenchmarkExportBundle {
  const BenchmarkExportBundle({
    required this.format,
    required this.path,
    this.summary,
  });

  final String format;
  final String path;
  final BenchmarkResultSummary? summary;
}

class BenchmarkRun {
  const BenchmarkRun({
    required this.id,
    required this.config,
    required this.status,
    required this.processedCount,
    required this.startedAt,
    required this.averageLatencyMs,
    required this.throughputOpsPerSecond,
    required this.liveLog,
    this.activeElapsedSeconds,
    this.completedAt,
    this.resultSummary,
  });

  final String id;
  final BenchmarkConfig config;
  final String status;
  final int processedCount;
  final DateTime startedAt;
  final DateTime? completedAt;
  final double averageLatencyMs;
  final double throughputOpsPerSecond;
  final List<String> liveLog;
  final double? activeElapsedSeconds;
  final BenchmarkResultSummary? resultSummary;

  BenchmarkRun copyWith({
    String? status,
    int? processedCount,
    DateTime? startedAt,
    DateTime? completedAt,
    double? averageLatencyMs,
    double? throughputOpsPerSecond,
    List<String>? liveLog,
    double? activeElapsedSeconds,
    BenchmarkResultSummary? resultSummary,
  }) {
    return BenchmarkRun(
      id: id,
      config: config,
      status: status ?? this.status,
      processedCount: processedCount ?? this.processedCount,
      startedAt: startedAt ?? this.startedAt,
      completedAt: completedAt ?? this.completedAt,
      averageLatencyMs: averageLatencyMs ?? this.averageLatencyMs,
      throughputOpsPerSecond:
          throughputOpsPerSecond ?? this.throughputOpsPerSecond,
      liveLog: liveLog ?? this.liveLog,
      activeElapsedSeconds: activeElapsedSeconds ?? this.activeElapsedSeconds,
      resultSummary: resultSummary ?? this.resultSummary,
    );
  }
}

class TransferJob {
  const TransferJob({
    required this.id,
    required this.label,
    required this.direction,
    required this.progress,
    required this.status,
    required this.bytesTransferred,
    required this.totalBytes,
    this.strategyLabel,
    this.currentItemLabel,
    this.itemCount,
    this.itemsCompleted,
    this.partSizeBytes,
    this.partsCompleted,
    this.partsTotal,
    this.canPause = true,
    this.canResume = true,
    this.canCancel = true,
    this.outputLines = const [],
  });

  final String id;
  final String label;
  final String direction;
  final double progress;
  final String status;
  final int bytesTransferred;
  final int totalBytes;
  final String? strategyLabel;
  final String? currentItemLabel;
  final int? itemCount;
  final int? itemsCompleted;
  final int? partSizeBytes;
  final int? partsCompleted;
  final int? partsTotal;
  final bool canPause;
  final bool canResume;
  final bool canCancel;
  final List<String> outputLines;

  TransferJob copyWith({
    double? progress,
    String? status,
    int? bytesTransferred,
    int? totalBytes,
    String? strategyLabel,
    String? currentItemLabel,
    int? itemCount,
    int? itemsCompleted,
    int? partSizeBytes,
    int? partsCompleted,
    int? partsTotal,
    bool? canPause,
    bool? canResume,
    bool? canCancel,
    List<String>? outputLines,
  }) {
    return TransferJob(
      id: id,
      label: label,
      direction: direction,
      progress: progress ?? this.progress,
      status: status ?? this.status,
      bytesTransferred: bytesTransferred ?? this.bytesTransferred,
      totalBytes: totalBytes ?? this.totalBytes,
      strategyLabel: strategyLabel ?? this.strategyLabel,
      currentItemLabel: currentItemLabel ?? this.currentItemLabel,
      itemCount: itemCount ?? this.itemCount,
      itemsCompleted: itemsCompleted ?? this.itemsCompleted,
      partSizeBytes: partSizeBytes ?? this.partSizeBytes,
      partsCompleted: partsCompleted ?? this.partsCompleted,
      partsTotal: partsTotal ?? this.partsTotal,
      canPause: canPause ?? this.canPause,
      canResume: canResume ?? this.canResume,
      canCancel: canCancel ?? this.canCancel,
      outputLines: outputLines ?? this.outputLines,
    );
  }
}

class BrowserTaskRecord {
  const BrowserTaskRecord({
    required this.id,
    required this.kind,
    required this.label,
    required this.status,
    required this.startedAt,
    required this.progress,
    this.profileId,
    this.bucketName,
    this.engineJobId,
    this.completedAt,
    this.outputLines = const [],
    this.bytesTransferred,
    this.totalBytes,
    this.strategyLabel,
    this.currentItemLabel,
    this.itemCount,
    this.itemsCompleted,
    this.partSizeBytes,
    this.partsCompleted,
    this.partsTotal,
    this.canPause = false,
    this.canResume = false,
    this.canCancel = false,
    this.workspaceTab,
    this.actionKey,
  });

  final String id;
  final BrowserTaskKind kind;
  final String label;
  final String status;
  final DateTime startedAt;
  final DateTime? completedAt;
  final double progress;
  final String? profileId;
  final String? bucketName;
  final String? engineJobId;
  final List<String> outputLines;
  final int? bytesTransferred;
  final int? totalBytes;
  final String? strategyLabel;
  final String? currentItemLabel;
  final int? itemCount;
  final int? itemsCompleted;
  final int? partSizeBytes;
  final int? partsCompleted;
  final int? partsTotal;
  final bool canPause;
  final bool canResume;
  final bool canCancel;
  final WorkspaceTab? workspaceTab;
  final String? actionKey;

  BrowserTaskRecord copyWith({
    String? status,
    DateTime? completedAt,
    double? progress,
    List<String>? outputLines,
    int? bytesTransferred,
    int? totalBytes,
    String? strategyLabel,
    String? currentItemLabel,
    int? itemCount,
    int? itemsCompleted,
    int? partSizeBytes,
    int? partsCompleted,
    int? partsTotal,
    bool? canPause,
    bool? canResume,
    bool? canCancel,
    WorkspaceTab? workspaceTab,
    String? actionKey,
  }) {
    return BrowserTaskRecord(
      id: id,
      kind: kind,
      label: label,
      status: status ?? this.status,
      startedAt: startedAt,
      completedAt: completedAt ?? this.completedAt,
      progress: progress ?? this.progress,
      profileId: profileId,
      bucketName: bucketName,
      engineJobId: engineJobId,
      outputLines: outputLines ?? this.outputLines,
      bytesTransferred: bytesTransferred ?? this.bytesTransferred,
      totalBytes: totalBytes ?? this.totalBytes,
      strategyLabel: strategyLabel ?? this.strategyLabel,
      currentItemLabel: currentItemLabel ?? this.currentItemLabel,
      itemCount: itemCount ?? this.itemCount,
      itemsCompleted: itemsCompleted ?? this.itemsCompleted,
      partSizeBytes: partSizeBytes ?? this.partSizeBytes,
      partsCompleted: partsCompleted ?? this.partsCompleted,
      partsTotal: partsTotal ?? this.partsTotal,
      canPause: canPause ?? this.canPause,
      canResume: canResume ?? this.canResume,
      canCancel: canCancel ?? this.canCancel,
      workspaceTab: workspaceTab ?? this.workspaceTab,
      actionKey: actionKey ?? this.actionKey,
    );
  }

  bool get isRunningLike {
    final normalized = status.toLowerCase();
    return normalized == 'running' ||
        normalized == 'queued' ||
        normalized == 'active' ||
        normalized == 'paused' ||
        normalized == 'cancelling' ||
        normalized == 'canceling';
  }

  bool get isFailedLike {
    final normalized = status.toLowerCase();
    return normalized == 'failed' ||
        normalized == 'error' ||
        normalized == 'cancelled' ||
        normalized == 'canceled';
  }
}

class AppSettings {
  const AppSettings({
    required this.darkMode,
    required this.defaultEngineId,
    this.defaultProfileId = '',
    required this.downloadPath,
    required this.tempPath,
    required this.transferConcurrency,
    required this.multipartThresholdMiB,
    required this.multipartChunkMiB,
    required this.dynamicMultipartSizing,
    required this.enableAnimations,
    required this.enableDiagnostics,
    required this.enableApiLogging,
    required this.enableDebugLogging,
    required this.safeRetries,
    required this.benchmarkChartSmoothing,
    required this.retryBaseDelayMs,
    required this.retryMaxDelayMs,
    required this.requestDelayMs,
    required this.connectTimeoutSeconds,
    required this.readTimeoutSeconds,
    required this.maxPoolConnections,
    required this.maxRequestsPerSecond,
    required this.enableCrashRecovery,
    required this.defaultPresignMinutes,
    required this.benchmarkDataCacheMb,
    required this.benchmarkDebugMode,
    required this.benchmarkLogPath,
    required this.browserInspectorLayout,
    required this.browserInspectorSize,
    required this.relistObjectsAfterMutation,
    required this.uiScalePercent,
    required this.logTextScalePercent,
  });

  final bool darkMode;
  final String defaultEngineId;
  final String defaultProfileId;
  final String downloadPath;
  final String tempPath;
  final int transferConcurrency;
  final int multipartThresholdMiB;
  final int multipartChunkMiB;
  final bool dynamicMultipartSizing;
  final bool enableAnimations;
  final bool enableDiagnostics;
  final bool enableApiLogging;
  final bool enableDebugLogging;
  final int safeRetries;
  final bool benchmarkChartSmoothing;
  final int retryBaseDelayMs;
  final int retryMaxDelayMs;
  final int requestDelayMs;
  final int connectTimeoutSeconds;
  final int readTimeoutSeconds;
  final int maxPoolConnections;
  final int maxRequestsPerSecond;
  final bool enableCrashRecovery;
  final int defaultPresignMinutes;
  final int benchmarkDataCacheMb;
  final bool benchmarkDebugMode;
  final String benchmarkLogPath;
  final BrowserInspectorLayout browserInspectorLayout;
  final int browserInspectorSize;
  final bool relistObjectsAfterMutation;
  final int uiScalePercent;
  final int logTextScalePercent;

  Map<String, Object?> toJson() {
    return {
      'darkMode': darkMode,
      'defaultEngineId': defaultEngineId,
      'defaultProfileId': defaultProfileId,
      'downloadPath': downloadPath,
      'tempPath': tempPath,
      'transferConcurrency': transferConcurrency,
      'multipartThresholdMiB': multipartThresholdMiB,
      'multipartChunkMiB': multipartChunkMiB,
      'dynamicMultipartSizing': dynamicMultipartSizing,
      'enableAnimations': enableAnimations,
      'enableDiagnostics': enableDiagnostics,
      'enableApiLogging': enableApiLogging,
      'enableDebugLogging': enableDebugLogging,
      'safeRetries': safeRetries,
      'benchmarkChartSmoothing': benchmarkChartSmoothing,
      'retryBaseDelayMs': retryBaseDelayMs,
      'retryMaxDelayMs': retryMaxDelayMs,
      'requestDelayMs': requestDelayMs,
      'connectTimeoutSeconds': connectTimeoutSeconds,
      'readTimeoutSeconds': readTimeoutSeconds,
      'maxPoolConnections': maxPoolConnections,
      'maxRequestsPerSecond': maxRequestsPerSecond,
      'enableCrashRecovery': enableCrashRecovery,
      'defaultPresignMinutes': defaultPresignMinutes,
      'benchmarkDataCacheMb': benchmarkDataCacheMb,
      'benchmarkDebugMode': benchmarkDebugMode,
      'benchmarkLogPath': benchmarkLogPath,
      'browserInspectorLayout': browserInspectorLayout.name,
      'browserInspectorSize': browserInspectorSize,
      'relistObjectsAfterMutation': relistObjectsAfterMutation,
      'uiScalePercent': uiScalePercent,
      'logTextScalePercent': logTextScalePercent,
    };
  }

  factory AppSettings.fromJson(Map<String, Object?> json) {
    final uiScalePercent = (json['uiScalePercent'] as num?)?.toInt() ?? 70;
    return AppSettings(
      darkMode: json['darkMode'] as bool? ?? false,
      defaultEngineId: (json['defaultEngineId'] as String?) ?? 'python',
      defaultProfileId: (json['defaultProfileId'] as String?) ?? '',
      downloadPath: (json['downloadPath'] as String?) ?? '',
      tempPath: (json['tempPath'] as String?) ?? '',
      transferConcurrency: (json['transferConcurrency'] as num?)?.toInt() ?? 8,
      multipartThresholdMiB:
          (json['multipartThresholdMiB'] as num?)?.toInt() ?? 32,
      multipartChunkMiB: (json['multipartChunkMiB'] as num?)?.toInt() ?? 8,
      dynamicMultipartSizing: json['dynamicMultipartSizing'] as bool? ?? true,
      enableAnimations: json['enableAnimations'] as bool? ?? true,
      enableDiagnostics: json['enableDiagnostics'] as bool? ?? true,
      enableApiLogging: json['enableApiLogging'] as bool? ?? false,
      enableDebugLogging: json['enableDebugLogging'] as bool? ?? false,
      safeRetries: (json['safeRetries'] as num?)?.toInt() ?? 3,
      benchmarkChartSmoothing: json['benchmarkChartSmoothing'] as bool? ?? true,
      retryBaseDelayMs: (json['retryBaseDelayMs'] as num?)?.toInt() ?? 250,
      retryMaxDelayMs: (json['retryMaxDelayMs'] as num?)?.toInt() ?? 4000,
      requestDelayMs: (json['requestDelayMs'] as num?)?.toInt() ?? 0,
      connectTimeoutSeconds:
          (json['connectTimeoutSeconds'] as num?)?.toInt() ?? 5,
      readTimeoutSeconds: (json['readTimeoutSeconds'] as num?)?.toInt() ?? 60,
      maxPoolConnections: (json['maxPoolConnections'] as num?)?.toInt() ?? 200,
      maxRequestsPerSecond:
          (json['maxRequestsPerSecond'] as num?)?.toInt() ?? 0,
      enableCrashRecovery: json['enableCrashRecovery'] as bool? ?? true,
      defaultPresignMinutes:
          (json['defaultPresignMinutes'] as num?)?.toInt() ?? 60,
      benchmarkDataCacheMb:
          (json['benchmarkDataCacheMb'] as num?)?.toInt() ?? 0,
      benchmarkDebugMode: json['benchmarkDebugMode'] as bool? ?? false,
      benchmarkLogPath: (json['benchmarkLogPath'] as String?) ?? '',
      browserInspectorLayout: BrowserInspectorLayout.values.byName(
        (json['browserInspectorLayout'] as String?) ?? 'bottom',
      ),
      browserInspectorSize:
          (json['browserInspectorSize'] as num?)?.toInt() ?? 360,
      relistObjectsAfterMutation:
          json['relistObjectsAfterMutation'] as bool? ?? true,
      uiScalePercent: uiScalePercent,
      logTextScalePercent: (json['logTextScalePercent'] as num?)?.toInt() ?? 80,
    );
  }

  AppSettings copyWith({
    bool? darkMode,
    String? defaultEngineId,
    String? defaultProfileId,
    String? downloadPath,
    String? tempPath,
    int? transferConcurrency,
    int? multipartThresholdMiB,
    int? multipartChunkMiB,
    bool? dynamicMultipartSizing,
    bool? enableAnimations,
    bool? enableDiagnostics,
    bool? enableApiLogging,
    bool? enableDebugLogging,
    int? safeRetries,
    bool? benchmarkChartSmoothing,
    int? retryBaseDelayMs,
    int? retryMaxDelayMs,
    int? requestDelayMs,
    int? connectTimeoutSeconds,
    int? readTimeoutSeconds,
    int? maxPoolConnections,
    int? maxRequestsPerSecond,
    bool? enableCrashRecovery,
    int? defaultPresignMinutes,
    int? benchmarkDataCacheMb,
    bool? benchmarkDebugMode,
    String? benchmarkLogPath,
    BrowserInspectorLayout? browserInspectorLayout,
    int? browserInspectorSize,
    bool? relistObjectsAfterMutation,
    int? uiScalePercent,
    int? logTextScalePercent,
  }) {
    return AppSettings(
      darkMode: darkMode ?? this.darkMode,
      defaultEngineId: defaultEngineId ?? this.defaultEngineId,
      defaultProfileId: defaultProfileId ?? this.defaultProfileId,
      downloadPath: downloadPath ?? this.downloadPath,
      tempPath: tempPath ?? this.tempPath,
      transferConcurrency: transferConcurrency ?? this.transferConcurrency,
      multipartThresholdMiB:
          multipartThresholdMiB ?? this.multipartThresholdMiB,
      multipartChunkMiB: multipartChunkMiB ?? this.multipartChunkMiB,
      dynamicMultipartSizing:
          dynamicMultipartSizing ?? this.dynamicMultipartSizing,
      enableAnimations: enableAnimations ?? this.enableAnimations,
      enableDiagnostics: enableDiagnostics ?? this.enableDiagnostics,
      enableApiLogging: enableApiLogging ?? this.enableApiLogging,
      enableDebugLogging: enableDebugLogging ?? this.enableDebugLogging,
      safeRetries: safeRetries ?? this.safeRetries,
      benchmarkChartSmoothing:
          benchmarkChartSmoothing ?? this.benchmarkChartSmoothing,
      retryBaseDelayMs: retryBaseDelayMs ?? this.retryBaseDelayMs,
      retryMaxDelayMs: retryMaxDelayMs ?? this.retryMaxDelayMs,
      requestDelayMs: requestDelayMs ?? this.requestDelayMs,
      connectTimeoutSeconds:
          connectTimeoutSeconds ?? this.connectTimeoutSeconds,
      readTimeoutSeconds: readTimeoutSeconds ?? this.readTimeoutSeconds,
      maxPoolConnections: maxPoolConnections ?? this.maxPoolConnections,
      maxRequestsPerSecond: maxRequestsPerSecond ?? this.maxRequestsPerSecond,
      enableCrashRecovery: enableCrashRecovery ?? this.enableCrashRecovery,
      defaultPresignMinutes:
          defaultPresignMinutes ?? this.defaultPresignMinutes,
      benchmarkDataCacheMb: benchmarkDataCacheMb ?? this.benchmarkDataCacheMb,
      benchmarkDebugMode: benchmarkDebugMode ?? this.benchmarkDebugMode,
      benchmarkLogPath: benchmarkLogPath ?? this.benchmarkLogPath,
      browserInspectorLayout:
          browserInspectorLayout ?? this.browserInspectorLayout,
      browserInspectorSize: browserInspectorSize ?? this.browserInspectorSize,
      relistObjectsAfterMutation:
          relistObjectsAfterMutation ?? this.relistObjectsAfterMutation,
      uiScalePercent: uiScalePercent ?? this.uiScalePercent,
      logTextScalePercent: logTextScalePercent ?? this.logTextScalePercent,
    );
  }
}

class EngineException implements Exception {
  const EngineException({
    required this.code,
    required this.message,
    this.details,
  });

  final ErrorCode code;
  final String message;
  final Map<String, Object?>? details;

  @override
  String toString() => 'EngineException($code, $message)';
}
