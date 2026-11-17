/// Host-only vault names. No derived key or decoded name belongs in diagnostics.
library;

import 'dart:convert';
import 'dart:typed_data';
import 'package:crypto/crypto.dart' as crypto;
import 'package:pointycastle/export.dart';
import 'age_primitives.dart'
    show ageRandomBytes, ageWipe, ageConstantTimeEquals;

Uint8List _hkdf(List<int> secret, List<int> salt, String info, int length) {
  final prk = Uint8List.fromList(
      crypto.Hmac(crypto.sha256, salt.isEmpty ? Uint8List(32) : salt)
          .convert(secret)
          .bytes);
  final out = BytesBuilder();
  var previous = Uint8List(0);
  try {
    for (var i = 1; out.length < length; i++) {
      final next = Uint8List.fromList(crypto.Hmac(crypto.sha256, prk)
          .convert([...previous, ...utf8.encode(info), i]).bytes);
      ageWipe(previous);
      previous = next;
      out.add(next);
    }
    final expanded = out.takeBytes();
    final result = Uint8List.fromList(expanded.sublist(0, length));
    ageWipe(expanded);
    return result;
  } finally {
    ageWipe(prk);
    ageWipe(previous);
  }
}

final class VaultNameKeys {
  VaultNameKeys.fromIdentitySecret(Uint8List secret)
      : deterministic = _hkdf(
            secret, [], 'object-data-browser/vault-names/v1/deterministic', 32),
        random =
            _hkdf(secret, [], 'object-data-browser/vault-names/v1/random', 32) {
    if (secret.length != 32) {
      wipe();
      throw ArgumentError('An X25519 identity must contain 32 bytes.');
    }
  }
  final Uint8List deterministic, random;
  final Map<String, String?> _decoded = {};
  bool _wiped = false;
  void wipe() {
    ageWipe(deterministic);
    ageWipe(random);
    _decoded.clear();
    _wiped = true;
  }

  String? open(String token) {
    if (_wiped) return null;
    if (_decoded.containsKey(token)) return _decoded[token];
    // Bound retention even when a listing contains many malformed names.
    if (_decoded.length >= 20000) _decoded.clear();
    return _decoded[token] = openVaultName(token, this);
  }

  void _check() {
    if (_wiped) throw StateError('Unlock your encryption key file first.');
  }
}

Uint8List _cmac(Uint8List key, Uint8List input) =>
    (CMac(AESEngine(), 128)..init(KeyParameter(key))).process(input);
Uint8List _double(Uint8List block) {
  final out = Uint8List(16);
  var carry = 0;
  for (var i = 15; i >= 0; i--) {
    out[i] = ((block[i] << 1) & 255) | carry;
    carry = block[i] >> 7;
  }
  out[15] ^= 0x87 * carry;
  return out;
}

void _xor(Uint8List target, Uint8List other, [int offset = 0]) {
  for (var i = 0; i < other.length; i++) {
    target[offset + i] ^= other[i];
  }
}

/// RFC 5297 S2V. Associated data is a list of byte strings (none for names).
Uint8List vaultS2v(
    Uint8List key, List<Uint8List> associatedData, Uint8List plaintext) {
  if (associatedData.length > 126) {
    throw ArgumentError('Too much associated data.');
  }
  var d = _cmac(key, Uint8List(16));
  for (final item in associatedData) {
    final next = _double(d);
    ageWipe(d);
    d = next;
    final mac = _cmac(key, item);
    _xor(d, mac);
    ageWipe(mac);
  }
  final Uint8List input;
  if (plaintext.length >= 16) {
    input = Uint8List.fromList(plaintext);
    _xor(input, d, input.length - 16);
  } else {
    input = _double(d);
    final padded = Uint8List(16)..setAll(0, plaintext);
    padded[plaintext.length] = 0x80;
    _xor(input, padded);
    ageWipe(padded);
  }
  try {
    return _cmac(key, input);
  } finally {
    ageWipe(d);
    ageWipe(input);
  }
}

Uint8List _ctr(Uint8List key, Uint8List iv, Uint8List input) {
  final counter = Uint8List.fromList(iv);
  counter[8] &= 0x7f;
  counter[12] &= 0x7f;
  final cipher = SICStreamCipher(AESEngine())
    ..init(true, ParametersWithIV(KeyParameter(key), counter));
  return cipher.process(input);
}

/// Raw RFC 5297 sealing, also used for the appendix interoperability vectors.
Uint8List vaultSivSeal(Uint8List key, Uint8List plaintext,
    {List<Uint8List> associatedData = const []}) {
  // RFC 5297's 256-bit key form: AES-128 for S2V and AES-128 for CTR. It is
  // the form the RFC's own vectors use, and the only one pointycastle's CMAC
  // accepts.
  if (key.length != 32) {
    throw ArgumentError('Invalid AES-SIV key length.');
  }
  final half = key.length ~/ 2;
  final iv =
      vaultS2v(Uint8List.sublistView(key, 0, half), associatedData, plaintext);
  return Uint8List.fromList(
      [...iv, ..._ctr(Uint8List.sublistView(key, half), iv, plaintext)]);
}

Uint8List? vaultSivOpen(Uint8List key, Uint8List sealed,
    {List<Uint8List> associatedData = const []}) {
  if (sealed.length < 16 || key.length != 32) return null;
  final half = key.length ~/ 2;
  final iv = Uint8List.sublistView(sealed, 0, 16);
  final clear = _ctr(
      Uint8List.sublistView(key, half), iv, Uint8List.sublistView(sealed, 16));
  final expected =
      vaultS2v(Uint8List.sublistView(key, 0, half), associatedData, clear);
  final valid = ageConstantTimeEquals(iv, expected);
  ageWipe(expected);
  if (valid) return clear;
  ageWipe(clear);
  return null;
}

// BaseAEADCipher.process does not finalize or authenticate. Always call
// doFinal explicitly and wipe its output buffer when authentication fails.
Uint8List _nameAead(ChaCha20Poly1305 cipher, Uint8List input) {
  final output = Uint8List(cipher.getOutputSize(input.length));
  try {
    var written = cipher.processBytes(input, 0, input.length, output, 0);
    written += cipher.doFinal(output, written);
    if (written != output.length) {
      throw StateError('Invalid name cipher output.');
    }
    return output;
  } catch (_) {
    ageWipe(output);
    rethrow;
  }
}

bool _valid(String name, bool random) =>
    !name.contains('\u0000') &&
    (random || !name.contains('/')) &&
    name.split('/').every((s) => s.isNotEmpty && s != '.' && s != '..');
String _encode(List<int> bytes) => base64Url.encode(bytes).replaceAll('=', '');
String sealVaultName(String name, VaultNameKeys keys,
    {Uint8List? salt, bool random = false}) {
  keys._check();
  if (!_valid(name, random)) throw const FormatException('Invalid vault name.');
  final clear = Uint8List.fromList(utf8.encode(name));
  try {
    if (!random) {
      return _encode([1, ...vaultSivSeal(keys.deterministic, clear)]);
    }
    final nameSalt = salt ?? ageRandomBytes(24);
    if (nameSalt.length != 24) throw ArgumentError('Invalid name salt length.');
    final key = _hkdf(keys.random, nameSalt, 'name', 32);
    final padded = Uint8List(((clear.length + 1 + 15) ~/ 16) * 16)
      ..setAll(0, clear);
    padded[clear.length] = 0x80;
    try {
      final cipher = ChaCha20Poly1305(ChaCha7539Engine(), Poly1305())
        ..init(
            true,
            AEADParameters(
                KeyParameter(key), 128, Uint8List(12), Uint8List(0)));
      return _encode([2, ...nameSalt, ..._nameAead(cipher, padded)]);
    } finally {
      ageWipe(key);
      ageWipe(padded);
    }
  } finally {
    ageWipe(clear);
  }
}

/// Untrusted tokens never throw or yield unauthenticated/partially decoded names.
String? openVaultName(String token, VaultNameKeys keys) {
  Uint8List? clear;
  try {
    keys._check();
    if (!RegExp(r'^[A-Za-z0-9_-]+$').hasMatch(token)) return null;
    final raw = base64Url.decode(base64Url.normalize(token));
    if (_encode(raw) != token || raw.isEmpty) return null;
    final random = raw[0] == 2;
    if (raw[0] == 1) {
      if (raw.length <= 17) return null;
      clear = vaultSivOpen(keys.deterministic, Uint8List.sublistView(raw, 1));
    } else if (random) {
      if (raw.length < 57 || (raw.length - 41) % 16 != 0) return null;
      final key = _hkdf(keys.random, raw.sublist(1, 25), 'name', 32);
      try {
        final cipher = ChaCha20Poly1305(ChaCha7539Engine(), Poly1305())
          ..init(
              false,
              AEADParameters(
                  KeyParameter(key), 128, Uint8List(12), Uint8List(0)));
        clear = _nameAead(cipher, Uint8List.sublistView(raw, 25));
      } finally {
        ageWipe(key);
      }
      var end = clear.length;
      while (end > 0 && clear[end - 1] == 0) {
        end--;
      }
      if (end == 0 || clear[end - 1] != 0x80 || clear.length - end > 15) {
        return null;
      }
      final unpadded = Uint8List.fromList(clear.sublist(0, end - 1));
      ageWipe(clear);
      clear = unpadded;
    } else {
      return null;
    }
    if (clear == null) return null;
    final name = utf8.decode(clear, allowMalformed: false);
    return _valid(name, random) ? name : null;
  } catch (_) {
    return null;
  } finally {
    ageWipe(clear);
  }
}
