import '../models/domain_models.dart';

/// Batch selection is independent of the single object inspected by the UI.
class ObjectSelection {
  final Set<String> _keys = {};
  String? _anchor;
  int revision = 0;
  Set<String>? _snapshot;
  Set<String> get keys => _snapshot ??= Set.unmodifiable(_keys);
  bool get isEmpty => _keys.isEmpty;
  void _changed() {
    revision++;
    _snapshot = null;
  }

  void clear() {
    if (_keys.isNotEmpty) {
      _keys.clear();
      _changed();
    }
    _anchor = null;
  }

  void retain(Iterable<String> keys) {
    final before = _keys.length;
    _keys.retainAll(keys);
    if (_keys.length != before) _changed();
  }

  void removeAll(Iterable<String> keys) {
    final before = _keys.length;
    _keys.removeAll(keys);
    if (_keys.length != before) _changed();
  }

  void selectAll(Iterable<ObjectEntry> objects) {
    final before = _keys.length;
    _keys.addAll(objects.where((o) => !o.isFolder).map((o) => o.key));
    if (_keys.length != before) _changed();
  }

  void toggle(ObjectEntry object, List<ObjectEntry> visible,
      {bool range = false}) {
    if (object.isFolder) return;
    if (range) {
      final start = visible.indexWhere((o) => o.key == _anchor);
      final end = visible.indexWhere((o) => o.key == object.key);
      if (start >= 0 && end >= 0) {
        selectAll(visible.sublist(
            start < end ? start : end, (start > end ? start : end) + 1));
        _anchor = object.key;
        return;
      }
    }
    if (!_keys.remove(object.key)) _keys.add(object.key);
    _changed();
    _anchor = object.key;
  }

  /// Batch contracts name failures, not successes. Infer successful targets
  /// only when counts and failure identities completely reconcile.
  static Set<String> confirmedDeletes(
      List<String> keys, BatchOperationResult result) {
    final failed = result.failures.map((f) => f.target).toSet();
    if (result.failureCount != failed.length ||
        result.successCount + result.failureCount != keys.length ||
        (failed.isNotEmpty && !keys.toSet().containsAll(failed))) {
      return {};
    }
    return keys.where((key) => !failed.contains(key)).toSet();
  }
}
