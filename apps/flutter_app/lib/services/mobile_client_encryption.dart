import 'dart:async';
import 'dart:convert';
import 'dart:isolate';
import 'dart:math';
import 'dart:typed_data';

import '../models/domain_models.dart';
import 'crypto/age.dart';
import 'crypto/age_primitives.dart' show ageWipe;

/// Request-local secrets. Never put this object in transfer snapshots or retries.
class MobileClientEncryption {
  MobileClientEncryption._(
      this.key, this.header, this.nonce, this.headerLength);
  final Uint8List key, header, nonce;
  final int headerLength;

  static MobileClientEncryption? parse(Object? value, {required bool upload}) {
    if (value == null) return null;
    try {
      if (value is! Map || value['format'] != 'age-v1') {
        throw const FormatException();
      }
      final key = base64Decode(value['fileKey'] as String);
      try {
        if (key.length != 16) throw const FormatException();
        final header =
            upload ? base64Decode(value['header'] as String) : Uint8List(0);
        final nonce = upload
            ? base64Decode(value['payloadNonce'] as String)
            : Uint8List(0);
        final length = upload ? header.length : value['headerLength'];
        if (length is! int ||
            length < 1 ||
            length > 65536 ||
            (upload && nonce.length != 16)) {
          throw const FormatException();
        }
        return MobileClientEncryption._(key, header, nonce, length);
      } catch (_) {
        ageWipe(key);
        rethrow;
      }
    } catch (_) {
      throw const EngineException(
          code: ErrorCode.invalidConfig,
          message: 'Invalid age-v1 client encryption parameters.');
    }
  }

  void dispose() => ageWipe(key);
  @override
  String toString() => 'MobileClientEncryption(age-v1)';
}

Never mobileDecryptionFailed(int chunk) => throw EngineException(
    code: ErrorCode.decryptionFailed,
    message:
        'Object integrity check failed at chunk $chunk. The encrypted data is corrupt, truncated or was modified.',
    details: {'chunk': chunk});

/// One cipher isolate per transfer. Callers await each bounded chunk, so at most
/// one input/output pair per active part can be queued, never an entire part.
class MobileAgeWorker {
  MobileAgeWorker(Uint8List key, Uint8List nonce) {
    _incoming.listen((message) {
      if (message is SendPort) {
        if (!_ready.isCompleted) _ready.complete(message);
      } else if (message is List && message.length == 3) {
        final pending = _pending.remove(message[0]);
        if (message[1] == true) {
          pending?.complete((message[2] as TransferableTypedData)
              .materialize()
              .asUint8List());
        } else {
          pending?.completeError(const AgeAuthenticationException(
              'Age payload authentication failed.'));
        }
      } else {
        close();
      }
    });
    // A source/open error may close the worker before its first chunk call.
    _ready.future.then((_) {}, onError: (Object _) {});
    _spawn(key, nonce);
  }
  final _incoming = ReceivePort();
  final _ready = Completer<SendPort>();
  final _pending = <int, Completer<Uint8List>>{};
  Isolate? _isolate;
  bool _closed = false;
  int _ticket = 0;

  Future<void> _spawn(Uint8List key, Uint8List nonce) async {
    final workerKey = Uint8List.fromList(key);
    try {
      _isolate = await Isolate.spawn(
          _ageMain, [_incoming.sendPort, workerKey, Uint8List.fromList(nonce)],
          onError: _incoming.sendPort, onExit: _incoming.sendPort);
      if (_closed) _isolate?.kill(priority: Isolate.immediate);
    } catch (_) {
      close();
    } finally {
      ageWipe(workerKey);
    }
  }

  Future<Uint8List> chunk(int index, Uint8List bytes,
      {required bool last, required bool seal}) async {
    if (_closed) throw StateError('Age worker is closed.');
    final port = await _ready.future;
    if (_closed) throw StateError('Age worker is closed.');
    final ticket = ++_ticket;
    final result = Completer<Uint8List>();
    _pending[ticket] = result;
    port.send([
      ticket,
      index,
      last,
      seal,
      TransferableTypedData.fromList([bytes])
    ]);
    return result.future;
  }

  void close() {
    if (_closed) return;
    _closed = true;
    _isolate?.kill(priority: Isolate.immediate);
    _incoming.close();
    if (!_ready.isCompleted) {
      _ready.completeError(StateError('Age worker stopped.'));
    }
    for (final result in _pending.values) {
      result.completeError(StateError('Age worker stopped.'));
    }
    _pending.clear();
  }

  /// A bounded ciphertext slice, including any overlapping header/nonce bytes.
  /// Boundary chunks are re-sealed deterministically for adjacent parts/passes.
  Future<Uint8List> readCiphertext(
      MobileClientEncryption config,
      int plaintextLength,
      int start,
      int count,
      Future<List<int>> Function(int, int) read) async {
    final output = Uint8List(count);
    final end = start + count;
    void copy(int offset, Uint8List bytes) {
      final first = max(start, offset), last = min(end, offset + bytes.length);
      if (last > first) {
        output.setRange(first - start, last - start, bytes, first - offset);
      }
    }

    copy(0, config.header);
    copy(config.headerLength, config.nonce);
    final chunks = ageChunksForCiphertextRange(
        headerLength: config.headerLength,
        plaintextLength: plaintextLength,
        start: start,
        endExclusive: end);
    if (chunks != null) {
      for (var index = chunks.firstChunk; index <= chunks.lastChunk; index++) {
        final offset = index * ageChunkSize;
        final bytes =
            await read(offset, min(ageChunkSize, plaintextLength - offset));
        final plain = bytes is Uint8List ? bytes : Uint8List.fromList(bytes);
        try {
          final sealed = await chunk(index, plain,
              last: index == ageChunkCount(plaintextLength) - 1, seal: true);
          copy(ageChunkOffset(headerLength: config.headerLength, index: index),
              sealed);
        } finally {
          ageWipe(plain);
        }
      }
    }
    return output;
  }
}

Future<void> _ageMain(List<dynamic> input) async {
  final reply = input[0] as SendPort;
  final key = input[1] as Uint8List;
  final cipher = await AgePayloadCipher.create(key, input[2] as Uint8List);
  ageWipe(key);
  final commands = ReceivePort();
  reply.send(commands.sendPort);
  await for (final dynamic value in commands) {
    final message = value as List;
    final bytes =
        (message[4] as TransferableTypedData).materialize().asUint8List();
    try {
      final result = message[3] == true
          ? await cipher.sealChunk(message[1] as int, bytes,
              last: message[2] as bool)
          : await cipher.openChunk(message[1] as int, bytes,
              last: message[2] as bool);
      reply.send([
        message[0],
        true,
        TransferableTypedData.fromList([result])
      ]);
      ageWipe(result);
    } catch (_) {
      // Do not transfer primitive errors or request parameters across isolates.
      reply.send([message[0], false, null]);
    } finally {
      ageWipe(bytes);
    }
  }
}
