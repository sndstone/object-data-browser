import 'dart:io';

/// Creates a logical size fixture without allocating its full size on Windows.
Future<void> createSparseFixture(File file, int size) async {
  await file.create();
  if (Platform.isWindows) {
    // Dart's Windows truncate path can materialize zeroes. Set EOF through the
    // native sparse-file utility instead: https://learn.microsoft.com/en-us/windows-server/administration/windows-commands/fsutil-file
    for (final args in [
      ['sparse', 'setflag', file.path],
      ['file', 'seteof', file.path, '$size'],
    ]) {
      final result = await Process.run('fsutil', args);
      if (result.exitCode != 0) {
        throw StateError(
            'Cannot create sparse fixture: ${result.stdout} ${result.stderr}');
      }
    }
  } else {
    final handle = await file.open(mode: FileMode.write);
    try {
      await handle.truncate(size);
    } finally {
      await handle.close();
    }
  }
  if (await file.length() != size) throw StateError('Wrong fixture size.');
}
