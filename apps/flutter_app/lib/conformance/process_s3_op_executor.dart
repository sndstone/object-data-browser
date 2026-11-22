import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 's3_op_executor.dart';

/// Speaks the desktop transport (line-delimited JSON over stdin/stdout) to an
/// engine process the caller started. Used by the headless conformance tool;
/// the app uses its sidecar service instead.
///
/// The profile carries credentials. It is sent to the engine only and never
/// logged; stderr from the engine is discarded.
class ProcessS3OpExecutor implements S3OpExecutor {
  ProcessS3OpExecutor._(this.engineId, this._process, this._profile,
      {required Duration timeout})
      : _timeout = timeout {
    _subscription = _process.stdout.listen(_onBytes, onDone: _failPending, onError: (_) => _failPending());
    _process.stderr.drain<void>();
  }

  static Future<ProcessS3OpExecutor> start({
    required String engineId,
    required String executable,
    List<String> arguments = const [],
    String? workingDirectory,
    Map<String, String>? environment,
    required Map<String, Object?> profile,
    Duration timeout = const Duration(minutes: 2),
  }) async {
    final process = await Process.start(executable, arguments,
        workingDirectory: workingDirectory, environment: environment);
    return ProcessS3OpExecutor._(engineId, process, profile, timeout: timeout);
  }

  @override
  final String engineId;
  final Process _process;
  final Map<String, Object?> _profile;
  final Duration _timeout;
  late final StreamSubscription<List<int>> _subscription;
  final BytesBuilder _line = BytesBuilder(copy: false);
  bool _discarding = false;

  /// One response frame is at most 64 MiB, matching the transport contract;
  /// a longer line is discarded instead of buffered.
  static const int maxFrameBytes = 64 * 1024 * 1024;

  void _onBytes(List<int> chunk) {
    var start = 0;
    for (var i = 0; i < chunk.length; i++) {
      if (chunk[i] != 10) continue;
      _append(chunk, start, i);
      if (!_discarding) {
        _onLine(utf8.decode(_line.takeBytes(), allowMalformed: true));
      }
      _line.clear();
      _discarding = false;
      start = i + 1;
    }
    _append(chunk, start, chunk.length);
  }

  void _append(List<int> chunk, int start, int end) {
    if (_discarding || end <= start) return;
    if (_line.length + (end - start) > maxFrameBytes) {
      _line.clear();
      _discarding = true;
      return;
    }
    _line.add(chunk.sublist(start, end));
  }

  final Map<String, Completer<Map<String, Object?>>> _pending = {};
  bool _closed = false;

  /// The engine exited: every outstanding request fails now, not at timeout.
  void _failPending() {
    _closed = true;
    for (final completer in _pending.values) {
      if (!completer.isCompleted) {
        completer.completeError(const S3OpRpcException('engine_unavailable', 'The engine process exited.'));
      }
    }
    _pending.clear();
  }
  int _sequence = 0;

  void _onLine(String line) {
    Map<String, Object?> json;
    try {
      json = Map<String, Object?>.from(jsonDecode(line) as Map);
    } catch (_) {
      return;
    }
    if (json.containsKey('event')) return;
    final completer = _pending.remove('${json['requestId']}');
    completer?.complete(json);
  }

  Future<Map<String, Object?>> _send(
      String method, Map<String, Object?> params) async {
    if (_closed) {
      throw const S3OpRpcException('engine_unavailable', 'The engine process exited.');
    }
    final id = 'conf-${++_sequence}';
    final completer = Completer<Map<String, Object?>>();
    _pending[id] = completer;
    _process.stdin.writeln(jsonEncode({
      'requestId': id,
      'method': method,
      'engineVersion': '1.0',
      'params': {...params, 'profile': _profile},
    }));
    await _process.stdin.flush();
    final response = await completer.future.timeout(_timeout, onTimeout: () {
      _pending.remove(id);
      throw const S3OpRpcException(
          'timeout', 'The engine did not answer in time.');
    });
    if (response['ok'] != true) {
      final error = response['error'];
      final map = error is Map ? error : const {};
      throw S3OpRpcException('${map['code'] ?? 'unknown'}',
          '${map['message'] ?? 'Engine error.'}');
    }
    final result = response['result'];
    return result is Map ? Map<String, Object?>.from(result) : const {};
  }

  @override
  Future<S3ConformanceCapability?> capability() async {
    final result = await _send('getCapabilities', const {});
    for (final item in (result['items'] as List?) ?? const []) {
      if (item is Map && item['key'] == 'conformance.s3') {
        return S3ConformanceCapability.fromJson(
            Map<String, Object?>.from(item));
      }
    }
    return null;
  }

  @override
  Future<S3OpObservation> execute(S3OpRequest request) async =>
      S3OpObservation.fromJson(scrubConformanceResult(
          await _send('s3ConformanceOp', request.toParams()), [
        '${_profile['secretKey'] ?? ''}',
        '${_profile['sessionToken'] ?? ''}',
        '${_profile['accessKey'] ?? ''}'
      ]));

  Future<void> close() async {
    await _process.stdin.close();
    final code = await _process.exitCode.timeout(const Duration(seconds: 10),
        onTimeout: () {
      _process.kill();
      return -1;
    });
    await _subscription.cancel();
    if (code != 0 && code != -1) {
      // Exit codes are reported by the caller only when relevant.
    }
  }
}
