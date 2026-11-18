/// A passphrase-protected key file for the app's optional encryption.
///
/// On disk the file is a standard age v1 file encrypted to an scrypt
/// (passphrase) recipient, so `age -d keys.age` with the passphrase recovers
/// it without this app. The plaintext is UTF-8 JSON:
///
/// ```json
/// {"format":"object-data-browser-keys","version":1,"keys":[
///   {"id":"<128-bit hex>","label":"…","type":"customerKey",
///    "createdAt":"<UTC ISO-8601>","secret":"<base64 of 32 bytes>"},
///   {"id":"…","label":"…","type":"ageIdentity",
///    "createdAt":"…","secret":"AGE-SECRET-KEY-1…"}]}
/// ```
///
/// Keys live only in this file and, while unlocked, in memory. They are
/// never written to the OS Keychain, the app's JSON state, logs, exception
/// messages or `toString()` output. [EncryptionKeyRecord] is the non-secret
/// view that UI and state JSON may hold.
///
/// This library depends only on `dart:io`, `package:crypto` and the age
/// library; it has no Flutter, `path_provider` or controller dependency.
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as digests;

import 'crypto/age.dart';
import 'key_file_merge.dart';
import 'crypto/age_primitives.dart'
    show ageConstantTimeEquals, ageRandomBytes, ageWipe;

const keyFileSyncMinPassphraseLength = 16;

final class KeyFileMergeResult {
  const KeyFileMergeResult(
      {required this.clock,
      required this.added,
      required this.updated,
      required this.removed,
      required this.localChanged,
      required this.remoteDiffers,
      this.remoteUsesDifferentPassphrase = false});
  final int clock, added, updated, removed;
  final bool localChanged, remoteDiffers, remoteUsesDifferentPassphrase;
  int get changes => added + updated + removed;
}

/// The kinds of key the store understands.
enum EncryptionKeyType {
  /// A raw 256-bit key, usable as an S3 SSE-C key or an Azure
  /// customer-provided key.
  customerKey,

  /// An age X25519 identity: a vault key for client-side encryption.
  ageIdentity,
}

/// Non-secret description of a stored key. Safe for UI and state JSON.
final class EncryptionKeyRecord {
  const EncryptionKeyRecord({
    required this.id,
    required this.label,
    required this.type,
    required this.createdAt,
    required this.fingerprint,
    this.md5Base64,
  });

  /// Parses the output of [toJson]. Throws [FormatException] when a field is
  /// missing or has the wrong type.
  factory EncryptionKeyRecord.fromJson(Map<String, Object?> json) {
    final id = json['id'];
    final label = json['label'];
    final typeName = json['type'];
    final createdAt = json['createdAt'];
    final fingerprint = json['fingerprint'];
    final md5 = json['md5Base64'];
    final type = EncryptionKeyType.values
        .where((value) => value.name == typeName)
        .firstOrNull;
    final created = createdAt is String ? DateTime.tryParse(createdAt) : null;
    if (id is! String ||
        label is! String ||
        type == null ||
        created == null ||
        fingerprint is! String ||
        (md5 != null && md5 is! String)) {
      throw const FormatException('Invalid encryption key record.');
    }
    return EncryptionKeyRecord(
      id: id,
      label: label,
      type: type,
      createdAt: created.toUtc(),
      fingerprint: fingerprint,
      md5Base64: md5 as String?,
    );
  }

  /// Random 128-bit identifier, lower-case hex. Stable across renames.
  final String id;

  /// User-chosen display name.
  final String label;

  final EncryptionKeyType type;

  /// Creation time in UTC.
  final DateTime createdAt;

  /// Public identifier of the key material.
  ///
  /// * [EncryptionKeyType.customerKey]: base64 SHA-256 of the key, which is
  ///   also the key hash Azure reports for customer-provided keys.
  /// * [EncryptionKeyType.ageIdentity]: the `age1…` recipient.
  final String fingerprint;

  /// For [EncryptionKeyType.customerKey] only: base64 MD5 of the key, which
  /// S3 reports for SSE-C objects. Null for other key types.
  final String? md5Base64;

  /// JSON without any secret material.
  Map<String, Object?> toJson() => <String, Object?>{
        'id': id,
        'label': label,
        'type': type.name,
        'createdAt': createdAt.toUtc().toIso8601String(),
        'fingerprint': fingerprint,
        if (md5Base64 != null) 'md5Base64': md5Base64,
      };

  @override
  bool operator ==(Object other) =>
      other is EncryptionKeyRecord &&
      other.id == id &&
      other.label == label &&
      other.type == type &&
      other.createdAt.isAtSameMomentAs(createdAt) &&
      other.fingerprint == fingerprint &&
      other.md5Base64 == md5Base64;

  @override
  int get hashCode => Object.hash(id, label, type,
      createdAt.microsecondsSinceEpoch, fingerprint, md5Base64);

  @override
  String toString() =>
      'EncryptionKeyRecord(${type.name}, id: $id, label: $label, '
      'fingerprint: $fingerprint)';
}

// ---------------------------------------------------------------------------
// Typed failures
// ---------------------------------------------------------------------------

/// Base class of every failure raised by [EncryptionKeyStore]. Messages
/// never contain keys or passphrases.
sealed class EncryptionKeyStoreException implements Exception {
  const EncryptionKeyStoreException(this.message);

  final String message;

  /// The message alone: forms show a thrown error's text to the user, and a
  /// class name in front of it is noise. Messages never hold key material.
  @override
  String toString() => message;
}

/// The operation needs the store to be unlocked.
final class EncryptionKeyStoreLockedException
    extends EncryptionKeyStoreException {
  const EncryptionKeyStoreLockedException()
      : super('The encryption key file is locked.');
}

/// The key file (or an import source) does not exist.
final class EncryptionKeyStoreMissingException
    extends EncryptionKeyStoreException {
  const EncryptionKeyStoreMissingException(super.message);
}

/// [EncryptionKeyStore.create] was called but the key file already exists.
final class EncryptionKeyStoreAlreadyExistsException
    extends EncryptionKeyStoreException {
  const EncryptionKeyStoreAlreadyExistsException()
      : super('An encryption key file already exists at this location.');
}

/// The passphrase does not open the key file.
final class EncryptionKeyStoreWrongPassphraseException
    extends EncryptionKeyStoreException {
  const EncryptionKeyStoreWrongPassphraseException()
      : super('The passphrase is incorrect.');
}

/// The file is damaged, was modified, or is not an Object Data Browser key
/// file.
final class EncryptionKeyStoreCorruptException
    extends EncryptionKeyStoreException {
  const EncryptionKeyStoreCorruptException(super.message);
}

/// The age container uses a feature this implementation cannot read.
final class EncryptionKeyStoreUnsupportedException
    extends EncryptionKeyStoreException {
  const EncryptionKeyStoreUnsupportedException()
      : super('The encryption key file uses an unsupported age format or '
            'feature.');
}

/// The key file was written by a newer version of the app. It is refused
/// rather than rewritten, so nothing in it can be lost.
final class EncryptionKeyStoreUnsupportedVersionException
    extends EncryptionKeyStoreException {
  const EncryptionKeyStoreUnsupportedVersionException(this.version)
      : super('The encryption key file uses format version $version, which '
            'this version of the app cannot read. Update the app.');

  final int version;
}

/// A new passphrase is shorter than
/// [EncryptionKeyStore.minimumPassphraseLength] characters.
final class EncryptionKeyStoreWeakPassphraseException
    extends EncryptionKeyStoreException {
  const EncryptionKeyStoreWeakPassphraseException(this.minimumLength)
      : super('The passphrase must be at least $minimumLength characters '
            'long.');

  final int minimumLength;
}

/// The key file could not be written. The previous file and in-memory keys
/// are unchanged unless rollback itself failed; in that case the store is
/// locked and the backup remains available for recovery.
final class EncryptionKeyStoreWriteException
    extends EncryptionKeyStoreException {
  const EncryptionKeyStoreWriteException(super.message);
}

/// No key with this id is stored.
final class EncryptionKeyNotFoundException extends EncryptionKeyStoreException {
  const EncryptionKeyNotFoundException(this.id)
      : super('No encryption key with id $id is stored.');

  final String id;
}

/// The key being imported is already stored; nothing was changed.
final class EncryptionKeyDuplicateException
    extends EncryptionKeyStoreException {
  const EncryptionKeyDuplicateException(this.existing)
      : super('This key is already stored.');

  /// The record that already holds the same secret.
  final EncryptionKeyRecord existing;
}

/// A supplied key, label or id is not usable: wrong key length, invalid age
/// secret key, empty label, or a key of the wrong type for the accessor.
final class EncryptionKeyInvalidException extends EncryptionKeyStoreException {
  const EncryptionKeyInvalidException(super.message);
}

/// Points in the atomic write at which a test can inject a failure.
enum EncryptionKeyStoreWriteStage {
  /// The new file is written and flushed beside the target.
  tempWritten,

  /// The new file was read back and decrypted, and the previous file was
  /// copied to `<name>.bak`.
  backedUp,

  /// The new file was renamed over the target.
  replaced,
}

// ---------------------------------------------------------------------------
// Store
// ---------------------------------------------------------------------------

final class _Entry {
  _Entry(this.raw, this.record, this.dedupeKey);

  /// The JSON object as stored, including fields this version ignores.
  final Map<String, Object?> raw;

  /// Null for key types this version does not understand.
  final EncryptionKeyRecord? record;

  /// Type plus canonical secret; equal for two entries holding the same key.
  final String? dedupeKey;

  String? get id {
    final value = raw['id'];
    return value is String ? value : null;
  }
}

final class _Unlocked {
  _Unlocked(this.passphrase, this.document, this.entries);

  final String passphrase;

  /// Top-level JSON fields other than `keys`, including unknown ones.
  final Map<String, Object?> document;
  final List<_Entry> entries;
}

/// A passphrase-encrypted key file that can be backed up and moved between
/// machines.
///
/// Typical use: [exists] → [create] or [unlock] → read [records], fetch
/// secrets with [customerKey] / [ageIdentity], mutate → [lock].
///
/// Every mutation rewrites the file atomically: the new file is written and
/// flushed beside the target, read back and decrypted with the passphrase
/// held in memory, and only then renamed over the target. The previous file
/// is kept as `<name>.bak` until the replaced file is confirmed to hold the
/// verified bytes, and is restored if that check fails. In-memory state
/// changes only after the file is safely on disk.
///
/// Operations are serialized, so concurrent calls cannot interleave writes.
/// Each mutation runs scrypt twice (encrypt and verify) on a helper
/// isolate.
final class EncryptionKeyStore {
  /// Creates a store for [file]. Nothing is read until [unlock].
  ///
  /// [scryptWorkFactor] is the base-two logarithm of scrypt's N used when
  /// writing (1..20). The default of 15 keeps unlocking fast in pure Dart on
  /// phones; files written at any accepted work factor can be read.
  /// [debugWriteFault] is called at each [EncryptionKeyStoreWriteStage] and
  /// exists so tests can simulate a failed write by throwing.
  EncryptionKeyStore(
    this.file, {
    this.scryptWorkFactor = ageDefaultScryptWorkFactor,
    this.debugWriteFault,
    String? deviceId,
  }) : deviceId = deviceId ?? newDeviceId() {
    RangeError.checkValueInInterval(
        scryptWorkFactor, 1, ageMaxScryptWorkFactor, 'scryptWorkFactor');
  }

  /// Value of the `format` field.
  static const String formatName = 'object-data-browser-keys';

  /// The `version` this implementation reads and writes.
  static const int formatVersion = 1;

  /// Minimum length, in Unicode code points, of a new passphrase.
  static const int minimumPassphraseLength = 12;

  /// Length of a customer key in bytes (256 bits).
  static const int customerKeyLength = 32;

  static const int _maxFileLength = 8 * 1024 * 1024;
  static const int _maxLabelLength = 256;
  static const _passphraseRotationField = 'localPassphraseRotation';

  /// The encrypted key file.
  final File file;
  final String deviceId;
  static String newDeviceId() =>
      ageRandomBytes(8).map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  final Set<void Function()> _listeners = {};
  void addListener(void Function() listener) => _listeners.add(listener);
  void removeListener(void Function() listener) => _listeners.remove(listener);
  void _changed() {
    for (final listener in _listeners.toList()) {
      listener();
    }
  }

  String? _previousPassphrase;

  /// Rotation metadata is committed with the new ciphertext. A different
  /// installation can read the file without inheriting that rotation intent.
  String? get localPassphraseRotation {
    final value = _requireUnlocked().document[_passphraseRotationField];
    return value is String && value.startsWith('$deviceId:') ? value : null;
  }

  int get clock => _requireUnlocked().document['clock'] as int? ?? 0;
  bool get passphraseMeetsSyncPolicy =>
      _requireUnlocked().passphrase.runes.length >=
      keyFileSyncMinPassphraseLength;

  /// scrypt work factor used when writing.
  final int scryptWorkFactor;

  /// Test hook; see the constructor.
  final void Function(EncryptionKeyStoreWriteStage stage)? debugWriteFault;

  _Unlocked? _state;
  int _lockGeneration = 0;
  Future<void> _tail = Future<void>.value();

  /// Whether the key file exists on disk.
  Future<bool> exists() => file.exists();

  /// Whether the store is unlocked and holds keys in memory.
  bool get isUnlocked => _state != null;

  /// Number of stored keys of a type this version does not understand
  /// (written by a newer app). They are preserved on every rewrite but not
  /// listed in [records]. Requires the store to be unlocked.
  int get unsupportedKeyCount =>
      _requireUnlocked().entries.where((e) => e.record == null).length;

  /// The stored keys, in creation order, without secrets. Requires the
  /// store to be unlocked.
  List<EncryptionKeyRecord> get records =>
      List<EncryptionKeyRecord>.unmodifiable(
          _requireUnlocked().entries.map((e) => e.record).nonNulls);

  /// Creates a new, empty key file protected by [passphrase] and leaves the
  /// store unlocked unless [lock] is called while the write is in flight.
  ///
  /// Throws [EncryptionKeyStoreAlreadyExistsException] when the file exists
  /// and [EncryptionKeyStoreWeakPassphraseException] when the passphrase is
  /// shorter than [minimumPassphraseLength] characters.
  Future<void> create(String passphrase) {
    final generation = _lockGeneration;
    return _serialized(() async {
      _checkLockGeneration(generation);
      _checkNewPassphrase(passphrase);
      if (await file.exists()) {
        throw const EncryptionKeyStoreAlreadyExistsException();
      }
      final state = _Unlocked(passphrase,
          <String, Object?>{'clock': 0, 'removed': <Object?>[]}, <_Entry>[]);
      await _write(_encode(state.document, state.entries), passphrase,
          creating: true);
      if (generation == _lockGeneration) {
        _state = state;
        _changed();
      }
    });
  }

  /// Reads and decrypts the key file.
  ///
  /// Throws [EncryptionKeyStoreMissingException] when there is no file,
  /// [EncryptionKeyStoreWrongPassphraseException] for a wrong passphrase,
  /// [EncryptionKeyStoreCorruptException] when the file is damaged or is not
  /// a key file, [EncryptionKeyStoreUnsupportedException] for an unsupported
  /// age container, and [EncryptionKeyStoreUnsupportedVersionException] when
  /// it was written by a newer key file format version.
  Future<void> unlock(String passphrase) {
    final generation = _lockGeneration;
    return _serialized(() async {
      _checkLockGeneration(generation);
      final state = await _load(file, passphrase);
      _checkLockGeneration(generation);
      _state = state;
      _changed();
    });
  }

  /// Drops the keys and the passphrase from memory.
  ///
  /// Best effort: Dart strings are immutable and the garbage collector may
  /// keep copies until it runs, so this narrows the exposure window rather
  /// than guaranteeing erasure.
  void lock() {
    _lockGeneration++;
    final state = _state;
    _state = null;
    _previousPassphrase = null;
    _changed();
    if (state == null) return;
    for (final entry in state.entries) {
      entry.raw.clear();
    }
    state.entries.clear();
    state.document.clear();
  }

  /// Generates and stores a random 256-bit customer key.
  Future<EncryptionKeyRecord> generateCustomerKey(String label) {
    final key = ageRandomBytes(customerKeyLength);
    return _addCustomerKey(label, key).whenComplete(() => ageWipe(key));
  }

  /// Stores an existing 256-bit customer key.
  ///
  /// Throws [EncryptionKeyInvalidException] unless [key] is exactly 32 bytes
  /// and [EncryptionKeyDuplicateException] when the same key is already
  /// stored.
  Future<EncryptionKeyRecord> importCustomerKey(String label, Uint8List key) {
    if (key.length != customerKeyLength) {
      return Future<EncryptionKeyRecord>.error(
          const EncryptionKeyInvalidException(
              'A customer key must be exactly 32 bytes (256 bits).'));
    }
    // Work on a private copy: the caller may overwrite [key] right away.
    final copy = Uint8List.fromList(key);
    return _addCustomerKey(label, copy).whenComplete(() => ageWipe(copy));
  }

  /// Generates and stores a new age X25519 identity (vault key).
  Future<EncryptionKeyRecord> generateAgeIdentity(String label) async {
    return _addAgeIdentity(label, await AgeIdentity.generate());
  }

  /// Stores an existing age identity given as `AGE-SECRET-KEY-1…`.
  ///
  /// Throws [EncryptionKeyInvalidException] when the text is not a supported
  /// age secret key and [EncryptionKeyDuplicateException] when the identity
  /// is already stored.
  Future<EncryptionKeyRecord> importAgeIdentity(
    String label,
    String secretKey,
  ) async {
    final AgeIdentity identity;
    try {
      identity = await AgeIdentity.parse(secretKey);
    } on AgeException {
      throw const EncryptionKeyInvalidException(
          'The text is not a supported age secret key.');
    }
    return _addAgeIdentity(label, identity);
  }

  /// Returns a copy of the 32-byte customer key [id]. The caller owns the
  /// copy and should overwrite it when done.
  Uint8List customerKey(String id) {
    final entry = _find(_requireUnlocked(), id);
    if (entry.record?.type != EncryptionKeyType.customerKey) {
      throw const EncryptionKeyInvalidException(
          'The selected key is not a customer key.');
    }
    return base64.decode(entry.raw['secret']! as String);
  }

  /// Returns the age identity [id].
  Future<AgeIdentity> ageIdentity(String id) async {
    final entry = _find(_requireUnlocked(), id);
    if (entry.record?.type != EncryptionKeyType.ageIdentity) {
      throw const EncryptionKeyInvalidException(
          'The selected key is not an age identity.');
    }
    return AgeIdentity.parse(entry.raw['secret']! as String);
  }

  /// Changes the label of key [id].
  Future<void> rename(String id, String label) => _serialized(() async {
        final state = _requireUnlocked();
        final cleanLabel = _checkLabel(label);
        final entries = List<_Entry>.of(state.entries);
        final index = entries.indexOf(_find(state, id));
        final old = entries[index];
        final raw = Map<String, Object?>.of(old.raw)
          ..['label'] = cleanLabel
          ..['rev'] = clock + 1
          ..['by'] = deviceId;
        final record = old.record;
        entries[index] = _Entry(
          raw,
          record == null
              ? null
              : EncryptionKeyRecord(
                  id: record.id,
                  label: cleanLabel,
                  type: record.type,
                  createdAt: record.createdAt,
                  fingerprint: record.fingerprint,
                  md5Base64: record.md5Base64,
                ),
          old.dedupeKey,
        );
        await _commit(state, entries, document: _nextDocument(state));
      });

  /// Permanently removes key [id] from the file. Data encrypted with it can
  /// no longer be decrypted unless the key is kept elsewhere.
  Future<void> delete(String id) => _serialized(() async {
        final state = _requireUnlocked();
        final entries = List<_Entry>.of(state.entries)
          ..remove(_find(state, id));
        final document = _nextDocument(state);
        document['removed'] = [
          for (final value in state.document['removed'] as List? ?? [])
            if ((value as Map)['id'] != id) value,
          {
            'id': id,
            'rev': clock + 1,
            'by': deviceId,
            'removedAt': DateTime.now().toUtc().toIso8601String()
          },
        ];
        await _commit(state, entries, document: document);
      });

  /// Re-encrypts the key file under a new passphrase.
  ///
  /// Requires the store to be unlocked. Throws
  /// [EncryptionKeyStoreWrongPassphraseException] when [current] is not the
  /// passphrase that unlocked the file, and
  /// [EncryptionKeyStoreWeakPassphraseException] when [next] is too short.
  /// Copies of the file made earlier stay protected by the old passphrase.
  Future<void> changePassphrase(String current, String next) =>
      _serialized(() async {
        final state = _requireUnlocked();
        if (!ageConstantTimeEquals(
            utf8.encode(current), utf8.encode(state.passphrase))) {
          throw const EncryptionKeyStoreWrongPassphraseException();
        }
        _checkNewPassphrase(next);
        await _commit(state, List<_Entry>.of(state.entries),
            passphrase: next,
            document: {
              ...state.document,
              _passphraseRotationField: '$deviceId:${newDeviceId()}',
            });
        if (isUnlocked) _previousPassphrase = current;
      });

  /// Copies the encrypted key file byte for byte to [destination],
  /// replacing it if it exists. Plaintext is never written; the copy is
  /// protected by the current passphrase. Works while locked.
  Future<void> exportTo(File destination) => _serialized(() async {
        if (!await file.exists()) {
          throw const EncryptionKeyStoreMissingException(
              'There is no encryption key file to export.');
        }
        try {
          if (await destination.exists() &&
              await FileSystemEntity.identical(
                  await file.resolveSymbolicLinks(),
                  await destination.resolveSymbolicLinks())) {
            throw const EncryptionKeyInvalidException(
                'The export destination is the key file itself.');
          }
          final bytes = await file.readAsBytes();
          await destination.writeAsBytes(bytes, flush: true);
        } on FileSystemException {
          throw const EncryptionKeyStoreWriteException(
              'The key file could not be exported.');
        }
      });

  /// Merges the keys of another key file, opened with its own [passphrase],
  /// into this store.
  ///
  /// Keys whose secret is already stored are skipped. A key whose id is
  /// already used by a different secret is added under a new random id.
  /// Returns how many keys were added and skipped; the file is rewritten
  /// only when at least one key was added. Requires the store to be
  /// unlocked. [source] is reported with the same typed errors as [unlock].
  Future<({int added, int skipped})> importFrom(
    File source,
    String passphrase,
  ) =>
      _serialized(() async {
        final state = _requireUnlocked();
        final incoming = await _load(source, passphrase);
        return _import(state, incoming);
      });

  Future<({int added, int skipped})> importEncrypted(
          Uint8List bytes, String passphrase) =>
      _serialized(() async {
        final state = _requireUnlocked();
        return _import(state, await _loadBytes(bytes, passphrase));
      });

  Future<({int added, int skipped})> _import(
      _Unlocked state, _Unlocked incoming) async {
    // lock() may have run while the source was being decrypted.
    if (!identical(_state, state)) {
      throw const EncryptionKeyStoreLockedException();
    }
    final entries = List<_Entry>.of(state.entries);
    final secrets = <String>{
      for (final entry in entries)
        if (entry.dedupeKey != null) entry.dedupeKey!,
    };
    final ids = <String>{
      for (final entry in entries)
        if (entry.id != null) entry.id!,
    };
    final incomingClock = incoming.document['clock'] as int? ?? 0;
    var revision = clock > incomingClock ? clock : incomingClock;
    final document = Map<String, Object?>.of(state.document);
    var added = 0;
    var skipped = 0;
    for (final entry in incoming.entries) {
      final dedupeKey = entry.dedupeKey;
      if (dedupeKey != null && !secrets.add(dedupeKey)) {
        skipped++;
        continue;
      }
      var merged = entry;
      final id = entry.id;
      if (id != null && !ids.add(id)) {
        final newId = _newId(ids);
        ids.add(newId);
        final record = entry.record;
        merged = _Entry(
          Map<String, Object?>.of(entry.raw)..['id'] = newId,
          record == null
              ? null
              : EncryptionKeyRecord(
                  id: newId,
                  label: record.label,
                  type: record.type,
                  createdAt: record.createdAt,
                  fingerprint: record.fingerprint,
                  md5Base64: record.md5Base64,
                ),
          dedupeKey,
        );
      }
      merged = _Entry(
          Map<String, Object?>.of(merged.raw)
            ..['rev'] = ++revision
            ..['by'] = deviceId,
          merged.record,
          merged.dedupeKey);
      entries.add(merged);
      added++;
    }
    document['clock'] = revision;
    document['removed'] = [
      for (final value in document['removed'] as List? ?? [])
        if (!entries.any((entry) => entry.id == (value as Map)['id'])) value
    ];
    if (added > 0) await _commit(state, entries, document: document);
    return (added: added, skipped: skipped);
  }

  @override
  String toString() =>
      'EncryptionKeyStore(${file.path}, ${isUnlocked ? 'unlocked' : 'locked'})';

  Map<String, Object?> _nextDocument(_Unlocked state) =>
      Map<String, Object?>.of(state.document)..['clock'] = clock + 1;

  static void _validateRevision(Map<String, Object?> raw) {
    final rev = raw['rev'];
    if (rev != null && (rev is! int || rev < 0)) _corrupt('invalid revision');
    if (raw['by'] != null && raw['by'] is! String) {
      _corrupt('invalid device id');
    }
  }

  Future<Uint8List> encryptedBytes() => _serialized(() async {
        try {
          return await file.readAsBytes();
        } on FileSystemException {
          throw const EncryptionKeyStoreMissingException(
              'The encryption key file could not be read.');
        }
      });

  /// Omitting the remote passphrase uses the unlocked passphrase. A sync
  /// location with a pending local rotation may try the previous passphrase.
  Future<KeyFileMergeResult> mergeEncrypted(Uint8List otherFile,
          {String? otherPassphrase,
          bool Function()? allowPreviousPassphrase,
          bool Function()? allowPassphraseAdoption}) =>
      _serialized(() async {
        final state = _requireUnlocked();
        _Unlocked incoming;
        var differentPassphrase =
            otherPassphrase != null && otherPassphrase != state.passphrase;
        try {
          incoming =
              await _loadBytes(otherFile, otherPassphrase ?? state.passphrase);
        } on EncryptionKeyStoreWrongPassphraseException {
          if (!identical(_state, state) ||
              otherPassphrase != null ||
              _previousPassphrase == null ||
              allowPreviousPassphrase?.call() != true) {
            rethrow;
          }
          incoming = await _loadBytes(otherFile, _previousPassphrase!);
          differentPassphrase = true;
        }
        if (!identical(_state, state)) {
          throw const EncryptionKeyStoreLockedException();
        }
        Map<String, Object?> documentOf(_Unlocked value) => {
              ...value.document,
              'format': formatName,
              'version': formatVersion,
              'keys': [for (final entry in value.entries) entry.raw],
            }..remove(_passphraseRotationField);
        final local = documentOf(state), remote = documentOf(incoming);
        final merged = mergeKeyFileDocuments(local, remote);
        final localChanged =
            normalizedKeyFileJson(local) != normalizedKeyFileJson(merged);
        final remoteDiffers =
            normalizedKeyFileJson(remote) != normalizedKeyFileJson(merged);
        final old = {for (final entry in state.entries) entry.id: entry.raw};
        final next = {
          for (final value in merged['keys'] as List)
            (value as Map)['id']: Map<String, Object?>.from(value)
        };
        final added = next.keys.where((id) => !old.containsKey(id)).length;
        final removed = old.keys.where((id) => !next.containsKey(id)).length;
        final updated = next.keys
            .where((id) =>
                old.containsKey(id) &&
                canonicalKeyFileJson(old[id]) != canonicalKeyFileJson(next[id]))
            .length;
        var nextEntries = List<_Entry>.of(state.entries);
        var nextDocument = state.document;
        if (localChanged) {
          final plaintext = Uint8List.fromList(utf8.encode(jsonEncode(merged)));
          try {
            final decoded = await _decode(plaintext, state.passphrase);
            nextEntries = decoded.entries;
            nextDocument = decoded.document;
            if (state.document.containsKey(_passphraseRotationField)) {
              nextDocument[_passphraseRotationField] =
                  state.document[_passphraseRotationField];
            }
          } finally {
            ageWipe(plaintext);
          }
        }
        final adopt = differentPassphrase &&
            otherPassphrase != null &&
            identical(_state, state) &&
            allowPassphraseAdoption?.call() == true;
        if (adopt &&
            otherPassphrase.runes.length < keyFileSyncMinPassphraseLength) {
          throw const EncryptionKeyStoreWeakPassphraseException(
              keyFileSyncMinPassphraseLength);
        }
        if (localChanged || adopt) {
          await _commit(state, nextEntries,
              document: nextDocument,
              passphrase: adopt ? otherPassphrase : null);
          if (adopt) _previousPassphrase = null;
        }
        return KeyFileMergeResult(
            clock: merged['clock'] as int,
            added: added,
            updated: updated,
            removed: removed,
            localChanged: localChanged,
            remoteDiffers: remoteDiffers,
            remoteUsesDifferentPassphrase: differentPassphrase && !adopt);
      });

  // -------------------------------------------------------------------------
  // Internals
  // -------------------------------------------------------------------------

  Future<T> _serialized<T>(Future<T> Function() action) {
    final result = _tail.then((_) => action());
    _tail = result.then<void>((_) {}, onError: (Object _, StackTrace __) {});
    return result;
  }

  _Unlocked _requireUnlocked() =>
      _state ?? (throw const EncryptionKeyStoreLockedException());

  void _checkLockGeneration(int generation) {
    if (generation != _lockGeneration) {
      throw const EncryptionKeyStoreLockedException();
    }
  }

  static _Entry _find(_Unlocked state, String id) {
    for (final entry in state.entries) {
      if (entry.record != null && entry.id == id) return entry;
    }
    throw EncryptionKeyNotFoundException(_printableId(id));
  }

  /// Ids are hex; anything else supplied by a caller is not echoed verbatim.
  static String _printableId(String id) =>
      RegExp(r'^[0-9a-f]{1,64}$').hasMatch(id) ? id : '(invalid id)';

  static void _checkNewPassphrase(String passphrase) {
    if (passphrase.runes.length < minimumPassphraseLength) {
      throw const EncryptionKeyStoreWeakPassphraseException(
          minimumPassphraseLength);
    }
  }

  static String _checkLabel(String label) {
    final clean = label.trim();
    if (clean.isEmpty) {
      throw const EncryptionKeyInvalidException('The key needs a name.');
    }
    if (clean.length > _maxLabelLength) {
      throw const EncryptionKeyInvalidException(
          'The key name is longer than $_maxLabelLength characters.');
    }
    return clean;
  }

  static String _newId(Set<String> taken) {
    while (true) {
      final bytes = ageRandomBytes(16);
      final id = bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
      if (!taken.contains(id)) return id;
    }
  }

  static String _customerDedupeKey(List<int> key) =>
      '${EncryptionKeyType.customerKey.name}\u0000${base64.encode(key)}';

  static String _identityDedupeKey(AgeIdentity identity) =>
      '${EncryptionKeyType.ageIdentity.name}\u0000${identity.secretKey}';

  static EncryptionKeyRecord _customerRecord(
    String id,
    String label,
    DateTime createdAt,
    List<int> key,
  ) =>
      EncryptionKeyRecord(
        id: id,
        label: label,
        type: EncryptionKeyType.customerKey,
        createdAt: createdAt,
        fingerprint: base64.encode(digests.sha256.convert(key).bytes),
        md5Base64: base64.encode(digests.md5.convert(key).bytes),
      );

  Future<EncryptionKeyRecord> _addCustomerKey(String label, Uint8List key) =>
      _serialized(() async {
        final state = _requireUnlocked();
        final cleanLabel = _checkLabel(label);
        final dedupeKey = _customerDedupeKey(key);
        _rejectDuplicate(state, dedupeKey);
        final id = _newId(_ids(state));
        final createdAt = DateTime.now().toUtc();
        final record = _customerRecord(id, cleanLabel, createdAt, key);
        final entry = _Entry(
          <String, Object?>{
            'id': id,
            'label': cleanLabel,
            'type': EncryptionKeyType.customerKey.name,
            'createdAt': createdAt.toIso8601String(),
            'secret': base64.encode(key),
            'rev': clock + 1,
            'by': deviceId,
          },
          record,
          dedupeKey,
        );
        await _commit(state, List<_Entry>.of(state.entries)..add(entry),
            document: _nextDocument(state));
        return record;
      });

  Future<EncryptionKeyRecord> _addAgeIdentity(
    String label,
    AgeIdentity identity,
  ) =>
      _serialized(() async {
        final state = _requireUnlocked();
        final cleanLabel = _checkLabel(label);
        final dedupeKey = _identityDedupeKey(identity);
        _rejectDuplicate(state, dedupeKey);
        final id = _newId(_ids(state));
        final createdAt = DateTime.now().toUtc();
        final record = EncryptionKeyRecord(
          id: id,
          label: cleanLabel,
          type: EncryptionKeyType.ageIdentity,
          createdAt: createdAt,
          fingerprint: identity.recipient,
        );
        final entry = _Entry(
          <String, Object?>{
            'id': id,
            'label': cleanLabel,
            'type': EncryptionKeyType.ageIdentity.name,
            'createdAt': createdAt.toIso8601String(),
            'secret': identity.secretKey,
            'rev': clock + 1,
            'by': deviceId,
          },
          record,
          dedupeKey,
        );
        await _commit(state, List<_Entry>.of(state.entries)..add(entry),
            document: _nextDocument(state));
        return record;
      });

  static Set<String> _ids(_Unlocked state) => <String>{
        for (final entry in state.entries)
          if (entry.id != null) entry.id!,
      };

  static void _rejectDuplicate(_Unlocked state, String dedupeKey) {
    for (final entry in state.entries) {
      if (entry.dedupeKey == dedupeKey && entry.record != null) {
        throw EncryptionKeyDuplicateException(entry.record!);
      }
    }
  }

  /// Persists [entries] and, if the store was not locked meanwhile, makes
  /// them the in-memory state.
  Future<void> _commit(
    _Unlocked state,
    List<_Entry> entries, {
    String? passphrase,
    Map<String, Object?>? document,
  }) async {
    // Never persist from a state that lock() has already emptied.
    if (!identical(_state, state)) {
      throw const EncryptionKeyStoreLockedException();
    }
    final nextPassphrase = passphrase ?? state.passphrase;
    // Snapshot and encode before the first await: lock() may clear the live
    // maps while the write is in flight.
    document = Map<String, Object?>.of(document ?? state.document);
    await _write(_encode(document, entries), nextPassphrase);
    if (identical(_state, state)) {
      _state = _Unlocked(nextPassphrase, document, entries);
      _changed();
    }
  }

  static Uint8List _encode(
    Map<String, Object?> document,
    List<_Entry> entries,
  ) {
    final json = <String, Object?>{
      'format': formatName,
      'version': formatVersion,
      'keys': <Object?>[for (final entry in entries) entry.raw],
      for (final field in document.entries)
        if (field.key != 'format' &&
            field.key != 'version' &&
            field.key != 'keys')
          field.key: field.value,
    };
    return Uint8List.fromList(utf8.encode(jsonEncode(json)));
  }

  /// Reads, decrypts and validates a key file.
  static Future<_Unlocked> _load(File source, String passphrase) async {
    final Uint8List bytes;
    try {
      if (!await source.exists()) {
        throw const EncryptionKeyStoreMissingException(
            'The encryption key file does not exist.');
      }
      if (await source.length() > _maxFileLength) {
        throw const EncryptionKeyStoreCorruptException(
            'The file is too large to be an encryption key file.');
      }
      bytes = await source.readAsBytes();
    } on FileSystemException {
      throw const EncryptionKeyStoreCorruptException(
          'The encryption key file could not be read.');
    }

    return _loadBytes(bytes, passphrase);
  }

  static Future<_Unlocked> _loadBytes(
      Uint8List bytes, String passphrase) async {
    if (bytes.length > _maxFileLength) {
      throw const EncryptionKeyStoreCorruptException(
          'The encryption key file is too large.');
    }
    final Uint8List plaintext;
    try {
      plaintext = await ageDecrypt(bytes, passphrase: passphrase);
    } on AgeWrongPassphraseException {
      throw const EncryptionKeyStoreWrongPassphraseException();
    } on AgeUnsupportedException {
      throw const EncryptionKeyStoreUnsupportedException();
    } on AgeException {
      throw const EncryptionKeyStoreCorruptException(
          'The encryption key file is damaged or is not a passphrase-'
          'protected key file.');
    }

    try {
      return await _decode(plaintext, passphrase);
    } finally {
      ageWipe(plaintext);
    }
  }

  static Never _corrupt(String detail) =>
      throw EncryptionKeyStoreCorruptException(
          'The encryption key file has invalid contents: $detail.');

  static Future<_Unlocked> _decode(
      Uint8List plaintext, String passphrase) async {
    final Object? decoded;
    try {
      decoded = jsonDecode(utf8.decode(plaintext));
    } on FormatException {
      _corrupt('not UTF-8 JSON');
    }
    if (decoded is! Map<String, Object?> || decoded['format'] != formatName) {
      _corrupt('not an Object Data Browser key file');
    }
    final version = decoded['version'];
    if (version is! int || version < 1) _corrupt('missing format version');
    if (version > formatVersion) {
      throw EncryptionKeyStoreUnsupportedVersionException(version);
    }
    final keys = decoded['keys'];
    if (keys is! List<Object?>) _corrupt('missing key list');

    final entries = <_Entry>[];
    final ids = <String>{};
    for (final item in keys) {
      if (item is! Map<String, Object?>) _corrupt('a key entry is malformed');
      final raw = Map<String, Object?>.of(item);
      _validateRevision(raw);
      final typeName = raw['type'];
      final type = EncryptionKeyType.values
          .where((value) => value.name == typeName)
          .firstOrNull;
      final id = raw['id'];
      if (id is! String || id.isEmpty) _corrupt('missing key id');
      if (!ids.add(id)) _corrupt('duplicate key id');
      if (type == null) {
        // A key type from a newer app: keep it verbatim, list nothing.
        entries.add(_Entry(
          raw,
          null,
          typeName is String && raw.containsKey('secret')
              ? '$typeName\u0000${jsonEncode(raw['secret'])}'
              : null,
        ));
        continue;
      }
      final label = raw['label'];
      final createdText = raw['createdAt'];
      final secret = raw['secret'];
      final createdAt =
          createdText is String ? DateTime.tryParse(createdText) : null;
      if (label is! String || createdAt == null || secret is! String) {
        _corrupt('a key entry is incomplete');
      }
      switch (type) {
        case EncryptionKeyType.customerKey:
          final Uint8List key;
          try {
            key = base64.decode(secret);
          } on FormatException {
            _corrupt('a customer key is not valid base64');
          }
          if (key.length != customerKeyLength) {
            _corrupt('a customer key is not 32 bytes');
          }
          entries.add(_Entry(
            raw,
            _customerRecord(id, label, createdAt.toUtc(), key),
            _customerDedupeKey(key),
          ));
          ageWipe(key);
        case EncryptionKeyType.ageIdentity:
          final AgeIdentity identity;
          try {
            identity = await AgeIdentity.parse(secret);
          } on AgeException {
            _corrupt('an age identity is not valid');
          }
          entries.add(_Entry(
            raw,
            EncryptionKeyRecord(
              id: id,
              label: label,
              type: type,
              createdAt: createdAt.toUtc(),
              fingerprint: identity.recipient,
            ),
            _identityDedupeKey(identity),
          ));
      }
    }
    final document = Map<String, Object?>.of(decoded)
      ..remove('format')
      ..remove('version')
      ..remove('keys');
    final documentClock = document['clock'];
    if (documentClock != null && (documentClock is! int || documentClock < 0)) {
      _corrupt('invalid clock');
    }
    final removed = document['removed'];
    if (removed != null && removed is! List) _corrupt('invalid tombstone list');
    final removedIds = <String>{};
    for (final item in removed as List? ?? []) {
      if (item is! Map<String, Object?> ||
          item['id'] is! String ||
          (item['id'] as String).isEmpty ||
          !removedIds.add(item['id'] as String)) {
        _corrupt('invalid tombstone');
      }
      _validateRevision(item);
      if (item['removedAt'] is! String ||
          DateTime.tryParse(item['removedAt'] as String) == null) {
        _corrupt('invalid tombstone date');
      }
    }
    // An older build may preserve a tombstone while restoring its live key.
    // Resolve that overlap with the very same deterministic join.
    final normalized = mergeKeyFileDocuments({
      ...document,
      'format': formatName,
      'version': formatVersion,
      'keys': [for (final entry in entries) entry.raw],
    }, {
      'format': formatName,
      'version': formatVersion,
      'keys': []
    });
    final liveIds =
        (normalized['keys'] as List).map((e) => (e as Map)['id']).toSet();
    document['clock'] = normalized['clock'];
    document['removed'] = normalized['removed'];
    return _Unlocked(passphrase, document,
        entries.where((e) => liveIds.contains(e.id)).toList());
  }

  /// Atomically replaces the key file with the encryption of [plaintext].
  Future<void> _write(
    Uint8List plaintext,
    String passphrase, {
    bool creating = false,
  }) async {
    final suffix = ageRandomBytes(4)
        .map((b) => b.toRadixString(16).padLeft(2, '0'))
        .join();
    final temp = File('${file.path}.tmp-$suffix');
    final backup = File('${file.path}.bak');
    var backedUp = false;
    var replaced = false;
    try {
      final encrypted = await ageEncrypt(
        plaintext,
        passphrase: passphrase,
        scryptWorkFactor: scryptWorkFactor,
      );
      if (encrypted.length > _maxFileLength) {
        throw const EncryptionKeyStoreWriteException(
            'The encryption key file exceeds the supported size limit.');
      }
      await file.parent.create(recursive: true);
      await temp.writeAsBytes(encrypted, flush: true);
      debugWriteFault?.call(EncryptionKeyStoreWriteStage.tempWritten);

      // Prove that what reached the disk opens with the passphrase and holds
      // exactly the intended contents before it can replace anything.
      final written = await temp.readAsBytes();
      final reopened = await ageDecrypt(written, passphrase: passphrase);
      final intact = ageConstantTimeEquals(reopened, plaintext);
      ageWipe(reopened);
      if (!intact) {
        throw const FileSystemException('verification of the new file failed');
      }

      if (await file.exists()) {
        if (creating) throw const EncryptionKeyStoreAlreadyExistsException();
        await file.copy(backup.path);
        backedUp = true;
      }
      debugWriteFault?.call(EncryptionKeyStoreWriteStage.backedUp);

      await temp.rename(file.path);
      replaced = true;
      debugWriteFault?.call(EncryptionKeyStoreWriteStage.replaced);

      // The previous file is kept until the replaced file is confirmed to
      // be, byte for byte, the file that was just proven decryptable.
      final current = await file.readAsBytes();
      if (!ageConstantTimeEquals(current, written)) {
        throw const FileSystemException('the replaced file does not match');
      }
      if (backedUp) await _deleteQuietly(backup);
    } catch (error) {
      if (replaced) {
        // Roll back to the previous generation (or to "no file" on create).
        try {
          if (backedUp) {
            await backup.rename(file.path);
          } else {
            await file.delete();
          }
        } on FileSystemException {
          // Leave whatever is there; `.bak` remains for manual recovery.
          // The active file may now hold the new generation, so cached old
          // keys/passphrase must not remain usable as if rollback succeeded.
          lock();
          throw const EncryptionKeyStoreWriteException(
              'The encryption key file could not be restored. The store '
              'was locked. Check the key file and any backup before retrying.');
        }
      } else if (backedUp) {
        await _deleteQuietly(backup);
      }
      await _deleteQuietly(temp);
      if (error is EncryptionKeyStoreException) rethrow;
      throw const EncryptionKeyStoreWriteException(
          'The encryption key file could not be saved. The '
          'previous file was kept.');
    } finally {
      ageWipe(plaintext);
    }
  }

  static Future<void> _deleteQuietly(File target) async {
    try {
      if (await target.exists()) await target.delete();
    } on FileSystemException {
      // Best effort.
    }
  }
}
