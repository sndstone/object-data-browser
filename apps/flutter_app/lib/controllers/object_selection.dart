import '../models/domain_models.dart';

/// Batch selection is independent of the single object inspected by the UI.
class ObjectSelection {
  final Set<String> _keys = {};
  String? _anchor;
  Set<String> get keys => Set.unmodifiable(_keys);
  bool get isEmpty => _keys.isEmpty;
  void clear() {
    _keys.clear();
    _anchor = null;
  }

  void retain(Iterable<String> keys) => _keys.retainAll(keys);
  void removeAll(Iterable<String> keys) => _keys.removeAll(keys);
  void selectAll(Iterable<ObjectEntry> objects) {
    _keys.addAll(objects.where((o) => !o.isFolder).map((o) => o.key));
  }

  void toggle(ObjectEntry object, List<ObjectEntry> visible,
      {bool range = false}) {
    if (object.isFolder) return;
    final start = visible.indexWhere((o) => o.key == _anchor);
    final end = visible.indexWhere((o) => o.key == object.key);
    if (range && start >= 0 && end >= 0) {
      selectAll(visible.sublist(
          start < end ? start : end, (start > end ? start : end) + 1));
    } else if (!_keys.remove(object.key)) {
      _keys.add(object.key);
    }
    _anchor = object.key;
  }

  /// Batch contracts name failures, not successes. Infer successful targets
  /// only when counts and failure identities completely reconcile.
  static Set<String> confirmedDeletes(
      List<String> keys, BatchOperationResult result) {
    final failed = result.failures.map((f) => f.target).toSet();
    if (result.failureCount != failed.length ||
        result.successCount + result.failureCount != keys.length ||
        !failed.every(keys.contains)) {
      return {};
    }
    return keys.where((key) => !failed.contains(key)).toSet();
  }
}
