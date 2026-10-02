import 'dart:convert';
import 'domain_models.dart';

/// Presets own only statements/rules with the ObjectBrowser prefix. Existing
/// custom configuration is round-tripped without rebuilding SDK projections.
class StoragePresets {
  static const encoder = JsonEncoder.withIndent('  ');
  static const accessLabels = {
    'private': 'Remove preset access grants',
    'read': 'Read access for a principal',
    'readWrite': 'Read and write, without delete',
    'readWriteDelete': 'Read, write and delete for a principal',
    'publicRead': 'Public read for objects',
    'tls': 'Require HTTPS',
  };
  static const lifecycleLabels = {
    'tier': 'Infrequent access after 30 days; archive after 90',
    'intelligent': 'Intelligent-Tiering from day 0',
    'archive': 'Archive after 90 days',
    'infrequent': 'Infrequent access after 30 days',
    'deepArchive': 'Deep Archive after 180 days',
    'custom': 'Transition to an endpoint storage class',
    'multipart': 'Remove incomplete uploads after 7 days',
    'history': 'Expire old versions after 90 days; retain 5',
  };

  static String partition(EndpointProfile profile) {
    final host = Uri.tryParse(profile.endpointUrl)?.host ?? '';
    if (profile.region.startsWith('cn-') ||
        host.endsWith('.amazonaws.com.cn')) {
      return 'aws-cn';
    }
    return profile.region.startsWith('us-gov-') ? 'aws-us-gov' : 'aws';
  }

  static Map<String, dynamic> document(String raw, String member) {
    final value = raw.trim().isEmpty ? <String, dynamic>{} : jsonDecode(raw);
    if (value is! Map<String, dynamic>) {
      throw const FormatException('Configuration must be a JSON object.');
    }
    final items = value[member];
    if (items != null &&
        items is! List &&
        !(member == 'Statement' && items is Map)) {
      throw FormatException('$member must be a list.');
    }
    return value;
  }

  static String access(
      {required EndpointProfile profile,
      required String bucket,
      required String preset,
      String principal = '',
      String prefix = '',
      String existing = '{}'}) {
    if (bucket.isEmpty || bucket.contains('*') || bucket.contains('?')) {
      throw const FormatException('A literal bucket name is required.');
    }
    if (prefix.contains('*') || prefix.contains('?') || bucket.contains('/')) {
      throw const FormatException(
          'This policy preset requires a literal bucket and prefix without wildcard characters.');
    }
    final doc = document(existing, 'Statement');
    final old = doc['Statement'];
    final statements = <dynamic>[
      if (old is Map) old else if (old is List) ...old,
    ];
    if (!accessLabels.containsKey(preset)) {
      throw const FormatException('Unknown access preset.');
    }
    final sid =
        preset == 'tls' ? 'ObjectBrowserRequireTLS' : 'ObjectBrowserAccess';
    statements.removeWhere((s) => s is Map && s['Sid'] == sid);
    final arn = 'arn:${partition(profile)}:s3:::$bucket';
    final scoped = prefix.isEmpty ? '*' : '$prefix*';
    if (preset == 'tls') {
      statements.add({
        'Sid': sid,
        'Effect': 'Deny',
        'Principal': '*',
        'Action': 's3:*',
        'Resource': [arn, '$arn/*'],
        'Condition': {
          'Bool': {
            'aws:SecureTransport': 'false',
            'aws:PrincipalIsAWSService': 'false'
          }
        }
      });
    } else if (preset != 'private') {
      if (preset != 'publicRead' &&
          !RegExp(r'^arn:(aws|aws-cn|aws-us-gov):iam::\d{12}:(root|user/.+|role/.+)$')
              .hasMatch(principal.trim())) {
        throw const FormatException('Enter an IAM account, role, or user ARN.');
      }
      final who = preset == 'publicRead'
          ? '*'
          : <String, String>{'AWS': principal.trim()};
      statements.add({
        'Sid': sid,
        'Effect': 'Allow',
        'Principal': who,
        'Action': [
          's3:GetObject',
          if ({'readWrite', 'readWriteDelete'}.contains(preset)) 's3:PutObject',
          if (preset == 'readWriteDelete') 's3:DeleteObject'
        ],
        'Resource': '$arn/$scoped'
      });
      statements
          .removeWhere((s) => s is Map && s['Sid'] == 'ObjectBrowserList');
      if (preset != 'publicRead') {
        statements.add({
          'Sid': 'ObjectBrowserList',
          'Effect': 'Allow',
          'Principal': who,
          'Action': 's3:ListBucket',
          'Resource': arn,
          if (prefix.isNotEmpty)
            'Condition': {
              'StringLike': {
                's3:prefix': ['$prefix*']
              }
            }
        });
      }
    }
    if (preset == 'private') {
      statements
          .removeWhere((s) => s is Map && s['Sid'] == 'ObjectBrowserList');
    }
    return encoder.convert({
      ...doc,
      'Version': doc['Version'] ?? '2012-10-17',
      'Statement': statements
    });
  }

  static String lifecycle({
    required EndpointProfile profile,
    required String preset,
    String prefix = '',
    String existing = '{"Rules":[]}',
    String storageClass = '',
    int days = 30,
    bool versioned = false,
    bool enabled = true,
    Map<String, String> tags = const {},
    int? minimumBytes,
    int? maximumBytes,
    int? expirationDays,
    int? transitionDays,
    int? archiveDays,
    int? noncurrentDays,
    int? retainVersions,
    int? abortDays,
  }) {
    if (!lifecycleLabels.containsKey(preset)) {
      throw const FormatException('Unknown lifecycle preset.');
    }
    if (profile.endpointType == EndpointProfileType.azureBlob) {
      throw const FormatException(
          'Azure lifecycle is an account management policy.');
    }
    if (profile.endpointType != EndpointProfileType.awsS3 &&
        {'tier', 'intelligent', 'archive', 'infrequent', 'deepArchive'}
            .contains(preset)) {
      throw const FormatException(
          'Select a storage class supported by this endpoint.');
    }
    if (preset == 'history' && enabled && !versioned) {
      throw const FormatException(
          'This preset requires bucket version history.');
    }
    if (preset == 'custom' &&
        (days < 0 ||
            storageClass.trim().isEmpty ||
            !profile.connection.storageClasses.contains(storageClass))) {
      throw const FormatException(
          'Select a configured storage class and a nonnegative day count.');
    }
    if (!enabled) {
      final existingDoc = document(existing, 'Rules');
      final existingRules =
          List<dynamic>.of(existingDoc['Rules'] as List? ?? []);
      final at = existingRules
          .indexWhere((r) => r is Map && r['ID'] == 'ObjectBrowser-$preset');
      if (at >= 0) {
        existingRules[at] = {...existingRules[at] as Map, 'Status': 'Disabled'};
        return encoder.convert({...existingDoc, 'Rules': existingRules});
      }
    }
    final firstDay = transitionDays ?? (preset == 'intelligent' ? 0 : 30);
    final finalDay = archiveDays ?? (preset == 'deepArchive' ? 180 : 90);
    if (firstDay < 0 ||
        finalDay < 0 ||
        (preset == 'tier' && finalDay <= firstDay) ||
        ({'tier', 'infrequent'}.contains(preset) && firstDay < 30) ||
        (preset == 'tier' && finalDay - firstDay < 30) ||
        (noncurrentDays ?? 90) < 1 ||
        (retainVersions ?? 5) < 1 ||
        (retainVersions ?? 5) > 100 ||
        (abortDays ?? 7) < 1 ||
        (expirationDays != null && expirationDays < 1) ||
        (minimumBytes != null && minimumBytes < 0) ||
        (maximumBytes != null && maximumBytes < 1) ||
        (minimumBytes != null &&
            maximumBytes != null &&
            minimumBytes >= maximumBytes)) {
      throw const FormatException(
          'Invalid age, retained count, transition order or object-size range. Standard-IA needs at least 30 days.');
    }
    if (preset == 'multipart' &&
        (tags.isNotEmpty ||
            minimumBytes != null ||
            maximumBytes != null ||
            expirationDays != null)) {
      throw const FormatException(
          'Incomplete-upload cleanup supports a prefix filter only.');
    }
    final lastTransition = switch (preset) {
      'tier' || 'archive' || 'deepArchive' => finalDay,
      'infrequent' || 'intelligent' => firstDay,
      'custom' => days,
      _ => null,
    };
    if (expirationDays != null &&
        lastTransition != null &&
        expirationDays <= lastTransition) {
      throw const FormatException(
          'Expiration must occur after the last transition.');
    }
    if (tags.length > 10 ||
        tags.entries.any((e) =>
            e.key.isEmpty || e.key.length > 128 || e.value.length > 256)) {
      throw const FormatException(
          'Use up to ten tags with keys up to 128 characters and values up to 256 characters.');
    }
    final predicates = <String, Object?>{
      if (prefix.isNotEmpty) 'Prefix': prefix,
      if (tags.length == 1)
        'Tag': {'Key': tags.keys.first, 'Value': tags.values.first},
      if (tags.length > 1)
        'Tags':
            tags.entries.map((e) => {'Key': e.key, 'Value': e.value}).toList(),
      if (minimumBytes != null) 'ObjectSizeGreaterThan': minimumBytes,
      if (maximumBytes != null) 'ObjectSizeLessThan': maximumBytes,
    };
    final count = (prefix.isNotEmpty ? 1 : 0) +
        tags.length +
        (minimumBytes != null ? 1 : 0) +
        (maximumBytes != null ? 1 : 0);
    if (count > 1 && predicates.containsKey('Tag')) {
      predicates['Tags'] = [predicates.remove('Tag')];
    }
    final filter = count == 0
        ? {'Prefix': ''}
        : count == 1
            ? predicates
            : {'And': predicates};
    final doc = document(existing, 'Rules');
    final rules = List<dynamic>.of(doc['Rules'] as List? ?? []);
    final id = 'ObjectBrowser-$preset';
    rules.removeWhere((r) => r is Map && r['ID'] == id);
    final rule = <String, Object?>{
      'ID': id,
      'Status': enabled ? 'Enabled' : 'Disabled',
      'Filter': filter,
      if (expirationDays != null) 'Expiration': {'Days': expirationDays}
    };
    switch (preset) {
      case 'tier':
        rule['Transitions'] = [
          {'Days': firstDay, 'StorageClass': 'STANDARD_IA'},
          {'Days': finalDay, 'StorageClass': 'GLACIER'}
        ];
      case 'archive':
        rule['Transitions'] = [
          {'Days': finalDay, 'StorageClass': 'GLACIER'}
        ];
      case 'infrequent':
        rule['Transitions'] = [
          {'Days': firstDay, 'StorageClass': 'STANDARD_IA'}
        ];
      case 'deepArchive':
        rule['Transitions'] = [
          {'Days': finalDay, 'StorageClass': 'DEEP_ARCHIVE'}
        ];
      case 'intelligent':
        rule['Transitions'] = [
          {'Days': firstDay, 'StorageClass': 'INTELLIGENT_TIERING'}
        ];
      case 'custom':
        rule['Transitions'] = [
          {'Days': days, 'StorageClass': storageClass}
        ];
      case 'multipart':
        rule['AbortIncompleteMultipartUpload'] = {
          'DaysAfterInitiation': abortDays ?? 7
        };
      case 'history':
        rule['NoncurrentVersionExpiration'] = {
          'NoncurrentDays': noncurrentDays ?? 90,
          'NewerNoncurrentVersions': retainVersions ?? 5
        };
    }
    if (rules.length >= 1000) {
      throw const FormatException(
          'A lifecycle configuration supports at most 1,000 rules.');
    }
    rules.add(rule);
    return encoder.convert({...doc, 'Rules': rules});
  }
}
