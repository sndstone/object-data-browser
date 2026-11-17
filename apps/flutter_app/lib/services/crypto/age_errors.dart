/// Typed failures raised by the age v1 implementation.
///
/// Messages are written for logs and UI. They never contain key material,
/// passphrases, file keys or the raw text of a rejected key string.
library;

/// Base class of every failure raised by the age library.
sealed class AgeException implements Exception {
  const AgeException(this.message);

  /// Human-readable description. Never contains key material.
  final String message;

  @override
  String toString() => '$runtimeType: $message';
}

/// The bytes are not a well-formed age v1 file.
///
/// Covers a bad version line, malformed stanzas, non-canonical base64,
/// padding, a header larger than 64 KiB, an scrypt stanza
/// mixed with another stanza, and structurally impossible payloads (missing
/// nonce, short non-final chunk, empty trailing chunk).
final class AgeMalformedException extends AgeException {
  const AgeMalformedException(super.message);
}

/// The input is recognisably age-related but uses a feature this
/// implementation deliberately does not support: another format version,
/// ASCII armor, an scrypt work factor above the accepted maximum, or a
/// recipient string of an unsupported kind (ssh, plugin, post-quantum).
final class AgeUnsupportedException extends AgeException {
  const AgeUnsupportedException(super.message);
}

/// The supplied prefix ends before the end of the age header.
///
/// Fetch more bytes from the start of the object and retry. A header never
/// exceeds [maxHeaderLength] bytes, so requesting that many bytes is always
/// enough.
final class AgeIncompleteHeaderException extends AgeException {
  const AgeIncompleteHeaderException({
    required this.availableLength,
    required this.maxHeaderLength,
  }) : super('The age header is incomplete; more bytes are needed.');

  /// Number of bytes that were supplied.
  final int availableLength;

  /// Upper bound for the header size accepted by this implementation.
  final int maxHeaderLength;
}

/// Alias matching the name used in the design brief.
typedef AgeIncompleteHeader = AgeIncompleteHeaderException;

/// None of the supplied identities can unwrap the file key (wrong key), or
/// no usable secret was supplied for this kind of file.
final class AgeNoMatchingIdentityException extends AgeException {
  const AgeNoMatchingIdentityException(
    super.message, {
    this.passphraseRequired = false,
  });

  /// True when the file is passphrase-protected (scrypt) and no passphrase
  /// was supplied.
  final bool passphraseRequired;
}

/// No identity matched and the header contains no X25519 stanza at all: the
/// file is encrypted only to recipient types this implementation does not
/// support (for example ssh, plugin, tagged or post-quantum recipients).
final class AgeUnsupportedRecipientException
    extends AgeNoMatchingIdentityException {
  const AgeUnsupportedRecipientException(super.message, this.stanzaTypes);

  /// The stanza types found in the header.
  final List<String> stanzaTypes;
}

/// The passphrase does not unwrap the scrypt stanza.
final class AgeWrongPassphraseException extends AgeException {
  const AgeWrongPassphraseException()
      : super('The passphrase is incorrect for this age file.');
}

/// Authentication failed: the header MAC or a payload chunk tag does not
/// verify. The data was modified, truncated, reordered or is corrupt.
final class AgeAuthenticationException extends AgeException {
  const AgeAuthenticationException(super.message, {this.chunkIndex});

  /// Zero-based index of the payload chunk that failed, or null when the
  /// header MAC failed.
  final int? chunkIndex;
}

/// An identity (`AGE-SECRET-KEY-1…`) or recipient (`age1…`) string is not
/// valid. The rejected text is never included in [message].
final class AgeInvalidKeyException extends AgeException {
  const AgeInvalidKeyException(super.message);
}
