part of 'mobile_storage_admin.dart';

extension MobileStorageTransfers on MobileStorageAdmin {
  Future<Map<String, Object?>> copyStorageObject(EndpointProfile source,
      EndpointProfile destination, Map<String, Object?> args) async {
    final from = client(source), to = client(destination);
    final sourceBucket = '${args['sourceBucketName']}',
        sourceKey = '${args['sourceKey']}';
    final bucket = '${args['destinationBucketName']}',
        key = '${args['destinationKey']}';
    final version = args['sourceVersionId'] as String?;
    final sameEndpoint = from.uri('').toString() == to.uri('').toString() ||
        (source.endpointType == EndpointProfileType.awsS3 &&
            destination.endpointType == EndpointProfileType.awsS3 &&
            source.region.startsWith('cn-') ==
                destination.region.startsWith('cn-') &&
            source.region.startsWith('us-gov-') ==
                destination.region.startsWith('us-gov-'));
    if (sameEndpoint &&
        sourceBucket == bucket &&
        sourceKey == key &&
        (args['move'] == true || args['options'] is! Map)) {
      MobileStorageAdmin._invalid('Choose a different destination object.');
    }
    final query = <String, String>{
      if (version != null) from.azure ? 'versionid' : 'versionId': version
    };
    final head =
        await from.request('HEAD', sourceBucket, key: sourceKey, query: query);
    final etag = head.headers['etag'];
    if (etag == null) {
      MobileStorageAdmin._conflict(
          'The source did not supply an ETag for a consistent copy.');
    }
    if (args['expectedSourceETag'] != null &&
        args['expectedSourceETag'] != etag) {
      MobileStorageAdmin._conflict('The source changed since it was listed.');
    }
    final size = int.parse(head.headers['content-length']!);
    final conflict = '${args['conflictPolicy'] ?? 'fail'}';
    if (!{'skip', 'fail', 'replace'}.contains(conflict)) {
      MobileStorageAdmin._invalid('Select a copy conflict policy.');
    }
    if (conflict != 'replace') {
      try {
        await to.request('HEAD', bucket, key: key);
        if (conflict == 'skip') {
          return {'skipped': true, 'successCount': 0, 'failureCount': 0};
        }
        MobileStorageAdmin._conflict('The destination key already exists.');
      } on StorageHttpException catch (e) {
        if (e.response.status != 404) rethrow;
      }
    }
    final options = args['options'] as Map? ?? {};
    final sourceMetadata = <String, String>{
      for (final h in head.headers.entries)
        if (h.key.startsWith(from.azure ? 'x-ms-meta-' : 'x-amz-meta-'))
          h.key.substring(from.azure ? 10 : 11): h.value
    };
    final metadata = options['metadata'] as Map? ?? sourceMetadata;
    final props = <String, String>{
      for (final h in MobileStorageAdmin.contentHeaders.entries)
        if (head.headers[h.value] != null) h.value: head.headers[h.value]!
    };
    for (final header in (options['headers'] as Map? ?? {}).entries) {
      final name = '${header.key}'.toLowerCase(), value = '${header.value}';
      if (!MobileStorageAdmin.contentHeaders.values.contains(name) ||
          value.contains(RegExp(r'[\r\n]'))) {
        MobileStorageAdmin._invalid(
            'Only supported content headers without line breaks can be changed.');
      }
      if (value.isEmpty) {
        props.remove(name);
      } else {
        props[name] = value;
      }
    }
    final selfCopy = sameEndpoint && sourceBucket == bucket && sourceKey == key;
    final headers = <String, String>{
      for (final m in metadata.entries)
        '${to.azure ? 'x-ms-meta-' : 'x-amz-meta-'}${m.key}': '${m.value}',
      for (final p in props.entries) p.key.toLowerCase(): p.value,
      if (options['storageClass'] != null &&
          '${options['storageClass']}'.isNotEmpty)
        to.azure ? 'x-ms-access-tier' : 'x-amz-storage-class':
            '${options['storageClass']}'
    };
    if (!to.azure) {
      if (selfCopy) {
        for (final name in [
          'x-amz-server-side-encryption',
          'x-amz-server-side-encryption-aws-kms-key-id',
          'x-amz-server-side-encryption-bucket-key-enabled',
          'x-amz-storage-class'
        ]) {
          if (head.headers[name] != null) {
            headers.putIfAbsent(name, () => head.headers[name]!);
          }
        }
      }
      if (options['encryption'] is Map) {
        final encryption = options['encryption'] as Map;
        final algorithm =
            encryption['ServerSideEncryption'] ?? encryption['algorithm'];
        if (!{'AES256', 'aws:kms', 'aws:kms:dsse'}.contains(algorithm)) {
          MobileStorageAdmin._invalid(
              'Select a supported encryption algorithm.');
        }
        headers['x-amz-server-side-encryption'] = '$algorithm';
        headers.remove('x-amz-server-side-encryption-aws-kms-key-id');
        headers.remove('x-amz-server-side-encryption-bucket-key-enabled');
        final key = encryption['SSEKMSKeyId'] ?? encryption['kmsKeyId'];
        if (key != null && '$algorithm'.startsWith('aws:kms')) {
          headers['x-amz-server-side-encryption-aws-kms-key-id'] = '$key';
        }
      }
    }
    // Read the tag set before any destination mutation. A denied read must not
    // silently publish a copy with tags missing.
    final tagResult =
        await action(profile: source, action: 'objectTags', arguments: {
      'bucketName': sourceBucket,
      'key': sourceKey,
      if (version != null) 'versionId': version
    });
    final tags = tagResult['tags'] as Map? ?? {};
    if (tags.isNotEmpty) {
      headers[to.azure ? 'x-ms-tags' : 'x-amz-tagging'] = tags.entries
          .map((t) =>
              '${storageUriEncode('${t.key}')}=${storageUriEncode('${t.value}')}')
          .join('&');
    }
    Future<List<int>> read(int start, int count) async {
      if (count == 0) return [];
      final response = await from.request('GET', sourceBucket,
          key: sourceKey,
          query: query,
          headers: {
            'range': 'bytes=$start-${start + count - 1}',
            'if-match': etag
          },
          maxResponseBytes: count);
      _validateRange(response, start, count, size, etag);
      return response.body;
    }

    try {
      final response = await _writeObject(to, bucket, key, size, read,
          headers: headers,
          conflict: conflict,
          expectedDestinationETag: selfCopy && version == null ? etag : null);
      final destinationVersion =
          response.headers[to.azure ? 'x-ms-version-id' : 'x-amz-version-id'];
      if (response.headers['etag'] == null && destinationVersion == null) {
        throw const EngineException(
            code: ErrorCode.unknown,
            message:
                'The copy response omitted its destination identity. Inspect the destination before retrying.');
      }
      final verified = await to.request('HEAD', bucket, key: key, query: {
        if (destinationVersion != null)
          to.azure ? 'versionid' : 'versionId': destinationVersion
      });
      if (int.tryParse(verified.headers['content-length'] ?? '') != size ||
          (response.headers['etag'] != null &&
              response.headers['etag'] != verified.headers['etag'])) {
        MobileStorageAdmin._conflict(
            'The destination changed before the copy could be verified.');
      }
      if (args['move'] == true) {
        await from.request('DELETE', sourceBucket,
            key: sourceKey, query: query, headers: {'if-match': etag});
      }
      return {
        'successCount': 1,
        'failureCount': 0,
        'failures': [],
        'bytesCopied': size,
        'destinationVersionId': destinationVersion,
        'etag': verified.headers['etag']
      };
    } on StorageHttpException catch (e) {
      if (e.response.status == 412 && conflict == 'skip') {
        return {'skipped': true, 'successCount': 0, 'failureCount': 0};
      }
      rethrow;
    }
  }

  Future<StorageHttpResponse> _writeObject(
      StorageHttpClient http,
      String bucket,
      String key,
      int size,
      Future<List<int>> Function(int start, int count) read,
      {Map<String, String> headers = const {},
      String conflict = 'replace',
      String? expectedDestinationETag,
      Future<void> Function()? verifySource,
      int partBytes = 8 * 1024 * 1024}) async {
    if (size > 50000 * 1024 * 1024 * 1024) {
      MobileStorageAdmin._invalid(
          'Object exceeds the supported transfer limit.');
    }
    final maximumParts = http.azure ? 50000 : 10000;
    final maximumPartSize = (http.azure ? 4000 : 5120) * 1024 * 1024;
    final partSize = max(min(partBytes, maximumPartSize),
        (size + maximumParts - 1) ~/ maximumParts);
    if (partSize > maximumPartSize) {
      MobileStorageAdmin._invalid(
          'Object exceeds this provider’s multipart limit.');
    }
    final condition = <String, String>{
      if (conflict != 'replace') 'if-none-match': '*',
      if (expectedDestinationETag != null) 'if-match': expectedDestinationETag
    };
    Future<StorageHttpResponse> sendPart(int offset, int count,
        Map<String, String> query, Map<String, String> partHeaders,
        {bool retrySafe = true}) async {
      if (count <= 128 * 1024 * 1024) {
        final bytes = await read(offset, count);
        if (!retrySafe) await verifySource?.call();
        return http.request('PUT', bucket,
            key: key,
            query: query,
            headers: partHeaders,
            body: bytes,
            retrySafe: retrySafe);
      }
      Stream<List<int>> stream() async* {
        const chunk = 8 * 1024 * 1024;
        for (var index = 0; index < count; index += chunk) {
          ActionScope.current?.check();
          yield await read(offset + index, min(chunk, count - index));
        }
      }

      final hash =
          http.azure ? null : (await sha256.bind(stream()).first).toString();
      return http.requestStream('PUT', bucket,
          key: key,
          query: query,
          headers: partHeaders,
          body: stream,
          bodyLength: count,
          payloadSha256: hash,
          retrySafe: retrySafe);
    }

    final count = (size + partSize - 1) ~/ partSize;
    final workers = min(
        count,
        min(http.profile.maxConcurrentRequests.clamp(1, 16),
            max(1, (256 * 1024 * 1024) ~/ min(partSize, 128 * 1024 * 1024))));
    if (size <= partSize) {
      return sendPart(
          0,
          size,
          {},
          {
            ...headers,
            ...condition,
            if (http.azure) 'x-ms-blob-type': 'BlockBlob'
          },
          retrySafe: false);
    }
    if (http.azure) {
      final prefix =
          '${DateTime.now().microsecondsSinceEpoch}-${Random.secure().nextInt(1 << 32)}';
      final blocks =
          await _parallelParts<String>(count, workers, (number) async {
        final offset = number * partSize;
        final id = base64Encode(
            utf8.encode('$prefix-${number.toString().padLeft(6, '0')}'));
        await sendPart(offset, min(partSize, size - offset),
            {'comp': 'block', 'blockid': id}, {});
        return id;
      });
      await verifySource?.call();
      final body = utf8.encode(
          '<BlockList>${blocks.map((id) => '<Latest>$id</Latest>').join()}</BlockList>');
      return http.request('PUT', bucket,
          key: key,
          query: {'comp': 'blocklist'},
          body: body,
          headers: {
            ...headers,
            ...condition,
            for (final h in headers.entries)
              if (MobileStorageAdmin.contentHeaders.values.contains(h.key))
                'x-ms-blob-${h.key}': h.value
          });
    }
    final start = await http.request('POST', bucket,
        key: key, query: {'uploads': ''}, headers: headers);
    final uploadId = xmlText(start.xml, 'UploadId');
    if (uploadId.isEmpty) {
      throw StateError('The endpoint did not return a multipart upload ID.');
    }
    var completing = false;
    try {
      final parts = await _parallelParts<Map<String, Object?>>(count, workers,
          (number) async {
        final offset = number * partSize;
        final part = await sendPart(offset, min(partSize, size - offset),
            {'uploadId': uploadId, 'partNumber': '${number + 1}'}, {});
        if (part.headers['etag'] == null) {
          throw StateError('An uploaded part has no ETag.');
        }
        return {'PartNumber': number + 1, 'ETag': part.headers['etag']};
      });
      await verifySource?.call();
      completing = true;
      final result = await http.request('POST', bucket,
          key: key,
          query: {'uploadId': uploadId},
          headers: condition,
          body: storageXml('CompleteMultipartUpload', {'Parts': parts}));
      if (result.xml.name.local == 'Error') {
        throw StorageHttpException(
            StorageHttpResponse(500, result.headers, result.body));
      }
      final etag = xmlText(result.xml, 'ETag');
      return StorageHttpResponse(result.status,
          {...result.headers, if (etag.isNotEmpty) 'etag': etag}, result.body);
    } catch (error) {
      // An ambiguous completion may have published an object. Never replay it.
      // Aborting a definitively rejected completion removes only its upload ID.
      if (!completing || error is StorageHttpException) {
        try {
          await ActionScope(inheritParent: false).run(() => http.request(
              'DELETE', bucket,
              key: key, query: {'uploadId': uploadId}));
        } catch (_) {/* Available through multipart recovery. */}
      }
      rethrow;
    }
  }

  Future<Map<String, Object?>> downloadStorageObject(
      EndpointProfile profile, Map<String, Object?> args) async {
    final http = client(profile),
        bucket = '${args['bucketName']}',
        key = '${args['key']}';
    final query = <String, String>{
      if (args['versionId'] != null)
        http.azure ? 'versionid' : 'versionId': '${args['versionId']}'
    };
    final head = await http.request('HEAD', bucket, key: key, query: query);
    final size = int.parse(head.headers['content-length']!),
        etag = head.headers['etag'];
    if (etag == null) {
      MobileStorageAdmin._conflict(
          'The endpoint did not return an ETag for a consistent download.');
    }
    final directory =
        Directory('${args['destinationDirectory'] ?? args['destinationPath']}');
    if (!await directory.exists()) {
      MobileStorageAdmin._invalid('Choose an existing download directory.');
    }
    final resolved = await directory.resolveSymbolicLinks();
    var name = key.split('/').last;
    if (name.isEmpty || {'.', '..'}.contains(name)) {
      name =
          'object-${sha256.convert(utf8.encode(key)).toString().substring(0, 12)}';
    }
    name = name.replaceAll(RegExp(r'[\\\x00-\x1f]'), '_');
    final destination = File('$resolved/$name');
    final staging = await Directory(resolved).createTemp('.object-browser-');
    final temp = File('${staging.path}/download');
    final file = await temp.open(mode: FileMode.write);
    try {
      const range = 8 * 1024 * 1024;
      for (var start = 0; start < size; start += range) {
        final count = min(range, size - start);
        final data = await http.request('GET', bucket,
            key: key,
            query: query,
            headers: {
              'range': 'bytes=$start-${start + count - 1}',
              'if-match': etag
            },
            maxResponseBytes: count);
        _validateRange(data, start, count, size, etag);
        await file.writeFrom(data.body);
      }
      await file.flush();
      await file.close();
      ActionScope.current?.check();
      var output = destination;
      if (args['conflictPolicy'] != 'replace') {
        var suffix = 0;
        // Reserve a previously unused name before atomic publication.
        while (true) {
          output =
              File('${destination.path}${suffix == 0 ? '' : ' ($suffix)'}');
          if (await FileSystemEntity.type(output.path, followLinks: false) ==
              FileSystemEntityType.notFound) {
            // Reserve the name exclusively, then replace only our reservation.
            try {
              await output.create(exclusive: true);
              break;
            } on FileSystemException {/* raced */}
          }
          suffix++;
        }
      }
      await temp.rename(output.path);
      return {
        'status': 'completed',
        'path': output.path,
        'fileSize': size,
        'completedBytes': size,
        'successCount': 1,
        'failureCount': 0
      };
    } finally {
      try {
        await file.close();
      } catch (_) {}
      if (await staging.exists()) await staging.delete(recursive: true);
    }
  }

  static void _validateRange(StorageHttpResponse response, int start, int count,
      int total, String etag) {
    if (response.status != 206 ||
        response.body.length != count ||
        response.headers['content-range'] !=
            'bytes $start-${start + count - 1}/$total' ||
        response.headers['etag'] != etag) {
      MobileStorageAdmin._conflict(
          'The object changed or the endpoint returned an invalid range.');
    }
  }

  Future<Map<String, Object?>> uploadStorageFile(
      EndpointProfile profile, Map<String, Object?> args) async {
    final paths = List<String>.from(args['filePaths'] as List? ?? []);
    var total = 0;
    for (final path in paths) {
      final file = File(path), before = await File(path).stat();
      Future<void> verifySource() async {
        final current = await file.stat();
        if (current.size != before.size ||
            current.modified != before.modified) {
          MobileStorageAdmin._conflict('The local file changed during upload.');
        }
      }

      {
        final key = (args['objectKeyByPath'] as Map?)?[path] as String? ??
            '${args['prefix'] ?? ''}${file.uri.pathSegments.last}';
        await _writeObject(
            client(profile), '${args['bucketName']}', key, before.size,
            (start, count) async {
          await verifySource();
          final handle = await file.open();
          late List<int> data;
          try {
            await handle.setPosition(start);
            data = await handle.read(count);
          } finally {
            await handle.close();
          }
          await verifySource();
          if (data.length != count) {
            MobileStorageAdmin._conflict(
                'The local file changed during upload.');
          }
          return data;
        },
            verifySource: verifySource,
            partBytes: ((args['multipartChunkMiB'] as num?)?.toInt() ?? 8)
                    .clamp(5, 5120) *
                1024 *
                1024);
        total += before.size;
      }
    }
    return transferResult('upload', total);
  }

  Map<String, Object?> transferResult(String direction, int size) => {
        'id': 'mobile-${DateTime.now().microsecondsSinceEpoch}',
        'direction': direction,
        'status': 'completed',
        'totalBytes': size,
        'bytesTransferred': size,
        'label': 'Completed $direction',
        'canPause': false,
        'canResume': false,
        'canCancel': false,
        'progress': 1.0,
        'bytesPerSecond': 0,
        'startedAt': DateTime.now().toUtc().toIso8601String(),
        'completedAt': DateTime.now().toUtc().toIso8601String(),
      };
}

Future<List<T>> _parallelParts<T>(
    int count, int workers, Future<T> Function(int) operation) async {
  final results = List<T?>.filled(count, null);
  var next = 0;
  Object? error;
  StackTrace? trace;
  await Future.wait(List.generate(workers, (_) async {
    while (error == null && next < count) {
      final index = next++;
      try {
        ActionScope.current?.check();
        results[index] = await operation(index);
      } catch (e, stack) {
        error ??= e;
        trace ??= stack;
      }
    }
  }));
  if (error != null) Error.throwWithStackTrace(error!, trace!);
  return results.cast<T>();
}
