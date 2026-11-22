part of 'conformance_suite.dart';

const _checksumAlgorithms = ['CRC32', 'CRC32C', 'SHA1', 'SHA256'];

const _specialKeys = <String, String>{
  'space': 'p1/keys/hello world.txt',
  'plus': 'p1/keys/a+b=c.txt',
  'percent': 'p1/keys/100% literal %2B.txt',
  'unicode': 'p1/keys/ünïcødé-日本語-🚀.txt',
  'nested': 'p1/keys/deep/nested/path/leaf.txt',
  'reserved': "p1/keys/sym!\$&'()*,;=:@~.txt",
};

extension _StandardObjects on S3ConformanceSuite {
  Future<void> _objectChecks() async {
    final data = ConformanceBytes.generate(1024, 1);
    const key = 'p1/object/basic.bin';
    await _check('object.put',
        category: 'Object CRUD',
        title: 'PutObject stores an object',
        spec: 'PutObject: 200 OK with a quoted ETag; for a single-part unencrypted upload the ETag is the MD5 of the payload.',
        body: (c) async {
      final o = await c.call('PutObject', {
        'Bucket': _stdBucket,
        'Key': key,
        'ContentType': 'application/octet-stream',
      }, body: S3OpBody.generate(1024, 1));
      c.status(o, 200);
      final etag = o.header('etag');
      c.isTrue('PutObject etag', etag != null && etag.startsWith('"') && etag.endsWith('"'),
          expected: 'quoted entity tag', actual: etag);
      c.equals('PutObject etag value', '"${ConformanceBytes.md5Hex(data)}"', etag,
          informational: true,
          explanation: 'AWS returns the payload MD5 for single-part unencrypted objects; treat ETags as opaque.');
      _state['basic.etag'] = etag;
    });
    await _check('object.get',
        category: 'Object CRUD',
        title: 'GetObject returns the stored bytes and headers',
        spec: 'GetObject: 200 with the same ETag, Content-Length and Content-Type; payload unchanged.',
        body: (c) async {
      c.requirePassed('object.put');
      final o = await c.call('GetObject', {'Bucket': _stdBucket, 'Key': key});
      c.status(o, 200);
      c.body(o, data);
      c.header(o, 'etag', _state['basic.etag']);
      c.header(o, 'content-length', '1024');
      c.header(o, 'content-type', 'application/octet-stream');
      c.headerPresent(o, 'last-modified');
    });
    await _check('object.head',
        category: 'Object CRUD',
        title: 'HeadObject returns metadata without a body',
        spec: 'HeadObject: 200 with ETag, Content-Length, Last-Modified and Accept-Ranges: bytes.',
        body: (c) async {
      c.requirePassed('object.put');
      final o = await c.call('HeadObject', {'Bucket': _stdBucket, 'Key': key});
      c.status(o, 200);
      c.header(o, 'etag', _state['basic.etag']);
      c.header(o, 'content-length', '1024');
      c.headerPresent(o, 'last-modified');
      c.header(o, 'accept-ranges', 'bytes', informational: true);
    });
    await _check('object.overwrite',
        category: 'Object CRUD',
        title: 'A second PutObject replaces the object',
        spec: 'PutObject on an existing key in an unversioned bucket replaces it; GetObject returns the new bytes and ETag.',
        body: (c) async {
      const overwriteKey = 'p1/object/overwrite.bin';
      final first = await c.call('PutObject', {'Bucket': _stdBucket, 'Key': overwriteKey}, body: S3OpBody.generate(512, 21));
      c.fixture(first);
      final second = await c.call('PutObject', {'Bucket': _stdBucket, 'Key': overwriteKey}, body: S3OpBody.generate(700, 22));
      c.status(second, 200);
      c.isTrue('ETag changed', first.header('etag') != second.header('etag'),
          expected: 'different ETag', actual: second.header('etag'));
      final get = await c.call('GetObject', {'Bucket': _stdBucket, 'Key': overwriteKey});
      c.status(get, 200);
      c.body(get, ConformanceBytes.generate(700, 22));
      c.header(get, 'etag', second.header('etag'));
    });
    await _check('object.empty',
        category: 'Object CRUD',
        title: 'Zero-byte object',
        spec: 'PutObject with an empty body: 200, ETag "d41d8cd98f00b204e9800998ecf8427e"; GetObject returns 0 bytes.',
        body: (c) async {
      const emptyKey = 'p1/object/empty.bin';
      final put = await c.call('PutObject', {'Bucket': _stdBucket, 'Key': emptyKey}, body: S3OpBody.text(''));
      c.status(put, 200);
      c.header(put, 'etag', '"d41d8cd98f00b204e9800998ecf8427e"', informational: true);
      final get = await c.call('GetObject', {'Bucket': _stdBucket, 'Key': emptyKey});
      c.status(get, 200);
      c.body(get, const []);
      final head = await c.call('HeadObject', {'Bucket': _stdBucket, 'Key': emptyKey});
      c.header(head, 'content-length', '0');
    });
    await _check('object.binary',
        category: 'Object CRUD',
        title: 'Every byte value round-trips unchanged',
        spec: 'PutObject/GetObject preserve arbitrary binary payloads (0x00–0xFF).',
        body: (c) async {
      final bytes = Uint8List.fromList([for (var r = 0; r < 4; r++) for (var b = 0; b < 256; b++) b]);
      const binKey = 'p1/object/all-bytes.bin';
      c.fixture(await c.call('PutObject', {'Bucket': _stdBucket, 'Key': binKey},
          body: S3OpBody.base64(base64.encode(bytes), bytes.length)));
      final get = await c.call('GetObject', {'Bucket': _stdBucket, 'Key': binKey});
      c.status(get, 200);
      c.body(get, bytes);
    });
    for (final entry in _specialKeys.entries) {
      await _check('object.key.${entry.key}',
          category: 'Object keys',
          title: 'Key with ${entry.key == 'reserved' ? 'reserved characters' : entry.key == 'nested' ? 'nested slashes' : entry.key} round-trips',
          spec: 'PutObject/HeadObject/GetObject/ListObjectsV2 address the exact UTF-8 key: ${jsonEncode(entry.value)}.',
          body: (c) async {
        final bytes = utf8.encode(entry.value);
        final put = await c.call('PutObject', {'Bucket': _stdBucket, 'Key': entry.value}, body: S3OpBody.text(entry.value));
        c.status(put, 200);
        final head = await c.call('HeadObject', {'Bucket': _stdBucket, 'Key': entry.value});
        c.status(head, 200);
        final get = await c.call('GetObject', {'Bucket': _stdBucket, 'Key': entry.value});
        c.status(get, 200);
        c.body(get, bytes);
        final list = await c.call('ListObjectsV2', {'Bucket': _stdBucket, 'Prefix': entry.value});
        c.equals('ListObjectsV2 Contents[].Key', [entry.value],
            [for (final item in list.list('Contents')) item['Key']]);
      });
    }
    await _check('object.key.plus-vs-space',
        category: 'Object keys',
        title: "'+' and space are different keys",
        spec: 'S3 keys are opaque: "x+y" and "x y" address different objects (a + in the path is not a space).',
        body: (c) async {
      c.fixture(await c.call('PutObject', {'Bucket': _stdBucket, 'Key': 'p1/keys/x+y.txt'}, body: S3OpBody.text('plus')));
      c.fixture(await c.call('PutObject', {'Bucket': _stdBucket, 'Key': 'p1/keys/x y.txt'}, body: S3OpBody.text('space')));
      final plus = await c.call('GetObject', {'Bucket': _stdBucket, 'Key': 'p1/keys/x+y.txt'});
      c.status(plus, 200);
      c.body(plus, utf8.encode('plus'), field: 'x+y.txt');
      final space = await c.call('GetObject', {'Bucket': _stdBucket, 'Key': 'p1/keys/x y.txt'});
      c.status(space, 200);
      c.body(space, utf8.encode('space'), field: 'x y.txt');
    });
  }

  Future<void> _metadataChecks() async {
    await _check('metadata.system',
        category: 'Metadata and headers',
        title: 'Standard HTTP headers are stored and returned',
        spec: 'PutObject Content-Type, Content-Disposition, Content-Encoding, Content-Language and Cache-Control are returned unchanged by HeadObject and GetObject.',
        body: (c) async {
      const key = 'p1/meta/system.txt.gz';
      final payload = gzip.encode(utf8.encode('S3 conformance payload, stored compressed.\n'));
      const headers = {
        'content-type': 'text/x-conformance; charset=utf-8',
        'content-disposition': 'attachment; filename="report.txt"',
        'content-encoding': 'gzip',
        'content-language': 'en-US',
        'cache-control': 'max-age=60, private',
      };
      c.fixture(await c.call('PutObject', {
        'Bucket': _stdBucket,
        'Key': key,
        'ContentType': headers['content-type'],
        'ContentDisposition': headers['content-disposition'],
        'ContentEncoding': headers['content-encoding'],
        'ContentLanguage': headers['content-language'],
        'CacheControl': headers['cache-control'],
      }, body: S3OpBody.base64(base64.encode(payload), payload.length)));
      final head = await c.call('HeadObject', {'Bucket': _stdBucket, 'Key': key});
      c.status(head, 200);
      for (final entry in headers.entries) {
        c.header(head, entry.key, entry.value);
      }
      final get = await c.call('GetObject', {'Bucket': _stdBucket, 'Key': key});
      c.status(get, 200);
      for (final entry in headers.entries) {
        c.header(get, entry.key, entry.value);
      }
      c.body(get, payload, field: 'stored gzip bytes');
    });
    await _check('metadata.user',
        category: 'Metadata and headers',
        title: 'User metadata (x-amz-meta-*) round-trips',
        spec: 'PutObject Metadata is returned as lower-case x-amz-meta-* headers by HeadObject and GetObject.',
        body: (c) async {
      const key = 'p1/meta/user.txt';
      c.fixture(await c.call('PutObject', {
        'Bucket': _stdBucket,
        'Key': key,
        'Metadata': {'color': 'blue', 'purpose': 's3 conformance'},
      }, body: S3OpBody.text('metadata')));
      for (final op in ['HeadObject', 'GetObject']) {
        final o = await c.call(op, {'Bucket': _stdBucket, 'Key': key});
        c.status(o, 200);
        c.header(o, 'x-amz-meta-color', 'blue');
        c.header(o, 'x-amz-meta-purpose', 's3 conformance');
      }
    });
  }

  Future<void> _checksumChecks() async {
    for (final (index, algorithm) in _checksumAlgorithms.indexed) {
      final lower = algorithm.toLowerCase();
      final data = ConformanceBytes.generate(4096, 40 + index);
      final expected = ConformanceBytes.checksum(algorithm, data);
      await _check('checksum.$lower.valid',
          category: 'Checksums',
          title: '$algorithm checksum is verified, stored and returned',
          spec: 'PutObject ChecksumAlgorithm=$algorithm: 200 with x-amz-checksum-$lower; HeadObject/GetObject with ChecksumMode=ENABLED return the same value.',
          body: (c) async {
        final key = 'p1/checksum/$lower.bin';
        final put = await c.call('PutObject', {'Bucket': _stdBucket, 'Key': key, 'ChecksumAlgorithm': algorithm},
            body: S3OpBody.generate(4096, 40 + index));
        c.status(put, 200);
        c.header(put, 'x-amz-checksum-$lower', expected);
        final head = await c.call('HeadObject', {'Bucket': _stdBucket, 'Key': key, 'ChecksumMode': 'ENABLED'});
        c.status(head, 200);
        c.header(head, 'x-amz-checksum-$lower', expected);
        c.header(head, 'x-amz-checksum-type', 'FULL_OBJECT', informational: true);
        final get = await c.call('GetObject', {'Bucket': _stdBucket, 'Key': key, 'ChecksumMode': 'ENABLED'});
        c.status(get, 200);
        c.header(get, 'x-amz-checksum-$lower', expected);
        c.body(get, data);
      });
      await _check('checksum.$lower.mismatch',
          category: 'Checksums',
          title: 'A wrong $algorithm checksum is rejected',
          spec: 'PutObject with a well-formed but wrong x-amz-checksum-$lower: 400 BadDigest; nothing is stored.',
          body: (c) async {
        final key = 'p1/checksum/$lower-bad.bin';
        final wrong = ConformanceBytes.checksum(algorithm, utf8.encode('different payload'));
        final put = await c.call('PutObject', {
          'Bucket': _stdBucket,
          'Key': key,
          'Checksum$algorithm': wrong,
        }, body: S3OpBody.generate(4096, 40 + index));
        c.status(put, 400, code: 'BadDigest', alternativeCodes: const ['InvalidDigest', 'XAmzContentChecksumMismatch'], informationalCode: true);
        final head = await c.call('HeadObject', {'Bucket': _stdBucket, 'Key': key});
        c.status(head, 404, explanation: 'A rejected upload must not create the object.');
      });
    }
    await _check('checksum.content-md5.valid',
        category: 'Checksums',
        title: 'A correct Content-MD5 is accepted',
        spec: 'PutObject with Content-MD5: 200.',
        body: (c) async {
      final data = ConformanceBytes.generate(2048, 48);
      final put = await c.call('PutObject', {
        'Bucket': _stdBucket,
        'Key': 'p1/checksum/md5.bin',
        'ContentMD5': ConformanceBytes.md5Base64(data),
      }, body: S3OpBody.generate(2048, 48));
      c.status(put, 200);
      final get = await c.call('GetObject', {'Bucket': _stdBucket, 'Key': 'p1/checksum/md5.bin'});
      c.body(get, data);
    });
    await _check('checksum.content-md5.mismatch',
        category: 'Checksums',
        title: 'A wrong Content-MD5 is rejected',
        spec: 'PutObject with a well-formed but wrong Content-MD5: 400 BadDigest; nothing is stored.',
        body: (c) async {
      final put = await c.call('PutObject', {
        'Bucket': _stdBucket,
        'Key': 'p1/checksum/md5-bad.bin',
        'ContentMD5': ConformanceBytes.md5Base64(utf8.encode('other')),
      }, body: S3OpBody.generate(2048, 48));
      c.status(put, 400, code: 'BadDigest');
      c.status(await c.call('HeadObject', {'Bucket': _stdBucket, 'Key': 'p1/checksum/md5-bad.bin'}), 404,
          explanation: 'A rejected upload must not create the object.');
    });
  }

  Future<void> _conditionalChecks() async {
    const key = 'p1/conditional/object.txt';
    String? etag;
    DateTime? lastModified;
    final ready = await _check('conditional.fixture',
        category: 'Conditional requests',
        title: 'Create the conditional-request fixture',
        spec: 'PutObject then HeadObject: ETag and Last-Modified are available.',
        body: (c) async {
      c.fixture(await c.call('PutObject', {'Bucket': _stdBucket, 'Key': key}, body: S3OpBody.text('conditional')));
      final head = await c.call('HeadObject', {'Bucket': _stdBucket, 'Key': key});
      c.fixture(head);
      etag = head.header('etag');
      lastModified = _parseHttpDate(head.header('last-modified') ?? '');
      c.isTrue('Last-Modified', lastModified != null,
          expected: 'HTTP date', actual: head.header('last-modified'));
      if (lastModified == null) throw const _CheckAbort();
    });
    if (ready.status != ConformanceStatus.pass) return;
    // Conditions use whole seconds after the modification, never a future date.
    await _waitUntilServer(lastModified!.add(const Duration(seconds: 2)));
    final after = _isoSeconds(lastModified!.add(const Duration(seconds: 1)));
    final before = _isoSeconds(lastModified!.subtract(const Duration(days: 1)));
    final cases = <(String, String, Map<String, Object?>, int, String?)>[
      ('conditional.get.if-match', 'If-Match with the current ETag', {'IfMatch': etag}, 200, null),
      ('conditional.get.if-match-fail', 'If-Match with another ETag', {'IfMatch': '"00000000000000000000000000000000"'}, 412, 'PreconditionFailed'),
      ('conditional.get.if-none-match', 'If-None-Match with the current ETag', {'IfNoneMatch': etag}, 304, null),
      ('conditional.get.if-none-match-other', 'If-None-Match with another ETag', {'IfNoneMatch': '"00000000000000000000000000000000"'}, 200, null),
      ('conditional.get.if-modified-since', 'If-Modified-Since after the last modification', {'IfModifiedSince': after}, 304, null),
      ('conditional.get.if-modified-since-earlier', 'If-Modified-Since before the last modification', {'IfModifiedSince': before}, 200, null),
      ('conditional.get.if-unmodified-since', 'If-Unmodified-Since after the last modification', {'IfUnmodifiedSince': after}, 200, null),
      ('conditional.get.if-unmodified-since-fail', 'If-Unmodified-Since before the last modification', {'IfUnmodifiedSince': before}, 412, 'PreconditionFailed'),
      ('conditional.get.if-match-precedence', 'If-Match true wins over a false If-Unmodified-Since', {'IfMatch': etag, 'IfUnmodifiedSince': before}, 200, null),
      ('conditional.get.if-none-match-precedence', 'If-None-Match false wins over a true If-Modified-Since', {'IfNoneMatch': etag, 'IfModifiedSince': before}, 304, null),
      ('conditional.head.if-match-fail', 'HeadObject If-Match with another ETag', {'IfMatch': '"00000000000000000000000000000000"'}, 412, null),
      ('conditional.head.if-none-match', 'HeadObject If-None-Match with the current ETag', {'IfNoneMatch': etag}, 304, null),
    ];
    for (final (id, title, conditions, expected, code) in cases) {
      final op = id.startsWith('conditional.head') ? 'HeadObject' : 'GetObject';
      await _check(id,
          category: 'Conditional requests',
          title: title,
          spec: '$op: $expected${code == null ? '' : ' $code'} (RFC 7232 as documented for $op).',
          body: (c) async {
        final o = await c.call(op, {'Bucket': _stdBucket, 'Key': key, ...conditions});
        c.status(o, expected, code: code);
        if (expected == 304) {
          c.header(o, 'etag', etag, informational: true);
        }
      });
    }
    await _check('conditional.put.if-none-match-star',
        category: 'Conditional requests',
        title: 'PutObject If-None-Match: * creates only when absent',
        spec: 'PutObject If-None-Match: *: 200 for a new key, 412 PreconditionFailed when the key exists; the first payload survives.',
        body: (c) async {
      const putKey = 'p1/conditional/create-only.txt';
      c.status(await c.call('PutObject', {'Bucket': _stdBucket, 'Key': putKey, 'IfNoneMatch': '*'}, body: S3OpBody.text('first')), 200);
      c.status(await c.call('PutObject', {'Bucket': _stdBucket, 'Key': putKey, 'IfNoneMatch': '*'}, body: S3OpBody.text('second')), 412,
          code: 'PreconditionFailed');
      final get = await c.call('GetObject', {'Bucket': _stdBucket, 'Key': putKey});
      c.body(get, utf8.encode('first'));
    });
    await _check('conditional.put.if-match',
        category: 'Conditional requests',
        title: 'PutObject If-Match replaces only the expected version',
        spec: 'PutObject If-Match: 200 when the ETag matches, 412 PreconditionFailed otherwise; 404 NoSuchKey for a missing key.',
        body: (c) async {
      const putKey = 'p1/conditional/compare-and-swap.txt';
      final first = await c.call('PutObject', {'Bucket': _stdBucket, 'Key': putKey}, body: S3OpBody.text('v1'));
      c.fixture(first);
      c.status(await c.call('PutObject', {'Bucket': _stdBucket, 'Key': putKey, 'IfMatch': '"00000000000000000000000000000000"'},
          body: S3OpBody.text('stale')), 412, code: 'PreconditionFailed');
      c.status(await c.call('PutObject', {'Bucket': _stdBucket, 'Key': putKey, 'IfMatch': first.header('etag')},
          body: S3OpBody.text('v2')), 200);
      c.body(await c.call('GetObject', {'Bucket': _stdBucket, 'Key': putKey}), utf8.encode('v2'));
      c.status(await c.call('PutObject', {'Bucket': _stdBucket, 'Key': 'p1/conditional/absent.txt', 'IfMatch': first.header('etag')},
          body: S3OpBody.text('x')), 404, code: 'NoSuchKey', informational: true);
    });
  }

  Future<void> _rangeChecks() async {
    const key = 'p1/range/object.bin';
    final data = ConformanceBytes.generate(1024, 3);
    final ready = await _check('range.fixture',
        category: 'Range requests',
        title: 'Create the range fixture',
        spec: 'PutObject: 200.',
        body: (c) async {
      c.fixture(await c.call('PutObject', {'Bucket': _stdBucket, 'Key': key}, body: S3OpBody.generate(1024, 3)));
    });
    if (ready.status != ConformanceStatus.pass) return;
    final cases = <(String, String, String, int, int)>[
      ('range.single', 'Closed byte range', 'bytes=2-5', 2, 5),
      ('range.suffix', 'Suffix byte range', 'bytes=-4', 1020, 1023),
      ('range.open-ended', 'Open-ended byte range', 'bytes=1000-', 1000, 1023),
      ('range.clamped', 'Range end beyond the object is clamped', 'bytes=1000-99999', 1000, 1023),
    ];
    for (final (id, title, range, start, end) in cases) {
      await _check(id,
          category: 'Range requests',
          title: '$title ($range)',
          spec: 'GetObject Range: 206 Partial Content, Content-Range bytes $start-$end/1024, exact slice.',
          body: (c) async {
        final o = await c.call('GetObject', {'Bucket': _stdBucket, 'Key': key, 'Range': range});
        c.status(o, 206);
        c.header(o, 'content-range', 'bytes $start-$end/1024');
        c.header(o, 'content-length', '${end - start + 1}');
        c.body(o, data.sublist(start, end + 1));
      });
    }
    await _check('range.unsatisfiable',
        category: 'Range requests',
        title: 'Range starting at the object size',
        spec: 'GetObject Range bytes=1024-: 416 InvalidRange.',
        body: (c) async {
      c.status(await c.call('GetObject', {'Bucket': _stdBucket, 'Key': key, 'Range': 'bytes=1024-'}), 416, code: 'InvalidRange');
    });
    await _check('range.multiple',
        category: 'Range requests',
        title: 'Multiple ranges in one request',
        spec: 'GetObject: S3 does not serve multipart/byteranges; AWS returns the whole object with 200.',
        severity: ConformanceSeverity.informational,
        body: (c) async {
      final o = await c.call('GetObject', {'Bucket': _stdBucket, 'Key': key, 'Range': 'bytes=0-1,4-5'});
      c.status(o, 200);
      c.body(o, data);
    });
    await _check('range.empty-object',
        category: 'Range requests',
        title: 'Range request on a zero-byte object',
        spec: 'GetObject Range bytes=0-0 on an empty object: 416 InvalidRange.',
        severity: ConformanceSeverity.informational,
        body: (c) async {
      c.fixture(await c.call('PutObject', {'Bucket': _stdBucket, 'Key': 'p1/range/empty.bin'}, body: S3OpBody.text('')));
      c.status(await c.call('GetObject', {'Bucket': _stdBucket, 'Key': 'p1/range/empty.bin', 'Range': 'bytes=0-0'}), 416,
          code: 'InvalidRange');
    });
  }

  Future<void> _attributeChecks() async {
    await _check('object.attributes',
        category: 'Object CRUD',
        title: 'GetObjectAttributes returns size, ETag, storage class and checksum',
        spec: 'GetObjectAttributes: 200; ETag without quotes, ObjectSize, StorageClass, Checksum.ChecksumSHA256 for an object uploaded with SHA256.',
        body: (c) async {
      const key = 'p1/attributes/object.bin';
      final data = ConformanceBytes.generate(3000, 5);
      final put = await c.call('PutObject', {'Bucket': _stdBucket, 'Key': key, 'ChecksumAlgorithm': 'SHA256'},
          body: S3OpBody.generate(3000, 5));
      c.fixture(put);
      final o = await c.call('GetObjectAttributes', {
        'Bucket': _stdBucket,
        'Key': key,
        'ObjectAttributes': ['ETag', 'ObjectSize', 'StorageClass', 'Checksum'],
      });
      c.status(o, 200);
      c.equals('ETag (unquoted)', _unquoteEtag(put.header('etag')), o.field('ETag'),
          explanation: 'GetObjectAttributes returns the ETag without quotes.');
      c.equals('ObjectSize', 3000, o.field('ObjectSize'));
      c.equals('StorageClass', 'STANDARD', o.field('StorageClass'), informational: true);
      c.equals('Checksum.ChecksumSHA256', ConformanceBytes.sha256Base64(data), o.field('Checksum.ChecksumSHA256'));
      c.headerPresent(o, 'last-modified', informational: true);
    });
  }

  Future<void> _copyChecks() async {
    const source = 'p1/copy/src a+b%c ü.txt';
    final data = ConformanceBytes.generate(2048, 4);
    String? sourceEtag;
    final ready = await _check('copy.fixture',
        category: 'CopyObject',
        title: 'Create the copy source (key with space, +, % and Unicode)',
        spec: 'PutObject with Content-Type, metadata and tags: 200.',
        body: (c) async {
      final put = await c.call('PutObject', {
        'Bucket': _stdBucket,
        'Key': source,
        'ContentType': 'text/x-source',
        'Metadata': {'origin': 'source'},
        'Tagging': 'stage=source',
      }, body: S3OpBody.generate(2048, 4));
      c.fixture(put);
      sourceEtag = put.header('etag');
    });
    if (ready.status != ConformanceStatus.pass) return;
    final copySource = {'Bucket': _stdBucket, 'Key': source};
    await _check('copy.same-bucket',
        category: 'CopyObject',
        title: 'CopyObject within a bucket keeps metadata (COPY)',
        spec: 'CopyObject: 200 with CopyObjectResult ETag and LastModified; MetadataDirective COPY keeps Content-Type and x-amz-meta-*.',
        body: (c) async {
      const dest = 'p1/copy/dest-copy.txt';
      final o = await c.call('CopyObject', {'Bucket': _stdBucket, 'Key': dest, 'CopySource': copySource});
      c.status(o, 200);
      c.isTrue('CopyObjectResult.ETag', '${o.field('CopyObjectResult.ETag') ?? ''}'.isNotEmpty,
          expected: 'present', actual: o.field('CopyObjectResult.ETag'));
      c.equals('CopyObjectResult.ETag', sourceEtag, o.field('CopyObjectResult.ETag'), informational: true,
          explanation: 'A single-part copy normally keeps the MD5 ETag.');
      c.isTrue('CopyObjectResult.LastModified', _parseIso(o.field('CopyObjectResult.LastModified')) != null,
          expected: 'ISO-8601', actual: o.field('CopyObjectResult.LastModified'));
      final head = await c.call('HeadObject', {'Bucket': _stdBucket, 'Key': dest});
      c.header(head, 'content-type', 'text/x-source');
      c.header(head, 'x-amz-meta-origin', 'source');
      c.body(await c.call('GetObject', {'Bucket': _stdBucket, 'Key': dest}), data);
    });
    await _check('copy.replace-metadata',
        category: 'CopyObject',
        title: 'CopyObject with MetadataDirective REPLACE',
        spec: 'CopyObject REPLACE: the destination has only the metadata and Content-Type sent with the copy.',
        body: (c) async {
      const dest = 'p1/copy/dest-replace.txt';
      final o = await c.call('CopyObject', {
        'Bucket': _stdBucket,
        'Key': dest,
        'CopySource': copySource,
        'MetadataDirective': 'REPLACE',
        'Metadata': {'origin': 'replaced', 'extra': 'yes'},
        'ContentType': 'text/x-replaced',
      });
      c.status(o, 200);
      final head = await c.call('HeadObject', {'Bucket': _stdBucket, 'Key': dest});
      c.header(head, 'content-type', 'text/x-replaced');
      c.header(head, 'x-amz-meta-origin', 'replaced');
      c.header(head, 'x-amz-meta-extra', 'yes');
    });
    await _check('copy.special-destination',
        category: 'CopyObject',
        title: 'CopyObject to a destination key with special characters',
        spec: 'CopyObject: 200; the destination key is exactly the requested UTF-8 key.',
        body: (c) async {
      const dest = 'p1/copy/dest ü+%2B.txt';
      c.status(await c.call('CopyObject', {'Bucket': _stdBucket, 'Key': dest, 'CopySource': copySource}), 200);
      c.body(await c.call('GetObject', {'Bucket': _stdBucket, 'Key': dest}), data);
      final list = await c.call('ListObjectsV2', {'Bucket': _stdBucket, 'Prefix': dest});
      c.equals('ListObjectsV2 Contents[].Key', [dest], [for (final item in list.list('Contents')) item['Key']]);
    });
    await _check('copy.tagging',
        category: 'CopyObject',
        title: 'CopyObject copies tags, or replaces them with TaggingDirective REPLACE',
        spec: 'CopyObject: TaggingDirective COPY (default) keeps the source tag set; REPLACE uses x-amz-tagging.',
        body: (c) async {
      c.fixture(await c.call('CopyObject', {'Bucket': _stdBucket, 'Key': 'p1/copy/tags-copy.txt', 'CopySource': copySource}));
      final copied = await c.call('GetObjectTagging', {'Bucket': _stdBucket, 'Key': 'p1/copy/tags-copy.txt'});
      c.equals('TagSet (COPY)', [{'Key': 'stage', 'Value': 'source'}], _tags(copied));
      c.fixture(await c.call('CopyObject', {
        'Bucket': _stdBucket,
        'Key': 'p1/copy/tags-replace.txt',
        'CopySource': copySource,
        'TaggingDirective': 'REPLACE',
        'Tagging': 'stage=replaced',
      }));
      final replaced = await c.call('GetObjectTagging', {'Bucket': _stdBucket, 'Key': 'p1/copy/tags-replace.txt'});
      c.equals('TagSet (REPLACE)', [{'Key': 'stage', 'Value': 'replaced'}], _tags(replaced));
    });
    await _check('copy.cross-bucket',
        category: 'CopyObject',
        title: 'CopyObject into another bucket',
        spec: 'CopyObject between buckets: 200; the destination payload equals the source.',
        body: (c) async {
      _ownedBuckets.add(_peerBucket);
      c.fixture(await c.call('CreateBucket', _createBucketInput(_peerBucket)));
      c.status(await c.call('CopyObject', {'Bucket': _peerBucket, 'Key': 'copied.txt', 'CopySource': copySource}), 200);
      c.body(await c.call('GetObject', {'Bucket': _peerBucket, 'Key': 'copied.txt'}), data);
      // Remove the peer now; teardown retries anything left.
      await c.call('DeleteObject', {'Bucket': _peerBucket, 'Key': 'copied.txt'});
      final deleted = await c.call('DeleteBucket', {'Bucket': _peerBucket});
      if (deleted.isSuccess) _ownedBuckets.remove(_peerBucket);
    });
    await _check('copy.conditional',
        category: 'CopyObject',
        title: 'CopyObject with a failing x-amz-copy-source-if-match',
        spec: 'CopyObject CopySourceIfMatch with another ETag: 412 PreconditionFailed.',
        body: (c) async {
      c.status(await c.call('CopyObject', {
        'Bucket': _stdBucket,
        'Key': 'p1/copy/never.txt',
        'CopySource': copySource,
        'CopySourceIfMatch': '"00000000000000000000000000000000"',
      }), 412, code: 'PreconditionFailed');
      c.status(await c.call('CopyObject', {
        'Bucket': _stdBucket,
        'Key': 'p1/copy/if-match.txt',
        'CopySource': copySource,
        'CopySourceIfMatch': sourceEtag,
      }), 200);
    });
    await _check('copy.missing-source',
        category: 'CopyObject',
        title: 'CopyObject from a missing key',
        spec: 'CopyObject: 404 NoSuchKey.',
        body: (c) async {
      c.status(await c.call('CopyObject', {
        'Bucket': _stdBucket,
        'Key': 'p1/copy/never2.txt',
        'CopySource': {'Bucket': _stdBucket, 'Key': 'p1/copy/does-not-exist.txt'},
      }), 404, code: 'NoSuchKey');
    });
    await _check('copy.onto-itself',
        category: 'CopyObject',
        title: 'CopyObject onto itself without changes, then with REPLACE',
        spec: 'CopyObject source = destination with COPY: 400 InvalidRequest; with MetadataDirective REPLACE: 200.',
        severity: ConformanceSeverity.informational,
        body: (c) async {
      c.status(await c.call('CopyObject', {'Bucket': _stdBucket, 'Key': source, 'CopySource': copySource}), 400,
          code: 'InvalidRequest');
      c.status(await c.call('CopyObject', {
        'Bucket': _stdBucket,
        'Key': source,
        'CopySource': copySource,
        'MetadataDirective': 'REPLACE',
        'Metadata': {'origin': 'self'},
        'ContentType': 'text/x-source',
      }), 200);
    });
  }

  Future<void> _deleteChecks() async {
    await _check('delete.existing',
        category: 'DeleteObject',
        title: 'DeleteObject removes an object',
        spec: 'DeleteObject: 204 No Content; a following HeadObject returns 404.',
        body: (c) async {
      const key = 'p1/delete/existing.txt';
      c.fixture(await c.call('PutObject', {'Bucket': _stdBucket, 'Key': key}, body: S3OpBody.text('x')));
      c.status(await c.call('DeleteObject', {'Bucket': _stdBucket, 'Key': key}), 204);
      c.status(await c.call('HeadObject', {'Bucket': _stdBucket, 'Key': key}), 404);
    });
    await _check('delete.missing',
        category: 'DeleteObject',
        title: 'DeleteObject of a missing key is idempotent',
        spec: 'DeleteObject on a key that does not exist: 204 No Content (not 404).',
        body: (c) async {
      c.status(await c.call('DeleteObject', {'Bucket': _stdBucket, 'Key': 'p1/delete/never-existed.txt'}), 204);
    });
    await _check('delete.batch.verbose',
        category: 'DeleteObjects',
        title: 'DeleteObjects (verbose) reports every requested key',
        spec: 'DeleteObjects Quiet=false: 200; Deleted lists every key including missing ones; Errors is empty.',
        body: (c) async {
      final keys = ['p1/batch/one.txt', 'p1/batch/two ü.txt', 'p1/batch/three+&.txt'];
      for (final key in keys) {
        c.fixture(await c.call('PutObject', {'Bucket': _stdBucket, 'Key': key}, body: S3OpBody.text(key)));
      }
      final requested = [...keys, 'p1/batch/missing.txt'];
      final o = await c.call('DeleteObjects', {
        'Bucket': _stdBucket,
        'Delete': {'Objects': [for (final key in requested) {'Key': key}], 'Quiet': false},
      });
      c.status(o, 200);
      c.equals('Deleted[].Key', (List.of(requested)..sort()),
          ([for (final item in o.list('Deleted')) '${item['Key']}']..sort()));
      c.equals('Errors', 0, o.list('Errors').length);
      final list = await c.call('ListObjectsV2', {'Bucket': _stdBucket, 'Prefix': 'p1/batch/'});
      c.equals('Remaining keys', 0, list.list('Contents').length);
    });
    await _check('delete.batch.quiet',
        category: 'DeleteObjects',
        title: 'DeleteObjects (quiet) omits successful deletions',
        spec: 'DeleteObjects Quiet=true: 200; no Deleted entries; Errors empty.',
        body: (c) async {
      final keys = ['p1/batch-quiet/one.txt', 'p1/batch-quiet/two.txt'];
      for (final key in keys) {
        c.fixture(await c.call('PutObject', {'Bucket': _stdBucket, 'Key': key}, body: S3OpBody.text(key)));
      }
      final o = await c.call('DeleteObjects', {
        'Bucket': _stdBucket,
        'Delete': {'Objects': [for (final key in keys) {'Key': key}], 'Quiet': true},
      });
      c.status(o, 200);
      c.equals('Deleted', 0, o.list('Deleted').length);
      c.equals('Errors', 0, o.list('Errors').length);
      final list = await c.call('ListObjectsV2', {'Bucket': _stdBucket, 'Prefix': 'p1/batch-quiet/'});
      c.equals('Remaining keys', 0, list.list('Contents').length);
    });
  }

  Future<void> _taggingChecks() async {
    await _check('tagging.object.empty',
        category: 'Object tagging',
        title: 'GetObjectTagging on an untagged object',
        spec: 'GetObjectTagging: 200 with an empty TagSet (not 404).',
        body: (c) async {
      c.fixture(await c.call('PutObject', {'Bucket': _stdBucket, 'Key': 'p1/tags/untagged.txt'}, body: S3OpBody.text('x')));
      final o = await c.call('GetObjectTagging', {'Bucket': _stdBucket, 'Key': 'p1/tags/untagged.txt'});
      c.status(o, 200);
      c.equals('TagSet', const [], _tags(o));
    });
    await _check('tagging.object.crud',
        category: 'Object tagging',
        title: 'Put, get and delete object tags',
        spec: 'PutObjectTagging: 200; GetObjectTagging returns the set; HeadObject x-amz-tagging-count; DeleteObjectTagging: 204.',
        body: (c) async {
      const key = 'p1/tags/crud.txt';
      final tags = [{'Key': 'env', 'Value': 'test'}, {'Key': 'team', 'Value': 'storage qa'}];
      c.fixture(await c.call('PutObject', {'Bucket': _stdBucket, 'Key': key}, body: S3OpBody.text('x')));
      c.status(await c.call('PutObjectTagging', {'Bucket': _stdBucket, 'Key': key, 'Tagging': {'TagSet': tags}}), 200);
      c.equals('TagSet', tags, _tags(await c.call('GetObjectTagging', {'Bucket': _stdBucket, 'Key': key})));
      c.header(await c.call('HeadObject', {'Bucket': _stdBucket, 'Key': key}), 'x-amz-tagging-count', '2');
      c.status(await c.call('DeleteObjectTagging', {'Bucket': _stdBucket, 'Key': key}), 204);
      c.equals('TagSet after delete', const [], _tags(await c.call('GetObjectTagging', {'Bucket': _stdBucket, 'Key': key})));
    });
    await _check('tagging.object.on-put',
        category: 'Object tagging',
        title: 'Tags sent with PutObject (x-amz-tagging)',
        spec: 'PutObject Tagging query string is stored as the tag set.',
        body: (c) async {
      const key = 'p1/tags/on-put.txt';
      c.fixture(await c.call('PutObject', {'Bucket': _stdBucket, 'Key': key, 'Tagging': 'a=1&b=two%20words'},
          body: S3OpBody.text('x')));
      c.equals('TagSet', [{'Key': 'a', 'Value': '1'}, {'Key': 'b', 'Value': 'two words'}],
          _tags(await c.call('GetObjectTagging', {'Bucket': _stdBucket, 'Key': key})));
    });
    await _check('tagging.object.limit',
        category: 'Object tagging',
        title: 'More than 10 tags are rejected',
        spec: 'PutObjectTagging with 11 tags: 400 BadRequest (AWS documents the 10-tag limit).',
        severity: ConformanceSeverity.informational,
        body: (c) async {
      const key = 'p1/tags/limit.txt';
      c.fixture(await c.call('PutObject', {'Bucket': _stdBucket, 'Key': key}, body: S3OpBody.text('x')));
      final o = await c.call('PutObjectTagging', {
        'Bucket': _stdBucket,
        'Key': key,
        'Tagging': {'TagSet': [for (var i = 0; i < 11; i++) {'Key': 'k$i', 'Value': 'v'}]},
      });
      c.status(o, 400, code: 'BadRequest', alternativeCodes: const ['InvalidTag'], informationalCode: true);
    });
  }

  Future<void> _aclChecks() async {
    await _check('acl.object.get',
        category: 'Access control lists',
        title: 'GetObjectAcl returns the owner with FULL_CONTROL',
        spec: 'GetObjectAcl: 200; Owner.ID present; a grant of FULL_CONTROL to the owner.',
        body: (c) async {
      c.fixture(await c.call('PutObject', {'Bucket': _stdBucket, 'Key': 'p1/acl/object.txt'}, body: S3OpBody.text('x')));
      final o = await c.call('GetObjectAcl', {'Bucket': _stdBucket, 'Key': 'p1/acl/object.txt'});
      c.status(o, 200);
      _expectOwnerFullControl(c, o);
    });
    await _check('acl.object.put-private',
        category: 'Access control lists',
        title: 'PutObjectAcl with the private canned ACL',
        spec: 'PutObjectAcl ACL=private: 200, or 400 AccessControlListNotSupported when Object Ownership is BucketOwnerEnforced.',
        severity: ConformanceSeverity.informational,
        body: (c) async {
      final o = await c.call('PutObjectAcl', {'Bucket': _stdBucket, 'Key': 'p1/acl/object.txt', 'ACL': 'private'});
      if (o.httpStatus == 400 && o.errorCode == 'AccessControlListNotSupported') {
        c.note('ACLs are disabled for this bucket (BucketOwnerEnforced).');
        c.status(o, 400, code: 'AccessControlListNotSupported');
        return;
      }
      c.status(o, 200);
    });
    await _check('acl.bucket.get',
        category: 'Access control lists',
        title: 'GetBucketAcl returns the owner with FULL_CONTROL',
        spec: 'GetBucketAcl: 200; Owner.ID present; a grant of FULL_CONTROL to the owner.',
        body: (c) async {
      final o = await c.call('GetBucketAcl', {'Bucket': _stdBucket});
      c.status(o, 200);
      _expectOwnerFullControl(c, o);
    });
    await _check('acl.bucket.put-private',
        category: 'Access control lists',
        title: 'PutBucketAcl with the private canned ACL',
        spec: 'PutBucketAcl ACL=private: 200, or 400 AccessControlListNotSupported when ACLs are disabled.',
        severity: ConformanceSeverity.informational,
        body: (c) async {
      final o = await c.call('PutBucketAcl', {'Bucket': _stdBucket, 'ACL': 'private'});
      if (o.httpStatus == 400 && o.errorCode == 'AccessControlListNotSupported') {
        c.note('ACLs are disabled for this bucket (BucketOwnerEnforced).');
        c.status(o, 400, code: 'AccessControlListNotSupported');
        return;
      }
      c.status(o, 200);
    });
  }

  void _expectOwnerFullControl(_CheckContext c, S3OpObservation o) {
    final ownerId = o.field('Owner.ID')?.toString();
    c.isTrue('Owner.ID', ownerId != null && ownerId.isNotEmpty, expected: 'present', actual: ownerId);
    final grants = o.list('Grants');
    final full = grants.where((grant) => grant['Permission'] == 'FULL_CONTROL').toList();
    c.isTrue('Grants FULL_CONTROL', full.isNotEmpty, expected: 'at least one', actual: '${full.length} of ${grants.length}');
    if (full.isNotEmpty && ownerId != null) {
      final grantee = full.first['Grantee'];
      c.equals('FULL_CONTROL Grantee.ID', ownerId, grantee is Map ? grantee['ID'] : null, informational: true);
    }
  }

  Future<void> _presignChecks() async {
    await _check('presign.get',
        category: 'Presigned URLs',
        title: 'Presigned GET downloads the object',
        spec: 'A SigV4 query-signed GET (X-Amz-Algorithm, X-Amz-Credential, X-Amz-Date, X-Amz-Expires, X-Amz-SignedHeaders, X-Amz-Signature): 200 with the payload.',
        body: (c) async {
      const key = 'p1/presign/get ü+.bin';
      final data = ConformanceBytes.generate(1500, 30);
      c.fixture(await c.call('PutObject', {'Bucket': _stdBucket, 'Key': key}, body: S3OpBody.generate(1500, 30)));
      final o = await c.call('PresignedRequest', {'Method': 'GET', 'Bucket': _stdBucket, 'Key': key, 'ExpiresIn': 300});
      c.status(o, 200);
      c.body(o, data);
      final keys = [for (final value in (o.field('Presign.QueryKeys') as List?) ?? const []) '$value'];
      for (final required in const ['X-Amz-Algorithm', 'X-Amz-Credential', 'X-Amz-Date', 'X-Amz-Expires', 'X-Amz-SignedHeaders', 'X-Amz-Signature']) {
        c.isTrue('query parameter $required', keys.contains(required), expected: 'present', actual: keys.join(', '));
      }
    });
    await _check('presign.put',
        category: 'Presigned URLs',
        title: 'Presigned PUT uploads an object',
        spec: 'A presigned PUT with a signed Content-Type: 200 with an ETag; the object then reads back unchanged.',
        body: (c) async {
      const key = 'p1/presign/put.txt';
      const text = 'uploaded through a presigned URL';
      final o = await c.call('PresignedRequest', {'Method': 'PUT', 'Bucket': _stdBucket, 'Key': key, 'ContentType': 'text/plain', 'ExpiresIn': 300},
          body: S3OpBody.text(text));
      c.status(o, 200);
      c.headerPresent(o, 'etag');
      final get = await c.call('GetObject', {'Bucket': _stdBucket, 'Key': key});
      c.status(get, 200);
      c.body(get, utf8.encode(text));
      c.header(get, 'content-type', 'text/plain', informational: true);
    });
    await _check('presign.get-missing',
        category: 'Presigned URLs',
        title: 'Presigned GET of a missing key',
        spec: 'Presigned GET: 404 NoSuchKey.',
        body: (c) async {
      c.status(await c.call('PresignedRequest', {'Method': 'GET', 'Bucket': _stdBucket, 'Key': 'p1/presign/missing.txt', 'ExpiresIn': 300}), 404,
          code: 'NoSuchKey');
    });
    await _check('presign.expired',
        category: 'Presigned URLs',
        title: 'An expired presigned URL is refused',
        spec: 'Presigned GET used after X-Amz-Expires: 403 AccessDenied (Request has expired).',
        severity: ConformanceSeverity.informational,
        body: (c) async {
      c.fixture(await c.call('PutObject', {'Bucket': _stdBucket, 'Key': 'p1/presign/expiring.txt'}, body: S3OpBody.text('x')));
      c.status(await c.call('PresignedRequest', {
        'Method': 'GET', 'Bucket': _stdBucket, 'Key': 'p1/presign/expiring.txt', 'ExpiresIn': 1, 'DelayMs': 2500,
      }), 403, code: 'AccessDenied');
    });
  }

  Future<void> _encryptionChecks() async {
    await _check('sse.s3',
        category: 'Server-side encryption',
        title: 'SSE-S3 (AES256) object',
        spec: 'PutObject x-amz-server-side-encryption: AES256 — 200; PutObject, HeadObject and GetObject report AES256.',
        body: (c) async {
      const key = 'p1/sse/s3.bin';
      final data = ConformanceBytes.generate(2048, 50);
      final put = await c.call('PutObject', {'Bucket': _stdBucket, 'Key': key, 'ServerSideEncryption': 'AES256'},
          body: S3OpBody.generate(2048, 50));
      c.status(put, 200);
      c.header(put, 'x-amz-server-side-encryption', 'AES256');
      final head = await c.call('HeadObject', {'Bucket': _stdBucket, 'Key': key});
      c.header(head, 'x-amz-server-side-encryption', 'AES256');
      final get = await c.call('GetObject', {'Bucket': _stdBucket, 'Key': key});
      c.header(get, 'x-amz-server-side-encryption', 'AES256');
      c.body(get, data);
    });
    await _check('sse.kms',
        category: 'Server-side encryption',
        title: 'SSE-KMS object',
        spec: 'PutObject x-amz-server-side-encryption: aws:kms (with the configured key, if any): 200; responses report aws:kms. Endpoints without KMS return an error.',
        severity: ConformanceSeverity.informational,
        body: (c) async {
      if (!config.includeSseKms) c.skip('SSE-KMS checks are turned off.');
      const key = 'p1/sse/kms.bin';
      final put = await c.call('PutObject', {
        'Bucket': _stdBucket,
        'Key': key,
        'ServerSideEncryption': 'aws:kms',
        if (config.kmsKeyId.trim().isNotEmpty) 'SSEKMSKeyId': config.kmsKeyId.trim(),
      }, body: S3OpBody.generate(1024, 51));
      if (!put.isSuccess) {
        c.note('The endpoint refused SSE-KMS (${_CheckContext.describe(put)}); this is expected where no KMS is configured.');
      }
      c.status(put, 200);
      if (!put.isSuccess) return;
      c.header(put, 'x-amz-server-side-encryption', 'aws:kms');
      c.headerPresent(put, 'x-amz-server-side-encryption-aws-kms-key-id', informational: true);
      final get = await c.call('GetObject', {'Bucket': _stdBucket, 'Key': key});
      c.header(get, 'x-amz-server-side-encryption', 'aws:kms');
      c.body(get, ConformanceBytes.generate(1024, 51));
    });
    await _check('sse.c',
        category: 'Server-side encryption',
        title: 'SSE-C object with a customer-provided key',
        spec: 'PutObject/HeadObject/GetObject with x-amz-server-side-encryption-customer-*: 200 and AES256 reported; '
            'reading without the key: 400; with another key: 403; CopyObject re-encrypts with copy-source keys.',
        severity: ConformanceSeverity.informational,
        body: (c) async {
      if (!config.includeSseC) c.skip('SSE-C checks are turned off.');
      if (!endpoint.allowsCustomerKeys) {
        c.skip('SSE-C requires an HTTPS (or loopback) endpoint; customer keys are never sent over plain HTTP.');
      }
      // Throwaway keys, generated per run and never stored or reported.
      final key = base64.encode(List<int>.generate(32, (_) => _random.nextInt(256)));
      final other = base64.encode(List<int>.generate(32, (_) => _random.nextInt(256)));
      const objectKey = 'p1/sse/c.bin';
      final data = ConformanceBytes.generate(2048, 52);
      final put = await c.call('PutObject', {'Bucket': _stdBucket, 'Key': objectKey}, body: S3OpBody.generate(2048, 52), customerKey: key);
      if (put.httpStatus == 403) {
        c.note('The bucket blocks SSE-C writes (AWS blocks SSE-C on new buckets unless allowed).');
      }
      c.status(put, 200);
      if (!put.isSuccess) return;
      c.header(put, 'x-amz-server-side-encryption-customer-algorithm', 'AES256');
      c.status(await c.call('HeadObject', {'Bucket': _stdBucket, 'Key': objectKey}), 400,
          explanation: 'Reading an SSE-C object requires the key.');
      final head = await c.call('HeadObject', {'Bucket': _stdBucket, 'Key': objectKey}, customerKey: key);
      c.status(head, 200);
      c.header(head, 'x-amz-server-side-encryption-customer-algorithm', 'AES256');
      c.body(await c.call('GetObject', {'Bucket': _stdBucket, 'Key': objectKey}, customerKey: key), data);
      c.status(await c.call('GetObject', {'Bucket': _stdBucket, 'Key': objectKey}, customerKey: other), 403,
          code: 'AccessDenied', informationalCode: true);
      _state['sse.c.keys'] = (key, other);
    });
    await _check('sse.c.copy',
        category: 'Server-side encryption',
        title: 'CopyObject re-encrypts an SSE-C object with another customer key',
        spec: 'CopyObject with x-amz-copy-source-server-side-encryption-customer-* (source key) and x-amz-server-side-encryption-customer-* (new key): 200; the copy reads back only with the new key.',
        severity: ConformanceSeverity.informational,
        body: (c) async {
      final keys = _state['sse.c.keys'];
      if (keys is! (String, String)) c.skip('Prerequisite sse.c did not pass.');
      final (key, other) = keys;
      final copy = await c.call('CopyObject', {
        'Bucket': _stdBucket,
        'Key': 'p1/sse/c-copy.bin',
        'CopySource': {'Bucket': _stdBucket, 'Key': 'p1/sse/c.bin'},
      }, customerKey: other, sourceCustomerKey: key);
      c.status(copy, 200);
      c.header(copy, 'x-amz-server-side-encryption-customer-algorithm', 'AES256', informational: true);
      c.body(await c.call('GetObject', {'Bucket': _stdBucket, 'Key': 'p1/sse/c-copy.bin'}, customerKey: other),
          ConformanceBytes.generate(2048, 52));
      c.status(await c.call('HeadObject', {'Bucket': _stdBucket, 'Key': 'p1/sse/c-copy.bin'}, customerKey: key), 403,
          explanation: 'The copy is encrypted with the new key only.', informational: true);
    });
    _state.remove('sse.c.keys');
  }

  Future<void> _multipartChecks() async {
    final partSize = multipartPartSize;
    final part1 = ConformanceBytes.generate(partSize, 11);
    final part2 = ConformanceBytes.generate(1024, 12);
    const key = 'p1/mpu/basic.bin';
    String? uploadId;
    final parts = <Map<String, Object?>>[];
    await _check('multipart.create',
        category: 'Multipart upload',
        title: 'CreateMultipartUpload starts an upload',
        spec: 'CreateMultipartUpload: 200 with Bucket, Key and UploadId.',
        body: (c) async {
      final o = await c.call('CreateMultipartUpload', {
        'Bucket': _stdBucket,
        'Key': key,
        'ContentType': 'application/x-multipart',
        'Metadata': {'kind': 'multipart'},
      });
      c.status(o, 200);
      uploadId = o.field('UploadId')?.toString();
      c.isTrue('UploadId', uploadId != null && uploadId!.isNotEmpty, expected: 'present', actual: uploadId);
      c.equals('Key', key, o.field('Key'));
      c.equals('Bucket', _stdBucket, o.field('Bucket'), informational: true);
    });
    await _check('multipart.upload-part',
        category: 'Multipart upload',
        title: 'UploadPart stores parts and returns their ETags',
        spec: 'UploadPart: 200 with an ETag per part (the MD5 of the part for unencrypted uploads).',
        body: (c) async {
      c.requirePassed('multipart.create');
      final first = await c.call('UploadPart', {'Bucket': _stdBucket, 'Key': key, 'UploadId': uploadId, 'PartNumber': 1},
          body: S3OpBody.generate(partSize, 11));
      c.status(first, 200);
      c.equals('part 1 ETag', '"${ConformanceBytes.md5Hex(part1)}"', first.header('etag'), informational: true);
      final second = await c.call('UploadPart', {'Bucket': _stdBucket, 'Key': key, 'UploadId': uploadId, 'PartNumber': 2},
          body: S3OpBody.generate(1024, 12));
      c.status(second, 200);
      parts
        ..add({'PartNumber': 1, 'ETag': first.header('etag')})
        ..add({'PartNumber': 2, 'ETag': second.header('etag')});
    });
    await _check('multipart.list-parts',
        category: 'Multipart upload',
        title: 'ListParts reports uploaded parts and paginates',
        spec: 'ListParts: 200 with PartNumber, ETag and Size per part; MaxParts=1 sets IsTruncated and NextPartNumberMarker.',
        body: (c) async {
      c.requirePassed('multipart.upload-part');
      final all = await c.call('ListParts', {'Bucket': _stdBucket, 'Key': key, 'UploadId': uploadId});
      c.status(all, 200);
      final listed = all.list('Parts');
      c.equals('Parts[].PartNumber', [1, 2], [for (final p in listed) p['PartNumber']]);
      c.equals('Parts[].Size', [partSize, 1024], [for (final p in listed) p['Size']]);
      c.equals('Parts[].ETag', [for (final p in parts) p['ETag']], [for (final p in listed) p['ETag']]);
      final page1 = await c.call('ListParts', {'Bucket': _stdBucket, 'Key': key, 'UploadId': uploadId, 'MaxParts': 1});
      c.status(page1, 200);
      c.equals('page 1 IsTruncated', true, page1.field('IsTruncated'));
      c.equals('page 1 NextPartNumberMarker', '1', '${page1.field('NextPartNumberMarker')}');
      final page2 = await c.call('ListParts', {
        'Bucket': _stdBucket, 'Key': key, 'UploadId': uploadId, 'MaxParts': 1,
        'PartNumberMarker': page1.field('NextPartNumberMarker') ?? 1,
      });
      c.equals('page 2 Parts[].PartNumber', [2], [for (final p in page2.list('Parts')) p['PartNumber']]);
    });
    await _check('multipart.list-uploads',
        category: 'Multipart upload',
        title: 'ListMultipartUploads lists the in-progress upload',
        spec: 'ListMultipartUploads: 200; Uploads contains the Key and UploadId.',
        body: (c) async {
      c.requirePassed('multipart.create');
      final o = await c.call('ListMultipartUploads', {'Bucket': _stdBucket, 'Prefix': 'p1/mpu/'});
      c.status(o, 200);
      final found = o.list('Uploads').any((u) => u['Key'] == key && u['UploadId'] == uploadId);
      c.isTrue('Uploads contains the upload', found, expected: '$key / UploadId', actual: found ? 'present' : 'missing');
    });
    await _check('multipart.complete',
        category: 'Multipart upload',
        title: 'CompleteMultipartUpload assembles the object',
        spec: 'CompleteMultipartUpload: 200 with an ETag ending in "-2"; the object has the concatenated bytes, Content-Type and metadata.',
        body: (c) async {
      c.requirePassed('multipart.upload-part');
      final o = await c.call('CompleteMultipartUpload', {
        'Bucket': _stdBucket,
        'Key': key,
        'UploadId': uploadId,
        'MultipartUpload': {'Parts': parts},
      });
      c.status(o, 200);
      final etag = '${o.field('ETag') ?? o.header('etag') ?? ''}';
      c.isTrue('ETag', _unquoteEtag(etag).endsWith('-2'), expected: 'ends with -2', actual: etag);
      c.equals('Key', key, o.field('Key'), informational: true);
      final head = await c.call('HeadObject', {'Bucket': _stdBucket, 'Key': key});
      c.header(head, 'content-length', '${partSize + 1024}');
      c.header(head, 'content-type', 'application/x-multipart');
      c.header(head, 'x-amz-meta-kind', 'multipart');
      c.body(await c.call('GetObject', {'Bucket': _stdBucket, 'Key': key}), _concat([part1, part2]));
      _state['mpu.complete'] = true;
    });
    await _check('multipart.part-number-read',
        category: 'Multipart upload',
        title: 'GetObject PartNumber=1 returns the first part',
        spec: 'GetObject partNumber=1: 206 with Content-Length of part 1 and x-amz-mp-parts-count: 2.',
        severity: ConformanceSeverity.informational,
        body: (c) async {
      c.requirePassed('multipart.complete');
      final o = await c.call('GetObject', {'Bucket': _stdBucket, 'Key': key, 'PartNumber': 1});
      c.status(o, 206);
      c.header(o, 'x-amz-mp-parts-count', '2');
      c.body(o, part1);
      final attributes = await c.call('GetObjectAttributes', {'Bucket': _stdBucket, 'Key': key, 'ObjectAttributes': ['ObjectParts']});
      c.equals('ObjectParts.TotalPartsCount', 2, attributes.field('ObjectParts.TotalPartsCount'));
    });
    await _check('multipart.upload-part-copy',
        category: 'Multipart upload',
        title: 'UploadPartCopy copies a byte range into a part',
        spec: 'UploadPartCopy with x-amz-copy-source-range: 200 with CopyPartResult.ETag; the completed object holds the copied range.',
        body: (c) async {
      const sourceKey = 'p1/mpu/copy source+.bin';
      const destKey = 'p1/mpu/part-copy.bin';
      final source = ConformanceBytes.generate(partSize + 4096, 13);
      final tail = ConformanceBytes.generate(512, 14);
      c.fixture(await c.call('PutObject', {'Bucket': _stdBucket, 'Key': sourceKey}, body: S3OpBody.generate(partSize + 4096, 13)));
      final create = await c.call('CreateMultipartUpload', {'Bucket': _stdBucket, 'Key': destKey});
      c.fixture(create);
      final id = create.field('UploadId');
      final copy = await c.call('UploadPartCopy', {
        'Bucket': _stdBucket,
        'Key': destKey,
        'UploadId': id,
        'PartNumber': 1,
        'CopySource': {'Bucket': _stdBucket, 'Key': sourceKey},
        'CopySourceRange': 'bytes=0-${partSize - 1}',
      });
      c.status(copy, 200);
      final copiedEtag = copy.field('CopyPartResult.ETag');
      c.isTrue('CopyPartResult.ETag', '${copiedEtag ?? ''}'.isNotEmpty, expected: 'present', actual: copiedEtag);
      final second = await c.call('UploadPart', {'Bucket': _stdBucket, 'Key': destKey, 'UploadId': id, 'PartNumber': 2},
          body: S3OpBody.generate(512, 14));
      c.fixture(second);
      final complete = await c.call('CompleteMultipartUpload', {
        'Bucket': _stdBucket,
        'Key': destKey,
        'UploadId': id,
        'MultipartUpload': {
          'Parts': [
            {'PartNumber': 1, 'ETag': copiedEtag},
            {'PartNumber': 2, 'ETag': second.header('etag')},
          ]
        },
      });
      c.status(complete, 200);
      c.body(await c.call('GetObject', {'Bucket': _stdBucket, 'Key': destKey}), _concat([source.sublist(0, partSize), tail]));
    });
    await _check('multipart.abort',
        category: 'Multipart upload',
        title: 'AbortMultipartUpload discards an upload',
        spec: 'AbortMultipartUpload: 204; afterwards ListParts returns 404 NoSuchUpload and the upload is no longer listed.',
        body: (c) async {
      const abortKey = 'p1/mpu/aborted.bin';
      final create = await c.call('CreateMultipartUpload', {'Bucket': _stdBucket, 'Key': abortKey});
      c.fixture(create);
      final id = create.field('UploadId');
      c.fixture(await c.call('UploadPart', {'Bucket': _stdBucket, 'Key': abortKey, 'UploadId': id, 'PartNumber': 1},
          body: S3OpBody.text('part')));
      c.status(await c.call('AbortMultipartUpload', {'Bucket': _stdBucket, 'Key': abortKey, 'UploadId': id}), 204);
      c.status(await c.call('ListParts', {'Bucket': _stdBucket, 'Key': abortKey, 'UploadId': id}), 404, code: 'NoSuchUpload');
      final uploads = await c.call('ListMultipartUploads', {'Bucket': _stdBucket, 'Prefix': abortKey});
      c.isTrue('Uploads', !uploads.list('Uploads').any((u) => u['UploadId'] == id),
          expected: 'upload not listed', actual: '${uploads.list('Uploads').length} listed');
      c.status(await c.call('HeadObject', {'Bucket': _stdBucket, 'Key': abortKey}), 404);
    });
    await _check('multipart.entity-too-small',
        category: 'Multipart upload',
        title: 'A non-final part below 5 MiB is rejected at completion',
        spec: 'CompleteMultipartUpload with a 1 KiB first part: 400 EntityTooSmall.',
        body: (c) async {
      await _rejectedCompletion(c, 'p1/mpu/too-small.bin', [S3OpBody.text('a' * 1024), S3OpBody.text('b' * 1024)],
          (etags) => [for (var i = 0; i < etags.length; i++) {'PartNumber': i + 1, 'ETag': etags[i]}], 'EntityTooSmall');
    });
    await _check('multipart.invalid-part',
        category: 'Multipart upload',
        title: 'Completion with an unknown part ETag is rejected',
        spec: 'CompleteMultipartUpload with a wrong ETag: 400 InvalidPart.',
        body: (c) async {
      await _rejectedCompletion(c, 'p1/mpu/invalid-part.bin', [S3OpBody.text('only part')],
          (_) => [{'PartNumber': 1, 'ETag': '"00000000000000000000000000000000"'}], 'InvalidPart');
    });
    await _check('multipart.invalid-part-order',
        category: 'Multipart upload',
        title: 'Parts listed out of order are rejected',
        spec: 'CompleteMultipartUpload with descending part numbers: 400 InvalidPartOrder.',
        body: (c) async {
      await _rejectedCompletion(c, 'p1/mpu/invalid-order.bin', [S3OpBody.generate(partSize, 15), S3OpBody.text('tail')],
          (etags) => [{'PartNumber': 2, 'ETag': etags[1]}, {'PartNumber': 1, 'ETag': etags[0]}], 'InvalidPartOrder');
    });
    await _check('multipart.list-uploads.pagination',
        category: 'Multipart upload',
        title: 'ListMultipartUploads paginates with key and upload-ID markers',
        spec: 'ListMultipartUploads MaxUploads=1: IsTruncated with NextKeyMarker and NextUploadIdMarker; the next page lists the other upload.',
        body: (c) async {
      final ids = <String, Object?>{};
      for (final k in ['p1/mpu/page-a.bin', 'p1/mpu/page-b.bin']) {
        final create = await c.call('CreateMultipartUpload', {'Bucket': _stdBucket, 'Key': k});
        c.fixture(create);
        ids[k] = create.field('UploadId');
      }
      try {
        final page1 = await c.call('ListMultipartUploads', {'Bucket': _stdBucket, 'Prefix': 'p1/mpu/page-', 'MaxUploads': 1});
        c.status(page1, 200);
        c.equals('page 1 IsTruncated', true, page1.field('IsTruncated'));
        c.equals('page 1 Uploads[].Key', ['p1/mpu/page-a.bin'], [for (final u in page1.list('Uploads')) u['Key']]);
        final page2 = await c.call('ListMultipartUploads', {
          'Bucket': _stdBucket,
          'Prefix': 'p1/mpu/page-',
          'MaxUploads': 1,
          'KeyMarker': page1.field('NextKeyMarker'),
          'UploadIdMarker': page1.field('NextUploadIdMarker'),
        });
        c.equals('page 2 Uploads[].Key', ['p1/mpu/page-b.bin'], [for (final u in page2.list('Uploads')) u['Key']]);
      } finally {
        for (final entry in ids.entries) {
          await _quiet('AbortMultipartUpload', {'Bucket': _stdBucket, 'Key': entry.key, 'UploadId': entry.value});
        }
      }
    });
  }

  Future<void> _rejectedCompletion(_CheckContext c, String key, List<S3OpBody> bodies,
      List<Map<String, Object?>> Function(List<String?> etags) parts, String code) async {
    final create = await c.call('CreateMultipartUpload', {'Bucket': _stdBucket, 'Key': key});
    c.fixture(create);
    final id = create.field('UploadId');
    try {
      final etags = <String?>[];
      for (var i = 0; i < bodies.length; i++) {
        final part = await c.call('UploadPart', {'Bucket': _stdBucket, 'Key': key, 'UploadId': id, 'PartNumber': i + 1}, body: bodies[i]);
        c.fixture(part);
        etags.add(part.header('etag'));
      }
      final o = await c.call('CompleteMultipartUpload', {
        'Bucket': _stdBucket,
        'Key': key,
        'UploadId': id,
        'MultipartUpload': {'Parts': parts(etags)},
      });
      c.status(o, 400, code: code);
    } finally {
      await _quiet('AbortMultipartUpload', {'Bucket': _stdBucket, 'Key': key, 'UploadId': id});
    }
  }
}

List<Map<String, Object?>> _tags(S3OpObservation o) => [
      for (final tag in o.list('TagSet')) {'Key': tag['Key'], 'Value': tag['Value']}
    ]..sort((a, b) => '${a['Key']}'.compareTo('${b['Key']}'));
