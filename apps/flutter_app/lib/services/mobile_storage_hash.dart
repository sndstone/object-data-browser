import 'dart:async';
import 'dart:convert';
import 'dart:isolate';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';

/// Reuses one hashing worker and acknowledges bounded blocks before more input
/// is read. Concurrent part digests share the worker without queueing whole files.
class MobilePayloadHasher {
  Isolate? _worker;
  ReceivePort? _incoming;
  Future<SendPort>? _starting;
  Completer<SendPort>? _ready;
  final Map<int, Completer<String?>> _pending = {};
  int _ticket = 0, _job = 0;
  bool _closed = false;

  Future<SendPort> _start() => _starting ??= () async {
        final incoming = _incoming = ReceivePort();
        final ready = _ready = Completer<SendPort>();
        ready.future.then((_) {}, onError: (Object _) {});
        incoming.listen((message) {
          if (message is SendPort) {
            if (!ready.isCompleted) ready.complete(message);
          } else if (message is List &&
              message.length == 3 &&
              message[0] is int) {
            final call = _pending.remove(message[0]);
            if (message[1] == true) {
              call?.complete(message[2] as String?);
            } else {
              call?.completeError(StateError('Payload hashing failed.'));
            }
          } else {
            _closed = true;
            if (!ready.isCompleted) {
              ready.completeError(StateError('Payload hashing worker stopped.'));
            }
            _failPending();
          }
        });
        _worker = await Isolate.spawn(_hashMain, incoming.sendPort,
            onError: incoming.sendPort, onExit: incoming.sendPort);
        if (_closed) {
          _worker?.kill(priority: Isolate.immediate);
        }
        return ready.future;
      }();

  Future<String?> _call(int job, String command,
      [TransferableTypedData? bytes]) async {
    if (_closed) throw StateError('Payload hashing worker is closed.');
    final port = await _start();
    if (_closed) throw StateError('Payload hashing worker is closed.');
    final ticket = ++_ticket;
    final result = Completer<String?>();
    _pending[ticket] = result;
    port.send([ticket, job, command, bytes]);
    return result.future;
  }

  Future<String> hash(Stream<List<int>> input, {void Function()? check}) async {
    final job = ++_job;
    var finished = false;
    await _call(job, 'begin');
    try {
      await for (final block in input) {
        final bytes = block is Uint8List ? block : Uint8List.fromList(block);
        for (var offset = 0; offset < bytes.length; offset += 256 * 1024) {
          check?.call();
          final end = (offset + 256 * 1024).clamp(0, bytes.length);
          await _call(
              job,
              'data',
              TransferableTypedData.fromList(
                  [Uint8List.sublistView(bytes, offset, end)]));
        }
      }
      check?.call();
      final digest = (await _call(job, 'end'))!;
      finished = true;
      return digest;
    } finally {
      if (!finished && !_closed) {
        try {
          await _call(job, 'discard');
        } catch (_) {}
      }
    }
  }

  void _failPending() {
    for (final call in _pending.values) {
      call.completeError(StateError('Payload hashing worker stopped.'));
    }
    _pending.clear();
  }

  void close() {
    if (_closed) return;
    _closed = true;
    _worker?.kill(priority: Isolate.immediate);
    _incoming?.close();
    if (_ready != null && !_ready!.isCompleted) {
      _ready!.completeError(StateError('Payload hashing worker is closed.'));
    }
    _failPending();
  }
}

class _DigestResult implements Sink<Digest> {
  Digest? value;
  @override
  void add(Digest digest) {
    value = digest;
  }

  @override
  void close() {}
}

void _hashMain(SendPort reply) {
  final commands = ReceivePort();
  final jobs = <int, (ByteConversionSink, _DigestResult)>{};
  reply.send(commands.sendPort);
  commands.listen((dynamic value) {
    final message = value as List;
    final ticket = message[0] as int, job = message[1] as int;
    try {
      String? result;
      switch (message[2]) {
        case 'begin':
          final digest = _DigestResult();
          jobs[job] = (sha256.startChunkedConversion(digest), digest);
        case 'data':
          jobs[job]!.$1.add((message[3] as TransferableTypedData)
              .materialize()
              .asUint8List());
        case 'end':
          final state = jobs.remove(job)!;
          state.$1.close();
          result = state.$2.value!.toString();
        case 'discard':
          jobs.remove(job)?.$1.close();
      }
      reply.send([ticket, true, result]);
    } catch (_) {
      reply.send([ticket, false, null]);
    }
  });
}
