// X25519 identities and recipients in age's Bech32 text encoding.
part of 'age.dart';

const String _identityHrp = 'AGE-SECRET-KEY-';
const String _recipientHrp = 'age';
const int _keyLength = 32;

/// An age X25519 identity: the secret half of a key pair.
///
/// The secret is held in memory for the lifetime of the object. [toString]
/// prints only the public recipient, so an identity is safe to log by
/// accident; [secretKey] is the only accessor that returns secret text.
final class AgeIdentity {
  AgeIdentity._(this._secret, this._publicKey)
      : recipient = bech32Encode(_recipientHrp, _publicKey);

  final Uint8List _secret;
  final Uint8List _publicKey;

  /// The public recipient, `age1…`. Safe to store and display.
  final String recipient;

  /// The secret key, `AGE-SECRET-KEY-1…`. Never log or persist in plaintext.
  String get secretKey => bech32Encode(_identityHrp, _secret);

  /// Derived host-only name keys; the caller wipes them when the key file locks.
  VaultNameKeys deriveNameKeys() => VaultNameKeys.fromIdentitySecret(_secret);

  /// Generates a new identity from 32 bytes of operating-system randomness.
  static Future<AgeIdentity> generate() async {
    final secret = ageRandomBytes(_keyLength);
    return AgeIdentity._(secret, await ageX25519PublicKey(secret));
  }

  /// Parses an `AGE-SECRET-KEY-1…` string. Surrounding whitespace is ignored.
  ///
  /// Like the reference implementation, only the upper-case form is accepted.
  /// Throws [AgeInvalidKeyException] (without echoing the input) when the
  /// text is not a valid X25519 identity, and [AgeUnsupportedException] for a
  /// post-quantum (`AGE-SECRET-KEY-PQ-1…`) or plugin identity.
  static Future<AgeIdentity> parse(String secretKey) async {
    final text = secretKey.trim();
    final ({String hrp, Uint8List data}) decoded;
    try {
      decoded = bech32Decode(text);
    } on FormatException {
      throw const AgeInvalidKeyException(
          'The text is not a valid age secret key.');
    }
    if (decoded.hrp != _identityHrp) {
      if (decoded.hrp.toUpperCase().startsWith('AGE-SECRET-KEY-PQ-') ||
          decoded.hrp.toUpperCase().startsWith('AGE-PLUGIN-')) {
        ageWipe(decoded.data);
        throw const AgeUnsupportedException(
            'Only X25519 age identities (AGE-SECRET-KEY-1…) are supported.');
      }
      ageWipe(decoded.data);
      throw const AgeInvalidKeyException(
          'The text is not an age secret key (expected AGE-SECRET-KEY-1…).');
    }
    if (decoded.data.length != _keyLength) {
      ageWipe(decoded.data);
      throw const AgeInvalidKeyException(
          'The age secret key has the wrong length.');
    }
    return AgeIdentity._(decoded.data, await ageX25519PublicKey(decoded.data));
  }

  @override
  String toString() => 'AgeIdentity($recipient)';
}

/// Decodes an X25519 recipient (`age1…`) to its 32 public key bytes.
///
/// Throws [AgeUnsupportedException] for recipient kinds this implementation
/// does not write (post-quantum, tagged, plugin, ssh) and
/// [AgeInvalidKeyException] for anything else that is not a valid recipient.
Uint8List _parseRecipient(String recipient) {
  final text = recipient.trim();
  if (text.startsWith('ssh-')) {
    throw const AgeUnsupportedException(
        'ssh recipients are not supported; use an age1… recipient.');
  }
  final ({String hrp, Uint8List data}) decoded;
  try {
    decoded = bech32Decode(text);
  } on FormatException {
    throw const AgeInvalidKeyException(
        'The text is not a valid age recipient.');
  }
  if (decoded.hrp != _recipientHrp) {
    if (decoded.hrp.toLowerCase().startsWith('age1')) {
      throw const AgeUnsupportedException(
          'Only X25519 age recipients (age1…) are supported; post-quantum, '
          'tagged and plugin recipients are not.');
    }
    throw const AgeInvalidKeyException(
        'The text is not an age recipient (expected lower-case age1…).');
  }
  if (decoded.data.length != _keyLength) {
    throw const AgeInvalidKeyException(
        'The age recipient has the wrong length.');
  }
  return decoded.data;
}

/// Whether [value] is a valid X25519 age recipient (`age1…`, lower case,
/// correct checksum, 32-byte key). Surrounding whitespace is ignored.
bool isAgeRecipient(String value) {
  try {
    _parseRecipient(value);
    return true;
  } on AgeException {
    return false;
  }
}
