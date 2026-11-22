import 'dart:async';
import 'dart:convert';
import 'dart:io';

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
    _subscription = _process.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen(_onLine);
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
  late final StreamSubscription<String> _subscription;
  final Map<String, Completer<Map<String, Object?>>> _pending = {};
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

  Future<Map<String, Object?>> _send(String method, Map<String, Object?> params) async {
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
      throw const S3OpRpcException('timeout', 'The engine did not answer in time.');
    });
    if (response['ok'] != true) {
      final error = response['error'];
      final map = error is Map ? error : const {};
      throw S3OpRpcException('${map['code'] ?? 'unknown'}', '${map['message'] ?? 'Engine error.'}');
    }
    final result = response['result'];
    return result is Map ? Map<String, Object?>.from(result) : const {};
  }

  @override
  Future<S3ConformanceCapability?> capability() async {
    final result = await _send('getCapabilities', const {});
    for (final item in (result['items'] as List?) ?? const []) {
      if (item is Map && item['key'] == 'conformance.s3') {
        return S3ConformanceCapability.fromJson(Map<String, Object?>.from(item));
      }
    }
    return null;
  }

  @override
  Future<S3OpObservation> execute(S3OpRequest request) async =>
      S3OpObservation.fromJson(await _send('s3ConformanceOp', request.toParams()));

  Future<void> close() async {
    await _process.stdin.close();
    final code = await _process.exitCode.timeout(const Duration(seconds: 10), onTimeout: () {
      _process.kill();
      return -1;
    });
    await _subscription.cancel();
    if (code != 0 && code != -1) {
      // Exit codes are reported by the caller only when relevant.
    }
  }
}
