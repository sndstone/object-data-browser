import 'dart:async';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:s3_browser_crossplat/services/desktop_engine_host.dart';
import 'package:s3_browser_crossplat/services/diagnostic_safety.dart';
import 'package:s3_browser_crossplat/services/atomic_metadata_store.dart';
import 'package:s3_browser_crossplat/controllers/object_selection.dart';
import 'package:s3_browser_crossplat/controllers/object_query.dart';
import 'package:s3_browser_crossplat/models/domain_models.dart';

void main() {
  test('range and select-all exclude folders and preserve explicit selection',
      () {
    final rows = List.generate(
        4,
        (i) => ObjectEntry(
            key: '$i',
            name: '$i',
            size: 1,
            storageClass: 'STANDARD',
            modifiedAt: DateTime(2026),
            isFolder: i == 1));
    final selection = ObjectSelection();
    selection.toggle(rows.first, rows);
    selection.toggle(rows.last, rows, range: true);
    expect(selection.keys, {'0', '2', '3'});
    selection.toggle(rows[2], rows);
    expect(selection.keys, {'0', '3'});
    selection.retain(['3']);
    expect(selection.keys, {'3'});
    selection.clear();
    expect(selection.isEmpty, true);
  });
  for (final count in [10000, 100000]) {
    test('bounded query benchmark $count keys', () async {
      final objects = List.generate(
          count,
          (i) => ObjectEntry(
              key: 'folder/object-$i.txt',
              name: 'object-$i.txt',
              size: i,
              storageClass: 'STANDARD',
              modifiedAt: DateTime(2026),
              isFolder: false));
      final done = Completer<String?>();
      final query = ObjectQuery(done.complete);
      addTearDown(query.dispose);
      final watch = Stopwatch()..start();
      query.resolve(objects, BrowserFilterMode.text, 'object-',
          BrowserObjectSortField.name, false);
      expect(query.loading, true);
      expect(await done.future.timeout(const Duration(seconds: 5)), isNull);
      final result = query.resolve(objects, BrowserFilterMode.text, 'object-',
          BrowserObjectSortField.name, false);
      expect(result.length, count);
      // Informational wall time, not a hardware-dependent CI threshold.
      // ignore: avoid_print
      print(
          '2.2.5 query benchmark: $count keys, ${watch.elapsedMilliseconds} ms including isolate startup');
      expect(
          identical(
              result,
              query.resolve(objects, BrowserFilterMode.text, 'object-',
                  BrowserObjectSortField.name, false)),
          true);
    });
  }
  test('diagnostics redact signed bearer URLs and cap oversized lines', () {
    final result = DiagnosticSafety.sanitize({
      'url':
          'https://example.test/key?X-Amz-Signature=secret&X-Amz-Credential=id',
      'Authorization': 'Bearer secret',
      'nested': {'accountKey': 'private'}
    }).toString();
    expect(result, isNot(contains('secret')));
    expect(result, isNot(contains('private')));
    final buffer = DiagnosticBuffer(maxCharacters: 1024);
    for (var i = 0; i < 100; i++) {
      buffer.add('x' * 500);
    }
    buffer.add('y' * 10000);
    expect(buffer.join('\n').length, lessThan(1100));
    expect(buffer.droppedLines, greaterThan(0));
  });

  test('delete confirmation only infers successes from complete results', () {
    const denied = BatchOperationFailure(
        target: 'b', code: 'AccessDenied', message: 'Denied');
    expect(
        ObjectSelection.confirmedDeletes(
            ['a', 'b'],
            const BatchOperationResult(
                successCount: 1, failureCount: 1, failures: [denied])),
        {'a'});
    expect(
        ObjectSelection.confirmedDeletes(
            ['b'],
            const BatchOperationResult(
                successCount: 0, failureCount: 1, failures: [denied])),
        isEmpty);
    expect(
        ObjectSelection.confirmedDeletes(
            ['a', 'b'],
            const BatchOperationResult(
                successCount: 1, failureCount: 1, failures: [])),
        isEmpty);
  });

  test('metadata saves serialize and recover a corrupt primary from last good',
      () async {
    final dir = await Directory.systemTemp.createTemp('metadata-225-');
    addTearDown(() => dir.delete(recursive: true));
    final file = File('${dir.path}/state.json');
    final store = AtomicMetadataStore();
    await Future.wait([
      for (var i = 0; i < 3; i++)
        store.serialize(() => store.replace(file, {
              'settings': {'revision': i},
              'profiles': []
            }))
    ]);
    expect((await store.read(file))!['settings'], {'revision': 2});
    await file.writeAsString('{corrupt');
    expect((await store.read(file))!['settings'], {'revision': 1});
    expect(
        await dir.list().where((f) => f.path.contains('.corrupt-')).length, 1);
    expect((await store.read(file))!['settings'], {'revision': 1});
  });

  group('host lifecycle', () {
    late Directory dir;
    late String script;
    late DesktopEngineHost host;
    setUp(() async {
      dir = await Directory.systemTemp.createTemp('host-225-');
      script = '${dir.path}/engine.py';
      await File(script).writeAsString(r'''
import sys,json,threading,time,os
lock=threading.Lock()
def emit(value):
 with lock:
  print(json.dumps(value),flush=True)
gate=threading.Event()
def work(r):
 emit({'event':'transferProgress','job':{'id':'job-1','status':'running'}})
 gate.wait(5)
 emit({'requestId':r['requestId'],'ok':True,'result':{'pid':os.getpid()}})
for line in sys.stdin:
 r=json.loads(line)
 if r['method']=='startUpload':threading.Thread(target=work,args=(r,)).start()
 elif r['method']=='cancelTransfer':
  emit({'requestId':r['requestId'],'ok':True,'result':{'pid':os.getpid()}})
  gate.set()
 elif r['method']=='hang':pass
 else:
  time.sleep(.05)
  emit({'requestId':r['requestId'],'ok':True,'result':{'pid':os.getpid()}})
''');
      host = DesktopEngineHost(
          maxProcesses: 2,
          maxProcessesPerEngine: 1,
          maxQueuedRequests: 1,
          requestTimeout: const Duration(milliseconds: 250));
    });
    tearDown(() async {
      host.dispose();
      await dir.delete(recursive: true);
    });
    Future<DesktopEngineHostResponse> send(String id, String method,
            {Map<String, Object?> params = const {},
            void Function(Map<String, Object?>)? event}) =>
        host.send(
            executablePath: 'python3',
            arguments: [script],
            request: {'requestId': id, 'method': method, 'params': params},
            onEvent: event,
            concurrentControls: true);

    test('control bypasses a full work queue and reaches the owning process',
        () async {
      final started = Completer<void>();
      final upload = send('upload', 'startUpload', event: (_) {
        if (!started.isCompleted) started.complete();
      });
      await started.future;
      final queued = send('next', 'health');
      await expectLater(send('overflow', 'health'), throwsA(isA<StateError>()));
      final cancel =
          await send('cancel', 'cancelTransfer', params: {'jobId': 'job-1'});
      final completed = await upload;
      expect(cancel.payload['result'], completed.payload['result']);
      await queued;
      expect(host.liveProcessCount, 1);
      expect(host.queuedRequestCount, 0);
    }, skip: Platform.isWindows);

    test('hung requests time out, reap the process, and recover', () async {
      await expectLater(send('hang', 'hang'), throwsA(isA<TimeoutException>()));
      expect(host.liveProcessCount, 0);
      expect((await send('health', 'health')).payload['ok'], true);
    }, skip: Platform.isWindows);

    test('queued listings can be cancelled without killing active work',
        () async {
      final first = send('first', 'health');
      final listing = send('listing', 'listObjects');
      final check = expectLater(listing, throwsA(isA<StateError>()));
      host.cancelQueuedListings();
      await check;
      await first;
      expect(host.liveProcessCount, 1);
    }, skip: Platform.isWindows);
  });

  test('pathological regex is isolated and cancelled at its execution budget',
      () async {
    final changed = Completer<String?>();
    final query = ObjectQuery((error) {
      if (!changed.isCompleted) changed.complete(error);
    });
    addTearDown(query.dispose);
    final object = ObjectEntry(
        key: '${'a' * 100}!',
        name: 'test',
        size: 1,
        storageClass: 'STANDARD',
        modifiedAt: DateTime(2026),
        isFolder: false);
    query.resolve([object], BrowserFilterMode.regex, r'^(a+)+$',
        BrowserObjectSortField.name, false);
    expect(await changed.future.timeout(const Duration(seconds: 5)),
        contains('execution budget'));
  });
}
