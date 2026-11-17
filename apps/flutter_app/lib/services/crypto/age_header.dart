// The textual age header: version line, recipient stanzas and header MAC.
part of 'age.dart';

/// Largest header this implementation accepts, in bytes. The specification
/// sets no limit; the cap bounds the work done on untrusted input and the
/// size of the first ranged read of an object.
const int ageMaxHeaderLength = 65536;

/// Length of the age file key, in bytes.
const int ageFileKeyLength = 16;

const String _versionLine = 'age-encryption.org/v1';
const String _versionPrefix = 'age-encryption.org/';
const String _armorMarker = '-----BEGIN AGE ENCRYPTED FILE-----';
const int _columns = 64;
const int _headerMacLength = 32;
const int _lf = 0x0a;

bool _isVisibleAscii(int c) => c >= 0x21 && c <= 0x7e;

/// One recipient stanza of an age header.
final class AgeStanza {
  /// Creates a stanza. [type] and every argument must be one or more
  /// printable ASCII characters without spaces.
  AgeStanza(this.type, List<String> arguments, Uint8List body)
      : arguments = List<String>.unmodifiable(arguments),
        _body = Uint8List.fromList(body) {
    for (final value in <String>[type, ...arguments]) {
      if (value.isEmpty || !value.codeUnits.every(_isVisibleAscii)) {
        throw ArgumentError(
            'Stanza arguments must be non-empty printable ASCII.');
      }
    }
  }

  /// The first argument, for example `X25519` or `scrypt`.
  final String type;

  /// The arguments after [type].
  final List<String> arguments;

  final Uint8List _body;

  /// The decoded stanza body (for native recipients, the wrapped file key).
  Uint8List get body => _body.asUnmodifiableView();

  /// The canonical text of the stanza: the argument line followed by the
  /// body as unpadded base64 wrapped at 64 columns.
  ///
  /// The body always ends with a line shorter than 64 characters, so a body
  /// whose length is a multiple of 48 bytes (including an empty body) ends
  /// with an empty line.
  String encode() {
    final buffer = StringBuffer('-> $type');
    for (final argument in arguments) {
      buffer
        ..write(' ')
        ..write(argument);
    }
    buffer.write('\n');
    final encoded = ageBase64Encode(_body);
    var offset = 0;
    for (; offset + _columns <= encoded.length; offset += _columns) {
      buffer
        ..write(encoded.substring(offset, offset + _columns))
        ..write('\n');
    }
    buffer
      ..write(encoded.substring(offset))
      ..write('\n');
    return buffer.toString();
  }

  @override
  String toString() => 'AgeStanza($type)';
}

/// A parsed (or newly written) age v1 header.
///
/// [bytes] is the exact header text, from `age-encryption.org/v1` up to and
/// including the line feed that ends the `---` MAC line. The 16-byte payload
/// nonce follows immediately at offset [length] of the object.
///
/// A header is ciphertext: it carries the file key wrapped for each
/// recipient and is safe to store (for example in a resumable-upload
/// manifest). The file key itself is never part of this object.
final class AgeHeader {
  AgeHeader._(this._bytes, this.stanzas, this._mac, this._macInputLength);

  final Uint8List _bytes;
  final Uint8List _mac;
  final int _macInputLength;

  /// The recipient stanzas, in file order.
  final List<AgeStanza> stanzas;

  /// The exact header bytes (read-only view).
  Uint8List get bytes => _bytes.asUnmodifiableView();

  /// Header length in bytes; the payload nonce starts at this offset.
  int get length => _bytes.length;

  /// True when the file key is wrapped with a passphrase (a single scrypt
  /// stanza) rather than for public-key recipients.
  bool get isPassphraseProtected =>
      stanzas.length == 1 && stanzas.single.type == _scryptType;

  /// The scrypt work factor (base-two logarithm of N) of a
  /// passphrase-protected header, or null when it is absent or not a
  /// canonical decimal number.
  int? get scryptWorkFactor {
    if (!isPassphraseProtected) return null;
    final arguments = stanzas.single.arguments;
    if (arguments.length != 2) return null;
    return _parseWorkFactor(arguments[1]);
  }

  /// Strictly parses the header at the start of [prefix].
  ///
  /// [prefix] is the first bytes of an age file; anything after the header
  /// is ignored. Throws [AgeIncompleteHeaderException] when [prefix] ends
  /// before the header does, [AgeMalformedException] for anything the
  /// specification forbids (including a header longer than
  /// [ageMaxHeaderLength]) and [AgeUnsupportedException] for another format
  /// version or an ASCII-armored file.
  ///
  /// Parsing does not authenticate the header; the MAC is checked when the
  /// file key is unwrapped by [ageReadHeader] or [ageDecrypt].
  static AgeHeader parse(Uint8List prefix) {
    _checkMagic(prefix);
    final reader = _LineReader(prefix);

    final version = reader.next();
    if (version != _versionLine) {
      final suffix = version.startsWith(_versionPrefix)
          ? version.substring(_versionPrefix.length)
          : '';
      if (suffix.isNotEmpty && suffix.codeUnits.every(_isVisibleAscii)) {
        throw const AgeUnsupportedException(
            'Unsupported age format version; only age-encryption.org/v1 '
            'files can be read.');
      }
      throw const AgeMalformedException(
          'Not an age file: the version line is malformed.');
    }

    final stanzas = <AgeStanza>[];
    while (true) {
      final lineStart = reader.position;
      final line = reader.next();
      if (line.startsWith('-> ')) {
        stanzas.add(_parseStanza(line, reader));
        continue;
      }
      if (line.startsWith('---')) {
        if (line.length != 4 + 43 || line[3] != ' ') {
          throw const AgeMalformedException(
              'Malformed age header: invalid MAC line.');
        }
        final mac = ageBase64DecodeStrict(line.substring(4));
        if (mac == null || mac.length != _headerMacLength) {
          throw const AgeMalformedException(
              'Malformed age header: the MAC is not canonical base64.');
        }
        if (stanzas.isEmpty) {
          throw const AgeMalformedException(
              'Malformed age header: no recipient stanza.');
        }
        final hasScrypt = stanzas.any((s) => s.type == _scryptType);
        if (hasScrypt && stanzas.length != 1) {
          throw const AgeMalformedException(
              'Malformed age header: an scrypt stanza must be the only '
              'stanza.');
        }
        return AgeHeader._(
          Uint8List.fromList(Uint8List.sublistView(prefix, 0, reader.position)),
          List<AgeStanza>.unmodifiable(stanzas),
          mac,
          lineStart + 3,
        );
      }
      throw const AgeMalformedException(
          'Malformed age header: unexpected line.');
    }
  }

  static void _checkMagic(Uint8List prefix) {
    final expected = _versionPrefix.codeUnits;
    final count = min(prefix.length, expected.length);
    for (var i = 0; i < count; i++) {
      if (prefix[i] == expected[i]) continue;
      final armor = _armorMarker.codeUnits;
      var isArmor = prefix.length >= armor.length;
      for (var j = 0; isArmor && j < armor.length; j++) {
        isArmor = prefix[j] == armor[j];
      }
      if (isArmor) {
        throw const AgeUnsupportedException(
            'ASCII-armored age files are not supported; use the binary '
            'format.');
      }
      throw const AgeMalformedException(
          'Not an age file: missing the age-encryption.org/v1 header.');
    }
  }

  static AgeStanza _parseStanza(String argumentLine, _LineReader reader) {
    final arguments = argumentLine.substring(3).split(' ');
    for (final argument in arguments) {
      if (argument.isEmpty || !argument.codeUnits.every(_isVisibleAscii)) {
        throw const AgeMalformedException(
            'Malformed age header: invalid stanza argument.');
      }
    }
    final body = BytesBuilder(copy: false);
    while (true) {
      final line = reader.next();
      if (line.length > _columns) {
        throw const AgeMalformedException(
            'Malformed age header: stanza body line longer than 64 columns.');
      }
      final decoded = ageBase64DecodeStrict(line);
      if (decoded == null) {
        throw const AgeMalformedException(
            'Malformed age header: stanza body is not canonical unpadded '
            'base64 ending in a short line.');
      }
      body.add(decoded);
      if (line.length < _columns) break;
    }
    return AgeStanza(arguments.first, arguments.sublist(1), body.takeBytes());
  }

  /// Builds a header from already wrapped stanzas and MACs it with [fileKey].
  static Future<AgeHeader> _seal(
    List<AgeStanza> stanzas,
    Uint8List fileKey,
  ) async {
    final text = StringBuffer('$_versionLine\n');
    for (final stanza in stanzas) {
      text.write(stanza.encode());
    }
    text.write('---');
    final unsigned = ascii.encode(text.toString());
    final mac = await _headerMac(fileKey, unsigned);
    final bytes = BytesBuilder(copy: false)
      ..add(unsigned)
      ..add(ascii.encode(' ${ageBase64Encode(mac)}\n'));
    if (bytes.length > ageMaxHeaderLength) {
      throw ArgumentError('Too many recipients: the header exceeds 64 KiB.');
    }
    // Re-parsing guarantees that what is written is what a reader accepts.
    return AgeHeader.parse(bytes.takeBytes());
  }

  @override
  String toString() =>
      'AgeHeader($length bytes, ${stanzas.map((s) => s.type).join(', ')})';
}

/// Reads LF-terminated lines from the first [ageMaxHeaderLength] bytes.
final class _LineReader {
  _LineReader(this._data) : _limit = min(_data.length, ageMaxHeaderLength);

  final Uint8List _data;
  final int _limit;
  int position = 0;

  /// Returns the next line without its line feed.
  String next() {
    for (var i = position; i < _limit; i++) {
      if (_data[i] != _lf) continue;
      // Bytes above 0x7f become characters that every later check rejects.
      final line = String.fromCharCodes(_data, position, i);
      position = i + 1;
      return line;
    }
    if (_data.length >= ageMaxHeaderLength) {
      throw const AgeMalformedException(
          'Malformed age file: the header is larger than 64 KiB.');
    }
    throw AgeIncompleteHeaderException(
      availableLength: _data.length,
      maxHeaderLength: ageMaxHeaderLength,
    );
  }
}

Future<Uint8List> _headerMac(Uint8List fileKey, List<int> macInput) async {
  final key = await ageHkdfSha256(
    ikm: fileKey,
    salt: const <int>[],
    info: 'header',
  );
  try {
    return await ageHmacSha256(key, macInput);
  } finally {
    ageWipe(key);
  }
}

// ---------------------------------------------------------------------------
// Native recipient stanzas
// ---------------------------------------------------------------------------

const String _x25519Type = 'X25519';
const String _x25519Info = 'age-encryption.org/v1/X25519';
const String _scryptType = 'scrypt';
const int _scryptSaltLength = 16;
const int _wrappedFileKeyLength = ageFileKeyLength + ageAeadTagLength;
final Uint8List _zeroNonce = Uint8List(12);
final RegExp _workFactorPattern = RegExp(r'^[1-9][0-9]*$');

bool _isAllZero(Uint8List bytes) {
  var acc = 0;
  for (final b in bytes) {
    acc |= b;
  }
  return acc == 0;
}

/// Parses a canonical decimal work factor; null when it is not one. Values
/// too large to matter are reported as a large number, never parsed blindly.
int? _parseWorkFactor(String text) {
  if (!_workFactorPattern.hasMatch(text)) return null;
  if (text.length > 4) return 1 << 30;
  return int.parse(text);
}

Future<AgeStanza> _wrapForX25519(
  Uint8List fileKey,
  Uint8List recipient,
) async {
  final ephemeral = ageRandomBytes(_keyLength);
  Uint8List? shared;
  Uint8List? wrapKey;
  try {
    final share = await ageX25519PublicKey(ephemeral);
    shared = await ageX25519SharedSecret(ephemeral, recipient);
    if (_isAllZero(shared)) {
      throw const AgeInvalidKeyException(
          'The age recipient is not a usable X25519 public key.');
    }
    wrapKey = await ageHkdfSha256(
      ikm: shared,
      salt: <int>[...share, ...recipient],
      info: _x25519Info,
    );
    final body = await ageAeadSeal(SecretKey(wrapKey), _zeroNonce, fileKey);
    return AgeStanza(_x25519Type, <String>[ageBase64Encode(share)], body);
  } finally {
    ageWipe(ephemeral);
    ageWipe(shared);
    ageWipe(wrapKey);
  }
}

Future<AgeStanza> _wrapForPassphrase(
  Uint8List fileKey,
  String passphrase,
  int workFactor,
) async {
  final salt = ageRandomBytes(_scryptSaltLength);
  final passphraseBytes = Uint8List.fromList(utf8.encode(passphrase));
  Uint8List? wrapKey;
  try {
    wrapKey = await ageScryptWrapKey(passphraseBytes, salt, workFactor);
    final body = await ageAeadSeal(SecretKey(wrapKey), _zeroNonce, fileKey);
    return AgeStanza(
      _scryptType,
      <String>[ageBase64Encode(salt), '$workFactor'],
      body,
    );
  } finally {
    ageWipe(passphraseBytes);
    ageWipe(wrapKey);
  }
}

({Uint8List share, Uint8List body}) _checkX25519Stanza(AgeStanza stanza) {
  if (stanza.arguments.length != 1) {
    throw const AgeMalformedException(
        'Malformed age header: an X25519 stanza must have two arguments.');
  }
  final share = ageBase64DecodeStrict(stanza.arguments.single);
  if (share == null || share.length != _keyLength) {
    throw const AgeMalformedException(
        'Malformed age header: invalid X25519 ephemeral share.');
  }
  if (stanza._body.length != _wrappedFileKeyLength) {
    throw const AgeMalformedException(
        'Malformed age header: an X25519 stanza body must be 32 bytes.');
  }
  return (share: share, body: stanza._body);
}

({Uint8List salt, int workFactor, Uint8List body}) _checkScryptStanza(
  AgeStanza stanza,
  int maxWorkFactor,
) {
  if (stanza.arguments.length != 2) {
    throw const AgeMalformedException(
        'Malformed age header: an scrypt stanza must have three arguments.');
  }
  final salt = ageBase64DecodeStrict(stanza.arguments[0]);
  if (salt == null || salt.length != _scryptSaltLength) {
    throw const AgeMalformedException(
        'Malformed age header: invalid scrypt salt.');
  }
  final workFactor = _parseWorkFactor(stanza.arguments[1]);
  if (workFactor == null) {
    throw const AgeMalformedException(
        'Malformed age header: invalid scrypt work factor.');
  }
  if (workFactor > maxWorkFactor) {
    throw AgeUnsupportedException(
        'The scrypt work factor of this age file exceeds the supported '
        'maximum of $maxWorkFactor.');
  }
  if (stanza._body.length != _wrappedFileKeyLength) {
    throw const AgeMalformedException(
        'Malformed age header: an scrypt stanza body must be 32 bytes.');
  }
  return (salt: salt, workFactor: workFactor, body: stanza._body);
}

/// Unwraps the file key from [header] and verifies the header MAC.
Future<Uint8List> _unwrapFileKey(
  AgeHeader header, {
  required List<AgeIdentity> identities,
  required String? passphrase,
  required int maxScryptWorkFactor,
}) async {
  Uint8List? fileKey;
  if (header.isPassphraseProtected) {
    // Validate, including the work-factor bound, before any expensive work.
    final stanza = _checkScryptStanza(
      header.stanzas.single,
      maxScryptWorkFactor,
    );
    if (passphrase == null) {
      throw const AgeNoMatchingIdentityException(
        'This age file is passphrase-protected; a passphrase is required.',
        passphraseRequired: true,
      );
    }
    final passphraseBytes = Uint8List.fromList(utf8.encode(passphrase));
    Uint8List? wrapKey;
    try {
      wrapKey = await ageScryptWrapKey(
        passphraseBytes,
        stanza.salt,
        stanza.workFactor,
      );
      fileKey = await ageAeadOpen(SecretKey(wrapKey), _zeroNonce, stanza.body);
    } finally {
      ageWipe(passphraseBytes);
      ageWipe(wrapKey);
    }
    if (fileKey == null) throw const AgeWrongPassphraseException();
  } else {
    // Every X25519 stanza must be well formed, whether or not it is ours.
    final candidates = <({Uint8List share, Uint8List body})>[
      for (final stanza in header.stanzas)
        if (stanza.type == _x25519Type) _checkX25519Stanza(stanza),
    ];
    search:
    for (final identity in identities) {
      for (final candidate in candidates) {
        final shared = await ageX25519SharedSecret(
          identity._secret,
          candidate.share,
        );
        if (_isAllZero(shared)) {
          throw const AgeMalformedException(
              'Malformed age header: low-order X25519 ephemeral share.');
        }
        final wrapKey = await ageHkdfSha256(
          ikm: shared,
          salt: <int>[...candidate.share, ...identity._publicKey],
          info: _x25519Info,
        );
        final opened = await ageAeadOpen(
          SecretKey(wrapKey),
          _zeroNonce,
          candidate.body,
        );
        ageWipe(shared);
        ageWipe(wrapKey);
        if (opened != null) {
          fileKey = opened;
          break search;
        }
      }
    }
    if (fileKey == null) {
      if (candidates.isEmpty) {
        final types = header.stanzas.map((s) => s.type).toSet().toList();
        throw AgeUnsupportedRecipientException(
          'This age file is encrypted only to recipient types that are not '
          'supported here; an X25519 (age1…) recipient is required.',
          List<String>.unmodifiable(types),
        );
      }
      throw AgeNoMatchingIdentityException(identities.isEmpty
          ? 'This age file is encrypted to a public key; an identity is '
              'required to decrypt it.'
          : 'None of the supplied identities can decrypt this age file.');
    }
  }

  final expected = await _headerMac(
    fileKey,
    Uint8List.sublistView(header._bytes, 0, header._macInputLength),
  );
  if (!ageConstantTimeEquals(expected, header._mac)) {
    ageWipe(fileKey);
    throw const AgeAuthenticationException(
        'The age header failed authentication (header MAC mismatch).');
  }
  return fileKey;
}
