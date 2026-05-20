import 'package:flutter_secure_storage/flutter_secure_storage.dart';

class ProfileSecretStore {
  ProfileSecretStore({
    FlutterSecureStorage? storage,
  }) : _storage = storage ?? const FlutterSecureStorage();

  final FlutterSecureStorage _storage;
  static const MacOsOptions _macOsOptions = MacOsOptions(
    useDataProtectionKeyChain: false,
  );

  Future<void> saveSecret(String key, String value) {
    return _storage.write(key: key, value: value, mOptions: _macOsOptions);
  }

  Future<String?> readSecret(String key) {
    return _storage.read(key: key, mOptions: _macOsOptions);
  }

  Future<void> deleteSecret(String key) {
    return _storage.delete(key: key, mOptions: _macOsOptions);
  }
}
