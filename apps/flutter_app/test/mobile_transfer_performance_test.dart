import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:s3_browser_crossplat/controllers/action_scope.dart';
import 'package:s3_browser_crossplat/models/domain_models.dart';
import 'package:s3_browser_crossplat/services/listing_cancellation.dart';
import 'package:s3_browser_crossplat/services/mobile_storage_admin.dart';
import 'package:s3_browser_crossplat/services/mobile_storage_hash.dart';
import 'package:s3_browser_crossplat/services/storage_http_client.dart';

void main() {
  late HttpServer server;
  late EndpointProfile profile;
  late MobileStorageAdmin admin;
  late Future<void> Function(HttpRequest) handler;
  setUp(() async {
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    profile = EndpointProfile(
        id: 'fixture',
        name: 'fixture',
        endpointUrl: 'http://127.0.0.1:${server.port}',
        region: 'us-east-1',
        accessKey: 'test',
        secretKey: 'secret',
        pathStyle: true,
        verifyTls: true,
        maxAttempts: 1);
    admin = MobileStorageAdmin();
    handler = (request) async {
      await request.drain<void>();
      request.response.statusCode = 200;
    };
    server.listen((request) async {
      try {
        await handler(request);
      } finally {
        await request.response.close();
      }
    });
  });
  tearDown(() async {
    admin.close();
    await server.close(force: true);
  });

  test('one hashing worker interleaves bounded streams with exact digests',
      () async {
    final hasher = MobilePayloadHasher();
    addTearDown(hasher.close);
    final a =
        Uint8List.fromList(List.generate(2 * 1024 * 1024, (i) => i % 251));
    final b = Uint8List.fromList(List.generate(1024 * 1024, (i) => i % 127));
    final actual = await Future.wait(
        [hasher.hash(Stream.value(a)), hasher.hash(Stream.value(b))]);
    expect(
        actual, [sha256.convert(a).toString(), sha256.convert(b).toString()]);
    expect(await hasher.hash(Stream.value(a.sublist(0, 32))),
        sha256.convert(a.sublist(0, 32)).toString());
  });
  test('closing a starting hashing worker completes its caller', () async {
    final hasher = MobilePayloadHasher();
    final work = hasher.hash(Stream.value([1, 2, 3]));
    hasher.close();
    await expectLater(
        work.timeout(const Duration(seconds: 2)), throwsStateError);
  });

  test('completed transport requests release cancellation listeners', () async {
    final scope = ActionScope(inheritParent: false);
    addTearDown(scope.dispose);
    await scope.run(() async {
      for (var i = 0; i < 100; i++) {
        await admin.client(profile).request('HEAD', 'bucket');
        expect(scope.activeListenerCount, 0);
      }
    });
  });

  test('cache eviction preserves clients leased by a whole action', () async {
    final scope = ActionScope(inheritParent: false);
    addTearDown(scope.dispose);
    await scope.run(() async {
      final held = admin.client(profile);
      for (var i = 0; i < 9; i++) {
        admin.client(profile.copyWith(name: 'other-$i'));
      }
      await held.request('HEAD', 'bucket');
    });
  });

  test('healthy upload may exceed one inactivity interval', () async {
    final http = StorageHttpClient(profile.copyWith(readTimeoutSeconds: 1));
    addTearDown(http.close);
    final bytes = Uint8List(64 * 1024);
    Stream<List<int>> body() async* {
      for (var i = 0; i < 6; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 250));
        yield bytes;
      }
    }

    final result = await http.requestStream('PUT', 'bucket',
        key: 'slow',
        body: body,
        bodyLength: bytes.length * 6,
        payloadSha256: sha256.convert(Uint8List(bytes.length * 6)).toString());
    expect(result.status, 200);
  });

  test('server retry delay is honored and cancellation interrupts it',
      () async {
    var attempts = 0;
    handler = (request) async {
      await request.drain<void>();
      if (++attempts == 1) {
        request.response.statusCode = 429;
        request.response.headers.set('retry-after', '1');
      }
    };
    final http = StorageHttpClient(profile.copyWith(maxAttempts: 2));
    addTearDown(http.close);
    final clock = Stopwatch()..start();
    await http.request('HEAD', 'bucket');
    expect(clock.elapsedMilliseconds, greaterThanOrEqualTo(900));
    expect(attempts, 2);
    final scope = ActionScope(inheritParent: false);
    addTearDown(scope.dispose);
    handler = (request) async {
      await request.drain<void>();
      request.response.statusCode = 429;
      request.response.headers.set('retry-after', '30');
      Timer(const Duration(milliseconds: 50), scope.cancel);
    };
    await expectLater(scope.run(() => http.request('HEAD', 'bucket')),
        throwsA(isA<ListingCancelled>()));
    expect(scope.activeListenerCount, 0);
  });

  test('downloads stream the configured ranges to disk', () async {
    const size = 11 * 1024 * 1024;
    final ranges = <String>[];
    handler = (request) async {
      await request.drain<void>();
      request.response.headers.set('etag', '"source"');
      if (request.method == 'HEAD') {
        request.response.contentLength = size;
      } else {
        final range = request.headers.value('range')!;
        ranges.add(range);
        final parts = range.substring(6).split('-').map(int.parse).toList();
        final count = parts[1] - parts[0] + 1;
        request.response.statusCode = 206;
        request.response.headers
            .set('content-range', 'bytes ${parts[0]}-${parts[1]}/$size');
        request.response.contentLength = count;
        final chunk = Uint8List(64 * 1024);
        for (var n = 0; n < count; n += chunk.length) {
          request.response
              .add(chunk.sublist(0, (count - n).clamp(0, chunk.length)));
        }
      }
    };
    final directory = await Directory.systemTemp.createTemp('mobile-ranges');
    addTearDown(() => directory.delete(recursive: true));
    final result = await admin.downloadStorageObject(profile, {
      'bucketName': 'bucket',
      'key': 'data',
      'destinationDirectory': directory.path,
      'multipartChunkMiB': 6
    });
    expect(
        ranges, unorderedEquals(['bytes=0-6291455', 'bytes=6291456-11534335']));
    expect(await File(result['path'] as String).length(), size);
  });

  test('invalid download names fail without spinning or retaining staging data',
      () async {
    handler = (request) async {
      await request.drain<void>();
      request.response.headers.set('etag', '"source"');
      request.response.contentLength = 0;
    };
    final directory =
        await Directory.systemTemp.createTemp('mobile-invalid-name');
    addTearDown(() => directory.delete(recursive: true));
    await expectLater(
        admin.downloadStorageObject(profile, {
          'bucketName': 'bucket',
          'key': 'x' * 300,
          'destinationDirectory': directory.path
        }).timeout(const Duration(seconds: 2)),
        throwsA(isA<FileSystemException>()));
    expect(await directory.list().toList(), isEmpty);
  });

  test('upload threshold is independent of part size', () async {
    final calls = <String>[];
    handler = (request) async {
      await request.drain<void>();
      calls.add(
          '${request.method} ${request.uri.queryParameters.keys.join(',')}');
      request.response.headers.set('etag', '"part"');
      if (request.uri.queryParameters.containsKey('uploads')) {
        request.response.write(
            '<InitiateMultipartUploadResult><UploadId>upload</UploadId></InitiateMultipartUploadResult>');
      } else if (request.method == 'POST') {
        request.response.write(
            '<CompleteMultipartUploadResult><ETag>"done"</ETag></CompleteMultipartUploadResult>');
      }
    };
    final directory = await Directory.systemTemp.createTemp('mobile-threshold');
    addTearDown(() => directory.delete(recursive: true));
    final file = File('${directory.path}/source');
    await file.writeAsBytes(Uint8List(6 * 1024 * 1024));
    final args = <String, Object?>{
      'bucketName': 'bucket',
      'filePaths': [file.path],
      'multipartChunkMiB': 5
    };
    await admin
        .uploadStorageFile(profile, {...args, 'multipartThresholdMiB': 32});
    expect(calls, ['PUT ']);
    calls.clear();
    await admin
        .uploadStorageFile(profile, {...args, 'multipartThresholdMiB': 5});
    expect(calls.where((call) => call.startsWith('PUT')).length, 2);
    expect(calls.where((call) => call.startsWith('POST')).length, 2);
    calls.clear();
    await file.writeAsBytes(Uint8List(5 * 1024 * 1024));
    await admin.uploadStorageFile(
        profile, {...args, 'multipartChunkMiB': 8, 'multipartThresholdMiB': 5});
    expect(calls.where((call) => call.startsWith('PUT')).length, 1);
    expect(calls.where((call) => call.startsWith('POST')).length, 2);
  });

  test('eligible replacement copies use a conditional provider copy', () async {
    var bodyGets = 0, copies = 0;
    handler = (request) async {
      await request.drain<void>();
      if (request.method == 'HEAD') {
        request.response.contentLength = 4;
        request.response.headers.set(
            'etag', request.uri.path.endsWith('/src') ? '"source"' : '"dest"');
      } else if (request.method == 'GET' &&
          request.uri.queryParameters.containsKey('tagging')) {
        request.response.write('<Tagging><TagSet/></Tagging>');
      } else if (request.method == 'PUT') {
        copies++;
        expect(request.headers.value('x-amz-copy-source'), '/bucket/src');
        expect(request.headers.value('x-amz-copy-source-if-match'), '"source"');
        request.response
            .write('<CopyObjectResult><ETag>"dest"</ETag></CopyObjectResult>');
      } else {
        bodyGets++;
      }
    };
    final result = await admin.copyStorageObject(profile, profile, {
      'sourceBucketName': 'bucket',
      'sourceKey': 'src',
      'destinationBucketName': 'bucket',
      'destinationKey': 'dst',
      'conflictPolicy': 'replace'
    });
    expect(result['successCount'], 1);
    expect(copies, 1);
    expect(bodyGets, 0);
  });
}
