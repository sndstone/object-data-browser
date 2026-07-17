import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import '../models/domain_models.dart';
import 'engine_service.dart';

class MockEngineService implements EngineService, TransferJobSinkRegistrant {
  MockEngineService();

  final Map<String, BenchmarkRun> _runs = {};
  final Map<String, TransferJob> _transfers = {};
  final math.Random _random = math.Random(7);
  TransferJobCallback? _transferSink;

  static final List<EngineDescriptor> _engines = [
    const EngineDescriptor(
      id: 'python',
      label: 'Python Engine',
      language: 'Python',
      version: '2.2.3',
      available: true,
      desktopSupported: true,
      androidSupported: false,
    ),
    const EngineDescriptor(
      id: 'go',
      label: 'Go Engine',
      language: 'Go',
      version: '2.2.3',
      available: true,
      desktopSupported: true,
      androidSupported: true,
    ),
    const EngineDescriptor(
      id: 'rust',
      label: 'Rust Engine',
      language: 'Rust',
      version: '2.2.3',
      available: true,
      desktopSupported: true,
      androidSupported: true,
    ),
    const EngineDescriptor(
      id: 'java',
      label: 'Java Engine',
      language: 'Java',
      version: '2.2.3',
      available: true,
      desktopSupported: true,
      androidSupported: false,
    ),
  ];

  @override
  void configureDiagnostics(DiagnosticsOptions options) {}

  @override
  bool get isMock => true;

  @override
  void shutdown() {}

  @override
  void setTransferSink(TransferJobCallback? sink) {
    _transferSink = sink;
  }

  @override
  Future<void> testProfile({
    required String engineId,
    required EndpointProfile profile,
  }) async {
    await Future<void>.delayed(const Duration(milliseconds: 250));
    if (profile.endpointUrl.trim().isEmpty) {
      throw const EngineException(
        code: ErrorCode.invalidConfig,
        message: 'Endpoint URL is required.',
      );
    }
    if (profile.accessKey.trim().isEmpty || profile.secretKey.trim().isEmpty) {
      throw const EngineException(
        code: ErrorCode.invalidConfig,
        message: 'Access key and secret key are required.',
      );
    }
  }

  @override
  Future<List<EngineDescriptor>> listEngines() async => _engines;

  @override
  Future<List<CapabilityDescriptor>> getCapabilities({
    required String engineId,
    required EndpointProfile profile,
  }) async {
    return [
      const CapabilityDescriptor(
        key: 'bucket.lifecycle',
        label: 'Lifecycle policy CRUD',
        state: CapabilityState.supported,
      ),
      const CapabilityDescriptor(
        key: 'bucket.policy',
        label: 'Bucket policy CRUD',
        state: CapabilityState.supported,
      ),
      const CapabilityDescriptor(
        key: 'bucket.cors',
        label: 'Bucket CORS CRUD',
        state: CapabilityState.supported,
      ),
      const CapabilityDescriptor(
        key: 'bucket.encryption',
        label: 'Bucket encryption',
        state: CapabilityState.supported,
      ),
      const CapabilityDescriptor(
        key: 'bucket.tagging',
        label: 'Bucket tagging',
        state: CapabilityState.supported,
      ),
      const CapabilityDescriptor(
        key: 'bucket.versioning',
        label: 'Bucket versioning',
        state: CapabilityState.supported,
      ),
      const CapabilityDescriptor(
        key: 'bucket.object_lock',
        label: 'Bucket object lock',
        state: CapabilityState.supported,
      ),
      const CapabilityDescriptor(
        key: 'object.resumable',
        label: 'Resumable transfer jobs',
        state: CapabilityState.supported,
      ),
      const CapabilityDescriptor(
        key: 'object.copy_move',
        label: 'Copy, move, rename',
        state: CapabilityState.supported,
      ),
      const CapabilityDescriptor(
        key: 'tools.bulk-delete',
        label: 'Delete-all maintenance tool',
        state: CapabilityState.supported,
      ),
      const CapabilityDescriptor(
        key: 'benchmark',
        label: 'Integrated benchmark mode',
        state: CapabilityState.supported,
      ),
    ];
  }

  @override
  Future<List<BucketSummary>> listBuckets({
    required String engineId,
    required EndpointProfile profile,
  }) async {
    final now = DateTime.now();
    return [
      BucketSummary(
        name: 'benchmark-scratch',
        region: profile.region.isEmpty ? 'us-east-1' : profile.region,
        objectCountHint: 512,
        versioningEnabled: false,
        createdAt: now.subtract(const Duration(days: 3)),
      ),
      BucketSummary(
        name: 'media-assets',
        region: profile.region.isEmpty ? 'us-east-1' : profile.region,
        objectCountHint: 1284,
        versioningEnabled: true,
        createdAt: now.subtract(const Duration(days: 90)),
      ),
      BucketSummary(
        name: 'archive-vault',
        region: profile.region.isEmpty ? 'us-east-1' : profile.region,
        objectCountHint: 94,
        versioningEnabled: true,
        createdAt: now.subtract(const Duration(days: 240)),
      ),
    ];
  }

  @override
  Future<BucketSummary> createBucket({
    required String engineId,
    required EndpointProfile profile,
    required String bucketName,
    required bool enableVersioning,
    required bool enableObjectLock,
  }) async {
    return BucketSummary(
      name: bucketName,
      region: profile.region.isEmpty ? 'us-east-1' : profile.region,
      objectCountHint: 0,
      versioningEnabled: enableVersioning,
      createdAt: DateTime.now(),
    );
  }

  @override
  Future<void> deleteBucket({
    required String engineId,
    required EndpointProfile profile,
    required String bucketName,
  }) async {}

  @override
  Future<BucketAdminState> getBucketAdminState({
    required String engineId,
    required EndpointProfile profile,
    required String bucketName,
  }) async {
    return _bucketAdminState(bucketName);
  }

  @override
  Future<BucketAdminState> setBucketVersioning({
    required String engineId,
    required EndpointProfile profile,
    required String bucketName,
    required bool enabled,
  }) async {
    return _bucketAdminState(bucketName).copyWith(
      versioningEnabled: enabled,
      versioningStatus: enabled ? 'Enabled' : 'Suspended',
    );
  }

  @override
  Future<BucketAdminState> putBucketLifecycle({
    required String engineId,
    required EndpointProfile profile,
    required String bucketName,
    required String lifecycleJson,
  }) async {
    return _bucketAdminState(bucketName).copyWith(
      lifecycleEnabled: true,
      lifecycleJson: lifecycleJson,
    );
  }

  @override
  Future<BucketAdminState> deleteBucketLifecycle({
    required String engineId,
    required EndpointProfile profile,
    required String bucketName,
  }) async {
    return _bucketAdminState(bucketName).copyWith(
      lifecycleEnabled: false,
      lifecycleRules: const [],
      lifecycleJson: '{\n  "Rules": []\n}',
    );
  }

  @override
  Future<BucketAdminState> putBucketPolicy({
    required String engineId,
    required EndpointProfile profile,
    required String bucketName,
    required String policyJson,
  }) async {
    return _bucketAdminState(bucketName).copyWith(
      policyAttached: true,
      policyJson: policyJson,
    );
  }

  @override
  Future<BucketAdminState> deleteBucketPolicy({
    required String engineId,
    required EndpointProfile profile,
    required String bucketName,
  }) async {
    return _bucketAdminState(bucketName).copyWith(
      policyAttached: false,
      policyJson: '{}',
    );
  }

  @override
  Future<BucketAdminState> putBucketCors({
    required String engineId,
    required EndpointProfile profile,
    required String bucketName,
    required String corsJson,
  }) async {
    return _bucketAdminState(bucketName).copyWith(
      corsEnabled: true,
      corsJson: corsJson,
    );
  }

  @override
  Future<BucketAdminState> deleteBucketCors({
    required String engineId,
    required EndpointProfile profile,
    required String bucketName,
  }) async {
    return _bucketAdminState(bucketName).copyWith(
      corsEnabled: false,
      corsJson: '[]',
    );
  }

  @override
  Future<BucketAdminState> putBucketEncryption({
    required String engineId,
    required EndpointProfile profile,
    required String bucketName,
    required String encryptionJson,
  }) async {
    return _bucketAdminState(bucketName).copyWith(
      encryptionEnabled: true,
      encryptionJson: encryptionJson,
    );
  }

  @override
  Future<BucketAdminState> deleteBucketEncryption({
    required String engineId,
    required EndpointProfile profile,
    required String bucketName,
  }) async {
    return _bucketAdminState(bucketName).copyWith(
      encryptionEnabled: false,
      encryptionSummary: 'Not configured',
      encryptionJson: '{}',
    );
  }

  @override
  Future<BucketAdminState> putBucketTagging({
    required String engineId,
    required EndpointProfile profile,
    required String bucketName,
    required Map<String, String> tags,
  }) async {
    return _bucketAdminState(bucketName).copyWith(tags: tags);
  }

  @override
  Future<BucketAdminState> deleteBucketTagging({
    required String engineId,
    required EndpointProfile profile,
    required String bucketName,
  }) async {
    return _bucketAdminState(bucketName).copyWith(tags: const {});
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
    final now = DateTime.now();
    final allItems = <ObjectEntry>[
      if (!flat && prefix.isEmpty)
        ObjectEntry(
          key: 'images/',
          name: 'images/',
          size: 0,
          storageClass: 'FOLDER',
          modifiedAt: now.subtract(const Duration(minutes: 20)),
          isFolder: true,
        ),
      if (!flat && prefix.isEmpty)
        ObjectEntry(
          key: 'logs/',
          name: 'logs/',
          size: 0,
          storageClass: 'FOLDER',
          modifiedAt: now.subtract(const Duration(minutes: 18)),
          isFolder: true,
        ),
      ObjectEntry(
        key: '${prefix}photo-001.jpg',
        name: prefix.isEmpty ? 'photo-001.jpg' : 'photo-001.jpg',
        size: 6291456,
        storageClass: 'STANDARD',
        modifiedAt: now.subtract(const Duration(hours: 2)),
        isFolder: false,
        etag: '9e4f2c0f8fa0',
        metadataCount: 3,
      ),
      ObjectEntry(
        key: '${prefix}report-2026-03.csv',
        name: prefix.isEmpty ? 'report-2026-03.csv' : 'report-2026-03.csv',
        size: 98304,
        storageClass: 'STANDARD_IA',
        modifiedAt: now.subtract(const Duration(hours: 12)),
        isFolder: false,
        etag: '112233445566',
        metadataCount: 2,
      ),
      ...List<ObjectEntry>.generate(
        2350,
        (index) {
          final keyPrefix =
              flat ? prefix : (prefix.isEmpty ? 'archive/' : prefix);
          final key =
              '${keyPrefix}object-${(index + 1).toString().padLeft(4, '0')}.bin';
          return ObjectEntry(
            key: key,
            name: key.split('/').last,
            size: 4096 + ((index % 24) * 8192),
            storageClass: index.isEven ? 'STANDARD' : 'STANDARD_IA',
            modifiedAt: now.subtract(Duration(minutes: index + 1)),
            isFolder: false,
            etag: 'mock-${index + 1}',
            metadataCount: (index % 4) + 1,
          );
        },
      ),
    ];
    const pageSize = 1000;
    final offset = int.tryParse(cursor?.value ?? '') ?? 0;
    final nextOffset = (offset + pageSize).clamp(0, allItems.length);
    final items = allItems.sublist(offset, nextOffset);
    return ObjectListResult(
      items: items,
      cursor: ListCursor(
        value: nextOffset >= allItems.length ? null : '$nextOffset',
        hasMore: nextOffset < allItems.length,
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
  }) async {
    final now = DateTime.now();
    final targetKey = key ?? 'media/cat.jpg';
    final items = [
      ObjectVersionEntry(
        key: targetKey,
        versionId: '3Lg7sample',
        modifiedAt: now.subtract(const Duration(hours: 1)),
        latest: true,
        deleteMarker: false,
        size: 6291456,
      ),
      ObjectVersionEntry(
        key: targetKey,
        versionId: '2Ju4sample',
        modifiedAt: now.subtract(const Duration(days: 1)),
        latest: false,
        deleteMarker: false,
        size: 6291200,
      ),
      ObjectVersionEntry(
        key: targetKey,
        versionId: '1Ab2sample',
        modifiedAt: now.subtract(const Duration(days: 5)),
        latest: false,
        deleteMarker: true,
        size: 0,
      ),
    ];
    if (key == null || key.isEmpty) {
      items.add(
        ObjectVersionEntry(
          key: 'docs/report.csv',
          versionId: '7Mn9sample',
          modifiedAt: now.subtract(const Duration(hours: 3)),
          latest: true,
          deleteMarker: false,
          size: 2048,
          storageClass: 'STANDARD',
        ),
      );
    }
    return ObjectVersionListResult(
      items: items,
      cursor: const ListCursor(value: null, hasMore: false),
      totalCount: items.length,
      versionCount: items.where((item) => !item.deleteMarker).length,
      deleteMarkerCount: items.where((item) => item.deleteMarker).length,
    );
  }

  @override
  Future<ObjectDetails> getObjectDetails({
    required String engineId,
    required EndpointProfile profile,
    required String bucketName,
    required String key,
  }) async {
    final now = DateTime.now();
    return ObjectDetails(
      key: key,
      metadata: const {
        'content-type': 'image/jpeg',
        'owner': 'team-media',
        'workflow': 'approved',
      },
      headers: {
        'ETag': '"9e4f2c0f8fa0"',
        'Cache-Control': 'max-age=3600',
        'Last-Modified':
            now.subtract(const Duration(hours: 2)).toIso8601String(),
        'x-amz-storage-class': 'STANDARD',
      },
      tags: const {
        'project': 'spring-campaign',
        'asset-type': 'hero-image',
      },
      debugEvents: [
        DiagnosticEvent(
          timestamp: now.subtract(const Duration(seconds: 12)),
          level: 'INFO',
          message: 'HEAD object completed via $engineId engine.',
        ),
        DiagnosticEvent(
          timestamp: now.subtract(const Duration(seconds: 5)),
          level: 'INFO',
          message: 'Tagging request returned 2 keys.',
        ),
      ],
      apiCalls: [
        ApiCallRecord(
          timestamp: now.subtract(const Duration(seconds: 12)),
          operation: 'HeadObject',
          status: '200',
          latencyMs: 41,
        ),
        ApiCallRecord(
          timestamp: now.subtract(const Duration(seconds: 5)),
          operation: 'GetObjectTagging',
          status: '200',
          latencyMs: 54,
        ),
      ],
      debugLogExcerpt: [
        'Resolved endpoint ${profile.endpointUrl}',
        'Loaded metadata for $bucketName/$key',
      ],
      rawDiagnostics: const {
        'engineState': 'healthy',
        'progressEvents': 2,
      },
    );
  }

  @override
  Future<void> createFolder({
    required String engineId,
    required EndpointProfile profile,
    required String bucketName,
    required String key,
  }) async {}

  @override
  Future<BatchOperationResult> copyObject({
    required String engineId,
    required EndpointProfile profile,
    required String sourceBucketName,
    required String sourceKey,
    required String destinationBucketName,
    required String destinationKey,
  }) async {
    return const BatchOperationResult(
      successCount: 1,
      failureCount: 0,
      failures: [],
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
  }) async {
    return const BatchOperationResult(
      successCount: 1,
      failureCount: 0,
      failures: [],
    );
  }

  @override
  Future<BatchOperationResult> deleteObjects({
    required String engineId,
    required EndpointProfile profile,
    required String bucketName,
    required List<String> keys,
  }) async {
    return BatchOperationResult(
      successCount: keys.length,
      failureCount: 0,
      failures: const [],
    );
  }

  @override
  Future<BatchOperationResult> deleteObjectVersions({
    required String engineId,
    required EndpointProfile profile,
    required String bucketName,
    required List<ObjectVersionRef> versions,
  }) async {
    return BatchOperationResult(
      successCount: versions.length,
      failureCount: 0,
      failures: const [],
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
  }) async {
    var totalBytes = 0;
    for (final filePath in filePaths) {
      totalBytes += await _fileLengthOrFallback(filePath);
    }
    final strategyLabel = _transferStrategyLabel(
      direction: 'upload',
      totalBytes: totalBytes,
      multipartThresholdMiB: multipartThresholdMiB,
    );
    final partSizeBytes = strategyLabel.startsWith('Multipart')
        ? multipartChunkMiB * 1024 * 1024
        : null;
    final partsTotal = partSizeBytes == null
        ? null
        : (totalBytes / partSizeBytes).ceil().clamp(1, 999999);
    final jobId = 'upload-${DateTime.now().millisecondsSinceEpoch}';
    var job = TransferJob(
      id: jobId,
      label: 'Upload ${filePaths.length} file(s) to $bucketName',
      direction: 'upload',
      progress: 0.0,
      status: 'queued',
      bytesTransferred: 0,
      totalBytes: totalBytes,
      strategyLabel: strategyLabel,
      currentItemLabel: filePaths.isEmpty ? null : filePaths.first,
      itemCount: filePaths.length,
      itemsCompleted: 0,
      partSizeBytes: partSizeBytes,
      partsCompleted: 0,
      partsTotal: partsTotal,
      canPause: true,
      canResume: false,
      canCancel: true,
      outputLines: [
        'Queued ${filePaths.length} file(s) for upload to $bucketName.'
      ],
    );
    _emitTransfer(job);
    await Future<void>.delayed(const Duration(milliseconds: 20));
    job = job.copyWith(
      status: 'running',
      progress: 0.35,
      bytesTransferred: (totalBytes * 0.35).round(),
      currentItemLabel: filePaths.isEmpty ? null : filePaths.first,
      itemsCompleted: filePaths.length > 1 ? 1 : 0,
      partsCompleted: partsTotal == null ? null : (partsTotal * 0.4).ceil(),
      outputLines: [
        ...job.outputLines,
        'Preparing request headers and opening source files.',
        'Transferring ${filePaths.isEmpty ? 'current file' : filePaths.first}.',
      ],
    );
    _emitTransfer(job);
    await Future<void>.delayed(const Duration(milliseconds: 20));
    job = job.copyWith(
      progress: 0.72,
      bytesTransferred: (totalBytes * 0.72).round(),
      currentItemLabel: filePaths.isEmpty ? null : filePaths.last,
      itemsCompleted: filePaths.length > 1 ? filePaths.length - 1 : 0,
      partsCompleted: partsTotal == null ? null : (partsTotal * 0.8).ceil(),
      outputLines: [
        ...job.outputLines,
        if (partSizeBytes != null)
          'Uploading multipart chunks of $multipartChunkMiB MiB.',
        'Upload progress is streaming to the Tasks workspace.',
      ],
    );
    _emitTransfer(job);
    await Future<void>.delayed(const Duration(milliseconds: 20));
    job = job.copyWith(
      status: 'completed',
      progress: 1,
      bytesTransferred: totalBytes,
      currentItemLabel: filePaths.isEmpty ? null : filePaths.last,
      itemsCompleted: filePaths.length,
      partsCompleted: partsTotal,
      canPause: false,
      canResume: false,
      canCancel: false,
      outputLines: [
        ...job.outputLines,
        'Uploaded ${filePaths.length} file(s) into $bucketName.',
      ],
    );
    _emitTransfer(job);
    return job;
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
    final totalBytes = _estimatedDownloadBytes(
      itemCount: keys.length,
      multipartThresholdMiB: multipartThresholdMiB,
      multipartChunkMiB: multipartChunkMiB,
    );
    final strategyLabel = _transferStrategyLabel(
      direction: 'download',
      totalBytes: totalBytes,
      multipartThresholdMiB: multipartThresholdMiB,
    );
    final partSizeBytes = strategyLabel.startsWith('Multipart')
        ? multipartChunkMiB * 1024 * 1024
        : null;
    final partsTotal = partSizeBytes == null
        ? null
        : (totalBytes / partSizeBytes).ceil().clamp(1, 999999);
    final jobId = 'download-${DateTime.now().millisecondsSinceEpoch}';
    var job = TransferJob(
      id: jobId,
      label: 'Download ${keys.length} object(s) to $destinationPath',
      direction: 'download',
      progress: 0.0,
      status: 'queued',
      bytesTransferred: 0,
      totalBytes: totalBytes,
      strategyLabel: strategyLabel,
      currentItemLabel: keys.isEmpty ? null : keys.first,
      itemCount: keys.length,
      itemsCompleted: 0,
      partSizeBytes: partSizeBytes,
      partsCompleted: 0,
      partsTotal: partsTotal,
      canPause: true,
      canResume: false,
      canCancel: true,
      outputLines: [
        'Queued ${keys.length} object(s) for download to $destinationPath.'
      ],
    );
    _emitTransfer(job);
    await Future<void>.delayed(const Duration(milliseconds: 20));
    job = job.copyWith(
      status: 'running',
      progress: 0.4,
      bytesTransferred: (totalBytes * 0.4).round(),
      currentItemLabel: keys.isEmpty ? null : keys.first,
      itemsCompleted: keys.length > 1 ? 1 : 0,
      partsCompleted: partsTotal == null ? null : (partsTotal * 0.45).ceil(),
      outputLines: [
        ...job.outputLines,
        'Opening destination path $destinationPath.',
        'Reading ${keys.isEmpty ? 'current object' : keys.first}.',
      ],
    );
    _emitTransfer(job);
    await Future<void>.delayed(const Duration(milliseconds: 20));
    job = job.copyWith(
      progress: 0.78,
      bytesTransferred: (totalBytes * 0.78).round(),
      currentItemLabel: keys.isEmpty ? null : keys.last,
      itemsCompleted: keys.length > 1 ? keys.length - 1 : 0,
      partsCompleted: partsTotal == null ? null : (partsTotal * 0.85).ceil(),
      outputLines: [
        ...job.outputLines,
        if (partSizeBytes != null)
          'Downloading multipart ranges of $multipartChunkMiB MiB.',
        'Download progress is streaming to the Tasks workspace.',
      ],
    );
    _emitTransfer(job);
    await Future<void>.delayed(const Duration(milliseconds: 20));
    job = job.copyWith(
      status: 'completed',
      progress: 1,
      bytesTransferred: totalBytes,
      currentItemLabel: keys.isEmpty ? null : keys.last,
      itemsCompleted: keys.length,
      partsCompleted: partsTotal,
      canPause: false,
      canResume: false,
      canCancel: false,
      outputLines: [
        ...job.outputLines,
        'Downloaded ${keys.length} object(s) into $destinationPath.',
      ],
    );
    _emitTransfer(job);
    return job;
  }

  @override
  Future<TransferJob> pauseTransfer({
    required String engineId,
    required String jobId,
  }) async {
    final current = _transfers[jobId];
    if (current == null) {
      throw const EngineException(
        code: ErrorCode.invalidConfig,
        message: 'Transfer job was not found.',
      );
    }
    final updated = current.copyWith(
      status: 'paused',
      canPause: false,
      canResume: true,
      outputLines: [...current.outputLines, 'Transfer paused.'],
    );
    _emitTransfer(updated);
    return updated;
  }

  @override
  Future<TransferJob> resumeTransfer({
    required String engineId,
    required String jobId,
  }) async {
    final current = _transfers[jobId];
    if (current == null) {
      throw const EngineException(
        code: ErrorCode.invalidConfig,
        message: 'Transfer job was not found.',
      );
    }
    final updated = current.copyWith(
      status: 'running',
      canPause: true,
      canResume: false,
      outputLines: [...current.outputLines, 'Transfer resumed.'],
    );
    _emitTransfer(updated);
    return updated;
  }

  @override
  Future<TransferJob> cancelTransfer({
    required String engineId,
    required String jobId,
  }) async {
    final current = _transfers[jobId];
    if (current == null) {
      throw const EngineException(
        code: ErrorCode.invalidConfig,
        message: 'Transfer job was not found.',
      );
    }
    final updated = current.copyWith(
      status: 'cancelled',
      progress: 1,
      canPause: false,
      canResume: false,
      canCancel: false,
      outputLines: [...current.outputLines, 'Transfer cancelled.'],
    );
    _emitTransfer(updated);
    return updated;
  }

  void _emitTransfer(TransferJob job) {
    _transfers[job.id] = job;
    _transferSink?.call(job);
  }

  Future<int> _fileLengthOrFallback(String path) async {
    final file = File(path);
    if (await file.exists()) {
      return file.length();
    }
    return 12 * 1024 * 1024;
  }

  int _estimatedDownloadBytes({
    required int itemCount,
    required int multipartThresholdMiB,
    required int multipartChunkMiB,
  }) {
    final thresholdBytes = multipartThresholdMiB * 1024 * 1024;
    final chunkBytes = multipartChunkMiB * 1024 * 1024;
    final baseline = itemCount * 6 * 1024 * 1024;
    if (itemCount <= 1) {
      return baseline
          .clamp(2 * 1024 * 1024, thresholdBytes + chunkBytes)
          .toInt();
    }
    return math.max(baseline, thresholdBytes + (chunkBytes * itemCount));
  }

  String _transferStrategyLabel({
    required String direction,
    required int totalBytes,
    required int multipartThresholdMiB,
  }) {
    final usesMultipart = totalBytes >= multipartThresholdMiB * 1024 * 1024;
    final prefix = usesMultipart ? 'Multipart' : 'Single-part';
    return '$prefix $direction';
  }

  @override
  Future<String> generatePresignedUrl({
    required String engineId,
    required EndpointProfile profile,
    required String bucketName,
    required String key,
    required Duration expiration,
  }) async {
    return '${profile.endpointUrl}/$bucketName/$key?X-Amz-Expires=${expiration.inSeconds}&engine=$engineId';
  }

  @override
  Future<ToolExecutionState> runPutTestData({
    required String engineId,
    required EndpointProfile profile,
    required TestDataToolConfig config,
  }) async {
    await Future<void>.delayed(const Duration(milliseconds: 300));
    return ToolExecutionState(
      label: 'put-testdata',
      running: false,
      lastStatus:
          'Queued ${config.objectCount} objects (${config.versions} versions each) for ${config.bucketName}.',
      jobId: 'tool-put-testdata',
      outputLines: [
        'Using ${config.threads} worker threads.',
        'Checksum algorithm: ${config.checksumAlgorithm}.',
      ],
      exitCode: 0,
    );
  }

  @override
  Future<ToolExecutionState> runDeleteAll({
    required String engineId,
    required EndpointProfile profile,
    required DeleteAllToolConfig config,
  }) async {
    await Future<void>.delayed(const Duration(milliseconds: 300));
    return ToolExecutionState(
      label: 'delete-all',
      running: false,
      lastStatus:
          'Prepared delete-all sweep for ${config.bucketName} with ${config.maxWorkers} workers.',
      jobId: 'tool-delete-all',
      outputLines: [
        'Batch size: ${config.batchSize}.',
        'Pipeline size: ${config.pipelineSize}.',
      ],
      exitCode: 0,
    );
  }

  @override
  Future<ToolExecutionState> cancelToolExecution({
    required String engineId,
    required String jobId,
  }) async {
    return ToolExecutionState(
      label: jobId,
      running: false,
      lastStatus: 'Cancelled tool execution $jobId.',
      jobId: jobId,
      exitCode: 130,
    );
  }

  @override
  Future<BenchmarkRun> startBenchmark({
    required BenchmarkConfig config,
    required EndpointProfile profile,
  }) async {
    final run = BenchmarkRun(
      id: 'bench-${DateTime.now().millisecondsSinceEpoch}',
      config: config,
      status: 'running',
      processedCount: 0,
      startedAt: DateTime.now(),
      averageLatencyMs: 0,
      throughputOpsPerSecond: 0,
      liveLog: const ['Benchmark queued.'],
      activeElapsedSeconds: 0,
    );
    _runs[run.id] = run;
    unawaited(_tickRun(run.id));
    return run;
  }

  Future<void> _tickRun(String runId) async {
    for (var count = 1; count <= 10; count++) {
      await Future<void>.delayed(const Duration(milliseconds: 250));
      final current = _runs[runId];
      if (current == null || current.status == 'stopped') {
        return;
      }
      if (current.status == 'paused') {
        count--;
        continue;
      }
      final processed = count * 120;
      _runs[runId] = current.copyWith(
        status: count == 10 ? 'completed' : 'running',
        processedCount: processed,
        completedAt: count == 10 ? DateTime.now() : current.completedAt,
        averageLatencyMs: 31 + count.toDouble(),
        throughputOpsPerSecond: 2450 + (count * 115).toDouble(),
        activeElapsedSeconds: current.config.testMode == 'duration'
            ? (count * 0.25).clamp(
                0,
                current.config.durationSeconds.toDouble(),
              )
            : current.activeElapsedSeconds,
        liveLog: [
          ...current.liveLog,
          'Processed $processed operations via ${current.config.engineId}.',
        ],
        resultSummary:
            count == 10 ? _summary(processed) : current.resultSummary,
      );
    }
  }

  BenchmarkResultSummary _summary(int processed) {
    final throughputSeries = List<Map<String, Object?>>.generate(
      24,
      (index) {
        final int second = index + 1;
        final int opsPerSecond = 1980 + _random.nextInt(420) + (index * 18);
        final int putOps = (opsPerSecond * 0.38).round();
        final int getOps = (opsPerSecond * 0.36).round();
        final int deleteOps = (opsPerSecond * 0.18).round();
        final int postOps = opsPerSecond - putOps - getOps - deleteOps;
        final avgLatency = 22 + (_random.nextDouble() * 18) + (index * 0.4);
        return <String, Object?>{
          'second': second,
          'label': '${second}s',
          'opsPerSecond': opsPerSecond,
          'bytesPerSecond': opsPerSecond * 65536,
          'averageLatencyMs': double.parse(avgLatency.toStringAsFixed(1)),
          'p95LatencyMs': double.parse((avgLatency * 1.44).toStringAsFixed(1)),
          'operations': <String, int>{
            'PUT': putOps,
            'GET': getOps,
            'DELETE': deleteOps,
            'POST': postOps,
          },
          'latencyByOperationMs': <String, double>{
            'PUT': double.parse((avgLatency * 1.18).toStringAsFixed(1)),
            'GET': double.parse((avgLatency * 0.92).toStringAsFixed(1)),
            'DELETE': double.parse((avgLatency * 0.86).toStringAsFixed(1)),
            'POST': double.parse((avgLatency * 1.06).toStringAsFixed(1)),
          },
        };
      },
    );
    var sequence = 0;
    final latencyTimeline = throughputSeries.expand((point) {
      final second = (point['second'] as num?)?.toInt() ?? 1;
      final latencyByOperation = Map<String, double>.from(
        ((point['latencyByOperationMs'] as Map?) ?? const <String, Object?>{})
            .map(
          (key, value) => MapEntry(key.toString(), (value as num).toDouble()),
        ),
      );
      final operations = latencyByOperation.keys.toList(growable: false);
      return operations.asMap().entries.map((entry) {
        sequence += 1;
        final elapsedSeconds = math.max(second - 1, 0) +
            ((entry.key + 1) / (operations.length + 1));
        return <String, Object?>{
          'sequence': sequence,
          'operation': entry.value,
          'second': second,
          'elapsedMs': double.parse((elapsedSeconds * 1000).toStringAsFixed(1)),
          'label': _timelineLabel(elapsedSeconds),
          'latencyMs': latencyByOperation[entry.value],
          'sizeBytes': const [4096, 65536, 1048576][sequence % 3],
        };
      });
    }).toList(growable: false);
    return BenchmarkResultSummary(
      totalOperations: processed,
      operationsByType: const {
        'PUT': 180,
        'GET': 180,
        'DELETE': 120,
        'POST': 60,
      },
      latencyPercentilesMs: const {
        'p50': 18.4,
        'p75': 27.8,
        'p90': 35.6,
        'p95': 41.2,
        'p99': 63.8,
        'p999': 81.4,
      },
      throughputSeries: throughputSeries,
      sizeLatencyBuckets: const [
        {
          'sizeBytes': 4096,
          'avgLatencyMs': 8.2,
          'p50LatencyMs': 6.7,
          'p95LatencyMs': 9.7,
          'p99LatencyMs': 11.6,
          'count': 140,
        },
        {
          'sizeBytes': 65536,
          'avgLatencyMs': 17.6,
          'p50LatencyMs': 14.4,
          'p95LatencyMs': 20.8,
          'p99LatencyMs': 24.9,
          'count': 140,
        },
        {
          'sizeBytes': 1048576,
          'avgLatencyMs': 42.4,
          'p50LatencyMs': 34.8,
          'p95LatencyMs': 50.0,
          'p99LatencyMs': 60.2,
          'count': 120,
        },
        {
          'sizeBytes': 104857600,
          'avgLatencyMs': 286.2,
          'p50LatencyMs': 234.7,
          'p95LatencyMs': 337.7,
          'p99LatencyMs': 406.4,
          'count': 60,
        },
        {
          'sizeBytes': 1073741824,
          'avgLatencyMs': 1924.5,
          'p50LatencyMs': 1578.1,
          'p95LatencyMs': 2270.9,
          'p99LatencyMs': 2732.8,
          'count': 20,
        },
      ],
      checksumStats: const {
        'validated_success': 480,
        'validated_failure': 0,
        'not_used': 0,
      },
      detailMetrics: <String, Object?>{
        'sampleCount': throughputSeries.length,
        'sampleWindowSeconds': 1,
        'averageOpsPerSecond': 2248.6,
        'peakOpsPerSecond': 2749,
        'averageBytesPerSecond': 147364249.6,
        'peakBytesPerSecond': 180158464,
        'averageObjectSizeBytes': 29442048,
        'checksumValidated': 480,
        'errorCount': 0,
        'retryCount': 3,
      },
      latencyPercentilesByOperationMs: const <String, Map<String, double>>{
        'PUT': {
          'p50': 21.7,
          'p75': 32.8,
          'p90': 42.0,
          'p95': 48.6,
          'p99': 75.3,
          'p999': 96.1,
        },
        'GET': {
          'p50': 16.9,
          'p75': 25.6,
          'p90': 32.8,
          'p95': 37.9,
          'p99': 58.7,
          'p999': 74.9,
        },
        'DELETE': {
          'p50': 15.8,
          'p75': 23.9,
          'p90': 30.6,
          'p95': 35.4,
          'p99': 54.9,
          'p999': 70.0,
        },
        'POST': {
          'p50': 19.5,
          'p75': 29.5,
          'p90': 37.7,
          'p95': 43.7,
          'p99': 67.6,
          'p999': 86.3,
        },
      },
      operationDetails: const <Map<String, Object?>>[
        {
          'operation': 'PUT',
          'count': 180,
          'sharePct': 33.3,
          'avgOpsPerSecond': 856.0,
          'peakOpsPerSecond': 1039.0,
          'avgLatencyMs': 32.8,
          'p50LatencyMs': 21.7,
          'p95LatencyMs': 48.6,
          'p99LatencyMs': 75.3,
        },
        {
          'operation': 'GET',
          'count': 180,
          'sharePct': 33.3,
          'avgOpsPerSecond': 809.0,
          'peakOpsPerSecond': 982.0,
          'avgLatencyMs': 25.6,
          'p50LatencyMs': 16.9,
          'p95LatencyMs': 37.9,
          'p99LatencyMs': 58.7,
        },
        {
          'operation': 'DELETE',
          'count': 120,
          'sharePct': 22.2,
          'avgOpsPerSecond': 404.0,
          'peakOpsPerSecond': 491.0,
          'avgLatencyMs': 23.9,
          'p50LatencyMs': 15.8,
          'p95LatencyMs': 35.4,
          'p99LatencyMs': 54.9,
        },
        {
          'operation': 'POST',
          'count': 60,
          'sharePct': 11.1,
          'avgOpsPerSecond': 179.0,
          'peakOpsPerSecond': 237.0,
          'avgLatencyMs': 29.5,
          'p50LatencyMs': 19.5,
          'p95LatencyMs': 43.7,
          'p99LatencyMs': 67.6,
        },
      ],
      latencyTimeline: latencyTimeline,
    );
  }

  String _timelineLabel(double elapsedSeconds) {
    final fractionDigits = elapsedSeconds >= 100
        ? 0
        : elapsedSeconds >= 10
            ? 1
            : 2;
    return '${elapsedSeconds.toStringAsFixed(fractionDigits)}s';
  }

  @override
  Future<BenchmarkRun> getBenchmarkStatus(String runId) async {
    return _runs[runId] ??
        BenchmarkRun(
          id: runId,
          config: const BenchmarkConfig(
            profileId: 'default',
            engineId: 'rust',
            bucketName: 'benchmark-scratch',
            prefix: 'benchmark/',
            workloadType: 'mixed',
            deleteMode: 'single',
            objectSizes: [1024],
            concurrentThreads: 4,
            testMode: 'duration',
            operationCount: 500,
            durationSeconds: 60,
            validateChecksum: true,
            checksumAlgorithm: 'crc32c',
            randomData: true,
            inMemoryData: false,
            objectCount: 500,
            connectTimeoutSeconds: 5,
            readTimeoutSeconds: 60,
            maxAttempts: 5,
            maxPoolConnections: 200,
            dataCacheMb: 0,
            csvOutputPath: 'results.csv',
            jsonOutputPath: 'results.json',
            logFilePath: 'benchmark.log',
            debugMode: false,
          ),
          status: 'unknown',
          processedCount: 0,
          startedAt: DateTime.now(),
          averageLatencyMs: 0,
          throughputOpsPerSecond: 0,
          liveLog: const [],
          activeElapsedSeconds: 0,
        );
  }

  @override
  Future<void> pauseBenchmark(String runId) async {
    final run = _runs[runId];
    if (run == null) {
      return;
    }
    _runs[runId] = run.copyWith(
      status: 'paused',
      liveLog: [...run.liveLog, 'Benchmark paused by user.'],
    );
  }

  @override
  Future<void> resumeBenchmark(String runId) async {
    final run = _runs[runId];
    if (run == null) {
      return;
    }
    _runs[runId] = run.copyWith(
      status: 'running',
      liveLog: [...run.liveLog, 'Benchmark resumed by user.'],
    );
    unawaited(_tickRun(run.id));
  }

  @override
  Future<void> stopBenchmark(String runId) async {
    final run = _runs[runId];
    if (run == null) {
      return;
    }
    _runs[runId] = run.copyWith(
      status: 'stopped',
      completedAt: DateTime.now(),
      liveLog: [...run.liveLog, 'Benchmark stopped by user.'],
      resultSummary: _summary(run.processedCount),
    );
  }

  @override
  Future<BenchmarkExportBundle> exportBenchmarkResults({
    required String runId,
    required String format,
  }) async {
    final run = await getBenchmarkStatus(runId);
    return BenchmarkExportBundle(
      format: format,
      path: format == 'csv'
          ? run.config.csvOutputPath
          : run.config.jsonOutputPath,
      summary: run.resultSummary,
    );
  }

  BucketAdminState _bucketAdminState(String bucketName) {
    return BucketAdminState(
      bucketName: bucketName,
      versioningEnabled: bucketName != 'benchmark-scratch',
      versioningStatus:
          bucketName == 'benchmark-scratch' ? 'Suspended' : 'Enabled',
      objectLockEnabled: bucketName == 'archive-vault',
      lifecycleEnabled: true,
      policyAttached: true,
      corsEnabled: true,
      encryptionEnabled: true,
      encryptionSummary: 'SSE-S3 default encryption with bucket keys enabled',
      objectLockMode: bucketName == 'archive-vault' ? 'GOVERNANCE' : null,
      objectLockRetentionDays: bucketName == 'archive-vault' ? 30 : null,
      tags: const {
        'owner': 'platform-team',
        'environment': 'dev',
        'compliance': 'archive',
      },
      lifecycleRules: const [
        LifecycleRule(
          id: 'archive-images',
          enabled: true,
          prefix: 'images/',
          transitionStorageClass: 'GLACIER_IR',
          transitionDays: 30,
          expirationDays: 365,
          abortIncompleteMultipartUploadDays: 7,
        ),
        LifecycleRule(
          id: 'trim-noncurrent',
          enabled: true,
          prefix: 'docs/',
          nonCurrentExpirationDays: 45,
          nonCurrentTransitionStorageClass: 'STANDARD_IA',
          nonCurrentTransitionDays: 7,
        ),
      ],
      policyJson: '''{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "AllowAppReadWrite",
      "Effect": "Allow",
      "Principal": {"AWS": "arn:aws:iam::123456789012:role/app-role"},
      "Action": ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"],
      "Resource": ["arn:aws:s3:::$bucketName/*"]
    }
  ]
}''',
      corsJson: '''[
  {
    "AllowedOrigins": ["*"],
    "AllowedMethods": ["GET", "PUT", "HEAD"],
    "AllowedHeaders": ["*"],
    "ExposeHeaders": ["ETag"],
    "MaxAgeSeconds": 3000
  }
]''',
      lifecycleJson: '''{
  "Rules": [
    {
      "ID": "archive-images",
      "Status": "Enabled",
      "Prefix": "images/"
    }
  ]
}''',
      encryptionJson: '''{
  "Rules": [
    {
      "ApplyServerSideEncryptionByDefault": {
        "SSEAlgorithm": "AES256"
      }
    }
  ]
}''',
      apiCalls: [
        ApiCallRecord(
          timestamp: DateTime.now().subtract(const Duration(seconds: 4)),
          operation: 'GetBucketLifecycleConfiguration',
          status: '200',
          latencyMs: 29,
        ),
        ApiCallRecord(
          timestamp: DateTime.now().subtract(const Duration(seconds: 2)),
          operation: 'GetBucketPolicy',
          status: '200',
          latencyMs: 31,
        ),
      ],
    );
  }
}
