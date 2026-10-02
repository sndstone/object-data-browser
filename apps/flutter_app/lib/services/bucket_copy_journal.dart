import 'dart:convert';
import 'dart:io';
import 'package:path_provider/path_provider.dart';

/// One bounded checkpoint for the active bucket-copy task. Contains profile
/// IDs, bucket names, opaque cursors and current-page identities; never profiles.
class BucketCopyJournal {
  BucketCopyJournal(this.file);
  final File file;
  static Future<BucketCopyJournal> open() async {
    final directory = await getApplicationSupportDirectory();
    return BucketCopyJournal(
        File('${directory.path}/bucket-copy-checkpoint.json'));
  }

  Future<Map<String, dynamic>?> read(Map<String, Object?> configuration) async {
    if (!await file.exists()) return null;
    final data = jsonDecode(await file.readAsString()) as Map<String, dynamic>;
    if (jsonEncode(data['configuration']) != jsonEncode(configuration)) {
      throw StateError(
          'The saved copy uses a different source, destination, prefix or conflict policy. Match those settings or start a new copy.');
    }
    return data;
  }

  Future<void> write(Map<String, Object?> data) async {
    await file.parent.create(recursive: true);
    final temp = File('${file.path}.tmp');
    await temp.writeAsString(jsonEncode(data), flush: true);
    await temp.rename(file.path);
  }

  Future<void> clear() async {
    if (await file.exists()) await file.delete();
  }
}
