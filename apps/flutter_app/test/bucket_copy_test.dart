import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:s3_browser_crossplat/models/domain_models.dart';
import 'package:s3_browser_crossplat/controllers/app_controller.dart';
import 'package:s3_browser_crossplat/services/bucket_copy_journal.dart';
import 'package:s3_browser_crossplat/services/mock_engine_service.dart';

class CopyEngine extends MockEngineService {
  final calls = <Map<String, Object?>>[];
  String? failKey;
  bool unknownOutcome = false, failConfiguration = false;
  int historyResumeCount = 0;
  @override
  Future<Map<String, Object?>> storageAction(
      {required EndpointProfile profile,
      required String action,
      Map<String, Object?> arguments = const {},
      EndpointProfile? destinationProfile}) async {
    calls.add({
      'action': action,
      ...arguments,
      'profileId': profile.id,
      'destinationProfileId': destinationProfile?.id
    });
    if (action == 'planHistoryCopy') {
      return {
        'recoveryId': 'history-test',
        'versionCount': 2,
        'deleteMarkerCount': 1
      };
    }
    if (action == 'resumeHistoryCopy') {
      historyResumeCount++;
      return {
        'status': historyResumeCount % 2 == 0 ? 'completed' : 'running',
        'completedCount': historyResumeCount
      };
    }
    if (action == 'planBucketConfigurationCopy') {
      return {'planId': 'configuration-test', 'changes': [], 'blocked': []};
    }
    if (action == 'applyBucketConfigurationCopy') {
      if (failConfiguration) throw StateError('Destination policy changed');
      return {'status': 'completed'};
    }
    if (action == 'listObjects') {
      return {
        'items': arguments['cursor'] == null
            ? [
                {'key': 'folder/', 'isFolder': true, 'size': 0, 'etag': 'a'},
                {'key': ' a + % file ', 'size': 1, 'etag': 'b'}
              ]
            : [
                {'key': 'last', 'size': 2, 'etag': 'c'}
              ],
        'nextCursor': arguments['cursor'] == null
            ? {'hasMore': true, 'value': 'p2'}
            : {'hasMore': false, 'value': null}
      };
    }
    if (action == 'copyObject') {
      if (arguments['sourceKey'] == failKey) {
        throw StateError('connection lost');
      }
      if (unknownOutcome) return {};
      return {'successCount': 1, 'failureCount': 0, 'bytesCopied': 1};
    }
    return {};
  }
}

const source = EndpointProfile(
    id: 'source',
    name: 'Source',
    endpointUrl: 'https://source.example',
    region: 'us-east-1',
    accessKey: 'key',
    secretKey: 'secret',
    pathStyle: true,
    verifyTls: true);
void main() {
  late Directory dir;
  late CopyEngine engine;
  late AppController controller;
  setUp(() async {
    dir = await Directory.systemTemp.createTemp('bucket-copy-test-');
    engine = CopyEngine();
    controller = AppController(
        engineService: engine,
        initialSettings: AppSettings.fromJson({}),
        initialProfiles: const [source],
        bucketCopyJournalProvider: () async =>
            BucketCopyJournal(File('${dir.path}/job.json')));
    await controller.initialize();
  });
  tearDown(() async {
    controller.dispose();
    await dir.delete(recursive: true);
  });
  test('copies pages across endpoints preserving folder markers and exact keys',
      () async {
    final destination = EndpointProfile.fromJson({
      ...source.toJson(),
      'id': 'dest',
      'endpointUrl': 'https://dest.example'
    });
    await controller.copyBucketContents(
        sourceBucketName: 'a',
        destinationBucketName: 'a',
        destinationProfile: destination);
    final copied =
        engine.calls.where((c) => c['action'] == 'copyObject').toList();
    expect(
        copied.map((c) => c['sourceKey']), ['folder/', ' a + % file ', 'last']);
    expect(copied.every((c) => c['destinationKey'] == c['sourceKey']), isTrue);
    expect(
        copied.every((c) =>
            c['destinationProfileId'] == 'dest' && c['profileId'] == 'source'),
        isTrue);
    expect(copied.map((c) => c['expectedSourceETag']), ['a', 'b', 'c']);
    expect(await File('${dir.path}/job.json').exists(), isFalse);
  });
  test(
      'checkpoint resumes within page, omits finished objects and retains unknown outcomes',
      () async {
    engine.failKey = ' a + % file ';
    await controller.copyBucketContents(
        sourceBucketName: 'a', destinationBucketName: 'b');
    expect(controller.bannerMessage, contains('Copy stopped'));
    expect(await File('${dir.path}/job.json').exists(), isTrue);
    engine.failKey = null;
    engine.calls.clear();
    await controller.copyBucketContents(
        sourceBucketName: 'a', destinationBucketName: 'b', resume: true);
    expect(
        engine.calls
            .where((c) => c['action'] == 'copyObject')
            .map((c) => c['sourceKey']),
        [' a + % file ', 'last']);
    expect(await File('${dir.path}/job.json').exists(), isFalse);
  });
  test('identical storage target is rejected even through another profile',
      () async {
    await controller.copyBucketContents(
        sourceBucketName: 'a',
        destinationBucketName: 'a',
        destinationProfile:
            EndpointProfile.fromJson({...source.toJson(), 'id': 'alias'}));
    expect(engine.calls, isEmpty);
    expect(controller.bannerMessage, contains('different'));
  });
  test('empty copy result never counts as success', () async {
    engine.unknownOutcome = true;
    await controller.copyBucketContents(
        sourceBucketName: 'a', destinationBucketName: 'b');
    expect(controller.bannerMessage, contains('unknown'));
    expect(await File('${dir.path}/job.json').exists(), isTrue);
    expect(
        engine.calls.where((c) => c['action'] == 'copyObject'), hasLength(1));
  });
  test('starting again cannot orphan a continuously running benchmark',
      () async {
    controller.benchmarkDraft =
        controller.benchmarkDraft.copyWith(bucketName: 'test-bucket');
    await controller.startBenchmark();
    final run = controller.benchmarkRun!;
    expect(run.status, 'running');
    await controller.startBenchmark();
    expect(controller.benchmarkRun!.id, run.id);
    expect(controller.bannerMessage, contains('active benchmark'));
  });
  test('history copy never replays after configuration failure', () async {
    engine.failConfiguration = true;
    final reviews = <String>[];
    await controller.copyBucketContents(
        sourceBucketName: 'a',
        destinationBucketName: 'b',
        includeHistory: true,
        configurationSections: ['tags'],
        reviewPlan: (plan) async {
          reviews.add(plan['planId'] != null ? 'configuration' : 'history');
          return true;
        });
    expect(reviews, ['configuration', 'history']);
    expect(engine.historyResumeCount, 2);
    expect(controller.bannerMessage, contains('Destination policy changed'));
    expect(await File('${dir.path}/job.json').exists(), isTrue);
    engine.failConfiguration = false;
    engine.calls.clear();
    await controller.copyBucketContents(
        sourceBucketName: 'a',
        destinationBucketName: 'b',
        resume: true,
        includeHistory: true,
        configurationSections: ['tags'],
        reviewPlan: (_) async =>
            throw StateError('Previously approved plan should be retained'));
    expect(
        engine.calls.map((c) => c['action']), ['applyBucketConfigurationCopy']);
    expect(await File('${dir.path}/job.json').exists(), isFalse);
  });
  test('configuration refusal stops before listing or copying', () async {
    await controller.copyBucketContents(
        sourceBucketName: 'a',
        destinationBucketName: 'b',
        configurationSections: ['lifecycle'],
        reviewPlan: (_) async => false);
    expect(
        engine.calls.map((c) => c['action']), ['planBucketConfigurationCopy']);
  });
  test('configuration failure preserves completed current-object copy',
      () async {
    engine.failConfiguration = true;
    await controller.copyBucketContents(
        sourceBucketName: 'a',
        destinationBucketName: 'b',
        configurationSections: ['tags'],
        reviewPlan: (_) async => true);
    expect(
        engine.calls.where((c) => c['action'] == 'copyObject'), hasLength(3));
    engine.failConfiguration = false;
    engine.calls.clear();
    await controller.copyBucketContents(
        sourceBucketName: 'a',
        destinationBucketName: 'b',
        resume: true,
        configurationSections: ['tags'],
        reviewPlan: (_) async => true);
    expect(
        engine.calls.map((c) => c['action']), ['applyBucketConfigurationCopy']);
  });
}
