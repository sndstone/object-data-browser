/// Non-secret provider encryption settings. Customer key bytes are resolved only
/// when dispatching an engine request; they never belong to this model.
enum ObjectEncryptionMode {
  bucketDefault('bucketDefault', 'Bucket default'),
  sseS3('sse-s3', 'SSE-S3'),
  sseKms('sse-kms', 'SSE-KMS'),
  dsseKms('dsse-kms', 'DSSE-KMS'),
  sseC('sse-c', 'Customer key (SSE-C)'),
  azureScope('azure-scope', 'Encryption scope'),
  azureCpk('azure-cpk', 'Customer-provided key');

  const ObjectEncryptionMode(this.wireName, this.label);
  final String wireName;
  final String label;
  bool get isCustomerKey => this == sseC || this == azureCpk;
  bool get isAzure => this == azureScope || this == azureCpk;
  static ObjectEncryptionMode parse(String value) => values.firstWhere(
        (mode) => mode.wireName == value,
        orElse: () => throw const FormatException('Unknown encryption mode.'),
      );
}

class ObjectEncryption {
  const ObjectEncryption({
    required this.mode,
    this.kmsKeyId,
    this.kmsEncryptionContext,
    this.bucketKeyEnabled,
    this.encryptionScope,
    this.customerKeyId,
    this.customerKeyFingerprint,
  });
  final ObjectEncryptionMode mode;
  final String? kmsKeyId;
  final Map<String, String>? kmsEncryptionContext;
  final bool? bucketKeyEnabled;
  final String? encryptionScope;
  final String? customerKeyId;
  final String? customerKeyFingerprint;

  Map<String, Object?> toJson() => {
        'mode': mode.wireName,
        if (kmsKeyId != null) 'kmsKeyId': kmsKeyId,
        if (kmsEncryptionContext != null)
          'kmsEncryptionContext': kmsEncryptionContext,
        if (bucketKeyEnabled != null) 'bucketKeyEnabled': bucketKeyEnabled,
        if (encryptionScope != null) 'encryptionScope': encryptionScope,
        if (customerKeyId != null) 'customerKeyId': customerKeyId,
        if (customerKeyFingerprint != null)
          'customerKeyFingerprint': customerKeyFingerprint,
      };

  @override
  bool operator ==(Object other) =>
      other is ObjectEncryption &&
      mode == other.mode &&
      kmsKeyId == other.kmsKeyId &&
      bucketKeyEnabled == other.bucketKeyEnabled &&
      encryptionScope == other.encryptionScope &&
      customerKeyId == other.customerKeyId &&
      customerKeyFingerprint == other.customerKeyFingerprint &&
      ((kmsEncryptionContext == null && other.kmsEncryptionContext == null) ||
          (kmsEncryptionContext != null &&
              other.kmsEncryptionContext != null &&
              kmsEncryptionContext!.length ==
                  other.kmsEncryptionContext!.length &&
              kmsEncryptionContext!.entries.every((entry) =>
                  other.kmsEncryptionContext![entry.key] == entry.value)));
  @override
  int get hashCode {
    final contextKeys = kmsEncryptionContext?.keys.toList();
    contextKeys?.sort();
    return Object.hash(
        mode,
        kmsKeyId,
        bucketKeyEnabled,
        encryptionScope,
        customerKeyId,
        customerKeyFingerprint,
        contextKeys == null
            ? null
            : Object.hashAll(contextKeys
                .map((key) => Object.hash(key, kmsEncryptionContext![key]))));
  }

  factory ObjectEncryption.fromJson(Map<String, Object?> json) =>
      ObjectEncryption(
        mode: ObjectEncryptionMode.parse(json['mode'] as String),
        kmsKeyId: json['kmsKeyId'] as String?,
        kmsEncryptionContext: json['kmsEncryptionContext'] == null
            ? null
            : Map<String, String>.from(json['kmsEncryptionContext'] as Map),
        bucketKeyEnabled: json['bucketKeyEnabled'] as bool?,
        encryptionScope: json['encryptionScope'] as String?,
        customerKeyId: json['customerKeyId'] as String?,
        customerKeyFingerprint: json['customerKeyFingerprint'] as String?,
      );
}

/// Provider-reported encryption metadata, containing no key material.
class ObjectEncryptionInfo {
  const ObjectEncryptionInfo({
    required this.mode,
    this.kmsKeyId,
    this.bucketKeyEnabled,
    this.customerKeyMd5,
    this.customerKeySha256,
    this.encryptionScope,
    this.serverEncrypted,
  });
  final String mode;
  final String? kmsKeyId;
  final bool? bucketKeyEnabled;
  final String? customerKeyMd5;
  final String? customerKeySha256;
  final String? encryptionScope;
  final bool? serverEncrypted;

  /// The mode as the rest of the app names it, for display.
  String get modeLabel => switch (mode) {
        'provider' => 'Provider managed',
        _ => ObjectEncryptionMode.values
                .where((value) => value.wireName == mode)
                .firstOrNull
                ?.label ??
            mode,
      };
  bool get isCustomerKey => mode == 'sse-c' || mode == 'azure-cpk';

  factory ObjectEncryptionInfo.fromJson(Map<String, Object?> json) =>
      ObjectEncryptionInfo(
        mode: json['mode'] as String,
        kmsKeyId: json['kmsKeyId'] as String?,
        bucketKeyEnabled: json['bucketKeyEnabled'] as bool?,
        customerKeyMd5: json['customerKeyMd5'] as String?,
        customerKeySha256: json['customerKeySha256'] as String?,
        encryptionScope: json['encryptionScope'] as String?,
        serverEncrypted: json['serverEncrypted'] as bool?,
      );
  Map<String, Object?> toJson() => {
        'mode': mode,
        if (kmsKeyId != null) 'kmsKeyId': kmsKeyId,
        if (bucketKeyEnabled != null) 'bucketKeyEnabled': bucketKeyEnabled,
        if (customerKeyMd5 != null) 'customerKeyMd5': customerKeyMd5,
        if (customerKeySha256 != null) 'customerKeySha256': customerKeySha256,
        if (encryptionScope != null) 'encryptionScope': encryptionScope,
        if (serverEncrypted != null) 'serverEncrypted': serverEncrypted,
      };
}

String? encryptionHintMessage(Object? hint) => switch (hint) {
      'encryption_required_by_policy' =>
        'This bucket policy requires encryption. Choose an upload encryption mode.',
      'kms_access_denied' =>
        'Access to the KMS key was denied. Check your key permissions.',
      'kms_key_unavailable' =>
        'The KMS key is unavailable. Check its region and status.',
      'sse_c_blocked' => 'This bucket blocks customer key encryption (SSE-C).',
      'sse_c_key_required' =>
        'This object is encrypted with a customer key: choose or unlock a key.',
      'sse_c_key_mismatch' => 'The customer key does not match this object.',
      'unsupported_by_endpoint' =>
        'This endpoint does not support the selected encryption mode.',
      _ => null,
    };
