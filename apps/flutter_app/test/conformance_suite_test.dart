import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:s3_browser_crossplat/conformance/conformance_bytes.dart';
import 'package:s3_browser_crossplat/conformance/conformance_export.dart';
import 'package:s3_browser_crossplat/conformance/conformance_models.dart';
import 'package:s3_browser_crossplat/conformance/conformance_suite.dart';
import 'package:s3_browser_crossplat/conformance/s3_op_executor.dart';

import 'conformance_fake.dart';

S3ConformanceSuite _suite(FakeExecutor executor,
        {ConformanceConfig? config, ConformanceCancellation? cancellation, String url = 'https://s3.example.test'}) =>
    S3ConformanceSuite(
      executor: executor,
      config: config ?? const ConformanceConfig(baseBucketName: 'odb-test'),
      endpoint: ConformanceEndpoint(endpointUrl: url, region: 'us-east-1', pathStyle: true),
      cancellation: cancellation,
      sleep: (_) async {},
      multipartPartSize: 64 * 1024,
    );

void main() {
  test('body generator matches the shared vectors', () {
    final vectors = jsonDecode(File('../../contracts/vectors/s3-conformance-body.json').readAsStringSync()) as Map;
    for (final item in (vectors['cases'] as List).cast<Map>()) {
      final data = ConformanceBytes.generate(item['size'] as int, item['seed'] as int);
      expect(ConformanceBytes.sha256Hex(data), item['sha256']);
      expect(data.take(8).map((b) => b.toRadixString(16).padLeft(2, '0')).join(), item['first8Hex']);
    }
  });

  test('checksums match known values', () {
    final data = utf8.encode('123456789');
    // Standard check values: CRC32 0xCBF43926, CRC32C 0xE3069283.
    expect(ConformanceBytes.crc32Base64(data), base64.encode([0xCB, 0xF4, 0x39, 0x26]));
    expect(ConformanceBytes.crc32cBase64(data), base64.encode([0xE3, 0x06, 0x92, 0x83]));
  });

  test('base bucket names are validated', () {
    expect(ConformanceConfig.validateBaseName('odb-conformance'), isNull);
    expect(ConformanceConfig.validateBaseName('Bad_Name'), isNotNull);
    expect(ConformanceConfig.validateBaseName('a'), isNotNull);
    expect(ConformanceConfig.validateBaseName('trailing-'), isNotNull);
    expect(ConformanceConfig.validateBaseName('x' * 41), isNotNull);
  });

  test('stages run in order and teardown deletes every bucket', () async {
    final executor = FakeExecutor();
    final run = await _suite(executor).run();
    final ops = executor.calls.map((c) => c.op).toList();
    // Preflight HEADs every planned name before anything is created.
    expect(ops.take(3), everyElement('HeadBucket'));
    final firstCreate = executor.calls.firstWhere((c) => c.op == 'CreateBucket');
    expect(firstCreate.input['Bucket'], startsWith('odb-test-std-'));
    final enable = executor.calls.indexWhere((c) =>
        c.op == 'PutBucketVersioning' && (c.input['VersioningConfiguration'] as Map)['Status'] == 'Enabled');
    final lastPhaseOne = run.checks.lastIndexWhere((c) => c.phase == ConformancePhase.standard);
    expect(enable, greaterThan(0));
    // The gate is recorded before versioning is enabled.
    expect(run.gatePassed, isNotNull);
    final gateIndex = run.checks.indexWhere((c) => c.id == 'versioning.gate');
    expect(gateIndex, greaterThan(lastPhaseOne));
    final lockCreate = executor.calls.indexWhere((c) => c.op == 'CreateBucket' && c.input['ObjectLockEnabledForBucket'] == true);
    expect(lockCreate, greaterThan(enable));
    expect(executor.calls[lockCreate].input['Bucket'], startsWith('odb-test-lock-'));
    expect(executor.buckets, isEmpty, reason: 'teardown must delete every bucket');
    expect(run.teardown?.bucketsRetained, isEmpty);
    expect(run.status, ConformanceRunStatus.completed);
    expect(run.checks.length, greaterThan(100));
    for (final check in run.checks) {
      for (final call in check.calls) {
        expect(call.latencyMs, 1.5);
      }
    }
  });

  test('a bucket the run did not create is never purged or deleted', () async {
    final executor = FakeExecutor()..collideFirstCreate = true;
    final run = await _suite(executor).run();
    expect(run.check('bucket.create')?.status, ConformanceStatus.fail);
    final collided = executor.collidedBucket!;
    expect(executor.buckets, contains(collided));
    expect(executor.objects[collided]?.keys, contains('precious.txt'));
    expect(executor.calls.where((c) => c.input['Bucket'] == collided && c.op.startsWith('Delete')), isEmpty);
  });

  test('names that cannot be confirmed unused are never created', () async {
    final executor = FakeExecutor()..headForbidden = true;
    final run = await _suite(executor).run();
    expect(run.status, ConformanceRunStatus.failed);
    expect(executor.calls.any((c) => c.op == 'CreateBucket'), isFalse);
  });

  test('a DeleteBucket that leaves the bucket in place is not reported clean', () async {
    final executor = FakeExecutor()..noOpDeleteBucket = true;
    final run = await _suite(executor).run();
    expect(run.teardown?.bucketsRetained, isNotEmpty);
    expect(run.teardown?.clean, isFalse);
  });

  test('the scrub backstop removes credentials and signing values', () {
    final scrubbed = scrubConformanceResult({
      'errorMessage': 'bad test key Signature=abc HTTPS://H.example/k?X-Amz-Signature=def ${'y' * 300}',
      'headers': {'location': 'https://h/k?X-Amz-Credential=AKID', 'etag': '"test"'},
      'output': {'TagSet': [{'Key': 'env', 'Value': 'test'}], 'Note': 'long-secret-value-0123456789'},
    }, ['test', 'long-secret-value-0123456789']);
    final message = scrubbed['errorMessage'] as String;
    expect(message.length, lessThanOrEqualTo(256));
    expect(message, isNot(contains(' test ')));
    expect(message, isNot(contains('abc')));
    expect(message, isNot(contains('def')));
    expect((scrubbed['headers'] as Map)['location'], 'https://h/k?[query]');
    // Short credentials are ordinary words in S3 data.
    expect((scrubbed['headers'] as Map)['etag'], '"test"');
    expect(jsonEncode(scrubbed['output']), contains('"Value":"test"'));
    expect(jsonEncode(scrubbed['output']), isNot(contains('long-secret-value')));
  });

  test('error codes survive redaction and quoted signing values do not', () {
    final scrubbed = scrubConformanceResult({
      'errorCode': 'AccessDenied',
      'errorMessage': 'Denied: Signature="abc123" "X-Amz-Credential":"AKID/x"',
      'headers': {'x-amz-request-id': 'req-Denied'},
    }, ['Denied']);
    expect(scrubbed['errorCode'], 'AccessDenied');
    expect(scrubbed['errorMessage'], isNot(contains('abc123')));
    expect(scrubbed['errorMessage'], isNot(contains('AKID/x')));
    expect((scrubbed['headers'] as Map)['x-amz-request-id'], 'req-[redacted]');
  });

  test('a create without a definite outcome is reported, never purged', () async {
    final executor = FakeExecutor(onCall: (_) {});
    final wrapped = _DecodeFailingCreate(executor);
    final run = await S3ConformanceSuite(
      executor: wrapped,
      config: const ConformanceConfig(baseBucketName: 'odb-test', includeObjectLock: false),
      endpoint: const ConformanceEndpoint(endpointUrl: 'https://s3.example.test', region: 'us-east-1', pathStyle: true),
      sleep: (_) async {},
      multipartPartSize: 64 * 1024,
    ).run();
    expect(run.teardown?.bucketsRetained, contains(startsWith('odb-test-std-')));
    expect(run.teardown?.clean, isFalse);
    expect(executor.buckets, isNotEmpty);
  });

  test('cancellation stops checks but still tears down', () async {
    final cancellation = ConformanceCancellation();
    late FakeExecutor executor;
    executor = FakeExecutor(onCall: (request) {
      if (executor.calls.length == 40) cancellation.cancel();
    });
    final run = await _suite(executor, cancellation: cancellation).run();
    expect(run.status, ConformanceRunStatus.cancelled);
    expect(executor.buckets, isEmpty);
    expect(run.checks.where((c) => c.phase == ConformancePhase.versioning), isEmpty);
  });

  test('force stop skips teardown and reports retained buckets', () async {
    final cancellation = ConformanceCancellation();
    late FakeExecutor executor;
    executor = FakeExecutor(onCall: (request) {
      if (executor.calls.length == 20) cancellation.cancel(skipTeardown: true);
    });
    final run = await _suite(executor, cancellation: cancellation).run();
    expect(run.teardown?.bucketsRetained, isNotEmpty);
    expect(executor.buckets, isNotEmpty);
  });

  test('engine without an operation reports unsupported, not failure', () async {
    final executor = FakeExecutor(ops: {...allConformanceOps}..remove('GetObjectAttributes'));
    final run = await _suite(executor).run();
    expect(run.check('object.attributes')?.status, ConformanceStatus.unsupported);
    expect(executor.calls.any((c) => c.op == 'GetObjectAttributes'), isFalse);
  });

  test('NotImplemented from the endpoint is recorded as unsupported', () async {
    final executor = FakeExecutor(unsupportedOps: const {'PutBucketWebsite'});
    final run = await _suite(executor).run();
    expect(run.check('bucket.website')?.status, ConformanceStatus.unsupported);
  });

  test('an engine without the capability does not touch the endpoint', () async {
    final executor = FakeExecutor()..capabilitySupported = false;
    final run = await _suite(executor).run();
    expect(run.status, ConformanceRunStatus.failed);
    expect(executor.calls, isEmpty);
  });

  test('SSE-C runs only on HTTPS or loopback and keys never reach the report', () async {
    final https = FakeExecutor();
    final run = await _suite(https).run();
    expect(https.customerKeys, isNotEmpty);
    final report = ConformanceReport(
        id: 'r', config: const ConformanceConfig(baseBucketName: 'odb-test'), profileName: 'p', startedAt: DateTime(2026))
      ..engines.add(run);
    final exported = ConformanceExport.json(report) + ConformanceExport.markdown(report, includePassing: true);
    for (final key in https.customerKeys) {
      expect(exported.contains(key), isFalse);
    }
    final plain = FakeExecutor();
    final plainRun = await _suite(plain, url: 'http://10.0.0.5:9000').run();
    expect(plain.customerKeys, isEmpty);
    expect(plainRun.check('sse.c')?.status, ConformanceStatus.skipped);
  });

  test('object lock stage can be turned off', () async {
    final executor = FakeExecutor();
    final run = await _suite(executor,
            config: const ConformanceConfig(baseBucketName: 'odb-test', includeObjectLock: false))
        .run();
    expect(executor.calls.any((c) => c.input['ObjectLockEnabledForBucket'] == true), isFalse);
    expect(run.checks.any((c) => c.phase == ConformancePhase.objectLock), isFalse);
  });

  test('report round-trips through JSON and finds discrepancies', () async {
    final a = await _suite(FakeExecutor()).run();
    final b = await _suite(FakeExecutor(ops: {...allConformanceOps}..remove('ListObjects'))).run();
    final report = ConformanceReport(
        id: 'r', config: const ConformanceConfig(baseBucketName: 'odb-test'), profileName: 'p', startedAt: DateTime(2026))
      ..engines.addAll([a, b]);
    final decoded = ConformanceReport.fromJson(jsonDecode(ConformanceExport.json(report)) as Map<String, Object?>);
    expect(decoded.engines.length, 2);
    expect(decoded.engines.first.checks.length, a.checks.length);
    expect(report.discrepancies(), contains('list.v1.delimiter'));
    expect(ConformanceExport.markdown(report), contains('## Engine discrepancies'));
  });

  test('observations parse the wire result', () {
    final o = S3OpObservation.fromJson({
      'op': 'ListObjectsV2',
      'outcome': 'service',
      'httpStatus': 200,
      'headers': {'ETag': '"x"'},
      'output': {
        'Contents': [
          {'Key': 'a'}
        ]
      },
      'latencyMs': 2.25,
    });
    expect(o.header('etag'), '"x"');
    expect(o.field('Contents.0.Key'), 'a');
    expect(o.list('Contents').single['Key'], 'a');
    expect(o.isSuccess, isTrue);
  });
}


/// Creates the bucket but reports an undecodable response.
class _DecodeFailingCreate implements S3OpExecutor {
  _DecodeFailingCreate(this.inner);
  final FakeExecutor inner;
  @override
  String get engineId => inner.engineId;
  @override
  Future<S3ConformanceCapability?> capability() => inner.capability();
  @override
  Future<S3OpObservation> execute(S3OpRequest request) async {
    final o = await inner.execute(request);
    if (request.op == 'CreateBucket' && o.isSuccess) {
      return const S3OpObservation(op: 'CreateBucket', outcome: 'sdk_decode', httpStatus: 200, errorCode: 'ParseError');
    }
    return o;
  }
}
