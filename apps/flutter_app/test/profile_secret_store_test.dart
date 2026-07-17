import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:s3_browser_crossplat/services/profile_secret_store.dart';

class RecordingFlutterSecureStorage extends FlutterSecureStorage {
  AppleOptions? lastReadOptions;
  AppleOptions? lastReadAllOptions;

  @override
  Future<String?> read({
    required String key,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) async {
    lastReadOptions = mOptions;
    return null;
  }

  @override
  Future<Map<String, String>> readAll({
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) async {
    lastReadAllOptions = mOptions;
    return const {};
  }
}

void main() {
  test('signed macOS mode migrates from the legacy Keychain', () async {
    final fallback = RecordingFlutterSecureStorage();
    final store = ProfileSecretStore(
      fallbackMacStorage: fallback,
      useDataProtectionMacKeychain: true,
    );

    expect(store.supportsPrimaryBulkRead, isTrue);
    expect(store.supportsFallbackBulkRead, isFalse);

    await store.readFallbackMacSecret('key');
    await store.readAllFallbackMacSecrets();

    expect(
      fallback.lastReadOptions?.toMap()['usesDataProtectionKeychain'],
      'false',
    );
    expect(
      fallback.lastReadAllOptions?.toMap()['usesDataProtectionKeychain'],
      'false',
    );
  });

  test('ad-hoc macOS mode migrates from the Data Protection Keychain',
      () async {
    final fallback = RecordingFlutterSecureStorage();
    final store = ProfileSecretStore(
      fallbackMacStorage: fallback,
      useDataProtectionMacKeychain: false,
    );

    expect(store.supportsPrimaryBulkRead, isFalse);
    expect(store.supportsFallbackBulkRead, isTrue);

    await store.readFallbackMacSecret('key');

    expect(
      fallback.lastReadOptions?.toMap()['usesDataProtectionKeychain'],
      'true',
    );
  });
}
