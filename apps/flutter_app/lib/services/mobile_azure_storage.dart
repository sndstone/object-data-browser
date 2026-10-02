part of 'mobile_storage_admin.dart';

const mobileAzureActions = <String>[
  'providerInfo',
  'testProfile',
  'listBuckets',
  'createBucket',
  'deleteBucket',
  'ensureBucket',
  'listObjects',
  'listObjectVersions',
  'deleteObjects',
  'deleteVersion',
  'objectDetails',
  'objectTags',
  'objectProperties',
  'getObjectProtection',
  'setObjectProtection',
  'getBucketProtection',
  'getBucketAdminState',
  'getAccess',
  'putAccess',
  'createFolder',
  'presignVersion',
  'generatePresignedUrl',
  'restoreObject',
  'setAccountCors',
  'setContainerMetadata',
  'copyObject',
  'downloadVersion',
];

extension MobileAzureStorageAdapter on MobileStorageAdmin {
  Future<Map<String, Object?>> azureAction(EndpointProfile profile,
      String action, Map<String, Object?> arguments) async {
    ActionScope.current?.check();
    if (!{'static', 'azureSas'}.contains(profile.connection.authMode)) {
      _azureUnsupported(
          'Mobile Azure storage requires an account key or SAS. Azure identity and management-plane authentication are unavailable.');
    }
    final http = client(profile);
    final bucket = '${arguments['bucketName'] ?? ''}';
    final key = arguments['key'] as String?;
    final version = arguments['versionId'] as String?;
    final query = <String, String>{
      if (version?.isNotEmpty == true) 'versionid': version!
    };
    if (action == 'providerInfo') {
      return {
        'provider': 'azureBlob',
        'support': 'supported',
        'actions': mobileAzureActions
            .where((name) =>
                profile.connection.authMode != 'azureSas' ||
                !{'presignVersion', 'generatePresignedUrl'}.contains(name))
            .toList(),
        'storageClasses': ['Hot', 'Cool', 'Cold', 'Archive'],
        'unsupported': [
          'accountLifecycle',
          'accountVersioning',
          'accountEncryption',
          'containerImmutabilityManagement',
          'azureDefault'
        ]
      };
    }
    if (action == 'listBuckets' || action == 'testProfile') {
      final known = profile.connection.knownBucket;
      Map<String, Object?> result;
      if (known.isNotEmpty) {
        if (action == 'testProfile') {
          await http.request('HEAD', known, query: {'restype': 'container'});
        }
        result = {
          'items': [_azureBucketRow(known, profile)],
          'nextCursor': {'hasMore': false, 'value': null}
        };
      } else {
        final root = (await http.request('GET', '', query: {
          'comp': 'list',
          'maxresults': '1000',
          if (_azureMarker(arguments) != null)
            'marker': _azureMarker(arguments)!
        }))
            .xml;
        final containers = _azureChild(root, 'Containers');
        result = {
          'items': [
            if (containers != null)
              for (final item in containers.childElements
                  .where((node) => node.name.local == 'Container'))
                _azureBucketRow(xmlText(item, 'Name'), profile,
                    modified: xmlText(_azureChild(item, 'Properties') ?? item,
                        'Last-Modified'))
          ],
          'nextCursor': _azureCursor(xmlText(root, 'NextMarker'))
        };
      }
      return action == 'testProfile'
          ? {
              'success': true,
              'message': known.isEmpty
                  ? 'Azure account listing succeeded.'
                  : 'Azure container access succeeded.',
              'bucketCount': (result['items'] as List).length
            }
          : result;
    }
    if (bucket.isEmpty && action != 'setAccountCors') {
      _azureInvalid('A container name is required.');
    }
    switch (action) {
      case 'ensureBucket':
      case 'createBucket':
        if (arguments['enableVersioning'] == true ||
            arguments['versioningEnabled'] == true ||
            arguments['enableObjectLock'] == true) {
          _azureUnsupported(
              'Azure versioning and container immutability require account management; no container was created.');
        }
        if (action == 'ensureBucket') {
          try {
            await http.request('HEAD', bucket, query: {'restype': 'container'});
            return {'exists': true};
          } on StorageHttpException catch (error) {
            if (error.response.status != 404) rethrow;
          }
        }
        await http.request('PUT', bucket, query: {'restype': 'container'});
        return action == 'ensureBucket'
            ? {'exists': true, 'created': true}
            : _azureBucketRow(bucket, profile);
      case 'deleteBucket':
        await http.request('DELETE', bucket, query: {'restype': 'container'});
        return {'deleted': true, 'bucketName': bucket};
      case 'listObjects':
      case 'listObjectVersions':
        final versions = action == 'listObjectVersions';
        final root = (await http.request('GET', bucket, query: {
          'restype': 'container',
          'comp': 'list',
          'maxresults': '1000',
          'prefix':
              versions && key != null ? key : '${arguments['prefix'] ?? ''}',
          if (!versions && arguments['flat'] != true) 'delimiter': '/',
          if (versions) 'include': 'versions',
          if (_azureMarker(arguments) != null)
            'marker': _azureMarker(arguments)!,
        }))
            .xml;
        final blobs = _azureChild(root, 'Blobs');
        final rows = <Map<String, Object?>>[];
        for (final item in blobs?.childElements ?? <XmlElement>[]) {
          final name = xmlText(item, 'Name');
          if (item.name.local == 'BlobPrefix' && !versions) {
            rows.add({'key': name, 'size': 0, 'isFolder': true});
          } else if (item.name.local == 'Blob' &&
              (!versions || key == null || key == name)) {
            final properties = _azureChild(item, 'Properties') ?? item;
            rows.add({
              'key': name,
              'size': int.tryParse(xmlText(properties, 'Content-Length')) ?? 0,
              'modifiedAt': MobileStorageAdmin._date(
                  xmlText(properties, 'Last-Modified')),
              'etag': xmlText(properties, 'Etag'),
              'storageClass': xmlText(properties, 'AccessTier').isEmpty
                  ? 'Hot'
                  : xmlText(properties, 'AccessTier'),
              'isFolder': false,
              if (versions) ...{
                'versionId': xmlText(item, 'VersionId'),
                'latest': xmlText(item, 'IsCurrentVersion') == 'true',
                'deleteMarker': false
              }
            });
          }
        }
        final cursor = _azureCursor(xmlText(root, 'NextMarker'));
        return {
          'items': rows,
          'cursor': cursor,
          'nextCursor': cursor,
          'totalCount': rows.length,
          if (versions) ...{'versionCount': rows.length, 'deleteMarkerCount': 0}
        };
      case 'objectDetails':
      case 'getObjectDetails':
        return _azureDetails(http, bucket, _azureKey(key), query);
      case 'createFolder':
        final raw = _azureKey(key ?? arguments['prefix'] as String?);
        final folder = raw.endsWith('/') ? raw : '$raw/';
        await http.request('PUT', bucket,
            key: folder,
            headers: {'x-ms-blob-type': 'BlockBlob', 'if-none-match': '*'});
        return {'created': true, 'key': folder};
      case 'deleteVersion':
        if (version == null || version.isEmpty) {
          _azureInvalid('An exact version ID is required.');
        }
        await http.request('DELETE', bucket, key: _azureKey(key), query: query);
        return {
          'deleted': true,
          'successCount': 1,
          'failureCount': 0,
          'failures': []
        };
      case 'deleteObjects':
      case 'deleteObjectVersions':
        final entries = action == 'deleteObjects'
            ? [
                for (final key
                    in (arguments['keys'] as List? ?? []).cast<String>())
                  {'key': key}
              ]
            : [
                for (final entry in arguments['versions'] as List? ?? [])
                  Map<String, Object?>.from(entry as Map)
              ];
        for (final entry in entries) {
          _azureKey(entry['key'] as String?);
          if (action == 'deleteObjectVersions' &&
              (entry['versionId'] is! String ||
                  (entry['versionId'] as String).isEmpty)) {
            _azureInvalid(
                'Every selected version must have an exact version ID.');
          }
        }
        var successes = 0;
        final failures = <Map<String, Object?>>[];
        for (final entry in entries) {
          final name = entry['key'] as String;
          ActionScope.current?.check();
          try {
            await http.request('DELETE', bucket, key: name, query: {
              if (entry['versionId'] != null)
                'versionid': '${entry['versionId']}'
            }, headers: {
              if (entry['versionId'] == null &&
                  arguments['deleteSnapshots'] == true)
                'x-ms-delete-snapshots': 'include',
            });
            successes++;
          } on StorageHttpException catch (error) {
            if (error.response.status == 404) {
              successes++;
            } else {
              failures.add({
                'target': name,
                'code': error.serviceCode,
                'message': error.message
              });
            }
          }
        }
        return {
          'successCount': successes,
          'failureCount': failures.length,
          'failures': failures
        };
      case 'objectTags':
        if (arguments.containsKey('tags')) {
          final tags = _azureStringMap(arguments['tags'], 'tags');
          if (tags.length > 10) {
            _azureInvalid('Azure Blob supports at most 10 index tags.');
          }
          final body = _azureXml('Tags', [
            XmlElement(XmlName('TagSet'), [], [
              for (final entry in tags.entries)
                XmlElement(XmlName('Tag'), [], [
                  _azureTextNode('Key', entry.key),
                  _azureTextNode('Value', entry.value)
                ])
            ])
          ]);
          await http.request('PUT', bucket,
              key: _azureKey(key),
              query: {...query, 'comp': 'tags'},
              body: body,
              headers: {
                'content-type': 'application/xml',
                if (arguments['expectedETag'] != null)
                  'if-match': '${arguments['expectedETag']}'
              });
        }
        final root = (await http.request('GET', bucket,
                key: _azureKey(key), query: {...query, 'comp': 'tags'}))
            .xml;
        return {
          'tags': {
            for (final item in root.descendants
                .whereType<XmlElement>()
                .where((item) => item.name.local == 'Tag'))
              xmlText(item, 'Key'): xmlText(item, 'Value')
          }
        };
      case 'objectProperties':
        return _azureSetProperties(
            http, bucket, _azureKey(key), query, arguments);
      case 'getObjectProtection':
      case 'setObjectProtection':
        return _azureProtection(http, bucket, _azureKey(key), query, arguments,
            write: action.startsWith('set'));
      case 'restoreObject':
        final tier =
            '${arguments['storageClass'] ?? arguments['targetTier'] ?? 'Hot'}';
        if (!{'Hot', 'Cool', 'Cold'}.contains(tier)) {
          _azureInvalid('Choose Hot, Cool, or Cold as the rehydration target.');
        }
        final priority = '${arguments['rehydratePriority'] ?? 'Standard'}';
        if (!{'Standard', 'High'}.contains(priority)) {
          _azureInvalid('Choose Standard or High rehydration priority.');
        }
        await http.request('PUT', bucket, key: _azureKey(key), query: {
          ...query,
          'comp': 'tier'
        }, headers: {
          'x-ms-access-tier': tier,
          'x-ms-rehydrate-priority': priority
        });
        return {
          'requested': true,
          'storageClass': tier,
          'rehydratePriority': priority
        };
      case 'presignVersion':
      case 'generatePresignedUrl':
        return mobileAzurePresign(http, bucket, _azureKey(key),
            versionId: version,
            expiresSeconds: ((arguments['expiresSeconds'] ??
                        arguments['expirationSeconds']) as num?)
                    ?.toInt() ??
                900);
      case 'getAccess':
        return _azureGetAccess(http, bucket);
      case 'putAccess':
      case 'setBucketPolicy':
      case 'putBucketPolicy':
      case 'deleteBucketPolicy':
        return _azureSetAccess(http, bucket, arguments,
            clear: action == 'deleteBucketPolicy');
      case 'getBucketAdminState':
        return _azureBucketAdmin(http, bucket);
      case 'getBucketProtection':
        final head =
            await http.request('HEAD', bucket, query: {'restype': 'container'});
        return {
          'configuration': {
            'hasImmutabilityPolicy':
                head.headers['x-ms-has-immutability-policy'] == 'true',
            'hasLegalHold': head.headers['x-ms-has-legal-hold'] == 'true'
          },
          'scope': 'container',
          'message':
              'Policy details and changes require Azure Resource Manager access.'
        };
      case 'setContainerMetadata':
        await http.request('PUT', bucket, query: {
          'restype': 'container',
          'comp': 'metadata'
        }, headers: {
          ..._azureMetadata(arguments['metadata']),
          if (arguments['expectedETag'] != null)
            'if-match': '${arguments['expectedETag']}'
        });
        return {'applied': true};
      case 'setAccountCors':
      case 'setBucketCors':
      case 'putBucketCors':
      case 'deleteBucketCors':
        if (arguments['confirmAccountScope'] != true) {
          _azureInvalid(
              'Azure CORS affects every container in the account. Explicit account-scope confirmation is required.');
        }
        return _azureSetCors(http, arguments,
            clear: action == 'deleteBucketCors');
      case 'setBucketTags':
      case 'putBucketTags':
      case 'deleteBucketTags':
      case 'putBucketTagging':
      case 'deleteBucketTagging':
        _azureUnsupported(
            'Azure containers have metadata, not S3 bucket tags. Account resource tags require Azure Resource Manager; use setContainerMetadata for explicit metadata changes.');
      case 'setBucketVersioning':
      case 'setBucketLifecycle':
      case 'putLifecycle':
      case 'putBucketLifecycle':
      case 'deleteBucketLifecycle':
      case 'setBucketProtection':
      case 'setContainerProtection':
      case 'putBucketEncryption':
      case 'deleteBucketEncryption':
        _azureUnsupported(
            'Azure account lifecycle, versioning, encryption and container protection changes require Azure Resource Manager authentication, unavailable with mobile account-key/SAS profiles.');
    }
    _azureUnsupported('Azure mobile action $action is unavailable.');
  }
}

Map<String, Object?> mobileAzurePresign(
    StorageHttpClient http, String bucket, String key,
    {String? versionId, int expiresSeconds = 900, DateTime? now}) {
  final profile = http.profile;
  if (profile.connection.authMode != 'static') {
    _azureUnsupported(
        'An existing SAS cannot mint a narrower object or version grant. Use an account-key profile to create a scoped sharing URL.');
  }
  final instant = (now ?? DateTime.now()).toUtc();
  final seconds = expiresSeconds.clamp(1, 604800);
  String format(DateTime time) => '${time.toIso8601String().split('.').first}Z';
  final target = http.uri(bucket, key);
  final query = <String, String>{
    'sp': 'r',
    'st': format(instant.subtract(const Duration(minutes: 5))),
    'se': format(instant.add(Duration(seconds: seconds))),
    'spr': target.scheme == 'https' ? 'https' : 'https,http',
    'sv': '2021-12-02',
    'sr': versionId?.isNotEmpty == true ? 'bv' : 'b'
  };
  final fields = [
    query['sp'],
    query['st'],
    query['se'],
    '/blob/${profile.accessKey}/$bucket/$key',
    '',
    '',
    query['spr'],
    query['sv'],
    query['sr'],
    versionId ?? '',
    '',
    '',
    '',
    '',
    '',
    ''
  ];
  try {
    final accountKey = base64Decode(profile.secretKey);
    if (profile.accessKey.isEmpty || accountKey.isEmpty) {
      _azureInvalid('Complete the Azure account name and key before sharing.');
    }
    query['sig'] = base64Encode(
        Hmac(sha256, accountKey).convert(utf8.encode(fields.join('\n'))).bytes);
  } on FormatException {
    _azureInvalid('The Azure account key is not valid base64.');
  }
  if (versionId?.isNotEmpty == true) query['versionid'] = versionId!;
  return {
    'url': http.uri(bucket, key, query).toString(),
    'expiresAt': query['se'],
    'expiresSeconds': seconds,
    'versionId': versionId
  };
}

Future<Map<String, Object?>> _azureDetails(StorageHttpClient http,
    String bucket, String key, Map<String, String> query) async {
  final response = await http.request('HEAD', bucket, key: key, query: query);
  final headers = response.headers;
  return {
    'key': key,
    'size': int.tryParse(headers['content-length'] ?? '') ?? 0,
    'etag': headers['etag'] ?? '',
    'contentType': headers['content-type'] ?? 'application/octet-stream',
    'modifiedAt': MobileStorageAdmin._date(headers['last-modified']),
    'versionId': headers['x-ms-version-id'] ?? query['versionid'],
    'storageClass': headers['x-ms-access-tier'] ?? 'Hot',
    'encryption': headers['x-ms-server-encrypted'],
    'metadata': {
      for (final entry in headers.entries)
        if (entry.key.startsWith('x-ms-meta-'))
          entry.key.substring(10): entry.value
    },
    'headers': {
      for (final entry in MobileStorageAdmin.contentHeaders.entries)
        if (headers[entry.value] != null) entry.key: headers[entry.value]
    },
    'rawHeaders': headers,
    'archiveStatus': headers['x-ms-archive-status'],
    'rehydratePriority': headers['x-ms-rehydrate-priority']
  };
}

Future<Map<String, Object?>> _azureSetProperties(
    StorageHttpClient http,
    String bucket,
    String key,
    Map<String, String> query,
    Map<String, Object?> arguments) async {
  if (arguments['encryption'] != null &&
      (arguments['encryption'] is! Map ||
          (arguments['encryption'] as Map).isNotEmpty)) {
    _azureUnsupported('Azure encryption changes require account management.');
  }
  final head = await http.request('HEAD', bucket, key: key, query: query);
  var etag = head.headers['etag'];
  if (etag == null || etag.isEmpty) {
    _azureUnsupported(
        'Azure omitted the object ETag; properties cannot be safely updated.');
  }
  if (arguments['expectedETag'] != null && arguments['expectedETag'] != etag) {
    MobileStorageAdmin._conflict(
        'Object properties changed. Refresh before saving.');
  }
  final metadata = arguments.containsKey('metadata')
      ? _azureMetadata(arguments['metadata'])
      : null;
  final changedHeaders = arguments.containsKey('headers')
      ? _azureStringMap(arguments['headers'], 'headers')
      : null;
  const allowed = {
    'content-type',
    'cache-control',
    'content-disposition',
    'content-encoding',
    'content-language',
    'content-md5'
  };
  if (changedHeaders != null &&
      changedHeaders.keys
          .any((name) => !allowed.contains(name.toLowerCase()))) {
    _azureInvalid('An unsupported Azure content property was supplied.');
  }
  final tier = arguments['storageClass'] as String?;
  if (tier != null && !{'Hot', 'Cool', 'Cold', 'Archive'}.contains(tier)) {
    _azureInvalid('Choose a supported Azure access tier.');
  }
  Future<void> write(String comp, Map<String, String> headers) async {
    final result = await http.request('PUT', bucket,
        key: key,
        query: {...query, 'comp': comp},
        headers: {'if-match': etag!, ...headers});
    etag = result.headers['etag'] ?? etag;
  }

  if (metadata != null) await write('metadata', metadata);
  if (changedHeaders != null) {
    final merged = {
      for (final name in allowed)
        if (head.headers[name] != null) name: head.headers[name]!,
      for (final entry in changedHeaders.entries)
        entry.key.toLowerCase(): entry.value
    };
    await write('properties', {
      for (final entry in merged.entries) 'x-ms-blob-${entry.key}': entry.value
    });
  }
  if (tier != null) await write('tier', {'x-ms-access-tier': tier});
  return {'applied': true, 'etag': etag, 'versionId': query['versionid']};
}

Future<Map<String, Object?>> _azureProtection(
    StorageHttpClient http,
    String bucket,
    String key,
    Map<String, String> query,
    Map<String, Object?> arguments,
    {required bool write}) async {
  final condition = <String, String>{
    if (arguments['expectedETag'] != null)
      'if-match': '${arguments['expectedETag']}'
  };
  final retention = arguments['retention'] as Map?;
  String? until, mode;
  if (write && retention != null) {
    final raw =
        '${retention['RetainUntilDate'] ?? retention['untilDate'] ?? ''}';
    final date = DateTime.tryParse(raw);
    if (!RegExp(r'(Z|[+-]\d\d:\d\d)$').hasMatch(raw) ||
        date == null ||
        !date.isAfter(DateTime.now())) {
      _azureInvalid('Retention requires a future timezone-qualified date.');
    }
    until = HttpDate.format(date.toUtc());
    final supplied = '${retention['Mode'] ?? retention['mode'] ?? 'Unlocked'}';
    mode = {
          'GOVERNANCE': 'Unlocked',
          'COMPLIANCE': 'Locked',
          'unlocked': 'Unlocked',
          'locked': 'Locked'
        }[supplied] ??
        supplied;
    if (!{'Unlocked', 'Locked'}.contains(mode)) {
      _azureInvalid('Azure retention mode must be Unlocked or Locked.');
    }
  }
  var hold = arguments['legalHold'];
  if (hold is Map) {
    if (!{'ON', 'OFF'}.contains(hold['Status'])) {
      _azureInvalid('Legal hold status must be ON or OFF.');
    }
    hold = hold['Status'] == 'ON';
  }
  if (write && arguments.containsKey('legalHold') && hold is! bool) {
    _azureInvalid('Legal hold must be true or false.');
  }
  if (write && retention != null) {
    final response = await http.request('PUT', bucket, key: key, query: {
      ...query,
      'comp': 'immutabilityPolicies'
    }, headers: {
      ...condition,
      'x-ms-immutability-policy-until-date': until!,
      'x-ms-immutability-policy-mode': mode!
    });
    if (response.headers['etag'] != null && condition.isNotEmpty) {
      condition['if-match'] = response.headers['etag']!;
    }
  }
  if (write && hold is bool) {
    await http.request('PUT', bucket,
        key: key,
        query: {...query, 'comp': 'legalhold'},
        headers: {...condition, 'x-ms-legal-hold': '$hold'});
  }
  final response = await http.request('HEAD', bucket, key: key, query: query);
  return {
    'retention': {
      'Mode': response.headers['x-ms-immutability-policy-mode'],
      'RetainUntilDate': response.headers['x-ms-immutability-policy-until-date']
    },
    'legalHold': {
      'Status': response.headers['x-ms-legal-hold'] == null
          ? null
          : response.headers['x-ms-legal-hold'] == 'true'
              ? 'ON'
              : 'OFF'
    },
    'versionId': response.headers['x-ms-version-id'] ?? query['versionid'],
    'etag': response.headers['etag']
  };
}

Future<Map<String, Object?>> _azureGetAccess(
    StorageHttpClient http, String bucket) async {
  final response = await http
      .request('GET', bucket, query: {'restype': 'container', 'comp': 'acl'});
  final policies = [
    for (final item in response.xml.childElements
        .where((node) => node.name.local == 'SignedIdentifier'))
      {
        'id': xmlText(item, 'Id'),
        'accessPolicy': {
          for (final field in ['Start', 'Expiry', 'Permission'])
            field.toLowerCase():
                xmlText(_azureChild(item, 'AccessPolicy') ?? item, field)
        }
      }
  ];
  final policy = {
    'publicAccess': response.headers['x-ms-blob-public-access'] ?? 'private',
    'signedIdentifiers': policies
  };
  return {
    'policyJson': jsonEncode(policy),
    ...policy,
    'acl': policy['publicAccess'],
    'etag': response.headers['etag'],
    'lastModified': response.headers['last-modified'],
    'sections': [
      {'section': 'GetContainerACL', 'state': 'supported'}
    ]
  };
}

Future<Map<String, Object?>> _azureSetAccess(
    StorageHttpClient http, String bucket, Map<String, Object?> arguments,
    {required bool clear}) async {
  final current = await _azureGetAccess(http, bucket);
  if (arguments['expectedPolicyJson'] != null &&
      !MobileStorageAdmin._sameJson(
          jsonDecode('${arguments['expectedPolicyJson']}'),
          jsonDecode('${current['policyJson']}'))) {
    MobileStorageAdmin._conflict(
        'Container access settings changed. Refresh before saving.');
  }
  final supplied = arguments['policyJson'] == null
      ? <String, Object?>{}
      : Map<String, Object?>.from(
          jsonDecode('${arguments['policyJson']}') as Map);
  if (supplied.keys
      .any((name) => !{'publicAccess', 'signedIdentifiers'}.contains(name))) {
    _azureInvalid(
        'Azure access settings accept publicAccess and signedIdentifiers; S3 bucket policy JSON is not supported.');
  }
  final acl = arguments['acl'];
  final access = clear
      ? 'private'
      : supplied['publicAccess'] ??
          arguments['publicAccess'] ??
          (acl == 'public-read' ? 'blob' : acl) ??
          current['publicAccess'];
  if (!{'private', 'blob', 'container'}.contains(access)) {
    _azureInvalid('Azure access must be private, blob, or container.');
  }
  final policies =
      (supplied['signedIdentifiers'] ?? current['signedIdentifiers']) as List;
  if (policies.length > 5) {
    _azureInvalid(
        'Azure supports at most five stored container access policies.');
  }
  final nodes = <XmlElement>[];
  for (final item in policies) {
    if (item is! Map ||
        item['id'] is! String ||
        (item['id'] as String).isEmpty ||
        item['accessPolicy'] is! Map) {
      _azureInvalid('Each stored policy needs an id and accessPolicy.');
    }
    final policy = item['accessPolicy'] as Map;
    nodes.add(XmlElement(XmlName('SignedIdentifier'), [], [
      _azureTextNode('Id', '${item['id']}'),
      XmlElement(XmlName('AccessPolicy'), [], [
        for (final field in ['Start', 'Expiry', 'Permission'])
          if (policy[field.toLowerCase()] != null &&
              '${policy[field.toLowerCase()]}'.isNotEmpty)
            _azureTextNode(field, '${policy[field.toLowerCase()]}')
      ])
    ]));
  }
  await http.request('PUT', bucket,
      query: {'restype': 'container', 'comp': 'acl'},
      body: _azureXml('SignedIdentifiers', nodes),
      headers: {
        'content-type': 'application/xml',
        if (access != 'private') 'x-ms-blob-public-access': '$access',
        if (current['lastModified'] != null)
          'if-unmodified-since': '${current['lastModified']}',
      });
  return {'applied': true};
}

Future<Map<String, Object?>> _azureBucketAdmin(
    StorageHttpClient http, String bucket) async {
  final sections = <Map<String, Object?>>[];
  Map<String, Object?> access = {};
  Map<String, String> headers = {};
  Future<void> inspect(String section, Future<void> Function() read) async {
    try {
      await read();
      sections.add({'section': section, 'state': 'supported'});
    } on StorageHttpException catch (error) {
      sections.add({
        'section': section,
        'state': error.response.status == 403
            ? 'denied'
            : error.response.status == 404
                ? 'missing'
                : error.response.status == 501
                    ? 'unsupported'
                    : 'unknown',
        'message': error.message
      });
    }
  }

  await inspect('GetContainerACL', () async {
    access = await _azureGetAccess(http, bucket);
  });
  await inspect('GetContainerProperties', () async {
    headers =
        (await http.request('HEAD', bucket, query: {'restype': 'container'}))
            .headers;
  });
  for (final operation in [
    'GetBucketVersioning',
    'GetBucketLifecycleConfiguration',
    'GetBucketEncryption',
    'GetBucketTagging',
    'GetBucketCors'
  ]) {
    sections.add({
      'section': operation,
      'state': 'unsupported',
      'message':
          'This S3 container setting has no equivalent container-scoped Azure API.'
    });
  }
  return {
    'bucketName': bucket,
    'versioningEnabled': false,
    'versioningStatus': 'Unknown',
    'objectLockEnabled': headers['x-ms-has-immutability-policy'] == 'true',
    'lifecycleEnabled': false,
    'policyAttached':
        access['publicAccess'] != null && access['publicAccess'] != 'private',
    'policyJson': access['policyJson'] ?? '{}',
    'lifecycleJson': '{}',
    'corsJson': '[]',
    'encryptionJson': '{}',
    'metadata': {
      for (final entry in headers.entries)
        if (entry.key.startsWith('x-ms-meta-'))
          entry.key.substring(10): entry.value
    },
    'tags': <String, String>{},
    'apiCalls': sections,
    'sections': sections,
    'sectionStatuses': {
      for (final section in sections)
        '${section['section']}': {
          'state': section['state'],
          'message': section['message'] ?? ''
        }
    }
  };
}

Future<Map<String, Object?>> _azureSetCors(
    StorageHttpClient http, Map<String, Object?> arguments,
    {required bool clear}) async {
  final decoded = clear ? [] : jsonDecode('${arguments['corsJson'] ?? '[]'}');
  if (decoded is! List || decoded.length > 5) {
    _azureInvalid('Azure CORS expects at most five rules.');
  }
  final rules = <XmlElement>[];
  for (final rule in decoded) {
    if (rule is! Map) _azureInvalid('A CORS rule must be an object.');
    const fields = [
      'AllowedOrigins',
      'AllowedMethods',
      'AllowedHeaders',
      'ExposedHeaders',
      'MaxAgeInSeconds'
    ];
    if (rule.keys.any((key) => !fields.contains(key))) {
      _azureInvalid(
          'Azure CORS rules require Azure service-properties field names.');
    }
    rules.add(XmlElement(XmlName('CorsRule'), [], [
      for (final field in fields)
        _azureTextNode(
            field,
            rule[field] is List
                ? (rule[field] as List).join(',')
                : '${rule[field] ?? (field == 'MaxAgeInSeconds' ? 0 : '')}')
    ]));
  }
  final current = (await http.request('GET', '',
          query: {'restype': 'service', 'comp': 'properties'}))
      .xml;
  final elements = <XmlNode>[
    for (final node in current.childElements)
      if (node.name.local != 'Cors') node.copy(),
    XmlElement(XmlName('Cors'), [], rules)
  ];
  await http.request('PUT', '',
      query: {'restype': 'service', 'comp': 'properties'},
      body: _azureXml('StorageServiceProperties', elements),
      headers: {'content-type': 'application/xml'});
  return {'applied': true, 'scope': 'account'};
}

Map<String, Object?> _azureBucketRow(String name, EndpointProfile profile,
        {String? modified}) =>
    {
      'name': name,
      'region': profile.region,
      'objectCountHint': 0,
      'versioningEnabled': false,
      'createdAt': modified == null ? null : MobileStorageAdmin._date(modified),
    };
Map<String, Object?> _azureCursor(String marker) =>
    {'hasMore': marker.isNotEmpty, 'value': marker.isEmpty ? null : marker};
String? _azureMarker(Map<String, Object?> args) =>
    ((args['cursor'] as Map?)?['value'] ?? args['marker']) as String?;
XmlElement? _azureChild(XmlElement element, String name) =>
    element.childElements.where((node) => node.name.local == name).firstOrNull;
XmlElement _azureTextNode(String name, String value) =>
    XmlElement(XmlName(name), [], [XmlText(value)]);
List<int> _azureXml(String root, List<XmlNode> children) => utf8.encode(
    XmlDocument([XmlElement(XmlName(root), [], children)]).toXmlString());
Map<String, String> _azureStringMap(Object? value, String label) {
  if (value is! Map ||
      value.entries
          .any((entry) => entry.key is! String || entry.value is! String)) {
    _azureInvalid('$label must map strings to strings.');
  }
  return Map<String, String>.from(value);
}

Map<String, String> _azureMetadata(Object? value) {
  final metadata = _azureStringMap(value, 'metadata');
  if (metadata.keys
          .any((key) => !RegExp(r'^[A-Za-z_][A-Za-z0-9_]*$').hasMatch(key)) ||
      metadata.values
          .any((value) => value.contains('\r') || value.contains('\n'))) {
    _azureInvalid(
        'Azure metadata names must be identifiers and values must be single-line strings.');
  }
  return {
    for (final entry in metadata.entries) 'x-ms-meta-${entry.key}': entry.value
  };
}

String _azureKey(String? key) {
  if (key == null || key.isEmpty) {
    _azureInvalid('An exact blob key is required.');
  }
  return key;
}

Never _azureInvalid(String message) =>
    throw EngineException(code: ErrorCode.invalidConfig, message: message);
Never _azureUnsupported(String message) =>
    throw EngineException(code: ErrorCode.unsupportedFeature, message: message);
