import 'dart:async';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:s3_browser_crossplat/controllers/upload_batch.dart';
import 'package:s3_browser_crossplat/models/domain_models.dart';
import 'package:s3_browser_crossplat/services/mock_engine_service.dart';

class FileEngine extends MockEngineService {
  final requests =
      <({String path, int chunk, String engine, Map<String, String> keys})>[];
  void Function(TransferJob)? progress;
  Completer<void>? hold;
  Completer<void> started = Completer();
  int? failIndex;
  bool throwFailure = false, controllable = true;
  TransferJob? current;
  final controls = <String>[];
  @override
  Future<TransferJob> startUpload(
      {required String engineId,
      required EndpointProfile profile,
      required String bucketName,
      required String prefix,
      required List<String> filePaths,
      required Map<String, String> objectKeyByPath,
      required int multipartThresholdMiB,
      required int multipartChunkMiB}) async {
    expect(filePaths, hasLength(1));
    final index = requests.length;
    final path = filePaths.single;
    requests.add((
      path: path,
      chunk: multipartChunkMiB,
      engine: engineId,
      keys: objectKeyByPath
    ));
    final size = await File(path).length();
    current = TransferJob(
        id: 'child-$index',
        label: path,
        direction: 'upload',
        progress: .5,
        status: 'running',
        bytesTransferred: size ~/ 2,
        totalBytes: size,
        canPause: controllable,
        canResume: false,
        canCancel: controllable);
    progress?.call(current!);
    if (!started.isCompleted) started.complete();
    if (hold != null) await hold!.future;
    if (index == failIndex && throwFailure) {
      throw StateError('Disconnected: outcome unknown');
    }
    final result = current!.copyWith(
        status: index == failIndex ? 'failed' : 'completed',
        progress: index == failIndex ? .5 : 1,
        bytesTransferred: index == failIndex ? size ~/ 2 : size,
        canPause: false,
        canResume: false,
        canCancel: false,
        outputLines: [index == failIndex ? 'Injected failure' : 'Uploaded']);
    progress?.call(result);
    return result;
  }

  @override
  Future<TransferJob> pauseTransfer(
      {required String engineId, required String jobId}) async {
    controls.add('$engineId/$jobId/pause');
    return current =
        current!.copyWith(status: 'paused', canPause: false, canResume: true);
  }

  @override
  Future<TransferJob> resumeTransfer(
      {required String engineId, required String jobId}) async {
    controls.add('$engineId/$jobId/resume');
    return current =
        current!.copyWith(status: 'running', canPause: true, canResume: false);
  }
}

void main() {
  late Directory dir;
  late FileEngine engine;
  late List<TransferJob> updates;
  late List<String> events;
  setUp(() async {
    dir = await Directory.systemTemp.createTemp('per-file-upload-');
    engine = FileEngine();
    updates = [];
    events = [];
  });
  tearDown(() async {
    await dir.delete(recursive: true);
  });
  Future<String> file(String name, int size) async {
    final path = '${dir.path}/$name';
    final handle = await File(path).open(mode: FileMode.write);
    await handle.truncate(size);
    await handle.close();
    return path;
  }

  UploadBatch batch(List<String> paths, {AppSettings? settings}) {
    final batch = UploadBatch(
        id: 'parent',
        engine: engine,
        engineId: 'python',
        profile: const EndpointProfile(
            id: 'test',
            name: 'Test',
            endpointUrl: 'http://localhost:9000',
            region: 'us-east-1',
            accessKey: 'fixture',
            secretKey: 'fixture',
            pathStyle: true,
            verifyTls: false),
        bucket: 'fixture',
        prefix: 'folder/',
        paths: paths,
        objectKeys: {paths.first: 'custom-name.bin'},
        settings: settings ?? AppSettings.fromJson({}),
        onUpdate: updates.add,
        onFile: (i, p, s, m, j) => events.add('$i/$s'));
    engine.progress = batch.consume;
    return batch;
  }

  test('mixed sizes dispatch independently and aggregate monotonic exact bytes',
      () async {
    final paths = [
      await file('large', 10 * 1024 * 1024 * 1024),
      await file('small', 1024),
      await file('zero', 0)
    ];
    final upload = batch(paths);
    await upload.prepare();
    final result = await upload.run();
    expect(engine.requests.map((r) => r.chunk), [128, 8, 8]);
    expect(engine.requests.first.keys, {paths.first: 'custom-name.bin'});
    expect(engine.requests.last.keys, isEmpty);
    expect(updates.map((j) => j.id).toSet(), {'parent'});
    for (var i = 1; i < updates.length; i++) {
      expect(updates[i].bytesTransferred,
          greaterThanOrEqualTo(updates[i - 1].bytesTransferred));
    }
    expect(result.status, 'completed');
    expect(result.itemsCompleted, 3);
    expect(result.progress, 1);
    expect(result.totalBytes, 10 * 1024 * 1024 * 1024 + 1024);
    expect(result.bytesTransferred, result.totalBytes);
  });
  test('known file failure remains failed while other files can complete',
      () async {
    engine.failIndex = 1;
    final upload =
        batch([await file('a', 10), await file('b', 10), await file('c', 10)]);
    await upload.prepare();
    final result = await upload.run();
    expect(result.status, 'failed');
    expect(result.itemsCompleted, 2);
    expect(engine.requests.length, 3);
    expect(events, contains('1/failed'));
    expect(result.outputLines.last, 'Injected failure');
  });
  test('unknown outcome stops scheduling remaining files', () async {
    engine.failIndex = 0;
    engine.throwFailure = true;
    final upload = batch([await file('a', 10), await file('b', 10)]);
    await upload.prepare();
    final result = await upload.run();
    expect(result.status, 'failed');
    expect(engine.requests.length, 1);
    expect(events, contains('1/not started'));
  });
  test(
      'cancelling sequential engine prevents the next file without fake cancellation',
      () async {
    engine.controllable = false;
    engine.hold = Completer();
    final upload = batch([await file('a', 10), await file('b', 10)]);
    await upload.prepare();
    final running = upload.run();
    await engine.started.future;
    await upload.control('cancel');
    expect(updates.last.status, 'cancelling');
    engine.hold!.complete();
    final result = await running;
    expect(result.status, 'cancelled');
    expect(engine.requests.length, 1);
    expect(result.itemsCompleted, 1);
    expect(events, contains('1/not started'));
  });
  test('parent pause and resume target the current child and original engine',
      () async {
    engine.hold = Completer();
    final upload = batch([await file('a', 10), await file('b', 10)]);
    await upload.prepare();
    final running = upload.run();
    await engine.started.future;
    await upload.control('pause');
    expect(updates.last.status, 'paused');
    await upload.control('resume');
    expect(updates.last.status, 'running');
    expect(engine.controls, ['python/child-0/pause', 'python/child-0/resume']);
    engine.hold!.complete();
    await running;
  });
  test('manual part limit rejects entire batch before any upload', () async {
    final upload = batch(
        [await file('tiny', 1), await file('large', 100 * 1024 * 1024 * 1024)],
        settings: AppSettings.fromJson({})
            .copyWith(dynamicMultipartSizing: false, multipartChunkMiB: 5));
    await expectLater(upload.prepare(), throwsArgumentError);
    expect(engine.requests, isEmpty);
  });
  test('zero-byte files complete without NaN progress', () async {
    final upload = batch([await file('a', 0), await file('b', 0)]);
    await upload.prepare();
    final result = await upload.run();
    expect(result.progress, 1);
    expect(result.itemsCompleted, 2);
  });
}
