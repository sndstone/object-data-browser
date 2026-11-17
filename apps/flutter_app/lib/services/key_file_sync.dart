import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'package:xml/xml.dart';
import '../models/key_file_sync_models.dart';
import 'encryption_key_store.dart';
export '../models/key_file_sync_models.dart';

class KeyFileSyncException implements Exception {
  const KeyFileSyncException(this.message);
  final String message;
  @override
  String toString() => message;
}

class KeyFileSyncResponse {
  const KeyFileSyncResponse(this.status, this.headers, this.body);
  final int status;
  final Map<String, String> headers;
  final Uint8List body;
}

/// This boundary sees encrypted key files only. Bucket admin bodies are XML.
abstract interface class KeyFileSyncTransport {
  Future<KeyFileSyncResponse> request(
    String method,
    String bucket, {
    String? key,
    Map<String, String> query = const {},
    Map<String, String> headers = const {},
    List<int> body = const [],
  });
  void close();
}

abstract interface class KeyFileSyncSetupTransport
    implements KeyFileSyncTransport {
  Future<List<String>> buckets();
  Future<void> createBucket(String bucket);
}

/// One installation, one location. Failures are status, never local rollback.
/// Call dispose when disabling sync or replacing the profile/location.
class KeyFileSync {
  KeyFileSync(
      {required this.store,
      required this.config,
      required this.transport,
      KeyFileSyncState state = const KeyFileSyncState(),
      this.onChanged,
      this.onStateChanged,
      this.debounce = const Duration(milliseconds: 400)})
      : _state = state {
    // Read now, not lazily: the first listener call must see a difference.
    _seenPassphraseChanges = store.passphraseChanges;
    store.addListener(_storeChanged);
  }
  final EncryptionKeyStore store;
  final KeyFileSyncConfig config;
  final KeyFileSyncTransport transport;
  final void Function()? onChanged;
  final Future<void> Function(KeyFileSyncState)? onStateChanged;
  final Duration debounce;
  KeyFileSyncState _state;
  KeyFileSyncState get state => _state;
  KeyFileSyncStatus _status = KeyFileSyncStatus.neverSynced;
  String? error;
  int mergedChanges = 0;
  bool _disposed = false, _again = false;
  int _internal = 0;
  int _seenPassphraseChanges = 0;
  Timer? _timer;
  Future<void>? _running;
  bool get localChangesPending =>
      store.isUnlocked && store.clock > state.syncedClock;
  KeyFileSyncStatus get status {
    if (_disposed) return KeyFileSyncStatus.off;
    if ({
      KeyFileSyncStatus.syncing,
      KeyFileSyncStatus.passphraseMismatch,
      KeyFileSyncStatus.error
    }.contains(_status)) {
      return _status;
    }
    if (localChangesPending) return KeyFileSyncStatus.pending;
    if (state.lastSyncedAt == null) return KeyFileSyncStatus.neverSynced;
    return _status == KeyFileSyncStatus.merged
        ? _status
        : KeyFileSyncStatus.upToDate;
  }

  String get statusText => switch (status) {
        KeyFileSyncStatus.off => 'Off',
        KeyFileSyncStatus.neverSynced => 'Never synced',
        KeyFileSyncStatus.upToDate => 'Up to date',
        KeyFileSyncStatus.pending => 'Local changes pending',
        KeyFileSyncStatus.syncing => 'Syncing…',
        KeyFileSyncStatus.merged =>
          'Merged $mergedChanges change(s) from another device',
        KeyFileSyncStatus.passphraseMismatch => state.passphraseChangePending
            ? 'You changed the passphrase on this device before the sync bucket was updated. Enter the previous passphrase to finish.'
            : 'The key file in the sync bucket uses a different passphrase — it was probably changed on another device.',
        KeyFileSyncStatus.error => error ?? 'Sync failed. Try again.',
      };

  void _storeChanged() {
    if (_internal > 0 || _disposed) return;
    if (store.passphraseChanges != _seenPassphraseChanges) {
      _seenPassphraseChanges = store.passphraseChanges;
      // Persist the intent: if this device restarts before the bucket copy is
      // re-encrypted, the mismatch must not revert the new passphrase.
      unawaited(_save(_withPassphrasePending(true)));
    }
    onChanged?.call();
    requestSync();
  }

  KeyFileSyncState _withPassphrasePending(bool pending) => KeyFileSyncState(
      etag: state.etag,
      versionId: state.versionId,
      lastSyncedAt: state.lastSyncedAt,
      syncedClock: state.syncedClock,
      conditionalWrites: state.conditionalWrites,
      versioningEnabled: state.versioningEnabled,
      passphraseChangePending: pending);

  void requestSync() {
    if (_disposed || !store.isUnlocked) return;
    if (_running != null) {
      _again = true;
      return;
    }
    _timer?.cancel();
    _timer = Timer(debounce, () {
      unawaited(syncNow());
    });
  }

  Future<void> syncNow({String? remotePassphrase}) {
    if (_disposed || !store.isUnlocked) return Future.value();
    _timer?.cancel();
    if (_running != null) {
      _again = true;
      return _running!;
    }
    final done = Completer<void>();
    _running = done.future;
    () async {
      try {
        do {
          _again = false;
          await _sync(remotePassphrase);
          remotePassphrase = null;
        } while (_again &&
            !_disposed &&
            store.isUnlocked &&
            status != KeyFileSyncStatus.passphraseMismatch);
      } finally {
        _running = null;
        done.complete();
      }
    }();
    return done.future;
  }

  void _check() {
    if (_disposed || !store.isUnlocked) {
      throw const EncryptionKeyStoreLockedException();
    }
    if (!store.passphraseMeetsSyncPolicy) {
      throw const KeyFileSyncException(
          'Change the key file passphrase to at least 16 characters to turn on sync.');
    }
  }

  Future<KeyFileSyncResponse> _request(String method,
      {String? key,
      Map<String, String> query = const {},
      Map<String, String> headers = const {},
      List<int> body = const []}) {
    _check();
    return transport.request(method, config.bucket,
        key: key, query: query, headers: headers, body: body);
  }

  static KeyFileSyncResponse _ok(KeyFileSyncResponse response) {
    if (response.status >= 200 && response.status < 300) return response;
    throw KeyFileSyncException(switch (response.status) {
      401 || 403 => 'Sync access denied.',
      404 => 'Sync bucket or object is missing.',
      400 || 405 || 501 => 'Sync endpoint unsupported.',
      _ => 'Sync request failed. Try again.',
    });
  }

  Future<T> _storeOperation<T>(Future<T> Function() action) async {
    _internal++;
    try {
      return await action();
    } finally {
      _internal--;
    }
  }

  Future<void> _save(KeyFileSyncState value) async {
    if (_disposed) return;
    _state = value;
    await onStateChanged?.call(value);
    if (!_disposed) onChanged?.call();
  }

  Future<void> _sync(String? remotePassphrase) async {
    _status = KeyFileSyncStatus.syncing;
    error = null;
    mergedChanges = 0;
    onChanged?.call();
    try {
      _check();
      if (remotePassphrase != null &&
          remotePassphrase.runes.length < keyFileSyncMinPassphraseLength) {
        throw const KeyFileSyncException(
            'The remote passphrase must have at least 16 characters.');
      }
      var conditional = state.conditionalWrites;
      for (var round = 0; round < 5; round++) {
        final remote = await _request('GET', key: config.objectKey);
        final absent = remote.status == 404;
        var push = absent;
        if (!absent) {
          _ok(remote);
          final result = await _storeOperation(
              () => store.mergeEncrypted(remote.body, remotePassphrase));
          mergedChanges += result.changes;
          push = result.remoteDiffers || result.remoteUsesDifferentPassphrase;
          if (remotePassphrase != null) {
            if (state.passphraseChangePending) {
              // The passphrase was changed here: keep it and re-encrypt the
              // bucket copy, instead of adopting the old one back.
              push = true;
            } else {
              await _storeOperation(
                  () => store.adoptPassphrase(remotePassphrase!));
            }
            remotePassphrase = null;
          }
        }
        // Snapshot revision BEFORE the queued ciphertext read. A later mutation
        // may be included in the bytes, but cannot be falsely marked synced.
        _check();
        final syncedClock = store.clock;
        String? expectedEtag = remote.headers['etag'];
        if (push) {
          final bytes = await store.encryptedBytes();
          final etag = remote.headers['etag'];
          if (!absent && etag == null) conditional = false;
          final headers = <String, String>{
            'content-type': 'application/octet-stream',
            if (conditional != false)
              if (absent) 'if-none-match': '*' else 'if-match': etag!,
          };
          var put = await _request('PUT',
              key: config.objectKey, headers: headers, body: bytes);
          if ({409, 412}.contains(put.status)) {
            conditional = true;
            continue;
          }
          final unsupported = put.status == 501 ||
              (put.status == 400 &&
                  RegExp(r'if-match|if-none-match', caseSensitive: false)
                      .hasMatch(utf8.decode(put.body, allowMalformed: true)));
          if (unsupported && conditional != false) {
            conditional = false;
            put = await _request('PUT',
                key: config.objectKey,
                headers: {'content-type': 'application/octet-stream'},
                body: bytes);
          }
          _ok(put);
          // Verify even successful conditional requests: some S3-compatible
          // endpoints silently ignore those headers. This also detects a writer
          // that changed the object immediately after our PUT.
          final confirmed = _ok(await _request('GET', key: config.objectKey));
          expectedEtag = confirmed.headers['etag'];
          if (!_equal(bytes, confirmed.body)) {
            conditional = false;
            continue;
          }
          // A successful PUT does not prove enforcement. Leave this unknown
          // until a stale precondition is demonstrably rejected.
        }
        final head = _ok(await _request('HEAD', key: config.objectKey));
        // If HEAD observes a later writer, merge that generation next round.
        if (head.headers['etag'] != expectedEtag) continue;
        await _save(KeyFileSyncState(
            etag: head.headers['etag'],
            versionId: head.headers['x-amz-version-id'],
            lastSyncedAt: DateTime.now().toUtc(),
            syncedClock: syncedClock,
            conditionalWrites: conditional,
            versioningEnabled: state.versioningEnabled));
        _status = mergedChanges > 0
            ? KeyFileSyncStatus.merged
            : KeyFileSyncStatus.upToDate;
        if (localChangesPending) _again = true;
        return;
      }
      throw const KeyFileSyncException(
          'Sync changed repeatedly on another device. Try again.');
    } on EncryptionKeyStoreWrongPassphraseException {
      _status = KeyFileSyncStatus.passphraseMismatch;
    } on EncryptionKeyStoreLockedException {
      _status = KeyFileSyncStatus.pending;
    } on KeyFileSyncException catch (failure) {
      error = failure.message;
      _status = KeyFileSyncStatus.error;
    } on EncryptionKeyStoreException {
      error =
          'The remote key file could not be opened or saved. Check the file and try again.';
      _status = KeyFileSyncStatus.error;
    } catch (_) {
      error = 'Sync is offline or unavailable. Try again.';
      _status = KeyFileSyncStatus.error;
    } finally {
      if (!_disposed) onChanged?.call();
    }
  }

  Future<void> refreshVersioning({bool enable = false}) async {
    if (enable) {
      _ok(await _request('PUT',
          query: {'versioning': ''},
          headers: {'content-type': 'application/xml'},
          body: utf8.encode(
              '<VersioningConfiguration xmlns="http://s3.amazonaws.com/doc/2006-03-01/"><Status>Enabled</Status></VersioningConfiguration>')));
    }
    bool? enabled;
    try {
      final response = _ok(await _request('GET', query: {'versioning': ''}));
      final xml = XmlDocument.parse(utf8.decode(response.body));
      enabled =
          xml.findAllElements('Status').firstOrNull?.innerText == 'Enabled';
    } catch (_) {
      enabled = null;
    }
    await _save(KeyFileSyncState(
        etag: state.etag,
        versionId: state.versionId,
        lastSyncedAt: state.lastSyncedAt,
        syncedClock: state.syncedClock,
        conditionalWrites: state.conditionalWrites,
        versioningEnabled: enabled,
        passphraseChangePending: state.passphraseChangePending));
  }

  Future<List<KeyFileSyncVersion>> earlierVersions() async {
    final result = <KeyFileSyncVersion>[];
    var query = <String, String>{'versions': '', 'prefix': config.objectKey};
    final cursors = <String>{};
    do {
      final response = _ok(await _request('GET', query: query));
      final xml = XmlDocument.parse(utf8.decode(response.body));
      String text(XmlElement element, String name) =>
          element.getElement(name)?.innerText ?? '';
      for (final version in xml.findAllElements('Version')) {
        if (text(version, 'Key') != config.objectKey) continue;
        result.add(KeyFileSyncVersion(
            id: text(version, 'VersionId'),
            size: int.tryParse(text(version, 'Size')) ?? 0,
            modifiedAt:
                DateTime.tryParse(text(version, 'LastModified'))?.toUtc()));
      }
      final root = xml.rootElement;
      if (text(root, 'IsTruncated') != 'true') break;
      final key = text(root, 'NextKeyMarker'),
          version = text(root, 'NextVersionIdMarker');
      if (!cursors.add('$key\u0000$version')) {
        throw const KeyFileSyncException('Version listing did not advance.');
      }
      query = {...query, 'key-marker': key, 'version-id-marker': version};
    } while (true);
    return result;
  }

  Future<({int added, int skipped})> importVersion(
      String versionId, String passphrase) async {
    final response = _ok(await _request('GET',
        key: config.objectKey, query: {'versionId': versionId}));
    final result = await store.importEncrypted(response.body, passphrase);
    requestSync();
    return result;
  }

  void dispose() {
    _disposed = true;
    _timer?.cancel();
    _again = false;
    store.removeListener(_storeChanged);
    transport.close();
  }

  static bool _equal(List<int> a, List<int> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}
