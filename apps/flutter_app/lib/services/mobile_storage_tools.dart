part of 'mobile_storage_admin.dart';

extension MobileStorageTools on MobileStorageAdmin {
  Future<Map<String, Object?>> runStoragePutTestData(
      EndpointProfile profile, Map<String, Object?> arguments) async {
    final config =
        Map<String, Object?>.from(arguments['config'] as Map? ?? arguments);
    final bucket = '${config['bucketName'] ?? ''}',
        prefix = '${config['prefix'] ?? ''}';
    final size = (config['objectSizeBytes'] as num?)?.toInt() ?? 0;
    final count = (config['objectCount'] as num?)?.toInt() ?? 1;
    final versions = (config['versions'] as num?)?.toInt() ?? 1;
    final threads = ((config['threads'] as num?)?.toInt() ?? 1).clamp(1, 8);
    if (bucket.isEmpty ||
        size < 0 ||
        size > MultipartSizing.maximumObjectBytes ||
        count < 0 ||
        versions < 1) {
      MobileStorageAdmin._invalid(
          'Choose a container, a supported object size, nonnegative object count and at least one write per key.');
    }
    final partSize = MultipartSizing.recommendedPartSizeMiB(size);
    final directory =
        await Directory.systemTemp.createTemp('object-browser-testdata-');
    var position = 0, success = 0, failures = 0;
    var stop = false;
    var exitCode = 0;
    final lines = <String>[
      'Bucket: $bucket; prefix: $prefix.',
      'Requested $count keys, $versions writes per key, $size bytes per write. Existing bucket versioning determines retained versions.'
    ];
    try {
      await Future.wait([
        for (var worker = 0; worker < min(threads, count); worker++)
          () async {
            final file = File('${directory.path}/payload-$worker');
            final handle = await file.open(mode: FileMode.write);
            try {
              final block = List<int>.filled(min(size, 1024 * 1024), 65);
              var remaining = size;
              while (remaining > 0) {
                ActionScope.current?.check();
                final length = min(remaining, block.length);
                await handle.writeFrom(block, 0, length);
                remaining -= length;
              }
            } finally {
              await handle.close();
            }
            while (!stop && position < count) {
              ActionScope.current?.check();
              final index = position++;
              final key =
                  '${prefix}testdata-${index.toString().padLeft(6, '0')}.bin';
              for (var version = 0; version < versions; version++) {
                if (stop) break;
                ActionScope.current?.check();
                try {
                  await uploadStorageFile(profile, {
                    'bucketName': bucket,
                    'filePaths': [file.path],
                    'objectKeyByPath': {file.path: key},
                    'multipartChunkMiB': partSize
                  });
                  success++;
                } catch (error) {
                  stop = true;
                  failures++;
                  if (lines.length < 100) {
                    lines.add(
                        '$key: ${error is EngineException ? error.message : 'Upload failed (${error.runtimeType}).'}');
                  }
                  // Uncertain outcomes and cancellation must stop queued uploads.
                  rethrow;
                }
              }
            }
          }()
      ]);
    } catch (_) {
      exitCode = (ActionScope.current?.isCancelled ?? false) ? 130 : 1;
    } finally {
      await directory.delete(recursive: true);
    }
    final summary =
        'Completed $success writes; $failures failures; ${count * versions - success - failures} writes not completed.';
    lines.add(summary);
    return {
      'label': 'put-testdata',
      'running': false,
      'cancellable': false,
      'lastStatus': summary,
      'exitCode': exitCode,
      'outputLines': lines,
      'successCount': success,
      'failureCount': failures,
      'outcomeUnknown': ActionScope.current?.outcomeUnknown ?? false
    };
  }

  Future<Map<String, Object?>> runStorageTool(
      EndpointProfile profile, Map<String, Object?> arguments) async {
    final config =
        Map<String, Object?>.from(arguments['config'] as Map? ?? arguments);
    final bucket = '${config['bucketName'] ?? ''}';
    if (bucket.isEmpty) {
      MobileStorageAdmin._invalid('A bucket or container name is required.');
    }
    final attempts =
        ((config['maxRetries'] as num?)?.toInt() ?? 2).clamp(0, 9) + 1;
    final workers = min(
        ((config['maxWorkers'] as num?)?.toInt() ?? 4).clamp(1, 16),
        ((config['pipelineSize'] as num?)?.toInt() ?? 16).clamp(1, 16));
    final configured = profile.copyWith(
      maxAttempts: attempts,
      maxConcurrentRequests: ((config['maxConnections'] as num?)?.toInt() ??
              profile.maxConcurrentRequests)
          .clamp(1, 64),
      maxRequestsPerSecond:
          ((config['maxRequestsPerSecond'] as num?)?.toInt() ??
                  profile.maxRequestsPerSecond)
              .clamp(0, 100000),
    );
    final runner =
        _MobileDeleteAll(client(configured), bucket, config, attempts, workers);
    return runner.run();
  }
}

class _DeleteReference {
  const _DeleteReference(this.key, {this.version, this.snapshot, this.etag});
  final String key;
  final String? version, snapshot, etag;
  String get identity => jsonEncode([key, version, snapshot]);
  Map<String, String> query(bool azure) => {
        if (version != null) (azure ? 'versionid' : 'versionId'): version!,
        if (snapshot != null) 'snapshot': snapshot!,
      };
}

class _DeletePage {
  const _DeletePage(this.items, this.next);
  final List<_DeleteReference> items;
  final Map<String, String>? next;
}

class _MobileDeleteAll {
  _MobileDeleteAll(
      this.http, this.bucket, this.config, this.attempts, this.workers);
  final StorageHttpClient http;
  final String bucket;
  final Map<String, Object?> config;
  final int attempts, workers;
  final outcomes = <Map<String, Object?>>[];
  final lines = <String>[];
  int listed = 0,
      enumerated = 0,
      deleted = 0,
      failed = 0,
      requestFailures = 0,
      aborted = 0;
  String versioning = 'Unknown';
  bool recoverStale = false;
  int adaptiveDelayMs = 0;

  Future<Map<String, Object?>> run() async {
    var exitCode = 0;
    try {
      ActionScope.current?.check();
      _checksumHeaders([]); // Reject unsupported choices before any mutation.
      final retryMode = '${config['retryMode'] ?? 'standard'}';
      if (!{'standard', 'adaptive', 'legacy'}.contains(retryMode)) {
        MobileStorageAdmin._invalid('Unsupported delete retry mode.');
      }
      if (!http.azure) {
        versioning = await _versioning();
        final host = Uri.parse(http.profile.endpointUrl).host.toLowerCase();
        recoverStale = versioning == 'NeverEnabled' &&
            http.profile.endpointType == EndpointProfileType.s3Compatible &&
            !host.endsWith('.amazonaws.com') &&
            !host.endsWith('.amazonaws.com.cn') &&
            host != 's3.amazonaws.com';
      } else {
        versioning = 'AzureVersionsAndSnapshots';
      }
      lines.add('Bucket: $bucket; versioning: $versioning.');
      if (config['immediateDeletion'] == false) {
        await _deferredDelete();
      } else {
        await _immediateDelete();
      }
      if (config['abortMultipartUploads'] == true && !http.azure) {
        await _abortUploads();
      }
    } catch (error) {
      final cancelled = ActionScope.current?.isCancelled ?? false;
      exitCode = cancelled ? 130 : 1;
      requestFailures++;
      lines.add(cancelled
          ? 'Deletion cancelled; remaining requests were stopped.'
          : _safeError(error));
      if (ActionScope.current?.outcomeUnknown ?? false) {
        lines.add(
            'A sent mutation has an unknown outcome. Inspect the bucket before retrying.');
      }
    }
    if (failed > 0 && exitCode == 0) exitCode = 1;
    final unconfirmed = max(0, listed - deleted - failed);
    final summary =
        'Listed $enumerated; processed $listed; deleted $deleted; failed $failed; unconfirmed $unconfirmed; request failures $requestFailures.';
    lines.add(summary);
    return {
      'label': 'delete-all',
      'running': false,
      'cancellable': false,
      'exitCode': exitCode,
      'jobId': 'delete-all-${DateTime.now().microsecondsSinceEpoch}',
      'lastStatus': summary,
      'outputLines': lines,
      'successCount': deleted,
      'failureCount': failed + requestFailures,
      'listedCount': enumerated,
      'processedCount': listed,
      'versioningStatus': versioning,
      'outcomes': outcomes,
      'unconfirmedCount': unconfirmed,
      'outcomesTruncated': listed > outcomes.length,
      'abortedUploadCount': aborted,
      'outcomeUnknown': ActionScope.current?.outcomeUnknown ?? false
    };
  }

  Future<void> _immediateDelete() async {
    Map<String, String>? cursor;
    final seen = <String>{};
    var page = await _list(cursor);
    while (true) {
      ActionScope.current?.check();
      _DeletePage? nextPage;
      if (page.next != null) {
        final identity = jsonEncode(page.next);
        if (!seen.add(identity)) {
          throw StateError('Storage listing repeated its cursor.');
        }
        // Prefetch one bounded page before removing its predecessor. Version
        // markers still exist when the next listing request is evaluated.
        cursor = page.next;
        nextPage = await _list(cursor);
      }
      await _processPage(page.items);
      if (nextPage == null) break;
      page = nextPage;
    }
  }

  Future<void> _deferredDelete() async {
    final directory =
        await Directory.systemTemp.createTemp('object-browser-delete-plan-');
    final manifest = File('${directory.path}/objects.jsonl');
    var planned = 0;
    try {
      final handle = await manifest.open(mode: FileMode.write);
      try {
        Map<String, String>? cursor;
        final seen = <String>{};
        while (true) {
          ActionScope.current?.check();
          final page = await _list(cursor);
          if (page.items.isNotEmpty) {
            await handle.writeString('${page.items.map((item) => jsonEncode({
                      'key': item.key,
                      'version': item.version,
                      'snapshot': item.snapshot,
                      'etag': item.etag
                    })).join('\n')}\n');
            planned += page.items.length;
          }
          if (page.next == null) break;
          if (!seen.add(jsonEncode(page.next))) {
            throw StateError('Storage listing repeated its cursor.');
          }
          cursor = page.next;
        }
      } finally {
        await handle.close();
      }
      lines.add(
          'Deferred deletion: finished listing $planned object/version references before sending any delete.');
      final pageSize =
          ((config['listMaxKeys'] as num?)?.toInt() ?? 1000).clamp(1, 1000);
      var page = <_DeleteReference>[];
      await for (final line in manifest
          .openRead()
          .transform(utf8.decoder)
          .transform(const LineSplitter())) {
        ActionScope.current?.check();
        final item = jsonDecode(line) as Map;
        page.add(_DeleteReference(item['key'] as String,
            version: item['version'] as String?,
            snapshot: item['snapshot'] as String?,
            etag: item['etag'] as String?));
        if (page.length >= pageSize) {
          await _processPage(page);
          page = [];
        }
      }
      if (page.isNotEmpty) await _processPage(page);
    } finally {
      // Credentials are never written; the private manifest contains only
      // exact references/validators and is removed even on listing failure.
      await directory.delete(recursive: true);
    }
  }

  Future<String> _versioning() async {
    final root =
        (await http.request('GET', bucket, query: {'versioning': ''})).xml;
    if (root.name.local != 'VersioningConfiguration') {
      throw StateError('Bucket versioning response could not be verified.');
    }
    final statuses = root.childElements
        .where((node) => node.name.local == 'Status')
        .toList();
    if (statuses.isEmpty) return 'NeverEnabled';
    if (statuses.length == 1 &&
        {'Enabled', 'Suspended'}.contains(statuses.single.innerText)) {
      return statuses.single.innerText;
    }
    throw StateError('Bucket versioning is unknown; no fallback is permitted.');
  }

  Future<_DeletePage> _list(Map<String, String>? cursor) async {
    final pageSize =
        ((config['listMaxKeys'] as num?)?.toInt() ?? 1000).clamp(1, 1000);
    if (http.azure) {
      final root = (await http.request('GET', bucket, query: {
        'restype': 'container',
        'comp': 'list',
        'include': 'versions,snapshots',
        'maxresults': '$pageSize',
        ...?cursor
      }))
          .xml;
      if (root.name.local != 'EnumerationResults') {
        throw StateError('Invalid Azure listing response.');
      }
      final rows = <_DeleteReference>[];
      for (final item
          in _azureChild(root, 'Blobs')?.childElements ?? <XmlElement>[]) {
        if (item.name.local != 'Blob') continue;
        final key = xmlText(item, 'Name');
        final version = xmlText(item, 'VersionId'),
            snapshot = xmlText(item, 'Snapshot');
        if (key.isEmpty) {
          throw StateError('Azure listing omitted an object key.');
        }
        rows.add(_DeleteReference(key,
            version: version.isEmpty ? null : version,
            snapshot: snapshot.isEmpty ? null : snapshot));
      }
      final marker = xmlText(root, 'NextMarker');
      enumerated += rows.length;
      return _DeletePage(rows, marker.isEmpty ? null : {'marker': marker});
    }
    final neverEnabled = versioning == 'NeverEnabled';
    final root = (await http.request('GET', bucket, query: {
      if (neverEnabled) 'list-type': '2' else 'versions': '',
      'encoding-type': 'url',
      'max-keys': '$pageSize',
      ...?cursor,
    }))
        .xml;
    if (root.name.local !=
        (neverEnabled ? 'ListBucketResult' : 'ListVersionsResult')) {
      throw StateError('Invalid S3 listing response.');
    }
    String keyText(XmlElement element, String field) {
      final raw = xmlText(element, field);
      return xmlText(root, 'EncodingType') == 'url'
          ? Uri.decodeComponent(raw)
          : raw;
    }

    final rows = <_DeleteReference>[];
    for (final item in root.childElements.where((element) => neverEnabled
        ? element.name.local == 'Contents'
        : {'Version', 'DeleteMarker'}.contains(element.name.local))) {
      final key = keyText(item, 'Key'),
          version = neverEnabled ? null : xmlText(item, 'VersionId');
      if (key.isEmpty || version == '') {
        throw StateError(
            'S3 listing omitted an exact object/version identifier.');
      }
      final etag = xmlText(item, 'ETag');
      rows.add(_DeleteReference(key,
          version: version, etag: etag.isEmpty ? null : etag));
    }
    enumerated += rows.length;
    if (xmlText(root, 'IsTruncated') != 'true') return _DeletePage(rows, null);
    if (neverEnabled) {
      final token = xmlText(root, 'NextContinuationToken');
      if (token.isEmpty) {
        throw StateError('Truncated listing omitted its continuation token.');
      }
      return _DeletePage(rows, {'continuation-token': token});
    }
    final key = keyText(root, 'NextKeyMarker'),
        version = xmlText(root, 'NextVersionIdMarker');
    if (key.isEmpty || version.isEmpty) {
      throw StateError('Truncated version listing omitted its exact cursor.');
    }
    return _DeletePage(rows, {'key-marker': key, 'version-id-marker': version});
  }

  Future<void> _processPage(List<_DeleteReference> items) async {
    final size =
        ((config['batchSize'] as num?)?.toInt() ?? 1000).clamp(1, 1000);
    var position = 0;
    await Future.wait([
      for (var worker = 0;
          worker < min(workers, (items.length + size - 1) ~/ size);
          worker++)
        () async {
          while (position < items.length) {
            ActionScope.current?.check();
            final start = position;
            position = min(position + size, items.length);
            final batch = items.sublist(start, position);
            listed += batch.length;
            if (http.azure) {
              await _azureDeleteBatch(batch);
            } else {
              await _s3DeleteBatch(batch);
            }
            final delay = ((config['deletionDelayMs'] as num?)?.toInt() ?? 0)
                .clamp(0, 60000);
            if (delay > 0) await _wait(Duration(milliseconds: delay));
          }
        }()
    ]);
  }

  Future<List<Map<String, Object?>>> _azureDeleteBatch(
      List<_DeleteReference> batch) async {
    final results = <Map<String, Object?>>[];
    for (final item in batch) {
      var code = 'UnknownOutcome';
      for (var attempt = 0; attempt < attempts; attempt++) {
        ActionScope.current?.check();
        try {
          await _send('DELETE',
              key: item.key,
              query: item.query(true),
              headers: {
                if (item.version == null && item.snapshot == null)
                  'x-ms-delete-snapshots': 'include',
              });
          code = '';
          break;
        } on StorageHttpException catch (error) {
          if (_missing(error)) {
            code = '';
            break;
          }
          code = error.serviceCode;
          if (!_transient(code)) break;
          if (attempt + 1 < attempts) await _pause(attempt);
        }
      }
      results.add(_record(_outcome(item, code.isEmpty, 'azure-delete', code)));
    }
    return results;
  }

  Future<List<Map<String, Object?>>> _s3DeleteBatch(
      List<_DeleteReference> batch) async {
    var pending = List<_DeleteReference>.of(batch);
    final codes = <String, String>{}, results = <Map<String, Object?>>[];
    for (var attempt = 0; attempt < attempts && pending.isNotEmpty; attempt++) {
      ActionScope.current?.check();
      final body = storageXml('Delete', {
        'Object': [
          for (final item in pending)
            {
              'Key': item.key,
              if (item.version != null) 'VersionId': item.version
            }
        ],
        'Quiet': false
      });
      final retry = <_DeleteReference>[];
      try {
        final root = (await _send('POST',
                query: {'delete': ''},
                body: body,
                headers: _checksumHeaders(body)))
            .xml;
        if (root.name.local != 'DeleteResult') {
          throw StateError('Delete response was not a DeleteResult.');
        }
        final confirmed = <String>{}, errors = <String, String>{};
        for (final node in root.childElements) {
          final reference = _DeleteReference(xmlText(node, 'Key'),
              version: _azureChild(node, 'VersionId') == null
                  ? null
                  : xmlText(node, 'VersionId'));
          if (node.name.local == 'Deleted') confirmed.add(reference.identity);
          if (node.name.local == 'Error') {
            errors[reference.identity] = xmlText(node, 'Code');
          }
        }
        for (final item in pending) {
          var code = errors[item.identity];
          if ((code == null && confirmed.contains(item.identity)) ||
              {'NoSuchKey', 'NoSuchVersion'}.contains(code)) {
            code = recoverStale ? await _remainingCode(item) : '';
          }
          code ??= 'UnknownOutcome';
          codes[item.identity] = code;
          if (code.isEmpty) {
            results.add(_record(_outcome(item, true, 'batch-delete', '')));
          } else if (_transient(code) || code == 'StillPresent') {
            retry.add(item);
          } else {
            results.add(_record(_outcome(item, false, 'batch-delete', code)));
          }
        }
      } on StorageHttpException catch (error) {
        for (final item in pending) {
          codes[item.identity] = error.serviceCode;
          if (_transient(error.serviceCode)) {
            retry.add(item);
          } else {
            results.add(_record(
                _outcome(item, false, 'batch-delete', error.serviceCode)));
          }
        }
      }
      pending = retry;
      if (pending.isNotEmpty && attempt + 1 < attempts) await _pause(attempt);
    }
    for (final item in pending) {
      results.add(_record(await _individualDelete(
          item, codes[item.identity] ?? 'UnknownOutcome')));
    }
    return results;
  }

  Future<String> _remainingCode(_DeleteReference item) async {
    try {
      final head = await http.request('HEAD', bucket,
          key: item.key, query: item.query(false));
      if (item.etag != null && head.headers['etag'] != item.etag) {
        return 'SourceChanged';
      }
      return 'StillPresent';
    } on StorageHttpException catch (error) {
      return _missing(error) ? '' : error.serviceCode;
    }
  }

  Future<Map<String, Object?>> _individualDelete(
      _DeleteReference item, String code) async {
    for (var attempt = 0; attempt < attempts; attempt++) {
      ActionScope.current?.check();
      try {
        await _send('DELETE',
            key: item.key,
            query: item.query(false),
            headers: {
              if (item.etag != null && item.version == null)
                'if-match': item.etag!
            });
        code = recoverStale ? await _remainingCode(item) : '';
      } on StorageHttpException catch (error) {
        code = _missing(error) ? '' : error.serviceCode;
      }
      if (code.isEmpty) return _outcome(item, true, 'individual-delete', '');
      if (!_transient(code) && code != 'StillPresent') {
        return _outcome(item, false, 'individual-delete', code);
      }
      if (attempt + 1 < attempts) await _pause(attempt);
    }
    if (!recoverStale ||
        item.version != null ||
        item.etag == null ||
        (!_transient(code) && code != 'StillPresent')) {
      return _outcome(item, false, 'individual-delete', code);
    }
    ActionScope.current?.check();
    StorageHttpResponse head;
    try {
      head = await http.request('HEAD', bucket, key: item.key);
    } on StorageHttpException catch (error) {
      return _outcome(
          item, _missing(error), 'individual-delete', error.serviceCode);
    }
    if (head.headers['etag'] != item.etag ||
        head.headers['x-amz-object-lock-mode']?.isNotEmpty == true ||
        head.headers['x-amz-object-lock-legal-hold'] == 'ON' ||
        head.headers['x-amz-object-lock-retain-until-date']?.isNotEmpty ==
            true) {
      return _outcome(item, false, 'individual-delete',
          'Object changed or has retention; empty overwrite prohibited.');
    }
    if (await _versioning() != 'NeverEnabled') {
      return _outcome(item, false, 'individual-delete',
          'Versioning changed; empty overwrite prohibited.');
    }
    ActionScope.current?.check();
    var overwritten = false;
    try {
      final replacement =
          await _send('PUT', key: item.key, headers: {'if-match': item.etag!});
      overwritten = true;
      final etag = replacement.headers['etag'];
      if (etag == null || etag.isEmpty) {
        return _outcome(item, false, 'empty-put-delete',
            'Overwritten with an empty object; no replacement ETag was returned.',
            overwritten: true);
      }
      ActionScope.current?.check();
      try {
        await _send('DELETE', key: item.key, headers: {'if-match': etag});
      } on StorageHttpException catch (error) {
        if (!_missing(error)) rethrow;
      }
      final remaining =
          await _remainingCode(_DeleteReference(item.key, etag: etag));
      return _outcome(
          item,
          remaining.isEmpty,
          'empty-put-delete',
          remaining.isEmpty
              ? 'Stale metadata recovered.'
              : 'Overwritten with an empty object; final deletion was not confirmed.',
          overwritten: true);
    } catch (error) {
      return _outcome(
          item,
          false,
          'empty-put-delete',
          overwritten
              ? 'Overwritten with an empty object; final deletion failed or was cancelled.'
              : _safeError(error),
          overwritten: overwritten);
    }
  }

  Future<void> _abortUploads() async {
    Map<String, String> markers = {};
    final seen = <String>{};
    while (true) {
      ActionScope.current?.check();
      final root = (await http.request('GET', bucket,
              query: {'uploads': '', 'max-uploads': '1000', ...markers}))
          .xml;
      final uploads = root.childElements
          .where((node) => node.name.local == 'Upload')
          .toList();
      for (final item in uploads) {
        final key = xmlText(item, 'Key'), upload = xmlText(item, 'UploadId');
        if (key.isEmpty || upload.isEmpty) {
          throw StateError('Incomplete upload listing omitted identifiers.');
        }
        await _send('DELETE', key: key, query: {'uploadId': upload});
        aborted++;
      }
      if (xmlText(root, 'IsTruncated') != 'true') break;
      markers = {
        'key-marker': xmlText(root, 'NextKeyMarker'),
        'upload-id-marker': xmlText(root, 'NextUploadIdMarker')
      };
      if (markers.values.any((value) => value.isEmpty) ||
          !seen.add(jsonEncode(markers))) {
        throw StateError('Upload listing cursor did not advance.');
      }
    }
  }

  Future<StorageHttpResponse> _send(String method,
      {String? key,
      Map<String, String> query = const {},
      Map<String, String> headers = const {},
      List<int> body = const []}) async {
    if (adaptiveDelayMs > 0) {
      await _wait(Duration(milliseconds: adaptiveDelayMs));
    }
    try {
      final response = await http.request(method, bucket,
          key: key,
          query: query,
          headers: headers,
          body: body,
          retrySafe: false);
      adaptiveDelayMs ~/= 2;
      return response;
    } on StorageHttpException catch (error) {
      if (config['retryMode'] == 'adaptive' && _transient(error.serviceCode)) {
        adaptiveDelayMs = min(2000, max(100, adaptiveDelayMs * 2));
      }
      rethrow;
    }
  }

  Future<void> _pause(int attempt) => _wait(Duration(
      milliseconds: config['retryMode'] == 'legacy'
          ? 100
          : min(2000, 100 * (1 << attempt))));
  Future<void> _wait(Duration duration) async {
    final future = Future<void>.delayed(duration);
    final scope = ActionScope.current;
    if (scope == null) {
      await future;
    } else {
      await scope.wait(future);
    }
  }

  bool _missing(StorageHttpException error) =>
      error.response.status == 404 &&
      {
        'NoSuchKey',
        'NoSuchVersion',
        'NotFound',
        'BlobNotFound',
        'request_failed'
      }.contains(error.serviceCode);
  bool _transient(String code) => {
        'InternalError',
        'InternalFailure',
        'ServiceUnavailable',
        'ServerBusy',
        'SlowDown',
        'RequestTimeout',
        'RequestTimeoutException',
        'OperationAborted'
      }.contains(code);
  String _safeError(Object error) => error is EngineException
      ? error.message
      : error is StateError
          ? error.message.toString()
          : 'Storage operation failed (${error.runtimeType}); no fallback was attempted.';
  Map<String, Object?> _outcome(
          _DeleteReference item, bool success, String stage, String message,
          {bool overwritten = false}) =>
      {
        'key': item.key,
        'versionId': item.version,
        'snapshot': item.snapshot,
        'deleted': success,
        'stage': stage,
        'message': message,
        'overwrittenWithEmptyObject': overwritten,
      };
  Map<String, Object?> _record(Map<String, Object?> result) {
    if (result['deleted'] == true) {
      deleted++;
    } else {
      failed++;
    }
    if (outcomes.length < 1000) outcomes.add(result);
    if (result['overwrittenWithEmptyObject'] == true && lines.length < 200) {
      lines.add('${result['key']}: ${result['message']}');
    }
    return result;
  }

  Map<String, String> _checksumHeaders(List<int> bytes) {
    final algorithm = '${config['checksumAlgorithm'] ?? 'md5'}'.toLowerCase();
    final headers = {
      'content-type': 'application/xml',
      'content-md5': base64Encode(md5.convert(bytes).bytes)
    };
    if (algorithm == 'md5') return headers;
    if (algorithm == 'sha256' || algorithm == 'sha1') {
      headers['x-amz-checksum-$algorithm'] = base64Encode(
          (algorithm == 'sha256' ? sha256 : sha1).convert(bytes).bytes);
    } else if (algorithm == 'crc32' || algorithm == 'crc32c') {
      var crc = 0xffffffff;
      final polynomial = algorithm == 'crc32c' ? 0x82f63b78 : 0xedb88320;
      for (final byte in bytes) {
        crc ^= byte;
        for (var bit = 0; bit < 8; bit++) {
          crc = (crc >> 1) ^ ((crc & 1) == 1 ? polynomial : 0);
        }
      }
      crc = (crc ^ 0xffffffff) & 0xffffffff;
      headers['x-amz-checksum-$algorithm'] = base64Encode(
          [crc >> 24, (crc >> 16) & 255, (crc >> 8) & 255, crc & 255]);
    } else {
      MobileStorageAdmin._invalid(
          'Unsupported bulk-delete checksum algorithm.');
    }
    return headers;
  }
}
