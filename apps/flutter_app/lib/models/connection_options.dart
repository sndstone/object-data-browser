import 'dart:convert';

/// Nonsecret connection configuration. Tokens belong to EndpointProfile's
/// secure credential fields, never this metadata record.
class ConnectionOptions {
  const ConnectionOptions({
    this.authMode = 'static',
    this.awsProfileName = '',
    this.roleArn = '',
    this.externalId = '',
    this.roleSessionName = 'object-browser',
    this.knownBucket = '',
    this.requesterPays = false,
    this.expectedBucketOwner = '',
    this.caBundlePath = '',
    this.storageClasses = const [],
  });

  final String authMode, awsProfileName, roleArn, externalId, roleSessionName;
  final String knownBucket, expectedBucketOwner, caBundlePath;
  final bool requesterPays;
  final List<String> storageClasses;
  bool get usesStaticKeys => authMode == 'static';

  Map<String, Object?> toJson() => {
        'authMode': authMode,
        'awsProfileName': awsProfileName,
        'roleArn': roleArn,
        'externalId': externalId,
        'roleSessionName': roleSessionName,
        'knownBucket': knownBucket,
        'requesterPays': requesterPays,
        'expectedBucketOwner': expectedBucketOwner,
        'caBundlePath': caBundlePath,
        'storageClasses': storageClasses,
      };

  factory ConnectionOptions.fromJson(Map<String, Object?> json) =>
      ConnectionOptions(
        authMode: json['authMode'] as String? ?? 'static',
        awsProfileName: json['awsProfileName'] as String? ?? '',
        roleArn: json['roleArn'] as String? ?? '',
        externalId: json['externalId'] as String? ?? '',
        roleSessionName: json['roleSessionName'] as String? ?? 'object-browser',
        knownBucket: json['knownBucket'] as String? ?? '',
        requesterPays: json['requesterPays'] == true,
        expectedBucketOwner: json['expectedBucketOwner'] as String? ?? '',
        caBundlePath: json['caBundlePath'] as String? ?? '',
        storageClasses:
            List<String>.from(json['storageClasses'] as List? ?? []),
      );

  ConnectionOptions update(String field, Object? value) =>
      ConnectionOptions.fromJson({...toJson(), field: value});

  @override
  bool operator ==(Object other) =>
      other is ConnectionOptions &&
      jsonEncode(toJson()) == jsonEncode(other.toJson());
  @override
  int get hashCode => jsonEncode(toJson()).hashCode;
}
