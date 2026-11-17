// The binary age payload: STREAM chunk cipher and size/offset arithmetic.
part of 'age.dart';

/// Plaintext bytes per payload chunk (64 KiB). Only the final chunk may be
/// shorter.
const int ageChunkSize = 65536;

/// Bytes added to every chunk by its ChaCha20-Poly1305 tag.
const int ageChunkOverhead = 16;

/// Length of the random payload nonce that follows the header.
const int agePayloadNonceLength = 16;

const int _sealedChunkSize = ageChunkSize + ageChunkOverhead;

/// The ChaCha20-Poly1305 STREAM cipher of one age payload.
///
/// An instance is bound to one file key and one 16-byte payload nonce, and
/// seals or opens chunks by index in any order. That makes it suitable for
/// parallel multipart uploads and ranged reads: chunk `i` covers plaintext
/// bytes `[i * 65536, (i + 1) * 65536)`.
///
/// Rules the caller must uphold when sealing:
///
/// * Never seal two different plaintexts with the same index (and `last`
///   flag) under one cipher: a retried part must re-read identical bytes.
/// * Use a fresh file key and nonce for every object and every new upload
///   attempt.
///
/// Rules to uphold when opening: release plaintext only from chunks that
/// opened successfully, and treat an object as complete only after its final
/// chunk opened with `last: true`.
///
/// The cipher runs on the calling isolate; process large objects on a
/// worker isolate.
final class AgePayloadCipher {
  AgePayloadCipher._(this._key);

  final SecretKey _key;

  /// Derives the payload key
  /// `HKDF-SHA-256(ikm = fileKey, salt = payloadNonce, info = "payload")`.
  ///
  /// [fileKey] is the 16-byte file key from [ageNewHeader] or
  /// [ageReadHeader]; [payloadNonce] is the 16 bytes that follow the header.
  static Future<AgePayloadCipher> create(
    Uint8List fileKey,
    Uint8List payloadNonce,
  ) async {
    if (fileKey.length != ageFileKeyLength) {
      throw ArgumentError('The age file key must be 16 bytes.');
    }
    if (payloadNonce.length != agePayloadNonceLength) {
      throw ArgumentError('The age payload nonce must be 16 bytes.');
    }
    final key = await ageHkdfSha256(
      ikm: fileKey,
      salt: payloadNonce,
      info: 'payload',
    );
    return AgePayloadCipher._(SecretKey(key));
  }

  /// 11-byte big-endian chunk counter followed by the final-chunk flag.
  static Uint8List _nonce(int index, bool last) {
    RangeError.checkNotNegative(index, 'index');
    final nonce = Uint8List(12);
    ByteData.sublistView(nonce).setUint64(3, index);
    nonce[11] = last ? 1 : 0;
    return nonce;
  }

  /// Encrypts chunk [index] and returns ciphertext followed by its 16-byte
  /// tag.
  ///
  /// Every chunk except the last must be exactly [ageChunkSize] bytes. The
  /// last chunk may be shorter, and may be empty only when it is chunk 0 of
  /// an empty payload. Violations throw [ArgumentError].
  Future<Uint8List> sealChunk(
    int index,
    Uint8List plaintext, {
    required bool last,
  }) async {
    if (plaintext.length > ageChunkSize) {
      throw ArgumentError('A chunk holds at most $ageChunkSize bytes.');
    }
    if (!last && plaintext.length != ageChunkSize) {
      throw ArgumentError(
          'Only the final chunk may be shorter than $ageChunkSize bytes.');
    }
    if (last && plaintext.isEmpty && index != 0) {
      throw ArgumentError(
          'The final chunk may be empty only when the payload is empty.');
    }
    return ageAeadSeal(_key, _nonce(index, last), plaintext);
  }

  /// Authenticates and decrypts chunk [index].
  ///
  /// [ciphertext] is the stored chunk including its tag. Throws
  /// [AgeMalformedException] for a size no valid file can contain (a short
  /// non-final chunk, a chunk shorter than a tag, an empty final chunk after
  /// chunk 0) and [AgeAuthenticationException] carrying [index] when the tag
  /// does not verify, which is also what truncation, reordering and a wrong
  /// `last` flag produce.
  Future<Uint8List> openChunk(
    int index,
    Uint8List ciphertext, {
    required bool last,
  }) async {
    if (ciphertext.length < ageChunkOverhead ||
        ciphertext.length > _sealedChunkSize) {
      throw AgeMalformedException(
          'Malformed age payload: chunk $index has an impossible size.');
    }
    if (!last && ciphertext.length != _sealedChunkSize) {
      throw AgeMalformedException(
          'Malformed age payload: chunk $index is short but not final.');
    }
    if (last && ciphertext.length == ageChunkOverhead && index != 0) {
      throw AgeMalformedException(
          'Malformed age payload: empty final chunk $index.');
    }
    final plaintext = await ageAeadOpen(_key, _nonce(index, last), ciphertext);
    if (plaintext == null) {
      throw AgeAuthenticationException(
        'Age payload chunk $index failed authentication; the data is '
        'corrupt, truncated or was modified.',
        chunkIndex: index,
      );
    }
    return plaintext;
  }
}

// ---------------------------------------------------------------------------
// Pure size and offset arithmetic
// ---------------------------------------------------------------------------

/// Number of payload chunks for [plaintextLength] bytes. An empty payload
/// still has one (empty, final) chunk.
int ageChunkCount(int plaintextLength) {
  RangeError.checkNotNegative(plaintextLength, 'plaintextLength');
  if (plaintextLength == 0) return 1;
  return (plaintextLength + ageChunkSize - 1) ~/ ageChunkSize;
}

/// Size in bytes of the age file that holds [plaintextLength] bytes behind a
/// header of [headerLength] bytes:
/// `header + 16 (nonce) + plaintext + 16 * max(1, ceil(plaintext / 65536))`.
int ageCiphertextLength({
  required int headerLength,
  required int plaintextLength,
}) {
  RangeError.checkNotNegative(headerLength, 'headerLength');
  return headerLength +
      agePayloadNonceLength +
      plaintextLength +
      ageChunkOverhead * ageChunkCount(plaintextLength);
}

/// Inverse of [ageCiphertextLength]: the plaintext size of an age file of
/// [ciphertextLength] bytes whose header is [headerLength] bytes.
///
/// Throws [AgeMalformedException] for a size no valid age file can have: too
/// short for the nonce and one tag, a final chunk shorter than a tag, or an
/// empty final chunk after a full one. Such an object is truncated or not a
/// complete age file.
int agePlaintextLength({
  required int headerLength,
  required int ciphertextLength,
}) {
  RangeError.checkNotNegative(headerLength, 'headerLength');
  RangeError.checkNotNegative(ciphertextLength, 'ciphertextLength');
  final body = ciphertextLength - headerLength - agePayloadNonceLength;
  if (body < ageChunkOverhead) {
    throw const AgeMalformedException(
        'Malformed age file: too short to hold a payload nonce and chunk.');
  }
  final chunks = (body + _sealedChunkSize - 1) ~/ _sealedChunkSize;
  final finalChunk = body - (chunks - 1) * _sealedChunkSize;
  if (finalChunk < ageChunkOverhead) {
    throw const AgeMalformedException(
        'Malformed age file: the final chunk is shorter than its tag.');
  }
  if (finalChunk == ageChunkOverhead && chunks > 1) {
    throw const AgeMalformedException(
        'Malformed age file: empty final chunk after a full chunk.');
  }
  return body - ageChunkOverhead * chunks;
}

/// Offset of sealed chunk [index] from the start of the age file.
int ageChunkOffset({required int headerLength, required int index}) {
  RangeError.checkNotNegative(headerLength, 'headerLength');
  RangeError.checkNotNegative(index, 'index');
  return headerLength + agePayloadNonceLength + index * _sealedChunkSize;
}

/// Maps the plaintext byte range `[start, endExclusive)` to the ciphertext
/// byte range that must be fetched to decrypt it, as whole chunks.
///
/// The result gives file offsets `[start, endExclusive)` and the inclusive
/// chunk indices `firstChunk..lastChunk` they hold. Chunk `i` of the result
/// begins at `start + (i - firstChunk) * 65552`; it is the final chunk
/// (`last: true`) exactly when `i == ageChunkCount(plaintextLength) - 1`.
///
/// The range must satisfy `0 <= start <= endExclusive <= plaintextLength`.
/// An empty range is answered with the single chunk that contains `start`
/// (the final chunk when `start == plaintextLength`), so a caller can still
/// authenticate that position. The 16-byte payload nonce at
/// `[headerLength, headerLength + 16)` is not part of the returned range and
/// must be read separately (normally together with the header).
({int start, int endExclusive, int firstChunk, int lastChunk})
    ageCiphertextRangeForPlaintext({
  required int headerLength,
  required int plaintextLength,
  required int start,
  required int endExclusive,
}) {
  RangeError.checkNotNegative(headerLength, 'headerLength');
  RangeError.checkNotNegative(plaintextLength, 'plaintextLength');
  RangeError.checkValueInInterval(start, 0, plaintextLength, 'start');
  RangeError.checkValueInInterval(
      endExclusive, start, plaintextLength, 'endExclusive');
  final finalChunk = ageChunkCount(plaintextLength) - 1;
  final firstChunk = min(start ~/ ageChunkSize, finalChunk);
  final lastChunk =
      endExclusive > start ? (endExclusive - 1) ~/ ageChunkSize : firstChunk;
  final total = ageCiphertextLength(
    headerLength: headerLength,
    plaintextLength: plaintextLength,
  );
  return (
    start: ageChunkOffset(headerLength: headerLength, index: firstChunk),
    endExclusive: min(
      ageChunkOffset(headerLength: headerLength, index: lastChunk + 1),
      total,
    ),
    firstChunk: firstChunk,
    lastChunk: lastChunk,
  );
}

/// Maps the ciphertext byte range `[start, endExclusive)` of an age file to
/// the inclusive chunk indices that overlap it, or null when the range holds
/// only header and nonce bytes.
///
/// This is the mapping a multipart upload worker needs: a part that covers
/// ciphertext bytes `[a, b)` must seal chunks `firstChunk..lastChunk` and
/// emit the overlapping slice. Boundary chunks are shared with the
/// neighbouring parts and seal to identical bytes.
///
/// The range must be non-empty and lie within the file.
({int firstChunk, int lastChunk})? ageChunksForCiphertextRange({
  required int headerLength,
  required int plaintextLength,
  required int start,
  required int endExclusive,
}) {
  final total = ageCiphertextLength(
    headerLength: headerLength,
    plaintextLength: plaintextLength,
  );
  RangeError.checkValueInInterval(start, 0, total - 1, 'start');
  RangeError.checkValueInInterval(
      endExclusive, start + 1, total, 'endExclusive');
  final payloadStart = headerLength + agePayloadNonceLength;
  if (endExclusive <= payloadStart) return null;
  final first =
      start <= payloadStart ? 0 : (start - payloadStart) ~/ _sealedChunkSize;
  final last = (endExclusive - 1 - payloadStart) ~/ _sealedChunkSize;
  return (firstChunk: first, lastChunk: last);
}
