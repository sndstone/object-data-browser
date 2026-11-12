import 'dart:collection';

/// Complete user-visible history with compact wire deltas. Prefix snapshots
/// share append-only storage without copying the full history on each event.
class TransferLogAccumulator {
  final Map<String, List<String>> _logs = {};
  final Map<String, AppendOnlyPrefix<String>> _views = {};
  int get activeJobCount => _logs.length;
  void forget(String id) {
    _logs.remove(id);
    _views.remove(id);
  }

  List<String>? accept(Map<String, Object?> job) {
    final id = job['id']?.toString();
    if (id == null) return null;
    final lines = List<String>.from(job['outputLines'] as List? ?? const []);
    final start = job['outputStartLine'];
    if (start == null) {
      final existing = _logs[id];
      var same = existing != null && existing.length == lines.length;
      for (var i = 0; same && i < lines.length; i++) {
        same = existing![i] == lines[i];
      }
      if (!same) {
        _logs[id] = lines;
        _views.remove(id);
      }
    } else {
      if (start is! int ||
          start < 0 ||
          job['outputLineCount'] != start + lines.length) {
        return null;
      }
      final log = _logs.putIfAbsent(id, () => []);
      if (start > log.length) return null;
      final overlap = log.length - start;
      if (overlap < lines.length) log.addAll(lines.skip(overlap));
    }
    final log = _logs[id]!;
    final previous = _views[id];
    final view = previous != null && previous.length == log.length
        ? previous
        : AppendOnlyPrefix<String>(log, log.length);
    _views[id] = view;
    if (!['queued', 'running', 'paused', 'cancelling']
        .contains(job['status'])) {
      _logs.remove(id);
      _views.remove(id);
    }
    return view;
  }

  void clear() {
    _logs.clear();
    _views.clear();
  }
}

class AppendOnlyPrefix<T> extends ListBase<T> {
  AppendOnlyPrefix(this._source, this._length);
  final List<T> _source;
  final int _length;
  @override
  int get length => _length;
  @override
  set length(int value) => throw UnsupportedError('Immutable log snapshot');
  @override
  T operator [](int index) {
    RangeError.checkValidIndex(index, this);
    return _source[index];
  }

  @override
  void operator []=(int index, T value) =>
      throw UnsupportedError('Immutable log snapshot');
}
