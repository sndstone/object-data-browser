import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

import '../models/domain_models.dart';
import 'profile_secret_store.dart';

class StoredAppState {
  const StoredAppState({
    required this.settings,
    required this.profiles,
    required this.selectedProfileId,
    this.credentialStoreError,
  });

  final AppSettings settings;
  final List<EndpointProfile> profiles;
  final String? selectedProfileId;
  final String? credentialStoreError;
}

abstract class AppStateRepository {
  Future<StoredAppState?> loadState();

  Future<void> saveState({
    required AppSettings settings,
    required List<EndpointProfile> profiles,
    required String? selectedProfileId,
    bool allowCredentialStoreRecovery = false,
  });

  Future<File> exportProfiles({
    required List<EndpointProfile> profiles,
    required String path,
  });

  Future<List<EndpointProfile>> importProfiles(String path);
}

class LocalAppStateRepository implements AppStateRepository {
  static const _profileSecretBundleKey = 'profiles.credentials.v2';
  static const _macBundleId = 'com.example.s3BrowserCrossplat';
  static const _stateFileName = 'object-data-browser-state.json';

  LocalAppStateRepository({
    ProfileSecretStore? secretStore,
    Future<Directory> Function()? applicationSupportDirectoryProvider,
  })  : _secretStore = secretStore ?? ProfileSecretStore(),
        _applicationSupportDirectoryProvider =
            applicationSupportDirectoryProvider ??
                getApplicationSupportDirectory;

  final ProfileSecretStore _secretStore;
  final Future<Directory> Function() _applicationSupportDirectoryProvider;
  String? _persistedSecretBundleJson;
  bool _secureStoreLoadFailed = false;
  String? _credentialStoreError;

  @override
  Future<StoredAppState?> loadState() async {
    final file = await _stateFileForLoad();
    if (!await file.exists()) {
      return null;
    }
    final decoded =
        jsonDecode(await file.readAsString()) as Map<String, Object?>;
    final settingsJson =
        Map<String, Object?>.from(decoded['settings'] as Map? ?? const {});
    final profilesJson = (decoded['profiles'] as List<Object?>? ?? const [])
        .map((item) => Map<String, Object?>.from(item as Map))
        .toList();
    final secretsByProfile = await _loadProfileSecretBundle(
      hasStoredProfiles: profilesJson.isNotEmpty,
    );
    final profiles = <EndpointProfile>[];
    for (final metadata in profilesJson) {
      profiles.add(_hydrateProfile(metadata, secretsByProfile));
    }
    return StoredAppState(
      settings: AppSettings.fromJson(settingsJson),
      profiles: profiles,
      selectedProfileId: decoded['selectedProfileId'] as String?,
      credentialStoreError: _credentialStoreError,
    );
  }

  @override
  Future<void> saveState({
    required AppSettings settings,
    required List<EndpointProfile> profiles,
    required String? selectedProfileId,
    bool allowCredentialStoreRecovery = false,
  }) async {
    final file = await _stateFile();
    final persistedToSecureStore = await _writeProfileSecretBundle(
      profiles,
      allowRecovery: allowCredentialStoreRecovery,
    );
    if (!persistedToSecureStore) {
      throw StateError(
        'Secure credential storage is unavailable. Profile secrets were not saved to local plaintext state.',
      );
    }

    await file.parent.create(recursive: true);
    await file.writeAsString(
      const JsonEncoder.withIndent('  ').convert({
        'settings': settings.toJson(),
        'selectedProfileId': selectedProfileId,
        'profiles': profiles
            .map((profile) => _profileMetadataToJson(
                  profile,
                ))
            .toList(),
      }),
    );
  }

  @override
  Future<File> exportProfiles({
    required List<EndpointProfile> profiles,
    required String path,
  }) async {
    final file = File(path);
    await file.parent.create(recursive: true);
    await file.writeAsString(
      const JsonEncoder.withIndent('  ').convert({
        'exportedAt': DateTime.now().toIso8601String(),
        'profiles':
            profiles.map((profile) => _profileToExportJson(profile)).toList(),
      }),
    );
    return file;
  }

  @override
  Future<List<EndpointProfile>> importProfiles(String path) async {
    final file = File(path);
    final decoded = jsonDecode(await file.readAsString());
    final profilesJson = decoded is List<Object?>
        ? decoded
        : (decoded as Map<String, Object?>)['profiles'] as List<Object?>? ??
            const [];
    return profilesJson
        .map((item) =>
            EndpointProfile.fromJson(Map<String, Object?>.from(item as Map)))
        .toList();
  }

  Future<File> _stateFile() async {
    final supportDir = await _applicationSupportDirectoryProvider();
    return File(
      '${supportDir.path}${Platform.pathSeparator}$_stateFileName',
    );
  }

  Future<File> _stateFileForLoad() async {
    final primary = await _stateFile();
    final alternate = _alternateMacStateFile(primary);
    if (alternate == null || !await alternate.exists()) return primary;
    if (!await primary.exists()) return alternate;
    final primaryModified = await primary.lastModified();
    final alternateModified = await alternate.lastModified();
    return alternateModified.isAfter(primaryModified) ? alternate : primary;
  }

  File? _alternateMacStateFile(File primary) {
    if (!Platform.isMacOS) return null;
    const containersMarker = '/Library/Containers/';
    const supportMarker = '/Library/Application Support/';
    final path = primary.path;
    if (path.contains(containersMarker)) {
      final home = path.substring(0, path.indexOf(containersMarker));
      return File(
        '$home/Library/Application Support/$_macBundleId/$_stateFileName',
      );
    }
    if (path.contains(supportMarker)) {
      final home = path.substring(0, path.indexOf(supportMarker));
      return File(
        '$home/Library/Containers/$_macBundleId/Data/Library/Application Support/$_macBundleId/$_stateFileName',
      );
    }
    return null;
  }

  EndpointProfile _hydrateProfile(
    Map<String, Object?> metadata,
    Map<String, Map<String, String?>> secretsByProfile,
  ) {
    final id = (metadata['id'] as String?) ?? '';
    final secrets = secretsByProfile[id] ?? const <String, String?>{};
    return EndpointProfile.fromJson({
      ...metadata,
      'accessKey': secrets['accessKey'] ?? '',
      'secretKey': secrets['secretKey'] ?? '',
      'sessionToken': secrets['sessionToken'],
    });
  }

  /// Serializes a profile for an exported file with all credentials stripped.
  /// Secrets are never written to a shareable export; keys stay present but
  /// empty so an exported file can be re-imported without crashing. Users
  /// re-enter credentials after importing.
  Map<String, Object?> _profileToExportJson(EndpointProfile profile) {
    final json = profile.toJson();
    json['accessKey'] = '';
    json['secretKey'] = '';
    json['sessionToken'] = null;
    return json;
  }

  Future<Map<String, Map<String, String?>>> _loadProfileSecretBundle({
    required bool hasStoredProfiles,
  }) async {
    String? bundleJson;
    Object? primaryReadError;
    try {
      bundleJson = await _secretStore.readSecret(_profileSecretBundleKey);
    } catch (error) {
      primaryReadError = error;
    }

    if (bundleJson != null && bundleJson.isNotEmpty) {
      try {
        final decoded = _decodeProfileSecretBundle(bundleJson);
        _persistedSecretBundleJson = _encodeProfileSecretBundle(decoded);
        return decoded;
      } catch (error) {
        _recordSecureStoreFailure(error);
        return const {};
      }
    }

    // Check the non-primary Keychain implementation before scanning old
    // per-field entries. Signed releases migrate legacy items into Data
    // Protection; ad-hoc development builds support the reverse transition.
    try {
      final fallbackBundle =
          await _secretStore.readFallbackMacSecret(_profileSecretBundleKey);
      if (fallbackBundle != null && fallbackBundle.isNotEmpty) {
        final decoded = _decodeProfileSecretBundle(fallbackBundle);
        await _persistMigratedBundle(decoded);
        if (primaryReadError != null) {
          _recordSecureStoreFailure(primaryReadError);
        }
        return decoded;
      }
    } catch (_) {
      // The alternate Keychain is a best-effort migration source.
    }

    Map<String, Map<String, String?>> migrated = const {};
    if (primaryReadError == null && _secretStore.supportsPrimaryBulkRead) {
      try {
        // One SecItemCopyMatching call replaces three reads per profile and
        // gives macOS one authorization boundary during migration.
        migrated = _legacyProfileSecrets(await _secretStore.readAllSecrets());
      } catch (error) {
        primaryReadError = error;
      }
    }
    if (migrated.isEmpty && _secretStore.supportsFallbackBulkRead) {
      try {
        migrated = _legacyProfileSecrets(
          await _secretStore.readAllFallbackMacSecrets(),
        );
      } catch (_) {
        // The alternate Keychain is a best-effort migration source.
      }
    }

    if (primaryReadError != null) {
      _recordSecureStoreFailure(primaryReadError);
    }
    if (migrated.isNotEmpty) {
      await _persistMigratedBundle(migrated);
    } else {
      _persistedSecretBundleJson = _encodeProfileSecretBundle(const {});
      if (primaryReadError == null && hasStoredProfiles) {
        _recordCredentialMigrationRequired();
      }
    }
    return migrated;
  }

  Future<void> _persistMigratedBundle(
    Map<String, Map<String, String?>> migrated,
  ) async {
    if (_secureStoreLoadFailed) return;
    final migratedJson = _encodeProfileSecretBundle(migrated);
    try {
      await _secretStore.saveSecret(_profileSecretBundleKey, migratedJson);
      _persistedSecretBundleJson = migratedJson;
    } catch (error) {
      _recordSecureStoreFailure(error);
    }
  }

  void _recordSecureStoreFailure(Object error) {
    _secureStoreLoadFailed = true;
    final detail = _secureStoreErrorDetail(error);
    _credentialStoreError =
        'macOS Keychain access failed${detail.isEmpty ? '' : ' ($detail)'}. '
        'Credentials were not loaded. Open Settings, re-enter them, and save to repair secure storage.';
  }

  void _recordCredentialMigrationRequired() {
    _secureStoreLoadFailed = true;
    _credentialStoreError =
        'Existing profile credentials could not be migrated safely from the legacy macOS Keychain. '
        'Open Settings, re-enter each profile\'s access and secret keys, and press Save once.';
  }

  String _secureStoreErrorDetail(Object error) {
    if (error is PlatformException) {
      final message = error.message?.replaceAll(RegExp(r'\s+'), ' ').trim();
      return message == null || message.isEmpty
          ? error.code
          : '${error.code}: $message';
    }
    return error.runtimeType.toString();
  }

  Future<bool> _writeProfileSecretBundle(
    List<EndpointProfile> profiles, {
    required bool allowRecovery,
  }) async {
    if (_secureStoreLoadFailed && !allowRecovery) return false;
    final secretsByProfile = <String, Map<String, String?>>{
      for (final profile in profiles)
        profile.id: <String, String?>{
          'accessKey': profile.accessKey,
          'secretKey': profile.secretKey,
          'sessionToken': (profile.sessionToken ?? '').isEmpty
              ? null
              : profile.sessionToken,
        },
    };
    final bundleJson = _encodeProfileSecretBundle(secretsByProfile);
    if (!_secureStoreLoadFailed && _persistedSecretBundleJson == bundleJson) {
      return true;
    }
    try {
      await _secretStore.saveSecret(_profileSecretBundleKey, bundleJson);
      _persistedSecretBundleJson = bundleJson;
      _secureStoreLoadFailed = false;
      _credentialStoreError = null;
      return true;
    } catch (_) {
      return false;
    }
  }

  String _encodeProfileSecretBundle(
    Map<String, Map<String, String?>> secretsByProfile,
  ) {
    final sortedIds = secretsByProfile.keys.toList()..sort();
    return jsonEncode(<String, Object?>{
      'version': 2,
      'profiles': <String, Object?>{
        for (final id in sortedIds) id: secretsByProfile[id],
      },
    });
  }

  Map<String, Map<String, String?>> _decodeProfileSecretBundle(String value) {
    final decoded = jsonDecode(value) as Map<String, Object?>;
    final profiles =
        Map<String, Object?>.from(decoded['profiles'] as Map? ?? const {});
    return <String, Map<String, String?>>{
      for (final entry in profiles.entries)
        entry.key:
            _credentialFields(Map<String, Object?>.from(entry.value as Map)),
    };
  }

  Map<String, Map<String, String?>> _legacyProfileSecrets(
    Map<String, String> items,
  ) {
    final result = <String, Map<String, String?>>{};
    final pattern =
        RegExp(r'^profile\.(.+)\.(accessKey|secretKey|sessionToken)$');
    for (final entry in items.entries) {
      final match = pattern.firstMatch(entry.key);
      if (match == null) continue;
      final profileId = match.group(1)!;
      final field = match.group(2)!;
      result.putIfAbsent(profileId, () => <String, String?>{})[field] =
          entry.value;
    }
    return <String, Map<String, String?>>{
      for (final entry in result.entries)
        entry.key: _credentialFields(entry.value),
    };
  }

  Map<String, String?> _credentialFields(Map<dynamic, dynamic> value) {
    return <String, String?>{
      'accessKey': value['accessKey'] as String? ?? '',
      'secretKey': value['secretKey'] as String? ?? '',
      'sessionToken': value['sessionToken'] as String?,
    };
  }

  Map<String, Object?> _profileMetadataToJson(
    EndpointProfile profile,
  ) {
    return <String, Object?>{
      'id': profile.id,
      'name': profile.name,
      'endpointUrl': profile.endpointUrl,
      'region': profile.region,
      'endpointType': profile.endpointType.name,
      'pathStyle': profile.pathStyle,
      'verifyTls': profile.verifyTls,
      'signerOverride': profile.signerOverride,
      'notes': profile.notes,
      'connectTimeoutSeconds': profile.connectTimeoutSeconds,
      'readTimeoutSeconds': profile.readTimeoutSeconds,
      'maxConcurrentRequests': profile.maxConcurrentRequests,
      'maxAttempts': profile.maxAttempts,
      'maxRequestsPerSecond': profile.maxRequestsPerSecond,
    };
  }
}
