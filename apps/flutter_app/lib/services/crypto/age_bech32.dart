/// Bech32 (BIP 173) codec without the 90-character length limit, as used by
/// age for identities and recipients.
///
/// This is an encoding, not a cipher. Failures are reported as
/// [FormatException] with messages that never echo the input, because the
/// input may be a secret key.
library;

import 'dart:typed_data';

const String _charset = 'qpzry9x8gf2tvdw0s3jn54khce6mua7l';
const List<int> _generator = <int>[
  0x3b6a57b2,
  0x26508e6d,
  0x1ea119fa,
  0x3d4233dd,
  0x2a1462b3,
];

int _polymod(Iterable<int> values) {
  var chk = 1;
  for (final value in values) {
    final top = chk >> 25;
    chk = ((chk & 0x1ffffff) << 5) ^ value;
    for (var i = 0; i < 5; i++) {
      if ((top >> i) & 1 == 1) chk ^= _generator[i];
    }
  }
  return chk;
}

List<int> _hrpExpand(String lowerHrp) {
  final units = lowerHrp.codeUnits;
  return <int>[
    for (final c in units) c >> 5,
    0,
    for (final c in units) c & 31,
  ];
}

bool _isAllLower(String s) => s.toLowerCase() == s;
bool _isAllUpper(String s) => s.toUpperCase() == s;

void _checkHrp(String hrp) {
  if (hrp.isEmpty) throw const FormatException('Empty Bech32 prefix.');
  for (final c in hrp.codeUnits) {
    if (c < 33 || c > 126) {
      throw const FormatException('Invalid character in Bech32 prefix.');
    }
  }
}

List<int> _convertBits(List<int> data, int from, int to, {required bool pad}) {
  var acc = 0;
  var bits = 0;
  final maxValue = (1 << to) - 1;
  final out = <int>[];
  for (final value in data) {
    acc = (acc << from) | value;
    bits += from;
    while (bits >= to) {
      bits -= to;
      out.add((acc >> bits) & maxValue);
    }
    acc &= (1 << bits) - 1;
  }
  if (pad) {
    if (bits > 0) out.add((acc << (to - bits)) & maxValue);
  } else {
    if (bits >= from) throw const FormatException('Illegal Bech32 padding.');
    if (((acc << (to - bits)) & maxValue) != 0) {
      throw const FormatException('Non-zero Bech32 padding.');
    }
  }
  return out;
}

/// Encodes [data] under the human-readable prefix [hrp].
///
/// The result is entirely upper case when [hrp] is upper case and entirely
/// lower case otherwise. The checksum is always computed over the lower-case
/// form, as BIP 173 requires.
String bech32Encode(String hrp, List<int> data) {
  _checkHrp(hrp);
  final lower = _isAllLower(hrp);
  if (!lower && !_isAllUpper(hrp)) {
    throw const FormatException('Mixed-case Bech32 prefix.');
  }
  final lowerHrp = hrp.toLowerCase();
  final values = _convertBits(data, 8, 5, pad: true);
  final polymod = _polymod(<int>[
        ..._hrpExpand(lowerHrp),
        ...values,
        0,
        0,
        0,
        0,
        0,
        0,
      ]) ^
      1;
  final buffer = StringBuffer(lowerHrp)..write('1');
  for (final value in values) {
    buffer.write(_charset[value]);
  }
  for (var i = 0; i < 6; i++) {
    buffer.write(_charset[(polymod >> (5 * (5 - i))) & 31]);
  }
  final encoded = buffer.toString();
  return lower ? encoded : encoded.toUpperCase();
}

/// Decodes a Bech32 string.
///
/// The returned prefix keeps the case of the input, so callers can enforce
/// age's case rules (identities upper case, recipients lower case). Mixed
/// case, a bad checksum, characters outside the Bech32 alphabet and
/// non-canonical padding bits are rejected.
({String hrp, Uint8List data}) bech32Decode(String input) {
  final lower = _isAllLower(input);
  if (!lower && !_isAllUpper(input)) {
    throw const FormatException('Mixed-case Bech32 string.');
  }
  final separator = input.lastIndexOf('1');
  if (separator < 1 || separator + 7 > input.length) {
    throw const FormatException('Invalid Bech32 separator position.');
  }
  final hrp = input.substring(0, separator);
  _checkHrp(hrp);
  final body = input.substring(separator + 1).toLowerCase();
  final values = <int>[];
  for (final unit in body.codeUnits) {
    final value = unit < 128 ? _charset.indexOf(String.fromCharCode(unit)) : -1;
    if (value < 0) {
      throw const FormatException('Invalid character in Bech32 data.');
    }
    values.add(value);
  }
  if (_polymod(<int>[..._hrpExpand(hrp.toLowerCase()), ...values]) != 1) {
    throw const FormatException('Invalid Bech32 checksum.');
  }
  final data = _convertBits(
    values.sublist(0, values.length - 6),
    5,
    8,
    pad: false,
  );
  return (hrp: hrp, data: Uint8List.fromList(data));
}
