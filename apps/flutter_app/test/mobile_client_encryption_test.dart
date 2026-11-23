import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:s3_browser_crossplat/models/domain_models.dart';
import 'package:s3_browser_crossplat/services/crypto/age.dart';
import 'package:s3_browser_crossplat/services/diagnostic_safety.dart';
import 'package:s3_browser_crossplat/services/mobile_client_encryption.dart';
import 'package:s3_browser_crossplat/services/mobile_storage_admin.dart';

import 'mobile_client_encryption_fixture.dart';

void main() {
  final vectors = mobileAgeVectors();
  for (final azure in [false, true]) {
    group(azure ? 'Azure mobile age' : 'S3 mobile age', () {
      late MobileAgeFixture fixture;
      setUp(() async {
        fixture = MobileAgeFixture(azure);
        await fixture.start();
      });
      tearDown(() => fixture.close());

      test('advertises age-v1 and validates configuration before network I/O',
          () async {
        final result = await fixture.dispatch('getCapabilities', {});
        final descriptor = (result['items'] as List)
            .cast<Map>()
            .singleWhere((item) => item['key'] == 'object.clientEncryption');
        expect(descriptor['state'], 'supported');
        expect(descriptor['formats'], ['age-v1']);
        final vector = vectors.first;
        for (final method in ['startUpload', 'startDownload']) {
          for (final count in [0, 2]) {
            await expectLater(
                fixture.dispatch(method, {
                  method == 'startUpload' ? 'filePaths' : 'keys':
                      List.filled(count, 'x'),
                  'clientEncryption': {'format': 'age-v1'}
                }),
                throwsA(isA<EngineException>()
                    .having((e) => e.code, 'code', ErrorCode.invalidConfig)));
          }
        }
        for (final bad in [
          {'format': 'other'},
          {
            'fileKey': base64Encode([1])
          },
          {
            'payloadNonce': base64Encode([1])
          },
          {'header': base64Encode(Uint8List(65537))},
        ]) {
          await expectLater(
              fixture.dispatch('startUpload', {
                'filePaths': ['unused'],
                'clientEncryption': {
                  'format': 'age-v1',
                  'header': vector['header'],
                  'fileKey': vector['fileKey'],
                  'payloadNonce': vector['payloadNonce'],
                  ...bad
                }
              }),
              throwsA(isA<EngineException>()
                  .having((e) => e.code, 'code', ErrorCode.invalidConfig)));
        }
        expect(fixture.requests, isEmpty);
      });

      for (final vector in vectors) {
        test(
            'single PUT vector ${vector['plaintextLength']} and authenticated download',
            () async {
          await fixture.upload(vector);
          final object = fixture.objects['report.pdf.age']!;
          expect(object.length, vector['objectLength']);
          expect(objectDigest(object), vector['objectSha256']);
          final result = await fixture.download(vector);
          expect(p.basename(result['path'] as String), 'report.pdf');
          final plaintext = await File(result['path'] as String).readAsBytes();
          expect(plaintext, orderedEquals(vectorPlaintext(vector)));
          expect(fixture.events.last['totalBytes'], vector['objectLength']);
          final put = fixture.requests.singleWhere((r) => r.method == 'PUT');
          expect(put.headers['content-length'], '${vector['objectLength']}');
          if (!azure) {
            expect(put.headers['x-amz-content-sha256'], vector['objectSha256']);
          }
        });
      }

      test('mapped upload names are relative to a non-empty stored prefix',
          () async {
        final vector = vectors.first;
        final source = File('${fixture.directory.path}/private-name.txt');
        await source.writeAsBytes(vectorPlaintext(vector));
        const mapped = 'encoded-folder/encoded-name.age';
        await fixture.dispatch('startUpload', {
          'prefix': 'vault/current/',
          'filePaths': [source.path],
          'objectKeyByPath': {source.path: mapped},
          'multipartThresholdMiB': 32,
          'multipartChunkMiB': 5,
          'clientEncryption': {
            'format': 'age-v1',
            'header': vector['header'],
            'fileKey': vector['fileKey'],
            'payloadNonce': vector['payloadNonce']
          }
        });
        expect(fixture.objects.keys, ['vault/current/$mapped']);
        expect(objectDigest(fixture.objects['vault/current/$mapped']!),
            vector['objectSha256']);
        expect(fixture.requests.where((r) => r.method == 'PUT').single.uri.path,
            '/bucket/vault/current/$mapped');
      });

      test(
          'multipart ciphertext ranges and retry reproduce vector in part order',
          () async {
        final vector = vectors.last;
        fixture.failPartOnce = true;
        fixture.reverseParts = true;
        await fixture.upload(vector, multipart: true);
        expect(objectDigest(fixture.objects['report.pdf.age']!),
            vector['objectSha256']);
        final parts = fixture.requests
            .where((r) => r.uri.queryParameters
                .containsKey(azure ? 'blockid' : 'partNumber'))
            .toList();
        final repeated = parts
            .where((r) => parts.where((p) => p.uri == r.uri).length == 2)
            .toList();
        expect(repeated, hasLength(2));
        expect(repeated[0].body, orderedEquals(repeated[1].body));
        expect(parts.every((r) => r.body.length <= 5 * 1024 * 1024), isTrue);
        final result = await fixture.download(vector);
        expect(objectDigest(await File(result['path'] as String).readAsBytes()),
            vector['plaintextSha256']);
      });

      test('ciphertext threshold and part-count boundaries', () async {
        for (final length in [1024 * 1024 - 1, 5 * 1024 * 1024 - 1]) {
          fixture.requests.clear();
          fixture.parts.clear();
          final vector = {...vectors.first, 'plaintextLength': length};
          await fixture.upload(vector, multipart: true);
          final size = ageCiphertextLength(
              headerLength: vector['headerLength'] as int,
              plaintextLength: length);
          expect(fixture.objects['report.pdf.age']!.length, size);
          final parts = fixture.requests.where((r) => r.uri.queryParameters
              .containsKey(azure ? 'blockid' : 'partNumber'));
          expect(
              parts.length, (size + 5 * 1024 * 1024 - 1) ~/ (5 * 1024 * 1024));
          expect(parts, isNotEmpty);
          final result = await fixture.download(vector);
          expect(await File(result['path'] as String).readAsBytes(),
              orderedEquals(vectorPlaintext(vector)));
        }
      });

      test('changed source between part attempts aborts without publication',
          () async {
        fixture.failPartOnce = true;
        fixture.onFailedPart = () async {
          await File('${fixture.directory.path}/source').writeAsBytes([99]);
        };
        await expectLater(
            fixture.upload(vectors.last, multipart: true),
            throwsA(isA<EngineException>()
                .having((e) => e.code, 'code', ErrorCode.objectConflict)));
        expect(fixture.objects, isEmpty);
        if (!azure) expect(fixture.aborts, 1);
        expect(
            fixture.requests
                .where((r) => r.uri.queryParameters['comp'] == 'blocklist'),
            isEmpty);
      });

      for (final corruption in [
        'bit',
        'boundary truncation',
        'mid chunk truncation',
        'missing final flag',
        'extra chunk',
        'swapped chunks',
        'impossible length'
      ]) {
        test('$corruption fails integrity and removes staged plaintext',
            () async {
          final vector =
              vectors.singleWhere((v) => v['plaintextLength'] == 131072);
          await fixture.upload(vector);
          final original = fixture.objects['report.pdf.age']!;
          final start = (vector['headerLength'] as int) + 16;
          const chunkSize = ageChunkSize + ageChunkOverhead;
          var corrupt = Uint8List.fromList(original);
          switch (corruption) {
            case 'bit':
              corrupt[start + 10] ^= 1;
            case 'boundary truncation':
              corrupt = corrupt.sublist(0, start + chunkSize);
            case 'mid chunk truncation':
              corrupt = corrupt.sublist(0, corrupt.length - 1);
            case 'missing final flag':
              final worker = MobileAgeWorker(
                  base64Decode(vector['fileKey'] as String),
                  base64Decode(vector['payloadNonce'] as String));
              try {
                final wrong = await worker.chunk(
                    1,
                    Uint8List.sublistView(
                        vectorPlaintext(vector), ageChunkSize),
                    last: false,
                    seal: true);
                corrupt.setRange(start + chunkSize, corrupt.length, wrong);
              } finally {
                worker.close();
              }
            case 'extra chunk':
              corrupt = (BytesBuilder()
                    ..add(original)
                    ..add(original.sublist(start, start + chunkSize)))
                  .takeBytes();
            case 'swapped chunks':
              corrupt.setRange(
                  start, start + chunkSize, original, start + chunkSize);
              corrupt.setRange(
                  start + chunkSize, corrupt.length, original, start);
            case 'impossible length':
              corrupt = corrupt.sublist(0, start + 5);
          }
          fixture.objects['report.pdf.age'] = corrupt;
          await expectLater(
              fixture.download(vector),
              throwsA(isA<EngineException>()
                  .having((e) => e.code, 'code', ErrorCode.decryptionFailed)
                  .having((e) => e.details?['chunk'], 'chunk', isA<int>())
                  .having(
                      (e) => e.userMessage, 'message', contains('integrity'))));
          final remaining = await fixture.directory.list().toList();
          expect(remaining.map((f) => p.basename(f.path)), ['source']);
        });
      }

      test(
          'published names strip one nonempty age suffix and keep both collisions',
          () async {
        final vector = vectors[1];
        await fixture.upload(vector);
        for (final pair in [
          ('report.pdf.age', 'report.pdf'),
          ('.age', '.age'),
          ('a.age.age', 'a.age')
        ]) {
          fixture.objects[pair.$1] = fixture.objects['report.pdf.age']!;
          final result = await fixture.download(vector, key: pair.$1);
          expect(p.basename(result['path'] as String), pair.$2);
        }
        final result = await fixture.download(vector);
        expect(p.basename(result['path'] as String), 'report.pdf (1)');
        expect(await File('${fixture.directory.path}/report.pdf').readAsBytes(),
            vectorPlaintext(vector));
      });

      test('supplied hidden name publishes plaintext with normal collisions',
          () async {
        final vector = vectors[1];
        await fixture.upload(vector);
        fixture.objects['token.age'] = fixture.objects['report.pdf.age']!;
        Future<Map<String, Object?>> download({String policy = 'keepBoth'}) =>
            fixture.admin.download(fixture.profile, {
              'bucketName': 'bucket',
              'key': 'token.age',
              'conflictPolicy': policy,
              'destinationPath': fixture.directory.path,
              'clientEncryption': {
                'format': 'age-v1',
                'fileKey': vector['fileKey'],
                'headerLength': vector['headerLength'],
                'fileName': 'hidden-report.pdf'
              }
            });
        final first = await download();
        expect(p.basename(first['path'] as String), 'hidden-report.pdf');
        expect(await File(first['path'] as String).readAsBytes(),
            vectorPlaintext(vector));
        final second = await download();
        expect(p.basename(second['path'] as String), 'hidden-report.pdf (1)');
        final replaced = await download(policy: 'replace');
        expect(replaced['path'], first['path']);
        expect(await File(first['path'] as String).readAsBytes(),
            vectorPlaintext(vector));
        for (final request in fixture.requests) {
          expect('${request.uri} ${request.headers}',
              isNot(contains('hidden-report.pdf')));
        }
        expect(
            jsonEncode(fixture.events), isNot(contains('hidden-report.pdf')));
        expect(
            jsonEncode(redactClientDownloadName({
              'clientEncryption': {'fileName': 'hidden-report.pdf'}
            })),
            isNot(contains('hidden-report.pdf')));
      });

      test('invalid supplied names fail before direct download network I/O',
          () async {
        final vector = vectors[1];
        for (final name in [
          null,
          1,
          false,
          [],
          {},
          '',
          '.',
          '..',
          'a/b',
          r'a\b',
          'a\x00b'
        ]) {
          await expectLater(
              fixture.admin.download(fixture.profile, {
                'bucketName': 'bucket',
                'key': 'token.age',
                'destinationPath': fixture.directory.path,
                'clientEncryption': {
                  'format': 'age-v1',
                  'fileKey': vector['fileKey'],
                  'headerLength': vector['headerLength'],
                  'fileName': name
                }
              }),
              throwsA(isA<EngineException>()
                  .having((e) => e.code, 'code', ErrorCode.invalidConfig)));
        }
        expect(fixture.requests, isEmpty);
      });

      test(
          'provider encryption wraps ciphertext and mobile retained data never leaks file key',
          () async {
        final vector = vectors[4];
        final provider = {
          'mode': azure ? 'azure-cpk' : 'sse-c',
          'customerKey': base64Encode(List.filled(32, 9))
        };
        await fixture.upload(vector, providerEncryption: provider);
        expect(objectDigest(fixture.objects['report.pdf.age']!),
            vector['objectSha256']);
        final put = fixture.requests.singleWhere((r) => r.method == 'PUT');
        expect(
            put.headers[azure
                ? 'x-ms-encryption-key'
                : 'x-amz-server-side-encryption-customer-key'],
            provider['customerKey']);
        final retained = jsonEncode({
          'events': fixture.events,
          'trace': DiagnosticSafety.trace({'clientEncryption': vector}),
          'requests': fixture.requests
              .map((r) => {
                    'headers': DiagnosticSafety.sanitize(r.headers),
                    'uri': '${r.uri}'
                  })
              .toList()
        });
        expect(retained, isNot(contains(vector['fileKey'])));
        expect(retained, isNot(contains(provider['customerKey'])));
      });

      test('default off preserves request bodies headers and downloaded bytes',
          () async {
        final vector = vectors[4];
        await fixture.upload(vector, encrypted: false);
        final first = fixture.requests.singleWhere((r) => r.method == 'PUT');
        fixture.requests.clear();
        final file = File('${fixture.directory.path}/source');
        await fixture.dispatch('startUpload', {
          'filePaths': [file.path],
          'objectKeyByPath': {file.path: 'report.pdf.age'},
          'multipartThresholdMiB': 32,
          'multipartChunkMiB': 5,
          'clientEncryption': null
        });
        final second = fixture.requests.singleWhere((r) => r.method == 'PUT');
        expect(second.body, orderedEquals(first.body));
        Map<String, String> stable(Map<String, String> headers) =>
            Map.of(headers)
              ..remove('authorization')
              ..remove('x-amz-date')
              ..remove('x-ms-date');
        expect(stable(second.headers), stable(first.headers));
        expect(fixture.objects['report.pdf.age'], vectorPlaintext(vector));
        final result = await fixture.admin.download(fixture.profile, {
          'bucketName': 'bucket',
          'key': 'report.pdf.age',
          'destinationPath': fixture.directory.path
        });
        expect(p.basename(result['path'] as String), 'report.pdf.age');
        expect(await File(result['path'] as String).readAsBytes(),
            vectorPlaintext(vector));
      });
    });
  }
}
