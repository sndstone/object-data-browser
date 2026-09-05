import 'dart:io';
import '../models/domain_models.dart';
import '../services/engine_service.dart';
import '../services/multipart_sizing.dart';

/// One user operation, one independently sized engine request per file.
/// Sequential files preserve the engine's bounded parallel *part* workers
/// without multiplying those workers by the selected file count.
class UploadBatch {
  UploadBatch(
      {required this.engine,
      required this.engineId,
      required this.profile,
      required this.bucket,
      required this.prefix,
      required this.paths,
      required this.objectKeys,
      required this.settings,
      required this.onUpdate,
      required this.onFile,
      required this.id});
  final EngineService engine;
  final String engineId, bucket, prefix, id;
  final EndpointProfile profile;
  final AppSettings settings;
  final List<String> paths;
  final Map<String, String> objectKeys;
  final void Function(TransferJob) onUpdate;
  final void Function(int index, String path, String status, String message,
      TransferJob? job) onFile;
  final Set<String> _childIds = {};
  final List<int> _sizes = [], _chunks = [];
  TransferJob? _child;
  int _index = -1, _finishedBytes = 0, _completed = 0, _failed = 0;
  int _currentBytes = 0;
  String? _failureMessage;
  bool _dispatching = false, _cancelled = false, _done = false;
  int get totalBytes => _sizes.fold(0, (a, b) => a + b);
  String? get childId => _child?.id;

  Future<void> prepare() async {
    // Validate every file before causing any external mutation.
    for (final path in paths) {
      final size = await File(path).length();
      final automatic = MultipartSizing.recommendedPartSizeMiB(size);
      final chunk = settings.dynamicMultipartSizing
          ? automatic
          : MultipartSizing.compliantManualPartSizeMiB(
              settings.multipartChunkMiB);
      if (MultipartSizing.partCount(fileSizeBytes: size, partSizeMiB: chunk) >
          MultipartSizing.maximumParts) {
        throw ArgumentError(
            'Manual part size is too small for $path; enable automatic sizing or increase it.');
      }
      _sizes.add(size);
      _chunks.add(chunk);
    }
  }

  TransferJob _snapshot({String? status}) {
    final state = status ??
        (_cancelled
            ? 'cancelling'
            : _child?.status == 'paused'
                ? 'paused'
                : 'running');
    final active = !_done;
    final bytes = _finishedBytes + _currentBytes;
    return TransferJob(
        id: id,
        label: 'Upload ${paths.length} files to $bucket',
        direction: 'upload',
        status: state,
        progress: totalBytes > 0
            ? (bytes / totalBytes).clamp(0, 1)
            : (_completed / paths.length),
        bytesTransferred: bytes,
        totalBytes: totalBytes,
        strategyLabel: 'Per-file upload · bounded part workers',
        currentItemLabel: _index < 0
            ? 'Preparing files'
            : '${_index + 1}/${paths.length} · ${paths[_index].split(Platform.pathSeparator).last}',
        itemCount: paths.length,
        itemsCompleted: _completed,
        partSizeBytes: _child?.partSizeBytes,
        partsCompleted: _child?.partsCompleted,
        partsTotal: _child?.partsTotal,
        canPause: active && !_cancelled && (_child?.canPause ?? false),
        canResume: active && !_cancelled && (_child?.canResume ?? false),
        canCancel: active && !_cancelled,
        outputLines: [
          '$_completed/${paths.length} files completed; $_failed failed.',
          if (_cancelled)
            'Remaining files stopped. An in-flight request may finish before cancellation takes effect.',
          if (_child != null) ..._child!.outputLines.take(8),
          if (_failureMessage != null) _failureMessage!,
        ]);
  }

  bool consume(TransferJob job) {
    if (_childIds.contains(job.id) && (!_dispatching || _child?.id != job.id)) {
      return true;
    }
    if (!_dispatching ||
        job.direction != 'upload' ||
        (_child != null && _child!.id != job.id)) {
      return false;
    }
    _childIds.add(job.id);
    _child = job;
    // Multipart retries or control responses must not move aggregate bytes backwards.
    final bytes = job.bytesTransferred.clamp(0, _sizes[_index]);
    if (bytes > _currentBytes) _currentBytes = bytes;
    onUpdate(_snapshot());
    return true;
  }

  Future<TransferJob> run() async {
    onUpdate(_snapshot());
    for (var i = 0; i < paths.length; i++) {
      if (_cancelled) break;
      _index = i;
      _child = null;
      _currentBytes = 0;
      _dispatching = true;
      onFile(
          i,
          paths[i],
          'running',
          'Uploading independently with ${_chunks[i]} MiB ${settings.dynamicMultipartSizing ? 'automatic' : 'manual'} parts when multipart is required.',
          null);
      onUpdate(_snapshot());
      try {
        final result = await engine.startUpload(
            engineId: engineId,
            profile: profile,
            bucketName: bucket,
            prefix: prefix,
            filePaths: [paths[i]],
            objectKeyByPath: {
              if (objectKeys.containsKey(paths[i]))
                paths[i]: objectKeys[paths[i]]!
            },
            multipartThresholdMiB: settings.multipartThresholdMiB,
            multipartChunkMiB: _chunks[i]);
        consume(result);
        if (result.status == 'completed') {
          _completed++;
          _currentBytes = _sizes[i];
        } else if (result.status == 'cancelled' ||
            result.status == 'canceled') {
          _cancelled = true;
        } else {
          _failed++;
          _failureMessage = result.outputLines.isEmpty
              ? 'File upload did not complete: ${paths[i]}'
              : result.outputLines.last;
          // A nonterminal response cannot authorize scheduling another file.
          if (!['failed', 'error'].contains(result.status)) {
            _cancelled = true;
          }
        }
        onFile(
            i,
            paths[i],
            result.status,
            result.outputLines.isEmpty
                ? result.status
                : result.outputLines.last,
            result);
      } catch (error) {
        _failed++;
        _failureMessage = error.toString();
        onFile(i, paths[i], 'failed', error.toString(), _child);
        // Unknown engine/process outcomes must stop the batch, not schedule
        // another request while an earlier upload might still be executing.
        _cancelled = true;
      } finally {
        _dispatching = false;
        _finishedBytes += _currentBytes;
        _currentBytes = 0;
      }
    }
    for (var i = _index + 1; i < paths.length; i++) {
      onFile(i, paths[i], 'not started',
          'Not sent because the upload batch stopped.', null);
    }
    _done = true;
    final result = _snapshot(
        status: _failed > 0
            ? 'failed'
            : _cancelled
                ? 'cancelled'
                : 'completed');
    onUpdate(result);
    return result;
  }

  Future<void> control(String action) async {
    if (_done) return;
    final child = _child;
    if (action == 'cancel') {
      _cancelled = true; // Stop queued files even on sequential engines.
      onUpdate(_snapshot());
      if (child == null || !child.canCancel || !_dispatching) return;
    } else if (child == null || !_dispatching) {
      return;
    }
    final result = switch (action) {
      'pause' =>
        await engine.pauseTransfer(engineId: engineId, jobId: child.id),
      'resume' =>
        await engine.resumeTransfer(engineId: engineId, jobId: child.id),
      _ => await engine.cancelTransfer(engineId: engineId, jobId: child.id),
    };
    consume(result);
  }
}
