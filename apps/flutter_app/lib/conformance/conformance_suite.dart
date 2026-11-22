// S3 API conformance suite: staged catalog, expectations and teardown.
//
// Pure Dart. One instance runs the whole catalog through one engine
// ([S3OpExecutor]); the host runs engines one after another. The catalog and
// its AWS expectations are documented in docs/s3-api-conformance-spec.md.
import 'dart:async';
import 'dart:convert';
import 'dart:io' show gzip;
import 'dart:math';
import 'dart:typed_data';

import 'conformance_bytes.dart';
import 'conformance_models.dart';
import 's3_op_executor.dart';

part 'suite_standard.dart';
part 'suite_standard_objects.dart';
part 'suite_bucket_config.dart';
part 'suite_versioning.dart';
part 'suite_object_lock.dart';
part 'suite_teardown.dart';

/// Endpoint facts the catalog needs. No credentials.
class ConformanceEndpoint {
  const ConformanceEndpoint({
    required this.endpointUrl,
    required this.region,
    required this.pathStyle,
    this.endpointType = 's3Compatible',
  });

  final String endpointUrl;
  final String region;
  final bool pathStyle;
  final String endpointType;

  /// Host and port only, for reports.
  String get displayHost {
    final uri = Uri.tryParse(endpointUrl);
    if (uri == null || uri.host.isEmpty) {
      return endpointType == 'awsS3' ? 'AWS S3 ($region)' : endpointUrl;
    }
    return uri.hasPort ? '${uri.scheme}://${uri.host}:${uri.port}' : '${uri.scheme}://${uri.host}';
  }

  /// SSE-C needs HTTPS, or a loopback endpoint for local fixtures.
  bool get allowsCustomerKeys {
    if (endpointUrl.isEmpty) return endpointType == 'awsS3';
    final uri = Uri.tryParse(endpointUrl);
    if (uri == null) return false;
    if (uri.scheme.toLowerCase() == 'https') return true;
    final host = uri.host.toLowerCase();
    return host == 'localhost' || host == '::1' || host.startsWith('127.');
  }
}

class ConformanceProgress {
  const ConformanceProgress({
    required this.engineId,
    required this.phase,
    required this.completed,
    required this.estimatedTotal,
    this.currentCheck,
    this.lastResult,
  });

  final String engineId;
  final ConformancePhase phase;
  final int completed;
  final int estimatedTotal;
  final String? currentCheck;
  final ConformanceCheckResult? lastResult;
}

/// Cooperative cancellation between S3 calls.
class ConformanceCancellation {
  bool _cancelled = false;
  bool _skipTeardown = false;

  bool get isCancelled => _cancelled;
  bool get skipTeardown => _skipTeardown;

  /// Stops after the in-flight call; teardown still runs unless [skipTeardown].
  void cancel({bool skipTeardown = false}) {
    _cancelled = true;
    _skipTeardown = _skipTeardown || skipTeardown;
  }
}

class _Cancelled implements Exception {
  const _Cancelled();
}

class _CheckSkipped implements Exception {
  const _CheckSkipped(this.reason);
  final String reason;
}

class _CheckUnsupported implements Exception {
  const _CheckUnsupported(this.reason);
  final String reason;
}

class _CheckError implements Exception {
  const _CheckError(this.reason);
  final String reason;
}

/// Stops evaluating a check after a failed fixture step; the mismatch already
/// recorded decides the status.
class _CheckAbort implements Exception {
  const _CheckAbort();
}

/// Approximate number of checks, for progress only.
const int conformanceEstimatedChecks = 170;

class S3ConformanceSuite {
  S3ConformanceSuite({
    required this.executor,
    required this.config,
    required this.endpoint,
    this.onProgress,
    ConformanceCancellation? cancellation,
    Random? random,
    Future<void> Function(Duration)? sleep,
    DateTime Function()? clock,
    this.multipartPartSize = 5 * 1024 * 1024,
  })  : cancellation = cancellation ?? ConformanceCancellation(),
        _random = random ?? Random.secure(),
        _sleep = sleep ?? Future<void>.delayed,
        _clock = clock ?? DateTime.now;

  final S3OpExecutor executor;
  final ConformanceConfig config;
  final ConformanceEndpoint endpoint;
  final void Function(ConformanceProgress progress)? onProgress;
  final ConformanceCancellation cancellation;

  /// Minimum non-final part size. 5 MiB per the S3 limits; tests may lower it
  /// only together with a fake executor.
  final int multipartPartSize;
  final Random _random;
  final Future<void> Function(Duration) _sleep;
  final DateTime Function() _clock;

  late ConformanceEngineRun _run;
  ConformancePhase _phase = ConformancePhase.setup;
  S3ConformanceCapability? _capability;
  Duration _serverSkew = Duration.zero;

  late String _stdBucket;
  late String _lockBucket;
  late String _peerBucket;

  /// Buckets this run proved it created (CreateBucket 2xx). Only these are
  /// purged and deleted by teardown.
  final List<String> _ownedBuckets = <String>[];

  /// Buckets whose CreateBucket had no definite outcome (for example a
  /// transport failure). Teardown reports them but never purges them.
  final Set<String> _uncertainBuckets = <String>{};
  bool _stdReady = false;
  bool _lockReady = false;
  bool _versioningEnabled = false;
  DateTime? _complianceUntil;

  /// Fixture state shared by dependent checks.
  final Map<String, Object?> _state = <String, Object?>{};

  /// Runs the full catalog and teardown; never throws for endpoint behaviour.
  Future<ConformanceEngineRun> run() async {
    var runId = _newRunId();
    _assignBuckets(runId);
    _run = ConformanceEngineRun(
      engineId: executor.engineId,
      runId: runId,
      startedAt: _clock(),
      endpoint: endpoint.displayHost,
      region: endpoint.region,
      pathStyle: endpoint.pathStyle,
      buckets: {
        'standard': _stdBucket,
        if (config.includeObjectLock) 'objectLock': _lockBucket,
        'copyPeer': _peerBucket,
      },
    );
    try {
      _capability = await executor.capability();
    } on S3OpRpcException catch (error) {
      _run.note = 'Capabilities unavailable: ${conformanceClip(error.message, 160)}';
    }
    final capability = _capability;
    if (capability != null) {
      _run.sdk = capability.sdk;
      _run.client = capability.client;
    }
    if (capability == null || !capability.supported) {
      _run.status = ConformanceRunStatus.failed;
      _run.note = capability?.reason ??
          'The ${executor.engineId} engine does not advertise conformance.s3.';
      _run.finishedAt = _clock();
      return _run;
    }
    // Pick names nobody uses yet: an existing bucket (ours or someone else's)
    // must never become a test bucket.
    for (var attempt = 0; attempt < 5 && await _anyBucketExists(); attempt++) {
      runId = _newRunId();
      _assignBuckets(runId);
    }
    _run = ConformanceEngineRun(
      engineId: _run.engineId,
      runId: runId,
      startedAt: _run.startedAt,
      sdk: _run.sdk,
      client: _run.client,
      endpoint: _run.endpoint,
      region: _run.region,
      pathStyle: _run.pathStyle,
      note: _run.note,
      buckets: {
        'standard': _stdBucket,
        if (config.includeObjectLock) 'objectLock': _lockBucket,
        'copyPeer': _peerBucket,
      },
    );
    var status = ConformanceRunStatus.completed;
    try {
      await _setupPhase();
      if (_stdReady) {
        _phase = ConformancePhase.standard;
        await _standardPhase();
        _phase = ConformancePhase.versioning;
        await _versioningPhase();
      }
      if (config.includeObjectLock) {
        _phase = ConformancePhase.objectLock;
        await _objectLockPhase();
      }
    } on _Cancelled {
      status = ConformanceRunStatus.cancelled;
    } catch (error) {
      status = ConformanceRunStatus.failed;
      _run.note = 'Suite stopped: ${conformanceClip(error, 200)}';
    }
    if (!cancellation.skipTeardown) {
      _phase = ConformancePhase.teardown;
      try {
        await _teardownPhase();
      } catch (error) {
        _run.teardown = ConformanceTeardownReport(
          bucketsRetained: List.of(_ownedBuckets),
          errors: ['Teardown stopped: ${conformanceClip(error, 200)}'],
        );
      }
    } else {
      _run.teardown = ConformanceTeardownReport(
        bucketsRetained: List.of(_ownedBuckets),
        errors: const ['Teardown skipped by force stop.'],
      );
    }
    _run.status = status;
    _run.finishedAt = _clock();
    return _run;
  }

  void _assignBuckets(String runId) {
    _stdBucket = '${config.baseBucketName}-std-$runId';
    _lockBucket = '${config.baseBucketName}-lock-$runId';
    _peerBucket = '${config.baseBucketName}-xb-$runId';
  }

  Future<bool> _anyBucketExists() async {
    for (final bucket in [_stdBucket, _lockBucket, _peerBucket]) {
      final head = await _quiet('HeadBucket', {'Bucket': bucket});
      if (head != null && head.isService && head.httpStatus != 404) return true;
    }
    return false;
  }

  /// CreateBucket inside a check, recording ownership only on proof.
  Future<S3OpObservation> _createBucket(_CheckContext c, String bucket,
      {bool objectLock = false, Map<String, Object?>? input}) async {
    _uncertainBuckets.add(bucket);
    try {
      final o = await c.call('CreateBucket', input ?? _createBucketInput(bucket, objectLock: objectLock));
      _uncertainBuckets.remove(bucket);
      if (o.isSuccess && !_ownedBuckets.contains(bucket)) _ownedBuckets.add(bucket);
      return o;
    } on _CheckUnsupported {
      _uncertainBuckets.remove(bucket);
      rethrow;
    }
  }

  String _newRunId() {
    const alphabet = '0123456789abcdefghijklmnopqrstuvwxyz';
    return List.generate(8, (_) => alphabet[_random.nextInt(alphabet.length)])
        .join();
  }

  /// Server time estimated from the latest `Date` response header.
  DateTime _serverNow() => _clock().toUtc().add(_serverSkew);

  void _observeDate(S3OpObservation observation) {
    final date = observation.header('date');
    if (date == null) return;
    final parsed = _parseHttpDate(date);
    if (parsed != null) _serverSkew = parsed.difference(_clock().toUtc());
  }

  Future<void> _waitUntilServer(DateTime target,
      {Duration max = const Duration(seconds: 30)}) async {
    final deadline = _clock().add(max);
    while (_serverNow().isBefore(target) && _clock().isBefore(deadline)) {
      _throwIfCancelled();
      final remaining = target.difference(_serverNow());
      await _sleep(remaining > const Duration(milliseconds: 500)
          ? const Duration(milliseconds: 500)
          : remaining + const Duration(milliseconds: 20));
    }
  }

  /// Teardown always runs to completion once started.
  void _throwIfCancelled() {
    if (cancellation.isCancelled && _phase != ConformancePhase.teardown) {
      throw const _Cancelled();
    }
  }

  bool _supportsOp(String op) => _capability?.ops.contains(op) ?? false;

  /// Runs one check and records its result.
  Future<ConformanceCheckResult> _check(
    String id, {
    required String category,
    required String title,
    required String spec,
    ConformanceSeverity severity = ConformanceSeverity.required,
    required Future<void> Function(_CheckContext c) body,
  }) async {
    _throwIfCancelled();
    final context = _CheckContext(this, id);
    final watch = Stopwatch()..start();
    onProgress?.call(ConformanceProgress(
      engineId: executor.engineId,
      phase: _phase,
      completed: _run.checks.length,
      estimatedTotal: conformanceEstimatedChecks,
      currentCheck: id,
    ));
    ConformanceStatus status;
    String? note;
    var cancelled = false;
    try {
      await body(context);
      status = context._statusFor(severity);
    } on _CheckAbort {
      status = context._statusFor(severity);
    } on _CheckSkipped catch (skip) {
      status = ConformanceStatus.skipped;
      note = skip.reason;
    } on _CheckUnsupported catch (unsupported) {
      status = ConformanceStatus.unsupported;
      note = unsupported.reason;
    } on _CheckError catch (error) {
      status = ConformanceStatus.error;
      note = error.reason;
    } on _Cancelled {
      status = ConformanceStatus.skipped;
      note = 'Cancelled.';
      cancelled = true;
    } catch (error) {
      status = ConformanceStatus.error;
      note = 'Harness error: ${conformanceClip(error, 200)}';
    }
    watch.stop();
    final result = ConformanceCheckResult(
      id: id,
      phase: _phase,
      category: category,
      title: title,
      specRef: spec,
      severity: severity,
      status: status,
      expectations: List.unmodifiable(context._expectations),
      calls: List.unmodifiable(context._calls),
      durationMs: watch.elapsedMicroseconds / 1000,
      note: note ?? context._note,
    );
    _run.checks.add(result);
    onProgress?.call(ConformanceProgress(
      engineId: executor.engineId,
      phase: _phase,
      completed: _run.checks.length,
      estimatedTotal: conformanceEstimatedChecks,
      lastResult: result,
    ));
    if (cancelled) throw const _Cancelled();
    return result;
  }

  bool _passed(String id) =>
      _run.check(id)?.status == ConformanceStatus.pass ||
      _run.check(id)?.status == ConformanceStatus.warn;

  /// Runs an untracked call (setup or teardown), outside any check.
  Future<S3OpObservation?> _quiet(String op, Map<String, Object?> input,
      {S3OpBody? body}) async {
    try {
      final observation = await executor.execute(S3OpRequest(op, input, body: body));
      _observeDate(observation);
      return observation;
    } catch (_) {
      // Untracked calls never stop setup or teardown.
      return null;
    }
  }

  Map<String, Object?> _createBucketInput(String bucket,
      {bool objectLock = false}) {
    final region = endpoint.region.trim();
    return {
      'Bucket': bucket,
      if (region.isNotEmpty && region != 'us-east-1')
        'CreateBucketConfiguration': {'LocationConstraint': region},
      if (objectLock) 'ObjectLockEnabledForBucket': true,
    };
  }
}

/// Collects calls and expectations for one check.
class _CheckContext {
  _CheckContext(this.suite, this.id);

  static const int _maxCalls = 64;
  static const int _maxExpectations = 96;

  final S3ConformanceSuite suite;
  final String id;
  final List<ConformanceCall> _calls = <ConformanceCall>[];
  final List<ConformanceExpectation> _expectations = <ConformanceExpectation>[];
  String? _note;
  int _droppedCalls = 0;

  String get std => suite._stdBucket;

  void note(String text) => _note = conformanceClip(text, 240);

  Never skip(String reason) => throw _CheckSkipped(reason);

  Never unsupported(String reason) => throw _CheckUnsupported(reason);

  void requirePassed(String checkId) {
    if (!suite._passed(checkId)) skip('Prerequisite $checkId did not pass.');
  }

  Future<S3OpObservation> call(
    String op,
    Map<String, Object?> input, {
    S3OpBody? body,
    String? customerKey,
    String? sourceCustomerKey,
    bool notImplementedIsUnsupported = true,
  }) async {
    suite._throwIfCancelled();
    if (!suite._supportsOp(op)) {
      unsupported('The ${suite.executor.engineId} engine does not implement $op.');
    }
    final S3OpObservation observation;
    try {
      observation = await suite.executor.execute(S3OpRequest(op, input,
          body: body,
          customerKey: customerKey,
          sourceCustomerKey: sourceCustomerKey));
    } on S3OpRpcException catch (error) {
      if (error.isUnsupported) {
        unsupported('The ${suite.executor.engineId} engine rejected $op: ${conformanceClip(error.message, 160)}');
      }
      throw _CheckError('$op failed in the engine (${error.code}): ${conformanceClip(error.message, 160)}');
    }
    suite._observeDate(observation);
    if (_calls.length < _maxCalls) {
      _calls.add(ConformanceCall(
        op: op,
        outcome: observation.outcome,
        httpStatus: observation.httpStatus,
        latencyMs: observation.latencyMs,
        errorCode: observation.errorCode,
        attempts: observation.attempts,
      ));
    } else {
      _droppedCalls++;
      _note = '$_droppedCalls further calls not listed.';
    }
    if (observation.outcome == 'transport') {
      throw _CheckError('$op transport failure: ${conformanceClip(observation.errorMessage ?? observation.errorCode, 160)}');
    }
    if (notImplementedIsUnsupported &&
        observation.isService &&
        (observation.httpStatus == 501 ||
            observation.errorCode == 'NotImplemented')) {
      unsupported('Endpoint returned ${observation.httpStatus} ${observation.errorCode ?? ''} for $op.'.trim());
    }
    return observation;
  }

  void _add(ConformanceExpectation expectation) {
    if (_expectations.length < _maxExpectations || !expectation.ok) {
      _expectations.add(expectation);
    }
  }

  static String describe(S3OpObservation o) {
    if (!o.isService) {
      return '${o.outcome}${o.errorCode == null ? '' : ' ${o.errorCode}'}'
          '${o.errorMessage == null ? '' : ': ${conformanceClip(o.errorMessage, 120)}'}';
    }
    return o.errorCode == null || o.httpStatus < 300
        ? '${o.httpStatus}'
        : '${o.httpStatus} ${o.errorCode}';
  }

  /// Status (and S3 error code for responses with a body) of [o].
  bool status(S3OpObservation o, int expected,
      {String? code,
      List<String> alternativeCodes = const [],
      bool informational = false,
      bool informationalCode = false,
      String? explanation}) {
    // A 2xx that carries an S3 error (CompleteMultipartUpload, copy) is not a success.
    final statusOk = o.isService && o.httpStatus == expected &&
        !(expected < 300 && o.errorCode != null);
    // HEAD responses and 304 have no body; SDK-synthesised codes are ignored.
    final hasBody = o.op != 'HeadObject' &&
        o.op != 'HeadBucket' &&
        o.httpStatus != 304;
    final wantCode = code != null && hasBody;
    final codeOk = !wantCode ||
        o.errorCode == code ||
        alternativeCodes.contains(o.errorCode);
    final expectedText = wantCode ? '$expected $code' : '$expected';
    if (wantCode && statusOk && !codeOk && informationalCode) {
      _add(ConformanceExpectation(
          field: '${o.op} status', expected: '$expected', actual: '${o.httpStatus}', ok: true));
      _add(ConformanceExpectation(
        field: '${o.op} error code',
        expected: code,
        actual: o.errorCode ?? 'absent',
        ok: false,
        informational: true,
        explanation: explanation ?? 'The status matches but the S3 error code differs.',
      ));
      return true;
    }
    final ok = statusOk && codeOk;
    _add(ConformanceExpectation(
      field: '${o.op} status',
      expected: expectedText,
      actual: describe(o),
      ok: ok,
      informational: informational,
      explanation: ok ? null : explanation,
    ));
    return ok;
  }

  /// Any 2xx response.
  bool success(S3OpObservation o,
      {int? preferred, bool informational = false, String? explanation}) {
    final ok = o.isSuccess;
    _add(ConformanceExpectation(
      field: '${o.op} status',
      expected: preferred == null ? '2xx' : '$preferred',
      actual: describe(o),
      ok: ok,
      informational: informational,
      explanation: ok ? null : explanation,
    ));
    if (ok && preferred != null && o.httpStatus != preferred) {
      _add(ConformanceExpectation(
        field: '${o.op} exact status',
        expected: '$preferred',
        actual: '${o.httpStatus}',
        ok: false,
        informational: true,
        explanation: 'A success status other than the one AWS documents.',
      ));
    }
    return ok;
  }

  /// Like [success] but stops the check when the fixture step failed.
  void fixture(S3OpObservation o, {String? explanation}) {
    if (!success(o, explanation: explanation ?? 'Fixture step failed; the rest of the check cannot run.')) {
      throw const _CheckAbort();
    }
  }

  bool equals(String field, Object? expected, Object? actual,
      {bool informational = false, String? explanation}) {
    final ok = _same(expected, actual);
    _add(ConformanceExpectation(
      field: field,
      expected: conformanceClip(_text(expected)),
      actual: conformanceClip(_text(actual)),
      ok: ok,
      informational: informational,
      explanation: ok ? null : explanation,
    ));
    return ok;
  }

  bool isTrue(String field, bool condition,
      {required String expected,
      required Object? actual,
      bool informational = false,
      String? explanation}) {
    _add(ConformanceExpectation(
      field: field,
      expected: conformanceClip(expected),
      actual: conformanceClip(_text(actual)),
      ok: condition,
      informational: informational,
      explanation: condition ? null : explanation,
    ));
    return condition;
  }

  bool header(S3OpObservation o, String name, Object? expected,
          {bool informational = false, String? explanation}) =>
      equals('${o.op} $name', expected, o.header(name),
          informational: informational, explanation: explanation);

  bool headerPresent(S3OpObservation o, String name,
      {bool informational = false, String? explanation}) {
    final value = o.header(name);
    return isTrue('${o.op} $name', value != null && value.isNotEmpty,
        expected: 'present',
        actual: value,
        informational: informational,
        explanation: explanation);
  }

  bool headerAbsent(S3OpObservation o, String name,
      {bool informational = false, String? explanation}) {
    final value = o.header(name);
    return isTrue('${o.op} $name', value == null,
        expected: 'absent',
        actual: value,
        informational: informational,
        explanation: explanation);
  }

  /// Compares a body digest from GetObject or a presigned GET.
  bool body(S3OpObservation o, List<int> expected, {String? field}) {
    final digest = o.field('Body.sha256');
    final length = o.field('Body.length');
    final okLength = equals('${field ?? o.op} body length', expected.length,
        length is num ? length.toInt() : length);
    final okDigest = equals('${field ?? o.op} body sha256',
        ConformanceBytes.sha256Hex(expected), digest,
        explanation: 'The payload returned differs from the bytes written.');
    return okLength && okDigest;
  }

  static String _text(Object? value) {
    if (value == null) return 'absent';
    if (value is String) return value;
    try {
      return jsonEncode(value);
    } catch (_) {
      return '$value';
    }
  }

  static bool _same(Object? a, Object? b) {
    if (a is num && b is num) return a == b;
    if (a is List && b is List) {
      if (a.length != b.length) return false;
      for (var i = 0; i < a.length; i++) {
        if (!_same(a[i], b[i])) return false;
      }
      return true;
    }
    if (a is Map && b is Map) {
      if (a.length != b.length) return false;
      for (final key in a.keys) {
        if (!b.containsKey(key) || !_same(a[key], b[key])) return false;
      }
      return true;
    }
    return a == b;
  }

  ConformanceStatus _statusFor(ConformanceSeverity severity) {
    final failed = _expectations.where((item) => !item.ok);
    if (failed.isEmpty) return ConformanceStatus.pass;
    final hard = failed.any((item) => !item.informational);
    if (hard && severity == ConformanceSeverity.required) {
      return ConformanceStatus.fail;
    }
    return ConformanceStatus.warn;
  }
}

/// Parses an RFC 7231 IMF-fixdate (`Tue, 03 Jun 2025 10:00:00 GMT`).
DateTime? _parseHttpDate(String value) {
  const months = {
    'Jan': 1, 'Feb': 2, 'Mar': 3, 'Apr': 4, 'May': 5, 'Jun': 6,
    'Jul': 7, 'Aug': 8, 'Sep': 9, 'Oct': 10, 'Nov': 11, 'Dec': 12,
  };
  final match = RegExp(r'(\d{1,2}) (\w{3}) (\d{4}) (\d{2}):(\d{2}):(\d{2})')
      .firstMatch(value);
  if (match == null) return DateTime.tryParse(value)?.toUtc();
  final month = months[match.group(2)];
  if (month == null) return null;
  return DateTime.utc(
    int.parse(match.group(3)!),
    month,
    int.parse(match.group(1)!),
    int.parse(match.group(4)!),
    int.parse(match.group(5)!),
    int.parse(match.group(6)!),
  );
}

/// ISO-8601 UTC with whole seconds, as the host sends timestamps.
String _isoSeconds(DateTime value) {
  final utc = value.toUtc();
  String two(int n) => n.toString().padLeft(2, '0');
  return '${utc.year.toString().padLeft(4, '0')}-${two(utc.month)}-${two(utc.day)}'
      'T${two(utc.hour)}:${two(utc.minute)}:${two(utc.second)}Z';
}

DateTime? _parseIso(Object? value) =>
    value == null ? null : DateTime.tryParse('$value')?.toUtc();

/// Decodes an `EncodingType=url` value: percent-decoding where `+` is a space,
/// as S3 and botocore do.
String _formDecode(String value) {
  try {
    return Uri.decodeQueryComponent(value);
  } catch (_) {
    return value;
  }
}

String _unquoteEtag(String? value) {
  if (value == null) return '';
  var text = value.trim();
  if (text.startsWith('W/')) text = text.substring(2);
  if (text.length >= 2 && text.startsWith('"') && text.endsWith('"')) {
    text = text.substring(1, text.length - 1);
  }
  return text;
}

Uint8List _concat(List<List<int>> parts) {
  final total = parts.fold<int>(0, (sum, part) => sum + part.length);
  final out = Uint8List(total);
  var offset = 0;
  for (final part in parts) {
    out.setRange(offset, offset + part.length, part);
    offset += part.length;
  }
  return out;
}
