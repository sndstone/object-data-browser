/// age v1 file encryption (https://c2sp.org/age), unmodified, so anything
/// written here can be decrypted with the stock `age` command-line tool and
/// vice versa.
///
/// Supported: X25519 recipients/identities (`age1…` / `AGE-SECRET-KEY-1…`)
/// and scrypt passphrase recipients, in the binary format. Not supported:
/// ssh, plugin, tagged and post-quantum recipients, and ASCII armor; files
/// that need them are rejected with a typed [AgeException].
///
/// Two levels of API:
///
/// * [ageEncrypt] / [ageDecrypt] work on whole buffers (key files, small
///   objects, previews).
/// * [ageNewHeader] / [ageReadHeader], [AgePayloadCipher] and the pure
///   arithmetic helpers ([ageCiphertextLength], [agePlaintextLength],
///   [ageCiphertextRangeForPlaintext], [ageChunksForCiphertextRange]) give
///   positional access for multipart uploads and ranged reads.
///
/// All primitives come from `package:cryptography` (X25519,
/// ChaCha20-Poly1305, HKDF-SHA-256, HMAC-SHA-256) and `package:pointycastle`
/// (scrypt). Only the Bech32 codec and the header framing are implemented
/// here. scrypt runs on a helper isolate; everything else runs on the
/// calling isolate.
///
/// Error messages and `toString()` output never contain key material.
library;

import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart' show SecretKey;

import 'vault_names.dart';
import 'age_bech32.dart';
import 'age_errors.dart';
import 'age_primitives.dart';

export 'age_errors.dart';

part 'age_header.dart';
part 'age_keys.dart';
part 'age_payload.dart';

/// Work factor (base-two logarithm of scrypt's N) used when writing
/// passphrase-protected files.
///
/// The `age` tool writes 18 (256 MiB). 15 (32 MiB) is a deliberate trade-off:
/// scrypt here is pure Dart, and 18 takes too long and too much memory on
/// phones. Files written at 15 are fully valid age files; the cost is that
/// each passphrase guess is eight times cheaper for an attacker, so
/// passphrase length matters more.
const int ageDefaultScryptWorkFactor = 15;

/// Largest scrypt work factor accepted when reading. Anything larger is
/// rejected before any key derivation runs, which bounds the CPU and memory
/// (1 GiB at 20) that an untrusted file can demand.
const int ageMaxScryptWorkFactor = 20;

void _checkWriterWorkFactor(int workFactor) {
  if (workFactor < 1 || workFactor > ageMaxScryptWorkFactor) {
    throw RangeError.range(
        workFactor, 1, ageMaxScryptWorkFactor, 'scryptWorkFactor');
  }
}

void _checkReaderWorkFactorLimit(int limit) {
  if (limit < 1 || limit > ageMaxScryptWorkFactor) {
    throw RangeError.range(
        limit, 1, ageMaxScryptWorkFactor, 'maxScryptWorkFactor');
  }
}

/// Creates the header for a new age file and the random file key it wraps.
///
/// Give either one or more X25519 [recipients] (`age1…`) or a [passphrase],
/// never both: the format forbids mixing a passphrase with other recipients.
/// A fresh 16-byte file key is generated on every call and must be used for
/// exactly one object and one upload attempt.
///
/// The caller then picks a random 16-byte payload nonce, writes
/// `header.bytes || nonce || chunks`, and seals chunks with an
/// [AgePayloadCipher] created from the returned file key and that nonce.
/// Wipe the file key when done; it must never be persisted.
///
/// Throws [AgeInvalidKeyException] or [AgeUnsupportedException] for a bad or
/// unsupported recipient string, and [ArgumentError] for an invalid
/// combination of arguments.
Future<({AgeHeader header, Uint8List fileKey})> ageNewHeader({
  List<String> recipients = const <String>[],
  String? passphrase,
  int scryptWorkFactor = ageDefaultScryptWorkFactor,
}) async {
  if (passphrase != null && recipients.isNotEmpty) {
    throw ArgumentError(
        'A passphrase cannot be combined with other age recipients.');
  }
  if (passphrase == null && recipients.isEmpty) {
    throw ArgumentError(
        'At least one age recipient or a passphrase is needed.');
  }
  if (passphrase != null && passphrase.isEmpty) {
    throw ArgumentError('The passphrase must not be empty.');
  }
  _checkWriterWorkFactor(scryptWorkFactor);
  // Validate every recipient before generating any secret.
  final recipientKeys = <Uint8List>[
    for (final recipient in recipients) _parseRecipient(recipient),
  ];

  final fileKey = ageRandomBytes(ageFileKeyLength);
  try {
    final stanzas = <AgeStanza>[
      if (passphrase != null)
        await _wrapForPassphrase(fileKey, passphrase, scryptWorkFactor),
      for (final key in recipientKeys) await _wrapForX25519(fileKey, key),
    ];
    final header = await AgeHeader._seal(stanzas, fileKey);
    return (header: header, fileKey: fileKey);
  } catch (_) {
    ageWipe(fileKey);
    rethrow;
  }
}

/// Parses the header at the start of an age object, unwraps the file key
/// and verifies the header MAC.
///
/// [prefix] is the first bytes of the object; bytes after the header are
/// ignored, so a caller can pass the result of a ranged read. Throws
/// [AgeIncompleteHeaderException] when more bytes are needed (a header never
/// exceeds [ageMaxHeaderLength] bytes).
///
/// Supply [identities] for files encrypted to X25519 recipients, or a
/// [passphrase] for passphrase-protected files. `headerLength` in the result
/// equals `header.length`: the payload nonce is the next
/// [agePayloadNonceLength] bytes of the object.
///
/// Throws [AgeNoMatchingIdentityException] when no identity fits (wrong key)
/// or the wrong kind of secret was supplied, [AgeWrongPassphraseException]
/// for a wrong passphrase, [AgeAuthenticationException] (with a null chunk
/// index) when the header was tampered with, [AgeMalformedException] and
/// [AgeUnsupportedException] for invalid or unsupported files. A scrypt work
/// factor above [maxScryptWorkFactor] is rejected before any key derivation.
Future<({AgeHeader header, Uint8List fileKey, int headerLength})> ageReadHeader(
  Uint8List prefix, {
  List<AgeIdentity> identities = const <AgeIdentity>[],
  String? passphrase,
  int maxScryptWorkFactor = ageMaxScryptWorkFactor,
}) async {
  _checkReaderWorkFactorLimit(maxScryptWorkFactor);
  final header = AgeHeader.parse(prefix);
  final fileKey = await _unwrapFileKey(
    header,
    identities: identities,
    passphrase: passphrase,
    maxScryptWorkFactor: maxScryptWorkFactor,
  );
  return (header: header, fileKey: fileKey, headerLength: header.length);
}

/// Encrypts [plaintext] into a complete age file held in memory.
///
/// Give either X25519 [recipients] or a [passphrase] (see [ageNewHeader]).
/// [scryptWorkFactor] applies to passphrase encryption only.
///
/// Intended for key files, small objects and previews. The payload cipher
/// runs on the calling isolate, so encrypt large buffers on a worker
/// isolate or use the chunk API.
Future<Uint8List> ageEncrypt(
  Uint8List plaintext, {
  List<String> recipients = const <String>[],
  String? passphrase,
  int scryptWorkFactor = ageDefaultScryptWorkFactor,
}) async {
  final created = await ageNewHeader(
    recipients: recipients,
    passphrase: passphrase,
    scryptWorkFactor: scryptWorkFactor,
  );
  try {
    final header = created.header;
    final nonce = ageRandomBytes(agePayloadNonceLength);
    final cipher = await AgePayloadCipher.create(created.fileKey, nonce);
    final out = Uint8List(ageCiphertextLength(
      headerLength: header.length,
      plaintextLength: plaintext.length,
    ));
    out.setRange(0, header.length, header._bytes);
    var offset = header.length;
    out.setRange(offset, offset + nonce.length, nonce);
    offset += nonce.length;
    final chunks = ageChunkCount(plaintext.length);
    for (var index = 0; index < chunks; index++) {
      final start = index * ageChunkSize;
      final end = min(start + ageChunkSize, plaintext.length);
      final sealed = await cipher.sealChunk(
        index,
        Uint8List.sublistView(plaintext, start, end),
        last: index == chunks - 1,
      );
      out.setRange(offset, offset + sealed.length, sealed);
      offset += sealed.length;
    }
    return out;
  } finally {
    ageWipe(created.fileKey);
  }
}

/// Decrypts a complete age file held in memory and returns the plaintext.
///
/// Supply [identities] or a [passphrase] as for [ageReadHeader]. Plaintext
/// is returned only when the header MAC and every chunk authenticate and
/// the final chunk carries the final flag, so truncated, extended,
/// reordered or modified files never yield partial output. The failing
/// chunk is reported in [AgeAuthenticationException.chunkIndex].
Future<Uint8List> ageDecrypt(
  Uint8List file, {
  List<AgeIdentity> identities = const <AgeIdentity>[],
  String? passphrase,
  int maxScryptWorkFactor = ageMaxScryptWorkFactor,
}) async {
  final ({AgeHeader header, Uint8List fileKey, int headerLength}) opened;
  try {
    opened = await ageReadHeader(
      file,
      identities: identities,
      passphrase: passphrase,
      maxScryptWorkFactor: maxScryptWorkFactor,
    );
  } on AgeIncompleteHeaderException {
    throw const AgeMalformedException(
        'Malformed age file: truncated inside the header.');
  }
  try {
    final headerLength = opened.headerLength;
    if (file.length < headerLength + agePayloadNonceLength) {
      throw const AgeMalformedException(
          'Malformed age file: truncated before the payload nonce.');
    }
    final plaintextLength = agePlaintextLength(
      headerLength: headerLength,
      ciphertextLength: file.length,
    );
    final nonce = Uint8List.sublistView(
      file,
      headerLength,
      headerLength + agePayloadNonceLength,
    );
    final cipher = await AgePayloadCipher.create(opened.fileKey, nonce);
    final out = Uint8List(plaintextLength);
    final chunks = ageChunkCount(plaintextLength);
    for (var index = 0; index < chunks; index++) {
      final start = ageChunkOffset(headerLength: headerLength, index: index);
      final end = min(start + _sealedChunkSize, file.length);
      final clear = await cipher.openChunk(
        index,
        Uint8List.sublistView(file, start, end),
        last: index == chunks - 1,
      );
      out.setRange(
          index * ageChunkSize, index * ageChunkSize + clear.length, clear);
    }
    return out;
  } finally {
    ageWipe(opened.fileKey);
  }
}
