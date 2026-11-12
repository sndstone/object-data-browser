import 'dart:async';
import 'dart:collection';
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
  SendPort? _commands;
  Future<SendPort>? _starting;
  final Map<int, Completer<Object>> _pending = {};
  bool loading = false;
  int _generation = 0, _workerEpoch = 0;
  bool _disposed = false;

  List<ObjectEntry> resolve(List<ObjectEntry> objects, BrowserFilterMode mode,
      String value, BrowserObjectSortField sort, bool descending) {
    final signature = (objects, mode, value, sort, descending);
    if (_signature == signature) return _result;
    _signature = signature;
    final generation = ++_generation;
    if (!identical(objects, _input)) {
      _resetWorker();
      _result = const [];
      _input = objects;
    }
    final spec = (objects, mode, value, sort, descending);
    if (mode != BrowserFilterMode.regex && objects.length < 5000) {
      loading = false;
      return _result = queryObjects(spec);
    }
    loading = true;
    scheduleMicrotask(() async {
      if (_disposed || generation != _generation) return;
      try {
        final commands = await (_starting ??= _startWorker(objects));
        if (_disposed || generation != _generation) return;
        final response = Completer<Object>();
        _pending[generation] = response;
        commands.send((generation, mode, value, sort, descending));
        final message =
            await response.future.timeout(const Duration(seconds: 2));
        if (_disposed || generation != _generation) return;
        if (message is String) throw FormatException(message);
        _result = (message as List)
            .cast<int>()
            .map((index) => objects[index])
            .toList();
        loading = false;
        onChanged(null);
      } catch (_) {
        if (!_disposed && generation == _generation) {
          _resetWorker();
          loading = false;
          onChanged(
              'This filter exceeded its execution budget or is invalid. Simplify it; previous results are retained.');
        }
      } finally {
        _pending.remove(generation);
      }
    });
    return _result;
  }

  Future<SendPort> _startWorker(List<ObjectEntry> objects) async {
    final epoch = _workerEpoch;
    final ready = Completer<SendPort>();
    final port = ReceivePort();
    _port = port;
    port.listen((message) {
      if (message is SendPort) {
        if (!ready.isCompleted) ready.complete(message);
      } else if (message is (int, Object)) {
        final pending = _pending[message.$1];
        if (pending != null && !pending.isCompleted) {
          pending.complete(message.$2);
        }
      }
    });
    final worker =
        await Isolate.spawn(_objectDatasetWorker, (port.sendPort, objects));
    if (_disposed || epoch != _workerEpoch) {
      worker.kill(priority: Isolate.immediate);
      port.close();
      throw StateError('Superseded object dataset.');
    }
    _worker = worker;
    _commands = await ready.future.timeout(const Duration(seconds: 2));
    return _commands!;
  }

  void _resetWorker() {
    _workerEpoch++;
    _worker?.kill(priority: Isolate.immediate);
    _worker = null;
    _commands = null;
    _starting = null;
    _port?.close();
    _port = null;
    for (final pending in _pending.values) {
      if (!pending.isCompleted) {
        pending.completeError(StateError('Superseded object query.'));
      }
    }
    _pending.clear();
  }

  void dispose() {
    _disposed = true;
    _generation++;
    _resetWorker();
  }
}

void _objectDatasetWorker((SendPort, List<ObjectEntry>) initial) {
  final data = _deriveObjects(initial.$2);
  final commands = ReceivePort();
  initial.$1.send(commands.sendPort);
  commands.listen((message) {
    final (id, mode, value, sort, descending) = message as (
      int,
      BrowserFilterMode,
      String,
      BrowserObjectSortField,
      bool
    );
    try {
      initial.$1.send((id, _queryIndices(data, mode, value, sort, descending)));
    } catch (error) {
      initial.$1.send((id, error.toString()));
    }
  });
}

typedef ObjectQuerySpec = (
  List<ObjectEntry>,
  BrowserFilterMode,
  String,
  BrowserObjectSortField,
  bool
);
typedef _DerivedObject = (int, ObjectEntry, String, String);
List<_DerivedObject> _deriveObjects(List<ObjectEntry> objects) => [
      for (var i = 0; i < objects.length; i++)
        (
          i,
          objects[i],
          objects[i].name.toLowerCase(),
          queryContentType(objects[i])
        )
    ];

List<int> _queryIndices(List<_DerivedObject> data, BrowserFilterMode mode,
    String value, BrowserObjectSortField sort, bool descending) {
  final regex = mode == BrowserFilterMode.regex && value.isNotEmpty
      ? RegExp(value, caseSensitive: false)
      : null;
  final query = value.toLowerCase();
  final result = data
      .where((entry) =>
          mode == BrowserFilterMode.prefix ||
          query.isEmpty ||
          (regex != null
              ? regex.hasMatch(entry.$2.key)
              : entry.$2.key.toLowerCase().contains(query)))
      .toList();
  result.sort((a, b) {
    if (a.$2.isFolder != b.$2.isFolder) return a.$2.isFolder ? -1 : 1;
    final comparison = switch (sort) {
      BrowserObjectSortField.name => a.$3.compareTo(b.$3),
      BrowserObjectSortField.size => a.$2.size.compareTo(b.$2.size),
      BrowserObjectSortField.lastModified =>
        a.$2.modifiedAt.compareTo(b.$2.modifiedAt),
      BrowserObjectSortField.contentType => a.$4.compareTo(b.$4),
    };
    return comparison == 0
        ? a.$3.compareTo(b.$3)
        : comparison * (descending ? -1 : 1);
  });
  return result.map((entry) => entry.$1).toList();
}

List<ObjectEntry> queryObjects(ObjectQuerySpec spec) {
  final (objects, mode, value, sort, descending) = spec;
  return _queryIndices(_deriveObjects(objects), mode, value, sort, descending)
      .map((index) => objects[index])
      .toList();
}

/// Version regexes have the same killable execution budget as object regexes.
class VersionQuery {
  VersionQuery(this.onChanged);
  final void Function(String?) onChanged;
  Object? _signature;
  List<ObjectVersionEntry>? _input;
  List<ObjectVersionEntry> _result = const [];
  Isolate? _worker;
  ReceivePort? _port;
  int _generation = 0;
  bool _disposed = false;
  bool loading = false;

  List<ObjectVersionEntry> resolve(
      List<ObjectVersionEntry> versions, VersionBrowserOptions options) {
    final signature = (
      versions,
      versions.length,
      options.filterMode,
      options.filterValue,
      options.showDeleteMarkers,
      options.showVersions
    );
    if (_signature == signature) return _result;
    final datasetChanged = !identical(_input, versions);
    _input = versions;
    _signature = signature;
    final generation = ++_generation;
    _worker?.kill(priority: Isolate.immediate);
    _port?.close();
    if (datasetChanged) _result = const [];
    if (options.filterMode != BrowserFilterMode.regex ||
        options.filterValue.trim().isEmpty) {
      loading = false;
      return _result = _filterVersions(versions, options);
    }
    loading = true;
    scheduleMicrotask(() async {
      if (_disposed || generation != _generation) return;
      final port = ReceivePort();
      _port = port;
      Isolate? worker;
      try {
        worker = await Isolate.spawn(
            _versionWorker, (port.sendPort, versions.toList(), options));
        if (_disposed || generation != _generation) return;
        _worker = worker;
        final message = await port.first.timeout(const Duration(seconds: 2));
        if (_disposed || generation != _generation) return;
        if (message is String) throw FormatException(message);
        _result = (message as List)
            .cast<int>()
            .map((index) => versions[index])
            .toList();
        loading = false;
        onChanged(null);
      } catch (_) {
        if (!_disposed && generation == _generation) {
          loading = false;
          onChanged(
              'This version filter exceeded its execution budget or is invalid. Simplify it; previous results are retained.');
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

List<ObjectVersionEntry> _filterVersions(
    List<ObjectVersionEntry> versions, VersionBrowserOptions options) {
  final value = options.filterValue.trim();
  final regex =
      options.filterMode == BrowserFilterMode.regex && value.isNotEmpty
          ? RegExp(value, caseSensitive: false)
          : null;
  final query = value.toLowerCase();
  return versions.where((item) {
    if ((!options.showDeleteMarkers && item.deleteMarker) ||
        (!options.showVersions && !item.deleteMarker)) {
      return false;
    }
    if (value.isEmpty) return true;
    if (regex != null) {
      return regex.hasMatch(item.key) || regex.hasMatch(item.versionId);
    }
    if (options.filterMode == BrowserFilterMode.prefix) {
      return item.key.startsWith(value);
    }
    return item.key.toLowerCase().contains(query) ||
        item.versionId.toLowerCase().contains(query);
  }).toList();
}

void _versionWorker(
    (SendPort, List<ObjectVersionEntry>, VersionBrowserOptions) message) {
  try {
    final filtered = _filterVersions(message.$2, message.$3).toSet();
    message.$1.send([
      for (var i = 0; i < message.$2.length; i++)
        if (filtered.contains(message.$2[i])) i
    ]);
  } catch (error) {
    message.$1.send(error.toString());
  }
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

/// Append-only immutable pages avoid recopying all prior version records.
class VersionPages extends ListBase<ObjectVersionEntry> {
  final List<List<ObjectVersionEntry>> _pages = [];
  final List<int> _ends = [];
  final Set<(String, String)> _identities = {};
  @override
  int get length => _ends.isEmpty ? 0 : _ends.last;
  @override
  set length(int value) =>
      throw UnsupportedError('Version pages are append-only.');
  void append(Iterable<ObjectVersionEntry> values) {
    final page = values
        .where((v) => _identities.add((v.key, v.versionId)))
        .toList(growable: false);
    if (page.isEmpty) return;
    _ends.add(length + page.length);
    _pages.add(List.unmodifiable(page));
  }

  @override
  ObjectVersionEntry operator [](int index) {
    RangeError.checkValidIndex(index, this);
    var low = 0, high = _ends.length - 1;
    while (low < high) {
      final mid = (low + high) ~/ 2;
      if (index < _ends[mid]) {
        high = mid;
      } else {
        low = mid + 1;
      }
    }
    return _pages[low][index - (low == 0 ? 0 : _ends[low - 1])];
  }

  @override
  void operator []=(int index, ObjectVersionEntry value) =>
      throw UnsupportedError('Version pages are immutable.');
}
