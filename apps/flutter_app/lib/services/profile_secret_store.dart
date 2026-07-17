import 'dart:io';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

class ProfileSecretStore {
  static const _configuredMacKeychainMode = String.fromEnvironment(
    'OBJECT_BROWSER_MAC_KEYCHAIN_MODE',
    defaultValue: 'legacy',
  );

  ProfileSecretStore({
    FlutterSecureStorage? storage,
    FlutterSecureStorage? fallbackMacStorage,
    bool? useDataProtectionMacKeychain,
  })  : _storage = storage ??
            FlutterSecureStorage(
              mOptions: MacOsOptions(
                usesDataProtectionKeychain: useDataProtectionMacKeychain ??
                    _configuredMacKeychainMode == 'data-protection',
              ),
            ),
        _fallbackMacStorage = fallbackMacStorage ??
            const FlutterSecureStorage(
              mOptions: MacOsOptions(usesDataProtectionKeychain: true),
            ),
        _primaryUsesDataProtection = useDataProtectionMacKeychain ??
            _configuredMacKeychainMode == 'data-protection';

  final FlutterSecureStorage _storage;
  final FlutterSecureStorage _fallbackMacStorage;
  final bool _primaryUsesDataProtection;

  /// The legacy file-based macOS Keychain rejects this plugin's bulk
  /// data-and-attributes query with errSecParam. Single-item access remains
  /// supported, while bulk migration is limited to Data Protection stores.
  bool get supportsPrimaryBulkRead =>
      !Platform.isMacOS || _primaryUsesDataProtection;

  bool get supportsFallbackBulkRead =>
      !Platform.isMacOS || !_primaryUsesDataProtection;

  Future<void> saveSecret(String key, String value) {
    return _storage.write(key: key, value: value);
  }

  Future<String?> readSecret(String key) {
    return _storage.read(key: key);
  }

  /// Reads all values with one native Keychain query. This is used only to
  /// migrate the legacy per-field profile items into the consolidated bundle.
  Future<Map<String, String>> readAllSecrets() {
    return _storage.readAll();
  }

  /// Reads from the other macOS Keychain implementation during migration.
  /// Signed releases use Data Protection as primary and legacy as fallback;
  /// ad-hoc development builds use the reverse order.
  Future<String?> readFallbackMacSecret(String key) {
    if (!Platform.isMacOS) return Future.value();
    return _fallbackMacStorage.read(
      key: key,
      mOptions: MacOsOptions(
        usesDataProtectionKeychain: !_primaryUsesDataProtection,
      ),
    );
  }

  Future<Map<String, String>> readAllFallbackMacSecrets() {
    if (!Platform.isMacOS) return Future.value(const {});
    return _fallbackMacStorage.readAll(
      mOptions: MacOsOptions(
        usesDataProtectionKeychain: !_primaryUsesDataProtection,
      ),
    );
  }

  Future<void> deleteSecret(String key) {
    return _storage.delete(key: key);
  }
}
