import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';
import 'package:xml/xml.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:s3_browser_crossplat/models/domain_models.dart';
import 'package:s3_browser_crossplat/services/mobile_benchmark_service.dart';
import 'package:s3_browser_crossplat/services/storage_http_client.dart';

void main() {
  late HttpServer server;
  late Directory directory;
  late EndpointProfile profile;
  late MobileBenchmarkService service;
  late Map<String, List<int>> objects;
  var puts = 0, gets = 0, failPuts = 0, active = 0, maxActive = 0;
  var delay = Duration.zero;
  var failDelete = false;
  final requestTimes = <DateTime>[];
  setUp(() async {
    puts = 0;
    gets = 0;
    failPuts = 0;
    active = 0;
    maxActive = 0;
    delay = Duration.zero;
    failDelete = false;
    objects = {};
    requestTimes.clear();
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    directory = await Directory.systemTemp.createTemp('mobile-benchmark-test-');
    profile = EndpointProfile.fromJson({
      'id': 'fixture',
      'name': 'fixture',
      'endpointType': 's3Compatible',
      'endpointUrl': 'http://127.0.0.1:${server.port}',
      'region': 'us-east-1',
      'pathStyle': true,
      'accessKey': 'fictional-access',
      'secretKey': 'fictional-secret',
      'sessionToken': 'fictional-token',
      'maxAttempts': 2
    });
    service = MobileBenchmarkService(checkpointDirectory: directory);
    server.listen((request) async {
      requestTimes.add(DateTime.now());
      active++;
      if (active > maxActive) maxActive = active;
      try {
        final payload =
            await request.fold<List<int>>(<int>[], (a, b) => a..addAll(b));
        if (request.headers.value('x-ms-date') == null) {
          expect(request.headers.value('x-amz-content-sha256'),
              sha256.convert(payload).toString());
        } else {
          expect(request.headers.value('authorization'),
              startsWith('SharedKey account:'));
          expect(request.contentLength, payload.length);
        }
        if (delay != Duration.zero) await Future<void>.delayed(delay);
        switch (request.method) {
          case 'PUT':
            if (failPuts > 0) {
              failPuts--;
              request.response.statusCode = 503;
              request.response.write('<Error><Code>SlowDown</Code></Error>');
              break;
            }
            puts++;
            objects[request.uri.path] = payload;
            request.response.headers.set('etag', '"${md5.convert(payload)}"');
          case 'GET':
            gets++;
            final bytes = objects[request.uri.path];
            if (bytes == null) {
              request.response.statusCode = 404;
              break;
            }
            request.response.contentLength = bytes.length;
            for (var start = 0; start < bytes.length; start += 4096) {
              request.response.add(
                  bytes.sublist(start, (start + 4096).clamp(0, bytes.length)));
              if (request.uri.path.endsWith('/stream') && start % 65536 == 0) {
                await request.response.flush();
                await Future<void>.delayed(const Duration(milliseconds: 2));
              }
            }
          case 'POST':
            final parsed = XmlDocument.parse(utf8.decode(payload));
            final keys =
                parsed.findAllElements('Key').map((e) => e.innerText).toList();
            final xml = XmlBuilder();
            xml.element('DeleteResult', nest: () {
              for (var i = 0; i < keys.length; i++) {
                if (failDelete && i == keys.length - 1) {
                  xml.element('Error', nest: () {
                    xml.element('Key', nest: keys[i]);
                    xml.element('Code', nest: 'AccessDenied');
                  });
                } else {
                  objects.remove('/fixture/${keys[i]}');
                  xml.element('Deleted', nest: () {
                    xml.element('Key', nest: keys[i]);
                  });
                }
              }
            });
            request.response.write(xml.buildDocument().toXmlString());
          case 'DELETE':
            objects.remove(request.uri.path);
            request.response.statusCode = 204;
          default:
            request.response.statusCode = 405;
        }
        await request.response.close();
      } on SocketException {
        // Cancellation can close the peer while the fixture is replying.
      } on HttpException {
        // Cancellation can close the peer while the fixture is replying.
      } finally {
        active--;
      }
    });
  });
  tearDown(() async {
    await service.close();
    await server.close(force: true);
    await directory.delete(recursive: true);
  });
  Map<String, Object?> config(
          {int count = 12, int workers = 4, bool memory = true}) =>
      {
        'bucketName': 'fixture',
        'testMode': 'operation-count',
        'operationCount': count,
        'objectCount': workers,
        'objectSizes': [32769],
        'concurrentThreads': workers,
        'maxPoolConnections': workers,
        'workloadType': 'write-only',
        'inMemoryData': memory,
        'dataCacheMb': 1,
        'maxAttempts': 2,
        'reducedLogging': true
      };
  Future<Map<String, Object?>> status(String id) => service
      .dispatch('getBenchmarkStatus', profile: profile, params: {'runId': id});
  Future<Map<String, Object?>> complete(String id) async {
    final deadline = DateTime.now().add(const Duration(seconds: 15));
    while (DateTime.now().isBefore(deadline)) {
      final state = await status(id);
      if (state['status'] != 'running') return state;
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    fail('Benchmark did not finish.');
  }

  test(
      'streamed retries reopen bodies, sign exact lengths and consume GET chunks',
      () async {
    final client = StorageHttpClient(profile);
    addTearDown(client.close);
    final body = Uint8List.fromList(List.generate(300003, (i) => i % 251));
    var factories = 0;
    failPuts = 1;
    await client.requestStream('PUT', 'fixture', key: 'stream', body: () {
      factories++;
      return Stream.fromIterable([body.sublist(0, 123), body.sublist(123)]);
    },
        bodyLength: body.length,
        payloadSha256: sha256.convert(body).toString(),
        retrySafe: true);
    expect(factories, 2);
    expect(client.retryCount, 1);
    var received = 0, chunks = 0;
    final response = await client.requestStream('GET', 'fixture',
        key: 'stream', maxResponseBytes: body.length, onResponseStart: () {
      received = 0;
    }, onResponseChunk: (part) {
      received += part.length;
      chunks++;
    });
    expect(received, body.length);
    expect(chunks, greaterThan(1));
    expect(response.body, isEmpty);
    expect(objects['/fixture/stream'], body);
  });
  for (final memory in [false, true]) {
    test(
        'background progress, workers, storage controls and secret-free checkpoints ($memory)',
        () async {
      delay = const Duration(milliseconds: 15);
      final started = await service.dispatch('startBenchmark',
          profile: profile, params: {'config': config(memory: memory)});
      final id = started['id'] as String;
      final deadline = DateTime.now().add(const Duration(seconds: 10));
      while (puts < 12 && DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
      expect(puts, 12,
          reason: 'Requests must progress without status polling.');
      final state = await complete(id);
      expect(state['status'], 'completed');
      expect(state['processedCount'], 12);
      expect(maxActive, inInclusiveRange(2, 4));
      expect(objects.length, 4);
      final summary = state['resultSummary'] as Map;
      expect(summary['operationsByType'], {'PUT': 12});
      final metrics = summary['detailMetrics'] as Map;
      expect(metrics['errorCount'], 0);
      expect(metrics['retryCount'], 0);
      expect(metrics['requestCount'], 12);
      final timeline = summary['latencyTimeline'] as List;
      expect(timeline.length, 12);
      expect((timeline.last as Map)['elapsedMs'],
          greaterThan((timeline.first as Map)['elapsedMs'] as num));
      expect(
          (state['liveLog'] as List)
              .where((v) => (v as String).startsWith('PUT ')),
          isEmpty);
      final checkpoint =
          await File('${directory.path}/$id.json').readAsString();
      for (final value in [
        'fictional-access',
        'fictional-secret',
        'fictional-token'
      ]) {
        expect(checkpoint, isNot(contains(value)));
        expect(jsonEncode(state), isNot(contains(value)));
      }
      final export = await service.dispatch('exportBenchmarkResults',
          profile: profile, params: {'runId': id, 'format': 'csv'});
      expect((await File(export['path'] as String).readAsLines()).length, 13);
      expect(
          (await directory.list().toList())
              .where((f) => f.path.endsWith('.tmp')),
          isEmpty);
    });
  }
  for (final algorithm in ['sha256', 'sha1', 'md5', 'crc32', 'crc32c']) {
    test('read-only counts seed PUTs and streams real $algorithm validation',
        () async {
      final started =
          await service.dispatch('startBenchmark', profile: profile, params: {
        'config': {
          ...config(count: 6, workers: 2, memory: false),
          'workloadType': 'read-only',
          'checksumAlgorithm': algorithm,
          'validateChecksum': true
        }
      });
      final state = await complete(started['id'] as String);
      expect(state['status'], 'completed');
      expect(puts, 2);
      expect(gets, 4);
      final summary = state['resultSummary'] as Map;
      expect(summary['operationsByType'], {'PUT': 2, 'GET': 4});
      expect((summary['checksumStats'] as Map)['validated_success'], 4);
      final checkpoint = jsonDecode(
          await File('${directory.path}/${started['id']}.json')
              .readAsString()) as Map;
      for (final record in (checkpoint['history'] as List)
          .cast<Map>()
          .where((r) => r['operation'] == 'GET')) {
        final data = objects['/fixture/${record['key']}']!;
        String expected;
        if (algorithm == 'crc32' || algorithm == 'crc32c') {
          var value = 0xffffffff;
          final polynomial = algorithm == 'crc32c' ? 0x82f63b78 : 0xedb88320;
          for (final byte in data) {
            value ^= byte;
            for (var bit = 0; bit < 8; bit++) {
              value = (value >>> 1) ^ ((value & 1) == 1 ? polynomial : 0);
            }
          }
          expected = (value ^ 0xffffffff).toRadixString(16).padLeft(8, '0');
        } else {
          final hash = algorithm == 'md5'
              ? md5
              : algorithm == 'sha1'
                  ? sha1
                  : sha256;
          expected = hash.convert(data).toString();
        }
        expect(record['checksumAlgorithm'], algorithm);
        expect(record['checksum'], expected);
      }
    });
  }
  test('real retries and final failures appear in metrics', () async {
    failPuts = 1;
    final started = await service.dispatch('startBenchmark',
        profile: profile, params: {'config': config(count: 1, workers: 1)});
    var state = await complete(started['id'] as String);
    expect(state['status'], 'completed');
    expect(
        ((state['resultSummary'] as Map)['detailMetrics'] as Map)['retryCount'],
        1);
    failPuts = 4;
    final failed =
        await service.dispatch('startBenchmark', profile: profile, params: {
      'config': {...config(count: 1, workers: 1), 'maxAttempts': 1}
    });
    state = await complete(failed['id'] as String);
    expect(state['status'], 'failed');
    expect(state['processedCount'], 0);
    expect(
        ((state['resultSummary'] as Map)['detailMetrics'] as Map)['errorCount'],
        1);
  });
  test('streamed Azure SharedKey uses the supplied payload length', () async {
    final azure = EndpointProfile.fromJson({
      ...profile.toJson(),
      'endpointType': 'azureBlob',
      'accessKey': 'account',
      'secretKey': base64Encode(List<int>.filled(32, 7)),
      'sessionToken': null
    });
    final client = StorageHttpClient(azure);
    addTearDown(client.close);
    final bytes = List<int>.generate(65539, (i) => i % 251);
    final now = DateTime.utc(2026, 10, 2);
    final target = client.uri('container', 'object');
    expect(
        client.signedHeaders(
            'PUT', target, {'x-ms-blob-type': 'BlockBlob'}, bytes, now),
        client.signedHeaders(
            'PUT', target, {'x-ms-blob-type': 'BlockBlob'}, [], now,
            bodyLength: bytes.length));
    await client.requestStream('PUT', 'container',
        key: 'object',
        headers: {'x-ms-blob-type': 'BlockBlob'},
        body: () => Stream.value(bytes),
        bodyLength: bytes.length,
        retrySafe: true);
    expect(objects['/container/object'], bytes);
  });

  test('parallel callers share one serialized request admission rate',
      () async {
    final client =
        StorageHttpClient(profile.copyWith(maxRequestsPerSecond: 20));
    addTearDown(client.close);
    await Future.wait(List.generate(
        4,
        (i) =>
            client.request('PUT', 'fixture', key: 'rate-$i', retrySafe: true)));
    expect(requestTimes.length, 4);
    for (var i = 1; i < requestTimes.length; i++) {
      expect(requestTimes[i].difference(requestTimes[i - 1]).inMilliseconds,
          greaterThanOrEqualTo(35));
    }
  });

  test(
      'checkpoint restoration bounds recent history while preserving cumulative totals',
      () async {
    final started = await service.dispatch('startBenchmark',
        profile: profile, params: {'config': config(count: 1, workers: 1)});
    final id = started['id'] as String;
    await complete(id);
    await service.close();
    final file = File('${directory.path}/$id.json');
    final saved = jsonDecode(await file.readAsString()) as Map<String, dynamic>;
    final first = (saved['history'] as List).first as Map;
    saved['status'] = 'paused';
    saved['processedCount'] = 10000;
    saved['totalRecordCount'] = 10000;
    saved['totalBytes'] = 32769 * 10000;
    saved['totalLatency'] = 10000.0;
    saved['activeElapsedSeconds'] = 1.0;
    saved['operations'] = {'PUT': 10000};
    saved['checksums'] = {'not_used': 10000};
    saved['history'] = List.generate(10000,
        (i) => {...first, 'second': 1, 'elapsedMs': i / 10, 'latencyMs': 1.0});
    saved['windows'] = {
      '1': {
        'operations': {'PUT': 10000},
        'count': 10000,
        'bytes': 32769 * 10000,
        'latency': 10000.0,
        'records': 10000
      }
    };
    (saved['config'] as Map)['operationCount'] = 10002;
    await file.writeAsString(jsonEncode(saved));
    service = MobileBenchmarkService(checkpointDirectory: directory);
    await service.dispatch('resumeBenchmarkRun',
        profile: profile, params: {'runId': id});
    final state = await complete(id);
    expect(state['status'], 'completed');
    expect(state['processedCount'], 10002);
    final summary = state['resultSummary'] as Map,
        metrics = summary['detailMetrics'] as Map;
    expect(summary['totalOperations'], 10002);
    expect(summary['operationsByType'], {'PUT': 10002});
    expect(metrics['historyRecordsRetained'], 10000);
    expect(metrics['historyTruncated'], true);
    expect(
        (summary['throughputSeries'] as List)
            .fold<int>(0, (n, e) => n + (e as Map)['opsPerSecond'] as int),
        10002);
  });

  for (final partial in [false, true]) {
    test('multi-delete counts only acknowledged removals ($partial)', () async {
      failDelete = partial;
      final started =
          await service.dispatch('startBenchmark', profile: profile, params: {
        'config': {
          ...config(count: 6, workers: 3),
          'workloadType': 'custom',
          'writePercent': 3,
          'readPercent': 0,
          'deletePercent': 97,
          'deleteMode': 'multi-object-post'
        }
      });
      final state = await complete(started['id'] as String);
      expect(state['status'], partial ? 'failed' : 'completed');
      expect(state['processedCount'], partial ? 5 : 6);
      final summary = state['resultSummary'] as Map;
      expect(
          summary['operationsByType'], {'PUT': 3, 'DELETE': partial ? 2 : 3});
      expect((summary['detailMetrics'] as Map)['errorCount'], partial ? 1 : 0);
    });
  }

  test('stop aborts owned requests and prevents queued benchmark work',
      () async {
    delay = const Duration(milliseconds: 100);
    final started = await service.dispatch('startBenchmark',
        profile: profile, params: {'config': config(count: 100, workers: 2)});
    final id = started['id'] as String;
    while (active == 0) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    final stopped = await service
        .dispatch('stopBenchmark', profile: profile, params: {'runId': id});
    expect(stopped['status'], 'stopped');
    expect(stopped['processedCount'], lessThan(100));
    await Future<void>.delayed(const Duration(milliseconds: 150));
    final before = puts;
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(puts, before);
    expect((await status(id))['status'], 'stopped');
  });

  test('pause and restart resume require the owner and exclude paused time',
      () async {
    delay = const Duration(milliseconds: 30);
    final started = await service.dispatch('startBenchmark',
        profile: profile, params: {'config': config(count: 20, workers: 1)});
    final id = started['id'] as String;
    while (puts < 2) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    final paused = await service
        .dispatch('pauseBenchmark', profile: profile, params: {'runId': id});
    expect(paused['status'], 'paused');
    final before = puts;
    final elapsed = paused['activeElapsedSeconds'] as num;
    await service.close();
    service = MobileBenchmarkService(checkpointDirectory: directory);
    await Future<void>.delayed(const Duration(milliseconds: 150));
    expect(puts, before);
    expect((await status(id))['activeElapsedSeconds'], elapsed);
    await expectLater(
        service.dispatch('resumeBenchmark',
            profile:
                EndpointProfile.fromJson({...profile.toJson(), 'id': 'other'}),
            params: {'runId': id}),
        throwsA(isA<EngineException>()));
    await service
        .dispatch('resumeBenchmark', profile: profile, params: {'runId': id});
    final ended = await complete(id);
    expect(ended['status'], 'completed');
    expect(puts, 20);
    expect(ended['processedCount'], 20);
    final export = await service.dispatch('exportBenchmarkResults',
        profile: profile, params: {'runId': id, 'format': 'csv'});
    expect((await File(export['path'] as String).readAsLines()).length, 21);
  });
}
