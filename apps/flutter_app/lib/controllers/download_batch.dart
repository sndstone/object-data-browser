import '../models/domain_models.dart';
import '../services/engine_service.dart';
import '../services/listing_cancellation.dart';

/// Groups mixed plaintext/encrypted downloads without retaining decrypt keys.
/// Each encrypted child unwraps its header only when it is dispatched.
class DownloadBatch {
  DownloadBatch(
      {required this.id,
      required this.keys,
      required this.engine,
      required this.engineId,
      required this.dispatch,
      required this.onUpdate});
  final String id, engineId;
  final List<String> keys;
  final EngineService engine;
  final Future<TransferJob> Function(String key) dispatch;
  final void Function(TransferJob) onUpdate;
  final Set<String> _children = {};
  TransferJob? _child;
  int _index = -1, _completed = 0, _bytes = 0;
  bool _dispatching = false, _cancelled = false, _done = false;

  TransferJob _snapshot(String status) => TransferJob(
      id: id,
      label: 'Download ${keys.length} objects',
      direction: 'download',
      status: status,
      progress: keys.isEmpty ? 1 : _completed / keys.length,
      bytesTransferred: _bytes + (_child?.bytesTransferred ?? 0),
      totalBytes: status == 'completed' ? _bytes : 0,
      itemCount: keys.length,
      itemsCompleted: _completed,
      currentItemLabel: _index < 0
          ? 'Preparing objects'
          : '${_index + 1}/${keys.length} · ${keys[_index]}',
      canCancel: !_done && !_cancelled,
      canPause: false,
      canResume: false,
      outputLines: [if (_child != null) ..._child!.outputLines.take(8)]);

  bool consume(TransferJob job) {
    if (_children.contains(job.id) && (!_dispatching || _child?.id != job.id)) {
      return true;
    }
    if (!_dispatching ||
        job.direction != 'download' ||
        (_child != null && job.id != _child!.id)) {
      return false;
    }
    _children.add(job.id);
    _child = job;
    onUpdate(_snapshot(_cancelled ? 'cancelling' : 'running'));
    return true;
  }

  Future<TransferJob> run() async {
    var status = 'completed';
    onUpdate(_snapshot('running'));
    try {
      for (var i = 0; i < keys.length; i++) {
        if (_cancelled) {
          status = 'cancelled';
          break;
        }
        _index = i;
        _child = null;
        _dispatching = true;
        final job = await dispatch(keys[i]);
        consume(job);
        _dispatching = false;
        if (job.status != 'completed') {
          status = job.status;
          break;
        }
        _completed++;
        _bytes += job.bytesTransferred;
        _child = null;
      }
    } on ListingCancelled {
      status = 'cancelled';
    } catch (_) {
      status = 'failed';
      rethrow;
    } finally {
      _dispatching = false;
      _done = true;
      onUpdate(_snapshot(status));
    }
    return _snapshot(status);
  }

  Future<void> cancel() async {
    _cancelled = true;
    final child = _child;
    if (!_done) onUpdate(_snapshot('cancelling'));
    if (_dispatching && child != null && child.canCancel) {
      consume(await engine.cancelTransfer(engineId: engineId, jobId: child.id));
    }
  }
}
