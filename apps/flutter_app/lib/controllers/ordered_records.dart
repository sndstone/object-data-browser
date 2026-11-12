import 'dart:collection';

/// O(1) job updates; immutable newest-first snapshots materialize only when a
/// view actually reads history, rather than on every engine progress event.
class OrderedRecords<T> {
  OrderedRecords(this.idOf);
  final String Function(T) idOf;
  final LinkedHashMap<String, T> _records = LinkedHashMap();
  List<T>? _snapshot;
  T? byId(String id) => _records[id];
  List<T> get snapshot =>
      _snapshot ??= List<T>.unmodifiable(_records.values.toList().reversed);
  void upsert(T record) {
    final id = idOf(record);
    _records.remove(id);
    _records[id] = record;
    _snapshot = null;
  }

  void replace(Iterable<T> records) {
    final values = records.toList();
    _records.clear();
    for (final record in values.reversed) {
      _records[idOf(record)] = record;
    }
    _snapshot = null;
  }
}
