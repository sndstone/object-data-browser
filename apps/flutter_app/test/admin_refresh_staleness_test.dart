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

class DeferredAdminEngine extends MockEngineService {
  final requests = <Completer<BucketAdminState>>[];
  final bucketNames = <String>[];
  Completer<BucketAdminState> get request => requests.first;
  int get calls => requests.length;
  @override
  Future<BucketAdminState> getBucketAdminState(
      {required String engineId,
      required EndpointProfile profile,
      required String bucketName}) {
    bucketNames.add(bucketName);
    final completer = Completer<BucketAdminState>();
    requests.add(completer);
    return completer.future;
  }
}

void main() {
  late DeferredAdminEngine engine;
  late AppController controller;
  late BucketAdminState original;
  late BucketAdminState newer;
  setUp(() async {
    engine = DeferredAdminEngine();
    controller = AppController(
        engineService: engine,
        initialSettings: AppSettings.fromJson({}),
        initialProfiles: const [_profile]);
    controller.selectedProfile = _profile;
    controller.selectedBucket = _bucket;
    final fixture = MockEngineService();
    original = await fixture.getBucketAdminState(
        engineId: 'mock', profile: _profile, bucketName: 'original');
    newer = await fixture.getBucketAdminState(
        engineId: 'mock', profile: _profile, bucketName: 'new-bucket');
  });
  tearDown(() => controller.dispose());

  for (final context in ['bucket', 'profile', 'engine']) {
    for (final outcome in ['result', 'engine error', 'unexpected error']) {
      test('late admin $outcome is ignored after changing $context', () async {
        final refresh = controller.refreshBucketAdminState();
        expect(controller.isBusy('refresh-bucket-admin'), isTrue);
        switch (context) {
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
        }
        controller.adminState = newer;
        controller.bannerMessage = 'New context';
        switch (outcome) {
          case 'result':
            engine.request.complete(original);
          case 'engine error':
            engine.request.completeError(const EngineException(
                code: ErrorCode.authFailed, message: 'Old bucket denied'));
          case 'unexpected error':
            engine.request.completeError(StateError('Old bucket denied'));
        }
        // The skipped refresh for the new context is issued once the stale
        // request settles, and only its result is applied.
        await pumpEventQueue();
        expect(engine.calls, 2);
        expect(engine.bucketNames.last,
            context == 'bucket' ? 'new-bucket' : 'original');
        engine.requests.last.complete(newer);
        await refresh;
        expect(controller.adminState, same(newer));
        expect(
            controller.eventLog.where((e) => e.message.contains('Old bucket')),
            isEmpty);
        expect(controller.hasBusyActions, isFalse);
      });
    }
  }

  test('clearing admin context invalidates an older request even if restored',
      () async {
    final refresh = controller.refreshBucketAdminState();
    controller.selectedBucket = null;
    await controller.refreshBucketAdminState();
    expect(controller.adminState, isNull);
    controller.selectedBucket = _bucket;
    engine.request.complete(original);
    await refresh;
    expect(controller.adminState, isNull);
    expect(controller.hasBusyActions, isFalse);
  });

  test('duplicate refresh and replacement profile with same ID keep valid data',
      () async {
    final refresh = controller.refreshBucketAdminState();
    controller.selectedProfile = _profile.copyWith(name: 'Saved profile');
    await controller.refreshBucketAdminState();
    expect(engine.calls, 1);
    engine.request.complete(original);
    await refresh;
    expect(controller.adminState, same(original));
    expect(controller.hasBusyActions, isFalse);
  });

  test('current admin errors still surface and release the busy action',
      () async {
    final refresh = controller.refreshBucketAdminState();
    engine.request.completeError(const EngineException(
        code: ErrorCode.authFailed, message: 'Current bucket denied'));
    await refresh;
    expect(controller.bannerMessage, contains('Current bucket denied'));
    expect(
        controller.eventLog.where((e) => e.message.contains('Current bucket')),
        isNotEmpty);
    expect(controller.hasBusyActions, isFalse);
  });
}
