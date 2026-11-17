import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:s3_browser_crossplat/controllers/app_controller.dart';
import 'package:s3_browser_crossplat/models/domain_models.dart';
import 'package:s3_browser_crossplat/services/android_engine_service.dart';
import 'package:s3_browser_crossplat/services/ios_engine_service.dart';
import 'package:s3_browser_crossplat/services/engine_service.dart';
import 'package:s3_browser_crossplat/services/app_state_repository.dart';
import 'package:s3_browser_crossplat/services/crypto/age.dart';
import 'package:s3_browser_crossplat/services/encryption_key_store.dart';

import 'app_state_repository_test.dart' show RecordingProfileSecretStore;
import 'mobile_client_encryption_fixture.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  // The test binding replaces HttpClient with one that answers 400; these
  // tests talk to a real loopback fixture.
  setUp(() => HttpOverrides.global = null);
  for (final ios in [false, true]) {
    test(
        '${ios ? 'iOS Azure' : 'Android S3'} controller vault upload download and bounded preview use REST adapter',
        () async {
      final fixture = MobileAgeFixture(ios);
      await fixture.start();
      addTearDown(fixture.close);
      final identity = await AgeIdentity.generate();
      final store = EncryptionKeyStore(
          File('${fixture.directory.path}/keys.age'),
          scryptWorkFactor: 1);
      await store.create('test-passphrase');
      await store.importAgeIdentity('Vault', identity.secretKey);
      final profile = fixture.profile.copyWith(clientEncryptionRules: [
        ClientEncryptionRule(
            bucket: 'bucket',
            keyId: store.records.single.id,
            recipient: identity.recipient,
            label: 'Vault')
      ]);
      final EngineService engine = ios
          ? IosEngineService() as EngineService
          : AndroidEngineService() as EngineService;
      final controller = AppController(
          engineService: engine,
          encryptionKeyStore: store,
          appStateRepository: LocalAppStateRepository(
              secretStore: RecordingProfileSecretStore({}),
              applicationSupportDirectoryProvider: () async =>
                  fixture.directory),
          initialSettings: AppSettings.fromJson({
            'downloadPath': fixture.directory.path,
            'relistObjectsAfterMutation': false,
            'enableAnimations': false,
            'enableApiLogging': true,
            'enableDebugLogging': true
          }),
          initialProfiles: [profile],
          previewRangeFetcher: (url, start, end, size, etag) async {
            final key = Uri.parse(url).pathSegments.skip(1).join('/');
            return Uint8List.sublistView(fixture.objects[key]!, start, end);
          });
      addTearDown(controller.dispose);
      controller.selectedProfile = profile;
      controller.selectedBucket = const BucketSummary(
          name: 'bucket',
          region: '',
          objectCountHint: 0,
          versioningEnabled: false);
      final source = await File('${fixture.directory.path}/note.txt')
          .writeAsString('phone vault');
      await controller.startSampleUpload([source.path]);
      expect(controller.transferJobs.first.status, 'completed');
      final stored = fixture.objects['note.txt.age']!;
      expect(await ageDecrypt(stored, identities: [identity]),
          utf8.encode('phone vault'));
      final object = ObjectEntry(
          key: 'note.txt.age',
          name: 'note.txt.age',
          size: stored.length,
          modifiedAt: DateTime.utc(2026),
          storageClass: 'STANDARD',
          isFolder: false,
          etag: '"fixture"');
      controller.objects = [object];
      await source.delete();
      await controller.startSampleDownload(key: object.key);
      expect(controller.transferJobs.first.status, 'completed');
      expect(await File('${fixture.directory.path}/note.txt').readAsString(),
          'phone vault');
      await controller.setSelectedObject(object, loadArtifacts: false);
      controller.refreshSelectedObjectPreview();
      for (var i = 0;
          i < 500 && controller.selectedObjectPreview?.loading == true;
          i++) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      expect(controller.selectedObjectPreview?.text, 'phone vault');
      final opened = await ageReadHeader(stored, identities: [identity]);
      final retained = jsonEncode({
        'events': controller.eventLog.map((e) => e.toJson()).toList(),
        'tasks': controller.browserTasks
            .map((t) => [t.label, t.outputLines])
            .toList(),
        'jobs': controller.transferJobs
            .map((j) => [j.label, j.outputLines])
            .toList(),
        'profiles': controller.profiles.map((p) => p.toJson()).toList()
      });
      expect(retained, isNot(contains(base64Encode(opened.fileKey))));
      expect(retained, isNot(contains(identity.secretKey)));
    });
  }
}
