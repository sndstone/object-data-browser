import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:xml/xml.dart';
import 'package:s3_browser_crossplat/models/domain_models.dart';
import 'package:s3_browser_crossplat/services/mobile_storage_admin.dart';
import 'package:s3_browser_crossplat/services/storage_http_client.dart';

void main() {
  late HttpServer server;
  late EndpointProfile profile;
  late MobileStorageAdmin admin;
  late Future<void> Function(HttpRequest) handle;
  setUp(() async {
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    profile = EndpointProfile.fromJson({
      'id': 'fixture',
      'endpointUrl': 'http://127.0.0.1:${server.port}',
      'accessKey': 'fixture',
      'secretKey': 'fixture',
      'region': 'us-east-1',
      'pathStyle': true,
      'maxAttempts': 1,
      'maxConcurrentRequests': 2
    });
    admin = MobileStorageAdmin();
    handle = (_) async => fail('Unexpected request');
    server.listen((request) async {
      try {
        await handle(request);
      } finally {
        await request.response.close();
      }
    });
  });
  tearDown(() async {
    admin.close();
    await server.close(force: true);
  });

  test('selection deletes chunk at 1000 and retain exact partial failures',
      () async {
    final sizes = <int>[];
    handle = (request) async {
      expect(request.method, 'POST');
      expect(request.uri.queryParameters.containsKey('delete'), isTrue);
      final body = XmlDocument.parse(await utf8.decoder.bind(request).join())
          .rootElement;
      final objects =
          body.childElements.where((e) => e.name.local == 'Object').toList();
      sizes.add(objects.length);
      request.response.write('<DeleteResult>${objects.map((o) {
        final key = xmlText(o, 'Key');
        return key == 'key-1000'
            ? '<Error><Key>$key</Key><Code>AccessDenied</Code><Message>denied</Message></Error>'
            : '<Deleted><Key>$key</Key></Deleted>';
      }).join()}</DeleteResult>');
    };
    final result = await admin.dispatch('deleteObjects', {
      'profile': profile.toJson(),
      'bucketName': 'bucket',
      'keys': List.generate(1001, (i) => 'key-$i')
    });
    expect(sizes, [1000, 1]);
    expect(result['successCount'], 1000);
    expect(result['failureCount'], 1);
    expect((result['failures'] as List).single, {
      'target': 'key-1000',
      'versionId': null,
      'code': 'AccessDenied',
      'message': 'denied'
    });
  });

  test('XML-safe browsing decodes keys once and leaves opaque cursors alone',
      () async {
    const key = 'a%2Fb+雪\u0001';
    const token = 'opaque+%2F';
    handle = (request) async {
      await request.drain<void>();
      expect(request.uri.queryParameters['encoding-type'], 'url');
      request.response.write(
          '<ListBucketResult><EncodingType>url</EncodingType><Contents><Key>${Uri.encodeComponent(key)}</Key><Size>1</Size></Contents><IsTruncated>true</IsTruncated><NextContinuationToken>$token</NextContinuationToken></ListBucketResult>');
    };
    final result = await admin
        .listObjects(profile, {'bucketName': 'bucket', 'flat': true});
    expect(((result['items'] as List).single as Map)['key'], key);
    expect((result['nextCursor'] as Map)['value'], token);
  });

  test('Intelligent-Tiering restores omit expiration', () async {
    String? body;
    handle = (request) async {
      if (request.method == 'HEAD') {
        await request.drain<void>();
        request.response.headers
            .set('x-amz-storage-class', 'INTELLIGENT_TIERING');
      } else {
        body = await utf8.decoder.bind(request).join();
      }
    };
    await admin.action(
        profile: profile,
        action: 'restoreObject',
        arguments: {'bucketName': 'bucket', 'key': 'key', 'days': 7});
    expect(body, contains('<Tier>Standard</Tier>'));
    expect(body, isNot(contains('<Days>')));
  });

  test('historical same-key restore permits literal null version', () async {
    var copied = false;
    handle = (request) async {
      await request.drain<void>();
      request.response.headers.set('etag', copied ? '"new"' : '"old"');
      if (request.method == 'HEAD') {
        request.response.contentLength = 3;
      } else if (request.uri.queryParameters.containsKey('tagging')) {
        request.response.write('<Tagging><TagSet/></Tagging>');
      } else if (request.method == 'GET') {
        expect(request.uri.queryParameters['versionId'], 'null');
        request.response.statusCode = 206;
        request.response.headers.set('content-range', 'bytes 0-2/3');
        request.response.write('old');
      } else if (request.method == 'PUT') {
        copied = true;
        request.response.headers.set('etag', '"new"');
      }
    };
    final result =
        await admin.action(profile: profile, action: 'copyObject', arguments: {
      'sourceBucketName': 'bucket',
      'sourceKey': 'key',
      'sourceVersionId': 'null',
      'destinationBucketName': 'bucket',
      'destinationKey': 'key',
      'conflictPolicy': 'replace'
    });
    expect(copied, isTrue);
    expect(result['successCount'], 1);
  });

  test('parallel range downloads stay bounded and publish correct offsets',
      () async {
    const part = 5 * 1024 * 1024, size = part * 3;
    var active = 0, peak = 0;
    handle = (request) async {
      await request.drain<void>();
      request.response.headers.set('etag', '"source"');
      if (request.method == 'HEAD') {
        request.response.contentLength = size;
        return;
      }
      active++;
      if (active > peak) peak = active;
      await Future<void>.delayed(const Duration(milliseconds: 50));
      final bounds = request.headers
          .value('range')!
          .substring(6)
          .split('-')
          .map(int.parse)
          .toList();
      request.response.statusCode = 206;
      request.response.headers
          .set('content-range', 'bytes ${bounds[0]}-${bounds[1]}/$size');
      request.response.contentLength = bounds[1] - bounds[0] + 1;
      final chunk = Uint8List(64 * 1024)
        ..fillRange(0, 64 * 1024, bounds[0] ~/ part + 1);
      for (var offset = bounds[0];
          offset <= bounds[1];
          offset += chunk.length) {
        request.response.add(
            chunk.sublist(0, (bounds[1] - offset + 1).clamp(0, chunk.length)));
      }
      await request.response.flush();
      active--;
    };
    final directory = await Directory.systemTemp.createTemp('review-ranges-');
    addTearDown(() => directory.delete(recursive: true));
    final result = await admin.downloadStorageObject(profile, {
      'bucketName': 'bucket',
      'key': 'key',
      'destinationDirectory': directory.path,
      'multipartChunkMiB': 5
    });
    expect(peak, 2);
    final file = await File(result['path'] as String).open();
    try {
      expect(await file.length(), size);
      for (var i = 0; i < 3; i++) {
        await file.setPosition(i * part);
        expect(await file.readByte(), i + 1);
      }
    } finally {
      await file.close();
    }
  });

  test('multipart uploads publish stable intermediate progress', () async {
    final events = <Map<String, Object?>>[];
    admin.onTransfer = events.add;
    handle = (request) async {
      await request.drain<void>();
      if (request.uri.queryParameters.containsKey('uploads')) {
        request.response.write(
            '<InitiateMultipartUploadResult><UploadId>upload</UploadId></InitiateMultipartUploadResult>');
      } else if (request.method == 'PUT') {
        request.response.headers.set('etag', '"part"');
      } else {
        request.response.write(
            '<CompleteMultipartUploadResult><ETag>"done"</ETag></CompleteMultipartUploadResult>');
      }
    };
    final directory = await Directory.systemTemp.createTemp('review-progress-');
    addTearDown(() => directory.delete(recursive: true));
    final file = await File('${directory.path}/data')
        .writeAsBytes(Uint8List(11 * 1024 * 1024));
    final result = await admin.dispatch('startUpload', {
      'profile': profile.toJson(),
      'bucketName': 'bucket',
      'filePaths': [file.path],
      'multipartThresholdMiB': 1,
      'multipartChunkMiB': 6
    });
    expect(events.map((event) => event['id']).toSet(), {result['id']});
    expect(
        events.any((event) =>
            event['status'] == 'running' &&
            (event['bytesTransferred'] as int) > 0 &&
            (event['bytesTransferred'] as int) < (event['totalBytes'] as int)),
        isTrue);
    expect(events.last['status'], 'completed');
    expect(result['bytesTransferred'], 11 * 1024 * 1024);
  });

  test(
      'property rewrites preserve ACL and lock headers and stop on denied reads',
      () async {
    var copied = false, deny = false, writes = 0;
    handle = (request) async {
      await request.drain<void>();
      final query = request.uri.queryParameters;
      request.response.headers.set('etag', copied ? '"new"' : '"old"');
      if (request.method == 'HEAD') {
        request.response.contentLength = 3;
      } else if (query.containsKey('ownershipControls')) {
        request.response.write(
            '<OwnershipControls><Rule><ObjectOwnership>ObjectWriter</ObjectOwnership></Rule></OwnershipControls>');
      } else if (query.containsKey('acl')) {
        if (deny) {
          request.response.statusCode = 403;
          request.response.write('<Error><Code>AccessDenied</Code></Error>');
        } else {
          request.response.write(
              '<AccessControlPolicy><AccessControlList><Grant><Grantee><ID>owner</ID></Grantee><Permission>FULL_CONTROL</Permission></Grant><Grant><Grantee><URI>http://acs.amazonaws.com/groups/global/AllUsers</URI></Grantee><Permission>READ</Permission></Grant></AccessControlList></AccessControlPolicy>');
        }
      } else if (query.containsKey('object-lock')) {
        request.response.write(
            '<ObjectLockConfiguration><ObjectLockEnabled>Enabled</ObjectLockEnabled></ObjectLockConfiguration>');
      } else if (query.containsKey('retention')) {
        request.response.write(
            '<Retention><Mode>COMPLIANCE</Mode><RetainUntilDate>2030-01-01T00:00:00Z</RetainUntilDate></Retention>');
      } else if (query.containsKey('legal-hold')) {
        request.response.write('<LegalHold><Status>ON</Status></LegalHold>');
      } else if (query.containsKey('tagging')) {
        request.response.write('<Tagging><TagSet/></Tagging>');
      } else if (request.method == 'GET') {
        request.response.statusCode = 206;
        request.response.headers.set('content-range', 'bytes 0-2/3');
        request.response.write('old');
      } else if (request.method == 'PUT') {
        writes++;
        expect(request.headers.value('x-amz-grant-read'),
            'uri="http://acs.amazonaws.com/groups/global/AllUsers"');
        expect(request.headers.value('x-amz-object-lock-mode'), 'COMPLIANCE');
        expect(request.headers.value('x-amz-object-lock-legal-hold'), 'ON');
        copied = true;
        request.response.headers.set('etag', '"new"');
      }
    };
    final args = {
      'bucketName': 'bucket',
      'key': 'key',
      'metadata': {'owner': 'team'}
    };
    await admin.action(
        profile: profile, action: 'objectProperties', arguments: args);
    expect(writes, 1);
    deny = true;
    await expectLater(
        admin.action(
            profile: profile, action: 'objectProperties', arguments: args),
        throwsStateError);
    expect(writes, 1);
  });

  test('region recovery trusts AWS origins and keeps credential partitions',
      () {
    final aws = profile.copyWith(
        endpointType: EndpointProfileType.awsS3,
        endpointUrl: 'https://s3.amazonaws.com');
    StorageHttpResponse response(String region) =>
        StorageHttpResponse(301, {'x-amz-bucket-region': region}, Uint8List(0));
    expect(storageAwsRedirectRegion(aws, 'bucket', response('eu-west-1')),
        'eu-west-1');
    expect(storageAwsRedirectRegion(aws, 'bucket', response('cn-north-1')),
        isNull);
    expect(
        storageAwsRedirectRegion(
            aws.copyWith(endpointUrl: 'https://s3.amazonaws.com.attacker.test'),
            'bucket',
            response('eu-west-1')),
        isNull);
    expect(storageAwsRedirectRegion(profile, 'bucket', response('eu-west-1')),
        isNull);
  });
}
