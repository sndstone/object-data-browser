/// How a vault rule protects object names.
///
/// * [standard] is the default: one vault key, and names are either left as
///   they are or, with [ClientEncryptionRule.encryptNames], encrypted
///   deterministically per path segment so folders keep working.
/// * [strict] gives every upload its own random name key. Names carry no
///   folder structure and the same name never encrypts the same way twice.
/// * [unsupported] is a value written by a newer app. Uploads under such a
///   rule are refused; it is never downgraded to another policy.
enum ClientEncryptionPolicy { standard, strict, unsupported }

/// Public vault routing metadata. No identity or per-file key belongs here.
class ClientEncryptionRule {
  const ClientEncryptionRule({
    required this.bucket,
    this.prefix = '',
    required this.keyId,
    required this.recipient,
    required this.label,
    this.policy = ClientEncryptionPolicy.standard,
    this.encryptNames = false,
    this.unsupportedPolicy,
  });
  final String bucket, prefix, keyId, recipient, label;
  final ClientEncryptionPolicy policy;

  /// Encrypt file and folder names under the standard policy. The strict
  /// policy always encrypts names, whatever this says.
  final bool encryptNames;

  /// The raw policy string when [policy] is [ClientEncryptionPolicy.unsupported],
  /// kept so saving the profile does not lose it.
  final String? unsupportedPolicy;

  /// Whether new uploads under this rule get encrypted names.
  bool get encryptsNames =>
      policy == ClientEncryptionPolicy.strict ||
      (policy == ClientEncryptionPolicy.standard && encryptNames);

  /// Whether new uploads get a random, structure-free name (strict policy).
  bool get randomNames => policy == ClientEncryptionPolicy.strict;

  bool matches(String bucketName, String key) =>
      bucket == bucketName && key.startsWith(prefix);

  ClientEncryptionRule copyWith({
    String? bucket,
    String? prefix,
    String? keyId,
    String? recipient,
    String? label,
    ClientEncryptionPolicy? policy,
    bool? encryptNames,
  }) {
    final nextPolicy = policy ?? this.policy;
    return ClientEncryptionRule(
      bucket: bucket ?? this.bucket,
      prefix: prefix ?? this.prefix,
      keyId: keyId ?? this.keyId,
      recipient: recipient ?? this.recipient,
      label: label ?? this.label,
      policy: nextPolicy,
      encryptNames: encryptNames ?? this.encryptNames,
      unsupportedPolicy: nextPolicy == ClientEncryptionPolicy.unsupported
          ? unsupportedPolicy
          : null,
    );
  }

  /// Defaults are omitted, so a rule without these options serialises exactly
  /// as it did before they existed.
  Map<String, Object?> toJson() => {
        'bucket': bucket,
        'prefix': prefix,
        'keyId': keyId,
        'recipient': recipient,
        'label': label,
        if (policy == ClientEncryptionPolicy.strict) 'policy': 'strict',
        if (policy == ClientEncryptionPolicy.unsupported &&
            unsupportedPolicy != null)
          'policy': unsupportedPolicy,
        if (encryptNames) 'encryptNames': true,
      };
  factory ClientEncryptionRule.fromJson(Map<String, Object?> json) {
    final rawPolicy = json['policy'];
    final policy = switch (rawPolicy) {
      null || 'default' => ClientEncryptionPolicy.standard,
      'strict' => ClientEncryptionPolicy.strict,
      _ => ClientEncryptionPolicy.unsupported,
    };
    return ClientEncryptionRule(
      bucket: json['bucket'] as String,
      prefix: json['prefix'] as String? ?? '',
      keyId: json['keyId'] as String,
      recipient: json['recipient'] as String,
      label: json['label'] as String,
      policy: policy,
      encryptNames: json['encryptNames'] == true,
      unsupportedPolicy: policy == ClientEncryptionPolicy.unsupported
          ? rawPolicy.toString()
          : null,
    );
  }
  @override
  bool operator ==(Object other) =>
      other is ClientEncryptionRule &&
      bucket == other.bucket &&
      prefix == other.prefix &&
      keyId == other.keyId &&
      recipient == other.recipient &&
      label == other.label &&
      policy == other.policy &&
      encryptNames == other.encryptNames &&
      unsupportedPolicy == other.unsupportedPolicy;
  @override
  int get hashCode => Object.hash(bucket, prefix, keyId, recipient, label,
      policy, encryptNames, unsupportedPolicy);
}

ClientEncryptionRule? matchingClientEncryptionRule(
  List<ClientEncryptionRule> rules,
  String bucket,
  String key,
) {
  ClientEncryptionRule? result;
  for (final rule in rules) {
    if (rule.matches(bucket, key) &&
        (result == null || rule.prefix.length > result.prefix.length)) {
      result = rule;
    }
  }
  return result;
}

const clientEncryptionUnavailable =
    'Client-side encryption requires a supported desktop engine. You can download an encrypted copy on this device.';

String clientEncryptionVisibleKey(String key) =>
    key.endsWith('.age') && key.split('/').last.length > 4
        ? key.substring(0, key.length - 4)
        : key;
