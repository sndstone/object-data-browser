import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:s3_browser_crossplat/models/domain_models.dart';
import 'package:s3_browser_crossplat/services/mobile_storage_admin.dart';

void main() {
  late HttpServer server;
  late MobileStorageAdmin admin;
  late EndpointProfile profile;
  final writes = <Map<String, String>>[];
  var genericMissing = false;
  setUp(() async {
    writes.clear();
    genericMissing = false;
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    profile = EndpointProfile.fromJson({
      'id': 'fixture',
      'endpointType': 's3Compatible',
      'endpointUrl': 'http://127.0.0.1:${server.port}',
      'region': 'us-east-1',
      'accessKey': 'local',
      'secretKey': 'secret'
    });
    admin = MobileStorageAdmin();
    server.listen((request) async {
      await request.drain<void>();
      final response = request.response;
      response.headers.set('etag', '"source"');
      if (request.uri.path == '/bucket/key' && request.method == 'HEAD') {
        response.headers.set('content-length', '3');
        response.headers.set('content-encoding', 'gzip');
        response.headers.set('content-language', 'en');
        response.headers.set('cache-control', 'max-age=300');
        response.headers.set('x-amz-server-side-encryption', 'aws:kms');
        response.headers
            .set('x-amz-server-side-encryption-aws-kms-key-id', 'old-key');
      } else if (request.uri.queryParameters.containsKey('tagging') &&
          request.uri.path.endsWith('/key')) {
        response.write('<Tagging><TagSet/></Tagging>');
      } else if (request.method == 'GET' && request.uri.path.endsWith('/key')) {
        response.statusCode = 206;
        response.headers.set('content-range', 'bytes 0-2/3');
        response.write('abc');
      } else if (request.method == 'PUT') {
        writes.add({
          for (final name in [
            'x-amz-server-side-encryption',
            'x-amz-server-side-encryption-aws-kms-key-id',
            'if-match',
            'content-encoding',
            'content-language',
            'cache-control',
            'x-amz-transition-default-minimum-object-size'
          ])
            if (request.headers.value(name) != null)
              name: request.headers.value(name)!
        });
      } else if (request.uri.queryParameters.containsKey('lifecycle')) {
        if (genericMissing) {
          response.statusCode = 404;
          response.write('<html>Not found</html>');
        } else {
          response.headers.set('x-amz-transition-default-minimum-object-size',
              'varies_by_storage_class');
          response.write(
              '<LifecycleConfiguration><Rule><ID>keep</ID><Status>Enabled</Status><Filter><Prefix>x/</Prefix></Filter><Expiration><Days>365</Days></Expiration></Rule></LifecycleConfiguration>');
        }
      } else {
        response.statusCode = 404;
        response.write('<Error><Code>NoSuchBucketPolicy</Code></Error>');
      }
      await response.close();
    });
  });
  tearDown(() async {
    admin.close();
    await server.close(force: true);
  });
  test(
      'property edits preserve unedited content headers, KMS and source condition',
      () async {
    await admin
        .action(profile: profile, action: 'objectProperties', arguments: {
      'bucketName': 'bucket',
      'key': 'key',
      'expectedETag': '"source"',
      'headers': {'Cache-Control': ''}
    });
    expect(writes.single['content-encoding'], 'gzip');
    expect(writes.single['content-language'], 'en');
    expect(writes.single.containsKey('cache-control'), isFalse);
    expect(writes.single['x-amz-server-side-encryption'], 'aws:kms');
    expect(writes.single['x-amz-server-side-encryption-aws-kms-key-id'],
        'old-key');
    expect(writes.single['if-match'], '"source"');
  });
  test('encryption uses shared UI field names and clears obsolete KMS headers',
      () async {
    await admin
        .action(profile: profile, action: 'objectProperties', arguments: {
      'bucketName': 'bucket',
      'key': 'key',
      'encryption': {'ServerSideEncryption': 'AES256'}
    });
    expect(writes.single['x-amz-server-side-encryption'], 'AES256');
    expect(
        writes.single
            .containsKey('x-amz-server-side-encryption-aws-kms-key-id'),
        isFalse);
  });
  test(
      'lifecycle inspection preserves transition behavior and generic404 is unknown',
      () async {
    final state = await admin.bucketAdmin(profile, 'bucket');
    expect(
        state['transitionDefaultMinimumObjectSize'], 'varies_by_storage_class');
    final rules = jsonDecode(state['lifecycleJson'] as String);
    await admin.action(profile: profile, action: 'putLifecycle', arguments: {
      'bucketName': 'bucket',
      'lifecycleJson': jsonEncode(rules),
      'expectedLifecycleJson': jsonEncode(rules),
      'transitionDefaultMinimumObjectSize':
          state['transitionDefaultMinimumObjectSize']
    });
    expect(writes.single['x-amz-transition-default-minimum-object-size'],
        'varies_by_storage_class');
    genericMissing = true;
    final missing = await admin.bucketAdmin(profile, 'bucket');
    expect(
        (missing['sections'] as Map)['GetBucketLifecycleConfiguration']
            ['state'],
        'unknown');
    await expectLater(
        admin.action(profile: profile, action: 'putLifecycle', arguments: {
          'bucketName': 'bucket',
          'lifecycleJson': jsonEncode(rules),
          'expectedLifecycleJson': '{}'
        }),
        throwsA(isA<EngineException>()));
    expect(writes, hasLength(1));
  });
  test('same-object move is rejected before mutation', () async {
    await expectLater(
        admin.copyStorageObject(profile, profile, {
          'sourceBucketName': 'bucket',
          'destinationBucketName': 'bucket',
          'sourceKey': 'key',
          'destinationKey': 'key',
          'move': true
        }),
        throwsA(isA<EngineException>()));
    expect(writes, isEmpty);
  });
}
