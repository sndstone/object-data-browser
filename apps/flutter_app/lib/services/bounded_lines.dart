import 'dart:convert';
import 'dart:typed_data';

/// Bounds bytes before decoding, including streams that never emit a newline.
Stream<String> boundedLines(Stream<List<int>> input,
    {required int maximumBytes, bool truncate = false}) async* {
  var pending = BytesBuilder(copy: false);
  var dropping = false;
  await for (final chunk in input) {
    var start = 0;
    for (var i = 0; i <= chunk.length; i++) {
      final newline = i < chunk.length && chunk[i] == 10;
      if (i != chunk.length && !newline) continue;
      if (!dropping) {
        final length = i - start;
        final remaining = maximumBytes - pending.length;
        if (length > remaining && !truncate) {
          throw const FormatException(
              'Engine protocol frame exceeded its byte budget.');
        }
        pending.add(chunk.sublist(
            start, start + (length > remaining ? remaining : length)));
        if (length > remaining) dropping = true;
      }
      if (newline) {
        final line = utf8.decode(pending.takeBytes(), allowMalformed: truncate);
        yield dropping
            ? '$line [truncated]'
            : line.endsWith('\r')
                ? line.substring(0, line.length - 1)
                : line;
        dropping = false;
      }
      start = i + 1;
    }
  }
  if (pending.isNotEmpty || dropping) {
    final line = utf8.decode(pending.takeBytes(), allowMalformed: truncate);
    yield dropping ? '$line [truncated]' : line;
  }
}
