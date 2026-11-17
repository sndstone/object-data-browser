import 'dart:convert';

/// Form projection of S3's default encryption document. Unknown members are
/// retained, never reconstructed from just the visible controls.
class BucketEncryptionConfig {
  BucketEncryptionConfig._(this._document, this.mode, this.kmsKeyId,
      this.bucketKeyEnabled, this.notice);

  final Map<String, dynamic> _document;
  final String mode;
  final String kmsKeyId;
  final bool? bucketKeyEnabled;
  final String? notice;
  bool get canEdit => notice == null;
  bool get hasRule => (_document['Rules'] as List?)?.isNotEmpty == true;

  factory BucketEncryptionConfig.parse(String source) {
    const unsafe =
        'This configuration cannot be safely represented by the form. Use Edit as JSON to preserve all rules and fields.';
    try {
      final decoded = jsonDecode(source);
      if (decoded is! Map<String, dynamic>) throw const FormatException();
      var document = decoded;
      if (decoded.containsKey('ServerSideEncryptionConfiguration')) {
        if (decoded.length != 1 ||
            decoded['ServerSideEncryptionConfiguration']
                is! Map<String, dynamic>) {
          return BucketEncryptionConfig._({}, '', '', null, unsafe);
        }
        document = decoded['ServerSideEncryptionConfiguration']
            as Map<String, dynamic>;
      }
      final rawRules = document['Rules'];
      if (rawRules != null && rawRules is! List) throw const FormatException();
      final rules = rawRules as List?;
      if (rules == null || rules.isEmpty) {
        return BucketEncryptionConfig._(document, '', '', null, null);
      }
      if (rules.length != 1 || rules.single is! Map) {
        return BucketEncryptionConfig._(document, '', '', null, unsafe);
      }
      final rule = rules.single as Map;
      final defaults = rule['ApplyServerSideEncryptionByDefault'];
      if (defaults is! Map ||
          !const ['AES256', 'aws:kms', 'aws:kms:dsse']
              .contains(defaults['SSEAlgorithm']) ||
          (defaults['KMSMasterKeyID'] != null &&
              defaults['KMSMasterKeyID'] is! String) ||
          (rule['BucketKeyEnabled'] != null &&
              rule['BucketKeyEnabled'] is! bool)) {
        return BucketEncryptionConfig._(document, '', '', null, unsafe);
      }
      return BucketEncryptionConfig._(
          document,
          defaults['SSEAlgorithm'] as String,
          defaults['KMSMasterKeyID'] as String? ?? '',
          rule['BucketKeyEnabled'] as bool?,
          null);
    } on FormatException {
      return BucketEncryptionConfig._({}, '', '', null, unsafe);
    }
  }

  /// Produces the top-level Rules shape accepted by all engine PUT paths.
  /// Provider default uses DELETE, never an empty PUT.
  String encode(
      {required String mode,
      required String kmsKeyId,
      required bool? bucketKeyEnabled}) {
    if (!canEdit || mode.isEmpty) {
      throw StateError('Use JSON or delete the explicit rule.');
    }
    final result = jsonDecode(jsonEncode(_document)) as Map<String, dynamic>;
    final oldRules = result['Rules'] as List? ?? [];
    final rule = oldRules.isEmpty
        ? <String, dynamic>{}
        : Map<String, dynamic>.from(oldRules.single as Map);
    final defaults = Map<String, dynamic>.from(
        rule['ApplyServerSideEncryptionByDefault'] as Map? ?? {});
    defaults['SSEAlgorithm'] = mode;
    // An unchanged form preserves even unusual known-field combinations.
    if (mode != this.mode || kmsKeyId != this.kmsKeyId) {
      defaults.remove('KMSMasterKeyID');
      if (mode != 'AES256' && kmsKeyId.trim().isNotEmpty) {
        defaults['KMSMasterKeyID'] = kmsKeyId.trim();
      }
    }
    if (mode != this.mode || bucketKeyEnabled != this.bucketKeyEnabled) {
      rule.remove('BucketKeyEnabled');
      if (mode == 'aws:kms' && bucketKeyEnabled != null) {
        rule['BucketKeyEnabled'] = bucketKeyEnabled;
      }
    }
    rule['ApplyServerSideEncryptionByDefault'] = defaults;
    result['Rules'] = [rule];
    return const JsonEncoder.withIndent('  ').convert(result);
  }
}
