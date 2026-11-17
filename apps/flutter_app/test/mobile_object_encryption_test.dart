import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:s3_browser_crossplat/models/domain_models.dart';
import 'package:s3_browser_crossplat/services/mobile_storage_admin.dart';

void main() {
  for (final azure in [false, true]) {
    group(azure ? 'Azure encryption headers' : 'S3 encryption headers', () {
      late HttpServer server;
      late MobileStorageAdmin admin;
      late EndpointProfile profile;
      late Directory directory;
      late List<({String method, Uri uri, Map<String, String> headers})>
          requests;
      final keyBytes = List.filled(32, 9);
      final encoded = base64Encode(keyBytes);
      final encryption = {
        'mode': azure ? 'azure-cpk' : 'sse-c',
        'customerKey': encoded
      };
      setUp(() async {
        requests = [];
        directory = await Directory.systemTemp.createTemp('mobile-encryption-');
        server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        profile = EndpointProfile(
            id: 'fixture',
            name: 'Fixture',
            endpointUrl: 'http://127.0.0.1:${server.port}',
            region: 'us-east-1',
            accessKey: 'test',
            secretKey: azure ? base64Encode(utf8.encode('secret')) : 'secret',
            endpointType: azure
                ? EndpointProfileType.azureBlob
                : EndpointProfileType.s3Compatible,
            pathStyle: true,
            verifyTls: true,
            maxAttempts: 1);
        admin = MobileStorageAdmin();
        server.listen((request) async {
          await request.drain<void>();
          final headers = <String, String>{};
          request.headers
              .forEach((name, values) => headers[name] = values.join(','));
          requests.add(
              (method: request.method, uri: request.uri, headers: headers));
          final response = request.response;
          response.headers.set('etag', '"fixture"');
          final q = request.uri.queryParameters;
          if (request.method == 'HEAD') {
            response.contentLength = 3;
            response.headers.set(
                azure
                    ? 'x-ms-encryption-key-sha256'
                    : 'x-amz-server-side-encryption-customer-key-md5',
                base64Encode((azure ? sha256 : md5).convert(keyBytes).bytes));
            if (azure) {
              response.headers.set('x-ms-server-encrypted', 'true');
            } else {
              response.headers.set(
                  'x-amz-server-side-encryption-customer-algorithm', 'AES256');
            }
          } else if (request.method == 'POST' && q.containsKey('uploads')) {
            response.write(
                '<InitiateMultipartUploadResult><UploadId>fixture</UploadId></InitiateMultipartUploadResult>');
          } else if (request.method == 'POST' && q.containsKey('uploadId')) {
            response.write(
                '<CompleteMultipartUploadResult><ETag>"fixture"</ETag></CompleteMultipartUploadResult>');
          } else if (q.containsKey('tagging') || q['comp'] == 'tags') {
            response.write('<Tagging><TagSet/></Tagging>');
          } else if (request.method == 'GET') {
            response.statusCode = 206;
            response.headers.set('content-range', 'bytes 0-2/3');
            response.write('abc');
          } else if (headers.containsKey('x-amz-copy-source')) {
            response.write(
                '<CopyObjectResult><ETag>"fixture"</ETag></CopyObjectResult>');
          }
          await response.close();
        });
      });
      tearDown(() async {
        admin.close();
        await server.close(force: true);
        await directory.delete(recursive: true);
      });

      Future<Map<String, Object?>> dispatch(
              String method, Map<String, Object?> args) =>
          admin.dispatch(method, {
            'profile': profile.toJson(),
            'bucketName': 'bucket',
            ...args,
          });
      void expectHeaders(Map<String, String> actual, {bool source = false}) {
        final prefix = source
            ? 'x-amz-copy-source-server-side-encryption-customer-'
            : 'x-amz-server-side-encryption-customer-';
        final expected = azure
            ? <String, String>{
                'x-ms-encryption-algorithm': 'AES256',
                'x-ms-encryption-key': encoded,
                'x-ms-encryption-key-sha256':
                    base64Encode(sha256.convert(keyBytes).bytes),
              }
            : <String, String>{
                '${prefix}algorithm': 'AES256',
                '${prefix}key': encoded,
                '${prefix}key-md5': base64Encode(md5.convert(keyBytes).bytes),
              };
        for (final header in expected.entries) {
          expect(actual[header.key], header.value, reason: header.key);
          if (!azure) expect(actual['authorization'], contains(header.key));
        }
      }

      Future<void> upload({Object? setting, int size = 3}) async {
        final file =
            await File('${directory.path}/upload').open(mode: FileMode.write);
        await file.truncate(size);
        await file.close();
        await dispatch('startUpload', {
          'filePaths': ['${directory.path}/upload'],
          'prefix': '',
          'objectKeyByPath': const <String, String>{},
          'multipartThresholdMiB': 1,
          'multipartChunkMiB': 5,
          if (setting != null) 'encryption': setting
        });
      }

      test(
          'customer headers are exact and signed on single and multipart uploads',
          () async {
        await upload(setting: encryption);
        expectHeaders(requests.single.headers);
        requests.clear();
        await upload(setting: encryption, size: 6 * 1024 * 1024);
        final writes = requests
            .where((r) =>
                r.method == 'PUT' ||
                r.uri.queryParameters.containsKey('uploads'))
            .toList();
        expect(writes.length, greaterThanOrEqualTo(3));
        for (final request in writes) {
          expectHeaders(request.headers);
        }
      });
      test('HEAD GET folder and copy use customer-key headers', () async {
        final details = await dispatch(
            'getObjectDetails', {'key': 'source', 'encryption': encryption});
        expect((details['encryption'] as Map)['mode'], encryption['mode']);
        expectHeaders(requests.single.headers);
        requests.clear();
        await dispatch('startDownload', {
          'keys': ['source'],
          'destinationPath': directory.path,
          'encryption': encryption
        });
        for (final request in requests) {
          expectHeaders(request.headers);
        }
        expect(await File('${directory.path}/source').readAsString(), 'abc');
        requests.clear();
        await dispatch(
            'createFolder', {'key': 'folder/', 'encryption': encryption});
        expectHeaders(requests.single.headers);
        requests.clear();
        await dispatch('copyObject', {
          'sourceBucketName': 'bucket',
          'sourceKey': 'source',
          'destinationBucketName': 'bucket',
          'destinationKey': 'copy',
          'encryption': encryption,
          'sourceEncryption': encryption
        });
        expectHeaders(requests.first.headers);
        final writes = requests.where((r) => r.method == 'PUT').toList();
        expect(writes, isNotEmpty);
        for (final request in writes) {
          expectHeaders(request.headers);
        }
        if (!azure) expectHeaders(writes.single.headers, source: true);
      });
      test('omitted encryption sends no encryption headers', () async {
        await upload();
        await dispatch('createFolder', {'key': 'folder/'});
        await dispatch('getObjectDetails', {'key': 'source'});
        for (final request in requests) {
          expect(
              request.headers.keys.where((key) => key.contains('encryption')),
              isEmpty);
        }
      });
      test('customer-key presign and invalid encryption fail without a request',
          () async {
        await expectLater(
            dispatch('generatePresignedUrl',
                {'key': 'source', 'encryption': encryption}),
            throwsA(isA<EngineException>()
                .having((e) => e.code, 'code', ErrorCode.unsupportedFeature)));
        await expectLater(
            dispatch('createFolder', {
              'key': 'folder/',
              'encryption': {
                'mode': azure ? 'sse-s3' : 'azure-scope',
                'encryptionScope': 'scope'
              }
            }),
            throwsA(isA<EngineException>()));
        expect(requests, isEmpty);
      });
      if (!azure) {
        test(
            'SSE-S3 and DSSE-KMS use exact algorithms and omit DSSE bucket keys',
            () async {
          await dispatch('createFolder', {
            'key': 's3/',
            'encryption': {'mode': 'sse-s3'}
          });
          expect(
              requests.last.headers['x-amz-server-side-encryption'], 'AES256');
          await dispatch('createFolder', {
            'key': 'dsse/',
            'encryption': {'mode': 'dsse-kms', 'kmsKeyId': 'kms-key'}
          });
          expect(requests.last.headers['x-amz-server-side-encryption'],
              'aws:kms:dsse');
          expect(
              requests
                  .last.headers['x-amz-server-side-encryption-aws-kms-key-id'],
              'kms-key');
          expect(
              requests.last.headers.containsKey(
                  'x-amz-server-side-encryption-bucket-key-enabled'),
              isFalse);
          await dispatch('getObjectDetails', {
            'key': 'source',
            'encryption': {'mode': 'sse-kms'}
          });
          expect(
              requests.last.headers.keys
                  .where((key) => key.contains('encryption')),
              isEmpty);
        });
      }
      test(
          'managed encryption headers apply only to supported write operations',
          () async {
        final setting = azure
            ? {'mode': 'azure-scope', 'encryptionScope': 'scope'}
            : {
                'mode': 'sse-kms',
                'kmsKeyId': 'kms-key',
                'kmsEncryptionContext': {'purpose': 'test'},
                'bucketKeyEnabled': true
              };
        await upload(setting: setting, size: 6 * 1024 * 1024);
        final expected = azure
            ? <String, String>{'x-ms-encryption-scope': 'scope'}
            : <String, String>{
                'x-amz-server-side-encryption': 'aws:kms',
                'x-amz-server-side-encryption-aws-kms-key-id': 'kms-key',
                'x-amz-server-side-encryption-context':
                    base64Encode(utf8.encode('{"purpose":"test"}')),
                'x-amz-server-side-encryption-bucket-key-enabled': 'true',
              };
        for (final request in requests) {
          final receives =
              azure || request.uri.queryParameters.containsKey('uploads');
          for (final header in expected.entries) {
            expect(request.headers[header.key], receives ? header.value : null);
          }
        }
      });
    });
  }
}
