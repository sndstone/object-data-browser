import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:path_provider/path_provider.dart';
import 'package:xml/xml.dart';

import '../controllers/action_scope.dart';
import '../models/domain_models.dart';
import 'listing_cancellation.dart';
import 'storage_http_client.dart';

/// The mobile benchmark runs actual provider requests independently of polling.
/// Checkpoints contain metadata and measurements; endpoint credentials stay in memory.
class MobileBenchmarkService {
  MobileBenchmarkService(
      {Directory? checkpointDirectory,
      StorageHttpClient Function(EndpointProfile)? clientFactory})
      : _directory = checkpointDirectory,
        _clientFactory = clientFactory ?? StorageHttpClient.new;

  static const methods = <String>{
    'startBenchmark',
    'getBenchmarkStatus',
    'pauseBenchmark',
    'resumeBenchmark',
    'stopBenchmark',
    'cancelBenchmark',
    'exportBenchmarkResults',
    'listBenchmarkRuns',
    'resumeBenchmarkRun',
    'discardBenchmarkRun'
  };
  static const historyLimit = 10000;
  final StorageHttpClient Function(EndpointProfile) _clientFactory;
  Directory? _directory;
  final Map<String, _Run> _runs = {};
  bool _closed = false;
  int _starting = 0;

  Future<Directory> _root() async {
    final directory = _directory ??= Directory(
        '${(await getApplicationSupportDirectory()).path}/mobile-benchmarks');
    await directory.create(recursive: true);
    return directory;
  }

  Future<Map<String, Object?>> dispatch(String method,
      {required EndpointProfile profile,
      Map<String, Object?> params = const {}}) async {
    if (_closed) _invalid('The mobile benchmark service is closed.');
    if (method == 'listBenchmarkRuns') {
      final items = <Map<String, Object?>>[];
      await for (final entry in (await _root()).list()) {
        if (items.length >= 100) break;
        if (entry is! File || !entry.path.endsWith('.json')) continue;
        try {
          final state = Map<String, Object?>.from(
              jsonDecode(await entry.readAsString()) as Map);
          if (state['owner'] != _owner(profile)) continue;
          items.add({
            for (final key in [
              'id',
              'profileId',
              'status',
              'startedAt',
              'completedAt',
              'processedCount',
              'config'
            ])
              key: state[key]
          });
        } on FormatException {
          continue;
        }
      }
      return {'items': items};
    }
    if (method == 'startBenchmark') return _newRun(profile, params);
    final id = '${params['runId'] ?? params['id'] ?? ''}';
    final run = await _load(id, profile);
    switch (method) {
      case 'getBenchmarkStatus':
        if (run.status != 'running') await run.worker;
        return _snapshot(run);
      case 'pauseBenchmark':
        if (run.status == 'running') {
          run.status = 'paused';
          run.log('Benchmark paused by user.');
          await run.worker;
          await _save(run);
        }
        return _snapshot(run);
      case 'resumeBenchmark':
      case 'resumeBenchmarkRun':
        if (run.status == 'paused') {
          await run.worker;
          _start(run, profile);
        }
        return _snapshot(run);
      case 'stopBenchmark':
      case 'cancelBenchmark':
        if (run.status == 'running' || run.status == 'paused') {
          run.status = 'stopped';
          run.scope?.cancel();
          await run.worker;
          run.completedAt = DateTime.now().toUtc().toIso8601String();
          run.log('Benchmark stopped by user.');
          await _save(run);
        }
        return _snapshot(run);
      case 'discardBenchmarkRun':
        if (run.status == 'running') {
          _invalid('Stop the benchmark before discarding its checkpoint.');
        }
        await run.worker;
        await File('${(await _root()).path}/$id.json').delete();
        _runs.remove(id);
        return {'discarded': true, 'remoteObjectsDeleted': false};
      case 'exportBenchmarkResults':
        await _save(run);
        final format = '${params['format'] ?? 'csv'}';
        if (!{'csv', 'json'}.contains(format)) {
          _invalid('Choose CSV or JSON export.');
        }
        return {
          'format': format,
          'path':
              run.config[format == 'csv' ? 'csvOutputPath' : 'jsonOutputPath'],
          'summary': _summary(run)
        };
      default:
        _invalid('Unknown benchmark method.');
    }
  }

  Future<Map<String, Object?>> _newRun(
      EndpointProfile profile, Map<String, Object?> params) async {
    if (_runs.length + _starting >= 4) {
      _invalid(
          'Stop an existing benchmark before starting another (maximum four live runs).');
    }
    _starting++;
    try {
      final config = _config(
          Map<String, Object?>.from(params['config'] as Map? ?? const {}));
      config['profileId'] = profile.id;
      final id =
          'bench-mobile-${DateTime.now().microsecondsSinceEpoch}-${Random.secure().nextInt(1 << 32).toRadixString(16)}';
      final root = await _root();
      final outputs = Directory('${root.path}/$id');
      await outputs.create();
      for (final entry in {
        'csvOutputPath': 'results.csv',
        'jsonOutputPath': 'results.json',
        'logFilePath': 'benchmark.log'
      }.entries) {
        config[entry.key] = '${outputs.path}/${entry.value}';
      }
      final run = _Run(id, profile.id, _owner(profile), config);
      _runs[id] = run;
      try {
        await _save(run);
      } catch (_) {
        _runs.remove(id);
        throw const EngineException(
            code: ErrorCode.unknown,
            message: 'The benchmark checkpoint could not be saved.');
      }
      if (_closed) {
        _runs.remove(id);
        _invalid('The mobile benchmark service is closed.');
      }
      _start(run, profile);
      return _snapshot(run);
    } finally {
      _starting--;
    }
  }

  Future<_Run> _load(String id, EndpointProfile profile) async {
    if (!RegExp(r'^bench-mobile-[A-Za-z0-9-]+$').hasMatch(id)) {
      _invalid('A valid benchmark run ID is required.');
    }
    final existing = _runs[id];
    if (existing != null) {
      if (existing.owner != _owner(profile)) {
        _invalid('Use the endpoint that owns this benchmark.');
      }
      return existing;
    }
    final file = File('${(await _root()).path}/$id.json');
    if (!await file.exists()) _invalid('Benchmark checkpoint was not found.');
    final state =
        Map<String, Object?>.from(jsonDecode(await file.readAsString()) as Map);
    if (state['owner'] != _owner(profile)) {
      _invalid('Use the endpoint that owns this benchmark.');
    }
    final run = _Run.restore(state);
    if (run.status == 'running') {
      run.status = 'paused';
      run.log(
          'Resume with the owning endpoint credentials after restarting the app.');
    }
    return run;
  }

  void _start(_Run run, EndpointProfile profile) {
    if (_closed || run.worker != null) return;
    if (!_runs.containsKey(run.id) && _runs.length >= 4) {
      _invalid('Maximum four live benchmark runs.');
    }
    _runs[run.id] = run;
    run.status = 'running';
    // Construct in a fresh zone: cancelling the Start button's action must not
    // cancel the independently owned background benchmark.
    run.scope = Zone.root.run(() => ActionScope());
    run.clock.start();
    final tuned = profile.copyWith(
        connectTimeoutSeconds: _int(run.config, 'connectTimeoutSeconds', 5),
        readTimeoutSeconds: _int(run.config, 'readTimeoutSeconds', 60),
        maxAttempts: _int(run.config, 'maxAttempts', 5),
        maxConcurrentRequests: _int(run.config, 'maxPoolConnections', 10));
    run.worker = run.scope!.run(() => _work(run, tuned));
    unawaited(run.worker);
  }

  Future<void> _work(_Run run, EndpointProfile profile) async {
    StorageHttpClient? client;
    IOSink? csv;
    var lastPersist = 0.0;
    try {
      client = _clientFactory(profile);
      final output = File(run.config['csvOutputPath'] as String);
      final header = !await output.exists();
      csv = output.openWrite(mode: FileMode.append);
      if (header) {
        csv.writeln(
            'second,operation,operationCount,latencyMs,sizeBytes,bytesTransferred,success,checksumState,key,elapsedMs');
      }
      while (run.status == 'running') {
        if (_complete(run)) {
          run.status = 'completed';
          break;
        }
        final tasks = _plan(run);
        if (tasks.isEmpty) {
          run.status = 'completed';
          break;
        }
        final records = await Future.wait(
            tasks.map((task) => _execute(run, client!, task)));
        final completed = records.whereType<Map<String, Object?>>().toList()
          ..sort((a, b) =>
              (a['elapsedMs'] as double).compareTo(b['elapsedMs'] as double));
        for (final record in completed) {
          _record(run, record);
          final key = '"${(record['key'] as String).replaceAll('"', '""')}"';
          csv.writeln(
              '${record['second']},${record['operation']},${record['operationCount']},${record['latencyMs']},${record['sizeBytes']},${record['bytesTransferred']},true,${record['checksumState']},$key,${record['elapsedMs']}');
        }
        run.requests = run.baseRequests + client.requestCount;
        run.retries = run.baseRetries + client.retryCount;
        await csv.flush();
        if (run.elapsed - lastPersist >= 1) {
          if (run.config['debugMode'] == true) {
            run.log(
                'DEBUG ${run.processed} completed operations, ${run.requests} requests, ${run.retries} retries, ${run.cacheBytes} cached bytes.');
          }
          await _save(run);
          lastPersist = run.elapsed;
        }
        // Yield between batches so UI controls stay responsive on a fast LAN.
        await Future<void>.delayed(Duration.zero);
      }
    } on ListingCancelled {
      if (run.status == 'running') run.status = 'stopped';
    } catch (error) {
      run.errors++;
      run.status = 'failed';
      run.log(error is EngineException
          ? error.message
          : 'Benchmark failed (${error.runtimeType}).');
    } finally {
      run.clock.stop();
      if (client != null) {
        run.requests = run.baseRequests + client.requestCount;
        run.retries = run.baseRetries + client.retryCount;
        client.close();
      }
      try {
        await csv?.flush();
        await csv?.close();
      } catch (_) {
        run.errors++;
        run.status = 'failed';
        run.log('Benchmark CSV output could not be saved.');
      }
      run.baseRequests = run.requests;
      run.baseRetries = run.retries;
      run.cache.clear();
      run.cacheBytes = 0;
      if (run.status != 'paused') {
        run.completedAt = DateTime.now().toUtc().toIso8601String();
      }
      run.log('Benchmark ${run.status} after ${run.processed} operation(s).');
      var saved = false;
      try {
        await _save(run);
        saved = true;
      } catch (_) {
        run.errors++;
        run.status = 'failed';
        run.log(
            'Checkpoint persistence failed; these results are available for this session only.');
      } finally {
        run.worker = null;
        run.scope = null;
        if (saved) _runs.remove(run.id);
      }
    }
  }

  bool _complete(_Run run) => run.config['testMode'] == 'operation-count'
      ? run.processed >= _int(run.config, 'operationCount', 1000)
      : run.elapsed >= _int(run.config, 'durationSeconds', 60);

  List<_Task> _plan(_Run run) {
    final countMode = run.config['testMode'] == 'operation-count';
    var remaining = countMode
        ? _int(run.config, 'operationCount', 1000) - run.processed
        : 1 << 30;
    final workers = min(_int(run.config, 'concurrentThreads', 1),
        _int(run.config, 'maxPoolConnections', 10));
    final reserved = <String>{};
    final tasks = <_Task>[];
    final sizes = (run.config['objectSizes'] as List).cast<int>();
    var plannedObjects = run.objects.length;
    for (var i = 0; i < workers && remaining > 0; i++) {
      var operation = _operation(run.config,
          run.processed + tasks.fold<int>(0, (n, t) => n + t.keys.length));
      final available =
          run.objects.keys.where((k) => !reserved.contains(k)).toList();
      if (available.isEmpty && operation != 'PUT') {
        if (plannedObjects >= _int(run.config, 'objectCount', 100)) break;
        operation = 'PUT';
      }
      final size = sizes[run.nextSize++ % sizes.length];
      if (operation == 'PUT') {
        String key;
        if (plannedObjects < _int(run.config, 'objectCount', 100)) {
          key = '${run.prefix}obj-${run.nextObject++}-$size.bin';
          plannedObjects++;
        } else {
          if (available.isEmpty) break;
          key = available[run.nextActive++ % available.length];
        }
        reserved.add(key);
        tasks.add(_Task('PUT', [key], size));
        remaining--;
      } else {
        final batch = operation == 'DELETE' &&
                run.config['deleteMode'] == 'multi-object-post'
            ? min(min(1000, remaining), available.length)
            : 1;
        final selected = <String>[];
        for (var j = 0; j < batch; j++) {
          selected.add(available[(run.nextActive + j) % available.length]);
        }
        run.nextActive += batch;
        reserved.addAll(selected);
        tasks.add(_Task(operation, selected,
            _int(run.objects[selected.first]!, 'sizeBytes', size)));
        remaining -= batch;
      }
    }
    return tasks;
  }

  Future<Map<String, Object?>?> _execute(
      _Run run, StorageHttpClient client, _Task task) async {
    final timer = Stopwatch()..start();
    var bytes = 0, count = 1;
    var checksumState = 'not_used';
    String? actualChecksum;
    final key = task.keys.first, bucket = run.config['bucketName'] as String;
    try {
      if (task.operation == 'PUT') {
        final payload = await _payload(run, key, task.size);
        try {
          final response = await client.requestStream('PUT', bucket,
              key: key,
              headers: {
                'content-type': 'application/octet-stream',
                if (client.azure) 'x-ms-blob-type': 'BlockBlob'
              },
              body: payload.open,
              bodyLength: task.size,
              payloadSha256: payload.sha256Hash,
              retrySafe: true);
          run.objects[key] = {
            'sizeBytes': task.size,
            'checksum': payload.checksum,
            if (response.headers['etag'] != null)
              'etag': response.headers['etag']
          };
          bytes = task.size;
        } finally {
          await payload.disposeFile();
        }
      } else if (task.operation == 'GET') {
        final target = run.objects[key]!;
        _DigestSink? sink;
        ByteConversionSink? hash;
        await client.requestStream('GET', bucket,
            key: key,
            headers: {
              if (target['etag'] != null) 'if-match': '${target['etag']}'
            },
            maxResponseBytes: task.size + 1, onResponseStart: () {
          bytes = 0;
          if (run.config['validateChecksum'] != false) {
            sink = _DigestSink();
            hash = _hash(run.config).startChunkedConversion(sink!);
          }
        }, onResponseChunk: (chunk) {
          bytes += chunk.length;
          hash?.add(chunk);
        });
        hash?.close();
        if (run.config['validateChecksum'] != false) {
          actualChecksum = sink!.value.toString();
          final valid =
              bytes == task.size && actualChecksum == target['checksum'];
          checksumState = valid ? 'validated_success' : 'validated_failure';
          if (!valid) run.errors++;
        }
      } else if (task.keys.length > 1 && !client.azure) {
        final xml = XmlBuilder();
        xml.element('Delete', nest: () {
          for (final name in task.keys) {
            xml.element('Object', nest: () {
              xml.element('Key', nest: name);
            });
          }
          xml.element('Quiet', nest: 'false');
        });
        final body = utf8.encode(xml.buildDocument().toXmlString());
        final response = await client.request('POST', bucket,
            query: {'delete': ''},
            body: body,
            headers: {'content-md5': base64Encode(md5.convert(body).bytes)},
            retrySafe: true);
        final failures = response.xml.findElements('Error').toList();
        final deleted = response.xml
            .findElements('Deleted')
            .map((e) => e.getElement('Key')?.innerText)
            .whereType<String>()
            .toSet();
        if (deleted.any((name) => !task.keys.contains(name))) {
          throw const EngineException(
              code: ErrorCode.unknown,
              message: 'Benchmark deletion returned an unexpected object key.');
        }
        for (final name in deleted) {
          run.objects.remove(name);
        }
        if (failures.isNotEmpty || deleted.length != task.keys.length) {
          run.errors++;
          run.status = 'failed';
          run.log('Benchmark batch deletion returned an incomplete result.');
          if (deleted.isEmpty) return null;
        }
        count = deleted.length;
      } else {
        // Azure REST has no native S3-style DeleteObjects API; count each actual DELETE.
        count = 0;
        for (final name in task.keys) {
          try {
            await client.request('DELETE', bucket, key: name, retrySafe: true);
          } on ListingCancelled {
            if (count == 0) return null;
            break;
          } catch (error) {
            run.errors++;
            run.status = 'failed';
            run.log(error is EngineException
                ? error.message
                : 'Benchmark deletion failed.');
            if (count == 0) return null;
            break;
          }
          run.objects.remove(name);
          count++;
        }
      }
      timer.stop();
      return {
        'timestamp': DateTime.now().toUtc().toIso8601String(),
        'second': run.elapsed.floor() + 1,
        'elapsedMs': run.elapsed * 1000,
        'operation': task.operation,
        'key': task.keys.length == 1
            ? key
            : '$key (+${task.keys.length - 1} more)',
        'sizeBytes': task.operation == 'DELETE' ? 0 : task.size,
        'latencyMs': timer.elapsedMicroseconds / 1000,
        'bytesTransferred': bytes,
        'success': true,
        'checksumState': checksumState,
        'checksum': actualChecksum,
        'checksumAlgorithm': run.config['checksumAlgorithm'],
        'operationCount': count
      };
    } on ListingCancelled {
      return null;
    } catch (error) {
      run.errors++;
      run.status = 'failed';
      run.log(error is EngineException
          ? error.message
          : 'Request failed (${error.runtimeType}).');
      return null;
    }
  }

  Future<_Payload> _payload(_Run run, String key, int size) async {
    final identity = '${run.config['randomData'] != false ? key : ''}:$size';
    final hit = run.cache.remove(identity);
    if (hit != null) {
      run.cache[identity] = hit;
      return hit;
    }
    final budget = _int(run.config, 'dataCacheMb', 64) * 1024 * 1024;
    final workers = min(_int(run.config, 'concurrentThreads', 1),
        _int(run.config, 'maxPoolConnections', 10));
    final memory = run.config['inMemoryData'] != false &&
        size <= max(256 * 1024, budget ~/ workers);
    final payload = _Payload();
    final seed = utf8.encode('${run.id}:$key:$size');
    final pattern = run.config['randomData'] == false
        ? Uint8List.fromList([65])
        : Uint8List.fromList(List.generate((seed.length * 8).clamp(64, 4096),
            (i) => (seed[i % seed.length] + i * 17) & 255));
    final shaSink = _DigestSink(), checksumSink = _DigestSink();
    final sha = sha256.startChunkedConversion(shaSink),
        checksum = _hash(run.config).startChunkedConversion(checksumSink);
    IOSink? file;
    try {
      if (memory) {
        payload.bytes = Uint8List(size);
      } else {
        payload.file = File(
            '${(await _root()).path}/payload-${run.id}-${run.nextPayload++}.tmp');
        file = payload.file!.openWrite();
      }
      for (var offset = 0; offset < size; offset += 256 * 1024) {
        run.scope?.check();
        final length = min(256 * 1024, size - offset);
        final chunk = memory
            ? Uint8List.sublistView(payload.bytes!, offset, offset + length)
            : Uint8List(length);
        var filled = 0;
        while (filled < length) {
          final start = (offset + filled) % pattern.length,
              amount = min(length - filled, pattern.length - start);
          chunk.setRange(filled, filled + amount, pattern, start);
          filled += amount;
        }
        sha.add(chunk);
        checksum.add(chunk);
        file?.add(chunk);
        if (file != null) await file.flush();
        await Future<void>.delayed(Duration.zero);
      }
      await file?.close();
      file = null;
      sha.close();
      checksum.close();
      payload.sha256Hash = shaSink.value.toString();
      payload.checksum = checksumSink.value.toString();
      if (memory && size <= budget) {
        while (run.cacheBytes + size > budget && run.cache.isNotEmpty) {
          final removed = run.cache.remove(run.cache.keys.first)!;
          run.cacheBytes -= removed.bytes!.length;
        }
        run.cache[identity] = payload;
        run.cacheBytes += size;
      }
      return payload;
    } catch (_) {
      await file?.close();
      await payload.disposeFile();
      rethrow;
    }
  }

  void _record(_Run run, Map<String, Object?> record) {
    final count = record['operationCount'] as int,
        operation = record['operation'] as String;
    run.processed += count;
    run.recordCount++;
    run.totalBytes += record['bytesTransferred'] as int;
    run.totalLatency += (record['latencyMs'] as num).toDouble();
    run.operations.update(operation, (n) => n + count, ifAbsent: () => count);
    run.checksums.update(record['checksumState'] as String, (n) => n + count,
        ifAbsent: () => count);
    run.history.add(record);
    if (run.history.length > historyLimit) run.history.removeFirst();
    final second = record['second'] as int;
    final window = run.windows.putIfAbsent(
        second,
        () => {
              'operations': <String, int>{},
              'count': 0,
              'bytes': 0,
              'latency': 0.0,
              'records': 0
            });
    window['count'] = (window['count'] as int) + count;
    window['bytes'] =
        (window['bytes'] as int) + (record['bytesTransferred'] as int);
    window['latency'] =
        (window['latency'] as double) + (record['latencyMs'] as double);
    window['records'] = (window['records'] as int) + 1;
    (window['operations'] as Map<String, int>)
        .update(operation, (n) => n + count, ifAbsent: () => count);
    while (run.windows.length > 3600) {
      run.windows.remove(run.windows.firstKey());
    }
    if (run.config['reducedLogging'] != true) {
      run.log(
          '$operation ${record['key']} completed in ${(record['latencyMs'] as num).toStringAsFixed(1)} ms.');
    }
  }

  Map<String, Object?> _summary(_Run run) {
    final records = run.history.toList(growable: false),
        latencies = records
            .map((r) => (r['latencyMs'] as num).toDouble())
            .toList()
          ..sort();
    double percentile(double p) {
      if (latencies.isEmpty) return 0;
      final rank = (latencies.length - 1) * p / 100;
      final low = rank.floor(), high = rank.ceil();
      return latencies[low] + (latencies[high] - latencies[low]) * (rank - low);
    }

    final bySize = <int, List<double>>{}, bySecond = <int, List<double>>{};
    final byOperation = <String, List<double>>{};
    for (final record in records) {
      final latency = (record['latencyMs'] as num).toDouble();
      (bySize[record['sizeBytes'] as int] ??= []).add(latency);
      (bySecond[record['second'] as int] ??= []).add(latency);
      (byOperation[record['operation'] as String] ??= []).add(latency);
    }
    final end = max(max(1, run.elapsed.ceil()), run.windows.lastKey() ?? 0);

    final series = <Map<String, Object?>>[];
    for (var second = max(1, end - 3599); second <= end; second++) {
      final w = run.windows[second];
      series.add({
        'second': second,
        'label': '${second}s',
        'opsPerSecond': w?['count'] ?? 0,
        'bytesPerSecond': w?['bytes'] ?? 0,
        'averageLatencyMs':
            w == null ? 0 : (w['latency'] as num) / (w['records'] as int),
        'operations':
            Map<String, int>.from(w?['operations'] as Map? ?? const {}),
        'p95LatencyMs': _percentile(bySecond[second] ?? [], 95)
      });
    }
    return {
      'totalOperations': run.processed,
      'operationsByType': Map<String, int>.of(run.operations),
      'latencyPercentilesMs': {
        for (final p in <num>[50, 75, 90, 95, 99, 99.9])
          p == 99.9 ? 'p999' : 'p$p': percentile(p.toDouble())
      },
      'throughputSeries': series,
      'latencyTimeline': [
        for (var i = 0; i < records.length; i++)
          {
            ...records[i],
            'sequence': run.recordCount - records.length + i + 1,
            'label':
                '${((records[i]['elapsedMs'] as num) / 1000).toStringAsFixed(2)}s'
          }
      ],
      'sizeLatencyBuckets': [
        for (final e in bySize.entries)
          if (e.key > 0)
            {
              'sizeBytes': e.key,
              'count': e.value.length,
              'avgLatencyMs': e.value.reduce((a, b) => a + b) / e.value.length,
              'p50LatencyMs': _percentile(e.value, 50),
              'p95LatencyMs': _percentile(e.value, 95),
              'p99LatencyMs': _percentile(e.value, 99)
            }
      ],
      'latencyPercentilesByOperationMs': {
        for (final e in byOperation.entries)
          e.key: {
            'p50': _percentile(e.value, 50),
            'p95': _percentile(e.value, 95),
            'p99': _percentile(e.value, 99)
          }
      },
      'checksumStats': Map<String, int>.of(run.checksums),
      'detailMetrics': {
        'checksumAlgorithm': run.config['checksumAlgorithm'],
        'sampleCount': series.length,
        'sampleWindowSeconds': 1,
        'averageObjectSizeBytes': (run.config['objectSizes'] as List)
                .cast<int>()
                .reduce((a, b) => a + b) /
            (run.config['objectSizes'] as List).length,
        'averageOpsPerSecond': run.processed / max(run.elapsed, .000001),
        'averageBytesPerSecond': run.totalBytes / max(run.elapsed, .000001),
        'peakOpsPerSecond':
            series.map((v) => v['opsPerSecond'] as int).fold(0, max),
        'peakBytesPerSecond':
            series.map((v) => v['bytesPerSecond'] as int).fold(0, max),
        'errorCount': run.errors,
        'retryCount': run.retries,
        'requestCount': run.requests,
        'checksumValidated': run.checksums['validated_success'] ?? 0,
        'historyLimit': historyLimit,
        'historyRecordsRetained': records.length,
        'historyTruncated': run.recordCount > records.length,
        'latencyStatisticsScope': 'retained-recent-requests',
        'cacheBytes': run.cacheBytes
      }
    };
  }

  Map<String, Object?> _snapshot(_Run run) => {
        'id': run.id,
        'profileId': run.profileId,
        'config': run.config,
        'status': run.status,
        'processedCount': run.processed,
        'startedAt': run.startedAt,
        'completedAt': run.completedAt,
        'activeElapsedSeconds': run.elapsed,
        'averageLatencyMs': run.totalLatency / max(run.recordCount, 1),
        'throughputOpsPerSecond': run.processed / max(run.elapsed, .000001),
        'liveLog': run.logs.toList(),
        'resultSummary': _summary(run)
      };

  Future<void> _save(_Run run) async {
    // Serialize the snapshot before awaiting, so concurrent status/control calls
    // cannot alter an in-progress JSON encoding or write endpoint credentials.
    final snapshot = _snapshot(run);
    final state = {
      ...snapshot,
      'owner': run.owner,
      'activeObjects': run.objects,
      'history': run.history.toList(),
      'totalRecordCount': run.recordCount,
      'totalBytes': run.totalBytes,
      'totalLatency': run.totalLatency,
      'operations': run.operations,
      'checksums': run.checksums,
      'errors': run.errors,
      'retries': run.retries,
      'requests': run.requests,
      'nextObject': run.nextObject,
      'nextSize': run.nextSize,
      'nextActive': run.nextActive,
      'windows': {for (final e in run.windows.entries) '${e.key}': e.value}
    };
    final json = jsonEncode(state),
        summary = jsonEncode(snapshot['resultSummary']),
        logs = run.logs.join('\n');
    // Serialize writers per run, including explicit export while a run is active.
    final previous = run.persistence;
    final work = () async {
      try {
        await previous;
      } catch (_) {
        // A fresh checkpoint write may recover from an earlier transient disk error.
      }
      final root = await _root();
      final target = File('${root.path}/${run.id}.json'),
          temporary = File('${root.path}/${run.id}.json.next');
      await temporary.writeAsString(json, flush: true);
      await temporary.rename(target.path);
      await File(run.config['jsonOutputPath'] as String).writeAsString(summary);
      await File(run.config['logFilePath'] as String).writeAsString(logs);
    }();
    run.persistence = work;
    await work;
  }

  Future<void> close() async {
    _closed = true;
    final runs = _runs.values.toList();
    for (final run in runs) {
      if (run.status == 'running') run.status = 'paused';
    }
    for (final run in runs) {
      await run.worker;
    }
    _runs.clear();
  }

  static double _percentile(List<double> input, double p) {
    if (input.isEmpty) return 0;
    final values = List<double>.of(input)..sort();
    final rank = (values.length - 1) * p / 100;
    return values[rank.floor()] +
        (values[rank.ceil()] - values[rank.floor()]) * (rank - rank.floor());
  }

  static String _owner(EndpointProfile p) => sha256
      .convert(utf8.encode(jsonEncode([
        p.id,
        p.endpointType.name,
        p.endpointUrl,
        p.region,
        p.pathStyle,
        p.connection.expectedBucketOwner
      ])))
      .toString();
  static int _int(Map<String, Object?> m, String key, int fallback) =>
      (m[key] as num?)?.toInt() ?? fallback;
  static Hash _hash(Map<String, Object?> config) =>
      switch (config['checksumAlgorithm']) {
        'md5' => md5,
        'sha1' => sha1,
        'crc32' => _CrcHash.ieee,
        'crc32c' => _CrcHash.castagnoli,
        _ => sha256
      };
  static Never _invalid(String message) =>
      throw EngineException(code: ErrorCode.invalidConfig, message: message);
  static Map<String, Object?> _config(Map<String, Object?> input) {
    const defaults = <String, Object?>{
      'profileId': '',
      'engineId': 'mobile',
      'bucketName': '',
      'prefix': '',
      'workloadType': 'mixed',
      'deleteMode': 'single',
      'objectSizes': [4096],
      'concurrentThreads': 1,
      'testMode': 'duration',
      'operationCount': 1000,
      'durationSeconds': 60,
      'validateChecksum': true,
      'checksumAlgorithm': 'sha256',
      'randomData': true,
      'inMemoryData': true,
      'objectCount': 100,
      'connectTimeoutSeconds': 5,
      'readTimeoutSeconds': 60,
      'maxAttempts': 5,
      'maxPoolConnections': 10,
      'dataCacheMb': 64,
      'debugMode': false,
      'reducedLogging': false,
      'readPercent': 34,
      'writePercent': 33,
      'deletePercent': 33
    };
    final result = {
      for (final e in defaults.entries) e.key: input[e.key] ?? e.value
    };
    for (final e in {
      'concurrentThreads': [1, 64],
      'maxPoolConnections': [1, 64],
      'objectCount': [1, 100000],
      'dataCacheMb': [0, 1024],
      'operationCount': [1, 100000000],
      'durationSeconds': [1, 86400],
      'maxAttempts': [1, 10],
      'connectTimeoutSeconds': [1, 300],
      'readTimeoutSeconds': [1, 3600]
    }.entries) {
      final value = _int(result, e.key, -1);
      if (value < e.value[0] || value > e.value[1]) {
        _invalid('Invalid benchmark ${e.key}.');
      }
      result[e.key] = value;
    }
    if ((result['bucketName'] as String).isEmpty) {
      _invalid('A benchmark bucket/container is required.');
    }
    if (!{
      'write-only',
      'read-only',
      'write-heavy',
      'read-heavy',
      'delete',
      'mixed',
      'custom'
    }.contains(result['workloadType'])) {
      _invalid('Unknown benchmark workload.');
    }
    if (!{'operation-count', 'duration'}.contains(result['testMode'])) {
      _invalid('Unknown benchmark test mode.');
    }
    if (!{'sha256', 'sha1', 'md5', 'crc32', 'crc32c'}
        .contains(result['checksumAlgorithm'])) {
      _invalid('Choose SHA256, SHA1, MD5, CRC32 or CRC32C.');
    }
    final sizes =
        (result['objectSizes'] as List).map((v) => (v as num).toInt()).toList();
    if (sizes.isEmpty ||
        sizes.length > 64 ||
        sizes.any((v) => v < 1 || v > 512 * 1024 * 1024)) {
      _invalid('Benchmark object sizes must be 1 byte–512 MiB.');
    }
    result['objectSizes'] = sizes;
    if (result['workloadType'] == 'custom') {
      final percentages = ['readPercent', 'writePercent', 'deletePercent']
          .map((k) => _int(result, k, 0))
          .toList();
      if (percentages.any((v) => v < 0 || v > 100) ||
          percentages.fold(0, (a, b) => a + b) != 100) {
        _invalid('Custom workload percentages must sum to 100.');
      }
    }
    return result;
  }

  static String _operation(Map<String, Object?> c, int index) {
    if (c['workloadType'] == 'write-only') return 'PUT';
    if (c['workloadType'] == 'read-only') return 'GET';
    if (c['workloadType'] == 'delete') return 'DELETE';
    final ratios = switch (c['workloadType']) {
      'write-heavy' => [60, 30, 10],
      'read-heavy' => [25, 65, 10],
      'custom' => [
          _int(c, 'writePercent', 33),
          _int(c, 'readPercent', 34),
          _int(c, 'deletePercent', 33)
        ],
      _ => [34, 33, 33]
    };
    final slot = index % 100;
    return slot < ratios[0]
        ? 'PUT'
        : slot < ratios[0] + ratios[1]
            ? 'GET'
            : 'DELETE';
  }
}

class _Run {
  _Run(this.id, this.profileId, this.owner, this.config);
  final String id, profileId, owner;
  final Map<String, Object?> config;
  String status = 'paused',
      startedAt = DateTime.now().toUtc().toIso8601String();
  String? completedAt;
  int processed = 0,
      recordCount = 0,
      totalBytes = 0,
      errors = 0,
      retries = 0,
      requests = 0,
      baseRetries = 0,
      baseRequests = 0;
  int nextObject = 0,
      nextSize = 0,
      nextActive = 0,
      nextPayload = 0,
      cacheBytes = 0;
  double totalLatency = 0, baseElapsed = 0;
  final Stopwatch clock = Stopwatch();
  double get elapsed => baseElapsed + clock.elapsedMicroseconds / 1000000;
  String get prefix {
    final p = config['prefix'] as String;
    return '${p.isEmpty || p.endsWith('/') ? p : '$p/'}$id/';
  }

  final Map<String, Map<String, Object?>> objects = {};
  final Map<String, int> operations = {}, checksums = {};
  final ListQueue<Map<String, Object?>> history = ListQueue();
  final SplayTreeMap<int, Map<String, Object?>> windows = SplayTreeMap();
  final ListQueue<String> logs = ListQueue.of(['Benchmark scheduled.']);
  final LinkedHashMap<String, _Payload> cache = LinkedHashMap();
  Future<void>? worker;
  Future<void> persistence = Future.value();
  ActionScope? scope;
  void log(String line) {
    logs.add(line);
    while (logs.length > 60) {
      logs.removeFirst();
    }
  }

  factory _Run.restore(Map<String, Object?> s) {
    final r = _Run(s['id'] as String, s['profileId'] as String,
        s['owner'] as String, Map<String, Object?>.from(s['config'] as Map));
    r.status = s['status'] as String;
    r.startedAt = s['startedAt'] as String;
    r.completedAt = s['completedAt'] as String?;
    int n(String k) => (s[k] as num?)?.toInt() ?? 0;
    r.processed = n('processedCount');
    r.recordCount = n('totalRecordCount');
    r.totalBytes = n('totalBytes');
    r.errors = n('errors');
    r.retries = n('retries');
    r.baseRetries = r.retries;
    r.requests = n('requests');
    r.baseRequests = r.requests;
    r.nextObject = n('nextObject');
    r.nextSize = n('nextSize');
    r.nextActive = n('nextActive');
    r.totalLatency = (s['totalLatency'] as num?)?.toDouble() ?? 0;
    r.baseElapsed = (s['activeElapsedSeconds'] as num?)?.toDouble() ?? 0;
    for (final e in (s['activeObjects'] as Map? ?? {}).entries) {
      r.objects[e.key as String] = Map<String, Object?>.from(e.value as Map);
    }
    for (final e in (s['operations'] as Map? ?? {}).entries) {
      r.operations[e.key as String] = (e.value as num).toInt();
    }
    for (final e in (s['checksums'] as Map? ?? {}).entries) {
      r.checksums[e.key as String] = (e.value as num).toInt();
    }
    for (final item in (s['history'] as List? ?? [])
        .reversed
        .take(MobileBenchmarkService.historyLimit)
        .toList()
        .reversed) {
      r.history.add(Map<String, Object?>.from(item as Map));
    }
    for (final e in (s['windows'] as Map? ?? {}).entries) {
      final w = Map<String, Object?>.from(e.value as Map);
      w['latency'] = (w['latency'] as num).toDouble();
      w['operations'] = Map<String, int>.from(w['operations'] as Map);
      r.windows[int.parse(e.key as String)] = w;
    }
    r.logs.clear();
    r.logs.addAll((s['liveLog'] as List? ?? [])
        .cast<String>()
        .reversed
        .take(60)
        .toList()
        .reversed);
    return r;
  }
}

class _Task {
  _Task(this.operation, this.keys, this.size);
  final String operation;
  final List<String> keys;
  final int size;
}

class _Payload {
  Uint8List? bytes;
  File? file;
  String sha256Hash = '', checksum = '';
  Stream<List<int>> open() async* {
    if (file != null) {
      yield* file!.openRead();
      return;
    }
    for (var offset = 0; offset < bytes!.length; offset += 256 * 1024) {
      yield Uint8List.sublistView(
          bytes!, offset, min(bytes!.length, offset + 256 * 1024));
    }
  }

  Future<void> disposeFile() async {
    if (file != null && await file!.exists()) await file!.delete();
  }
}

class _DigestSink implements Sink<Digest> {
  Digest? value;
  @override
  void add(Digest data) {
    value = data;
  }

  @override
  void close() {}
}

/// Streaming CRC with one reusable 256-entry table per polynomial.
class _CrcHash extends Hash {
  _CrcHash(int polynomial)
      : table = List<int>.generate(256, (index) {
          var value = index;
          for (var bit = 0; bit < 8; bit++) {
            value = (value >>> 1) ^ ((value & 1) == 1 ? polynomial : 0);
          }
          return value;
        });
  static final ieee = _CrcHash(0xedb88320);
  static final castagnoli = _CrcHash(0x82f63b78);
  final List<int> table;
  @override
  int get blockSize => 1;
  @override
  ByteConversionSink startChunkedConversion(Sink<Digest> sink) =>
      _CrcSink(table, sink);
}

class _CrcSink extends ByteConversionSinkBase {
  _CrcSink(this.table, this.output);
  final List<int> table;
  final Sink<Digest> output;
  var value = 0xffffffff;
  var closed = false;
  @override
  void add(List<int> chunk) => addSlice(chunk, 0, chunk.length, false);
  @override
  void addSlice(List<int> chunk, int start, int end, bool isLast) {
    if (closed) throw StateError('Checksum sink is closed.');
    for (var index = start; index < end; index++) {
      value = table[(value ^ chunk[index]) & 255] ^ (value >>> 8);
    }
    if (isLast) close();
  }

  @override
  void close() {
    if (closed) return;
    closed = true;
    final crc = value ^ 0xffffffff;
    output.add(Digest([
      (crc >>> 24) & 255,
      (crc >>> 16) & 255,
      (crc >>> 8) & 255,
      crc & 255
    ]));
    output.close();
  }
}
