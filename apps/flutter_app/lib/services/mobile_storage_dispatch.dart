part of 'mobile_storage_admin.dart';

extension MobileStorageDispatch on MobileStorageAdmin {
  bool handles(String method, Map<String, Object?> params) {
    if (params['profile'] is! Map) return false;
    if (method.toLowerCase().contains('benchmark')) return false;
    if ({'listBuckets', 'testProfile'}.contains(method)) {
      final profile = EndpointProfile.fromJson(
          Map<String, Object?>.from(params['profile'] as Map));
      final options = profile.connection;
      // AWS uses explicit REST pagination. Keep the existing native bridge for
      // ordinary compatible endpoints and their cached metadata behavior.
      if (profile.endpointType == EndpointProfileType.s3Compatible &&
          options.authMode == 'static' &&
          options.knownBucket.isEmpty &&
          options.caBundlePath.isEmpty &&
          !options.requesterPays &&
          options.expectedBucketOwner.isEmpty) {
        return false;
      }
    }
    return _portableMethods.contains(method);
  }

  Future<Map<String, Object?>> dispatch(
      String method, Map<String, Object?> params) async {
    final profile = EndpointProfile.fromJson(
        Map<String, Object?>.from(params['profile'] as Map));
    final http = client(profile), bucket = '${params['bucketName'] ?? ''}';
    if (method == 'runDeleteAll') return runStorageTool(profile, params);
    if (method == 'runPutTestData') {
      return runStoragePutTestData(profile, params);
    }
    if (method == 'getCapabilities') {
      return {
        'items': [
          for (final key in [
            'storage.admin',
            'bucket.browse',
            'object.browse',
            'object.versions',
            'object.copy_move',
            'object.tags',
            'object.debug',
            'bucket.admin_mutation',
            'benchmark',
            'transfers',
            'bucket.lifecycle',
            'bucket.encryption',
            'object.presign'
          ])
            {
              'key': key,
              'label': key,
              'state': http.azure &&
                      ({'bucket.lifecycle', 'bucket.encryption'}
                              .contains(key) ||
                          (key == 'object.presign' &&
                              profile.connection.authMode == 'azureSas'))
                  ? 'unsupported'
                  : 'supported',
              'reason': 'Provider REST adapter'
            }
        ]
      };
    }
    if (method == 'startUpload') {
      return trackedTransfer(profile, 'upload', params,
          (args) => uploadStorageFile(profile, args));
    }
    if (method == 'startDownload') {
      return trackedTransfer(profile, 'download', params, (args) async {
        var bytes = 0;
        for (final key in args['keys'] as List? ?? []) {
          final result = await download(profile, {...args, 'key': key});
          bytes += (result['completedBytes'] as num).toInt();
        }
        return transferResult('download', bytes);
      });
    }
    if (method == 'copyObject' || method == 'moveObject') {
      return copyStorageObject(profile, profile, {
        ...params,
        'conflictPolicy': 'replace',
        'move': method == 'moveObject'
      });
    }
    if (http.azure) {
      if (method == 'listBuckets') {
        final items = <Object?>[];
        final seen = <String>{};
        Map<String, Object?> cursor = {};
        do {
          final page =
              await azureAction(profile, method, {...params, 'cursor': cursor});
          items.addAll(page['items'] as List? ?? []);
          cursor = Map<String, Object?>.from(page['nextCursor'] as Map? ?? {});
          if (cursor['hasMore'] != true) break;
          if (!seen.add('${cursor['value']}')) {
            throw StateError('The container listing repeated its cursor.');
          }
        } while (true);
        return {'items': items};
      }
      return azureAction(
          profile,
          switch (method) {
            'getObjectDetails' => 'objectDetails',
            'generatePresignedUrl' => 'presignVersion',
            _ => method,
          },
          params);
    }
    switch (method) {
      case 'testProfile':
        if (profile.connection.knownBucket.isNotEmpty) {
          await http.request('HEAD', profile.connection.knownBucket);
        } else {
          await dispatch('listBuckets', params);
        }
        return {'success': true};
      case 'listBuckets':
        if (profile.connection.knownBucket.isNotEmpty) {
          await http.request('HEAD', profile.connection.knownBucket);
          return {
            'items': [
              {'name': profile.connection.knownBucket, 'region': profile.region}
            ]
          };
        }
        final items = <Map<String, Object?>>[];
        String? token;
        do {
          final root = (await http.request('GET', '', query: {
            'max-buckets': '1000',
            if (token != null) 'continuation-token': token
          }))
              .xml;
          for (final b in root.descendants
              .whereType<XmlElement>()
              .where((e) => e.name.local == 'Bucket')) {
            items.add({
              'name': xmlText(b, 'Name'),
              'region': xmlText(b, 'BucketRegion'),
              'createdAt': xmlText(b, 'CreationDate')
            });
          }
          final next = xmlText(root, 'ContinuationToken');
          if (next.isEmpty) break;
          if (next == token) {
            throw StateError('The bucket listing repeated its cursor.');
          }
          token = next;
        } while (true);
        return {'items': items};
      case 'createBucket':
        await action(
            profile: profile, action: 'ensureBucket', arguments: params);
        return {
          'name': bucket,
          'region': profile.region,
          'versioningEnabled': params['enableVersioning'] == true
        };
      case 'deleteBucket':
        await http.request('DELETE', bucket);
        return {'deleted': true};
      case 'getBucketAdminState':
        return bucketAdmin(profile, bucket);
      case 'setBucketVersioning':
        await _putXml(http, bucket, 'versioning', 'VersioningConfiguration',
            {'Status': params['enabled'] == true ? 'Enabled' : 'Suspended'});
        return bucketAdmin(profile, bucket);
      case 'putBucketLifecycle':
      case 'deleteBucketLifecycle':
        return action(profile: profile, action: 'putLifecycle', arguments: {
          ...params,
          if (method.startsWith('delete')) 'lifecycleJson': '{"Rules":[]}'
        });
      case 'putBucketPolicy':
      case 'deleteBucketPolicy':
        await action(profile: profile, action: 'putAccess', arguments: {
          ...params,
          if (method.startsWith('delete')) 'policyJson': '{}'
        });
        return bucketAdmin(profile, bucket);
      case 'putBucketCors':
      case 'deleteBucketCors':
      case 'putBucketEncryption':
      case 'deleteBucketEncryption':
      case 'putBucketTagging':
      case 'putBucketTags':
      case 'deleteBucketTagging':
      case 'deleteBucketTags':
        final section = method.contains('Cors')
            ? 'cors'
            : method.contains('Encryption')
                ? 'encryption'
                : 'tagging';
        if (method.startsWith('delete')) {
          await http.request('DELETE', bucket, query: {section: ''});
        } else {
          Map<String, Object?> value;
          if (section == 'tagging') {
            value = {
              'TagSet': {
                'Tags': (params['tags'] as Map? ?? {})
                    .entries
                    .map((e) => {'Key': '${e.key}', 'Value': '${e.value}'})
                    .toList()
              }
            };
          } else {
            final decoded = jsonDecode(
                '${params[section == 'cors' ? 'corsJson' : 'encryptionJson']}');
            value = decoded is List
                ? {'CORSRules': decoded}
                : Map<String, Object?>.from(decoded as Map);
          }
          await _putXml(
              http,
              bucket,
              section,
              section == 'cors'
                  ? 'CORSConfiguration'
                  : section == 'tagging'
                      ? 'Tagging'
                      : 'ServerSideEncryptionConfiguration',
              value);
        }
        return bucketAdmin(profile, bucket);
      case 'listObjects':
        return listObjects(profile, params);
      case 'listObjectVersions':
        return action(profile: profile, action: method, arguments: params);
      case 'getObjectDetails':
        return action(
            profile: profile, action: 'objectDetails', arguments: params);
      case 'generatePresignedUrl':
        return action(profile: profile, action: 'presignVersion', arguments: {
          ...params,
          'expiresSeconds': params['expirationSeconds'] ?? 3600
        });
      case 'createFolder':
        final key = '${params['key'] ?? params['prefix'] ?? ''}';
        await http.request('PUT', bucket,
            key: key.endsWith('/') ? key : '$key/');
        return {'created': true};
      case 'deleteObjects':
      case 'deleteObjectVersions':
        final entries = method == 'deleteObjects'
            ? (params['keys'] as List? ?? []).map((k) => {'key': k}).toList()
            : params['versions'] as List? ?? [];
        var completed = 0;
        final failures = <Map<String, Object?>>[];
        for (var start = 0; start < entries.length; start += 1000) {
          ActionScope.current?.check();
          final end = min(start + 1000, entries.length);
          final batch = entries.sublist(start, end).cast<Map>();
          final body = storageXml('Delete', {
            'Object': [
              for (final ref in batch)
                {
                  'Key': ref['key'],
                  if (ref['versionId'] != null) 'VersionId': ref['versionId']
                }
            ],
            'Quiet': false
          });
          try {
            final root = (await http.request('POST', bucket,
                    query: {'delete': ''},
                    body: body,
                    headers: {
                      'content-md5': base64Encode(md5.convert(body).bytes)
                    },
                    retrySafe: false))
                .xml;
            if (root.name.local != 'DeleteResult') {
              throw StateError('Invalid delete result.');
            }
            String identity(Object? key, Object? version) =>
                jsonEncode([key, version]);
            final outcomes = <String, XmlElement>{
              for (final node in root.childElements)
                if ({'Deleted', 'Error'}.contains(node.name.local))
                  identity(
                      xmlText(node, 'Key'),
                      node.childElements.any((e) => e.name.local == 'VersionId')
                          ? xmlText(node, 'VersionId')
                          : null): node
            };
            for (final ref in batch) {
              final outcome = outcomes[identity(ref['key'], ref['versionId'])];
              if (outcome?.name.local == 'Deleted') {
                completed++;
              } else {
                failures.add({
                  'target': ref['key'],
                  'versionId': ref['versionId'],
                  'code': outcome == null
                      ? 'unknown_outcome'
                      : xmlText(outcome, 'Code'),
                  'message': outcome == null
                      ? 'Deletion was not confirmed.'
                      : xmlText(outcome, 'Message')
                });
              }
            }
          } catch (e) {
            if (e is ListingCancelled) rethrow;
            for (var index = start; index < entries.length; index++) {
              final ref = entries[index] as Map;
              failures.add({
                'target': ref['key'],
                'versionId': ref['versionId'],
                'code': index < end
                    ? (e is StorageHttpException
                        ? e.serviceCode
                        : 'unknown_outcome')
                    : 'not_attempted',
                'message': index < end
                    ? (e is StorageHttpException
                        ? e.message
                        : 'Deletion was not confirmed. Inspect the selected objects before retrying.')
                    : 'Stopped after a failed delete batch.'
              });
            }
            break;
          }
        }
        return {
          'successCount': completed,
          'failureCount': failures.length,
          'failures': failures
        };
    }
    throw EngineException(
        code: ErrorCode.unsupportedFeature,
        message: 'Storage method $method is unavailable on this platform.');
  }
}

const _portableMethods = {
  'runDeleteAll',
  'runPutTestData',
  'getCapabilities',
  'testProfile',
  'listBuckets',
  'createBucket',
  'deleteBucket',
  'getBucketAdminState',
  'setBucketVersioning',
  'putBucketLifecycle',
  'deleteBucketLifecycle',
  'putBucketPolicy',
  'deleteBucketPolicy',
  'putBucketCors',
  'deleteBucketCors',
  'putBucketEncryption',
  'deleteBucketEncryption',
  'putBucketTagging',
  'deleteBucketTagging',
  'putBucketTags',
  'deleteBucketTags',
  'listObjects',
  'listObjectVersions',
  'getObjectDetails',
  'generatePresignedUrl',
  'createFolder',
  'copyObject',
  'moveObject',
  'deleteObjects',
  'deleteObjectVersions',
  'startUpload',
  'startDownload'
};
