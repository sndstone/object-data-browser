import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:xml/xml.dart';

import '../controllers/action_scope.dart';
import '../models/domain_models.dart';
import 'storage_http_client.dart';
import 'multipart_sizing.dart';

part 'mobile_azure_storage.dart';
part 'mobile_storage_transfers.dart';
part 'mobile_storage_dispatch.dart';
part 'mobile_storage_tools.dart';

/// Provider REST administration for Android/iOS, independent of desktop
/// sidecars and the reduced configuration models in older native SDKs.
class MobileStorageAdmin {
  final Map<EndpointProfile, StorageHttpClient> _clients = {};
  StorageHttpClient client(EndpointProfile profile) {
    if (!_clients.containsKey(profile) && _clients.length >= 8) {
      _clients.remove(_clients.keys.first)?.close();
    }
    return _clients.putIfAbsent(profile, () => StorageHttpClient(profile));
  }

  void close() {
    for (final value in _clients.values) {
      value.close();
    }
    _clients.clear();
  }

  static const s3Actions = [
    'providerInfo',
    'ensureBucket',
    'getBucketAdminState',
    'getBucketConfiguration',
    'putLifecycle',
    'getAccess',
    'putAccess',
    'objectDetails',
    'objectTags',
    'objectProperties',
    'getObjectProtection',
    'setObjectProtection',
    'getBucketProtection',
    'setBucketProtection',
    'restoreObject',
    'listMultipartUploads',
    'listParts',
    'abortMultipartUpload',
    'copyObject',
    'listObjects',
    'listObjectVersions',
    'downloadVersion',
    'presignVersion',
    'deleteVersion',
  ];

  Future<Map<String, Object?>> action(
      {required EndpointProfile profile,
      required String action,
      Map<String, Object?> arguments = const {},
      EndpointProfile? destinationProfile}) async {
    ActionScope.current?.check();
    final http = client(profile);
    final bucket = '${arguments['bucketName'] ?? ''}';
    final key = arguments['key'] as String?;
    final version = arguments['versionId'] as String?;
    final versionQuery = <String, String>{
      if (version != null) 'versionId': version
    };
    if (action == 'providerInfo') {
      if (http.azure) return azureAction(profile, action, arguments);
      return {
        'provider': profile.endpointType.name,
        'support': profile.endpointType == EndpointProfileType.s3Compatible
            ? 'unknown'
            : 'supported',
        'actions': http.azure ? mobileAzureActions : s3Actions,
        'storageClasses': http.azure
            ? ['Hot', 'Cool', 'Cold', 'Archive']
            : profile.connection.storageClasses.isNotEmpty
                ? profile.connection.storageClasses
                : [
                    'STANDARD',
                    'STANDARD_IA',
                    'ONEZONE_IA',
                    'INTELLIGENT_TIERING',
                    'GLACIER_IR',
                    'GLACIER',
                    'DEEP_ARCHIVE'
                  ]
      };
    }
    if (action == 'copyObject') {
      return _copy(profile, destinationProfile ?? profile, arguments);
    }
    if (action == 'downloadVersion') {
      return download(profile, arguments);
    }
    if (http.azure) return _azureAction(profile, action, arguments);
    if (bucket.isEmpty) _invalid('Bucket name is required.');
    switch (action) {
      case 'ensureBucket':
        try {
          await http.request('HEAD', bucket);
        } on StorageHttpException catch (error) {
          if (error.response.status != 404) rethrow;
          final payload =
              profile.region.isEmpty || profile.region == 'us-east-1'
                  ? <int>[]
                  : storageXml('CreateBucketConfiguration',
                      {'LocationConstraint': profile.region});
          await http.request('PUT', bucket, body: payload, headers: {
            if (arguments['enableObjectLock'] == true)
              'x-amz-bucket-object-lock-enabled': 'true'
          });
        }
        if (arguments['enableVersioning'] == true ||
            arguments['versioningEnabled'] == true) {
          await _putXml(http, bucket, 'versioning', 'VersioningConfiguration',
              {'Status': 'Enabled'});
        }
        return {'exists': true};
      case 'getBucketAdminState':
        return bucketAdmin(profile, bucket);
      case 'getBucketConfiguration':
        final sections = <Map<String, Object?>>[], result = <String, Object?>{};
        for (final entry in {
          'replication': 'replication',
          'notification': 'notification',
          'ownershipControls': 'ownershipControls',
          'publicAccessBlock': 'publicAccessBlock'
        }.entries) {
          result[entry.key] =
              await _optionalConfig(http, bucket, entry.value, sections);
        }
        return {...result, 'sections': sections, 'apiCalls': sections};
      case 'putLifecycle':
        final parsed =
            jsonDecode(arguments['lifecycleJson'] as String? ?? '{}');
        final configuration = parsed is List
            ? {'Rules': parsed}
            : Map<String, Object?>.from(parsed as Map);
        if (arguments['expectedLifecycleJson'] != null) {
          final current = await _getConfig(http, bucket, 'lifecycle');
          if (!_sameJson(current,
              jsonDecode(arguments['expectedLifecycleJson'] as String))) {
            _conflict(
                'Lifecycle policy changed. Refresh the preset before saving.');
          }
        }
        if ((configuration['Rules'] as List? ?? []).isEmpty) {
          await http.request('DELETE', bucket, query: {'lifecycle': ''});
        } else {
          await _putXml(http, bucket, 'lifecycle', 'LifecycleConfiguration',
              configuration,
              headers: {
                if (arguments['transitionDefaultMinimumObjectSize'] != null)
                  'x-amz-transition-default-minimum-object-size':
                      '${arguments['transitionDefaultMinimumObjectSize']}'
              });
        }
        return bucketAdmin(profile, bucket);
      case 'getAccess':
        final calls = <Map<String, Object?>>[];
        return {
          'policyJson':
              jsonEncode(await _optionalConfig(http, bucket, 'policy', calls)),
          'acl': await _optionalConfig(http, bucket, 'acl', calls),
          'ownershipControls':
              await _optionalConfig(http, bucket, 'ownershipControls', calls),
          'publicAccessBlock':
              await _optionalConfig(http, bucket, 'publicAccessBlock', calls),
          'sections': calls,
        };
      case 'putAccess':
        if (arguments.containsKey('expectedPolicyJson')) {
          final current = await _getConfig(http, bucket, 'policy');
          if (!_sameJson(current,
              jsonDecode(arguments['expectedPolicyJson'] as String? ?? '{}'))) {
            _conflict(
                'Bucket policy changed. Refresh before applying the preset.');
          }
        }
        if (arguments['policyJson'] != null) {
          final policy = jsonDecode(arguments['policyJson'] as String) as Map;
          if (policy.isEmpty ||
              (policy['Statement'] is List &&
                  (policy['Statement'] as List).isEmpty)) {
            await http.request('DELETE', bucket, query: {'policy': ''});
          } else {
            await http.request('PUT', bucket,
                query: {'policy': ''},
                body: utf8.encode(jsonEncode(policy)),
                headers: {'content-type': 'application/json'});
          }
        }
        if (arguments['acl'] != null) {
          final acl = '${arguments['acl']}';
          if (!{'private', 'public-read'}.contains(acl)) {
            _invalid('Select a supported bucket ACL preset.');
          }
          await http.request('PUT', bucket,
              query: {'acl': ''}, headers: {'x-amz-acl': acl});
        }
        return {'applied': true};
      case 'listObjects':
        return listObjects(profile, arguments);
      case 'listObjectVersions':
        final cursor =
            Map<String, Object?>.from(arguments['cursor'] as Map? ?? {});
        final marker = cursor['value'] == null
            ? <String, dynamic>{}
            : jsonDecode('${cursor['value']}') as Map<String, dynamic>;
        final root = (await http.request('GET', bucket, query: {
          'versions': '',
          'max-keys': '1000',
          'prefix': key ?? '${arguments['prefix'] ?? ''}',
          if (marker['key'] != null) 'key-marker': '${marker['key']}',
          if (marker['version'] != null)
            'version-id-marker': '${marker['version']}'
        }))
            .xml;
        final rows = <Map<String, Object?>>[];
        for (final element in root.childElements
            .where((e) => {'Version', 'DeleteMarker'}.contains(e.name.local))) {
          final name = xmlText(element, 'Key');
          if (key != null && name != key) continue;
          final options = arguments['options'] as Map? ?? {};
          if (element.name.local == 'Version' &&
              options['showVersions'] == false) {
            continue;
          }
          if (element.name.local == 'DeleteMarker' &&
              options['showDeleteMarkers'] == false) {
            continue;
          }
          rows.add({
            'key': name,
            'versionId': xmlText(element, 'VersionId'),
            'modifiedAt': xmlText(element, 'LastModified'),
            'latest': xmlText(element, 'IsLatest') == 'true',
            'deleteMarker': element.name.local == 'DeleteMarker',
            'size': int.tryParse(xmlText(element, 'Size')) ?? 0,
            'etag': xmlText(element, 'ETag'),
            'storageClass': xmlText(element, 'StorageClass')
          });
        }
        final more = xmlText(root, 'IsTruncated') == 'true';
        return {
          'items': rows,
          'cursor': {
            'hasMore': more,
            'value': more
                ? jsonEncode({
                    'key': xmlText(root, 'NextKeyMarker'),
                    'version': xmlText(root, 'NextVersionIdMarker')
                  })
                : null
          },
          'totalCount': rows.length,
          'versionCount': rows.where((r) => r['deleteMarker'] == false).length,
          'deleteMarkerCount':
              rows.where((r) => r['deleteMarker'] == true).length
        };
      case 'objectDetails':
        return _s3Details(http, bucket, _key(key), versionQuery);
      case 'objectTags':
        if (arguments['tags'] is Map) {
          await _putXml(
              http,
              bucket,
              'tagging',
              'Tagging',
              {
                'TagSet': {
                  'Tag': (arguments['tags'] as Map)
                      .entries
                      .map((e) => {'Key': '${e.key}', 'Value': '${e.value}'})
                      .toList()
                }
              },
              key: _key(key),
              query: versionQuery);
        }
        final root = (await http.request('GET', bucket,
                key: _key(key), query: {...versionQuery, 'tagging': ''}))
            .xml;
        return {
          'tags': {
            for (final item in root.descendants
                .whereType<XmlElement>()
                .where((e) => e.name.local == 'Tag'))
              xmlText(item, 'Key'): xmlText(item, 'Value')
          }
        };
      case 'deleteVersion':
        if (version == null || version.isEmpty) {
          _invalid('An explicit version ID is required.');
        }
        await http.request('DELETE', bucket,
            key: _key(key), query: versionQuery);
        return {
          'successCount': 1,
          'failureCount': 0,
          'failures': [],
          'deleted': true
        };
      case 'presignVersion':
        return {
          'url': http.presign(bucket, _key(key),
              versionId: version,
              expiresSeconds:
                  (arguments['expiresSeconds'] as num?)?.toInt() ?? 3600)
        };
      case 'getBucketProtection':
      case 'setBucketProtection':
        if (action.startsWith('set')) {
          await _putXml(http, bucket, 'object-lock', 'ObjectLockConfiguration',
              Map<String, Object?>.from(arguments['configuration'] as Map));
        }
        return {'configuration': await _getConfig(http, bucket, 'object-lock')};
      case 'getObjectProtection':
      case 'setObjectProtection':
        if (action.startsWith('set')) {
          if (arguments['retention'] is Map) {
            await _putXml(http, bucket, 'retention', 'Retention',
                Map<String, Object?>.from(arguments['retention'] as Map),
                key: _key(key),
                query: versionQuery,
                headers: {
                  if (arguments['bypassGovernanceRetention'] == true)
                    'x-amz-bypass-governance-retention': 'true'
                });
          }
          if (arguments.containsKey('legalHold')) {
            final hold = arguments['legalHold'];
            await _putXml(
                http,
                bucket,
                'legal-hold',
                'LegalHold',
                hold is Map
                    ? Map<String, Object?>.from(hold)
                    : {'Status': hold == true ? 'ON' : 'OFF'},
                key: _key(key),
                query: versionQuery);
          }
        }
        final sections = <Map<String, Object?>>[];
        return {
          'retention': await _optionalConfig(
              http, bucket, 'retention', sections,
              key: _key(key), query: versionQuery),
          'legalHold': await _optionalConfig(
              http, bucket, 'legal-hold', sections,
              key: _key(key), query: versionQuery),
          'sections': sections
        };
      case 'restoreObject':
        await _putXml(
            http,
            bucket,
            'restore',
            'RestoreRequest',
            {
              'Days': arguments['days'] ?? 7,
              'GlacierJobParameters': {'Tier': arguments['tier'] ?? 'Standard'}
            },
            key: _key(key),
            query: versionQuery,
            method: 'POST');
        return {'requested': true};
      case 'listMultipartUploads':
        final cursor = arguments['cursor'] as Map? ?? {};
        final root = (await http.request('GET', bucket, query: {
          'uploads': '',
          'max-uploads': '1000',
          'prefix': '${arguments['prefix'] ?? ''}',
          if (cursor['KeyMarker'] != null)
            'key-marker': '${cursor['KeyMarker']}',
          if (cursor['UploadIdMarker'] != null)
            'upload-id-marker': '${cursor['UploadIdMarker']}'
        }))
            .xml;
        return {
          'items': root.childElements
              .where((e) => e.name.local == 'Upload')
              .map(storageXmlMap)
              .toList(),
          'nextCursor': {
            'KeyMarker': xmlText(root, 'NextKeyMarker'),
            'UploadIdMarker': xmlText(root, 'NextUploadIdMarker'),
            'hasMore': xmlText(root, 'IsTruncated') == 'true'
          }
        };
      case 'listParts':
        final cursor = arguments['cursor'] as Map? ?? {};
        final root = (await http.request('GET', bucket, key: _key(key), query: {
          'uploadId': '${arguments['uploadId']}',
          'max-parts': '1000',
          if (cursor['PartNumberMarker'] != null)
            'part-number-marker': '${cursor['PartNumberMarker']}'
        }))
            .xml;
        return {
          'items': root.childElements
              .where((e) => e.name.local == 'Part')
              .map(storageXmlMap)
              .toList(),
          'nextCursor': {
            'PartNumberMarker': xmlText(root, 'NextPartNumberMarker'),
            'hasMore': xmlText(root, 'IsTruncated') == 'true'
          }
        };
      case 'abortMultipartUpload':
        await http.request('DELETE', bucket,
            key: _key(key), query: {'uploadId': '${arguments['uploadId']}'});
        return {'aborted': true};
      case 'objectProperties':
        return _copy(profile, profile, {
          'sourceBucketName': bucket,
          'destinationBucketName': bucket,
          'sourceKey': _key(key),
          'destinationKey': key,
          'sourceVersionId': version,
          'conflictPolicy': 'replace',
          'expectedSourceETag': arguments['expectedETag'],
          'options': {
            for (final field in [
              'metadata',
              'headers',
              'storageClass',
              'encryption'
            ])
              if (arguments.containsKey(field)) field: arguments[field]
          }
        });
    }
    throw EngineException(
        code: ErrorCode.unsupportedFeature,
        message: 'Mobile storage action $action is unavailable.');
  }

  Future<Map<String, Object?>> bucketAdmin(
      EndpointProfile profile, String bucket) async {
    final http = client(profile), calls = <Map<String, Object?>>[];
    final values = <String, Object?>{};
    for (final query in [
      'versioning',
      'lifecycle',
      'policy',
      'cors',
      'encryption',
      'tagging',
      'object-lock'
    ]) {
      values[query] = await _optionalConfig(http, bucket, query, calls);
    }
    final versioning = values['versioning'] as Map? ?? {};
    final lock = values['object-lock'] as Map? ?? {};
    final tagging = values['tagging'] as Map? ?? {};
    final tagSet = tagging['TagSet'] as Map? ?? {};
    final tags = tagSet['Tags'] ?? tagSet['Tag'] ?? [];
    final rules = (values['lifecycle'] as Map?)?['Rules'] as List? ?? [];
    final retention = (lock['Rule'] as Map?)?['DefaultRetention'] as Map? ?? {};
    final encryptionRules =
        (values['encryption'] as Map?)?['Rules'] as List? ?? [];
    final encryption = encryptionRules.isEmpty
        ? <Object?, Object?>{}
        : (encryptionRules.first as Map)['ApplyServerSideEncryptionByDefault']
                as Map? ??
            {};

    return {
      'bucketName': bucket,
      'versioningEnabled': versioning['Status'] == 'Enabled',
      'versioningStatus': versioning['Status'] ?? '',
      'objectLockMode': retention['Mode'],
      'objectLockRetentionDays': retention['Days'],
      'objectLockRetentionYears': retention['Years'],
      'lifecycleEnabled': rules.isNotEmpty,
      'policyAttached': (values['policy'] as Map?)?.isNotEmpty == true,
      'corsEnabled':
          ((values['cors'] as Map?)?['CORSRules'] as List? ?? []).isNotEmpty,
      'encryptionEnabled': encryptionRules.isNotEmpty,
      'encryptionSummary': encryption['SSEAlgorithm'] ?? 'Not configured',
      'transitionDefaultMinimumObjectSize': calls
          .where((c) => c['section'] == 'lifecycle')
          .firstOrNull?['transitionDefaultMinimumObjectSize'],
      'lifecycleRules': [
        for (final raw in rules)
          {
            'id': (raw as Map)['ID'] ?? '',
            'enabled': raw['Status'] == 'Enabled',
            'prefix': (raw['Filter'] as Map?)?['Prefix'] ?? raw['Prefix'] ?? '',
            'expirationDays': (raw['Expiration'] as Map?)?['Days']
          }
      ],
      'objectLockEnabled': lock['ObjectLockEnabled'] == 'Enabled',
      'lifecycleJson': jsonEncode(values['lifecycle']),
      'policyJson': jsonEncode(values['policy']),
      'corsJson': jsonEncode((values['cors'] as Map?)?['CORSRules'] ?? []),
      'encryptionJson': jsonEncode(values['encryption']),
      'tags': {
        if (tags is List)
          for (final tag in tags.whereType<Map>())
            '${tag['Key']}': '${tag['Value']}'
      },
      'apiCalls': calls,
      'sections': {
        for (final call in calls)
          '${call['operation']}': {
            'state': call['state'],
            'message': call['message'] ?? ''
          }
      }
    };
  }

  Future<Map<String, Object?>> listObjects(
      EndpointProfile profile, Map<String, Object?> arguments) async {
    final http = client(profile);
    if (http.azure) return _azureAction(profile, 'listObjects', arguments);
    final cursor = arguments['cursor'] as Map? ?? {};
    final root =
        (await http.request('GET', '${arguments['bucketName']}', query: {
      'list-type': '2',
      'max-keys': '1000',
      'prefix': '${arguments['prefix'] ?? ''}',
      if (arguments['flat'] != true) 'delimiter': '/',
      if (cursor['value'] != null) 'continuation-token': '${cursor['value']}'
    }))
            .xml;
    final rows = <Map<String, Object?>>[];
    for (final item in root.childElements) {
      if (item.name.local == 'Contents') {
        rows.add({
          'key': xmlText(item, 'Key'),
          'name': xmlText(item, 'Key').split('/').last,
          'size': int.tryParse(xmlText(item, 'Size')) ?? 0,
          'modifiedAt': xmlText(item, 'LastModified'),
          'etag': xmlText(item, 'ETag'),
          'storageClass': xmlText(item, 'StorageClass'),
          'isFolder': false
        });
      }
      if (item.name.local == 'CommonPrefixes') {
        rows.add({
          'key': xmlText(item, 'Prefix'),
          'name': xmlText(item, 'Prefix')
              .substring('${arguments['prefix'] ?? ''}'.length),
          'size': 0,
          'isFolder': true
        });
      }
    }
    return {
      'items': rows,
      'nextCursor': {
        'hasMore': xmlText(root, 'IsTruncated') == 'true',
        'value': xmlText(root, 'NextContinuationToken').isEmpty
            ? null
            : xmlText(root, 'NextContinuationToken')
      },
      'totalCount': rows.length
    };
  }

  Future<Map<String, Object?>> _s3Details(StorageHttpClient http, String bucket,
      String key, Map<String, String> query) async {
    final response = await http.request('HEAD', bucket, key: key, query: query);
    return {
      'key': key,
      'size': int.tryParse(response.headers['content-length'] ?? '') ?? 0,
      'etag': response.headers['etag'] ?? '',
      'contentType':
          response.headers['content-type'] ?? 'application/octet-stream',
      'modifiedAt': _date(response.headers['last-modified']),
      'versionId': response.headers['x-amz-version-id'],
      'storageClass': response.headers['x-amz-storage-class'] ?? 'STANDARD',
      'encryption': response.headers['x-amz-server-side-encryption'],
      'metadata': {
        for (final e in response.headers.entries)
          if (e.key.startsWith('x-amz-meta-')) e.key.substring(11): e.value
      },
      'headers': {
        for (final e in contentHeaders.entries)
          if (response.headers[e.value] != null)
            e.key: response.headers[e.value]
      },
      'rawHeaders': response.headers
    };
  }

  Future<Map<String, Object?>> _getConfig(
      StorageHttpClient http, String bucket, String query,
      {String? key, Map<String, String> parameters = const {}}) async {
    try {
      final response = await http
          .request('GET', bucket, key: key, query: {...parameters, query: ''});
      return query == 'policy'
          ? Map<String, Object?>.from(jsonDecode(response.text) as Map)
          : storageXmlMap(response.xml);
    } on StorageHttpException catch (error) {
      if (error.response.status == 404 &&
          _missingConfigurations.contains(error.serviceCode)) {
        return {};
      }
      rethrow;
    }
  }

  Future<Map<String, Object?>> _optionalConfig(StorageHttpClient http,
      String bucket, String subresource, List<Map<String, Object?>> calls,
      {String? key, Map<String, String> query = const {}}) async {
    try {
      final response = await http
          .request('GET', bucket, key: key, query: {...query, subresource: ''});
      calls.add({
        'section': subresource,
        'state': 'supported',
        'operation': _configOperations[subresource] ?? 'Get $subresource',
        'success': true,
        if (subresource == 'lifecycle')
          'transitionDefaultMinimumObjectSize':
              response.headers['x-amz-transition-default-minimum-object-size'],
      });
      return subresource == 'policy'
          ? Map<String, Object?>.from(jsonDecode(response.text) as Map)
          : storageXmlMap(response.xml);
    } on StorageHttpException catch (error) {
      if ({'NoSuchBucket', 'NoSuchKey', 'NoSuchVersion'}
          .contains(error.serviceCode)) {
        rethrow;
      }
      final state = switch (error.response.status) {
        404 => _missingConfigurations.contains(error.serviceCode)
            ? 'missing'
            : 'unknown',
        401 || 403 => 'denied',
        405 || 501 => 'unsupported',
        _ => 'error'
      };
      calls.add({
        'section': subresource,
        'state': state,
        'operation': _configOperations[subresource] ?? 'Get $subresource',
        'success': false,
        'message': error.message
      });
      return {};
    }
  }

  Future<void> _putXml(StorageHttpClient http, String bucket,
      String subresource, String root, Map<String, Object?> value,
      {String? key,
      Map<String, String> query = const {},
      Map<String, String> headers = const {},
      String method = 'PUT'}) async {
    final body = storageXml(root, value);
    await http.request(method, bucket,
        key: key,
        query: {...query, subresource: ''},
        body: body,
        headers: {
          'content-type': 'application/xml',
          'content-md5': base64Encode(md5.convert(body).bytes),
          ...headers
        });
  }

  static const contentHeaders = {
    'Content-Type': 'content-type',
    'Cache-Control': 'cache-control',
    'Content-Disposition': 'content-disposition',
    'Content-Encoding': 'content-encoding',
    'Content-Language': 'content-language',
    'Expires': 'expires'
  };
  static String _key(String? key) {
    if (key == null || key.isEmpty) {
      _invalid('An exact object key is required.');
    }
    return key;
  }

  static String? _date(String? value) {
    if (value == null) return null;
    try {
      return HttpDate.parse(value).toUtc().toIso8601String();
    } catch (_) {
      return value;
    }
  }

  static Never _invalid(String message) =>
      throw EngineException(code: ErrorCode.invalidConfig, message: message);
  static Never _conflict(String message) =>
      throw EngineException(code: ErrorCode.objectConflict, message: message);
  static bool _sameJson(Object? a, Object? b) {
    Object? canonical(Object? value) {
      if (value is Map) {
        return {
          for (final key in value.keys.map((k) => '$k').toList()..sort())
            key: canonical(value[key])
        };
      }
      if (value is List) return value.map(canonical).toList();
      return value;
    }

    return jsonEncode(canonical(a)) == jsonEncode(canonical(b));
  }

  // Implementations below share the same signed transport and bounded ranges.
  Future<Map<String, Object?>> _azureAction(EndpointProfile profile,
          String action, Map<String, Object?> arguments) =>
      azureAction(profile, action, arguments);
  Future<Map<String, Object?>> _copy(EndpointProfile source,
          EndpointProfile destination, Map<String, Object?> arguments) =>
      copyStorageObject(source, destination, arguments);
  Future<Map<String, Object?>> download(
          EndpointProfile profile, Map<String, Object?> arguments) =>
      downloadStorageObject(profile, arguments);
}

String xmlText(XmlElement element, String name) =>
    element.childElements
        .where((e) => e.name.local == name)
        .firstOrNull
        ?.innerText ??
    '';

const _xmlNames = {
  'Rules': 'Rule',
  'Transitions': 'Transition',
  'NoncurrentVersionTransitions': 'NoncurrentVersionTransition',
  'Tags': 'Tag',
  'CORSRules': 'CORSRule',
  'AllowedOrigins': 'AllowedOrigin',
  'AllowedMethods': 'AllowedMethod',
  'AllowedHeaders': 'AllowedHeader',
  'ExposeHeaders': 'ExposeHeader',
  'Grants': 'Grant',
  'Parts': 'Part'
};

List<int> storageXml(String root, Map<String, Object?> data) {
  XmlElement element(String name, Object? value) => XmlElement(
      XmlName(name),
      [],
      value is Map
          ? value.entries
              .expand((entry) => entry.value is List
                  ? (entry.value as List).map((child) => element(
                      _xmlNames['${entry.key}'] ?? '${entry.key}', child))
                  : [element('${entry.key}', entry.value)])
              .toList()
          : value == null
              ? []
              : [XmlText('$value')]);
  final value = element(root, data);
  value.setAttribute('xmlns', 'http://s3.amazonaws.com/doc/2006-03-01/');
  return utf8.encode(XmlDocument([value]).toXmlString());
}

Map<String, Object?> storageXmlMap(XmlElement root) {
  final result = <String, Object?>{};
  for (final element in root.childElements) {
    final name = element.name.local;
    final plural =
        root.name.local == 'ObjectLockConfiguration' && name == 'Rule'
            ? null
            : _xmlNames.entries.where((e) => e.value == name).firstOrNull?.key;
    Object? value;
    if (element.childElements.isNotEmpty) {
      value = storageXmlMap(element);
    } else {
      final text = element.innerText;
      value = {
        'Days',
        'Years',
        'NoncurrentDays',
        'NewerNoncurrentVersions',
        'DaysAfterInitiation',
        'ObjectSizeGreaterThan',
        'ObjectSizeLessThan',
        'MaxAgeSeconds',
        'PartNumber',
        'Size'
      }.contains(name)
          ? int.tryParse(text) ?? text
          : {'true', 'false'}.contains(text)
              ? text == 'true'
              : text;
    }
    if (plural != null) {
      (result.putIfAbsent(plural, () => <Object?>[]) as List).add(value);
    } else if (result.containsKey(name)) {
      final existing = result[name];
      if (existing is List) {
        existing.add(value);
      } else {
        result[name] = [existing, value];
      }
    } else {
      result[name] = value;
    }
  }
  return result;
}

const _configOperations = {
  'versioning': 'GetBucketVersioning',
  'lifecycle': 'GetBucketLifecycleConfiguration',
  'policy': 'GetBucketPolicy',
  'cors': 'GetBucketCors',
  'encryption': 'GetBucketEncryption',
  'tagging': 'GetBucketTagging',
  'object-lock': 'GetObjectLockConfiguration',
  'acl': 'GetBucketAcl',
  'ownershipControls': 'GetBucketOwnershipControls',
  'publicAccessBlock': 'GetPublicAccessBlock',
  'retention': 'GetObjectRetention',
  'legal-hold': 'GetObjectLegalHold'
};

const _missingConfigurations = {
  'NoSuchLifecycleConfiguration',
  'NoSuchBucketPolicy',
  'NoSuchCORSConfiguration',
  'NoSuchTagSet',
  'ServerSideEncryptionConfigurationNotFoundError',
  'ObjectLockConfigurationNotFoundError',
  'NoSuchOwnershipControls',
  'NoSuchPublicAccessBlockConfiguration'
};
