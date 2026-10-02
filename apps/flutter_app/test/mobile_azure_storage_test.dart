import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xml/xml.dart';

import 'package:s3_browser_crossplat/models/domain_models.dart';
import 'package:s3_browser_crossplat/services/mobile_storage_admin.dart';
import 'package:s3_browser_crossplat/services/storage_http_client.dart';

void main() {
  late HttpServer server;
  late MobileStorageAdmin admin;
  late EndpointProfile profile;
  late Future<void> Function(HttpRequest) handler;
  late List<
          ({String method, Uri uri, Map<String, String> headers, String body})>
      requests;

  setUp(() async {
    requests = [];
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    profile = EndpointProfile(
        id: 'azure',
        name: 'Azure fixture',
        endpointUrl: 'http://127.0.0.1:${server.port}/fixture',
        region: '',
        accessKey: 'fixture',
        secretKey: base64Encode(utf8.encode('fixture-key')),
        endpointType: EndpointProfileType.azureBlob,
        pathStyle: true,
        verifyTls: true,
        maxAttempts: 1);
    admin = MobileStorageAdmin();
    handler = (request) async {
      request.response.statusCode = 500;
      request.response.write('<Error><Code>UnexpectedRequest</Code></Error>');
    };
    server.listen((request) async {
      final body = await utf8.decoder.bind(request).join();
      final headers = <String, String>{};
      request.headers.forEach((key, values) => headers[key] = values.join(','));
      requests.add((
        method: request.method,
        uri: request.uri,
        headers: headers,
        body: body
      ));
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

  Future<Map<String, Object?>> action(String name,
          [Map<String, Object?> args = const {}]) =>
      admin.action(
          profile: profile,
          action: name,
          arguments: {'bucketName': 'container', ...args});

  test('Azure listing keeps exact names, version IDs and opaque pagination',
      () async {
    handler = (request) async {
      expect(request.headers.value('authorization'),
          startsWith('SharedKey fixture:'));
      request.response.write('''<EnumerationResults><Blobs>
        <Blob><Name> a/../x &amp; y </Name><VersionId>2026-01-01T00:00:00.0000000Z</VersionId><IsCurrentVersion>true</IsCurrentVersion>
        <Properties><Last-Modified>Thu, 01 Jan 2026 00:00:00 GMT</Last-Modified><Content-Length>7</Content-Length><Etag>"v1"</Etag><AccessTier>Cool</AccessTier></Properties></Blob>
        <Blob><Name> a/../x &amp; y -other</Name><VersionId>other</VersionId><Properties><Content-Length>9</Content-Length></Properties></Blob>
        </Blobs><NextMarker>next&amp;page=2</NextMarker></EnumerationResults>''');
    };
    final result = await action('listObjectVersions', {
      'key': ' a/../x & y ',
      'cursor': {'value': 'before&key=1'}
    });
    final items = result['items'] as List;
    expect(items, hasLength(1));
    expect((items.single as Map)['key'], ' a/../x & y ');
    expect((items.single as Map)['latest'], true);
    expect((items.single as Map)['size'], 7);
    expect(result['cursor'], {'hasMore': true, 'value': 'next&page=2'});
    expect(requests.single.uri.queryParameters['marker'], 'before&key=1');
    expect(requests.single.uri.queryParameters['include'], 'versions');
  });

  test('version tag mutations retain the version and XML-escape user values',
      () async {
    handler = (request) async {
      if (request.method == 'PUT') {
        request.response.statusCode = 204;
      } else {
        request.response.write(
            '<Tags><TagSet><Tag><Key>owner</Key><Value>a&amp;b</Value></Tag></TagSet></Tags>');
      }
    };
    final result = await action('objectTags', {
      'key': 'name',
      'versionId': 'version+one',
      'tags': {'owner': 'a&b'}
    });
    expect(result['tags'], {'owner': 'a&b'});
    for (final request in requests) {
      expect(request.uri.queryParameters['versionid'], 'version+one');
      expect(request.uri.queryParameters['comp'], 'tags');
    }
    expect(
        XmlDocument.parse(requests.first.body)
            .findAllElements('Value')
            .single
            .innerText,
        'a&b');
    expect(requests.first.body, isNot(contains('amazonaws.com')));
  });

  test(
      'property updates preserve unspecified content headers and use fresh ETags',
      () async {
    handler = (request) async {
      if (request.method == 'HEAD') {
        request.response.headers.set('etag', '"v1"');
        request.response.headers.set('content-type', 'text/plain');
        request.response.headers.set('content-language', 'nl');
        request.response.headers.set('cache-control', 'max-age=60');
        request.response.contentLength = 7;
      } else {
        request.response.headers.set(
            'etag',
            request.uri.queryParameters['comp'] == 'metadata'
                ? '"v2"'
                : '"v3"');
      }
    };
    await action('objectProperties', {
      'key': 'name',
      'expectedETag': '"v1"',
      'metadata': {'owner': 'team'},
      'headers': {'Content-Type': 'text/html'}
    });
    expect(requests.map((request) => request.method), ['HEAD', 'PUT', 'PUT']);
    expect(requests[1].headers['if-match'], '"v1"');
    expect(requests[2].headers['if-match'], '"v2"');
    expect(requests[2].headers['x-ms-blob-content-type'], 'text/html');
    expect(requests[2].headers['x-ms-blob-content-language'], 'nl');
    expect(requests[2].headers['x-ms-blob-cache-control'], 'max-age=60');
  });

  test('stale object properties do not mutate storage', () async {
    handler = (request) async {
      request.response.headers.set('etag', '"new"');
    };
    await expectLater(
        action('objectProperties', {
          'key': 'name',
          'expectedETag': '"old"',
          'metadata': {'a': 'b'}
        }),
        throwsA(isA<EngineException>()
            .having((error) => error.code, 'code', ErrorCode.objectConflict)));
    expect(requests.map((request) => request.method), ['HEAD']);
  });

  test('private access preset preserves stored SAS policies', () async {
    handler = (request) async {
      if (request.method == 'GET') {
        request.response.headers.set('x-ms-blob-public-access', 'blob');
        request.response.headers
            .set('last-modified', 'Thu, 01 Jan 2026 00:00:00 GMT');
        request.response.write(
            '<SignedIdentifiers><SignedIdentifier><Id>existing</Id><AccessPolicy><Permission>r</Permission></AccessPolicy></SignedIdentifier></SignedIdentifiers>');
      }
    };
    await action('putAccess', {'acl': 'private'});
    expect(requests.last.method, 'PUT');
    expect(requests.last.headers, isNot(contains('x-ms-blob-public-access')));
    expect(
        XmlDocument.parse(requests.last.body)
            .findAllElements('Id')
            .single
            .innerText,
        'existing');
    expect(requests.last.headers['if-unmodified-since'],
        'Thu, 01 Jan 2026 00:00:00 GMT');
  });

  test('immutability updates require valid input before any mutation',
      () async {
    await expectLater(
        action('setObjectProtection', {
          'key': 'name',
          'retention': {
            'Mode': 'Locked',
            'RetainUntilDate': '2000-01-01T00:00:00Z'
          },
          'legalHold': true
        }),
        throwsA(isA<EngineException>()
            .having((error) => error.code, 'code', ErrorCode.invalidConfig)));
    expect(requests, isEmpty);
  });

  test('version protection writes address only the requested version',
      () async {
    handler = (request) async {
      request.response.headers.set('x-ms-version-id', 'exact-version');
      request.response.headers.set('x-ms-legal-hold', 'true');
      request.response.headers.set('etag', '"v2"');
    };
    final result = await action('setObjectProtection', {
      'key': 'name',
      'versionId': 'exact-version',
      'legalHold': {'Status': 'ON'}
    });
    expect((result['legalHold'] as Map)['Status'], 'ON');
    expect(requests.first.headers['x-ms-legal-hold'], 'true');
    expect(
        requests.every((request) =>
            request.uri.queryParameters['versionid'] == 'exact-version'),
        true);
  });

  test('account-only and S3-only features fail before sending requests',
      () async {
    for (final name in [
      'putLifecycle',
      'setBucketVersioning',
      'setBucketProtection',
      'setBucketTags'
    ]) {
      await expectLater(
          action(name),
          throwsA(isA<EngineException>().having(
              (error) => error.code, 'code', ErrorCode.unsupportedFeature)));
    }
    await expectLater(
        action('setBucketCors', {'corsJson': '[]'}),
        throwsA(isA<EngineException>()
            .having((error) => error.code, 'code', ErrorCode.invalidConfig)));
    expect(requests, isEmpty);
  });

  test('SharedKey version SAS binds version and exact opaque key', () {
    final http = StorageHttpClient(profile);
    addTearDown(http.close);
    final signed = mobileAzurePresign(http, 'container', ' a/../b+& ',
        versionId: 'v+1', expiresSeconds: 60, now: DateTime.utc(2026));
    final url = signed['url'] as String;
    expect(url, contains('/container/%20a/../b%2B%26%20?'));
    final query = Uri.splitQueryString(url.split('?').last);
    expect(query['sr'], 'bv');
    expect(query['versionid'], 'v+1');
    expect(query['sp'], 'r');
    final fields = [
      'r',
      '2025-12-31T23:55:00Z',
      '2026-01-01T00:01:00Z',
      '/blob/fixture/container/ a/../b+& ',
      '',
      '',
      'https,http',
      '2021-12-02',
      'bv',
      'v+1',
      '',
      '',
      '',
      '',
      '',
      ''
    ];
    final expected = base64Encode(Hmac(sha256, utf8.encode('fixture-key'))
        .convert(utf8.encode(fields.join('\n')))
        .bytes);
    expect(query['sig'], expected);
  });

  test('existing SAS cannot be leaked as a newly narrowed version grant', () {
    final sasProfile = EndpointProfile.fromJson({
      ...profile.toJson(),
      'secretKey': '',
      'sessionToken': 'sig=broad-account-secret&sp=rwdlac',
      ...const ConnectionOptions(authMode: 'azureSas').toJson()
    });
    final http = StorageHttpClient(sasProfile);
    addTearDown(http.close);
    expect(
        () => mobileAzurePresign(http, 'container', 'name', versionId: 'v1'),
        throwsA(isA<EngineException>().having(
            (error) => error.code, 'code', ErrorCode.unsupportedFeature)));
  });
}
