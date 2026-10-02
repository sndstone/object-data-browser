import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:s3_browser_crossplat/controllers/action_scope.dart';
import 'package:s3_browser_crossplat/models/domain_models.dart';
import 'package:s3_browser_crossplat/services/mobile_storage_admin.dart';
import 'package:xml/xml.dart';

void main() {
  for (final listingFails in [false, true]) {
    test(
        'deferred deletion finishes listing before mutations (failure=$listingFails)',
        () async {
      // Mobile privacy comes from the app-owned temporary parent. Desktop Dart
      // createTemp does not promise a portable POSIX mode for each child.
      final fixtureRoot = await Directory.systemTemp
          .createTemp('object-browser-tools-fixture-');
      addTearDown(() async {
        if (await fixtureRoot.exists()) {
          await fixtureRoot.delete(recursive: true);
        }
      });
      if (!Platform.isWindows) {
        final chmod = await Process.run('chmod', ['700', fixtureRoot.path]);
        expect(chmod.exitCode, 0, reason: '${chmod.stderr}');
      }
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final admin = MobileStorageAdmin();
      addTearDown(() async {
        admin.close();
        await server.close(force: true);
      });
      Future<Set<String>> plans() async => (await fixtureRoot
              .list()
              .where((entry) =>
                  entry is Directory &&
                  entry.uri.pathSegments
                      .where((segment) => segment.isNotEmpty)
                      .last
                      .startsWith('object-browser-delete-plan-'))
              .toList())
          .map((entry) => entry.path)
          .toSet();
      final before = await plans();
      var pages = 0, deletes = 0;
      final observedPlans = <String>{};
      server.listen((request) async {
        final body = await utf8.decoder.bind(request).join();
        final query = request.uri.queryParameters;
        if (query.containsKey('versioning')) {
          request.response.write('<VersioningConfiguration/>');
        } else if (query['list-type'] == '2') {
          pages++;
          observedPlans.addAll((await plans()).difference(before));
          if (!Platform.isWindows) {
            expect((await fixtureRoot.stat()).mode & 0x3f, 0,
                reason: 'The simulated app-private parent must stay private.');
          }
          for (final path in observedPlans) {
            expect(Directory(path).parent.path, fixtureRoot.path,
                reason: 'Deletion plans must remain inside the app sandbox.');
          }
          if (listingFails && pages == 3) {
            request.response.statusCode = 403;
            request.response.write('<Error><Code>AccessDenied</Code></Error>');
          } else {
            request.response.write(
                '<ListBucketResult><IsTruncated>${pages < 3}</IsTruncated><Contents><Key>key$pages</Key><ETag>"original"</ETag></Contents>${pages < 3 ? '<NextContinuationToken>page${pages + 1}</NextContinuationToken>' : ''}</ListBucketResult>');
          }
        } else if (query.containsKey('delete')) {
          deletes++;
          expect(pages, 3,
              reason: 'Deferred mode must finish every list page first.');
          expect(listingFails, false);
          final keys = XmlDocument.parse(body)
              .findAllElements('Object')
              .map((node) => node.getElement('Key')!.innerText);
          request.response.write(
              '<DeleteResult>${keys.map((key) => '<Deleted><Key>$key</Key></Deleted>').join()}</DeleteResult>');
        } else {
          fail('Unexpected ${request.method} ${request.uri}');
        }
        await request.response.close();
      });
      final result = await IOOverrides.runZoned(
        () => admin.runStorageTool(
            _profile(server.port)
                .copyWith(endpointType: EndpointProfileType.awsS3),
            {
              'config': {
                'bucketName': 'bucket',
                'immediateDeletion': false,
                'listMaxKeys': 1,
                'batchSize': 1,
                'maxRetries': 0,
              }
            }),
        getSystemTempDirectory: () => fixtureRoot,
      );
      expect(result['exitCode'], listingFails ? 1 : 0);
      expect(result['listedCount'], listingFails ? 2 : 3);
      expect(result['successCount'], listingFails ? 0 : 3);
      expect(deletes, listingFails ? 0 : 3);
      expect(observedPlans, isNotEmpty);
      for (final path in observedPlans) {
        expect(await Directory(path).exists(), false);
      }
    });
  }

  for (final scenario in [
    'recover',
    'final-failure',
    'enabled',
    'suspended',
    'unknown-versioning',
    'version-list-denied',
    'denied',
    'unknown-error',
    'changed-etag',
    'retention',
    'versioning-changed',
    'missing-listed-etag',
    'cancelled'
  ]) {
    test('mobile delete recovery boundary: $scenario', () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final admin = MobileStorageAdmin();
      addTearDown(() async {
        admin.close();
        await server.close(force: true);
      });
      final profile = _profile(server.port);
      var puts = 0,
          deletes = 0,
          bulkRequests = 0,
          versionChecks = 0,
          versionLists = 0,
          objectLists = 0;
      var removed = false;
      final deletedVersions = <String>[];
      final scope = ActionScope(inheritParent: false);
      final versioned =
          {'enabled', 'suspended', 'version-list-denied'}.contains(scenario);
      server.listen((request) async {
        final bytes =
            await request.fold<List<int>>([], (all, data) => all..addAll(data));
        void error(String code, [int status = 500]) {
          request.response.statusCode = status;
          request.response.write('<Error><Code>$code</Code></Error>');
        }

        final query = request.uri.queryParameters;
        if (query.containsKey('versioning')) {
          versionChecks++;
          if (scenario == 'unknown-versioning') {
            error('AccessDenied', 403);
          } else {
            final status = scenario == 'suspended'
                ? 'Suspended'
                : versioned ||
                        (scenario == 'versioning-changed' && versionChecks > 1)
                    ? 'Enabled'
                    : '';
            request.response.write(
                '<VersioningConfiguration>${status.isEmpty ? '' : '<Status>$status</Status>'}</VersioningConfiguration>');
          }
        } else if (query.containsKey('versions')) {
          versionLists++;
          if (scenario == 'version-list-denied') {
            error('AccessDenied', 403);
          } else {
            request.response.write(
                '<ListVersionsResult><IsTruncated>false</IsTruncated><Version><Key> exact key </Key><VersionId>v1</VersionId></Version><DeleteMarker><Key> exact key </Key><VersionId>d1</VersionId></DeleteMarker></ListVersionsResult>');
          }
        } else if (query['list-type'] == '2') {
          objectLists++;
          request.response.write(
              '<ListBucketResult><IsTruncated>false</IsTruncated><Contents><Key> exact key </Key>${scenario == 'missing-listed-etag' ? '' : '<ETag>"listed"</ETag>'}</Contents></ListBucketResult>');
        } else if (query.containsKey('delete')) {
          bulkRequests++;
          if (scenario == 'cancelled') scope.cancel();
          final root = XmlDocument.parse(utf8.decode(bytes));
          final code = scenario == 'denied'
              ? 'AccessDenied'
              : scenario == 'unknown-error'
                  ? 'MysteryFailure'
                  : 'InternalError';
          request.response.write(
              '<DeleteResult>${root.findAllElements('Object').map((node) {
            final key = node.getElement('Key')!.innerText;
            expect(key, ' exact key ');
            final version = node.getElement('VersionId')?.innerText;
            return '<Error><Key> exact key </Key>${version == null ? '' : '<VersionId>$version</VersionId>'}<Code>$code</Code></Error>';
          }).join()}</DeleteResult>');
        } else if (request.method == 'HEAD') {
          if (removed) {
            request.response.statusCode = 404;
          } else {
            request.response.headers.set(
                'etag',
                scenario == 'changed-etag'
                    ? '"changed"'
                    : puts > 0
                        ? '"empty"'
                        : '"listed"');
            if (scenario == 'retention') {
              request.response.headers
                  .set('x-amz-object-lock-mode', 'GOVERNANCE');
            }
          }
        } else if (request.method == 'DELETE') {
          deletes++;
          if (query['versionId'] != null) {
            deletedVersions.add(query['versionId']!);
          }
          if (puts > 0 && scenario != 'final-failure') {
            expect(request.headers.value('if-match'), '"empty"');
            removed = true;
            request.response.statusCode = 204;
          } else {
            error('InternalError');
          }
        } else if (request.method == 'PUT') {
          puts++;
          expect(bytes, isEmpty);
          expect(request.headers.value('if-match'), '"listed"');
          request.response.headers.set('etag', '"empty"');
        } else {
          error('UnexpectedRequest');
        }
        try {
          await request.response.close();
        } catch (_) {/* Cancellation aborts the socket. */}
      });
      final result = await scope.run(() => admin.runStorageTool(profile, {
            'config': {
              'bucketName': 'bucket',
              'maxRetries': 1,
              'maxWorkers': 1,
              'batchSize': 1000,
              'retryMode': 'standard',
              'checksumAlgorithm': 'crc32c',
            }
          }));
      final recovery = scenario == 'recover' || scenario == 'final-failure';
      expect(puts, recovery ? 1 : 0);
      expect(result['successCount'], scenario == 'recover' ? 1 : 0);
      expect(
          result['exitCode'],
          scenario == 'recover'
              ? 0
              : scenario == 'cancelled'
                  ? 130
                  : 1);
      if (recovery) {
        expect(bulkRequests, 2);
        expect(deletes, 3);
        expect(versionChecks, 2);
      }
      if (scenario == 'final-failure') {
        final outcome = (result['outcomes'] as List).single as Map;
        expect(outcome['overwrittenWithEmptyObject'], true);
        expect(outcome['deleted'], false);
        expect(outcome['message'], contains('empty object'));
      }
      if (versioned) {
        expect(versionLists, 1);
        expect(objectLists, 0);
        if (scenario != 'version-list-denied') {
          expect(deletedVersions.toSet(), {'v1', 'd1'});
        }
      }
      if (scenario == 'unknown-versioning') {
        expect(objectLists, 0);
        expect(bulkRequests, 0);
      }
      if (scenario == 'denied' || scenario == 'unknown-error') {
        expect(bulkRequests, 1);
        expect(deletes, 0);
      }
    });
  }

  test('Azure full delete addresses versions and snapshots without empty PUTs',
      () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final admin = MobileStorageAdmin();
    addTearDown(() async {
      admin.close();
      await server.close(force: true);
    });
    final seen = <Uri>[];
    server.listen((request) async {
      await request.drain<void>();
      if (request.method == 'GET') {
        expect(request.uri.queryParameters['include'], 'versions,snapshots');
        request.response.write(
            '<EnumerationResults><Blobs><Blob><Name>versioned</Name><VersionId>v1</VersionId></Blob><Blob><Name>snapshot</Name><Snapshot>s1</Snapshot></Blob></Blobs><NextMarker /></EnumerationResults>');
      } else {
        expect(request.method, 'DELETE');
        seen.add(request.uri);
        request.response.statusCode = 202;
      }
      await request.response.close();
    });
    final result = await admin.runStorageTool(
        _profile(server.port, azure: true),
        {'bucketName': 'container', 'maxRetries': 0});
    expect(result['exitCode'], 0);
    expect(result['successCount'], 2);
    expect(seen[0].queryParameters['versionid'], 'v1');
    expect(seen[1].queryParameters['snapshot'], 's1');
  });

  test(
      'portable test data writes exact prefixes and versions using bounded files',
      () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final admin = MobileStorageAdmin();
    addTearDown(() async {
      admin.close();
      await server.close(force: true);
    });
    final writes = <String, int>{};
    server.listen((request) async {
      final body =
          await request.fold<List<int>>([], (all, bytes) => all..addAll(bytes));
      expect(request.method, 'PUT');
      expect(body, List<int>.filled(37, 65));
      writes.update(request.uri.path, (value) => value + 1, ifAbsent: () => 1);
      request.response.headers.set('etag', '"uploaded"');
      await request.response.close();
    });
    final result =
        await admin.runStoragePutTestData(_profile(server.port, azure: true), {
      'config': {
        'bucketName': 'container',
        'prefix': ' exact/',
        'objectSizeBytes': 37,
        'objectCount': 2,
        'versions': 2,
        'threads': 2,
      }
    });
    expect(result['exitCode'], 0);
    expect(result['successCount'], 4);
    expect(writes, {
      '/container/%20exact/testdata-000000.bin': 2,
      '/container/%20exact/testdata-000001.bin': 2
    });
  });
}

EndpointProfile _profile(int port, {bool azure = false}) => EndpointProfile(
      id: 'tool-fixture',
      name: 'Tool fixture',
      endpointUrl: 'http://127.0.0.1:$port',
      endpointType: azure
          ? EndpointProfileType.azureBlob
          : EndpointProfileType.s3Compatible,
      region: 'us-east-1',
      accessKey: 'fixture',
      secretKey: azure ? base64Encode(utf8.encode('fixture')) : 'fixture',
      pathStyle: true,
      verifyTls: true,
      maxAttempts: 1,
    );
