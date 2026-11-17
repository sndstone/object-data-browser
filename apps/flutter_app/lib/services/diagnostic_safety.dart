import 'dart:collection';
import 'dart:convert';
import 'vault_name_codec.dart'
    show looksLikeVaultToken, hiddenNameNeedle, mentionsHiddenName;

/// One sanitization boundary for display, retained diagnostics and exports.
class DiagnosticSafety {
  static const traceMaxBytes = 16 * 1024;
  static const traceMaxDepth = 6;
  static const traceMaxItems = 32;

  /// Bounds the encoded UTF-8 payload as well as traversal and retained nodes.
  /// Inspect complete keys and redact complete strings before shortening them.
  static Object? trace(
    Object? value, {
    int maxBytes = traceMaxBytes,
    int maxDepth = traceMaxDepth,
    int maxItems = traceMaxItems,
  }) {
    assert(maxBytes >= 128 && maxDepth >= 0 && maxItems > 0);
    final writer = _TraceSanitizer(maxBytes - 32, maxDepth, maxItems);
    final result = writer.visit(value, 0);
    return writer.truncated ? {'value': result, 'truncated': true} : result;
  }

  /// Project local upload names to stored keys and drop download text that
  /// could mention a hidden published name. The engine request is untouched.
  static Object? forNameEncryptedRequest(Object? value, Map? params) {
    final replacements = <String, String>{};
    final mapping = params?['objectKeyByPath'];
    if (mapping is Map) {
      for (final entry in mapping.entries) {
        final stored = entry.value.toString();
        if (!stored.split('/').any(looksLikeVaultToken)) continue;
        final path = entry.key.toString();
        replacements[path] = stored;
        final name = path.replaceAll('\\', '/').split('/').last;
        if (name.isNotEmpty) replacements[name] = stored.split('/').last;
      }
    }
    final client = params?['clientEncryption'];
    String? hiddenDownloadNeedle;
    if (client is Map &&
        client['fileName'] is String &&
        (client['fileName'] as String).isNotEmpty) {
      hiddenDownloadNeedle = hiddenNameNeedle(client['fileName'] as String);
      final stored = params?['keys'];
      replacements[client['fileName'] as String] =
          stored is List && stored.length == 1
              ? stored.single.toString().split('/').last
              : '[redacted]';
    }
    if (replacements.isEmpty) return value;
    String text(String input) {
      // Published names may contain platform sanitising or collision suffixes.
      // Drop the complete engine text; replacing an exact substring cannot
      // protect those variants. Keep unrelated output intact.
      final needle = hiddenDownloadNeedle;
      if (needle != null && mentionsHiddenName(input, needle)) {
        return '[Output hidden for an encrypted name.]';
      }
      for (final entry in replacements.entries) {
        final pattern = RegExp(r'''(^|[\s/\\"'=:(])''' +
            RegExp.escape(entry.key) +
            r'''(?=$|[\s/\\"'),:;.])''');
        input = input.replaceAllMapped(pattern, (m) => '${m[1]}${entry.value}');
      }
      return input;
    }

    Object? visit(Object? input) {
      if (input is String) return text(input);
      if (input is List) return input.map(visit).toList();
      if (input is Map) {
        return input.map((k, v) => MapEntry(
            mapping is Map && mapping.containsKey(k)
                ? mapping[k].toString()
                : k.toString(),
            const {
              'id',
              'jobId',
              'requestId',
              'status',
              'direction',
              'event',
              'format',
              // Machine-readable codes: a short hidden name such as "a" would
              // otherwise blank them and lose the error's meaning.
              'code',
              'awsCode',
              'errorCode',
              'encryptionHint'
            }.contains(k)
                ? v
                : visit(v)));
      }
      return input;
    }

    return visit(value);
  }

  static final _secretKey = RegExp(
    r'^(file.?name|file.?key|customer.?key|x-amz-(?:copy-source-)?server-side-encryption-customer-key|x-ms-encryption-key|access.?key(id)?|secret.?key|secret.?access.?key|session.?token|authorization|proxy.authorization|account.?key|password|(?:azure)?sas.?token|sig|signature|x-amz-(signature|credential|security-token))$',
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

  static String text(String value) => value
      .replaceAllMapped(
          RegExp(r'(\bfileName\s*[=:]\s*)([\s\S]*)', caseSensitive: false),
          (m) => '${m[1]}[redacted]')
      .replaceAllMapped(
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
      )
      .replaceAllMapped(
        RegExp(
            r'("(?:fileName|fileKey|customerKey|x-amz-(?:copy-source-)?server-side-encryption-customer-key|x-ms-encryption-key)"\s*:\s*")(?:\\.|[^"\\])*"',
            caseSensitive: false),
        (m) => '${m[1]}[redacted]"',
      )
      .replaceAllMapped(
        RegExp(
            r'((?:fileName|fileKey|customerKey|x-amz-(?:copy-source-)?server-side-encryption-customer-key|x-ms-encryption-key|authorization|secretKey|accessKey|sessionToken|azureSasToken|sasToken|accountKey|password|sig)\s*[=:]\s*)([^\s,;]+)',
            caseSensitive: false),
        (m) => '${m[1]}[redacted]',
      );
}

class _TraceSanitizer {
  _TraceSanitizer(this.remaining, this.maxDepth, this.maxItems);
  int remaining;
  final int maxDepth;
  final int maxItems;
  bool truncated = false;

  Object? visit(Object? value, int depth) {
    if (value is Map || value is List) {
      if (depth >= maxDepth) {
        truncated = true;
        remaining -= 4;
        return null;
      }
      remaining -= 2; // Container delimiters.
      if (value is Map) {
        final result = <String, Object?>{};
        for (final entry in value.entries) {
          if (result.length >= maxItems || remaining < 64) {
            truncated = true;
            break;
          }
          final rawKey = entry.key.toString();
          // Omit oversized keys in full; never match secrets on a partial key.
          if (rawKey.length > remaining ~/ 6) {
            truncated = true;
            break;
          }
          final key = DiagnosticSafety.text(rawKey);
          final keyBytes = utf8.encode(jsonEncode(key)).length + 2;
          if (remaining - keyBytes < 32) {
            truncated = true;
            break;
          }
          remaining -= keyBytes; // Key, colon and optional comma.
          result[key] = visit(
            DiagnosticSafety._secretKey.hasMatch(rawKey)
                ? '[redacted]'
                : entry.value,
            depth + 1,
          );
        }
        return result;
      }
      final result = <Object?>[];
      for (final entry in value as List) {
        if (result.length >= maxItems || remaining < 64) {
          truncated = true;
          break;
        }
        remaining--; // Optional comma.
        result.add(visit(entry, depth + 1));
      }
      return result;
    }
    if (value is String || (value != null && value is! num && value is! bool)) {
      var safe = DiagnosticSafety.text(value.toString());
      // A rune needs at most six bytes in JSON (escaped control characters).
      final limit = (remaining - 2) ~/ 6;
      if (safe.length > limit) {
        safe = String.fromCharCodes(safe.runes.take(limit));
        truncated = true;
      }
      remaining -= utf8.encode(jsonEncode(safe)).length;
      return safe;
    }
    final bytes = utf8.encode(jsonEncode(value)).length;
    if (bytes > remaining) {
      truncated = true;
      remaining -= 4;
      return null;
    }
    remaining -= bytes;
    return value;
  }
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
