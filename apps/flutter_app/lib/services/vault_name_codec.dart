import 'dart:convert';
import '../models/client_encryption.dart';
import 'crypto/vault_names.dart';

const vaultNamesLocked =
    'Unlock your encryption key file to upload here. This location encrypts names.';
const vaultNamesLockedFilter =
    'Unlock your encryption key file to filter by name here. This location encrypts names.';
const vaultNamesKeyMissingFilter =
    'The key for this vault location is not in your key file, so names here cannot be translated. Import the key, or filter by the stored name.';
const vaultPolicyUnsupportedFilter =
    'This vault rule was written by a newer version of the app. Update the app to filter by name here.';
const vaultPolicyUnsupported =
    'This vault rule was written by a newer version of the app. Update the app to upload here.';
const vaultStrictFolders =
    'Folders cannot be created here. The strict policy stores every object under one random name.';

void validateVaultPolicy(ClientEncryptionRule rule, VaultNameKeys? keys) {
  if (rule.policy == ClientEncryptionPolicy.unsupported) {
    throw const FormatException(vaultPolicyUnsupported);
  }
  if (rule.encryptsNames && keys == null) {
    throw const FormatException(vaultNamesLocked);
  }
}

String validateStoredKey(String key) {
  if (utf8.encode(key).length > 1024) {
    throw const FormatException(
        'The stored key exceeds 1,024 UTF-8 bytes. Use a shorter name or path.');
  }
  return key;
}

/// The destination prefix is already stored: never re-encode its segments.
String encodeVaultObjectKey(
    {required ClientEncryptionRule rule,
    required VaultNameKeys? keys,
    required String destinationPrefix,
    required String relativeName,
    bool folder = false}) {
  if (folder && rule.randomNames) {
    throw const FormatException(vaultStrictFolders);
  }
  validateVaultPolicy(rule, keys);
  final base = destinationPrefix.length >= rule.prefix.length
      ? destinationPrefix
      : rule.prefix;
  final full = '$destinationPrefix$relativeName';
  var remainder =
      full.startsWith(base) ? full.substring(base.length) : relativeName;
  if (folder && remainder.endsWith('/')) {
    remainder = remainder.substring(0, remainder.length - 1);
  }
  if (!rule.encryptsNames) {
    return validateStoredKey('$base$remainder${folder ? '/' : '.age'}');
  }
  final encoded = rule.randomNames
      ? sealVaultName(remainder, keys!, random: true)
      : remainder.split('/').map((s) => sealVaultName(s, keys!)).join('/');
  return validateStoredKey('$base$encoded${folder ? '/' : '.age'}');
}

String _openSegment(String segment, ClientEncryptionRule rule,
    Map<String, VaultNameKeys> keys) {
  final first = keys[rule.keyId];
  final opened = first?.open(segment);
  if (opened != null) return opened;
  for (final other in keys.values) {
    if (identical(other, first)) continue;
    final value = other.open(segment);
    if (value != null) return value;
  }
  return segment;
}

String decodeVaultKey(
    String stored, ClientEncryptionRule rule, Map<String, VaultNameKeys> keys,
    {bool file = true}) {
  if (!stored.startsWith(rule.prefix)) return stored;
  var tail = stored.substring(rule.prefix.length);
  if (file && tail.endsWith('.age') && tail.length > 4) {
    tail = tail.substring(0, tail.length - 4);
  }
  return rule.prefix +
      tail.split('/').map((s) => _openSegment(s, rule, keys)).join('/');
}

/// Reuse matching reference segments exactly, including legacy plaintext
/// folders. A random segment can represent several visible path segments.
String translateVaultKey(
    {required String visible,
    required String reference,
    required ClientEncryptionRule rule,
    required Map<String, VaultNameKeys> keys,
    bool folder = false,
    bool encryptedFile = true}) {
  validateVaultPolicy(rule, keys[rule.keyId]);
  if (!visible.startsWith(rule.prefix)) {
    throw const FormatException(
        'The destination must remain inside the vault prefix.');
  }
  if (rule.randomNames) {
    if (folder) throw const FormatException(vaultStrictFolders);
    final wanted = visible.substring(rule.prefix.length).split('/');
    final ref = reference.startsWith(rule.prefix)
        ? reference.substring(rule.prefix.length).split('/')
        : <String>[];
    if (ref.isNotEmpty) {
      ref.removeLast(); // Never reuse the source's file token.
    }
    final parents = <String>[];
    var cursor = 0;
    for (final segment in ref) {
      final decoded = _openSegment(segment, rule, keys).split('/');
      if (cursor + decoded.length >= wanted.length) break;
      var same = true;
      for (var i = 0; i < decoded.length; i++) {
        if (wanted[cursor + i] != decoded[i]) same = false;
      }
      if (!same) break;
      parents.add(segment);
      cursor += decoded.length;
    }
    final base =
        '${rule.prefix}${parents.isEmpty ? '' : '${parents.join('/')}/'}';
    final stored = encodeVaultObjectKey(
        rule: rule,
        keys: keys[rule.keyId],
        destinationPrefix: base,
        relativeName: wanted.skip(cursor).join('/'));
    return encryptedFile ? stored : stored.substring(0, stored.length - 4);
  }
  final wanted = visible.substring(rule.prefix.length).split('/');
  if (folder && wanted.last.isEmpty) wanted.removeLast();
  var ref = reference.startsWith(rule.prefix)
      ? reference.substring(rule.prefix.length)
      : '';
  if (ref.endsWith('/')) ref = ref.substring(0, ref.length - 1);
  if (!folder && ref.endsWith('.age')) ref = ref.substring(0, ref.length - 4);
  final reused = <String>[];
  var cursor = 0;
  for (final storedSegment in ref.split('/')) {
    final decoded = _openSegment(storedSegment, rule, keys).split('/');
    if (cursor + decoded.length > wanted.length) break;
    var equal = true;
    for (var i = 0; i < decoded.length; i++) {
      if (wanted[cursor + i] != decoded[i]) equal = false;
    }
    if (!equal) break;
    reused.add(storedSegment);
    cursor += decoded.length;
  }
  final rest = wanted
      .skip(cursor)
      .map((s) => rule.encryptsNames ? sealVaultName(s, keys[rule.keyId]!) : s);
  return validateStoredKey('${rule.prefix}${[
    ...reused,
    ...rest
  ].join('/')}${folder ? '/' : encryptedFile ? '.age' : ''}');
}

/// Spaces and control characters an engine may trim from either end of a
/// bucket name, key or prefix. Engines do not agree on the set, so this is a
/// superset of all of them.
const _edgeBlankClass =
    r'[\x00-\x20\x7f-\xa0\u1680\u180e\u2000-\u200d\u2028\u2029\u202f\u205f\u2060\u3000\ufeff]';
final _edgeBlank = RegExp('^$_edgeBlankClass+|$_edgeBlankClass+\$');
final _leadingBlanks = RegExp('^$_edgeBlankClass+');
final _trailingBlanks = RegExp('$_edgeBlankClass+\$');

String withoutEdgeBlanks(String value) => value.replaceAll(_edgeBlank, '');

/// Every way an engine might trim [value]: any number of blanks removed from
/// the start and any number from the end. Engines trim different sets, so
/// one may stop where another goes on. Null when there are more blanks than
/// this enumerates.
Set<String>? vaultTrimVariants(String value) {
  final lead = _leadingBlanks.firstMatch(value)?.end ?? 0;
  final trail = lead == value.length
      ? 0
      : value.length -
          (_trailingBlanks.firstMatch(value)?.start ?? value.length);
  if (lead > 8 || trail > 8) return null;
  return {
    for (var i = 0; i <= lead; i++)
      for (var j = 0; j <= trail; j++) value.substring(i, value.length - j)
  };
}

const vaultAmbiguousTarget =
    'This name has a space, control character, backslash, leading slash or dot segment that may be removed on the way, and without it the target could be a vault location. Rename it first.';

/// Whether an engine could read [bucket] and [key] as a target under another
/// vault rule than the one they match as given. Some engine handlers trim a
/// bucket name or key; upload handlers trim the name, turn its backslashes
/// into slashes, drop its leading slashes, and one drops a blank prefix. The
/// host does not model each engine. It refuses a target whose readings
/// disagree. An HTTP client may also resolve "." and ".." segments.
///
/// For an upload pass the destination [uploadPrefix] and the relative
/// [uploadName]; [key] is then their concatenation.
bool vaultTargetIsAmbiguous(
    List<ClientEncryptionRule> rules, String bucket, String key,
    {String? uploadPrefix, String? uploadName}) {
  if (rules.isEmpty) return false;
  final keys = <String>{key};
  if (uploadName != null) {
    final prefix = uploadPrefix ?? '';
    // Two engines trim the name itself before adding the prefix; the trim
    // comes before the slashes are normalised.
    final trimmed = vaultTrimVariants(uploadName);
    if (trimmed == null) return true;
    final names = <String>{
      for (final name in trimmed) ...[
        name,
        name.replaceAll('\\', '/').replaceFirst(RegExp(r'^/+'), ''),
      ]
    };
    for (final name in names) {
      keys.add('$prefix$name');
      if (withoutEdgeBlanks(prefix).isEmpty) keys.add(name);
    }
  }
  final seen = matchingClientEncryptionRule(rules, bucket, key);
  if (keys.length == 1 &&
      withoutEdgeBlanks(bucket) == bucket &&
      withoutEdgeBlanks(key) == key &&
      !hasDotSegment(key) &&
      vaultBucketIsCertain(rules, bucket)) {
    return false;
  }
  bool other(String bucket, String key) {
    final rule = matchingClientEncryptionRule(rules, bucket, key);
    return rule != null && !identical(rule, seen);
  }

  if (!vaultBucketIsCertain(rules, bucket)) return true;
  final buckets = vaultTrimVariants(bucket);
  if (buckets == null) return true;
  for (final reading in keys) {
    final variants = vaultTrimVariants(reading);
    if (variants == null) return true;
    for (final b in buckets) {
      for (final k in variants) {
        if (other(b, k)) return true;
        // An HTTP client may resolve "." and ".." in the request path. What
        // lies above the key there (the bucket, an endpoint path, or
        // nothing) depends on the endpoint, so a key that climbs out of its
        // own root could land anywhere and is refused outright.
        if (hasDotSegment(k)) {
          final resolved = _withoutDotSegments(k);
          if (resolved == null || other(b, resolved)) return true;
        }
      }
    }
  }
  return false;
}

final _plainBucketName = RegExp(r'^[A-Za-z0-9$][A-Za-z0-9._$-]*$');

/// Whether a bucket argument is certain to address the bucket the rules
/// were matched against. With vault rules in the connection only a plain
/// name is: letters, digits, ".", "-", "_" and "$", starting with a letter,
/// digit or "$" (which covers every valid S3, Azure and Cloud Storage name).
/// Anything else may be rewritten on the way: engines trim blanks, one puts
/// the name into the request path as it is, and an HTTP client resolves dot
/// segments and percent escapes. A name that differs from a rule's bucket
/// only in case is uncertain too, because a host name is case-insensitive.
bool vaultBucketIsCertain(List<ClientEncryptionRule> rules, String bucket) =>
    rules.isEmpty ||
    (_plainBucketName.hasMatch(bucket) &&
        !rules.any((rule) =>
            rule.bucket != bucket &&
            rule.bucket.toLowerCase() == bucket.toLowerCase()));

bool hasDotSegment(String key) =>
    key.split('/').any((segment) => segment == '.' || segment == '..');

/// [key] with its dot segments removed as RFC 3986 section 5.2.4 does. Null
/// when a ".." climbs above the key's own root.
String? _withoutDotSegments(String key) {
  final parts = key.split('/');
  final out = <String>[];
  for (final part in parts) {
    if (part == '.') continue;
    if (part == '..') {
      if (out.isEmpty) return null;
      out.removeLast();
      continue;
    }
    out.add(part);
  }
  // A trailing dot segment leaves a directory, with its slash.
  if (out.isNotEmpty && (parts.last == '.' || parts.last == '..')) out.add('');
  return out.join('/');
}

bool looksLikeVaultToken(String segment) {
  if (segment.endsWith('.age')) {
    segment = segment.substring(0, segment.length - 4);
  }
  try {
    if (!RegExp(r'^[A-Za-z0-9_-]+$').hasMatch(segment)) return false;
    final raw = base64Url.decode(base64Url.normalize(segment));
    // Tokens are canonical encodings; most ordinary names that happen to
    // decode are not.
    return raw.length >= 18 &&
        (raw[0] == 1 || raw[0] == 2) &&
        base64Url.encode(raw).replaceAll('=', '') == segment;
  } catch (_) {
    return false;
  }
}

String _foldName(String text) =>
    text.toLowerCase().replaceAll(RegExp(r'[^\p{L}\p{N}]', unicode: true), '');

/// What to look for in engine text to tell whether it could name a file that
/// was published under [name]: the start of its stem, letters and digits only,
/// so a collision suffix, sanitised punctuation or truncation still match.
/// Empty means "everything matches".
String hiddenNameNeedle(String name) {
  final dot = name.lastIndexOf('.');
  final folded = _foldName(dot > 0 ? name.substring(0, dot) : name);
  return folded.length > 12 ? folded.substring(0, 12) : folded;
}

bool mentionsHiddenName(String text, String needle) =>
    needle.isEmpty || _foldName(text).contains(needle);
