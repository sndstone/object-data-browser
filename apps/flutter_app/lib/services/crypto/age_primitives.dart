/// Thin adapters over the primitive packages. Nothing in this file
/// implements a cipher, hash, KDF or curve operation itself:
///
/// * X25519, ChaCha20-Poly1305, HKDF-SHA-256 and HMAC-SHA-256 come from
///   `package:cryptography` (pure Dart by default).
/// * scrypt comes from `package:pointycastle`.
///
/// This file is an implementation detail of `age.dart`; import that instead.
library;

import 'dart:convert';
import 'dart:isolate';
import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:pointycastle/key_derivators/api.dart' show ScryptParameters;
import 'package:pointycastle/key_derivators/scrypt.dart' show Scrypt;

final Random _secureRandom = Random.secure();

/// Returns [length] bytes from the operating system CSPRNG.
Uint8List ageRandomBytes(int length) {
  final bytes = Uint8List(length);
  for (var i = 0; i < length; i++) {
    bytes[i] = _secureRandom.nextInt(256);
  }
  return bytes;
}

/// Overwrites [bytes] with zeros. Best effort: the Dart VM may have copied
/// the data elsewhere.
void ageWipe(List<int>? bytes) {
  if (bytes == null) return;
  try {
    bytes.fillRange(0, bytes.length, 0);
  } on UnsupportedError {
    // Unmodifiable view; nothing to do.
  }
}

/// Compares two byte strings without an early exit on the first difference.
bool ageConstantTimeEquals(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  var diff = 0;
  for (var i = 0; i < a.length; i++) {
    diff |= a[i] ^ b[i];
  }
  return diff == 0;
}

/// Unpadded standard base64, as the age header uses.
String ageBase64Encode(List<int> bytes) =>
    base64.encode(bytes).replaceAll('=', '');

/// Strictly decodes unpadded, canonical standard base64.
///
/// Returns null for padding characters, characters outside the alphabet,
/// impossible lengths and non-canonical trailing bits.
Uint8List? ageBase64DecodeStrict(String text) {
  if (text.length % 4 == 1) return null;
  for (final c in text.codeUnits) {
    final ok = (c >= 0x41 && c <= 0x5a) || // A-Z
        (c >= 0x61 && c <= 0x7a) || // a-z
        (c >= 0x30 && c <= 0x39) || // 0-9
        c == 0x2b || // +
        c == 0x2f; // /
    if (!ok) return null;
  }
  final padded = text.padRight((text.length + 3) & ~3, '=');
  final Uint8List decoded;
  try {
    decoded = base64.decode(padded);
  } on FormatException {
    return null;
  }
  // dart:convert accepts non-zero trailing bits; re-encoding detects them.
  if (ageBase64Encode(decoded) != text) return null;
  return decoded;
}

/// X25519(secret, basepoint).
Future<Uint8List> ageX25519PublicKey(Uint8List secret) async {
  final keyPair = await X25519().newKeyPairFromSeed(secret);
  final publicKey = await keyPair.extractPublicKey();
  return Uint8List.fromList(publicKey.bytes);
}

/// X25519(secret, peerPublicKey). The result may be all zeros for low-order
/// inputs; callers must check.
Future<Uint8List> ageX25519SharedSecret(
  Uint8List secret,
  Uint8List peerPublicKey,
) async {
  final algorithm = X25519();
  final keyPair = await algorithm.newKeyPairFromSeed(secret);
  final shared = await algorithm.sharedSecretKey(
    keyPair: keyPair,
    remotePublicKey: SimplePublicKey(peerPublicKey, type: KeyPairType.x25519),
  );
  return Uint8List.fromList(await shared.extractBytes());
}

/// HKDF-SHA-256 (extract then expand) with a 32-byte output.
Future<Uint8List> ageHkdfSha256({
  required List<int> ikm,
  required List<int> salt,
  required String info,
}) async {
  final derived = await Hkdf(hmac: Hmac.sha256(), outputLength: 32).deriveKey(
    secretKey: SecretKey(ikm),
    nonce: salt,
    info: ascii.encode(info),
  );
  return Uint8List.fromList(await derived.extractBytes());
}

/// HMAC-SHA-256.
Future<Uint8List> ageHmacSha256(List<int> key, List<int> message) async {
  final mac = await Hmac.sha256().calculateMac(
    message,
    secretKey: SecretKey(key),
  );
  return Uint8List.fromList(mac.bytes);
}

/// Length of a ChaCha20-Poly1305 tag.
const int ageAeadTagLength = 16;

/// ChaCha20-Poly1305 (RFC 7539) seal. Returns ciphertext followed by the
/// 16-byte tag.
Future<Uint8List> ageAeadSeal(
  SecretKey key,
  List<int> nonce,
  List<int> plaintext,
) async {
  final box = await Chacha20.poly1305Aead().encrypt(
    plaintext,
    secretKey: key,
    nonce: nonce,
  );
  final out = Uint8List(plaintext.length + ageAeadTagLength);
  out.setRange(0, plaintext.length, box.cipherText);
  out.setRange(plaintext.length, out.length, box.mac.bytes);
  return out;
}

/// ChaCha20-Poly1305 (RFC 7539) open. Returns null when the tag does not
/// verify. [sealed] must be at least [ageAeadTagLength] bytes.
Future<Uint8List?> ageAeadOpen(
  SecretKey key,
  List<int> nonce,
  Uint8List sealed,
) async {
  final split = sealed.length - ageAeadTagLength;
  final box = SecretBox(
    Uint8List.sublistView(sealed, 0, split),
    nonce: nonce,
    mac: Mac(Uint8List.sublistView(sealed, split)),
  );
  try {
    final clear = await Chacha20.poly1305Aead().decrypt(box, secretKey: key);
    return clear is Uint8List ? clear : Uint8List.fromList(clear);
  } on SecretBoxAuthenticationError {
    return null;
  }
}

/// Label prepended to the random salt of an scrypt stanza.
const String ageScryptSaltLabel = 'age-encryption.org/v1/scrypt';

Uint8List _scryptSync(Uint8List passphrase, Uint8List salt, int logN) {
  final labelled = Uint8List(ageScryptSaltLabel.length + salt.length)
    ..setRange(0, ageScryptSaltLabel.length, ascii.encode(ageScryptSaltLabel))
    ..setRange(ageScryptSaltLabel.length,
        ageScryptSaltLabel.length + salt.length, salt);
  final derivator = Scrypt()
    ..init(ScryptParameters(1 << logN, 8, 1, 32, labelled));
  return derivator.process(passphrase);
}

/// Derives the scrypt wrap key for an age scrypt stanza on a helper isolate:
/// `scrypt(N = 2^logN, r = 8, p = 1, dkLen = 32,
/// S = "age-encryption.org/v1/scrypt" || salt, P = passphrase)`.
///
/// Memory use is `128 * 8 * 2^logN` bytes (32 MiB at 15, 256 MiB at 18).
Future<Uint8List> ageScryptWrapKey(
  Uint8List passphrase,
  Uint8List salt,
  int logN,
) {
  // Only sendable values are in scope, so the closure captures nothing else.
  return Isolate.run(() => _scryptSync(passphrase, salt, logN));
}
