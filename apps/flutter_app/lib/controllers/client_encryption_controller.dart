part of 'app_controller.dart';

extension AppControllerClientEncryption on AppController {
  bool get clientKeyUnlockRequired =>
      _encryptionKeyStore?.isUnlocked != true &&
      (bannerMessage?.contains('Unlock your encryption key file') == true ||
          clientRuleFor(currentPrefix)?.encryptsNames == true ||
          objects.any((o) =>
              clientRuleFor(o.key) != null &&
              o.key.split('/').any(looksLikeVaultToken)));

  void _clearNameKeys() {
    _nameKeyGeneration++;
    for (final key in _vaultNameKeys.values) {
      key.wipe();
    }
    _vaultNameKeys.clear();
    _nameQueryObjects = null;
    _nameQueryKeys = null;
    _nameQueryVersions = null;
    _nameVersionKeys = null;
    _objectQuery.invalidate();
    _versionQuery.invalidate();
  }

  void _nameKeysChanged() {
    _clearNameKeys();
    final store = _encryptionKeyStore;
    final generation = _nameKeyGeneration;
    if (!_disposed && store?.isUnlocked == true) {
      _nameKeysLoading = () async {
        final derived = <String, VaultNameKeys>{};
        try {
          for (final record in store!.records) {
            if (record.type == EncryptionKeyType.ageIdentity) {
              derived[record.id] =
                  (await store.ageIdentity(record.id)).deriveNameKeys();
            }
          }
          if (_disposed ||
              !store.isUnlocked ||
              generation != _nameKeyGeneration) {
            return;
          }
          _nameKeyGeneration++;
          _nameQueryObjects = null;
          _vaultNameKeys.addAll(derived);
          derived.clear();
          _syncObjectFilterWithPrefix();
          _notifyEncryptionChanged();
        } catch (_) {
          // A lock or removal may race identity parsing. No key survives it.
        } finally {
          for (final key in derived.values) {
            key.wipe();
          }
        }
      }();
    } else {
      _nameKeysLoading = null;
      _syncObjectFilterWithPrefix();
    }
    _notifyEncryptionChanged();
  }

  List<String> get _visibleQueryKeys {
    final context =
        (selectedProfile?.clientEncryptionRules, selectedBucket?.name);
    if (_nameQueryContext != context ||
        !identical(_nameQueryObjects, objects) ||
        _nameQueryKeys?.length != objects.length ||
        _nameQueryGeneration != _nameKeyGeneration) {
      _nameQueryContext = context;
      _nameQueryObjects = objects;
      _nameQueryGeneration = _nameKeyGeneration;
      _nameQueryKeys = objects.map(visibleObjectKey).toList(growable: false);
    }
    return _nameQueryKeys!;
  }

  String visibleStoredKey(String key, {bool? folder}) {
    final rule = clientRuleFor(key);
    return rule == null
        ? key
        : decodeVaultKey(key, rule, _vaultNameKeys,
            file: !(folder ?? key.endsWith('/')));
  }

  String visiblePrefix(String storedPrefix) =>
      visibleStoredKey(storedPrefix, folder: true);

  String visibleTransferText(String text) =>
      text.replaceAllMapped(RegExp(r'[A-Za-z0-9_-]{24,}(?:\.age)?'), (match) {
        final raw = match[0]!;
        final token =
            raw.endsWith('.age') ? raw.substring(0, raw.length - 4) : raw;
        for (final keys in _vaultNameKeys.values) {
          final name = keys.open(token);
          if (name != null) return name;
        }
        return raw;
      });

  /// Engine text about a download that is published under a decrypted name.
  ///
  /// The published name may differ from the decoded one (a collision suffix,
  /// platform sanitising, truncation), so replacing the exact name is not
  /// enough. Any text that could mention it is replaced by text built from the
  /// stored key. Records therefore keep the stored key; the transfer views
  /// decode it again for display while the key file is unlocked.
  TransferJob _safeDownloadJob(TransferJob job) {
    if (_activeDownloadNames.isEmpty || job.direction != 'download') return job;
    var label = job.label;
    var item = job.currentItemLabel;
    var lines = job.outputLines;
    for (final entry in _activeDownloadNames.entries) {
      final stored = entry.key.split('/').last;
      final needle = hiddenNameNeedle(entry.value);
      if (mentionsHiddenName(label, needle)) label = 'Download $stored';
      if (item != null && mentionsHiddenName(item, needle)) item = stored;
      if (lines.any((line) => mentionsHiddenName(line, needle))) {
        final hidden =
            'Output hidden for $stored (stored under an encrypted name).';
        final kept = <String>[];
        for (final line in lines) {
          final next = mentionsHiddenName(line, needle) ? hidden : line;
          if (kept.isEmpty || kept.last != next) kept.add(next);
        }
        lines = kept;
      }
    }
    return job.copyWith(
        label: label, currentItemLabel: item, outputLines: lines);
  }

  Future<VaultNameKeys?> _uploadNameKeys(ClientEncryptionRule rule) async {
    if (rule.policy == ClientEncryptionPolicy.unsupported) {
      throw const FormatException(vaultPolicyUnsupported);
    }
    if (rule.encryptsNames) {
      await ensureEncryptionKeyStore();
      await _nameKeysLoading;
    }
    final keys = _vaultNameKeys[rule.keyId];
    validateVaultPolicy(rule, keys);
    return keys;
  }

  void retainClientPreview(ObjectPreview preview) =>
      _retainedClientPreviews.add(preview);
  void releaseClientPreview(ObjectPreview preview) {
    _retainedClientPreviews.remove(preview);
    if (!identical(selectedObjectPreview, preview)) ageWipe(preview.bytes);
  }

  void _clearClientPreviewBytes() {
    ageWipe(selectedObjectPreview?.bytes);
    for (final preview in _retainedClientPreviews) {
      ageWipe(preview.bytes);
    }
  }

  ClientEncryptionRule? clientRuleFor(
    String key, {
    EndpointProfile? profile,
    String? bucket,
  }) {
    final p = profile ?? selectedProfile;
    final b = bucket ?? selectedBucket?.name;
    return p == null || b == null
        ? null
        : matchingClientEncryptionRule(p.clientEncryptionRules, b, key);
  }

  /// Listing is a read operation: unknown policies and locked key files must
  /// not be validated as uploads. Prefer folders already present in the listing
  /// so older encoded trees remain readable after name encryption is disabled.
  Future<String> _storedListingPrefix(String value,
      {bool versionListing = false}) async {
    final reference = currentPrefix;
    // The typed value decides: text outside every vault location is not
    // hidden and is sent as typed, wherever the browser currently is.
    final rule = clientRuleFor(value);
    if (rule == null) return value;
    final unknownPolicy = rule.policy == ClientEncryptionPolicy.unsupported;
    final rules = selectedProfile?.clientEncryptionRules ?? const [];
    final folders = objects.where((o) => o.isFolder).toList();
    await _nameKeysLoading;
    if (rule.randomNames) {
      return reference.startsWith(rule.prefix) ? reference : rule.prefix;
    }
    final slash = value.lastIndexOf('/');
    final complete = slash < rule.prefix.length
        ? rule.prefix
        : value.substring(0, slash + 1);
    var stored = rule.prefix;
    var visible = rule.prefix;
    // Encoded names are known to exist under this rule when the browser is
    // inside one or the listing shows one. Names elsewhere say nothing about
    // this location. A policy this version cannot read may hide every name.
    var encoded = rule.encryptsNames ||
        unknownPolicy ||
        _hasVaultTokenBelow(rule, reference, rules) ||
        objects.any((o) => _hasVaultTokenBelow(rule, o.key, rules));
    if (reference.startsWith(rule.prefix)) {
      for (final segment
          in reference.substring(rule.prefix.length).split('/')) {
        if (segment.isEmpty) break;
        final candidate = '$stored$segment/';
        final decoded =
            decodeVaultKey(candidate, rule, _vaultNameKeys, file: false);
        if (!complete.startsWith(decoded)) break;
        stored = candidate;
        visible = decoded;
      }
    }
    for (final segment in complete.substring(visible.length).split('/')) {
      if (segment.isEmpty) continue;
      final wanted = '$visible$segment/';
      final folder = folders.where((o) {
        if (!o.key.startsWith(stored)) return false;
        final tail =
            o.key.substring(stored.length).replaceFirst(RegExp(r'/$'), '');
        return !tail.contains('/') &&
            decodeVaultKey(o.key, rule, _vaultNameKeys, file: false) == wanted;
      }).firstOrNull;
      final keys = _vaultNameKeys[rule.keyId];
      // Only a folder below the rule's own prefix can be an encoded parent.
      final previous = stored
          .substring(rule.prefix.length)
          .split('/')
          .where((s) => s.isNotEmpty)
          .lastOrNull;
      // Where encoded names are known below this rule, an unresolved name is
      // taken for a hidden one, with or without the keys.
      final sealed = rule.encryptsNames ||
          encoded ||
          (previous != null && _isEncodedName(previous, rule));
      // A name that may be hidden and cannot be translated is never sent as
      // typed: the key file is locked, the rule's policy is unknown to this
      // version, or encoded names are known to exist here. Version listings
      // fall back to the deepest folder already known; the object filter
      // says why.
      if (folder == null &&
          (unknownPolicy || (keys == null && (sealed || encoded)))) {
        if (!versionListing) {
          throw FormatException(unknownPolicy
              ? vaultPolicyUnsupportedFilter
              : _encryptionKeyStore?.isUnlocked == true
                  ? vaultNamesKeyMissingFilter
                  : vaultNamesLockedFilter);
        }
        encoded = true;
        break;
      }
      final String storedSegment;
      try {
        storedSegment = folder != null
            ? folder.key
                .substring(stored.length)
                .replaceFirst(RegExp(r'/$'), '')
            : sealed
                ? sealVaultName(segment, keys!)
                : segment;
      } on FormatException {
        // A segment that cannot be a name ("." or ".."). Only the object
        // filter reports it; a version listing has no place to show it.
        if (!versionListing) rethrow;
        encoded = true;
        break;
      }
      if (_isEncodedName(storedSegment, rule)) encoded = true;
      stored = '$stored$storedSegment/';
      visible = wanted;
    }
    // Where nothing is encoded, names are plaintext by the rule's own setting
    // and the server may filter on the partial segment, exactly as before.
    if (!encoded) return value;
    // Otherwise keep the partial segment in the visible query, never in a
    // stored prefix.
    return stored;
  }

  /// Whether [key] shows an encoded name that belongs to [rule]. A key owned
  /// by a nested rule says nothing about the rule around it.
  bool _hasVaultTokenBelow(ClientEncryptionRule rule, String key,
          List<ClientEncryptionRule> rules) =>
      key.startsWith(rule.prefix) &&
      identical(matchingClientEncryptionRule(rules, rule.bucket, key), rule) &&
      key
          .substring(rule.prefix.length)
          .split('/')
          .any((segment) => _isEncodedName(segment, rule));

  /// Whether a stored segment below [rule] is an encoded name. When the
  /// rule's key is loaded only a name that opens counts, so an ordinary name
  /// that merely has a token's shape ("Accounts_receivable_2024") is not
  /// evidence. Without that key (locked, still loading, or the key is not in
  /// the key file) the shape is all there is, and it errs on the side of
  /// hiding.
  bool _isEncodedName(String segment, ClientEncryptionRule rule) {
    if (!looksLikeVaultToken(segment)) return false;
    if (_vaultNameKeys[rule.keyId] == null) return true;
    final token = segment.endsWith('.age')
        ? segment.substring(0, segment.length - 4)
        : segment;
    return _vaultNameKeys.values.any((keys) => keys.open(token) != null);
  }

  /// The marker of the rule's own prefix, which is never encrypted.
  bool _isVaultRootMarker(ClientEncryptionRule rule, String key) =>
      rule.prefix.isNotEmpty &&
      key == (rule.prefix.endsWith('/') ? rule.prefix : '${rule.prefix}/');

  bool _versionPrefixNeedsTranslation(VersionBrowserOptions options) {
    if (options.filterMode == BrowserFilterMode.prefix) {
      return (clientRuleFor(currentPrefix) ??
              clientRuleFor(options.filterValue)) !=
          null;
    }
    // Text and regex filters are applied here, to visible names. Engines do
    // not use the text, so it stays out of their requests and traces wherever
    // the bucket has a vault location.
    final bucket = selectedBucket?.name;
    return options.filterValue.isNotEmpty &&
        (selectedProfile?.clientEncryptionRules
                .any((rule) => rule.bucket == bucket) ??
            false);
  }

  Future<VersionBrowserOptions> _versionOptionsForStorage(
      VersionBrowserOptions options) async {
    if (options.filterMode != BrowserFilterMode.prefix) {
      return options.copyWith(filterValue: '');
    }
    final stored =
        await _storedListingPrefix(options.filterValue, versionListing: true);
    return stored == options.filterValue
        ? options
        : options.copyWith(filterValue: stored);
  }

  /// Whether names below [rule] may be hidden: by its setting, by a policy
  /// this version cannot read, or because the browser shows encoded names
  /// there. The loaded listing is evidence only for the bucket it shows.
  bool _vaultNamesMayBeHidden(
      EndpointProfile profile, String bucket, ClientEncryptionRule rule) {
    if (rule.encryptsNames ||
        rule.policy == ClientEncryptionPolicy.unsupported) {
      return true;
    }
    return profile.id == selectedProfile?.id &&
        bucket == selectedBucket?.name &&
        (_hasVaultTokenBelow(
                rule, currentPrefix, profile.clientEncryptionRules) ||
            objects.any((o) => _hasVaultTokenBelow(
                rule, o.key, profile.clientEncryptionRules)));
  }

  static String _listedPathId(String profileId, String bucket, String path) =>
      jsonEncode([profileId, bucket, path.replaceFirst(RegExp(r'/+$'), '')]);

  /// Paths a provider returned are stored names, whatever they look like.
  void _rememberListedPaths(
      EndpointProfile profile, Object? bucket, Object? items) {
    if (bucket is! String ||
        items is! List ||
        profile.clientEncryptionRules.isEmpty) {
      return;
    }
    for (final item in items) {
      final name = item is Map ? item['name'] : null;
      if (name is String) {
        // Insertion-ordered: re-adding moves a path to the newest end, and
        // the oldest are dropped first.
        final id = _listedPathId(profile.id, bucket, name);
        _listedStoragePaths
          ..remove(id)
          ..add(id);
      }
    }
    while (_listedStoragePaths.length > 4096) {
      _listedStoragePaths.remove(_listedStoragePaths.first);
    }
  }

  /// A typed path is acceptable below hidden names when it is in stored form
  /// (every segment a token) or names something a listing returned.
  bool _isStoredVaultPath(EndpointProfile profile, String bucket,
      ClientEncryptionRule rule, String path) {
    if (path
        .substring(rule.prefix.length)
        .split('/')
        .where((s) => s.isNotEmpty)
        .every(looksLikeVaultToken)) {
      return true;
    }
    if (_listedStoragePaths.contains(_listedPathId(profile.id, bucket, path))) {
      return true;
    }
    final folder = path.endsWith('/') ? path : '$path/';
    return profile.id == selectedProfile?.id &&
        bucket == selectedBucket?.name &&
        objects.any((o) => o.key.startsWith(folder));
  }

  /// A bucket copy lists its source by the prefix as typed. Where names may be
  /// hidden only stored names exist, and a visible name typed there would
  /// reach the provider and the copy checkpoint in plaintext and match nothing.
  void _guardVaultCopyPrefix(
      EndpointProfile source, String bucket, String prefix) {
    final rule = matchingClientEncryptionRule(
        source.clientEncryptionRules, bucket, prefix);
    if (rule == null ||
        !_vaultNamesMayBeHidden(source, bucket, rule) ||
        _isStoredVaultPath(source, bucket, rule, prefix)) {
      return;
    }
    throw const EngineException(
        code: ErrorCode.invalidConfig,
        message:
            'This source prefix is inside a location with encrypted names. Copy from the vault location itself, or enter the stored (encrypted) folder name.');
  }

  /// Directory administration takes a path as typed. Where names may be
  /// hidden only a stored path may be sent, as paths picked from a listing are.
  void _guardTypedVaultPath(
      EndpointProfile profile, String bucket, String path) {
    final rule = matchingClientEncryptionRule(
        profile.clientEncryptionRules, bucket, path);
    if (rule == null ||
        !_vaultNamesMayBeHidden(profile, bucket, rule) ||
        _isStoredVaultPath(profile, bucket, rule, path)) {
      return;
    }
    throw const EngineException(
        code: ErrorCode.unsupportedFeature,
        message:
            'This location has encrypted names. Enter the stored (encrypted) directory name, or pick the directory from the list.');
  }

  static String _withoutEdgeBlanks(String value) => withoutEdgeBlanks(value);
  static Set<String>? _trimVariants(String value) => vaultTrimVariants(value);

  /// Some engine handlers trim a bucket name or key before using it. Refuse a
  /// write whose target reaches a vault location, or another rule, once
  /// trimmed, fully or in part: the guards here would not see it, and the
  /// engine would write it there. See [vaultTargetIsAmbiguous].
  void _guardTrimmedVaultKey(
      EndpointProfile profile, Object? bucket, Object? key) {
    if (bucket is String &&
        key is String &&
        vaultTargetIsAmbiguous(profile.clientEncryptionRules, bucket, key)) {
      throw const EngineException(
          code: ErrorCode.invalidConfig, message: vaultAmbiguousTarget);
    }
  }

  /// Generated test and benchmark data is not encrypted. Null when the keys
  /// written for [prefix] cannot lie in a vault location of [bucket].
  ///
  /// The keys must be predictable for that: a prefix with a space or control
  /// character at either end is refused outright when the bucket has a vault
  /// location, because each engine trims a different set of them.
  String? _vaultGeneratedDataRefusal(
      EndpointProfile profile, String bucket, String prefix,
      {required bool benchmark}) {
    if (profile.clientEncryptionRules.isEmpty) return null;
    // A "." or ".." folder may be resolved on the way, into any bucket of
    // this connection: with a vault rule anywhere, refuse it.
    if (!vaultBucketIsCertain(profile.clientEncryptionRules, bucket)) {
      return 'This connection has a vault location, and generated data is not encrypted. Enter the bucket name exactly as it is listed, without spaces or other characters.';
    }
    final readings = _trimVariants(prefix);
    if (readings == null || readings.any(hasDotSegment)) {
      return 'This connection has a vault location, and generated data is not encrypted. Remove any "." or ".." folder from the prefix so its destination is certain.';
    }
    final buckets = _trimVariants(bucket);
    final rules = profile.clientEncryptionRules
        .where((rule) => buckets == null || buckets.contains(rule.bucket));
    if (rules.isEmpty) return null;
    if (_withoutEdgeBlanks(prefix) != prefix) {
      return 'This bucket has a vault location, and generated data is not encrypted. Remove the spaces or control characters at the start and end of the prefix so its destination is certain.';
    }
    final keyPrefixes = benchmark
        ? _benchmarkKeyPrefixes(prefix)
        : _testDataKeyPrefixes(prefix);
    return rules.any((rule) => keyPrefixes.any((written) =>
            written.startsWith(rule.prefix) || rule.prefix.startsWith(written)))
        ? 'Generated data is not encrypted, so it cannot be written where it could land in a vault location. Choose a bucket or a prefix outside it.'
        : null;
  }

  /// Where a benchmark writes for a prefix no engine trims: desktop engines
  /// and the Dart mobile service add a slash and a "bench-" run folder;
  /// Android writes directly below the prefix, or below "benchmarks/" when
  /// it is empty.
  static Set<String> _benchmarkKeyPrefixes(String prefix) => prefix.isEmpty
      ? const {'bench-', 'benchmarks/'}
      : {prefix.endsWith('/') ? prefix : '$prefix/'};

  /// Where the test-data tool writes: "<prefix>testdata-", with a slash added
  /// by one engine.
  static Set<String> _testDataKeyPrefixes(String prefix) => {
        '${prefix}testdata-',
        if (prefix.isNotEmpty && !prefix.endsWith('/')) '$prefix/testdata-',
      };

  void _guardVaultStorageAction(String action, Map<String, Object?> arguments,
      EndpointProfile destination,
      {bool sameProfile = true}) {
    // Recovery IDs hide the actual target. History workflows likewise dispatch
    // a batch without exposing each destination key to this host-side guard.
    // Refuse those writes when their target range can overlap a protected rule:
    // nothing here can tell whether an entry is ciphertext.
    // See [vaultBucketIsCertain].
    if (destination.clientEncryptionRules.isNotEmpty) {
      for (final name in const ['bucketName', 'destinationBucketName']) {
        final value = arguments[name];
        if (value is String &&
            !vaultBucketIsCertain(destination.clientEncryptionRules, value)) {
          throw const EngineException(
              code: ErrorCode.invalidConfig,
              message:
                  'This connection has a vault location, so the bucket must be certain. Enter the bucket name exactly as it is listed, without spaces or other characters.');
        }
      }
    }
    final history =
        action == 'planHistoryCopy' || action == 'resumeHistoryCopy';
    if (action == 'resumeUpload' || history) {
      final bucket =
          arguments[history ? 'destinationBucketName' : 'bucketName'];
      final prefix = history ? arguments['prefix'] as String? ?? '' : '';
      // Also as an engine that trims its arguments, fully or in part, would
      // read them. Too many blanks to enumerate counts as overlapping.
      final buckets = bucket is String ? _trimVariants(bucket) : null;
      final prefixes = _trimVariants(prefix);
      final protected = destination.clientEncryptionRules.any((rule) =>
          (bucket is! String ||
              buckets == null ||
              buckets.contains(rule.bucket)) &&
          (prefixes == null ||
              prefixes.any((p) =>
                  p.startsWith(rule.prefix) || rule.prefix.startsWith(p))));
      if (protected) {
        throw EngineException(
            code: ErrorCode.unsupportedFeature,
            message: history
                ? 'This destination contains a vault location, so version history cannot be copied into it. Copy without version history: vault-encrypted objects are copied as they are.'
                : 'Recoverable uploads cannot write into a vault location. Use Upload in the object browser.');
      }
      return;
    }
    _guardTrimmedVaultKey(
        destination,
        arguments['destinationBucketName'] ?? arguments['bucketName'],
        arguments['destinationKey']);
    _guardTrimmedVaultKey(
        destination, arguments['bucketName'], arguments['key']);
    if (const {
      'listDirectories',
      'getDirectoryAccess',
      'setDirectoryAccess',
      'deleteDirectory',
      'renameDirectory',
      'createDirectory'
    }.contains(action)) {
      final bucket = arguments['bucketName'];
      // A rename names two paths, and its target is typed.
      for (final path in [arguments['key'], arguments['destinationKey']]) {
        if (bucket is String && path is String) {
          _guardTypedVaultPath(destination, bucket, path);
        }
      }
    }
    final copy = action == 'copyObject';
    final directory =
        action == 'createDirectory' || action == 'renameDirectory';
    if (!copy && !directory && action != 'startResumableUpload') return;
    final bucket = arguments[copy ? 'destinationBucketName' : 'bucketName'];
    final key = arguments[
        copy || action == 'renameDirectory' ? 'destinationKey' : 'key'];
    if (bucket is! String || key is! String) return;
    // Directory paths in Azure administration need not have a trailing slash.
    final target = directory && !key.endsWith('/') ? '$key/' : key;
    final rule = matchingClientEncryptionRule(
        destination.clientEncryptionRules, bucket, target);
    // A directory move carries its whole subtree: a vault location below the
    // new name would receive whatever the directory holds.
    if (action == 'renameDirectory' &&
        destination.clientEncryptionRules.any((r) =>
            r.bucket == bucket &&
            r.prefix.length > target.length &&
            r.prefix.startsWith(target))) {
      throw const EngineException(
          code: ErrorCode.unsupportedFeature,
          message:
              'A directory cannot be moved onto a path that contains a vault location: its contents would not be encrypted.');
    }
    // The rule's own prefix is never encrypted and holds no content.
    if (rule == null ||
        (_isVaultRootMarker(rule, target) &&
            (action == 'createDirectory' || (copy && key.endsWith('/'))))) {
      return;
    }
    // What is already stored under this rule adds nothing to it by moving
    // or being copied inside it.
    final sourceKey = arguments[copy ? 'sourceKey' : 'key'];
    final inside = sameProfile &&
        sourceKey is String &&
        (!copy || arguments['sourceBucketName'] == bucket) &&
        identical(
            matchingClientEncryptionRule(
                destination.clientEncryptionRules,
                bucket,
                directory && !sourceKey.endsWith('/')
                    ? '$sourceKey/'
                    : sourceKey),
            rule);
    String? message;
    if (action == 'startResumableUpload') {
      message =
          'Recoverable uploads cannot write into a vault location. Use Upload in the object browser.';
    } else if (directory &&
        (rule.encryptsNames ||
            rule.policy == ClientEncryptionPolicy.unsupported)) {
      message =
          'This location encrypts names. Create and rename folders in the object browser.';
    } else if (action == 'renameDirectory' && !inside) {
      message =
          'A directory cannot be moved into a vault location: its contents would not be encrypted. Upload them in the object browser.';
    } else if (copy) {
      final marker = key.endsWith('/');
      if (rule.policy == ClientEncryptionPolicy.unsupported) {
        message = vaultPolicyUnsupported;
      } else if (rule.encryptsNames &&
          // Restoring a version onto its own key creates no new name.
          !(inside && sourceKey == key) &&
          // A folder marker of an encoded tree ends in "<token>/".
          !(marker
              ? looksLikeVaultToken(
                  key.split('/').where((s) => s.isNotEmpty).lastOrNull ?? '')
              : key.endsWith('.age') &&
                  looksLikeVaultToken(key.split('/').last))) {
        message =
            'This destination encrypts names. Only objects that already have an encrypted name can be copied here.';
      } else if (!marker &&
          !inside &&
          !(key.endsWith('.age') &&
              sourceKey is String &&
              sourceKey.endsWith('.age'))) {
        // A copy transfers the stored bytes as they are. Only ciphertext may
        // enter a vault location that way, whatever the rule does to names.
        message =
            'This destination is a vault location. Only vault-encrypted objects (.age) can be copied or moved into it. Upload other files in the object browser so they are encrypted.';
      }
    }
    if (message != null) {
      throw EngineException(
          code: ErrorCode.unsupportedFeature, message: message);
    }
  }

  bool isClientEncrypted(ObjectEntry object) =>
      !object.isFolder &&
      object.key.endsWith('.age') &&
      clientRuleFor(object.key) != null;
  String visibleObjectKey(ObjectEntry object) =>
      visibleStoredKey(object.key, folder: object.isFolder);
  String visibleObjectName(ObjectEntry object) {
    if (clientRuleFor(object.key) == null) return object.name;
    final visible = visibleObjectKey(object);
    if (object.key.endsWith(object.name)) {
      final parent =
          object.key.substring(0, object.key.length - object.name.length);
      final visibleParent = visiblePrefix(parent);
      if (visible.startsWith(visibleParent)) {
        return visible.substring(visibleParent.length);
      }
    }
    return visible;
  }

  int? clientPlaintextSize(String key) {
    if (selectedProfile == null || selectedBucket == null) return null;
    final cached = _clientPlaintextSizes[
        _encryptionIdentity(selectedProfile!, selectedBucket!.name, key)];
    final object = selectedObject?.key == key
        ? selectedObject
        : objects.where((o) => o.key == key).firstOrNull;
    return cached != null &&
            object != null &&
            cached.storedSize == object.size &&
            cached.etag == object.etag
        ? cached.plaintextSize
        : null;
  }

  Future<void> _requireClientEncryptionCapability(
    EndpointProfile profile,
    String engine,
  ) async {
    final supported = await _engineService.getCapabilities(
      engineId: engine,
      profile: profile,
    );
    if (!supported.any(
      (c) =>
          c.key == 'object.clientEncryption' &&
          c.state == CapabilityState.supported,
    )) {
      throw const EngineException(
        code: ErrorCode.unsupportedFeature,
        message:
            'The selected engine does not support client-side encryption. Choose a supported engine.',
      );
    }
  }

  Future<List<AgeIdentity>> _vaultIdentities() async {
    final store = await ensureEncryptionKeyStore();
    if (!store.isUnlocked) {
      throw const EngineException(
        code: ErrorCode.invalidConfig,
        message: 'Unlock your encryption key file to decrypt this object.',
      );
    }
    return [
      for (final record in store.records)
        if (record.type == EncryptionKeyType.ageIdentity)
          await store.ageIdentity(record.id),
    ];
  }

  Future<String> _clientObjectUrl(
      EndpointProfile profile, String bucket, String key, String engine) async {
    final providerEncryption =
        await _downloadEncryption(profile, bucket, [key]);
    if (providerEncryption?.mode.isCustomerKey == true) {
      throw const EngineException(
          code: ErrorCode.unsupportedFeature,
          message:
              'Provider customer-key encryption cannot be read through a presigned preview range. Download an encrypted copy and decrypt it with age.');
    }
    return _engineService.generatePresignedUrl(
        engineId: engine,
        profile: profile,
        bucketName: bucket,
        key: key,
        expiration:
            Duration(minutes: settings.defaultPresignMinutes.clamp(1, 15)));
  }

  Future<ClientObjectHeader> _openClientObject(
    ClientObjectReader reader,
    String url,
    ObjectEntry object,
    EndpointProfile profile,
    String bucket,
  ) async {
    final identities = await _vaultIdentities();
    try {
      final header = await reader.open(
        url,
        object.size,
        object.etag,
        identities,
      );
      if (_encryptionKeyStore?.isUnlocked != true || _disposed) {
        header.dispose();
        throw const EngineException(
          code: ErrorCode.invalidConfig,
          message: 'Unlock your encryption key file to decrypt this object.',
        );
      }
      _clientPlaintextSizes[_encryptionIdentity(profile, bucket, object.key)] =
          (
        storedSize: object.size,
        etag: object.etag,
        plaintextSize: header.plaintextLength
      );
      return header;
    } on AgeNoMatchingIdentityException {
      throw const EngineException(
        code: ErrorCode.invalidConfig,
        message:
            'This object is encrypted to a vault key that is not in your key file.',
      );
    } on AgeAuthenticationException catch (error) {
      throw EngineException(
        code: ErrorCode.decryptionFailed,
        message:
            'Integrity check failed. The encrypted object is corrupt or was modified.',
        details: {'chunk': error.chunkIndex ?? 0},
      );
    } on AgeMalformedException {
      throw const EngineException(
        code: ErrorCode.decryptionFailed,
        message:
            'Integrity check failed. The encrypted object is corrupt or truncated.',
        details: {'chunk': 0},
      );
    }
  }

  Future<TransferJob> _startClientDownload(
      EndpointProfile profile, String bucket, String key, String engine,
      {bool attach = true}) async {
    await _requireClientEncryptionCapability(profile, engine);
    // Check the lock before requesting any presigned URL or ciphertext.
    await _vaultIdentities();
    final object = objects.where((o) => o.key == key).firstOrNull ??
        (selectedObject?.key == key ? selectedObject : null);
    if (object == null) {
      throw const EngineException(
        code: ErrorCode.invalidConfig,
        message: 'Refresh the object listing before decrypting this object.',
      );
    }
    final url = await _clientObjectUrl(profile, bucket, key, engine);
    final reader = ClientObjectReader(
      _previewRangeFetcher ?? _fetchClientRange,
    );
    final header = await _openClientObject(
      reader,
      url,
      object,
      profile,
      bucket,
    );
    late final TransferJob job;
    try {
      final providerEncryption = await _downloadEncryption(profile, bucket, [
        key,
      ]);
      if (_encryptionKeyStore?.isUnlocked != true) {
        throw const EngineException(
          code: ErrorCode.invalidConfig,
          message: 'Unlock your encryption key file to decrypt this object.',
        );
      }
      // Engines accept one plain file name. A decoded name may hold a
      // backslash (legal on macOS and Linux), which they reject.
      final visibleName = visibleObjectKey(object)
          .split('/')
          .last
          .replaceAll(RegExp(r'[\\\x00]'), '_');
      final hiddenName =
          visibleName != clientEncryptionVisibleKey(key.split('/').last);
      if (hiddenName) _activeDownloadNames[key] = visibleName;
      final rawJob = await _engineService.startDownload(
        engineId: engine,
        profile: profile,
        bucketName: bucket,
        keys: [key],
        destinationPath: settings.downloadPath,
        conflictPolicy: settings.downloadConflictPolicy,
        multipartThresholdMiB: settings.multipartThresholdMiB,
        multipartChunkMiB: settings.multipartChunkMiB,
        encryption: providerEncryption,
        clientEncryption: {
          ...header.downloadParameters,
          if (hiddenName) 'fileName': visibleName,
        },
      );
      job = _safeDownloadJob(rawJob);
    } catch (error) {
      final name = _activeDownloadNames[key];
      if (name == null ||
          !mentionsHiddenName(error.toString(), hiddenNameNeedle(name))) {
        rethrow;
      }
      throw EngineException(
          code: error is EngineException ? error.code : ErrorCode.unknown,
          message:
              'The download of ${key.split('/').last} failed. Details are hidden because the object is stored under an encrypted name.');
    } finally {
      _activeDownloadNames.remove(key);
      header.dispose();
    }
    if (!attach) return job;
    // The closure retains only routing metadata. A retry unwraps the header anew.
    _retryTransfers[job.id] = () async {
      if (activeEngineId != engine ||
          selectedProfile?.id != profile.id ||
          selectedBucket?.name != bucket) {
        showBannerMessage(
            'Select the original connection, engine and bucket before retrying.',
            severity: BannerSeverity.warning);
        return;
      }
      await startSampleDownload(key: key);
    };
    _jobEngineOwners[job.id] = engine;
    transferJobs = [job, ...transferJobs];
    _trackTransferJob(job);
    bannerTaskId = job.id;
    bannerMessage = transferBannerMessage(job);
    bannerSeverity = job.status == 'failed' || job.status == 'error'
        ? BannerSeverity.error
        : job.status == 'completed'
            ? BannerSeverity.success
            : BannerSeverity.info;
    _notifyEncryptionChanged();
    return job;
  }

  Future<void> _startClientDownloadBatch(EndpointProfile profile, String bucket,
      List<String> keys, String engine) async {
    await _requireClientEncryptionCapability(profile, engine);
    await _vaultIdentities();
    final id = 'download-batch-${DateTime.now().microsecondsSinceEpoch}';
    final destination = settings.downloadPath;
    final conflict = settings.downloadConflictPolicy;
    final threshold = settings.multipartThresholdMiB;
    final chunk = settings.multipartChunkMiB;
    final batch = DownloadBatch(
        id: id,
        keys: keys,
        engine: _engineService,
        engineId: engine,
        dispatch: (key) async {
          if (clientRuleFor(key, profile: profile, bucket: bucket) != null &&
              key.endsWith('.age')) {
            return _startClientDownload(profile, bucket, key, engine,
                attach: false);
          }
          return _engineService.startDownload(
              engineId: engine,
              profile: profile,
              bucketName: bucket,
              keys: [key],
              destinationPath: destination,
              conflictPolicy: conflict,
              multipartThresholdMiB: threshold,
              multipartChunkMiB: chunk,
              encryption: await _downloadEncryption(profile, bucket, [key]));
        },
        onUpdate: (job) {
          _jobEngineOwners[id] = engine;
          bannerTaskId = id;
          _replaceTransfer(job);
          _trackTransferJob(job);
          _notifyEncryptionChanged();
        });
    _retryTransfers[id] = () async {
      if (activeEngineId == engine &&
          selectedProfile?.id == profile.id &&
          selectedBucket?.name == bucket) {
        await startSampleDownload(keysOverride: keys);
      } else {
        showBannerMessage(
            'Select the original connection, engine and bucket before retrying.',
            severity: BannerSeverity.warning);
      }
    };
    _downloadBatch = batch;
    try {
      await batch.run();
    } finally {
      _downloadBatch = null;
      _notifyEncryptionChanged();
    }
  }

  Future<Uint8List> _fetchClientRange(
    String url,
    int start,
    int endExclusive,
    int objectSize,
    String? etag,
  ) async {
    if (start < 0 || endExclusive <= start || endExclusive > objectSize) {
      throw const FormatException('Invalid encrypted object range.');
    }
    ActionScope.current?.check();
    final client = _textPreviewClient = HttpClient()
      ..connectionTimeout = const Duration(seconds: 8);
    final releaseCancel = ActionScope.current?.onCancel(
      () => client.close(force: true),
    );
    final deadline = Timer(
      const Duration(seconds: 30),
      () => client.close(force: true),
    );
    final maximum = endExclusive - start;
    try {
      final request = await client.getUrl(Uri.parse(url));
      request.maxRedirects = 3;
      request.headers.set(
        HttpHeaders.rangeHeader,
        'bytes=$start-${endExclusive - 1}',
      );
      if (etag != null && etag.isNotEmpty) {
        request.headers.set(HttpHeaders.ifMatchHeader, etag);
      }
      final response = await request.close().timeout(
            const Duration(seconds: 15),
          );
      if (response.statusCode == HttpStatus.partialContent) {
        if (response.headers.value(HttpHeaders.contentRangeHeader) !=
            'bytes $start-${endExclusive - 1}/$objectSize') {
          throw const FormatException('Invalid encrypted preview byte range.');
        }
      } else if (response.statusCode != HttpStatus.ok ||
          start != 0 ||
          maximum != objectSize) {
        throw const FormatException(
          'The server did not honor the encrypted preview byte range.',
        );
      }
      if (response.contentLength > maximum) {
        throw const FormatException('Encrypted preview exceeds its limit.');
      }
      final output = BytesBuilder(copy: false);
      await for (final chunk in response.timeout(const Duration(seconds: 10))) {
        ActionScope.current?.check();
        if (output.length + chunk.length > maximum) {
          throw const FormatException('Encrypted preview exceeds its limit.');
        }
        output.add(chunk);
      }
      if (output.length != maximum) {
        throw const FormatException('Encrypted object range was truncated.');
      }
      ActionScope.current?.check();
      return output.takeBytes();
    } catch (_) {
      ActionScope.current?.check();
      rethrow;
    } finally {
      releaseCancel?.call();
      deadline.cancel();
      client.close(force: true);
      if (identical(_textPreviewClient, client)) _textPreviewClient = null;
    }
  }

  Future<void> _loadClientPreview(ObjectEntry object, int requestId) async {
    final profile = selectedProfile!;
    final bucket = selectedBucket!.name;
    final engine = activeEngineId;
    final visibleKey = visibleObjectKey(object);
    final contentType = _objectContentType(
      ObjectEntry(
        key: visibleKey,
        name: visibleObjectName(object),
        size: object.size,
        modifiedAt: object.modifiedAt,
        storageClass: object.storageClass,
        isFolder: false,
      ),
    );
    bool current() =>
        !_disposed &&
        activeEngineId == engine &&
        selectedProfile?.id == profile.id &&
        selectedBucket?.name == bucket &&
        _isCurrentPreviewRequest(object.key, requestId);
    ClientObjectHeader? header;
    Uint8List? bytes;
    try {
      await _vaultIdentities();
      final kind = _previewKindFor(
        ObjectEntry(
          key: visibleKey,
          name: visibleKey,
          size: object.size,
          modifiedAt: object.modifiedAt,
          storageClass: object.storageClass,
          isFolder: false,
        ),
        contentType,
      );
      if (kind != ObjectPreviewKind.text && kind != ObjectPreviewKind.image) {
        throw const EngineException(
          code: ErrorCode.unsupportedFeature,
          message: 'Download to view.',
        );
      }
      final url = await _clientObjectUrl(profile, bucket, object.key, engine);
      if (!current()) return;
      final reader = ClientObjectReader((url, start, end, size, etag) async {
        if (!current() || _encryptionKeyStore?.isUnlocked != true) {
          throw const ListingCancelled();
        }
        final bytes = await (_previewRangeFetcher ?? _fetchClientRange)(
            url, start, end, size, etag);
        if (!current() || _encryptionKeyStore?.isUnlocked != true) {
          throw const ListingCancelled();
        }
        return bytes;
      });
      header = await _openClientObject(reader, url, object, profile, bucket);
      if (!current()) return;
      if (kind == ObjectPreviewKind.image &&
          header.plaintextLength > AppController.objectPreviewImageMaxBytes) {
        throw const EngineException(
          code: ErrorCode.unsupportedFeature,
          message: 'Image is too large for inline preview. Download to view.',
        );
      }
      bytes = await reader.preview(
        url,
        object.size,
        object.etag,
        header,
        kind == ObjectPreviewKind.text
            ? AppController.objectPreviewTextByteLimit
            : AppController.objectPreviewImageMaxBytes,
      );
      if (!current() || _encryptionKeyStore?.isUnlocked != true) return;
      final truncated = bytes.length < header.plaintextLength;
      selectedObjectPreview = ObjectPreview.ready(
        key: object.key,
        kind: kind,
        contentType: contentType,
        text: kind == ObjectPreviewKind.text
            ? const Utf8Decoder(allowMalformed: true).convert(bytes)
            : null,
        bytes: kind == ObjectPreviewKind.image ? bytes : null,
        loadedBytes: bytes.length,
        truncated: truncated,
        message: truncated
            ? 'Showing the first ${bytes.length} bytes.'
            : 'Preview loaded.',
      );
      if (kind == ObjectPreviewKind.image) {
        bytes = null; // owned by the preview until cleared
      }
    } catch (error) {
      if (current()) {
        selectedObjectPreview = ObjectPreview.unsupported(
          key: object.key,
          contentType: contentType,
          message: error is EngineException
              ? error.message
              : error is AgeAuthenticationException
                  ? 'Integrity check failed. The encrypted object is corrupt or was modified.'
                  : 'Cannot decrypt this object. Download an encrypted copy to inspect it with age.',
        );
      }
    } finally {
      header?.dispose();
      if (bytes != null) ageWipe(bytes);
    }
    if (current()) _notifyEncryptionChanged();
  }
}
