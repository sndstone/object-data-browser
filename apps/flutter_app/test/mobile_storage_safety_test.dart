import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:s3_browser_crossplat/models/domain_models.dart';
import 'package:s3_browser_crossplat/services/mobile_storage_admin.dart';

void main() {
  late HttpServer server;
  late MobileStorageAdmin admin;
  late EndpointProfile profile;
  final writes = <Map<String, String>>[];
  var genericMissing = false;
  var aclEnabled = false;
  var dropGrants = false;
  var revokeOnAclRead = 0;
  var aclReads = 0;
  var deletes = 0;
  var sourceHeads = 0;
  var versionChanges = false;
  var denyDestinationHead = false;
  var rejectDelete = false;
  var sourceSize = 3;
  var putBytes = 0;
  var ownerOnly = false;
  var etagChanges = false;
  var multipartStarts = 0;
  setUp(() async {
    writes.clear();
    genericMissing = false;
    aclEnabled = false;
    dropGrants = false;
    revokeOnAclRead = 0;
    aclReads = 0;
    deletes = 0;
    sourceHeads = 0;
    versionChanges = false;
    denyDestinationHead = false;
    rejectDelete = false;
    sourceSize = 3;
    putBytes = 0;
    ownerOnly = false;
    etagChanges = false;
    multipartStarts = 0;
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
      await for (final bytes in request) {
        if (request.method == 'PUT') putBytes += bytes.length;
      }
      final response = request.response;
      response.headers.set('etag', '"source"');
      if (denyDestinationHead &&
          request.uri.path == '/bucket/moved' &&
          request.method == 'HEAD' &&
          writes.isNotEmpty) {
        response.statusCode = 403;
      } else if (request.uri.path == '/bucket/moved' &&
          request.method == 'HEAD' &&
          writes.isEmpty) {
        response.statusCode = 404;
      } else if (request.method == 'HEAD' &&
          {'/bucket/key', '/bucket/moved'}.contains(request.uri.path)) {
        if (request.uri.path == '/bucket/key' && (versionChanges || etagChanges)) {
          sourceHeads++;
          if (versionChanges) {
            response.headers
                .set('x-amz-version-id', sourceHeads == 1 ? 'old' : 'new');
          }
          if (etagChanges && sourceHeads > 1) {
            response.headers.set('etag', '"other"');
          }
        }
        response.headers.set('content-length', '$sourceSize');
        response.headers.set('content-encoding', 'gzip');
        response.headers.set('content-language', 'en');
        response.headers.set('cache-control', 'max-age=300');
        response.headers.set('x-amz-server-side-encryption', 'aws:kms');
        response.headers
            .set('x-amz-server-side-encryption-aws-kms-key-id', 'old-key');
      } else if (request.uri.queryParameters.containsKey('ownershipControls')) {
        final ownership = aclEnabled ? 'ObjectWriter' : 'BucketOwnerEnforced';
        response.write(
            '<OwnershipControls><Rule><ObjectOwnership>$ownership</ObjectOwnership></Rule></OwnershipControls>');
      } else if (request.uri.queryParameters.containsKey('acl')) {
        const owner =
            '<Grant><Grantee><ID>owner</ID></Grantee><Permission>FULL_CONTROL</Permission></Grant>';
        const reader =
            '<Grant><Grantee><ID>reader</ID></Grantee><Permission>READ</Permission></Grant>';
        aclReads++;
        final lost = (dropGrants && writes.isNotEmpty) ||
            revokeOnAclRead == aclReads;
        final grants = lost || ownerOnly ? owner : owner + reader;
        response.write(
            '<AccessControlPolicy><Owner><ID>owner</ID></Owner><AccessControlList>$grants</AccessControlList></AccessControlPolicy>');
      } else if (request.uri.queryParameters['list-type'] == '2') {
        response.write(
            '<ListBucketResult><EncodingType>url</EncodingType><Contents><Key>a+%2B+b</Key><Size>1</Size></Contents></ListBucketResult>');
      } else if (request.uri.queryParameters.containsKey('object-lock')) {
        response.statusCode = 404;
        response.write(
            '<Error><Code>ObjectLockConfigurationNotFoundError</Code></Error>');
      } else if (request.uri.queryParameters.containsKey('tagging') &&
          request.uri.path.endsWith('/key')) {
        response.write('<Tagging><TagSet/></Tagging>');
      } else if (request.method == 'GET' && request.uri.path.endsWith('/key')) {
        response.statusCode = 206;
        final range = request.headers.value('range')!.substring(6).split('-');
        final start = int.parse(range[0]), end = int.parse(range[1]);
        response.headers.set('content-range', 'bytes $start-$end/$sourceSize');
        if (sourceSize == 3) {
          response.write('abc');
        } else {
          response.add(Uint8List(end - start + 1));
        }
      } else if (request.uri.queryParameters.containsKey('uploads')) {
        multipartStarts++;
        response.statusCode = 403;
        response.write('<Error><Code>AccessDenied</Code></Error>');
      } else if (request.method == 'PUT') {
        writes.add({
          for (final name in [
            'x-amz-server-side-encryption',
            'x-amz-server-side-encryption-aws-kms-key-id',
            'if-match',
            'x-amz-grant-read',
            'content-encoding',
            'content-language',
            'cache-control',
            'x-amz-transition-default-minimum-object-size'
          ])
            if (request.headers.value(name) != null)
              name: request.headers.value(name)!
        });
      } else if (request.method == 'DELETE') {
        deletes++;
        if (rejectDelete) {
          response.statusCode = 412;
          response.write('<Error><Code>PreconditionFailed</Code></Error>');
        }
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
  test('encoded listings distinguish spaces from literal plus signs', () async {
    final result = await admin.listObjects(profile, {'bucketName': 'bucket'});
    expect((result['items'] as List).single['key'], 'a + b');
  });
  for (final losesGrant in [false, true]) {
    test('property edit verifies object ACL (lost grant: $losesGrant)', () async {
      aclEnabled = true;
      dropGrants = losesGrant;
      final result = await admin.action(
          profile: profile, action: 'objectProperties', arguments: {
        'bucketName': 'bucket',
        'key': 'key',
        'metadata': {'updated': 'true'},
      });
      if (losesGrant) {
        expect(result['requiresVerification'], isTrue);
        expect((result['failures'] as List).single['code'], 'acl_unverified');
      } else {
        expect(result['successCount'], 1);
      }
      expect(writes.single['x-amz-grant-read'], 'id="reader"');
    });
  }
  test('same ETag with a revoked ACL stops the edit before writing', () async {
    aclEnabled = true;
    revokeOnAclRead = 2;
    await expectLater(
        admin.action(
            profile: profile, action: 'objectProperties', arguments: {
          'bucketName': 'bucket',
          'key': 'key',
          'metadata': {'updated': 'true'},
        }),
        throwsA(isA<EngineException>().having((error) => error.message,
            'message', contains('source ACL changed'))));
    expect(writes, isEmpty);
  });
  test('new current version with the same ETag stops the edit', () async {
    aclEnabled = true;
    versionChanges = true;
    await expectLater(
        admin.action(
            profile: profile, action: 'objectProperties', arguments: {
          'bucketName': 'bucket',
          'key': 'key',
          'metadata': {'updated': 'true'},
        }),
        throwsA(isA<EngineException>().having((error) => error.message,
            'message', contains('current source version changed'))));
    expect(writes, isEmpty);
  });
  test('an ACL-bearing edit above the multipart threshold uses one PUT',
      () async {
    aclEnabled = true;
    sourceSize = 9 * 1024 * 1024;
    final result = await admin.action(
        profile: profile, action: 'objectProperties', arguments: {
      'bucketName': 'bucket',
      'key': 'key',
      'metadata': {'edited': 'yes'},
    });
    expect(result['successCount'], 1);
    expect(aclReads, 3);
    expect(putBytes, sourceSize);
    expect(writes.single['x-amz-grant-read'], 'id="reader"');
    expect(writes.single['if-match'], '"source"');
  });
  test('an unversioned ETag change stops a guarded edit before publication',
      () async {
    aclEnabled = true;
    etagChanges = true;
    await expectLater(
        admin.action(profile: profile, action: 'objectProperties', arguments: {
          'bucketName': 'bucket',
          'key': 'key',
          'metadata': {'edited': 'yes'},
        }),
        throwsA(isA<EngineException>().having((error) => error.message,
            'message', contains('source ETag changed'))));
    expect(writes, isEmpty);
  });
  test('a large owner-only ACL edit can still start multipart upload', () async {
    aclEnabled = true;
    ownerOnly = true;
    sourceSize = 5 * 1024 * 1024 * 1024 + 1;
    await expectLater(
        admin.action(profile: profile, action: 'objectProperties', arguments: {
          'bucketName': 'bucket',
          'key': 'key',
          'metadata': {'edited': 'yes'},
        }),
        throwsA(anything));
    expect(multipartStarts, 1);
    expect(writes, isEmpty);
  });
  test('compatible move with no selected version stops before writing',
      () async {
    aclEnabled = true;
    await expectLater(
        admin.copyStorageObject(profile, profile, {
          'sourceBucketName': 'bucket',
          'sourceKey': 'key',
          'destinationBucketName': 'bucket',
          'destinationKey': 'moved',
          'move': true,
          'options': {'preserveObjectProtection': true},
        }),
        throwsA(isA<EngineException>()));
    expect(writes, isEmpty);
    expect(deletes, 0);
  });
  for (final failure in ['acl_unverified', 'source_acl_unverified', 'destination_unverified']) {
    test('move retains source on verification failure ($failure)', () async {
      aclEnabled = true;
      profile = profile.copyWith(endpointType: EndpointProfileType.awsS3);
      dropGrants = failure == 'acl_unverified';
      revokeOnAclRead = failure == 'source_acl_unverified' ? 4 : 0;
      denyDestinationHead = failure == 'destination_unverified';
      final result = await admin.copyStorageObject(profile, profile, {
        'sourceBucketName': 'bucket',
        'sourceKey': 'key',
        'destinationBucketName': 'bucket',
        'destinationKey': 'moved',
        'conflictPolicy': 'fail',
        'move': true,
        'options': {'preserveObjectProtection': true},
      });
      expect(result['requiresVerification'], isTrue);
      expect(result['sourceRetained'], isTrue);
      expect((result['failures'] as List).single['code'], failure);
      expect(writes, hasLength(1));
      expect(deletes, 0);
    });
  }
  test('a move with a rejected delete reports the written destination', () async {
    aclEnabled = true;
    profile = profile.copyWith(endpointType: EndpointProfileType.awsS3);
    rejectDelete = true;
    final result = await admin.copyStorageObject(profile, profile, {
      'sourceBucketName': 'bucket',
      'sourceKey': 'key',
      'destinationBucketName': 'bucket',
      'destinationKey': 'moved',
      'conflictPolicy': 'skip',
      'move': true,
      'options': {'preserveObjectProtection': true},
    });
    expect(result['skipped'], isNot(true));
    expect(result['failureCount'], 1);
    expect(result['copiedCount'], 1);
    expect(result['sourceRetained'], isTrue);
    expect((result['failures'] as List).single['code'], 'source_delete_failed');
    expect(writes, hasLength(1));
    expect(deletes, 1);
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
