import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:s3_browser_crossplat/models/domain_models.dart';
import 'package:s3_browser_crossplat/services/mobile_storage_admin.dart';
import 'package:s3_browser_crossplat/services/storage_http_client.dart';
import 'package:xml/xml.dart';

void main() {
  test(
      'lifecycle XML preserves complex filters, dates, and noncurrent retention',
      () {
    final configuration = {
      'Rules': [
        {
          'ID': 'complex',
          'Status': 'Enabled',
          'Filter': {
            'And': {
              'Prefix': 'a/',
              'Tags': [
                {'Key': 'a', 'Value': 'b'},
                {'Key': 'c', 'Value': 'd'}
              ],
              'ObjectSizeGreaterThan': 128
            }
          },
          'Transitions': [
            {'Date': '2027-01-01T00:00:00Z', 'StorageClass': 'GLACIER'}
          ],
          'NoncurrentVersionExpiration': {
            'NoncurrentDays': 30,
            'NewerNoncurrentVersions': 5
          }
        }
      ]
    };
    expect(
        storageXmlMap(XmlDocument.parse(utf8
                .decode(storageXml('LifecycleConfiguration', configuration)))
            .rootElement),
        configuration);
    final lock = {
      'ObjectLockEnabled': 'Enabled',
      'Rule': {
        'DefaultRetention': {'Mode': 'GOVERNANCE', 'Years': 2}
      }
    };
    expect(
        storageXmlMap(XmlDocument.parse(
                utf8.decode(storageXml('ObjectLockConfiguration', lock)))
            .rootElement),
        lock);
  });
  test('signed transport preserves opaque key paths and escapes reserved bytes',
      () {
    final client = StorageHttpClient(
        profile('http://127.0.0.1:9000', 's3Compatible', 'id', 'key'));
    addTearDown(client.close);
    expect(client.uri('bucket', 'a/.././ b+%//x').path,
        '/bucket/a/.././%20b%2B%25//x');
    expect(client.uri('bucket', 'a', {'versionId': 'a+/='}).query,
        'versionId=a%2B%2F%3D');
  });
  test(
      'real local S3/Azure REST copy, multipart, tags and exact-version download',
      () async {
    final env = Platform.environment;
    final s3 = profile(env['LOCAL_STORAGE_S3_ENDPOINT']!, 's3Compatible',
        env['LOCAL_STORAGE_S3_ACCESS']!, env['LOCAL_STORAGE_S3_SECRET']!);
    final azure = profile(env['LOCAL_STORAGE_AZURE_ENDPOINT']!, 'azureBlob',
        env['LOCAL_STORAGE_AZURE_ACCOUNT']!, env['LOCAL_STORAGE_AZURE_KEY']!);
    final admin = MobileStorageAdmin();
    final dir = await Directory.systemTemp.createTemp('portable-storage-test-');
    addTearDown(() async {
      admin.close();
      await dir.delete(recursive: true);
    });
    final suffix = DateTime.now().microsecondsSinceEpoch;
    final bucket = 'portable-$suffix', container = 'portable-$suffix';
    await admin.action(
        profile: s3,
        action: 'ensureBucket',
        arguments: {'bucketName': bucket, 'enableVersioning': true});
    await admin.action(
        profile: azure,
        action: 'ensureBucket',
        arguments: {'bucketName': container});
    final data = Uint8List.fromList(
        List<int>.generate(11 * 1024 * 1024 + 31, (i) => i % 251));
    final source = File('${dir.path}/source.bin');
    await source.writeAsBytes(data);
    const key = 'folder/ space+percent%/large.bin';
    await admin.dispatch('startUpload', {
      'profile': s3.toJson(),
      'bucketName': bucket,
      'filePaths': [source.path],
      'objectKeyByPath': {source.path: key},
      'multipartChunkMiB': 5
    });
    await admin.action(profile: s3, action: 'objectTags', arguments: {
      'bucketName': bucket,
      'key': key,
      'tags': {'purpose': 'local-test'}
    });
    final details = await admin.action(
        profile: s3,
        action: 'objectDetails',
        arguments: {'bucketName': bucket, 'key': key});
    final version = details['versionId'];
    expect(version, isNotEmpty);
    await admin
        .client(s3)
        .request('PUT', bucket, key: key, body: utf8.encode('new current'));
    final original =
        await admin.action(profile: s3, action: 'downloadVersion', arguments: {
      'bucketName': bucket,
      'key': key,
      'versionId': version,
      'destinationDirectory': dir.path
    });
    expect(sha256.convert(await File(original['path'] as String).readAsBytes()),
        sha256.convert(data));
    final copy = await admin.action(
        profile: s3,
        destinationProfile: azure,
        action: 'copyObject',
        arguments: {
          'sourceBucketName': bucket,
          'sourceKey': key,
          'sourceVersionId': version,
          'destinationBucketName': container,
          'destinationKey': key,
          'conflictPolicy': 'fail'
        });
    expect(copy['successCount'], 1);
    final roundtrip = await admin.action(
        profile: azure,
        action: 'downloadVersion',
        arguments: {
          'bucketName': container,
          'key': key,
          'destinationDirectory': dir.path
        });
    expect(
        sha256.convert(await File(roundtrip['path'] as String).readAsBytes()),
        sha256.convert(data));
    expect(
        (await admin.action(
            profile: azure,
            action: 'objectTags',
            arguments: {'bucketName': container, 'key': key}))['tags'],
        {'purpose': 'local-test'});
    final back = await admin.action(
        profile: azure,
        destinationProfile: s3,
        action: 'copyObject',
        arguments: {
          'sourceBucketName': container,
          'sourceKey': key,
          'destinationBucketName': bucket,
          'destinationKey': 'roundtrip',
          'conflictPolicy': 'fail'
        });
    expect(back['successCount'], 1);
    final signed = await admin.action(
        profile: azure,
        action: 'presignVersion',
        arguments: {
          'bucketName': container,
          'key': key,
          'expiresSeconds': 120
        });
    final http = HttpClient();
    try {
      final response =
          await (await http.getUrl(Uri.parse(signed['url'] as String))).close();
      expect(response.statusCode, 200);
      expect(await response.fold<int>(0, (n, bytes) => n + bytes.length),
          data.length);
    } finally {
      http.close(force: true);
    }
  },
      skip: Platform.environment['LOCAL_STORAGE_VERIFY'] != '1',
      timeout: const Timeout(Duration(minutes: 4)));
}

EndpointProfile profile(
        String url, String type, String access, String secret) =>
    EndpointProfile.fromJson({
      'id': type,
      'name': type,
      'endpointUrl': url,
      'endpointType': type,
      'region': 'us-east-1',
      'pathStyle': true,
      'accessKey': access,
      'secretKey': secret
    });
