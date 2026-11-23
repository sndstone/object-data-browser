part of 'conformance_suite.dart';

extension _BucketConfig on S3ConformanceSuite {
  Map<String, Object?> get _b => {'Bucket': _stdBucket};

  Future<void> _bucketConfigChecks() async {
    await _check('bucket.tagging',
        category: 'Bucket subresources',
        title: 'Bucket tagging: absent, put, get, delete',
        spec: 'GetBucketTagging without tags: 404 NoSuchTagSet; PutBucketTagging: 204; GetBucketTagging: 200 with the set; DeleteBucketTagging: 204.',
        body: (c) async {
      c.status(await c.call('GetBucketTagging', _b), 404, code: 'NoSuchTagSet');
      final tags = [{'Key': 'purpose', 'Value': 'conformance'}, {'Key': 'run', 'Value': _run.runId}];
      c.success(await c.call('PutBucketTagging', {..._b, 'Tagging': {'TagSet': tags}}), preferred: 204);
      c.equals('TagSet', tags, _tags(await c.call('GetBucketTagging', _b)));
      c.status(await c.call('DeleteBucketTagging', _b), 204);
      c.status(await c.call('GetBucketTagging', _b), 404, code: 'NoSuchTagSet');
    });
    await _check('bucket.cors',
        category: 'Bucket subresources',
        title: 'Bucket CORS: absent, put, get, delete',
        spec: 'GetBucketCors without rules: 404 NoSuchCORSConfiguration; PutBucketCors: 200; GetBucketCors returns the rule; DeleteBucketCors: 204.',
        body: (c) async {
      c.status(await c.call('GetBucketCors', _b), 404, code: 'NoSuchCORSConfiguration');
      final rule = {
        'ID': 'conformance-rule',
        'AllowedHeaders': ['*'],
        'AllowedMethods': ['GET', 'PUT'],
        'AllowedOrigins': ['https://example.test'],
        'ExposeHeaders': ['ETag'],
        'MaxAgeSeconds': 300,
      };
      c.success(await c.call('PutBucketCors', {..._b, 'CORSConfiguration': {'CORSRules': [rule]}}), preferred: 200);
      final got = await c.call('GetBucketCors', _b);
      c.status(got, 200);
      final rules = got.list('CORSRules');
      c.equals('CORSRules count', 1, rules.length);
      if (rules.isNotEmpty) {
        for (final field in ['AllowedHeaders', 'AllowedMethods', 'AllowedOrigins', 'ExposeHeaders', 'MaxAgeSeconds']) {
          c.equals('CORSRules[0].$field', rule[field], rules.first[field]);
        }
        c.equals('CORSRules[0].ID', 'conformance-rule', rules.first['ID'], informational: true);
      }
      c.status(await c.call('DeleteBucketCors', _b), 204);
      c.status(await c.call('GetBucketCors', _b), 404, code: 'NoSuchCORSConfiguration');
    });
    await _check('bucket.lifecycle',
        category: 'Bucket subresources',
        title: 'Bucket lifecycle: absent, put, get, delete',
        spec: 'GetBucketLifecycleConfiguration without rules: 404 NoSuchLifecycleConfiguration; Put: 200; Get returns the rule; DeleteBucketLifecycle: 204.',
        body: (c) async {
      c.status(await c.call('GetBucketLifecycleConfiguration', _b), 404, code: 'NoSuchLifecycleConfiguration');
      final rule = {
        'ID': 'conformance-expire',
        'Status': 'Disabled',
        'Filter': {'Prefix': 'p1/lifecycle/'},
        'Expiration': {'Days': 30},
      };
      c.success(await c.call('PutBucketLifecycleConfiguration', {..._b, 'LifecycleConfiguration': {'Rules': [rule]}}), preferred: 200);
      final got = await c.call('GetBucketLifecycleConfiguration', _b);
      c.status(got, 200);
      final rules = got.list('Rules');
      c.equals('Rules count', 1, rules.length);
      if (rules.isNotEmpty) {
        c.equals('Rules[0].ID', 'conformance-expire', rules.first['ID']);
        c.equals('Rules[0].Status', 'Disabled', rules.first['Status']);
        c.equals('Rules[0].Filter.Prefix', 'p1/lifecycle/', (rules.first['Filter'] as Map?)?['Prefix']);
        c.equals('Rules[0].Expiration.Days', 30, (rules.first['Expiration'] as Map?)?['Days']);
      }
      c.status(await c.call('DeleteBucketLifecycle', _b), 204);
      c.status(await c.call('GetBucketLifecycleConfiguration', _b), 404, code: 'NoSuchLifecycleConfiguration');
    });
    await _check('bucket.policy',
        category: 'Bucket subresources',
        title: 'Bucket policy: absent, put, get, status, delete',
        spec: 'GetBucketPolicy without a policy: 404 NoSuchBucketPolicy; PutBucketPolicy: 204; GetBucketPolicy returns it; GetBucketPolicyStatus IsPublic=false; DeleteBucketPolicy: 204.',
        body: (c) async {
      c.status(await c.call('GetBucketPolicy', _b), 404, code: 'NoSuchBucketPolicy');
      // A deny on an unused prefix: private, and it never blocks cleanup.
      final policy = {
        'Version': '2012-10-17',
        'Statement': [
          {
            'Sid': 'ConformanceDenyUnusedPrefix',
            'Effect': 'Deny',
            'Principal': '*',
            'Action': 's3:GetObject',
            'Resource': 'arn:aws:s3:::$_stdBucket/p1/policy-denied/*',
          }
        ],
      };
      c.success(await c.call('PutBucketPolicy', {..._b, 'Policy': jsonEncode(policy)}), preferred: 204);
      final got = await c.call('GetBucketPolicy', _b);
      c.status(got, 200);
      Map<String, Object?>? parsed;
      try {
        parsed = Map<String, Object?>.from(jsonDecode('${got.field('Policy')}') as Map);
      } catch (_) {}
      c.isTrue('Policy JSON', parsed != null, expected: 'JSON document', actual: conformanceClip(got.field('Policy'), 80));
      final statement = (parsed?['Statement'] as List?)?.whereType<Map>().firstOrNull;
      c.equals('Statement[0].Effect', 'Deny', statement?['Effect']);
      final action = statement?['Action'];
      c.equals('Statement[0].Action', 's3:GetObject', action is List && action.length == 1 ? action.first : action);
      final status = await c.call('GetBucketPolicyStatus', _b, notImplementedIsUnsupported: false);
      if (status.httpStatus == 501 || status.errorCode == 'NotImplemented') {
        c.note('GetBucketPolicyStatus is not implemented by the endpoint.');
        c.status(status, 200, informational: true);
      } else {
        c.status(status, 200, informational: true);
        c.equals('PolicyStatus.IsPublic', false, status.field('PolicyStatus.IsPublic'), informational: true);
      }
      c.status(await c.call('DeleteBucketPolicy', _b), 204);
      c.status(await c.call('GetBucketPolicy', _b), 404, code: 'NoSuchBucketPolicy');
    });
    await _check('bucket.encryption',
        category: 'Bucket subresources',
        title: 'Default bucket encryption: put, get, delete',
        spec: 'PutBucketEncryption AES256: 200; GetBucketEncryption returns the rule; DeleteBucketEncryption: 204. AWS buckets keep SSE-S3 as the default afterwards.',
        body: (c) async {
      final initial = await c.call('GetBucketEncryption', _b);
      if (initial.httpStatus == 404) {
        c.status(initial, 404, code: 'ServerSideEncryptionConfigurationNotFoundError', informational: true);
      } else {
        c.status(initial, 200, informational: true,
            explanation: 'AWS applies SSE-S3 to every new bucket and reports it here.');
      }
      c.success(await c.call('PutBucketEncryption', {
        ..._b,
        'ServerSideEncryptionConfiguration': {
          'Rules': [
            {'ApplyServerSideEncryptionByDefault': {'SSEAlgorithm': 'AES256'}, 'BucketKeyEnabled': false}
          ]
        },
      }), preferred: 200);
      final got = await c.call('GetBucketEncryption', _b);
      c.status(got, 200);
      c.equals('Rules[0].ApplyServerSideEncryptionByDefault.SSEAlgorithm', 'AES256',
          got.field('ServerSideEncryptionConfiguration.Rules.0.ApplyServerSideEncryptionByDefault.SSEAlgorithm'));
      c.status(await c.call('DeleteBucketEncryption', _b), 204);
      final after = await c.call('GetBucketEncryption', _b);
      if (after.httpStatus == 404) {
        c.status(after, 404, code: 'ServerSideEncryptionConfigurationNotFoundError', informational: true,
            explanation: 'AWS keeps SSE-S3 as the default after deletion and returns 200.');
      } else {
        c.status(after, 200, informational: true);
        c.equals('default after delete', 'AES256',
            after.field('ServerSideEncryptionConfiguration.Rules.0.ApplyServerSideEncryptionByDefault.SSEAlgorithm'),
            informational: true);
      }
    });
    await _check('bucket.public-access-block',
        category: 'Bucket subresources',
        title: 'Public access block: put, get, delete',
        spec: 'PutPublicAccessBlock: 200; GetPublicAccessBlock returns all four flags; DeletePublicAccessBlock: 204; then 404 NoSuchPublicAccessBlockConfiguration.',
        body: (c) async {
      const flags = {
        'BlockPublicAcls': true,
        'IgnorePublicAcls': true,
        'BlockPublicPolicy': true,
        'RestrictPublicBuckets': true,
      };
      c.success(await c.call('PutPublicAccessBlock', {..._b, 'PublicAccessBlockConfiguration': flags}), preferred: 200);
      final got = await c.call('GetPublicAccessBlock', _b);
      c.status(got, 200);
      for (final entry in flags.entries) {
        c.equals('PublicAccessBlockConfiguration.${entry.key}', entry.value,
            got.field('PublicAccessBlockConfiguration.${entry.key}'));
      }
      c.status(await c.call('DeletePublicAccessBlock', _b), 204);
      c.status(await c.call('GetPublicAccessBlock', _b), 404, code: 'NoSuchPublicAccessBlockConfiguration');
    });
    await _check('bucket.ownership-controls',
        category: 'Bucket subresources',
        title: 'Object Ownership controls: put, get, delete',
        spec: 'PutBucketOwnershipControls: 200; GetBucketOwnershipControls returns the rule; DeleteBucketOwnershipControls: 204; then 404 OwnershipControlsNotFoundError.',
        body: (c) async {
      final initial = await c.call('GetBucketOwnershipControls', _b);
      c.isTrue('initial state', initial.httpStatus == 200 || initial.httpStatus == 404,
          expected: '200 (AWS default BucketOwnerEnforced) or 404', actual: _CheckContext.describe(initial), informational: true);
      c.success(await c.call('PutBucketOwnershipControls', {
        ..._b,
        'OwnershipControls': {'Rules': [{'ObjectOwnership': 'BucketOwnerPreferred'}]},
      }), preferred: 200);
      final got = await c.call('GetBucketOwnershipControls', _b);
      c.status(got, 200);
      c.equals('OwnershipControls.Rules[0].ObjectOwnership', 'BucketOwnerPreferred',
          got.field('OwnershipControls.Rules.0.ObjectOwnership'));
      c.status(await c.call('DeleteBucketOwnershipControls', _b), 204);
      c.status(await c.call('GetBucketOwnershipControls', _b), 404, code: 'OwnershipControlsNotFoundError');
    });
    await _check('bucket.accelerate',
        category: 'Bucket subresources',
        title: 'Transfer acceleration configuration',
        spec: 'GetBucketAccelerateConfiguration: 200 without Status; PutBucketAccelerateConfiguration Suspended: 200; Get reports Suspended.',
        severity: ConformanceSeverity.informational,
        body: (c) async {
      final initial = await c.call('GetBucketAccelerateConfiguration', _b);
      c.status(initial, 200);
      c.equals('initial Status', null, initial.field('Status'));
      c.success(await c.call('PutBucketAccelerateConfiguration', {..._b, 'AccelerateConfiguration': {'Status': 'Suspended'}}), preferred: 200);
      c.equals('Status', 'Suspended', (await c.call('GetBucketAccelerateConfiguration', _b)).field('Status'));
    });
    await _check('bucket.request-payment',
        category: 'Bucket subresources',
        title: 'Requester pays configuration',
        spec: 'GetBucketRequestPayment: 200 Payer=BucketOwner; PutBucketRequestPayment BucketOwner: 200.',
        severity: ConformanceSeverity.informational,
        body: (c) async {
      final got = await c.call('GetBucketRequestPayment', _b);
      c.status(got, 200);
      c.equals('Payer', 'BucketOwner', got.field('Payer'));
      c.success(await c.call('PutBucketRequestPayment', {..._b, 'RequestPaymentConfiguration': {'Payer': 'BucketOwner'}}), preferred: 200);
    });
    await _check('bucket.logging',
        category: 'Bucket subresources',
        title: 'Server access logging status',
        spec: 'GetBucketLogging: 200 with no LoggingEnabled element for a new bucket.',
        severity: ConformanceSeverity.informational,
        body: (c) async {
      final got = await c.call('GetBucketLogging', _b);
      c.status(got, 200);
      c.equals('LoggingEnabled', null, got.field('LoggingEnabled'));
    });
    await _check('bucket.website',
        category: 'Bucket subresources',
        title: 'Static website configuration',
        spec: 'GetBucketWebsite without configuration: 404 NoSuchWebsiteConfiguration; PutBucketWebsite: 200; Get returns index and error documents; DeleteBucketWebsite: 204.',
        severity: ConformanceSeverity.informational,
        body: (c) async {
      c.status(await c.call('GetBucketWebsite', _b), 404, code: 'NoSuchWebsiteConfiguration');
      c.success(await c.call('PutBucketWebsite', {
        ..._b,
        'WebsiteConfiguration': {'IndexDocument': {'Suffix': 'index.html'}, 'ErrorDocument': {'Key': 'error.html'}},
      }), preferred: 200);
      final got = await c.call('GetBucketWebsite', _b);
      c.status(got, 200);
      c.equals('IndexDocument.Suffix', 'index.html', got.field('IndexDocument.Suffix'));
      c.equals('ErrorDocument.Key', 'error.html', got.field('ErrorDocument.Key'));
      c.status(await c.call('DeleteBucketWebsite', _b), 204);
      c.status(await c.call('GetBucketWebsite', _b), 404, code: 'NoSuchWebsiteConfiguration');
    });
    await _check('bucket.notification',
        category: 'Bucket subresources',
        title: 'Event notification configuration',
        spec: 'GetBucketNotificationConfiguration: 200 and empty for a new bucket; PutBucketNotificationConfiguration with an empty configuration: 200.',
        severity: ConformanceSeverity.informational,
        body: (c) async {
      final got = await c.call('GetBucketNotificationConfiguration', _b);
      c.status(got, 200);
      final count = got.list('TopicConfigurations').length + got.list('QueueConfigurations').length +
          got.list('LambdaFunctionConfigurations').length;
      c.equals('configurations', 0, count);
      c.success(await c.call('PutBucketNotificationConfiguration', {..._b, 'NotificationConfiguration': <String, Object?>{}}), preferred: 200);
    });
    await _check('bucket.replication',
        category: 'Bucket subresources',
        title: 'Replication configuration is absent',
        spec: 'GetBucketReplication without configuration: 404 ReplicationConfigurationNotFoundError; DeleteBucketReplication: 204. Positive replication needs an IAM role and is not exercised.',
        severity: ConformanceSeverity.informational,
        body: (c) async {
      c.status(await c.call('GetBucketReplication', _b), 404, code: 'ReplicationConfigurationNotFoundError');
      c.status(await c.call('DeleteBucketReplication', _b), 204);
    });
    final analytics = <(String, String, String, Map<String, Object?>, String)>[
      ('analytics', 'BucketAnalyticsConfiguration', 'AnalyticsConfiguration',
          {'Id': 'conformance', 'StorageClassAnalysis': <String, Object?>{}}, 'AnalyticsConfigurationList'),
      ('metrics', 'BucketMetricsConfiguration', 'MetricsConfiguration', {'Id': 'conformance'}, 'MetricsConfigurationList'),
      ('inventory', 'BucketInventoryConfiguration', 'InventoryConfiguration', {
        'Id': 'conformance',
        'IsEnabled': false,
        'IncludedObjectVersions': 'Current',
        'Schedule': {'Frequency': 'Weekly'},
        'Destination': {
          'S3BucketDestination': {'Bucket': 'arn:aws:s3:::$_stdBucket', 'Format': 'CSV', 'Prefix': 'p1/inventory'}
        },
      }, 'InventoryConfigurationList'),
      ('intelligent-tiering', 'BucketIntelligentTieringConfiguration', 'IntelligentTieringConfiguration', {
        'Id': 'conformance',
        'Status': 'Disabled',
        'Tierings': [{'Days': 90, 'AccessTier': 'ARCHIVE_ACCESS'}],
      }, 'IntelligentTieringConfigurationList'),
    ];
    for (final (id, name, member, configuration, listMember) in analytics) {
      await _check('bucket.$id',
          category: 'Bucket subresources',
          title: '${member.replaceAll('Configuration', '')} configuration: list, put, get, delete',
          spec: 'List$name' 's: 200 and empty; Put$name: 200; Get$name returns Id conformance; Delete$name: 204.',
          severity: ConformanceSeverity.informational,
          body: (c) async {
        final listed = await c.call('List${name}s', _b);
        c.status(listed, 200);
        c.equals('$listMember count', 0, listed.list(listMember).length);
        c.success(await c.call('Put$name', {..._b, 'Id': 'conformance', member: configuration}), preferred: 200);
        final got = await c.call('Get$name', {..._b, 'Id': 'conformance'});
        c.status(got, 200);
        c.equals('$member.Id', 'conformance', got.field('$member.Id'));
        c.status(await c.call('Delete$name', {..._b, 'Id': 'conformance'}), 204);
      });
    }
  }
}
