import 'dart:math' as math;
import 'dart:typed_data';
import 'package:s3_browser_crossplat/services/crypto/age.dart';

Future<({Uint8List bytes, Uint8List fileKey, int headerLength})> clientFixture(
    Uint8List plaintext, AgeIdentity identity,
    {int recipients = 1}) async {
  final header = await ageNewHeader(
      recipients: List.filled(recipients, identity.recipient));
  final nonce = Uint8List.fromList(List.generate(16, (i) => i));
  final cipher = await AgePayloadCipher.create(header.fileKey, nonce);
  final output = BytesBuilder()
    ..add(header.header.bytes)
    ..add(nonce);
  for (var i = 0; i < ageChunkCount(plaintext.length); i++) {
    output.add(await cipher.sealChunk(
        i,
        Uint8List.sublistView(plaintext, i * ageChunkSize,
            math.min(plaintext.length, (i + 1) * ageChunkSize)),
        last: i == ageChunkCount(plaintext.length) - 1));
  }
  return (
    bytes: output.takeBytes(),
    fileKey: header.fileKey,
    headerLength: header.header.length
  );
}
