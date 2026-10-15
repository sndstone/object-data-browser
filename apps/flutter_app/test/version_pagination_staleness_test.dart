import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:s3_browser_crossplat/controllers/app_controller.dart';
import 'package:s3_browser_crossplat/models/domain_models.dart';
import 'package:s3_browser_crossplat/services/mock_engine_service.dart';

const _profile = EndpointProfile(
    id: 'test',
    name: 'Test',
    endpointUrl: 'http://localhost:9000',
    region: 'us-east-1',
    accessKey: 'fixture',
    secretKey: 'fixture',
    pathStyle: true,
    verifyTls: false);
const _bucket = BucketSummary(
    name: 'original',
    region: 'us-east-1',
    objectCountHint: 1,
    versioningEnabled: true);
ObjectEntry object(String key) => ObjectEntry(
    key: key,
    name: key,
    size: 1,
    storageClass: 'STANDARD',
    modifiedAt: DateTime(2026),
    isFolder: false);
ObjectVersionEntry version(String id, {String key = 'same.bin'}) =>
    ObjectVersionEntry(
        key: key,
        versionId: id,
        modifiedAt: DateTime(2026),
        latest: false,
        deleteMarker: false,
        size: 1);
ObjectVersionListResult page(List<ObjectVersionEntry> items,
        {bool more = false}) =>
    ObjectVersionListResult(
        items: items,
        cursor: ListCursor(value: more ? 'next' : null, hasMore: more),
        totalCount: items.length,
        versionCount: items.length,
        deleteMarkerCount: 0);

class DeferredPageEngine extends MockEngineService {
  final request = Completer<ObjectVersionListResult>();
  int pageCalls = 0;
  String? requestedKey;
  ListCursor? requestedCursor;
  String? requestedEngine;
  String? requestedBucket;
  String? requestedProfile;
  VersionBrowserOptions? requestedOptions;

  @override
  Future<ObjectVersionListResult> listObjectVersions(
      {required String engineId,
      required EndpointProfile profile,
      required String bucketName,
      String? key,
      VersionBrowserOptions? options,
      ListCursor? cursor}) {
    if (cursor == null) return Future.value(page([version('fresh')]));
    pageCalls++;
    requestedKey = key;
    requestedCursor = cursor;
    requestedEngine = engineId;
    requestedBucket = bucketName;
    requestedProfile = profile.id;
    requestedOptions = options;
    return request.future;
  }

  @override
  Future<ObjectDetails> getObjectDetails(
          {required String engineId,
          required EndpointProfile profile,
          required String bucketName,
          required String key}) async =>
      ObjectDetails(
          key: key,
          metadata: const {},
          headers: const {},
          tags: const {},
          debugEvents: const [],
          apiCalls: const []);
}

void main() {
  late DeferredPageEngine engine;
  late AppController controller;
  setUp(() {
    engine = DeferredPageEngine();
    controller = AppController(
        engineService: engine,
        initialSettings: AppSettings.fromJson({}),
        initialProfiles: const [_profile]);
    controller.selectedProfile = _profile;
    controller.selectedBucket = _bucket;
    controller.selectedObject = object('same.bin');
    controller.versions = [version('initial')];
    controller.versionCursor = const ListCursor(value: 'next', hasMore: true);
  });
  tearDown(() => controller.dispose());

  for (final context in [
    'object',
    'bucket',
    'profile',
    'engine',
    'prefix',
    'options'
  ]) {
    for (final outcome in ['result', 'engine error', 'unexpected error']) {
      test('late version page $outcome is ignored after changing $context',
          () async {
        final loading = controller.loadMoreVersions();
        expect(controller.isBusy('more-versions'), isTrue);
        switch (context) {
          case 'object':
            controller.selectedObject = object('different.bin');
          case 'bucket':
            controller.selectedBucket = const BucketSummary(
                name: 'new-bucket',
                region: 'us-east-1',
                objectCountHint: 1,
                versioningEnabled: true);
          case 'profile':
            controller.selectedProfile =
                EndpointProfile.fromJson({..._profile.toJson(), 'id': 'other'});
          case 'engine':
            controller.activeEngineId = 'other';
          case 'prefix':
            controller.currentPrefix = 'other/';
          case 'options':
            controller.versionBrowserOptions =
                const VersionBrowserOptions(filterValue: 'other');
        }
        final newer = [version('new-context')];
        const cursor = ListCursor(value: 'new-cursor', hasMore: true);
        controller.versions = newer;
        controller.versionCursor = cursor;
        controller.bannerMessage = 'New context';
        switch (outcome) {
          case 'result':
            engine.request.complete(page([version('stale')]));
          case 'engine error':
            engine.request.completeError(const EngineException(
                code: ErrorCode.authFailed, message: 'Old page denied'));
          case 'unexpected error':
            engine.request.completeError(StateError('Old page denied'));
        }
        await loading;
        expect(controller.versions, same(newer));
        expect(controller.versionCursor, same(cursor));
        expect(controller.bannerMessage, 'New context');
        expect(controller.eventLog.where((e) => e.message.contains('Old page')),
            isEmpty);
        expect(controller.hasBusyActions, isFalse);
      });
    }
  }

  for (final fail in [false, true]) {
    test(
        'fresh same-object versions supersede an older page ${fail ? 'error' : 'result'}',
        () async {
      final loading = controller.loadMoreVersions();
      await controller.setSelectedObject(object('same.bin'));
      expect(controller.versions.single.versionId, 'fresh');
      final freshCursor = controller.versionCursor;
      if (fail) {
        engine.request.completeError(const EngineException(
            code: ErrorCode.authFailed, message: 'Old page denied'));
      } else {
        engine.request.complete(page([version('stale')]));
      }
      await loading;
      expect(controller.versions.single.versionId, 'fresh');
      expect(controller.versionCursor, same(freshCursor));
      expect(controller.eventLog.where((e) => e.message.contains('Old page')),
          isEmpty);
      expect(controller.hasBusyActions, isFalse);
    });
  }

  test(
      'current page uses captured context, deduplicates and tolerates a profile save',
      () async {
    final cursor = controller.versionCursor;
    final options = controller.versionBrowserOptions;
    final engineId = controller.activeEngineId;
    final loading = controller.loadMoreVersions();
    controller.selectedProfile = _profile.copyWith(name: 'Saved profile');
    await controller.loadMoreVersions();
    expect(engine.pageCalls, 1);
    expect(engine.requestedKey, 'same.bin');
    expect(engine.requestedCursor, same(cursor));
    expect(engine.requestedOptions, same(options));
    expect(engine.requestedEngine, engineId);
    expect(engine.requestedBucket, 'original');
    expect(engine.requestedProfile, 'test');
    engine.request.complete(page(
        [version('initial'), version('next'), version('next')],
        more: true));
    await loading;
    expect(controller.versions.map((v) => v.versionId), ['initial', 'next']);
    expect(controller.versionCursor.hasMore, isTrue);
    expect(controller.hasBusyActions, isFalse);
  });

  test('current page errors still surface and release the busy action',
      () async {
    final loading = controller.loadMoreVersions();
    engine.request.completeError(const EngineException(
        code: ErrorCode.authFailed, message: 'Current page denied'));
    await loading;
    expect(controller.bannerMessage, contains('Current page denied'));
    expect(controller.versions.single.versionId, 'initial');
    expect(controller.versionCursor.hasMore, isTrue);
    expect(controller.hasBusyActions, isFalse);
  });
}
