import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:s3_browser_crossplat/models/domain_models.dart';
import 'package:s3_browser_crossplat/services/app_state_repository.dart';
import 'package:s3_browser_crossplat/services/profile_secret_store.dart';

class _Secrets extends ProfileSecretStore {
  final values = <String, String>{};
  @override
  bool get supportsPrimaryBulkRead => true;
  @override
  bool get supportsFallbackBulkRead => true;
  @override
  Future<String?> readSecret(String key) async => values[key];
  @override
  Future<void> saveSecret(String key, String value) async {
    values[key] = value;
  }

  @override
  Future<void> deleteSecret(String key) async {
    values.remove(key);
  }

  @override
  Future<Map<String, String>> readAllSecrets() async => Map.of(values);
  @override
  Future<String?> readFallbackMacSecret(String key) async => null;
  @override
  Future<Map<String, String>> readAllFallbackMacSecrets() async => {};
}

void main() {
  test(
      'sync metadata persists through repository; state and exports exclude secrets',
      () async {
    final directory = await Directory.systemTemp.createTemp('key-sync-state-');
    try {
      final repository = LocalAppStateRepository(
          secretStore: _Secrets(),
          applicationSupportDirectoryProvider: () async => directory);
      const profile = EndpointProfile(
          id: 'p',
          name: 'Sync S3',
          endpointUrl: 'https://example.test',
          region: 'us-east-1',
          accessKey: 'private-access-marker',
          secretKey: 'private-secret-marker',
          pathStyle: true,
          verifyTls: true);
      final settings = AppSettings.fromJson({}).copyWith(
          keyFileDeviceId: '0123456789abcdef',
          keyFileSync: const KeyFileSyncConfig(profileId: 'p', bucket: 'keys'),
          keyFileSyncState: KeyFileSyncState(
              etag: 'etag',
              versionId: 'v1',
              lastSyncedAt: DateTime.utc(2026, 11, 15),
              syncedClock: 8,
              conditionalWrites: false,
              versioningEnabled: true));
      await repository.saveState(
          settings: settings, profiles: [profile], selectedProfileId: 'p');
      final loaded = (await repository.loadState())!;
      expect(loaded.settings.keyFileDeviceId, settings.keyFileDeviceId);
      expect(loaded.settings.keyFileSync!.toJson(),
          settings.keyFileSync!.toJson());
      expect(loaded.settings.keyFileSyncState.toJson(),
          settings.keyFileSyncState.toJson());
      final export = await repository.exportProfiles(
          profiles: [profile], path: '${directory.path}/export.json');
      for (final file in [
        File('${directory.path}/object-data-browser-state.json'),
        export
      ]) {
        final text = await file.readAsString();
        expect(text, isNot(contains(profile.accessKey)));
        expect(text, isNot(contains(profile.secretKey)));
        expect(text, isNot(contains('AGE-SECRET-KEY-1')));
        expect(text, isNot(contains('"passphrase"')));
      }
      final exported = jsonDecode(await export.readAsString()) as Map;
      final exportedProfile = (exported['profiles'] as List).single as Map;
      expect(exportedProfile['accessKey'], '');
      expect(exportedProfile['secretKey'], '');
      // Older files contain no sync keys and keep sync off.
      await File('${directory.path}/object-data-browser-state.json')
          .writeAsString(jsonEncode({'settings': {}, 'profiles': []}));
      final old = (await repository.loadState())!;
      expect(old.settings.keyFileSync, isNull);
      expect(old.settings.keyFileSyncState.lastSyncedAt, isNull);
    } finally {
      await directory.delete(recursive: true);
    }
  });
}
