import '../services/client_encryption.dart';
import '../services/crypto/age.dart';
import '../services/vault_name_codec.dart';
import '../services/diagnostic_safety.dart';
import 'dart:io';
import 'action_scope.dart';
import '../services/listing_cancellation.dart';
import '../models/domain_models.dart';
import '../services/engine_service.dart';
import '../services/multipart_sizing.dart';

/// One user operation, one independently sized engine request per file.
/// Sequential files preserve the engine's bounded parallel *part* workers
/// without multiplying those workers by the selected file count.
class UploadBatch {
  UploadBatch(
      {this.encryption,
      this.encodeName,
      required this.engine,
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
  final ObjectEncryption? encryption;
  final Future<String> Function(ClientEncryptionRule, String)? encodeName;
  final Map<String, String> _storedKeys = {};
  final Set<String> _nameEncryptedPaths = {};
  String storedKeyFor(String path) =>
      _storedKeys[path] ??
      '$prefix${objectKeys[path] ?? path.split(Platform.pathSeparator).last}';
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
  bool _dispatching = false,
      _cancelled = false,
      _done = false,
      _unknown = false;
  int _totalBytes = 0;
  int get totalBytes => _totalBytes;
  String? get childId => _child?.id;

  Future<void> prepare() async {
    _storedKeys.clear();
    _nameEncryptedPaths.clear();
    _sizes.clear();
    _chunks.clear();
    _totalBytes = 0;
    // Validate every file before causing any external mutation.
    for (final path in paths) {
      final name = objectKeys[path] ?? path.split(Platform.pathSeparator).last;
      final key = '$prefix$name';
      // Engines may read a name differently from how it is matched here.
      if (vaultTargetIsAmbiguous(profile.clientEncryptionRules, bucket, key,
          uploadPrefix: prefix, uploadName: name)) {
        throw const FormatException(vaultAmbiguousTarget);
      }
      final rule = matchingClientEncryptionRule(
        profile.clientEncryptionRules,
        bucket,
        key,
      );
      if (rule != null) {
        if (rule.policy == ClientEncryptionPolicy.unsupported) {
          throw const FormatException(vaultPolicyUnsupported);
        }
        if (rule.encryptsNames && encodeName == null) {
          throw const FormatException(vaultNamesLocked);
        }
        if (rule.encryptsNames) _nameEncryptedPaths.add(path);
        _storedKeys[path] = rule.encryptsNames
            ? await encodeName!(rule,
                objectKeys[path] ?? path.split(Platform.pathSeparator).last)
            : validateStoredKey('$key.age');
      } else {
        _storedKeys[path] = validateStoredKey(key);
      }
      final int plaintextSize;
      try {
        plaintextSize = await File(path).length();
      } catch (_) {
        if (rule?.encryptsNames == true) {
          throw const FormatException(
              'Cannot read a file selected for this vault upload.');
        }
        rethrow;
      }
      // Measure a fresh header without retaining its key. The dispatched
      // attempt creates its own fresh header, key and nonce.
      final encryptedSizing = rule == null
          ? null
          : await withClientUpload(
              rule,
              (_, headerLength) async => (
                    size: ageCiphertextLength(
                        headerLength: headerLength,
                        plaintextLength: plaintextSize),
                    chunk: clientUploadPartSizeMiB(
                        headerLength: headerLength,
                        plaintextLength: plaintextSize,
                        automatic: settings.dynamicMultipartSizing,
                        manualMiB: settings.multipartChunkMiB)
                  ));
      final size = encryptedSizing?.size ?? plaintextSize;
      final automatic = MultipartSizing.recommendedPartSizeMiB(size);
      final chunk = encryptedSizing?.chunk ??
          (settings.dynamicMultipartSizing
              ? automatic
              : MultipartSizing.compliantManualPartSizeMiB(
                  settings.multipartChunkMiB));
      if (MultipartSizing.partCount(fileSizeBytes: size, partSizeMiB: chunk) >
          MultipartSizing.maximumParts) {
        throw ArgumentError(
            'Manual part size is too small; enable automatic sizing or increase it.');
      }
      _sizes.add(size);
      _totalBytes += size;
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
            : '${_index + 1}/${paths.length} · ${_nameEncryptedPaths.contains(paths[_index]) ? storedKeyFor(paths[_index]) : paths[_index].split(Platform.pathSeparator).last}',
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

  String _safeText(String text) =>
      DiagnosticSafety.forNameEncryptedRequest(text, {
        'objectKeyByPath': {
          for (final path in _nameEncryptedPaths) path: _storedKeys[path]
        }
      }) as String;

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
    job = job.copyWith(
        label: _safeText(job.label),
        currentItemLabel: job.currentItemLabel == null
            ? null
            : _safeText(job.currentItemLabel!),
        outputLines: job.outputLines.map(_safeText).toList());
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
        Future<TransferJob> dispatch(
          Map<String, Object?>? clientEncryption,
        ) =>
            engine.startUpload(
              clientEncryption: clientEncryption,
              encryption: encryption,
              engineId: engineId,
              profile: profile,
              bucketName: bucket,
              prefix: prefix,
              filePaths: [paths[i]],
              objectKeyByPath: {
                if (clientEncryption != null ||
                    objectKeys.containsKey(paths[i]))
                  paths[i]: storedKeyFor(paths[i]).substring(prefix.length)
              },
              multipartThresholdMiB: settings.multipartThresholdMiB,
              multipartChunkMiB: _chunks[i],
            );
        final key =
            '$prefix${objectKeys[paths[i]] ?? paths[i].split(Platform.pathSeparator).last}';
        final rule = matchingClientEncryptionRule(
          profile.clientEncryptionRules,
          bucket,
          key,
        );
        final result = rule == null
            ? await dispatch(null)
            : await withClientUpload(rule, (payload, _) => dispatch(payload));
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
              ? 'File upload did not complete: ${storedKeyFor(paths[i])}'
              : _safeText(result.outputLines.last);
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
                : _safeText(result.outputLines.last),
            result);
      } on ListingCancelled {
        _cancelled = true;
        _unknown = ActionScope.current?.outcomeUnknown ?? false;
        onFile(
            i,
            paths[i],
            _unknown ? 'unknown' : 'cancelled',
            _unknown
                ? 'Upload completion was not confirmed. Inspect the destination before retrying.'
                : 'Upload cancelled.',
            _child);
      } catch (error) {
        _failed++;
        _failureMessage = _safeText(error.toString());
        onFile(i, paths[i], 'failed', _failureMessage!, _child);
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
        status: _unknown
            ? 'unknown'
            : _failed > 0
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
