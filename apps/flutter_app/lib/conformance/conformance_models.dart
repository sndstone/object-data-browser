// Result model of the S3 API conformance suite. Pure Dart.
//
// Records hold bounded strings only: no bodies, no request URLs, no credentials
// and no customer keys. Exports are built from these records alone.

enum ConformancePhase {
  setup('Setup', 'Bucket 1 creation and baseline state'),
  standard('Phase 1', 'Bucket 1, versioning not enabled'),
  versioning('Phase 2', 'Bucket 1 after versioning is enabled'),
  objectLock('Phase 3', 'Bucket 2 with Object Lock enabled'),
  teardown('Teardown', 'Purge and delete the test buckets');

  const ConformancePhase(this.label, this.description);
  final String label;
  final String description;
}

enum ConformanceSeverity { required, informational }

enum ConformanceStatus {
  pass('Pass'),
  fail('Fail'),
  warn('Deviation'),
  unsupported('Unsupported'),
  skipped('Skipped'),
  error('Error');

  const ConformanceStatus(this.label);
  final String label;
}

/// One compared value. A failed expectation is a mismatch.
class ConformanceExpectation {
  const ConformanceExpectation({
    required this.field,
    required this.expected,
    required this.actual,
    required this.ok,
    this.explanation,
    this.informational = false,
  });

  factory ConformanceExpectation.fromJson(Map<String, Object?> json) =>
      ConformanceExpectation(
        field: '${json['field']}',
        expected: '${json['expected']}',
        actual: '${json['actual']}',
        ok: json['ok'] == true,
        explanation: json['explanation']?.toString(),
        informational: json['informational'] == true,
      );

  final String field;
  final String expected;
  final String actual;
  final bool ok;
  final String? explanation;

  /// A deviation that does not fail a required check (reported as a warning).
  final bool informational;

  Map<String, Object?> toJson() => {
        'field': field,
        'expected': expected,
        'actual': actual,
        'ok': ok,
        if (explanation != null) 'explanation': explanation,
        if (informational) 'informational': true,
      };
}

/// One S3 call made while evaluating a check.
class ConformanceCall {
  const ConformanceCall({
    required this.op,
    required this.outcome,
    required this.httpStatus,
    required this.latencyMs,
    this.errorCode,
    this.attempts = 1,
  });

  factory ConformanceCall.fromJson(Map<String, Object?> json) =>
      ConformanceCall(
        op: '${json['op']}',
        outcome: '${json['outcome'] ?? 'service'}',
        httpStatus: (json['httpStatus'] as num?)?.toInt() ?? 0,
        latencyMs: (json['latencyMs'] as num?)?.toDouble() ?? 0,
        errorCode: json['errorCode']?.toString(),
        attempts: (json['attempts'] as num?)?.toInt() ?? 1,
      );

  final String op;
  final String outcome;
  final int httpStatus;
  final double latencyMs;
  final String? errorCode;
  final int attempts;

  Map<String, Object?> toJson() => {
        'op': op,
        'outcome': outcome,
        'httpStatus': httpStatus,
        'latencyMs': double.parse(latencyMs.toStringAsFixed(3)),
        if (errorCode != null) 'errorCode': errorCode,
        if (attempts != 1) 'attempts': attempts,
      };
}

class ConformanceCheckResult {
  const ConformanceCheckResult({
    required this.id,
    required this.phase,
    required this.category,
    required this.title,
    required this.specRef,
    required this.severity,
    required this.status,
    required this.expectations,
    required this.calls,
    required this.durationMs,
    this.note,
  });

  factory ConformanceCheckResult.fromJson(Map<String, Object?> json) =>
      ConformanceCheckResult(
        id: '${json['id']}',
        phase: ConformancePhase.values.firstWhere(
            (value) => value.name == json['phase'],
            orElse: () => ConformancePhase.standard),
        category: '${json['category']}',
        title: '${json['title']}',
        specRef: '${json['specRef']}',
        severity: json['severity'] == 'informational'
            ? ConformanceSeverity.informational
            : ConformanceSeverity.required,
        status: ConformanceStatus.values.firstWhere(
            (value) => value.name == json['status'],
            orElse: () => ConformanceStatus.error),
        expectations: [
          for (final item in (json['expectations'] as List?) ?? const [])
            if (item is Map)
              ConformanceExpectation.fromJson(Map<String, Object?>.from(item))
        ],
        calls: [
          for (final item in (json['calls'] as List?) ?? const [])
            if (item is Map)
              ConformanceCall.fromJson(Map<String, Object?>.from(item))
        ],
        durationMs: (json['durationMs'] as num?)?.toDouble() ?? 0,
        note: json['note']?.toString(),
      );

  final String id;
  final ConformancePhase phase;
  final String category;
  final String title;

  /// AWS S3 API reference operation(s) and the rule checked.
  final String specRef;
  final ConformanceSeverity severity;
  final ConformanceStatus status;
  final List<ConformanceExpectation> expectations;
  final List<ConformanceCall> calls;
  final double durationMs;

  /// Why the check was skipped, unsupported or errored.
  final String? note;

  Iterable<ConformanceExpectation> get mismatches =>
      expectations.where((item) => !item.ok);

  double get callLatencyMs =>
      calls.fold(0.0, (sum, call) => sum + call.latencyMs);

  /// The status, HTTP status and error code of the decisive call, for tables.
  String get headline {
    final failed = mismatches.firstOrNull;
    if (failed != null) return '${failed.field}: ${failed.actual}';
    final last = calls.lastOrNull;
    if (last == null) return note ?? status.label;
    return '${last.op} ${last.httpStatus}${last.errorCode == null ? '' : ' ${last.errorCode}'}';
  }

  Map<String, Object?> toJson() => {
        'id': id,
        'phase': phase.name,
        'category': category,
        'title': title,
        'specRef': specRef,
        'severity': severity.name,
        'status': status.name,
        'expectations': [for (final item in expectations) item.toJson()],
        'calls': [for (final call in calls) call.toJson()],
        'durationMs': double.parse(durationMs.toStringAsFixed(3)),
        if (note != null) 'note': note,
      };
}

class ConformanceTeardownReport {
  const ConformanceTeardownReport({
    this.bucketsDeleted = const [],
    this.bucketsRetained = const [],
    this.objectsDeleted = 0,
    this.uploadsAborted = 0,
    this.legalHoldsCleared = 0,
    this.leftovers = 0,
    this.errors = const [],
  });

  factory ConformanceTeardownReport.fromJson(Map<String, Object?> json) =>
      ConformanceTeardownReport(
        bucketsDeleted: [
          for (final item in (json['bucketsDeleted'] as List?) ?? const [])
            '$item'
        ],
        bucketsRetained: [
          for (final item in (json['bucketsRetained'] as List?) ?? const [])
            '$item'
        ],
        objectsDeleted: (json['objectsDeleted'] as num?)?.toInt() ?? 0,
        uploadsAborted: (json['uploadsAborted'] as num?)?.toInt() ?? 0,
        legalHoldsCleared: (json['legalHoldsCleared'] as num?)?.toInt() ?? 0,
        leftovers: (json['leftovers'] as num?)?.toInt() ?? 0,
        errors: [
          for (final item in (json['errors'] as List?) ?? const []) '$item'
        ],
      );

  final List<String> bucketsDeleted;
  final List<String> bucketsRetained;
  final int objectsDeleted;
  final int uploadsAborted;
  final int legalHoldsCleared;
  final int leftovers;
  final List<String> errors;

  bool get clean => errors.isEmpty && leftovers == 0 && bucketsRetained.isEmpty;

  Map<String, Object?> toJson() => {
        'bucketsDeleted': bucketsDeleted,
        'bucketsRetained': bucketsRetained,
        'objectsDeleted': objectsDeleted,
        'uploadsAborted': uploadsAborted,
        'legalHoldsCleared': legalHoldsCleared,
        'leftovers': leftovers,
        'errors': errors,
      };
}

class ConformanceConfig {
  const ConformanceConfig({
    required this.baseBucketName,
    this.engineIds = const ['python'],
    this.includeObjectLock = true,
    this.includeShortCompliance = true,
    this.includeSseC = true,
    this.includeSseKms = true,
    this.kmsKeyId = '',
    this.retainBucketsOnFailure = false,
  });

  factory ConformanceConfig.fromJson(Map<String, Object?> json) =>
      ConformanceConfig(
        baseBucketName: '${json['baseBucketName'] ?? 'odb-conformance'}',
        engineIds: [
          for (final item in (json['engineIds'] as List?) ?? const ['python'])
            '$item'
        ],
        includeObjectLock: json['includeObjectLock'] != false,
        includeShortCompliance: json['includeShortCompliance'] != false,
        includeSseC: json['includeSseC'] != false,
        includeSseKms: json['includeSseKms'] != false,
        kmsKeyId: '${json['kmsKeyId'] ?? ''}',
        retainBucketsOnFailure: json['retainBucketsOnFailure'] == true,
      );

  /// Lower-case letters, digits and hyphens; buckets are
  /// `<base>-std-<run>`, `<base>-lock-<run>` and `<base>-xb-<run>`.
  final String baseBucketName;
  final List<String> engineIds;
  final bool includeObjectLock;

  /// A COMPLIANCE retention of a few seconds on one object; teardown waits
  /// for it to expire.
  final bool includeShortCompliance;

  /// SSE-C runs only on HTTPS or loopback endpoints; otherwise it is skipped.
  final bool includeSseC;
  final bool includeSseKms;
  final String kmsKeyId;
  final bool retainBucketsOnFailure;

  static final RegExp _basePattern = RegExp(r'^[a-z0-9](?:[a-z0-9-]{1,38}[a-z0-9])$');

  /// Returns a reason the base bucket name is not usable, or null.
  static String? validateBaseName(String value) {
    if (!_basePattern.hasMatch(value)) {
      return 'Use 3–40 lower-case letters, digits or hyphens, starting and ending with a letter or digit.';
    }
    if (value.contains('--')) return 'Avoid consecutive hyphens.';
    return null;
  }

  ConformanceConfig copyWith({
    String? baseBucketName,
    List<String>? engineIds,
    bool? includeObjectLock,
    bool? includeShortCompliance,
    bool? includeSseC,
    bool? includeSseKms,
    String? kmsKeyId,
    bool? retainBucketsOnFailure,
  }) =>
      ConformanceConfig(
        baseBucketName: baseBucketName ?? this.baseBucketName,
        engineIds: engineIds ?? this.engineIds,
        includeObjectLock: includeObjectLock ?? this.includeObjectLock,
        includeShortCompliance:
            includeShortCompliance ?? this.includeShortCompliance,
        includeSseC: includeSseC ?? this.includeSseC,
        includeSseKms: includeSseKms ?? this.includeSseKms,
        kmsKeyId: kmsKeyId ?? this.kmsKeyId,
        retainBucketsOnFailure:
            retainBucketsOnFailure ?? this.retainBucketsOnFailure,
      );

  Map<String, Object?> toJson() => {
        'baseBucketName': baseBucketName,
        'engineIds': engineIds,
        'includeObjectLock': includeObjectLock,
        'includeShortCompliance': includeShortCompliance,
        'includeSseC': includeSseC,
        'includeSseKms': includeSseKms,
        'kmsKeyId': kmsKeyId,
        'retainBucketsOnFailure': retainBucketsOnFailure,
      };
}

enum ConformanceRunStatus { running, completed, cancelled, failed }

/// The suite's result for one engine.
class ConformanceEngineRun {
  ConformanceEngineRun({
    required this.engineId,
    required this.runId,
    required this.startedAt,
    this.sdk = '',
    this.client = const {},
    this.endpoint = '',
    this.region = '',
    this.pathStyle = false,
    this.buckets = const {},
    List<ConformanceCheckResult>? checks,
    this.teardown,
    this.finishedAt,
    this.status = ConformanceRunStatus.running,
    this.gatePassed,
    this.note,
  }) : checks = checks ?? <ConformanceCheckResult>[];

  factory ConformanceEngineRun.fromJson(Map<String, Object?> json) =>
      ConformanceEngineRun(
        engineId: '${json['engineId']}',
        runId: '${json['runId']}',
        startedAt: DateTime.tryParse('${json['startedAt']}') ?? DateTime(1970),
        finishedAt: DateTime.tryParse('${json['finishedAt']}'),
        sdk: '${json['sdk'] ?? ''}',
        client: json['client'] is Map
            ? Map<String, Object?>.from(json['client'] as Map)
            : const {},
        endpoint: '${json['endpoint'] ?? ''}',
        region: '${json['region'] ?? ''}',
        pathStyle: json['pathStyle'] == true,
        buckets: json['buckets'] is Map
            ? {
                for (final entry in (json['buckets'] as Map).entries)
                  '${entry.key}': '${entry.value}'
              }
            : const {},
        checks: [
          for (final item in (json['checks'] as List?) ?? const [])
            if (item is Map)
              ConformanceCheckResult.fromJson(Map<String, Object?>.from(item))
        ],
        teardown: json['teardown'] is Map
            ? ConformanceTeardownReport.fromJson(
                Map<String, Object?>.from(json['teardown'] as Map))
            : null,
        status: ConformanceRunStatus.values.firstWhere(
            (value) => value.name == json['status'],
            orElse: () => ConformanceRunStatus.failed),
        gatePassed: json['gatePassed'] as bool?,
        note: json['note']?.toString(),
      );

  final String engineId;
  final String runId;
  final DateTime startedAt;
  DateTime? finishedAt;
  String sdk;
  Map<String, Object?> client;
  String endpoint;
  String region;
  bool pathStyle;
  Map<String, String> buckets;
  final List<ConformanceCheckResult> checks;
  ConformanceTeardownReport? teardown;
  ConformanceRunStatus status;

  /// Whether every required phase-1 check passed before versioning was enabled.
  bool? gatePassed;
  String? note;

  int count(ConformanceStatus status) =>
      checks.where((check) => check.status == status).length;

  Map<ConformanceStatus, int> get counts => {
        for (final status in ConformanceStatus.values) status: count(status)
      };

  double get totalCallLatencyMs =>
      checks.fold(0.0, (sum, check) => sum + check.callLatencyMs);

  int get callCount => checks.fold(0, (sum, check) => sum + check.calls.length);

  ConformanceCheckResult? check(String id) =>
      checks.where((check) => check.id == id).firstOrNull;

  Map<String, Object?> toJson() => {
        'engineId': engineId,
        'runId': runId,
        'startedAt': startedAt.toUtc().toIso8601String(),
        if (finishedAt != null)
          'finishedAt': finishedAt!.toUtc().toIso8601String(),
        'status': status.name,
        'sdk': sdk,
        'client': client,
        'endpoint': endpoint,
        'region': region,
        'pathStyle': pathStyle,
        'buckets': buckets,
        if (gatePassed != null) 'gatePassed': gatePassed,
        if (note != null) 'note': note,
        'summary': {
          for (final entry in counts.entries) entry.key.name: entry.value,
          'calls': callCount,
          'callLatencyMs': double.parse(totalCallLatencyMs.toStringAsFixed(3)),
        },
        'checks': [for (final check in checks) check.toJson()],
        if (teardown != null) 'teardown': teardown!.toJson(),
      };
}

/// A complete conformance run across one or more engines.
class ConformanceReport {
  ConformanceReport({
    required this.id,
    required this.config,
    required this.profileName,
    required this.startedAt,
    List<ConformanceEngineRun>? engines,
    this.finishedAt,
  }) : engines = engines ?? <ConformanceEngineRun>[];

  factory ConformanceReport.fromJson(Map<String, Object?> json) =>
      ConformanceReport(
        id: '${json['id']}',
        config: ConformanceConfig.fromJson(
            Map<String, Object?>.from((json['config'] as Map?) ?? const {})),
        profileName: '${json['profileName'] ?? ''}',
        startedAt: DateTime.tryParse('${json['startedAt']}') ?? DateTime(1970),
        finishedAt: DateTime.tryParse('${json['finishedAt']}'),
        engines: [
          for (final item in (json['engines'] as List?) ?? const [])
            if (item is Map)
              ConformanceEngineRun.fromJson(Map<String, Object?>.from(item))
        ],
      );

  final String id;
  final ConformanceConfig config;
  final String profileName;
  final DateTime startedAt;
  DateTime? finishedAt;
  final List<ConformanceEngineRun> engines;

  Map<String, Object?> toJson() => {
        'format': 'object-data-browser.s3-conformance',
        'formatVersion': 1,
        'id': id,
        'profileName': profileName,
        'startedAt': startedAt.toUtc().toIso8601String(),
        if (finishedAt != null)
          'finishedAt': finishedAt!.toUtc().toIso8601String(),
        'config': config.toJson(),
        'engines': [for (final engine in engines) engine.toJson()],
      };

  /// Check IDs whose status differs between engines that ran them.
  List<String> discrepancies() {
    final ids = <String>[];
    final seen = <String>{};
    for (final engine in engines) {
      for (final check in engine.checks) {
        if (!seen.add(check.id)) continue;
        final statuses = {
          for (final other in engines) other.check(check.id)?.status
        }..remove(null);
        if (statuses.length > 1) ids.add(check.id);
      }
    }
    return ids;
  }
}

/// Bounded text for records: no record string grows beyond [max] characters.
String conformanceClip(Object? value, [int max = 240]) {
  final text = value == null ? 'absent' : '$value';
  return text.length <= max ? text : '${text.substring(0, max - 1)}…';
}
