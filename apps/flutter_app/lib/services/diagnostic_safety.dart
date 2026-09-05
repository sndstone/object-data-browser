import 'dart:collection';
import 'dart:convert';

/// One sanitization boundary for display, retained diagnostics and exports.
class DiagnosticSafety {
  static final _secretKey = RegExp(
    r'^(access.?key(id)?|secret.?key|secret.?access.?key|session.?token|authorization|proxy.authorization|account.?key|password|sas.?token|sig|signature|x-amz-(signature|credential|security-token))$',
    caseSensitive: false,
  );
  static Object? sanitize(Object? value) {
    if (value is Map) {
      return value.map((key, entry) => MapEntry(
          key.toString(),
          _secretKey.hasMatch(key.toString())
              ? '[redacted]'
              : sanitize(entry)));
    }
    if (value is List) return value.map(sanitize).toList();
    if (value is String) return text(value);
    return value;
  }

  static String text(String value) => value.replaceAllMapped(
        RegExp(r'(https?://[^\s"<>]+)', caseSensitive: false),
        (match) {
          final raw = match[0]!;
          final uri = Uri.tryParse(raw);
          if (uri == null || !uri.hasQuery) return raw;
          if (!uri.queryParameters.keys
              .any((key) => _secretKey.hasMatch(key))) {
            return raw;
          }
          // Signed URLs are bearer credentials. Drop the whole query to also
          // cover provider-specific credential aliases and future additions.
          return '${raw.split('?').first}?[redacted]';
        },
      ).replaceAllMapped(
        RegExp(
            r'((?:authorization|secretKey|accessKey|sessionToken|accountKey|password)\s*[=:]\s*)([^\s,;]+)',
            caseSensitive: false),
        (m) => '${m[1]}[redacted]',
      );
}

/// Bounded retention, including a single oversized diagnostic line.
class DiagnosticBuffer {
  DiagnosticBuffer({this.maxCharacters = 64 * 1024});
  final int maxCharacters;
  final Queue<String> _lines = Queue<String>();
  int _characters = 0;
  int droppedLines = 0;
  bool get isEmpty => _lines.isEmpty;
  bool get isNotEmpty => _lines.isNotEmpty;
  void add(String raw) {
    var line = DiagnosticSafety.text(raw);
    try {
      final parsed = jsonDecode(raw);
      if (parsed is Map || parsed is List) {
        line = jsonEncode(DiagnosticSafety.sanitize(parsed));
      }
    } on FormatException {/* Non-JSON diagnostics still get text redaction. */}
    if (line.length > maxCharacters) {
      line = '${line.substring(0, maxCharacters - 32)}… [line truncated]';
      droppedLines++;
    }
    while (_lines.isNotEmpty && _characters + line.length > maxCharacters) {
      _characters -= _lines.removeFirst().length;
      droppedLines++;
    }
    _lines.add(line);
    _characters += line.length;
  }

  void addAll(Iterable<String> lines) => lines.forEach(add);
  Iterable<String> get lines => _lines;
  String join(String separator) => [
        if (droppedLines > 0) '[diagnostics truncated: $droppedLines lines]',
        ..._lines,
      ].join(separator);
  void clear() {
    _lines.clear();
    _characters = 0;
    droppedLines = 0;
  }
}
