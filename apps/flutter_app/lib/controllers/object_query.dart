import 'dart:async';
import 'dart:isolate';
import '../models/domain_models.dart';
import '../services/source_preview.dart';

class ObjectQuery {
  ObjectQuery(this.onChanged);
  final void Function(String? error) onChanged;
  Object? _signature;
  List<ObjectEntry>? _input;
  List<ObjectEntry> _result = const [];
  Isolate? _worker;
  ReceivePort? _port;
  bool loading = false;
  int _generation = 0;
  bool _disposed = false;

  List<ObjectEntry> resolve(List<ObjectEntry> objects, BrowserFilterMode mode,
      String value, BrowserObjectSortField sort, bool descending) {
    final signature = (objects, mode, value, sort, descending);
    if (_signature == signature) return _result;
    _signature = signature;
    final generation = ++_generation;
    _worker?.kill(priority: Isolate.immediate);
    _port?.close();
    if (!identical(objects, _input)) _result = const [];
    _input = objects;
    final spec = (objects, mode, value, sort, descending);
    if (mode != BrowserFilterMode.regex && objects.length < 5000) {
      loading = false;
      return _result = queryObjects(spec);
    }
    loading = true;
    // Keep build synchronous; work and completion notifications happen later.
    scheduleMicrotask(() async {
      if (_disposed || generation != _generation) return;
      final port = ReceivePort();
      _port = port;
      Isolate? worker;
      try {
        worker = await Isolate.spawn(_queryWorker, (port.sendPort, spec));
        if (_disposed || generation != _generation) return;
        _worker = worker;
        final message = await port.first.timeout(const Duration(seconds: 2));
        if (_disposed || generation != _generation) return;
        if (message is String) throw FormatException(message);
        _result = (message as List).cast<ObjectEntry>();
        loading = false;
        onChanged(null);
      } catch (_) {
        if (!_disposed && generation == _generation) {
          loading = false;
          onChanged(
              'This filter exceeded its execution budget or is invalid. Simplify it; previous results are retained.');
        }
      } finally {
        worker?.kill(priority: Isolate.immediate);
        port.close();
      }
    });
    return _result;
  }

  void dispose() {
    _disposed = true;
    _generation++;
    _worker?.kill(priority: Isolate.immediate);
    _port?.close();
  }
}

typedef ObjectQuerySpec = (
  List<ObjectEntry>,
  BrowserFilterMode,
  String,
  BrowserObjectSortField,
  bool
);
void _queryWorker((SendPort, ObjectQuerySpec) message) {
  try {
    message.$1.send(queryObjects(message.$2));
  } catch (error) {
    message.$1.send(error.toString());
  }
}

List<ObjectEntry> queryObjects(ObjectQuerySpec spec) {
  final (objects, mode, value, sort, descending) = spec;
  final regex = mode == BrowserFilterMode.regex && value.isNotEmpty
      ? RegExp(value, caseSensitive: false)
      : null;
  final query = value.toLowerCase();
  final result = objects
      .where((o) =>
          mode == BrowserFilterMode.prefix ||
          query.isEmpty ||
          (regex != null
              ? regex.hasMatch(o.key)
              : o.key.toLowerCase().contains(query)))
      .toList();
  result.sort((a, b) {
    if (a.isFolder != b.isFolder) return a.isFolder ? -1 : 1;
    final comparison = switch (sort) {
      BrowserObjectSortField.name =>
        a.name.toLowerCase().compareTo(b.name.toLowerCase()),
      BrowserObjectSortField.size => a.size.compareTo(b.size),
      BrowserObjectSortField.lastModified =>
        a.modifiedAt.compareTo(b.modifiedAt),
      BrowserObjectSortField.contentType =>
        queryContentType(a).compareTo(queryContentType(b)),
    };
    return comparison == 0
        ? a.name.toLowerCase().compareTo(b.name.toLowerCase())
        : comparison * (descending ? -1 : 1);
  });
  return result;
}

String queryContentType(ObjectEntry object) {
  if (object.isFolder) return 'inode/directory';
  final key = object.name.toLowerCase();
  const types = {
    'json': 'application/json',
    'csv': 'text/csv',
    'html': 'text/html',
    'htm': 'text/html',
    'xml': 'application/xml',
    'css': 'text/css',
    'js': 'text/javascript',
    'mjs': 'text/javascript',
    'jsx': 'text/javascript',
    'ts': 'text/typescript',
    'tsx': 'text/typescript',
    'png': 'image/png',
    'jpg': 'image/jpeg',
    'jpeg': 'image/jpeg',
    'gif': 'image/gif',
    'webp': 'image/webp',
    'mp4': 'video/mp4',
    'm4v': 'video/mp4',
    'webm': 'video/webm',
    'mov': 'video/quicktime',
    'pdf': 'application/pdf',
    'zip': 'application/zip',
    'parquet': 'application/parquet'
  };
  return types[key.split('.').last] ??
      (sourcePreviewLanguage(key, null) != null ||
              ['txt', 'log', 'md', 'yaml', 'yml'].contains(key.split('.').last)
          ? 'text/plain'
          : 'application/octet-stream');
}
