part of 'conformance_suite.dart';

extension _SetupAndStandard on S3ConformanceSuite {
  Future<void> _setupPhase() async {
    _phase = ConformancePhase.setup;
    final create = await _check('bucket.create',
        category: 'Bucket administration',
        title: 'CreateBucket creates the standard test bucket',
        spec: 'CreateBucket: 200 OK with a Location header; omit LocationConstraint in us-east-1.',
        body: (c) async {
      final o = await _createBucket(c, _stdBucket);
      c.status(o, 200);
      c.headerPresent(o, 'location', informational: true);
    });
    _stdReady = _ownedBuckets.contains(_stdBucket) &&
        (create.status == ConformanceStatus.pass || create.status == ConformanceStatus.warn);
    if (!_stdReady) {
      // A timed-out create may still have succeeded; teardown checks the name.
      _run.note = 'Bucket 1 could not be created; phases 1 and 2 were skipped.';
      return;
    }
    await _check('bucket.head',
        category: 'Bucket administration',
        title: 'HeadBucket on an owned bucket',
        spec: 'HeadBucket: 200 OK; AWS adds x-amz-bucket-region.',
        body: (c) async {
      final o = await c.call('HeadBucket', {'Bucket': _stdBucket});
      c.status(o, 200);
      c.headerPresent(o, 'x-amz-bucket-region', informational: true);
    });
    await _check('bucket.location',
        category: 'Bucket administration',
        title: 'GetBucketLocation reports the bucket region',
        spec: 'GetBucketLocation: 200; LocationConstraint is empty/null for us-east-1, else the region.',
        body: (c) async {
      final o = await c.call('GetBucketLocation', {'Bucket': _stdBucket});
      c.status(o, 200);
      final region = endpoint.region.trim().isEmpty ? 'us-east-1' : endpoint.region.trim();
      final reported = o.field('LocationConstraint');
      final normalized = (reported == null || '$reported'.isEmpty) ? 'us-east-1' : '$reported';
      c.equals('LocationConstraint (empty means us-east-1)', region, normalized,
          informational: true,
          explanation: 'The location differs from the profile region.');
    });
    await _check('bucket.list',
        category: 'Bucket administration',
        title: 'ListBuckets includes the new bucket',
        spec: 'ListBuckets: 200; Buckets[].Name contains the bucket with a CreationDate.',
        severity: ConformanceSeverity.informational,
        body: (c) async {
      String? token;
      Map<String, Object?>? found;
      for (var page = 0; page < 20 && found == null; page++) {
        final o = await c.call('ListBuckets', {
          'MaxBuckets': 1000,
          if (token != null) 'ContinuationToken': token,
        });
        if (!c.status(o, 200)) return;
        found = o.list('Buckets').where((b) => b['Name'] == _stdBucket).firstOrNull;
        token = o.field('ContinuationToken')?.toString();
        if (token == null || token.isEmpty) break;
      }
      c.isTrue('Buckets[].Name', found != null,
          expected: 'contains $_stdBucket', actual: found == null ? 'missing' : 'present');
      if (found != null) {
        c.isTrue('CreationDate', _parseIso(found['CreationDate']) != null,
            expected: 'ISO-8601 timestamp', actual: found['CreationDate']);
      }
    });
    await _check('bucket.create.duplicate',
        category: 'Bucket administration',
        title: 'CreateBucket on a bucket you already own',
        spec: 'CreateBucket: 409 BucketAlreadyOwnedByYou (AWS us-east-1 legacy behaviour may return 200).',
        severity: ConformanceSeverity.informational,
        body: (c) async {
      final o = await c.call('CreateBucket', _createBucketInput(_stdBucket));
      if (o.httpStatus == 200 && (endpoint.region.isEmpty || endpoint.region == 'us-east-1')) {
        c.note('200 accepted: AWS keeps the legacy us-east-1 behaviour for buckets you own.');
        c.status(o, 200);
        return;
      }
      c.status(o, 409, code: 'BucketAlreadyOwnedByYou');
    });
    await _check('bucket.versioning.initial',
        category: 'Bucket administration',
        title: 'A new bucket has never had versioning enabled',
        spec: 'GetBucketVersioning: 200 with no Status element.',
        body: (c) async {
      final o = await c.call('GetBucketVersioning', {'Bucket': _stdBucket});
      c.status(o, 200);
      c.equals('Status', null, o.field('Status'),
          explanation: 'A bucket that never had versioning must not report a status.');
    });
  }

  Future<void> _standardPhase() async {
    await _objectChecks();
    await _metadataChecks();
    await _checksumChecks();
    await _conditionalChecks();
    await _rangeChecks();
    await _attributeChecks();
    await _copyChecks();
    await _deleteChecks();
    await _listingChecks();
    await _taggingChecks();
    await _aclChecks();
    await _multipartChecks();
    await _presignChecks();
    await _encryptionChecks();
    await _bucketConfigChecks();
    await _negativeChecks();
  }

  Future<void> _listingChecks() async {
    const prefix = 'p1/list/';
    const keys = [
      'p1/list/a.txt',
      'p1/list/b.txt',
      'p1/list/c/d.txt',
      'p1/list/c/e.txt',
      'p1/list/f g.txt',
      'p1/list/h+i.txt',
      'p1/list/ü.txt',
    ];
    // Bytewise UTF-8 order, which S3 uses for listings.
    final sorted = List.of(keys)
      ..sort((a, b) {
        final x = utf8.encode(a);
        final y = utf8.encode(b);
        for (var i = 0; i < x.length && i < y.length; i++) {
          if (x[i] != y[i]) return x[i] - y[i];
        }
        return x.length - y.length;
      });
    final ready = await _check('list.fixture',
        category: 'Listing',
        title: 'Create listing fixture objects',
        spec: 'PutObject: 200 for each fixture key.',
        body: (c) async {
      for (final key in keys) {
        c.fixture(await c.call('PutObject', {'Bucket': _stdBucket, 'Key': key},
            body: S3OpBody.text(key)));
      }
    });
    if (ready.status != ConformanceStatus.pass) {
      return;
    }
    await _check('list.v2.prefix',
        category: 'Listing',
        title: 'ListObjectsV2 with a prefix returns every key in UTF-8 binary order',
        spec: 'ListObjectsV2: 200; Contents sorted by UTF-8 bytes; KeyCount equals returned keys; IsTruncated false.',
        body: (c) async {
      final o = await c.call('ListObjectsV2', {'Bucket': _stdBucket, 'Prefix': prefix});
      c.status(o, 200);
      c.equals('Contents[].Key', sorted, [for (final item in o.list('Contents')) item['Key']]);
      c.equals('KeyCount', keys.length, o.field('KeyCount'));
      c.equals('IsTruncated', false, o.field('IsTruncated') ?? false);
      final first = o.list('Contents').firstOrNull;
      if (first != null) {
        c.isTrue('Contents[0].ETag', '${first['ETag'] ?? ''}'.isNotEmpty,
            expected: 'present', actual: first['ETag']);
        c.isTrue('Contents[0].LastModified', _parseIso(first['LastModified']) != null,
            expected: 'ISO-8601', actual: first['LastModified']);
        c.equals('Contents[0].Size', utf8.encode(sorted.first).length, first['Size']);
        c.equals('Contents[0].StorageClass', 'STANDARD', first['StorageClass'], informational: true);
      }
    });
    await _check('list.v2.delimiter',
        category: 'Listing',
        title: 'ListObjectsV2 with a delimiter rolls nested keys into CommonPrefixes',
        spec: 'ListObjectsV2: Contents holds direct children; CommonPrefixes holds p1/list/c/; KeyCount counts both.',
        body: (c) async {
      final o = await c.call('ListObjectsV2',
          {'Bucket': _stdBucket, 'Prefix': prefix, 'Delimiter': '/'});
      c.status(o, 200);
      c.equals('Contents[].Key', sorted.where((k) => !k.startsWith('p1/list/c/')).toList(),
          [for (final item in o.list('Contents')) item['Key']]);
      c.equals('CommonPrefixes[].Prefix', ['p1/list/c/'],
          [for (final item in o.list('CommonPrefixes')) item['Prefix']]);
      c.equals('KeyCount', keys.length - 1, o.field('KeyCount'),
          explanation: 'KeyCount includes rolled-up common prefixes.');
      c.equals('Delimiter', '/', o.field('Delimiter'), informational: true);
    });
    await _check('list.v2.pagination',
        category: 'Listing',
        title: 'ListObjectsV2 pages with MaxKeys and ContinuationToken',
        spec: 'ListObjectsV2: IsTruncated true with NextContinuationToken until the last page; no gaps or duplicates.',
        body: (c) async {
      final seen = <String>[];
      final tokens = <String>{};
      String? token;
      var pages = 0;
      while (pages < 20) {
        final o = await c.call('ListObjectsV2', {
          'Bucket': _stdBucket,
          'Prefix': prefix,
          'MaxKeys': 2,
          if (token != null) 'ContinuationToken': token,
        });
        pages++;
        if (!o.isSuccess) {
          c.status(o, 200);
          return;
        }
        final page = [for (final item in o.list('Contents')) '${item['Key']}'];
        c.isTrue('page $pages size', page.length <= 2, expected: 'at most MaxKeys (2)', actual: page.length);
        seen.addAll(page);
        final truncated = o.field('IsTruncated') == true;
        if (!truncated) break;
        token = o.field('NextContinuationToken')?.toString();
        if (!c.isTrue('NextContinuationToken', token != null && token.isNotEmpty && tokens.add(token),
            expected: 'a new cursor while IsTruncated', actual: token)) {
          return;
        }
      }
      // AWS may return short pages; coverage and order are what must hold.
      c.equals('Keys across pages', sorted, seen);
      c.isTrue('pages', pages >= 4 && pages < 20, expected: 'at least 4 pages of at most 2 keys', actual: pages);
    });
    await _check('list.v2.start-after',
        category: 'Listing',
        title: 'ListObjectsV2 StartAfter excludes the boundary key',
        spec: 'ListObjectsV2: keys strictly after StartAfter in binary order.',
        body: (c) async {
      final o = await c.call('ListObjectsV2',
          {'Bucket': _stdBucket, 'Prefix': prefix, 'StartAfter': 'p1/list/b.txt'});
      c.status(o, 200);
      c.equals('Contents[].Key', sorted.where((k) => _bytewiseAfter(k, 'p1/list/b.txt')).toList(),
          [for (final item in o.list('Contents')) item['Key']]);
      c.equals('StartAfter', 'p1/list/b.txt', o.field('StartAfter'), informational: true);
    });
    await _check('list.v2.encoding-url',
        category: 'Listing',
        title: 'ListObjectsV2 EncodingType=url encodes keys and prefixes',
        spec: 'ListObjectsV2: EncodingType url in the response; Key, Prefix, Delimiter and StartAfter are URL-encoded (space as +).',
        body: (c) async {
      final o = await c.call('ListObjectsV2', {
        'Bucket': _stdBucket,
        'Prefix': prefix,
        'Delimiter': '/',
        'EncodingType': 'url',
      });
      c.status(o, 200);
      c.equals('EncodingType', 'url', o.field('EncodingType'));
      final raw = [for (final item in o.list('Contents')) '${item['Key']}'];
      final direct = sorted.where((k) => !k.startsWith('p1/list/c/')).toList();
      final sdkDecoded = _sdkDecodes(c);
      final decode = sdkDecoded ? (String v) => v : _formDecode;
      c.equals('decoded Contents[].Key', direct, [for (final key in raw) decode(key)]);
      final prefixes = [for (final item in o.list('CommonPrefixes')) '${item['Prefix']}'];
      c.equals('decoded CommonPrefixes', ['p1/list/c/'], [for (final p in prefixes) decode(p)]);
      c.equals('decoded Prefix', prefix, decode('${o.field('Prefix') ?? ''}'));
      if (sdkDecoded) return;
      final unicode = raw.where((k) => _formDecode(k) == 'p1/list/ü.txt').firstOrNull;
      c.isTrue('encoded unicode key', unicode != null && unicode.contains('%C3%BC'),
          expected: 'p1/list/%C3%BC.txt', actual: unicode);
      final plus = raw.where((k) => _formDecode(k) == 'p1/list/h+i.txt').firstOrNull;
      c.isTrue('encoded plus key', plus != null && plus.contains('%2B'),
          expected: 'p1/list/h%2Bi.txt', actual: plus,
          explanation: 'A literal + must be encoded as %2B so it is not read as a space.');
    });
    await _check('list.v2.encoding-url-fields',
        category: 'Listing',
        title: 'EncodingType=url also encodes Prefix, Delimiter and StartAfter',
        spec: 'ListObjectsV2 EncodingType=url: Prefix, StartAfter, Key and CommonPrefixes are URL-encoded in the response.',
        body: (c) async {
      const prefix = 'p1/enc ü+/';
      for (final key in ['p1/enc ü+/a b.txt', 'p1/enc ü+/c+d.txt', 'p1/enc ü+/sub dir/e.txt']) {
        c.fixture(await c.call('PutObject', {'Bucket': _stdBucket, 'Key': key}, body: S3OpBody.text(key)));
      }
      final o = await c.call('ListObjectsV2', {
        'Bucket': _stdBucket,
        'Prefix': prefix,
        'Delimiter': '/',
        'StartAfter': 'p1/enc ü+/a b.txt',
        'EncodingType': 'url',
      });
      c.status(o, 200);
      final rawPrefix = '${o.field('Prefix') ?? ''}';
      final rawStart = '${o.field('StartAfter') ?? ''}';
      final rawKeys = [for (final item in o.list('Contents')) '${item['Key']}'];
      final rawCommon = [for (final item in o.list('CommonPrefixes')) '${item['Prefix']}'];
      final sdkDecoded = _sdkDecodes(c);
      final decode = sdkDecoded ? (String v) => v : _formDecode;
      c.equals('decoded Prefix', prefix, decode(rawPrefix));
      c.equals('decoded StartAfter', 'p1/enc ü+/a b.txt', decode(rawStart));
      c.equals('decoded Contents[].Key', ['p1/enc ü+/c+d.txt'], [for (final k in rawKeys) decode(k)]);
      c.equals('decoded CommonPrefixes', ['p1/enc ü+/sub dir/'], [for (final p in rawCommon) decode(p)]);
      if (!sdkDecoded) {
        c.isTrue('Prefix encoded', !rawPrefix.contains(' ') && !rawPrefix.contains('ü'),
            expected: 'URL-encoded', actual: rawPrefix);
        c.isTrue('StartAfter encoded', !rawStart.contains(' '), expected: 'URL-encoded', actual: rawStart);
      }
      c.equals('Delimiter', '/', o.field('Delimiter'), informational: true);
    });
    await _check('list.v2.empty',
        category: 'Listing',
        title: 'ListObjectsV2 for a prefix without objects',
        spec: 'ListObjectsV2: 200, KeyCount 0, no Contents, IsTruncated false.',
        body: (c) async {
      final o = await c.call('ListObjectsV2', {'Bucket': _stdBucket, 'Prefix': 'p1/nothing-here/'});
      c.status(o, 200);
      c.equals('KeyCount', 0, o.field('KeyCount'));
      c.equals('Contents', 0, o.list('Contents').length);
      c.equals('IsTruncated', false, o.field('IsTruncated') ?? false);
    });
    await _check('list.v1.delimiter',
        category: 'Listing',
        title: 'ListObjects (v1) with prefix and delimiter',
        spec: 'ListObjects: 200; Contents and CommonPrefixes as for v2; Marker echoed.',
        body: (c) async {
      final o = await c.call('ListObjects', {'Bucket': _stdBucket, 'Prefix': prefix, 'Delimiter': '/'});
      c.status(o, 200);
      c.equals('Contents[].Key', sorted.where((k) => !k.startsWith('p1/list/c/')).toList(),
          [for (final item in o.list('Contents')) item['Key']]);
      c.equals('CommonPrefixes[].Prefix', ['p1/list/c/'],
          [for (final item in o.list('CommonPrefixes')) item['Prefix']]);
    });
    await _check('list.v1.pagination',
        category: 'Listing',
        title: 'ListObjects (v1) pages with MaxKeys and Marker',
        spec: 'ListObjects: IsTruncated; NextMarker only with a delimiter, otherwise the last key is the next Marker.',
        body: (c) async {
      final seen = <String>[];
      String? marker;
      for (var page = 0; page < 10; page++) {
        final o = await c.call('ListObjects', {
          'Bucket': _stdBucket,
          'Prefix': prefix,
          'MaxKeys': 3,
          if (marker != null) 'Marker': marker,
        });
        if (!o.isSuccess) {
          c.status(o, 200);
          return;
        }
        final page = [for (final item in o.list('Contents')) '${item['Key']}'];
        seen.addAll(page);
        if (o.field('IsTruncated') != true) break;
        marker = o.field('NextMarker')?.toString() ?? page.lastOrNull;
        if (marker == null) break;
      }
      c.equals('Keys across pages', sorted, seen);
    });
    await _check('list.v1.encoding-url',
        category: 'Listing',
        title: 'ListObjects (v1) EncodingType=url',
        spec: 'ListObjects: EncodingType url; keys URL-encoded.',
        severity: ConformanceSeverity.informational,
        body: (c) async {
      final o = await c.call('ListObjects', {'Bucket': _stdBucket, 'Prefix': prefix, 'EncodingType': 'url'});
      c.status(o, 200);
      c.equals('EncodingType', 'url', o.field('EncodingType'));
      final raw = [for (final item in o.list('Contents')) '${item['Key']}'];
      final decode = _sdkDecodes(c) ? (String v) => v : _formDecode;
      c.equals('decoded Contents[].Key', sorted, [for (final key in raw) decode(key)]);
    });
  }

  Future<void> _negativeChecks() async {
    final missingBucket = '${config.baseBucketName}-none-${_newRunId()}';
    await _check('error.no-such-bucket',
        category: 'Error responses',
        title: 'Requests to a bucket that does not exist',
        spec: 'GetObject/ListObjectsV2: 404 NoSuchBucket; HeadBucket: 404 without a body.',
        body: (c) async {
      c.status(await c.call('GetObject', {'Bucket': missingBucket, 'Key': 'k'}), 404, code: 'NoSuchBucket');
      c.status(await c.call('ListObjectsV2', {'Bucket': missingBucket}), 404, code: 'NoSuchBucket');
      c.status(await c.call('HeadBucket', {'Bucket': missingBucket}), 404);
    });
    await _check('error.no-such-key',
        category: 'Error responses',
        title: 'Reading a key that does not exist',
        spec: 'GetObject: 404 NoSuchKey; HeadObject: 404 without a body.',
        body: (c) async {
      c.status(await c.call('GetObject', {'Bucket': _stdBucket, 'Key': 'p1/missing.bin'}), 404, code: 'NoSuchKey');
      c.status(await c.call('HeadObject', {'Bucket': _stdBucket, 'Key': 'p1/missing.bin'}), 404);
      c.status(await c.call('GetObjectTagging', {'Bucket': _stdBucket, 'Key': 'p1/missing.bin'}), 404, code: 'NoSuchKey');
    });
    await _check('error.bucket-not-empty',
        category: 'Error responses',
        title: 'DeleteBucket on a bucket that still holds objects',
        spec: 'DeleteBucket: 409 BucketNotEmpty.',
        body: (c) async {
      c.fixture(await c.call('PutObject', {'Bucket': _stdBucket, 'Key': 'p1/keep-bucket.txt'}, body: S3OpBody.text('keep')));
      c.status(await c.call('DeleteBucket', {'Bucket': _stdBucket}), 409, code: 'BucketNotEmpty');
    });
    await _check('error.invalid-bucket-name',
        category: 'Error responses',
        title: 'CreateBucket with an invalid name',
        spec: 'CreateBucket: 400 InvalidBucketName. An SDK may refuse the name before sending.',
        severity: ConformanceSeverity.informational,
        body: (c) async {
      final invalidName = 'Invalid_Name..${_newRunId()}';
      // Like every created name, it must be confirmed unused first; ownership
      // is recorded only if the endpoint then accepts the name.
      final probe = await _quiet('HeadBucket', {'Bucket': invalidName});
      if (probe == null || !probe.isService || (probe.httpStatus != 404 && probe.httpStatus != 400)) {
        c.skip('The invalid name could not be confirmed unused (HeadBucket ${probe == null ? 'failed' : _CheckContext.describe(probe)}).');
      }
      final o = await _createBucket(c, invalidName, input: {'Bucket': invalidName});
      if (o.outcome == 'sdk_validation') {
        c.note('The SDK rejected the name before sending (${o.errorCode ?? 'validation'}).');
        return;
      }
      c.status(o, 400, code: 'InvalidBucketName');
    });
    await _check('error.no-such-upload',
        category: 'Error responses',
        title: 'Multipart operations with an unknown UploadId',
        spec: 'ListParts/UploadPart/AbortMultipartUpload: 404 NoSuchUpload.',
        body: (c) async {
      const uploadId = 'conformance-unknown-upload-id';
      c.status(await c.call('ListParts', {'Bucket': _stdBucket, 'Key': 'p1/none', 'UploadId': uploadId}), 404, code: 'NoSuchUpload');
      c.status(await c.call('UploadPart', {'Bucket': _stdBucket, 'Key': 'p1/none', 'UploadId': uploadId, 'PartNumber': 1},
          body: S3OpBody.text('x')), 404, code: 'NoSuchUpload');
      c.status(await c.call('AbortMultipartUpload', {'Bucket': _stdBucket, 'Key': 'p1/none', 'UploadId': uploadId}), 404,
          code: 'NoSuchUpload', informational: true);
    });
  }
}

/// Some SDKs (AWS SDK for Java v2) URL-decode `EncodingType=url` listings
/// before returning them, and their engines declare it in the capability. The
/// decoded values are still compared; only the wire encoding is reported as
/// unobservable (a deviation). Any other engine is decoded by the host, so
/// unencoded values from the endpoint fail.
bool _sdkDecodes(_CheckContext c) {
  if (c.suite._capability?.client['urlEncodedListings'] != 'decodedBySdk') return false;
  c.isTrue('wire encoding visible', false,
      expected: 'URL-encoded values', actual: 'values already decoded by the SDK',
      informational: true,
      explanation: 'The SDK decodes EncodingType=url responses itself; the endpoint encoding cannot be checked through it.');
  return true;
}

bool _bytewiseAfter(String key, String boundary) {
  final a = utf8.encode(key);
  final b = utf8.encode(boundary);
  for (var i = 0; i < a.length && i < b.length; i++) {
    if (a[i] != b[i]) return a[i] > b[i];
  }
  return a.length > b.length;
}
