import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

import '../models/domain_models.dart';
import 'profile_secret_store.dart';

class StoredAppState {
  const StoredAppState({
    required this.settings,
    required this.profiles,
    required this.selectedProfileId,
  });

  final AppSettings settings;
  final List<EndpointProfile> profiles;
  final String? selectedProfileId;
}

abstract class AppStateRepository {
  Future<StoredAppState?> loadState();

  Future<void> saveState({
    required AppSettings settings,
    required List<EndpointProfile> profiles,
    required String? selectedProfileId,
  });

  Future<File> exportProfiles({
    required List<EndpointProfile> profiles,
    required String path,
  });

  Future<List<EndpointProfile>> importProfiles(String path);
}

class LocalAppStateRepository implements AppStateRepository {
  LocalAppStateRepository({
    ProfileSecretStore? secretStore,
    Future<Directory> Function()? applicationSupportDirectoryProvider,
  })  : _secretStore = secretStore ?? ProfileSecretStore(),
        _applicationSupportDirectoryProvider =
            applicationSupportDirectoryProvider ??
                getApplicationSupportDirectory;

  final ProfileSecretStore _secretStore;
  final Future<Directory> Function() _applicationSupportDirectoryProvider;

  @override
  Future<StoredAppState?> loadState() async {
    final file = await _stateFile();
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
    final profiles = <EndpointProfile>[];
    for (final metadata in profilesJson) {
      profiles.add(await _hydrateProfile(metadata));
    }
    return StoredAppState(
      settings: AppSettings.fromJson(settingsJson),
      profiles: profiles,
      selectedProfileId: decoded['selectedProfileId'] as String?,
    );
  }

  @override
  Future<void> saveState({
    required AppSettings settings,
    required List<EndpointProfile> profiles,
    required String? selectedProfileId,
  }) async {
    final file = await _stateFile();
    final previousIds = await _storedProfileIds(file);
    final nextIds = profiles.map((profile) => profile.id).toSet();

    for (final profile in profiles) {
      final persistedToSecureStore = await _writeProfileSecrets(profile);
      if (!persistedToSecureStore) {
        throw StateError(
          'Secure credential storage is unavailable. Profile secrets were not saved to local plaintext state.',
        );
      }
    }
    for (final removedId in previousIds.difference(nextIds)) {
      await _deleteProfileSecrets(removedId);
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
        'profiles': profiles.map((profile) => profile.toJson()).toList(),
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
      '${supportDir.path}${Platform.pathSeparator}object-data-browser-state.json',
    );
  }

  Future<Set<String>> _storedProfileIds(File file) async {
    if (!await file.exists()) {
      return <String>{};
    }
    final decoded =
        jsonDecode(await file.readAsString()) as Map<String, Object?>;
    final profilesJson = decoded['profiles'] as List<Object?>? ?? const [];
    return profilesJson
        .map((item) => Map<String, Object?>.from(item as Map))
        .map((item) => (item['id'] as String?) ?? '')
        .where((id) => id.isNotEmpty)
        .toSet();
  }

  Future<EndpointProfile> _hydrateProfile(Map<String, Object?> metadata) async {
    final id = (metadata['id'] as String?) ?? '';
    final inlineSecrets = Map<String, Object?>.from(
        metadata['inlineSecrets'] as Map? ?? const {});
    final accessKey = await _readSecret(
          profileId: id,
          field: 'accessKey',
        ) ??
        (inlineSecrets['accessKey'] as String? ?? '');
    final secretKey = await _readSecret(
          profileId: id,
          field: 'secretKey',
        ) ??
        (inlineSecrets['secretKey'] as String? ?? '');
    final sessionToken = await _readSecret(
          profileId: id,
          field: 'sessionToken',
        ) ??
        (inlineSecrets['sessionToken'] as String?);
    return EndpointProfile.fromJson({
      ...metadata,
      'accessKey': accessKey,
      'secretKey': secretKey,
      'sessionToken': sessionToken,
    });
  }

  Future<bool> _writeProfileSecrets(EndpointProfile profile) async {
    try {
      await _secretStore.saveSecret(
        _secretKey(profile.id, 'accessKey'),
        profile.accessKey,
      );
      await _secretStore.saveSecret(
        _secretKey(profile.id, 'secretKey'),
        profile.secretKey,
      );
      if ((profile.sessionToken ?? '').isEmpty) {
        await _secretStore.deleteSecret(_secretKey(profile.id, 'sessionToken'));
      } else {
        await _secretStore.saveSecret(
          _secretKey(profile.id, 'sessionToken'),
          profile.sessionToken ?? '',
        );
      }
      return true;
    } catch (_) {
      return false;
    }
  }

  Future<void> _deleteProfileSecrets(String profileId) async {
    try {
      await _secretStore.deleteSecret(_secretKey(profileId, 'accessKey'));
      await _secretStore.deleteSecret(_secretKey(profileId, 'secretKey'));
      await _secretStore.deleteSecret(_secretKey(profileId, 'sessionToken'));
    } catch (_) {
      // Deleting a removed profile should not block saving the remaining state.
    }
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

  Future<String?> _readSecret({
    required String profileId,
    required String field,
  }) async {
    try {
      return await _secretStore.readSecret(_secretKey(profileId, field));
    } catch (_) {
      return null;
    }
  }

  String _secretKey(String profileId, String field) {
    return 'profile.$profileId.$field';
  }
}
