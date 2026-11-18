part of 'mobile_storage_admin.dart';

/// Sealed age chunks fetched per ranged request on encrypted downloads.
const _ageChunksPerRequest = 64;

extension MobileStorageTransfers on MobileStorageAdmin {
  Future<Map<String, Object?>> copyStorageObject(EndpointProfile source,
      EndpointProfile destination, Map<String, Object?> args) async {
    final sourceHeaders = objectEncryptionHeaders(
      source,
      args['sourceEncryption'],
      read: true,
    );
    final copySourceHeaders = objectEncryptionHeaders(
      source,
      args['sourceEncryption'],
      source: args['sourceEncryption'] != null,
    );
    final destinationHeaders = objectEncryptionHeaders(
      destination,
      args['encryption'],
    );
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
        (args['move'] == true ||
            (version == null && args['options'] is! Map))) {
      MobileStorageAdmin._invalid('Choose a different destination object.');
    }
    final query = <String, String>{
      if (version != null) from.azure ? 'versionid' : 'versionId': version
    };
    final deleteQuery = Map<String, String>.of(query);
    final head = await from.request(
      'HEAD',
      sourceBucket,
      key: sourceKey,
      query: query,
      headers: sourceHeaders,
    );
    final copiedVersion = version ??
        head.headers[from.azure ? 'x-ms-version-id' : 'x-amz-version-id'];
    if (copiedVersion != null) {
      query[from.azure ? 'versionid' : 'versionId'] = copiedVersion;
    }
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
    final requireEmptySource = args['requireEmptySource'] == true;
    if (requireEmptySource && size != 0) {
      MobileStorageAdmin._invalid(
          'Only empty markers can be copied into this vault.');
    }
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
    var expectedGrants = <String, String>{};
    if ((selfCopy || args['move'] == true) &&
        args['options'] is Map &&
        !from.azure) {
      final protection =
          await _propertyProtectionHeaders(from, sourceBucket, sourceKey, query);
      expectedGrants = Map.fromEntries(protection.entries
          .where((entry) => entry.key.startsWith('x-amz-grant-')));
      headers.addAll(protection);
    }
    if (expectedGrants.isNotEmpty && to.azure) {
      throw const EngineException(
          code: ErrorCode.unsupportedFeature,
          message: 'S3 object ACLs cannot be preserved in Azure Blob.');
    }
    final localProtectedWrite = expectedGrants.isNotEmpty &&
        {'127.0.0.1', 'localhost', '::1'}.contains(to.uri('').host);
    if (localProtectedWrite &&
        (size > 8 * 1024 * 1024 ||
            (selfCopy && version != null) ||
            (args['move'] == true && (source != destination || conflict == 'replace')) ||
            requireEmptySource)) {
      throw const EngineException(
          code: ErrorCode.unsupportedFeature,
          message:
              'This loopback endpoint requires a single conditional PUT to preserve object ACLs.');
    }
    Future<void> verifySourceGrants() async {
      if (expectedGrants.isEmpty) return;
      if (version == null && copiedVersion != null) {
        final current = await from.request('HEAD', sourceBucket,
            key: sourceKey, headers: sourceHeaders);
        if (current.headers['x-amz-version-id'] != copiedVersion) {
          MobileStorageAdmin._conflict(
              'The current source version changed during the copy. Refresh before retrying.');
        }
      }
      final acl = (await from.request('GET', sourceBucket,
              key: sourceKey, query: {...deleteQuery, 'acl': ''}))
          .xml;
      if (!_matchingAclGrants(acl, expectedGrants)) {
        MobileStorageAdmin._conflict(
            'The source ACL changed during the copy. Refresh before retrying.');
      }
    }
    // Read the tag set before any destination mutation. A denied read must not
    // silently publish a copy with tags missing.
    final tagResult =
        await action(profile: source, action: 'objectTags', arguments: {
      'bucketName': sourceBucket,
      'key': sourceKey,
      if (copiedVersion != null) 'versionId': copiedVersion
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
            ...sourceHeaders,
            'range': 'bytes=$start-${start + count - 1}',
            'if-match': etag
          },
          maxResponseBytes: count);
      _validateRange(response, start, count, size, etag);
      return response.body;
    }

    try {
      final serverCopyEligible = !requireEmptySource &&
          !localProtectedWrite &&
          sameEndpoint &&
          !from.azure &&
          !to.azure &&
          source.accessKey == destination.accessKey &&
          source.secretKey == destination.secretKey &&
          source.sessionToken == destination.sessionToken &&
          conflict == 'replace' &&
          !selfCopy &&
          size <= 5 * 1024 * 1024 * 1024;
      final StorageHttpResponse response;
      if (serverCopyEligible) {
        // Only replace is eligible: HEAD-then-copy cannot enforce no-overwrite.
        final sourceLocation =
            '/${storageUriEncode(sourceBucket)}/${sourceKey.split('/').map(storageUriEncode).join('/')}'
            '${copiedVersion == null ? '' : '?versionId=${storageUriEncode(copiedVersion)}'}';
        await verifySourceGrants();
        final copied = await to.request('PUT', bucket, key: key, headers: {
          ...headers,
          ...destinationHeaders,
          ...copySourceHeaders,
          'x-amz-copy-source': sourceLocation,
          'x-amz-copy-source-if-match': etag,
          'x-amz-metadata-directive': 'REPLACE',
          'x-amz-tagging-directive': 'REPLACE',
        });
        if (copied.xml.name.local == 'Error') {
          throw StorageHttpException(
              StorageHttpResponse(500, copied.headers, copied.body));
        }
        final copiedEtag = xmlText(copied.xml, 'ETag');
        response = StorageHttpResponse(
            copied.status,
            {...copied.headers, if (copiedEtag.isNotEmpty) 'etag': copiedEtag},
            copied.body);
      } else {
        response = await _writeObject(to, bucket, key, size, read,
            headers: headers,
            encryption: args['encryption'],
            conflict: conflict,
            verifySource: expectedGrants.isEmpty ? null : verifySourceGrants,
            expectedDestinationETag: selfCopy && version == null ? etag : null);
      }
      final destinationVersion =
          response.headers[to.azure ? 'x-ms-version-id' : 'x-amz-version-id'];
      final destinationQuery = {
        if (destinationVersion != null)
          to.azure ? 'versionid' : 'versionId': destinationVersion
      };
      Map<String, Object?> incompleteCopy(String code, String message,
              {bool sourceRetained = true}) =>
          {
            'successCount': 0,
            'failureCount': 1,
            'requiresVerification': true,
            'destinationVersionId': destinationVersion,
            if (args['move'] == true) ...{
              'copiedCount': 1,
              if (sourceRetained) 'sourceRetained': true,
            },
            'failures': [
              {'target': key, 'code': code, 'message': message}
            ],
          };
      final StorageHttpResponse verified;
      try {
        if (response.headers['etag'] == null && destinationVersion == null) {
          throw const EngineException(
              code: ErrorCode.unknown,
              message:
                  'The copy response omitted its destination identity. Inspect the destination before retrying.');
        }
        verified = await to.request('HEAD', bucket,
            key: key,
            headers: objectEncryptionHeaders(
              destination,
              args['encryption'],
              read: true,
            ),
            query: destinationQuery);
        if (int.tryParse(verified.headers['content-length'] ?? '') != size ||
            (response.headers['etag'] != null &&
                response.headers['etag'] != verified.headers['etag'])) {
          MobileStorageAdmin._conflict(
              'The destination changed before the copy could be verified.');
        }
      } catch (_) {
        if (expectedGrants.isEmpty) rethrow;
        return incompleteCopy('destination_unverified',
            'The copy was written, but its destination could not be verified. Inspect it before retrying.');
      }
      if (expectedGrants.isNotEmpty) {
        try {
          final acl = (await to.request('GET', bucket,
                  key: key, query: {...destinationQuery, 'acl': ''}))
              .xml;
          if (!_matchingAclGrants(acl, expectedGrants)) {
            throw StateError('Destination grants differ from the source.');
          }
        } catch (_) {
          return incompleteCopy('acl_unverified',
              'The copy was written, but its ACL could not be verified. Review the destination grants before retrying.');
        }
      }
      if (args['move'] == true) {
        try {
          await verifySourceGrants();
        } catch (_) {
          return incompleteCopy('source_acl_unverified',
              'The copy was written and the source was kept because its ACL changed or could not be verified.');
        }
        try {
          await from.request('DELETE', sourceBucket,
              key: sourceKey, query: deleteQuery, headers: {'if-match': etag});
        } on StorageHttpException catch (error) {
          return incompleteCopy('source_delete_failed',
              'The copy was written, but source deletion was not confirmed.',
              sourceRetained: error.response.status == 412);
        } catch (_) {
          return incompleteCopy('source_delete_failed',
              'The copy was written, but source deletion was not confirmed.',
              sourceRetained: false);
        }
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

  Future<Map<String, String>> _propertyProtectionHeaders(StorageHttpClient http,
      String bucket, String key, Map<String, String> query) async {
    final result = <String, String>{};
    Future<XmlElement?> optional(String name, {bool object = false}) async {
      try {
        return (await http.request('GET', bucket,
                key: object ? key : null,
                query: {...(object ? query : <String, String>{}), name: ''}))
            .xml;
      } on StorageHttpException catch (error) {
        if ({
          'OwnershipControlsNotFoundError',
          'NoSuchOwnershipControls',
          'ObjectLockConfigurationNotFoundError',
          'NoSuchObjectLockConfiguration',
          'NoSuchRetentionConfiguration',
          'NotImplemented'
        }.contains(error.serviceCode)) {
          return null;
        }
        throw StateError(
            'Cannot safely preserve access permissions and Object Lock settings. No property changes were applied. ${error.message}');
      }
    }

    final ownership = await optional('ownershipControls');
    final enforced = ownership?.descendants.whereType<XmlElement>().any((e) =>
            e.name.local == 'ObjectOwnership' &&
            e.innerText == 'BucketOwnerEnforced') ??
        false;
    if (!enforced) {
      final acl = await optional('acl', object: true);
      if (acl == null) {
        throw StateError(
            'The object ACL could not be read. No property changes were applied.');
      }
      result.addAll(_aclGrantHeaders(acl));
    }
    final lock = await optional('object-lock');
    if (lock != null && xmlText(lock, 'ObjectLockEnabled') == 'Enabled') {
      final retention = await optional('retention', object: true);
      final hold = await optional('legal-hold', object: true);
      if (retention != null && xmlText(retention, 'Mode').isNotEmpty) {
        result['x-amz-object-lock-mode'] = xmlText(retention, 'Mode');
        result['x-amz-object-lock-retain-until-date'] =
            xmlText(retention, 'RetainUntilDate');
      }
      if (hold != null && xmlText(hold, 'Status').isNotEmpty) {
        result['x-amz-object-lock-legal-hold'] = xmlText(hold, 'Status');
      }
    }
    return result;
  }

  Map<String, String> _aclGrantHeaders(XmlElement acl) {
    const names = {
      'FULL_CONTROL': 'x-amz-grant-full-control',
      'READ': 'x-amz-grant-read',
      'READ_ACP': 'x-amz-grant-read-acp',
      'WRITE_ACP': 'x-amz-grant-write-acp'
    };
    final grants = <String, Set<String>>{};
    for (final grant in acl.descendants
        .whereType<XmlElement>()
        .where((e) => e.name.local == 'Grant')) {
      final field = names[xmlText(grant, 'Permission')];
      final grantee =
          grant.childElements.where((e) => e.name.local == 'Grantee').firstOrNull;
      final id = grantee == null ? '' : xmlText(grantee, 'ID');
      final uri = grantee == null ? '' : xmlText(grantee, 'URI');
      final value = id.isNotEmpty ? id : uri;
      if (field == null ||
          value.isEmpty ||
          value.contains(RegExp(r'[\r\n"]'))) {
        throw StateError(
            'This object ACL cannot be preserved by a property edit.');
      }
      grants
          .putIfAbsent(field, () => {})
          .add('${id.isNotEmpty ? 'id' : 'uri'}="$value"');
    }
    if (grants.isEmpty) {
      throw StateError('The object ACL did not contain any grants.');
    }
    return grants.map(
        (name, values) => MapEntry(name, (values.toList()..sort()).join(', ')));
  }

  bool _matchingAclGrants(XmlElement acl, Map<String, String> expected) {
    final actual = _aclGrantHeaders(acl);
    return actual.length == expected.length &&
        expected.entries.every((entry) => actual[entry.key] == entry.value);
  }

  Future<StorageHttpResponse> _writeObject(
      StorageHttpClient http,
      String bucket,
      String key,
      int size,
      Future<List<int>> Function(int start, int count) read,
      {Map<String, String> headers = const {},
      Object? encryption,
      String conflict = 'replace',
      String? expectedDestinationETag,
      Future<void> Function()? verifySource,
      int partBytes = 8 * 1024 * 1024,
      int streamReadBytes = 8 * 1024 * 1024,
      int? multipartThresholdBytes,
      void Function(int)? onProgress,
      bool clientEncrypted = false}) async {
    final encryptionHeaders = objectEncryptionHeaders(http.profile, encryption);
    final partEncryptionHeaders = http.azure
        ? encryptionHeaders
        : objectEncryptionHeaders(http.profile, encryption, read: true);
    headers = {...headers, ...encryptionHeaders};
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
      if (!clientEncrypted && !http.azure && count <= 8 * 1024 * 1024) {
        final bytes = await read(offset, count);
        if (!retrySafe) await verifySource?.call();
        final response = await http.request('PUT', bucket,
            key: key,
            query: query,
            headers: partHeaders,
            body: bytes,
            retrySafe: retrySafe);
        onProgress?.call(count);
        return response;
      }
      Stream<List<int>> stream() async* {
        if (clientEncrypted) await verifySource?.call();
        final chunk = streamReadBytes.clamp(64 * 1024, 8 * 1024 * 1024);
        for (var index = 0; index < count; index += chunk) {
          ActionScope.current?.check();
          yield await read(offset + index, min(chunk, count - index));
        }
        if (clientEncrypted) await verifySource?.call();
      }

      final hash = await http.hashPayload(stream());
      final response = await http.requestStream('PUT', bucket,
          key: key,
          query: query,
          headers: partHeaders,
          body: stream,
          bodyLength: count,
          payloadSha256: hash,
          retrySafe: retrySafe);
      onProgress?.call(count);
      return response;
    }

    final count = (size + partSize - 1) ~/ partSize;
    final workers = min(
        count,
        min(
            http.profile.maxConcurrentRequests.clamp(1, 16),
            max(1,
                (256 * 1024 * 1024) ~/ (min(partSize, 8 * 1024 * 1024) * 2))));
    final singleRequestLimit = (http.azure ? 5000 : 5120) * 1024 * 1024;
    final single = size <= singleRequestLimit &&
        (size == 0 ||
            (multipartThresholdBytes == null
                ? size <= partSize
                : size < multipartThresholdBytes));
    if (single) {
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
            {'comp': 'block', 'blockid': id}, partEncryptionHeaders);
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
        final part = await sendPart(
            offset,
            min(partSize, size - offset),
            {'uploadId': uploadId, 'partNumber': '${number + 1}'},
            partEncryptionHeaders);
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
          headers: {...condition, ...partEncryptionHeaders},
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
        final cleanup = ActionScope(inheritParent: false);
        try {
          await cleanup.run(() => http.request('DELETE', bucket,
              key: key, query: {'uploadId': uploadId}));
        } catch (_) {/* Available through multipart recovery. */} finally {
          cleanup.dispose();
        }
      }
      rethrow;
    }
  }

  Future<Map<String, Object?>> downloadStorageObject(
      EndpointProfile profile, Map<String, Object?> args) async {
    validateClientDownloadName(args['clientEncryption']);
    final config =
        MobileClientEncryption.parse(args['clientEncryption'], upload: false);
    try {
      return await _downloadStorageObject(profile, args, config);
    } finally {
      config?.dispose();
    }
  }

  Future<Map<String, Object?>> _downloadStorageObject(EndpointProfile profile,
      Map<String, Object?> args, MobileClientEncryption? config) async {
    final http = client(profile),
        bucket = '${args['bucketName']}',
        key = '${args['key']}';
    final query = <String, String>{
      if (args['versionId'] != null)
        http.azure ? 'versionid' : 'versionId': '${args['versionId']}'
    };
    final readEncryptionHeaders = objectEncryptionHeaders(
      profile,
      args['encryption'],
      read: true,
    );
    final head = (args['_heads'] as Map?)?[key] as StorageHttpResponse? ??
        await http.request(
          'HEAD',
          bucket,
          key: key,
          query: query,
          headers: readEncryptionHeaders,
        );
    final size = config == null
        ? int.parse(head.headers['content-length']!)
        : int.tryParse(head.headers['content-length'] ?? '') ?? -1;
    if (config != null && size < 0) mobileDecryptionFailed(0);
    final etag = head.headers['etag'];
    if (etag == null) {
      MobileStorageAdmin._conflict(
          'The endpoint did not return an ETag for a consistent download.');
    }
    var plaintextSize = size;
    if (config != null) {
      try {
        plaintextSize = agePlaintextLength(
            headerLength: config.headerLength, ciphertextLength: size);
      } on AgeException {
        mobileDecryptionFailed(0);
      }
    }
    final directory =
        Directory('${args['destinationDirectory'] ?? args['destinationPath']}');
    if (!await directory.exists()) {
      MobileStorageAdmin._invalid('Choose an existing download directory.');
    }
    final resolved = await directory.resolveSymbolicLinks();
    var name = key.split('/').last;
    final suppliedName = config == null
        ? null
        : (args['clientEncryption'] as Map)['fileName'] as String?;
    if (suppliedName != null) {
      name = suppliedName;
    } else if (config != null && name.endsWith('.age') && name.length > 4) {
      name = name.substring(0, name.length - 4);
    }
    if (name.isEmpty || {'.', '..'}.contains(name)) {
      name =
          'object-${sha256.convert(utf8.encode(key)).toString().substring(0, 12)}';
    }
    name = name.replaceAll(RegExp(r'[\\\x00-\x1f]'), '_');
    final destination = File('$resolved/$name');
    final staging = await Directory(resolved).createTemp('.object-browser-');
    final temp = File('${staging.path}/download');
    final file = await temp.open(mode: FileMode.write);
    File? reservation;
    MobileAgeWorker? cipher;
    try {
      if (config != null) {
        Future<Uint8List> read(int start, int count) async {
          final response = await http.request('GET', bucket,
              key: key,
              query: query,
              headers: {
                ...readEncryptionHeaders,
                'range': 'bytes=$start-${start + count - 1}',
                'if-match': etag
              },
              maxResponseBytes: count);
          _validateRange(response, start, count, size, etag);
          return Uint8List.fromList(response.body);
        }

        final nonce = await read(config.headerLength, agePayloadNonceLength);
        final worker = cipher = MobileAgeWorker(config.key, nonce);
        (args['_progress'] as void Function(int)?)
            ?.call(config.headerLength + agePayloadNonceLength);
        final chunks = ageChunkCount(plaintextSize);
        Future<void> writes = Future.value();
        final workers = min(chunks, profile.maxConcurrentRequests.clamp(1, 8));
        var nextChunk = 0, failed = false;
        await _parallelParts(workers, workers, (_) async {
          try {
            while (!failed && nextChunk < chunks) {
              // Claim a run of chunks per request: one request per 64 KiB
              // chunk would cost a round trip each. The cap bounds what a
              // worker holds to about 4 MiB of ciphertext.
              final first = nextChunk;
              final end = min(first + _ageChunksPerRequest, chunks);
              nextChunk = end;
              ActionScope.current?.check();
              final start = ageChunkOffset(
                  headerLength: config.headerLength, index: first);
              final stop = end == chunks
                  ? size
                  : ageChunkOffset(
                      headerLength: config.headerLength, index: end);
              final batch = await read(start, stop - start);
              for (var index = first; index < end && !failed; index++) {
                final offset =
                    (index - first) * (ageChunkSize + ageChunkOverhead);
                final count =
                    min(ageChunkSize + ageChunkOverhead, batch.length - offset);
                final sealed =
                    Uint8List.sublistView(batch, offset, offset + count);
                Uint8List plain;
                try {
                  plain = await worker.chunk(index, sealed,
                      last: index == chunks - 1, seal: false);
                } on AgeException {
                  mobileDecryptionFailed(index);
                }
                try {
                  writes = writes.then((_) async {
                    ActionScope.current?.check();
                    await file.setPosition(index * ageChunkSize);
                    await file.writeFrom(plain);
                  });
                  await writes;
                } finally {
                  ageWipe(plain);
                }
                (args['_progress'] as void Function(int)?)?.call(count);
              }
            }
          } catch (_) {
            failed = true;
            rethrow;
          }
          return true;
        });
      } else {
        final range =
            ((args['multipartChunkMiB'] as num?)?.toInt() ?? 8).clamp(5, 5120) *
                1024 *
                1024;
        Future<void> writes = Future.value();
        await _parallelParts((size + range - 1) ~/ range,
            profile.maxConcurrentRequests.clamp(1, 8), (index) async {
          final start = index * range;
          final count = min(range, size - start);
          var received = 0;
          final data = await http.requestStream('GET', bucket,
              key: key,
              query: query,
              headers: {
                ...readEncryptionHeaders,
                'range': 'bytes=$start-${start + count - 1}',
                'if-match': etag
              },
              maxResponseBytes: count, onResponseStart: () async {
            received = 0;
          }, onResponseChunk: (chunk) async {
            final offset = start + received;
            received += chunk.length;
            // Serialize disk writes while bounded network streams run together.
            writes = writes.then((_) async {
              await file.setPosition(offset);
              await file.writeFrom(chunk);
            });
            await writes;
          });
          _validateRange(data, start, count, size, etag,
              receivedBytes: received);
          (args['_progress'] as void Function(int)?)?.call(count);
          return true;
        });
      }
      await file.flush();
      await file.close();
      ActionScope.current?.check();
      var output = destination;
      if (args['conflictPolicy'] != 'replace') {
        var suffix = 0;
        // Reserve a previously unused name before atomic publication.
        while (true) {
          ActionScope.current?.check();
          output =
              File('${destination.path}${suffix == 0 ? '' : ' ($suffix)'}');
          if (await FileSystemEntity.type(output.path, followLinks: false) ==
              FileSystemEntityType.notFound) {
            // Reserve the name exclusively, then replace only our reservation.
            try {
              await output.create(exclusive: true);
              reservation = output;
              break;
            } on FileSystemException {
              // Only a confirmed racing name collision is retryable.
              if (await FileSystemEntity.type(output.path,
                      followLinks: false) ==
                  FileSystemEntityType.notFound) {
                rethrow;
              }
            }
          }
          suffix++;
        }
      }
      await temp.rename(output.path);
      reservation = null;
      return {
        'status': 'completed',
        'path': output.path,
        'fileSize': plaintextSize,
        'completedBytes': size,
        'successCount': 1,
        'failureCount': 0
      };
    } finally {
      cipher?.close();
      try {
        await file.close();
      } catch (_) {}
      if (reservation != null) {
        try {
          await reservation.delete();
        } catch (_) {}
      }
      if (await staging.exists()) await staging.delete(recursive: true);
    }
  }

  static void _validateRange(StorageHttpResponse response, int start, int count,
      int total, String etag,
      {int? receivedBytes}) {
    if (response.status != 206 ||
        (receivedBytes ?? response.body.length) != count ||
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
    if (args['clientEncryption'] != null && paths.length != 1) {
      MobileStorageAdmin._invalid(
          'Client encryption requires exactly one file.');
    }
    final config =
        MobileClientEncryption.parse(args['clientEncryption'], upload: true);
    final cipher =
        config == null ? null : MobileAgeWorker(config.key, config.nonce);
    try {
      var total = 0;
      for (final path in paths) {
        final file = File(path), before = await File(path).stat();
        Future<void> verifySource() async {
          final current = await file.stat();
          if (current.size != before.size ||
              current.modified != before.modified) {
            MobileStorageAdmin._conflict(
                'The local file changed during upload.');
          }
        }

        {
          // As in the desktop engines, a mapped name is relative to the prefix.
          final key = '${args['prefix'] ?? ''}'
              '${(args['objectKeyByPath'] as Map?)?[path] as String? ?? file.uri.pathSegments.last}';
          Future<List<int>> read(int start, int count) async {
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
          }

          final storedSize = config == null
              ? before.size
              : ageCiphertextLength(
                  headerLength: config.headerLength,
                  plaintextLength: before.size);
          await _writeObject(
              client(profile),
              '${args['bucketName']}',
              key,
              storedSize,
              config == null
                  ? read
                  : (start, count) => cipher!
                      .readCiphertext(config, before.size, start, count, read),
              clientEncrypted: config != null,
              encryption: args['encryption'],
              verifySource: verifySource,
              onProgress: args['_progress'] as void Function(int)?,
              streamReadBytes: config == null ? 256 * 1024 : 64 * 1024,
              multipartThresholdBytes:
                  ((args['multipartThresholdMiB'] as num?)?.toInt() ?? 32)
                          .clamp(1, 5120) *
                      1024 *
                      1024,
              partBytes: ((args['multipartChunkMiB'] as num?)?.toInt() ?? 8)
                      .clamp(5, 5120) *
                  1024 *
                  1024);
          total += storedSize;
        }
      }
      return transferResult('upload', total);
    } finally {
      cipher?.close();
      config?.dispose();
    }
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

/// Validate before mobile services enter trackedTransfer (which performs HEAD).
void validateClientDownloadName(Object? option) {
  if (option is! Map || !option.containsKey('fileName')) return;
  final name = option['fileName'];
  if (name is! String ||
      name.isEmpty ||
      name == '.' ||
      name == '..' ||
      name.contains(RegExp(r'[/\\\x00]'))) {
    MobileStorageAdmin._invalid('Invalid client encryption fileName.');
  }
}

/// Keep hidden names out of mobile service diagnostics, including nested traces.
Object? redactClientDownloadName(Object? value, [Object? option]) {
  final name = option is Map ? option['fileName'] : null;
  if (value is Map) {
    return value.map((key, item) => MapEntry(
        key,
        key == 'fileName'
            ? '[redacted]'
            : redactClientDownloadName(item, option)));
  }
  if (value is List) {
    return value.map((item) => redactClientDownloadName(item, option)).toList();
  }
  if (value is String && name is String && name.isNotEmpty) {
    return value.replaceAll(name, '[redacted]');
  }
  return value;
}
