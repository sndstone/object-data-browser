// Opt-in real-service workload. The launcher owns the disposable S3 server and
// bucket. No AppController, app-state repository, or credential store is opened.
//
// Required environment: LOCAL_S3_PERF=1, LOCAL_S3_ENDPOINT,
// LOCAL_S3_ACCESS_KEY, LOCAL_S3_SECRET_KEY, LOCAL_S3_BUCKET,
// LOCAL_S3_ENGINE_ROOT, LOCAL_S3_OUTPUT_DIR.
// Optional workload settings are documented in _Configuration below.
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:s3_browser_crossplat/models/domain_models.dart';
import 'package:s3_browser_crossplat/services/desktop_engine_host.dart';
import 'package:s3_browser_crossplat/services/desktop_sidecar_engine_service.dart';

void main() {
  test('real local S3 service performance and roundtrip integrity', () async {
    final harness = _LocalS3Performance(_Configuration.fromEnvironment());
    await harness.run();
  },
      skip: Platform.environment['LOCAL_S3_PERF'] != '1'
          ? 'Set LOCAL_S3_PERF=1 through the disposable local S3 launcher.'
          : false,
      timeout: const Timeout(Duration(hours: 2)));
}

class _Configuration {
  _Configuration.fromEnvironment()
      : endpoint = _required('LOCAL_S3_ENDPOINT'),
        accessKey = _required('LOCAL_S3_ACCESS_KEY'),
        secretKey = _required('LOCAL_S3_SECRET_KEY'),
        bucket = _required('LOCAL_S3_BUCKET'),
        engineRoot = Directory(_required('LOCAL_S3_ENGINE_ROOT')).absolute.path,
        output = Directory(_required('LOCAL_S3_OUTPUT_DIR')).absolute,
        engines =
            (Platform.environment['LOCAL_S3_ENGINES'] ?? 'python,go,rust,java')
                .split(',')
                .map((value) => value.trim())
                .where((value) => value.isNotEmpty)
                .toSet()
                .toList(),
        repetitions = _number('LOCAL_S3_REPETITIONS', 3, 1, 20),
        transferMiB = _number('LOCAL_S3_TRANSFER_MIB', 256, 1, 4096),
        operations = _number('LOCAL_S3_OPERATIONS', 1024, 32, 100000),
        benchmarkConcurrency = _numbers('LOCAL_S3_BENCH_CONCURRENCY', '1,4,8'),
        transferConcurrency = _numbers('LOCAL_S3_TRANSFER_CONCURRENCY', '1,4'),
        listingSeedCount = _number('LOCAL_S3_LISTING_SEED_COUNT', 0, 0, 10000),
        pollMs = _number('LOCAL_S3_POLL_MS', 100, 10, 10000),
        timeout = Duration(
            seconds: _number('LOCAL_S3_CASE_TIMEOUT_SECONDS', 600, 10, 3600)) {
    final uri = Uri.parse(endpoint);
    _require(
        {'http', 'https'}.contains(uri.scheme) &&
            {'127.0.0.1', '::1', '[::1]', 'localhost'}.contains(uri.host) &&
            uri.hasPort &&
            uri.port > 0 &&
            uri.userInfo.isEmpty &&
            !uri.hasQuery &&
            !uri.hasFragment,
        'The performance endpoint must be an explicit loopback URL without credentials or query parameters.');
    _require(engines.isNotEmpty, 'Select at least one desktop engine.');
    _require(engines.every({'python', 'go', 'rust', 'java'}.contains),
        'Only the four desktop engine IDs are accepted.');
    _require(File('$engineRoot/manifest.json').existsSync(),
        'LOCAL_S3_ENGINE_ROOT must contain the real desktop engine manifest.');
  }

  final String endpoint, accessKey, secretKey, bucket, engineRoot;
  final Directory output;
  final List<String> engines;
  final int repetitions, transferMiB, operations, listingSeedCount, pollMs;
  final List<int> benchmarkConcurrency, transferConcurrency;
  final Duration timeout;

  EndpointProfile profile(int concurrency) => EndpointProfile(
        id: 'local-s3-performance-only',
        name: 'Disposable local S3 performance fixture',
        endpointUrl: endpoint,
        region: 'us-east-1',
        accessKey: accessKey,
        secretKey: secretKey,
        pathStyle: true,
        verifyTls: true,
        maxConcurrentRequests: concurrency,
        maxAttempts: 3,
        readTimeoutSeconds: 120,
      );

  static String _required(String name) {
    final value = Platform.environment[name];
    if (value == null || value.isEmpty) throw StateError('Set $name.');
    return value;
  }

  static int _number(String name, int fallback, int minimum, int maximum) {
    final raw = Platform.environment[name];
    final value = raw == null ? fallback : int.tryParse(raw);
    if (value == null || value < minimum || value > maximum) {
      throw StateError('$name must be between $minimum and $maximum.');
    }
    return value;
  }

  static List<int> _numbers(String name, String fallback) {
    final values = (Platform.environment[name] ?? fallback)
        .split(',')
        .map((item) => int.tryParse(item.trim()))
        .toList();
    if (values.isEmpty ||
        values.any((value) => value == null || value < 1 || value > 32)) {
      throw StateError('$name must contain concurrency values from 1 to 32.');
    }
    return values.cast<int>().toSet().toList();
  }
}

void _require(bool condition, String message) {
  if (!condition) throw StateError(message);
}

class _LocalS3Performance {
  _LocalS3Performance(this.config);
  final _Configuration config;
  final String runId =
      'app-perf-${DateTime.now().toUtc().microsecondsSinceEpoch}-${Random.secure().nextInt(1 << 32).toRadixString(16)}';
  final List<String> failures = [];
  final Map<String, List<CapabilityDescriptor>> capabilities = {};
  final Map<String, String> engineVersions = {};
  late DesktopSidecarEngineService service;
  late Directory scratch;
  late File source;
  late String sourceSha256;
  late IOSink rows;
  int _caseSequence = 0;

  DesktopSidecarEngineService _newService() => DesktopSidecarEngineService(
        engineRoot: config.engineRoot,
        host: DesktopEngineHost(
          maxProcesses: 4,
          maxProcessesPerEngine: 1,
          requestTimeout: config.timeout,
          queueTimeout: config.timeout,
        ),
        // Supplying a fallback would enable simulated results. Never do that.
      );

  Future<void> run() async {
    await config.output.create(recursive: true);
    rows = File('${config.output.path}/app-service-results.jsonl')
        .openWrite(mode: FileMode.append);
    scratch = await Directory.systemTemp.createTemp('object-browser-s3-perf-');
    service = _newService();
    try {
      _require(!service.isMock, 'A real desktop service is required.');
      await _row({
        'recordType': 'run',
        'status': 'started',
        'endpoint': config.endpoint,
        'bucket': config.bucket,
        'engineRoot': config.engineRoot,
        'requestedEngines': config.engines,
        'repetitions': config.repetitions,
        'operations': config.operations,
        'transferMiB': config.transferMiB,
        'benchmarkConcurrency': config.benchmarkConcurrency,
        'transferConcurrency': config.transferConcurrency,
        'pollMs': config.pollMs,
        'listingSeedCount': config.listingSeedCount,
        'os': Platform.operatingSystem,
        'osVersion': Platform.operatingSystemVersion,
        'dartVersion': Platform.version,
        'processorCount': Platform.numberOfProcessors,
        'timing':
            'monotonic app-service wall time; includes RPC and polling, excludes file generation and SHA256 verification',
      });
      final descriptors = await service.listEngines();
      final available = <String>[];
      for (final id in config.engines) {
        final descriptor =
            descriptors.where((engine) => engine.id == id).firstOrNull;
        if (descriptor == null || !descriptor.available) {
          failures.add('$id: requested engine is unavailable.');
          await _row({
            'recordType': 'availability',
            'engine': id,
            'status': 'unavailable',
          });
          continue;
        }
        engineVersions[id] = descriptor.version;
        final ready = await _attempt(id, 'warmup', 0, 1, () async {
          await service.testProfile(engineId: id, profile: config.profile(1));
          final buckets = await service.listBuckets(
              engineId: id, profile: config.profile(1));
          _require(buckets.any((bucket) => bucket.name == config.bucket),
              'The actual endpoint did not list the runner-created bucket.');
          capabilities[id] = await service.getCapabilities(
              engineId: id, profile: config.profile(1));
          final empty = await service.listObjects(
              engineId: id,
              profile: config.profile(1),
              bucketName: config.bucket,
              prefix: '$runId/not-created/',
              flat: true);
          _require(empty.items.isEmpty && !empty.cursor.hasMore,
              'A fresh random prefix was not empty; fixture isolation failed.');
        });
        if (ready) available.add(id);
      }
      _require(
          available.isNotEmpty, 'No real engine could connect to local S3.');

      source = File('${scratch.path}/roundtrip.bin');
      await _writeFixture(source, config.transferMiB * 1024 * 1024);
      sourceSha256 = await _sha256(source);
      await _row({
        'recordType': 'fixture',
        'bytes': await source.length(),
        'sha256': sourceSha256,
        'payload': 'deterministic 1MiB pseudo-random blocks with a block index',
      });
      if (config.listingSeedCount > 0) {
        final seedEngine =
            available.contains('python') ? 'python' : available.first;
        await _attempt(seedEngine, 'seed_listing', 0, 4, () async {
          final profile = config.profile(4);
          final seeded = await service.runPutTestData(
              engineId: seedEngine,
              profile: profile,
              config: TestDataToolConfig(
                bucketName: config.bucket,
                endpointUrl: config.endpoint,
                accessKey: config.accessKey,
                secretKey: config.secretKey,
                objectSizeBytes: 128,
                versions: 1,
                objectCount: config.listingSeedCount,
                prefix: '$runId/listing/',
                threads: 4,
                checksumAlgorithm: 'none',
              ));
          _require(seeded.exitCode == 0 && !seeded.running,
              'The listing fixture did not finish successfully.');
        });
      }

      // Rotate engine order between repetitions to reduce order/thermal bias.
      for (var repetition = 1; repetition <= config.repetitions; repetition++) {
        final offset = (repetition - 1) % available.length;
        final order = [...available.skip(offset), ...available.take(offset)];
        for (final engine in order) {
          await _attempt(engine, 'listing', repetition, 1,
              () => _listing(engine, repetition));
          final supportsBenchmark = capabilities[engine]!.any((capability) =>
              capability.key == 'benchmark' &&
              capability.state == CapabilityState.supported);
          for (final concurrency in config.benchmarkConcurrency) {
            if (!supportsBenchmark) {
              await _row({
                'recordType': 'measurement',
                'engine': engine,
                'case': 'put_64k',
                'repetition': repetition,
                'concurrency': concurrency,
                'status': 'unsupported',
              });
              continue;
            }
            await _attempt(engine, 'put_64k', repetition, concurrency,
                () => _benchmark(engine, repetition, concurrency));
          }
          for (final concurrency in config.transferConcurrency) {
            await _attempt(engine, 'multipart_roundtrip', repetition,
                concurrency, () => _roundtrip(engine, repetition, concurrency));
          }
        }
      }
      await _row({
        'recordType': 'run',
        'status': failures.isEmpty ? 'completed' : 'failed',
        'failureCount': failures.length,
        'failures': failures,
      });
      expect(failures, isEmpty,
          reason: 'See ${config.output.path}/app-service-results.jsonl');
    } finally {
      service.shutdown();
      await rows.flush();
      await rows.close();
      await scratch.delete(recursive: true);
    }
  }

  Future<bool> _attempt(String engine, String label, int repetition,
      int concurrency, Future<void> Function() work) async {
    try {
      await work().timeout(config.timeout);
      return true;
    } catch (error) {
      final message = _redact(error.toString());
      failures.add(
          '$engine $label repetition=$repetition concurrency=$concurrency: $message');
      await _row({
        'recordType': 'case_failure',
        'engine': engine,
        'case': label,
        'repetition': repetition,
        'concurrency': concurrency,
        'status': 'failed',
        'error': message,
      });
      // A timed-out sidecar may still have a request in flight. Terminate it
      // before the next measurement; never overlap or substitute a mock.
      service.shutdown();
      service = _newService();
      return false;
    }
  }

  Future<T> _measure<T>(
      String engine,
      String label,
      int repetition,
      int concurrency,
      Future<T> Function() work,
      Map<String, Object?> Function(T) describe) async {
    final caseId = '$runId-${++_caseSequence}';
    final fields = <String, Object?>{
      'engine': engine,
      'engineVersion': engineVersions[engine],
      'case': label,
      'caseId': caseId,
      'repetition': repetition,
      'concurrency': concurrency,
    };
    await _row({...fields, 'recordType': 'event', 'status': 'started'});
    final startedAt = DateTime.now().toUtc();
    final stopwatch = Stopwatch()..start();
    try {
      final result = await work();
      stopwatch.stop();
      final completedAt = DateTime.now().toUtc();
      final details = describe(result);
      final seconds = stopwatch.elapsedMicroseconds / 1000000;
      final bytes = (details['bytes'] as num?)?.toDouble();
      final operations = (details['operations'] as num?)?.toDouble();
      await _row({
        ...fields,
        'recordType': 'measurement',
        'status': 'completed',
        'startedAt': startedAt.toIso8601String(),
        'finishedAt': completedAt.toIso8601String(),
        'completedAt': completedAt.toIso8601String(),
        'elapsedMs': stopwatch.elapsedMicroseconds / 1000,
        if (bytes != null) 'miBPerSecond': bytes / (1024 * 1024) / seconds,
        if (operations != null) 'wallOpsPerSecond': operations / seconds,
        ...details,
      });
      return result;
    } catch (error) {
      stopwatch.stop();
      final completedAt = DateTime.now().toUtc();
      await _row({
        ...fields,
        'recordType': 'measurement',
        'status': 'failed',
        'startedAt': startedAt.toIso8601String(),
        'finishedAt': completedAt.toIso8601String(),
        'completedAt': completedAt.toIso8601String(),
        'elapsedMs': stopwatch.elapsedMicroseconds / 1000,
        'error': _redact(error.toString()),
      });
      rethrow;
    }
  }

  Future<void> _listing(String engine, int repetition) async {
    final currentService = service;
    await _measure(
        engine,
        'list_buckets',
        repetition,
        1,
        () => currentService.listBuckets(
            engineId: engine, profile: config.profile(1)), (buckets) {
      _require(buckets.any((bucket) => bucket.name == config.bucket),
          'The fixture bucket disappeared from the real listing.');
      return {'bucketCount': buckets.length, 'operations': 1};
    });
    await _measure(engine, 'list_objects', repetition, 1, () async {
      ListCursor? cursor;
      final keys = <String>{};
      final seen = <String>{};
      var pages = 0;
      do {
        final page = await currentService.listObjects(
            engineId: engine,
            profile: config.profile(1),
            bucketName: config.bucket,
            prefix: '$runId/listing/',
            flat: true,
            cursor: cursor);
        pages++;
        for (final item in page.items) {
          _require(keys.add(item.key), 'Listing repeated an object key.');
        }
        cursor = page.cursor;
        if (cursor.hasMore) {
          _require(cursor.value != null && seen.add(cursor.value!),
              'Listing returned a missing or repeated cursor.');
        }
      } while (cursor.hasMore);
      _require(keys.length == config.listingSeedCount,
          'Expected ${config.listingSeedCount} seeded keys, got ${keys.length}.');
      if (config.listingSeedCount > 1000) {
        _require(
            pages > 1, 'The pagination fixture did not span multiple pages.');
      }
      return {'objectCount': keys.length, 'pages': pages, 'operations': pages};
    }, (details) => details);
  }

  Future<void> _benchmark(
      String engine, int repetition, int concurrency) async {
    final currentService = service;
    final profile = config.profile(concurrency);
    // Warm the actual process, SDK client, and endpoint before timing.
    await currentService.listObjects(
        engineId: engine,
        profile: profile,
        bucketName: config.bucket,
        prefix: '$runId/warmup/',
        flat: true);
    final artifactPrefix =
        '${config.output.path}/$engine-r$repetition-c$concurrency';
    final benchmark = BenchmarkConfig(
      profileId: profile.id,
      engineId: engine,
      bucketName: config.bucket,
      prefix: '$runId/benchmark/$engine/r$repetition/c$concurrency/',
      workloadType: 'write-only',
      deleteMode: 'single',
      objectSizes: const [64 * 1024],
      concurrentThreads: concurrency,
      testMode: 'operation-count',
      operationCount: config.operations,
      durationSeconds: config.timeout.inSeconds,
      validateChecksum: true,
      checksumAlgorithm: 'sha256',
      randomData: false,
      inMemoryData: true,
      objectCount: config.operations,
      connectTimeoutSeconds: profile.connectTimeoutSeconds,
      readTimeoutSeconds: profile.readTimeoutSeconds,
      maxAttempts: profile.maxAttempts,
      maxPoolConnections: concurrency,
      dataCacheMb: 64,
      csvOutputPath: '$artifactPrefix.csv',
      jsonOutputPath: '$artifactPrefix.json',
      logFilePath: '$artifactPrefix.log',
      debugMode: false,
      reducedLogging: true,
    );
    BenchmarkRun? active;
    var polls = 0;
    try {
      await _measure(engine, 'put_64k', repetition, concurrency, () async {
        var run = await currentService.startBenchmark(
            config: benchmark, profile: profile);
        active = run;
        _require(run.config.engineId == engine,
            'The benchmark response changed engine identity.');
        final deadline = Stopwatch()..start();
        while (!{'completed', 'failed', 'stopped', 'cancelled', 'interrupted'}
            .contains(run.status)) {
          _require(deadline.elapsed < config.timeout,
              'Benchmark deadline exceeded.');
          await Future<void>.delayed(Duration(milliseconds: config.pollMs));
          run = await currentService.getBenchmarkStatus(run.id);
          active = run;
          polls++;
        }
        _require(
            run.status == 'completed', 'Benchmark ended as ${run.status}.');
        final summary = run.resultSummary;
        _require(
            summary != null && summary.totalOperations == config.operations,
            'Benchmark did not execute the requested operation count.');
        _require(
            summary!.operationsByType['PUT'] == config.operations &&
                summary.operationsByType.entries
                    .every((entry) => entry.key == 'PUT' || entry.value == 0),
            'The write-only benchmark performed other operations.');
        _require((summary.checksumStats['validated_failure'] ?? 0) == 0,
            'The benchmark reported checksum failures.');
        return run;
      }, (run) {
        final summary = run.resultSummary!;
        return {
          'bytes': summary.totalOperations * 64 * 1024,
          'operations': summary.totalOperations,
          'processedCount': run.processedCount,
          'objectBytes': 64 * 1024,
          'pollCount': polls,
          'pollIntervalMs': config.pollMs,
          'engineActiveElapsedSeconds': run.activeElapsedSeconds,
          'engineReportedOpsPerSecond': run.throughputOpsPerSecond,
          'summary': _summary(summary),
          'checksumScope':
              'PUT benchmark counters; independent SHA256 validation is performed by the multipart roundtrip cases',
        };
      });
      // Verify committed server objects independently of benchmark counters.
      // These paginated reads are deliberately outside the timed PUT window.
      final verification = Stopwatch()..start();
      ListCursor? cursor;
      final keys = <String>{};
      final cursors = <String>{};
      var observedBytes = 0;
      var pages = 0;
      do {
        final page = await currentService.listObjects(
            engineId: engine,
            profile: profile,
            bucketName: config.bucket,
            prefix: benchmark.prefix,
            flat: true,
            cursor: cursor);
        pages++;
        for (final item in page.items) {
          _require(item.key.startsWith(benchmark.prefix),
              'Benchmark verification returned a key outside its prefix.');
          _require(keys.add(item.key),
              'Benchmark verification repeated an object key.');
          _require(item.size == 64 * 1024,
              'A committed benchmark object is not exactly 64 KiB.');
          observedBytes += item.size;
        }
        cursor = page.cursor;
        if (cursor.hasMore) {
          _require(cursor.value != null && cursors.add(cursor.value!),
              'Benchmark verification received a missing or repeated cursor.');
        }
      } while (cursor.hasMore);
      verification.stop();
      _require(keys.length == config.operations,
          'Expected ${config.operations} committed benchmark objects, got ${keys.length}.');
      await _row({
        'recordType': 'verification',
        'engine': engine,
        'case': 'put_64k',
        'repetition': repetition,
        'concurrency': concurrency,
        'status': 'completed',
        'observedObjectCount': keys.length,
        'observedBytes': observedBytes,
        'pages': pages,
        'verificationElapsedMs': verification.elapsedMicroseconds / 1000,
        'outsideTimedWindow': true,
      });
    } finally {
      if (active != null &&
          !{'completed', 'failed', 'stopped', 'cancelled', 'interrupted'}
              .contains(active!.status)) {
        try {
          await currentService.stopBenchmark(active!.id);
        } catch (_) {
          // _attempt disposes the host on failure before the next case.
        }
      }
    }
  }

  Future<void> _roundtrip(
      String engine, int repetition, int concurrency) async {
    final currentService = service;
    final profile = config.profile(concurrency);
    final key =
        '$runId/transfers/$engine/r$repetition/c$concurrency/roundtrip.bin';
    final destination =
        Directory('${scratch.path}/$engine-r$repetition-c$concurrency');
    await destination.create();
    final expectedBytes = config.transferMiB * 1024 * 1024;
    try {
      await currentService.listObjects(
          engineId: engine,
          profile: profile,
          bucketName: config.bucket,
          prefix: '$runId/warmup/',
          flat: true);
      await _measure(
          engine,
          'multipart_upload',
          repetition,
          concurrency,
          () => currentService.startUpload(
                engineId: engine,
                profile: profile,
                bucketName: config.bucket,
                prefix: '',
                filePaths: [source.path],
                objectKeyByPath: {source.path: key},
                multipartThresholdMiB: 8,
                multipartChunkMiB: 8,
              ),
          (job) => _transfer(job, expectedBytes));
      final listed = await currentService.listObjects(
          engineId: engine,
          profile: profile,
          bucketName: config.bucket,
          prefix: key,
          flat: true);
      _require(
          listed.items
              .any((item) => item.key == key && item.size == expectedBytes),
          'The uploaded bytes did not appear under the exact expected key.');
      await _measure(
          engine,
          'multipart_download',
          repetition,
          concurrency,
          () => currentService.startDownload(
                engineId: engine,
                profile: profile,
                bucketName: config.bucket,
                keys: [key],
                destinationPath: destination.path,
                conflictPolicy: 'replace',
                multipartThresholdMiB: 8,
                multipartChunkMiB: 8,
              ),
          (job) => _transfer(job, expectedBytes));
      final downloaded = File('${destination.path}/roundtrip.bin');
      _require(await downloaded.exists(), 'The download was not published.');
      _require(await downloaded.length() == expectedBytes,
          'The published download size differs from the source.');
      final downloadedSha256 = await _sha256(downloaded);
      _require(downloadedSha256 == sourceSha256,
          'SHA256 mismatch between the actual uploaded and downloaded file.');
      await _row({
        'recordType': 'verification',
        'engine': engine,
        'case': 'multipart_roundtrip',
        'repetition': repetition,
        'concurrency': concurrency,
        'status': 'completed',
        'bytes': expectedBytes,
        'sourceSha256': sourceSha256,
        'downloadedSha256': downloadedSha256,
      });
      final deleted = await currentService.deleteObjects(
          engineId: engine,
          profile: profile,
          bucketName: config.bucket,
          keys: [key]);
      _require(deleted.failureCount == 0 && deleted.successCount == 1,
          'Cleanup of this fixture object failed.');
    } finally {
      if (await destination.exists()) await destination.delete(recursive: true);
    }
  }

  Map<String, Object?> _transfer(TransferJob job, int expectedBytes) {
    _require(
        job.status == 'completed' &&
            job.bytesTransferred == expectedBytes &&
            job.totalBytes == expectedBytes,
        'A transfer did not report completion of the exact byte count.');
    return {
      'bytes': expectedBytes,
      'jobStatus': job.status,
      'partBytes': job.partSizeBytes,
      'partsCompleted': job.partsCompleted,
      'partsTotal': job.partsTotal,
      'strategy': job.strategyLabel,
    };
  }

  Map<String, Object?> _summary(BenchmarkResultSummary summary) => {
        'totalOperations': summary.totalOperations,
        'operationsByType': summary.operationsByType,
        'latencyPercentilesMs': summary.latencyPercentilesMs,
        'latencyPercentilesByOperationMs':
            summary.latencyPercentilesByOperationMs,
        'throughputSeries': summary.throughputSeries,
        'sizeLatencyBuckets': summary.sizeLatencyBuckets,
        'checksumStats': summary.checksumStats,
        'detailMetrics': summary.detailMetrics,
        'operationDetails': summary.operationDetails,
        'latencyTimeline': summary.latencyTimeline,
      };

  Future<void> _row(Map<String, Object?> fields) async {
    final row = {
      'schemaVersion': 1,
      'runId': runId,
      'timestamp': DateTime.now().toUtc().toIso8601String(),
      'adapter': 'DesktopSidecarEngineService',
      ...fields,
    };
    final encoded = jsonEncode(row);
    _require(
        !encoded.contains(config.secretKey) &&
            !encoded.contains(config.accessKey),
        'Refusing to write credentials into performance output.');
    rows.writeln(encoded);
    await rows.flush();
    // Small timestamped events let the launcher correlate resource samples.
    stdout.writeln('LOCAL_S3_PERF ${jsonEncode({
          'timestamp': row['timestamp'],
          'runId': runId,
          for (final field in [
            'recordType',
            'engine',
            'case',
            'caseId',
            'repetition',
            'concurrency',
            'status',
            'elapsedMs'
          ])
            if (row.containsKey(field)) field: row[field],
        })}');
  }

  String _redact(String message) => message
      .replaceAll(config.secretKey, '[redacted]')
      .replaceAll(config.accessKey, '[redacted]');
}

Future<void> _writeFixture(File file, int size) async {
  final block = Uint8List(1024 * 1024);
  var value = 0x6a09e667;
  for (var index = 0; index < block.length; index++) {
    value ^= (value << 13) & 0xffffffff;
    value ^= value >> 17;
    value ^= (value << 5) & 0xffffffff;
    block[index] = value & 0xff;
  }
  final output = await file.open(mode: FileMode.write);
  try {
    final header = ByteData.sublistView(block);
    for (var written = 0; written < size; written += block.length) {
      header.setUint32(0, written ~/ block.length, Endian.little);
      await output.writeFrom(block, 0, min(block.length, size - written));
    }
    await output.flush();
  } finally {
    await output.close();
  }
}

Future<String> _sha256(File file) async {
  final ProcessResult result;
  if (Platform.isWindows) {
    result = await Process.run('powershell', [
      '-NoProfile',
      '-NonInteractive',
      '-Command',
      r'(Get-FileHash -Algorithm SHA256 -LiteralPath $env:LOCAL_S3_CHECKSUM_PATH).Hash',
    ], environment: {
      'LOCAL_S3_CHECKSUM_PATH': file.path
    });
  } else if (Platform.isMacOS) {
    result = await Process.run('/usr/bin/shasum', ['-a', '256', file.path]);
  } else {
    result = await Process.run('sha256sum', [file.path]);
  }
  _require(result.exitCode == 0, 'The platform SHA256 utility failed.');
  final digest =
      result.stdout.toString().trim().split(RegExp(r'\s+')).first.toLowerCase();
  _require(RegExp(r'^[a-f0-9]{64}$').hasMatch(digest),
      'The platform checksum utility did not return a SHA256 digest.');
  return digest;
}
