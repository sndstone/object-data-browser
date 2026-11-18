/// Only non-secret sync metadata belongs in application state.
const defaultKeyFileSyncObjectKey = 'object-data-browser/encryption-keys.age';

class KeyFileSyncConfig {
  const KeyFileSyncConfig(
      {required this.profileId,
      required this.bucket,
      this.objectKey = defaultKeyFileSyncObjectKey});
  final String profileId, bucket, objectKey;
  Map<String, Object?> toJson() =>
      {'profileId': profileId, 'bucket': bucket, 'objectKey': objectKey};
  factory KeyFileSyncConfig.fromJson(Map<String, Object?> json) =>
      KeyFileSyncConfig(
          profileId: json['profileId'] as String,
          bucket: json['bucket'] as String,
          objectKey:
              json['objectKey'] as String? ?? defaultKeyFileSyncObjectKey);
}

class KeyFileSyncState {
  const KeyFileSyncState(
      {this.etag,
      this.versionId,
      this.lastSyncedAt,
      this.syncedClock = 0,
      this.conditionalWrites,
      this.versioningEnabled,
      this.confirmedPassphraseRotation,
      this.passphraseChangePending = false});
  final String? etag, versionId;

  /// Pending intent written by builds before rotations were stamped in the
  /// encrypted key file. Retained until a successful sync of this location.
  final bool passphraseChangePending;
  final String? confirmedPassphraseRotation;
  final DateTime? lastSyncedAt;
  final int syncedClock;
  final bool? conditionalWrites, versioningEnabled;
  Map<String, Object?> toJson() => {
        'etag': etag,
        'versionId': versionId,
        'lastSyncedAt': lastSyncedAt?.toUtc().toIso8601String(),
        'syncedClock': syncedClock,
        'conditionalWrites': conditionalWrites,
        'versioningEnabled': versioningEnabled,
        if (confirmedPassphraseRotation != null)
          'confirmedPassphraseRotation': confirmedPassphraseRotation,
        if (passphraseChangePending) 'passphraseChangePending': true,
      };
  factory KeyFileSyncState.fromJson(Map<String, Object?> json) =>
      KeyFileSyncState(
          etag: json['etag'] as String?,
          versionId: json['versionId'] as String?,
          lastSyncedAt:
              DateTime.tryParse(json['lastSyncedAt'] as String? ?? '')?.toUtc(),
          syncedClock: json['syncedClock'] as int? ?? 0,
          conditionalWrites: json['conditionalWrites'] as bool?,
          versioningEnabled: json['versioningEnabled'] as bool?,
          confirmedPassphraseRotation:
              json['confirmedPassphraseRotation'] as String?,
          passphraseChangePending: json['passphraseChangePending'] == true);
}

enum KeyFileSyncStatus {
  off,
  neverSynced,
  upToDate,
  pending,
  syncing,
  merged,
  passphraseMismatch,
  error
}

class KeyFileSyncVersion {
  const KeyFileSyncVersion(
      {required this.id, required this.size, this.modifiedAt});
  final String id;
  final int size;
  final DateTime? modifiedAt;
}
