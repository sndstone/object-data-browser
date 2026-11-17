import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:s3_browser_crossplat/models/bucket_encryption_config.dart';

void main() {
  for (final algorithm in ['AES256', 'aws:kms', 'aws:kms:dsse']) {
    for (final key in [null, 'arn:aws:kms:region:account:key/example']) {
      for (final bucketKey in [null, false, true]) {
        for (final wrapped in [false, true]) {
          test(
              'round trip $algorithm key=$key bucketKey=$bucketKey wrapped=$wrapped',
              () {
            final document = {
              'Rules': [
                {
                  'ApplyServerSideEncryptionByDefault': {
                    'SSEAlgorithm': algorithm,
                    if (key != null) 'KMSMasterKeyID': key,
                  },
                  if (bucketKey != null) 'BucketKeyEnabled': bucketKey
                }
              ]
            };
            final config = BucketEncryptionConfig.parse(jsonEncode(wrapped
                ? {'ServerSideEncryptionConfiguration': document}
                : document));
            expect(config.canEdit, isTrue);
            expect(config.mode, algorithm);
            expect(config.hasRule, isTrue);
            expect(config.kmsKeyId, key ?? '');
            expect(config.bucketKeyEnabled, bucketKey);
            expect(
                jsonDecode(config.encode(
                    mode: config.mode,
                    kmsKeyId: config.kmsKeyId,
                    bucketKeyEnabled: config.bucketKeyEnabled)),
                document);
          });
        }
      }
    }
  }

  test('empty documents are provider default and never generate an empty PUT',
      () {
    for (final source in [
      '{}',
      '{"Rules":[]}',
      '{"ServerSideEncryptionConfiguration":{}}'
    ]) {
      final config = BucketEncryptionConfig.parse(source);
      expect(config.mode, '');
      expect(config.canEdit, isTrue);
      expect(config.hasRule, isFalse);
      expect(
          () => config.encode(mode: '', kmsKeyId: '', bucketKeyEnabled: null),
          throwsStateError);
      expect(
          jsonDecode(config.encode(
              mode: 'aws:kms', kmsKeyId: 'kms-id', bucketKeyEnabled: true)),
          {
            'Rules': [
              {
                'ApplyServerSideEncryptionByDefault': {
                  'SSEAlgorithm': 'aws:kms',
                  'KMSMasterKeyID': 'kms-id'
                },
                'BucketKeyEnabled': true
              }
            ]
          });
    }
  });

  test('unknown fields at every level survive changes to modeled fields', () {
    final document = {
      'FutureSetting': {'preserve': true},
      'Rules': [
        {
          'BlockedEncryptionTypes': {
            'EncryptionType': ['SSE-C']
          },
          'ApplyServerSideEncryptionByDefault': {
            'SSEAlgorithm': 'AES256',
            'FutureDefault': 7
          }
        }
      ]
    };
    final config = BucketEncryptionConfig.parse(jsonEncode(document));
    final result = jsonDecode(config.encode(
        mode: 'aws:kms', kmsKeyId: 'key', bucketKeyEnabled: true));
    expect(result['FutureSetting'], document['FutureSetting']);
    expect(result['Rules'][0]['BlockedEncryptionTypes'], {
      'EncryptionType': ['SSE-C']
    });
    expect(
        result['Rules'][0]['ApplyServerSideEncryptionByDefault']
            ['FutureDefault'],
        7);
  });

  test('multiple rules and unfamiliar or malformed shapes require JSON', () {
    for (final source in [
      '{"Rules":[{},{}]}',
      '{"Rules":{}}',
      '{"Rules":[null]}',
      '{"Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"future"}}]}',
      '{"Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"aws:kms"},"BucketKeyEnabled":"yes"}]}',
      '{"ServerSideEncryptionConfiguration":{"Rules":[]},"future":1}',
      '[]',
      'null',
      'not JSON',
    ]) {
      final config = BucketEncryptionConfig.parse(source);
      expect(config.canEdit, isFalse, reason: source);
      expect(config.notice, isNotNull);
      expect(
          () => config.encode(
              mode: 'AES256', kmsKeyId: '', bucketKeyEnabled: null),
          throwsStateError);
    }
  });

  test('changing away from KMS removes modeled KMS fields only', () {
    final config = BucketEncryptionConfig.parse(
        '{"Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"aws:kms","KMSMasterKeyID":"old"},"BucketKeyEnabled":true,"Future":42}]}');
    final result = jsonDecode(
        config.encode(mode: 'AES256', kmsKeyId: '', bucketKeyEnabled: null));
    expect(result['Rules'][0], {
      'ApplyServerSideEncryptionByDefault': {'SSEAlgorithm': 'AES256'},
      'Future': 42
    });
  });
}
