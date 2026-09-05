import 'dart:convert';
import 'dart:io';

/// Serialized metadata only. Credentials must never be passed to this store.
class AtomicMetadataStore {
  Future<void> _tail = Future<void>.value();

  Future<T> serialize<T>(Future<T> Function() action) {
    final result = _tail.then((_) => action());
    _tail = result.then<void>((_) {}, onError: (Object _, StackTrace __) {});
    return result;
  }

  Future<Map<String, Object?>?> read(File file) async {
    final backup = File('${file.path}.last-good');
    if (!await file.exists() && !await backup.exists()) return null;
    try {
      return await _decode(file);
    } catch (_) {
      if (await file.exists()) {
        await file.copy(
            '${file.path}.corrupt-${DateTime.now().microsecondsSinceEpoch}');
      }
      try {
        final recovered = await _decode(backup);
        await replace(file, recovered, preserveBackup: true);
        return recovered;
      } catch (_) {
        throw FormatException(
            'Application metadata is unreadable. A recovery copy is kept beside ${file.path}. Restore a metadata backup before restarting; Keychain credentials have not been changed.');
      }
    }
  }

  Future<Map<String, Object?>> _decode(File file) async {
    final value = jsonDecode(await file.readAsString());
    if (value is! Map ||
        value['settings'] is! Map ||
        value['profiles'] is! List) {
      throw const FormatException('Invalid application metadata schema.');
    }
    return Map<String, Object?>.from(value);
  }

  Future<void> replace(File file, Map<String, Object?> metadata,
      {bool preserveBackup = false}) async {
    await file.parent.create(recursive: true);
    final temp = File('${file.path}.pending');
    await temp.writeAsString(
        const JsonEncoder.withIndent('  ').convert(metadata),
        flush: true);
    if (!preserveBackup && await file.exists()) {
      // Validate before rotating: never replace the last-good backup with a
      // corrupt primary. The secure-store write is handled by the caller.
      await _decode(file);
      final backupTemp = File('${file.path}.last-good.pending');
      await backupTemp.writeAsString(await file.readAsString(), flush: true);
      await backupTemp.rename('${file.path}.last-good');
    }
    // Dart's same-directory rename replaces an existing file on supported
    // platforms. No delete-first gap: an unsuccessful rename preserves it.
    await temp.rename(file.path);
  }
}
