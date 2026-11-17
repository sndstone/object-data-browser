part of 'app_controller.dart';

extension AppControllerEncryption on AppController {
  EncryptionKeyStore? get encryptionKeyStore => _encryptionKeyStore;
  List<EncryptionKeyRecord> get encryptionKeys =>
      _encryptionKeyStore?.isUnlocked == true
          ? _encryptionKeyStore!.records
          : const [];

  Future<EncryptionKeyStore> ensureEncryptionKeyStore() async {
    if (_encryptionKeyStore != null) {
      encryptionKeyFileExists = await _encryptionKeyStore!.exists();
      _ensureKeyFileSync();
      return _encryptionKeyStore!;
    }
    return _encryptionKeyStoreFuture ??= () async {
      final repository = _appStateRepository;
      final file = await (repository is LocalAppStateRepository
              ? repository
              : LocalAppStateRepository())
          .encryptionKeyFile();
      if (settings.keyFileDeviceId.isEmpty) {
        settings = settings.copyWith(
            keyFileDeviceId: EncryptionKeyStore.newDeviceId());
        await _persistState();
      }
      final store =
          EncryptionKeyStore(file, deviceId: settings.keyFileDeviceId);
      _encryptionKeyStore = store;
      store.addListener(_nameKeysChanged);
      _nameKeysChanged();
      _ensureKeyFileSync();
      encryptionKeyFileExists = await store.exists();
      if (_disposed) store.lock();
      _notifyEncryptionChanged();
      return store;
    }();
  }

  Future<void> updateEncryptionKeys(
    Future<void> Function(EncryptionKeyStore) action,
  ) async {
    final store = await ensureEncryptionKeyStore();
    try {
      await action(store);
      await _nameKeysLoading;
    } finally {
      encryptionKeyFileExists = await store.exists();
      if (_disposed) store.lock();
      _notifyEncryptionChanged();
    }
  }

  KeyFileSync? get keyFileSync => _keyFileSync;

  void _ensureKeyFileSync() {
    final config = settings.keyFileSync;
    final store = _encryptionKeyStore;
    if (_disposed ||
        _credentialStoreError != null ||
        config == null ||
        store == null ||
        _keyFileSync != null) {
      return;
    }
    final profile = profiles.where((p) => p.id == config.profileId).firstOrNull;
    if (profile == null || keyFileSyncProfileIneligibility(profile) != null) {
      return;
    }
    final sync = KeyFileSync(
        store: store,
        config: config,
        transport: _keyFileSyncTransportFactory(profile),
        state: settings.keyFileSyncState,
        onChanged: _notifyEncryptionChanged,
        onStateChanged: (state) async {
          if (_disposed || !identical(settings.keyFileSync, config)) return;
          settings = settings.copyWith(keyFileSyncState: state);
          await _persistState();
        });
    _keyFileSync = sync;
    if (store.isUnlocked) sync.requestSync();
  }

  KeyFileSyncSetupTransport createKeyFileSyncSetupTransport(
      EndpointProfile profile) {
    if (_credentialStoreError != null) {
      throw const KeyFileSyncException(
          'Save the sync profile credentials securely before setting up sync.');
    }
    final transport = _keyFileSyncTransportFactory(profile);
    if (transport is KeyFileSyncSetupTransport) return transport;
    transport.close();
    throw const KeyFileSyncException('Bucket setup is unavailable.');
  }

  Future<void> configureKeyFileSync(KeyFileSyncConfig config) async {
    if (_credentialStoreError != null) {
      throw const KeyFileSyncException(
          'Save the sync profile credentials securely before setting up sync.');
    }
    final store = await ensureEncryptionKeyStore();
    if (!store.isUnlocked) throw const EncryptionKeyStoreLockedException();
    if (!store.passphraseMeetsSyncPolicy) {
      throw const KeyFileSyncException(
          'Change the key file passphrase to at least 16 characters to turn on sync.');
    }
    final profile = profiles.where((p) => p.id == config.profileId).firstOrNull;
    if (profile == null) {
      throw const KeyFileSyncException('Choose an existing profile.');
    }
    final reason = keyFileSyncProfileIneligibility(profile);
    if (reason != null) throw KeyFileSyncException(reason);
    if (config.bucket.trim().isEmpty || config.objectKey.trim().isEmpty) {
      throw const KeyFileSyncException('Choose a bucket and object key.');
    }
    _keyFileSync?.dispose();
    _keyFileSync = null;
    settings = settings.copyWith(
        keyFileSync: config, keyFileSyncState: const KeyFileSyncState());
    await _persistState();
    _ensureKeyFileSync();
    await _keyFileSync?.refreshVersioning();
    _keyFileSync?.requestSync();
    _notifyEncryptionChanged();
  }

  Future<void> turnOffKeyFileSync() async {
    _keyFileSync?.dispose();
    _keyFileSync = null;
    settings = settings.copyWith(
        clearKeyFileSync: true, keyFileSyncState: const KeyFileSyncState());
    await _persistState();
    _notifyEncryptionChanged();
  }

  void lockEncryptionKeyFile() {
    _encryptionKeyStore?.lock();
    _clearClientPreviewBytes();
    _cancelTextPreview();
    if (selectedObject != null && isClientEncrypted(selectedObject!)) {
      selectedObjectPreview = ObjectPreview.unsupported(
        key: selectedObject!.key,
        message: 'Unlock your encryption key file to decrypt this object.',
      );
    }
    _notifyEncryptionChanged();
  }

  EncryptionKeyRecord? matchingEncryptionKey(ObjectEncryptionInfo info) =>
      encryptionKeys
          .where(
            (key) =>
                key.type == EncryptionKeyType.customerKey &&
                ((info.customerKeyMd5 != null &&
                        key.md5Base64 == info.customerKeyMd5) ||
                    (info.customerKeySha256 != null &&
                        key.fingerprint == info.customerKeySha256)),
          )
          .firstOrNull;

  String _encryptionIdentity(EndpointProfile p, String bucket, String key) =>
      jsonEncode([p.id, bucket, key]);

  bool _usesCustomerEncryption(
    EndpointProfile profile,
    String bucket,
    String key,
  ) {
    final identity = _encryptionIdentity(profile, bucket, key);
    return _objectEncryption[identity]?.isCustomerKey == true ||
        _customerKeyRequiredObjects.contains(identity);
  }

  Future<void> _requireEncryptionCapability(
    EndpointProfile profile,
    String engineId,
    ObjectEncryption encryption,
  ) async {
    if (encryption.mode == ObjectEncryptionMode.bucketDefault) return;
    final supported = await _engineService.getCapabilities(
      engineId: engineId,
      profile: profile,
    );
    if (!supported.any(
      (capability) =>
          capability.key == 'object.encryption.${encryption.mode.wireName}' &&
          capability.state == CapabilityState.supported,
    )) {
      throw EngineException(
        code: ErrorCode.unsupportedFeature,
        message:
            'The selected engine does not support ${encryption.mode.label}. Choose a supported engine or change Upload encryption.',
      );
    }
  }

  Future<ObjectEncryption?> _effectiveUploadEncryption(
    EndpointProfile profile,
    String engineId,
  ) async {
    final encryption = profile.uploadEncryption;
    if (encryption == null ||
        encryption.mode == ObjectEncryptionMode.bucketDefault) {
      return null;
    }
    if (encryption.mode.isCustomerKey) {
      final store = await ensureEncryptionKeyStore();
      if (!store.isUnlocked ||
          !store.records.any(
            (key) =>
                key.id == encryption.customerKeyId &&
                key.type == EncryptionKeyType.customerKey &&
                (encryption.customerKeyFingerprint == null ||
                    key.fingerprint == encryption.customerKeyFingerprint),
          )) {
        throw const EncryptionDispatchException();
      }
    }
    await _requireEncryptionCapability(profile, engineId, encryption);
    return encryption;
  }

  ObjectEncryption? _preservedEncryption(ObjectEncryptionInfo? info) {
    if (info == null || info.mode == 'provider') return null;
    if (info.isCustomerKey) {
      if (encryptionKeyFileExists && _encryptionKeyStore?.isUnlocked != true) {
        throw const EncryptionDispatchException();
      }
      final key = matchingEncryptionKey(info);
      if (key == null) {
        throw const EngineException(
          code: ErrorCode.invalidConfig,
          message:
              'This object is encrypted with a customer key that is not in your key file.',
        );
      }
      return ObjectEncryption(
        mode: ObjectEncryptionMode.parse(info.mode),
        customerKeyId: key.id,
        customerKeyFingerprint: key.fingerprint,
      );
    }
    return ObjectEncryption(
      mode: ObjectEncryptionMode.parse(info.mode),
      kmsKeyId: info.kmsKeyId,
      bucketKeyEnabled: info.mode == 'sse-kms' ? info.bucketKeyEnabled : null,
      encryptionScope: info.encryptionScope,
    );
  }

  Future<ObjectDetails> _loadEncryptedObjectDetails({
    required String engineId,
    required EndpointProfile profile,
    required String bucketName,
    required String key,
  }) async {
    final identity = _encryptionIdentity(profile, bucketName, key);
    final known = _objectEncryption[identity];
    if (known?.isCustomerKey == true) await ensureEncryptionKeyStore();
    ObjectEncryption? encryption =
        known?.isCustomerKey == true ? _preservedEncryption(known) : null;
    Future<ObjectDetails> load() => _engineService.getObjectDetails(
          engineId: engineId,
          profile: profile,
          bucketName: bucketName,
          key: key,
          encryption: encryption,
        );
    if (encryption != null) {
      await _requireEncryptionCapability(profile, engineId, encryption);
    }
    ObjectDetails details;
    try {
      details = await load();
    } on EngineException catch (error) {
      if (error.details?['encryptionHint'] != 'sse_c_key_required' ||
          encryption != null) {
        rethrow;
      }
      _customerKeyRequiredObjects.add(identity);
      final configured = profile.uploadEncryption;
      if (configured?.mode.isCustomerKey != true) {
        throw const EngineException(
          code: ErrorCode.invalidConfig,
          message:
              'This object is encrypted with a customer key: choose or unlock a key.',
          details: {'encryptionHint': 'sse_c_key_required'},
        );
      }
      encryption = configured;
      await _requireEncryptionCapability(profile, engineId, encryption!);
      details = await load(); // Exactly one retry, and only for this read.
    }
    if (details.encryption != null) {
      if (!details.encryption!.isCustomerKey) {
        _customerKeyRequiredObjects.remove(identity);
      }
      _objectEncryption[identity] = details.encryption!;
    } else {
      _objectEncryption.remove(identity);
    }
    return details;
  }

  Future<List<({List<String> keys, ObjectEncryption? encryption})>>
      _downloadEncryptionGroups(
    EndpointProfile profile,
    String bucket,
    List<String> keys,
  ) async {
    final groups =
        <String, ({List<String> keys, ObjectEncryption? encryption})>{};
    for (final key in keys) {
      final encryption = await _downloadEncryption(profile, bucket, [key]);
      final identity = jsonEncode(encryption?.toJson());
      final group = groups.putIfAbsent(
        identity,
        () => (keys: <String>[], encryption: encryption),
      );
      group.keys.add(key);
    }
    return groups.values.toList();
  }

  Future<ObjectEncryption?> _downloadEncryption(
    EndpointProfile profile,
    String bucket,
    List<String> keys,
  ) async {
    ObjectEncryption? encryption;
    for (final key in keys) {
      if (!_objectEncryption.containsKey(
            _encryptionIdentity(profile, bucket, key),
          ) &&
          profile.uploadEncryption?.mode.isCustomerKey == true) {
        await _loadEncryptedObjectDetails(
          engineId: activeEngineId,
          profile: profile,
          bucketName: bucket,
          key: key,
        );
      }
      final identity = _encryptionIdentity(profile, bucket, key);
      if (_customerKeyRequiredObjects.contains(identity) &&
          profile.uploadEncryption?.mode.isCustomerKey != true &&
          _objectEncryption[identity] == null) {
        throw const EngineException(
          code: ErrorCode.invalidConfig,
          message:
              'This object is encrypted with a customer key: choose or unlock a key.',
          details: {'encryptionHint': 'sse_c_key_required'},
        );
      }
      final info = _objectEncryption[identity];
      if (info?.isCustomerKey == true) {
        await ensureEncryptionKeyStore();
        final next = _preservedEncryption(info)!;
        await _requireEncryptionCapability(profile, activeEngineId, next);
        if (encryption != null &&
            encryption.customerKeyId != next.customerKeyId) {
          throw const EngineException(
            code: ErrorCode.invalidConfig,
            message:
                'Download objects with different customer keys separately.',
          );
        }
        encryption = next;
      }
    }
    return encryption;
  }
}
