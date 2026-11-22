import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;

/// Fixture bytes and the digests the conformance suite compares against.
abstract final class ConformanceBytes {
  /// byte i = (seed * 131 + i * 7 + (i >> 10)) & 0xFF.
  /// Vectors: contracts/vectors/s3-conformance-body.json.
  static Uint8List generate(int size, int seed) {
    final out = Uint8List(size);
    final base = seed * 131;
    for (var i = 0; i < size; i++) {
      out[i] = (base + i * 7 + (i >> 10)) & 0xFF;
    }
    return out;
  }

  static String sha256Hex(List<int> data) =>
      crypto.sha256.convert(data).toString();

  static String md5Hex(List<int> data) => crypto.md5.convert(data).toString();

  static String md5Base64(List<int> data) =>
      base64.encode(crypto.md5.convert(data).bytes);

  static String sha1Base64(List<int> data) =>
      base64.encode(crypto.sha1.convert(data).bytes);

  static String sha256Base64(List<int> data) =>
      base64.encode(crypto.sha256.convert(data).bytes);

  static String crc32Base64(List<int> data) =>
      _uint32Base64(_crc(data, _crc32Table));

  static String crc32cBase64(List<int> data) =>
      _uint32Base64(_crc(data, _crc32cTable));

  /// Checksum value for the S3 `ChecksumAlgorithm` name.
  static String checksum(String algorithm, List<int> data) =>
      switch (algorithm) {
        'CRC32' => crc32Base64(data),
        'CRC32C' => crc32cBase64(data),
        'SHA1' => sha1Base64(data),
        'SHA256' => sha256Base64(data),
        _ => throw ArgumentError.value(algorithm, 'algorithm'),
      };

  static String _uint32Base64(int value) => base64.encode([
        (value >> 24) & 0xFF,
        (value >> 16) & 0xFF,
        (value >> 8) & 0xFF,
        value & 0xFF,
      ]);

  static int _crc(List<int> data, List<int> table) {
    var crc = 0xFFFFFFFF;
    for (final byte in data) {
      crc = table[(crc ^ byte) & 0xFF] ^ (crc >> 8);
    }
    return (crc ^ 0xFFFFFFFF) & 0xFFFFFFFF;
  }

  static final List<int> _crc32Table = _table(0xEDB88320);
  static final List<int> _crc32cTable = _table(0x82F63B78);

  static List<int> _table(int polynomial) => List<int>.generate(256, (n) {
        var c = n;
        for (var k = 0; k < 8; k++) {
          c = (c & 1) != 0 ? polynomial ^ (c >> 1) : c >> 1;
        }
        return c;
      }, growable: false);
}
