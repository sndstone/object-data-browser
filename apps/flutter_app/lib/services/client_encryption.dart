import 'crypto/age_primitives.dart' show ageRandomBytes, ageWipe;
import 'dart:convert';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';
import '../models/client_encryption.dart';
import 'crypto/age.dart';
import 'multipart_sizing.dart';

/// This map exists only for the duration of an engine request. Never retain it
/// in a job, event or retry closure. New attempts create new headers and nonces.
Future<T> withClientUpload<T>(
  ClientEncryptionRule rule,
  Future<T> Function(Map<String, Object?> payload, int headerLength) dispatch,
) async {
  final fresh = await ageNewHeader(recipients: [rule.recipient]);
  try {
    return await dispatch({
      'format': 'age-v1',
      'header': base64Encode(fresh.header.bytes),
      'payloadNonce': base64Encode(ageRandomBytes(16)),
      'fileKey': base64Encode(fresh.fileKey),
    }, fresh.header.length);
  } finally {
    ageWipe(fresh.fileKey);
  }
}

int clientUploadPartSizeMiB({
  required int headerLength,
  required int plaintextLength,
  required bool automatic,
  required int manualMiB,
}) {
  final size = ageCiphertextLength(
    headerLength: headerLength,
    plaintextLength: plaintextLength,
  );
  final recommended = MultipartSizing.recommendedPartSizeMiB(size);
  final part = automatic
      ? recommended
      : MultipartSizing.compliantManualPartSizeMiB(manualMiB);
  if (MultipartSizing.partCount(fileSizeBytes: size, partSizeMiB: part) >
      MultipartSizing.maximumParts) {
    throw ArgumentError(
      'Manual part size is too small for the encrypted object. Enable automatic sizing or increase it.',
    );
  }
  return part;
}

typedef PreviewRangeFetcher = Future<Uint8List> Function(
  String url,
  int start,
  int endExclusive,
  int objectSize,
  String? etag,
);

class ClientObjectHeader {
  ClientObjectHeader(this.fileKey, this.headerLength, this.plaintextLength);
  final Uint8List fileKey;
  final int headerLength, plaintextLength;
  Map<String, Object?> get downloadParameters => {
        'format': 'age-v1',
        'headerLength': headerLength,
        'fileKey': base64Encode(fileKey),
      };
  void dispose() => ageWipe(fileKey);
  @override
  String toString() => 'ClientObjectHeader(age-v1)';
}

/// Ranged, bounded authenticated reads. No plaintext is returned until every
/// requested chunk has authenticated. The true stored size determines last.
class ClientObjectReader {
  ClientObjectReader(this.fetch);
  final PreviewRangeFetcher fetch;
  Future<ClientObjectHeader> open(
    String url,
    int size,
    String? etag,
    List<AgeIdentity> identities,
  ) async {
    for (var limit = 8192; limit <= 65536; limit *= 2) {
      final prefix = await fetch(url, 0, math.min(size, limit), size, etag);
      try {
        final opened = await ageReadHeader(prefix, identities: identities);
        try {
          return ClientObjectHeader(
            opened.fileKey,
            opened.headerLength,
            agePlaintextLength(
              headerLength: opened.headerLength,
              ciphertextLength: size,
            ),
          );
        } catch (_) {
          ageWipe(opened.fileKey);
          rethrow;
        }
      } on AgeIncompleteHeader {
        if (limit == 65536 || limit >= size) rethrow;
      }
    }
    throw const FormatException('The age header exceeds the supported limit.');
  }

  Future<Uint8List> preview(
    String url,
    int size,
    String? etag,
    ClientObjectHeader header,
    int limit,
  ) async {
    final count = math.min(limit, header.plaintextLength);
    final range = ageCiphertextRangeForPlaintext(
      headerLength: header.headerLength,
      plaintextLength: header.plaintextLength,
      start: 0,
      endExclusive: count,
    );
    final nonce = await fetch(
      url,
      header.headerLength,
      header.headerLength + agePayloadNonceLength,
      size,
      etag,
    );
    final sealed = await fetch(
      url,
      range.start,
      range.endExclusive,
      size,
      etag,
    );
    final input = (
      key: Uint8List.fromList(header.fileKey),
      nonce: nonce,
      sealed: sealed,
      plaintextLength: header.plaintextLength,
      first: range.firstChunk,
      last: range.lastChunk,
      count: count,
    );
    try {
      return await Isolate.run(() => decryptClientPreview(input));
    } finally {
      ageWipe(input.key);
    }
  }
}

typedef ClientPreviewInput = ({
  Uint8List key,
  Uint8List nonce,
  Uint8List sealed,
  int plaintextLength,
  int first,
  int last,
  int count,
});

Future<Uint8List> decryptClientPreview(ClientPreviewInput input) async {
  final output = Uint8List(input.count);
  try {
    final cipher = await AgePayloadCipher.create(input.key, input.nonce);
    var offset = 0, written = 0;
    for (var index = input.first; index <= input.last; index++) {
      final end = math.min(
          offset + ageChunkSize + ageChunkOverhead, input.sealed.length);
      final chunk = await cipher.openChunk(
          index, Uint8List.sublistView(input.sealed, offset, end),
          last: index == ageChunkCount(input.plaintextLength) - 1);
      final count = math.min(chunk.length, output.length - written);
      output.setRange(written, written + count, chunk);
      written += count;
      ageWipe(chunk);
      offset = end;
    }
    return output;
  } catch (_) {
    ageWipe(output);
    rethrow;
  } finally {
    ageWipe(input.key);
  }
}
