import 'dart:convert';
import 'dart:io';
import 'package:path_provider/path_provider.dart';

/// One bounded checkpoint for the active bucket-copy task. Contains profile
/// IDs, bucket names, opaque cursors and current-page identities; never profiles.
class BucketCopyJournal {
  BucketCopyJournal(this.file);
  final File file;
  static final Map<String, Future<void>> _writers = {};

  Future<T> _serialize<T>(Future<T> Function() action) async {
    final key = file.absolute.path;
    final previous = _writers[key] ?? Future<void>.value();
    final result = previous.then((_) => action());
    final tail =
        result.then<void>((_) {}, onError: (Object _, StackTrace __) {});
    _writers[key] = tail;
    try {
      return await result;
    } finally {
      if (identical(_writers[key], tail)) _writers.remove(key);
    }
  }

  Future<Map<String, dynamic>> _decode(File source) async {
    final value = jsonDecode(await source.readAsString());
    if (value is! Map ||
        value['configuration'] is! Map ||
        (value['completed'] != null &&
            (value['completed'] is! List ||
                (value['completed'] as List).any((x) => x is! String))) ||
        (value['cursor'] != null && value['cursor'] is! Map) ||
        (value['contentComplete'] != null &&
            value['contentComplete'] is! bool)) {
      throw const FormatException('Invalid bucket-copy checkpoint.');
    }
    for (final name in ['copied', 'skipped', 'bytes']) {
      if (value[name] != null &&
          (value[name] is! int || (value[name] as int) < 0)) {
        throw const FormatException('Invalid bucket-copy counters.');
      }
    }
    for (final name in [
      'historyRecoveryId',
      'configurationPlanId',
      'inFlight'
    ]) {
      if (value[name] != null && value[name] is! String) {
        throw const FormatException('Invalid bucket-copy identity.');
      }
    }
    return Map<String, dynamic>.from(value);
  }

  static Future<BucketCopyJournal> open() async {
    final directory = await getApplicationSupportDirectory();
    return BucketCopyJournal(
        File('${directory.path}/bucket-copy-checkpoint.json'));
  }

  Future<Map<String, dynamic>?> read(Map<String, Object?> configuration) =>
      _serialize(() async {
        final backup = File('${file.path}.last-good');
        if (!await file.exists() && !await backup.exists()) return null;
        late Map<String, dynamic> data;
        try {
          data = await _decode(file);
        } catch (_) {
          if (await file.exists()) {
            await file.copy(
                '${file.path}.corrupt-${DateTime.now().microsecondsSinceEpoch}');
          }
          data = await _decode(backup);
          // A newer unreadable generation may have recorded a remote mutation.
          // Existing controller reconciliation prevents replay of overwrite work.
          data['inFlight'] = 'an operation from a damaged checkpoint';
        }
        if (jsonEncode(data['configuration']) != jsonEncode(configuration)) {
          throw StateError(
              'The saved copy uses a different source, destination, prefix or conflict policy. Match those settings or start a new copy.');
        }
        return data;
      });

  Future<void> write(Map<String, Object?> data) => _serialize(() async {
        await file.parent.create(recursive: true);
        final lock =
            await File('${file.path}.lock').open(mode: FileMode.append);
        await lock.lock(FileLock.blockingExclusive);
        final temp = File(
            '${file.path}.$pid-${DateTime.now().microsecondsSinceEpoch}.tmp');
        try {
          await temp.writeAsString(jsonEncode(data), flush: true);
          await _decode(temp);
          if (await file.exists()) {
            try {
              await _decode(file);
              final backup = File('${temp.path}.backup');
              await file.copy(backup.path);
              await backup.rename('${file.path}.last-good');
            } on FormatException {
              await file.copy(
                  '${file.path}.corrupt-${DateTime.now().microsecondsSinceEpoch}');
            }
          }
          await temp.rename(file.path);
        } finally {
          if (await temp.exists()) await temp.delete();
          await lock.unlock();
          await lock.close();
        }
      });

  Future<void> clear() => _serialize(() async {
        for (final candidate in [file, File('${file.path}.last-good')]) {
          if (await candidate.exists()) await candidate.delete();
        }
      });
}
