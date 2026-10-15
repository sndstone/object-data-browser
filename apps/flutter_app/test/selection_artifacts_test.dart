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
final _object = ObjectEntry(
    key: 'same.bin',
    name: 'same.bin',
    size: 1,
    storageClass: 'STANDARD',
    modifiedAt: DateTime(2026),
    isFolder: false);

class DeferredInspectorEngine extends MockEngineService {
  final details = Completer<ObjectDetails>();
  final versions = Completer<ObjectVersionListResult>();
  final presign = Completer<String>();
  bool defer = true;

  @override
  Future<String> generatePresignedUrl({
    required String engineId,
    required EndpointProfile profile,
    required String bucketName,
    required String key,
    required Duration expiration,
  }) =>
      presign.future;

  @override
  Future<ObjectDetails> getObjectDetails({
    required String engineId,
    required EndpointProfile profile,
    required String bucketName,
    required String key,
  }) async {
    if (defer) return details.future;
    return ObjectDetails(
        key: key,
        metadata: {'bucket': bucketName},
        headers: const {},
        tags: const {},
        debugEvents: const [],
        apiCalls: const []);
  }

  @override
  Future<ObjectVersionListResult> listObjectVersions({
    required String engineId,
    required EndpointProfile profile,
    required String bucketName,
    String? key,
    VersionBrowserOptions? options,
    ListCursor? cursor,
  }) async {
    if (defer) return versions.future;
    return versionResult(bucketName);
  }

  @override
  Future<ObjectListResult> listObjects({
    required String engineId,
    required EndpointProfile profile,
    required String bucketName,
    required String prefix,
    required bool flat,
    ListCursor? cursor,
  }) async =>
      ObjectListResult(
          items: [_object],
          cursor: const ListCursor(value: null, hasMore: false));
}

ObjectVersionListResult versionResult(String version) =>
    ObjectVersionListResult(
        items: [
          ObjectVersionEntry(
              key: _object.key,
              versionId: version,
              modifiedAt: DateTime(2026),
              latest: true,
              deleteMarker: false,
              size: 1)
        ],
        cursor: const ListCursor(value: null, hasMore: false),
        totalCount: 1,
        versionCount: 1,
        deleteMarkerCount: 0);

void main() {
  late DeferredInspectorEngine engine;
  late AppController controller;
  setUp(() {
    engine = DeferredInspectorEngine();
    controller = AppController(
        engineService: engine,
        initialSettings: AppSettings.fromJson({}),
        initialProfiles: const [_profile]);
    controller.selectedProfile = _profile;
    controller.selectedBucket = _bucket;
    controller.objects = [_object];
  });
  tearDown(() => controller.dispose());

  test('late details are ignored before the new context has loaded', () async {
    final selection = controller.setSelectedObject(_object);
    controller.activeEngineId = 'go';
    engine.details.complete(const ObjectDetails(
        key: 'same.bin',
        metadata: {},
        headers: {},
        tags: {},
        debugEvents: [],
        apiCalls: []));
    engine.versions.complete(versionResult('stale'));
    await selection;
    expect(controller.selectedObjectDetails, isNull);
    expect(controller.selectedObjectPreview, isNull);
    expect(controller.versions, isEmpty);
  });

  test('presigned previews cannot cross buckets with the same object key',
      () async {
    engine.defer = false;
    final image = ObjectEntry(
        key: 'same.png',
        name: 'same.png',
        size: 1,
        storageClass: 'STANDARD',
        modifiedAt: DateTime(2026),
        isFolder: false);
    await controller.setSelectedObject(image);
    expect(controller.selectedObjectPreview!.loading, isTrue);
    await controller.setSelectedBucket(const BucketSummary(
        name: 'new-bucket',
        region: 'us-east-1',
        objectCountHint: 1,
        versioningEnabled: true));
    await controller.setSelectedObject(image, loadArtifacts: false);
    engine.presign.complete('https://example.invalid/original/same.png');
    await Future<void>.delayed(Duration.zero);
    expect(controller.selectedObjectPreview, isNull);
  });

  for (final fail in [false, true]) {
    test('late inspector ${fail ? 'errors' : 'results'} preserve newer data',
        () async {
      final oldSelection = controller.setSelectedObject(_object);
      engine.defer = false;
      controller.selectedBucket = const BucketSummary(
          name: 'new-bucket',
          region: 'us-east-1',
          objectCountHint: 1,
          versioningEnabled: true);
      await controller.refreshObjects();
      expect(
          controller.selectedObjectDetails!.metadata['bucket'], 'new-bucket');
      expect(controller.versions.single.versionId, 'new-bucket');

      if (fail) {
        const error = EngineException(
            code: ErrorCode.authFailed, message: 'Old bucket denied');
        engine.details.completeError(error);
        engine.versions.completeError(error);
      } else {
        engine.details.complete(const ObjectDetails(
            key: 'same.bin',
            metadata: {'bucket': 'original'},
            headers: {},
            tags: {},
            debugEvents: [],
            apiCalls: []));
        engine.versions.complete(versionResult('old-version'));
      }
      await oldSelection;
      expect(
          controller.selectedObjectDetails!.metadata['bucket'], 'new-bucket');
      expect(controller.versions.single.versionId, 'new-bucket');
      expect(controller.eventLog.where((e) => e.message.contains('Old bucket')),
          isEmpty);
    });
  }
}
