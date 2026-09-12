import 'package:s3_browser_crossplat/controllers/action_scope.dart';
import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:s3_browser_crossplat/services/desktop_engine_host.dart';
import 'package:s3_browser_crossplat/services/listing_cancellation.dart';

void main() {
  group('listing request cancellation', () {
    late Directory dir;
    late String script;
    late DesktopEngineHost host;
    setUp(() async {
      dir = await Directory.systemTemp.createTemp('cancel-listing-');
      script = '${dir.path}/engine.sh';
      await File(script).writeAsString(r'''
while IFS= read -r line; do
  rid=$(printf '%s' "$line" | sed -n 's/.*"requestId":"\([^"]*\)".*/\1/p')
  case "$line" in
    *'"listObjects"'*|*'"listBuckets"'*|*'"copyObject"'*)
      printf '{"event":"listingStarted"}\n' ;;
    *'"startUpload"'*)
      upload_id=$rid
      printf '{"event":"transferProgress","job":{"id":"upload-job","status":"running"}}\n' ;;
    *'"cancelTransfer"'*)
      printf '{"requestId":"%s","ok":true,"result":{}}\n' "$rid"
      printf '{"requestId":"%s","ok":true,"result":{}}\n' "$upload_id" ;;
    *) printf '{"requestId":"%s","ok":true,"result":{}}\n' "$rid" ;;
  esac
done
''');
      host = DesktopEngineHost(
          maxProcesses: 2,
          maxProcessesPerEngine: 2,
          requestTimeout: const Duration(seconds: 30));
    });
    tearDown(() async {
      host.dispose();
      await dir.delete(recursive: true);
    });
    Future<DesktopEngineHostResponse> send(String id, String method,
            {void Function(Map<String, Object?>)? event,
            Map<String, Object?> params = const {}}) =>
        host.send(
            executablePath: '/bin/sh',
            arguments: [script],
            request: {'requestId': id, 'method': method, 'params': params},
            onEvent: event,
            concurrentControls: true);

    test(
        'scoped cancellation stops only its own request and records unknown mutations',
        () async {
      final readScope = ActionScope();
      final mutationScope = ActionScope();
      final readStarted = Completer<void>();
      final mutationStarted = Completer<void>();
      Future<DesktopEngineHostResponse> scoped(
              String method, ActionScope scope, Completer<void> started) =>
          host.send(
              executablePath: '/bin/sh',
              arguments: [script],
              request: {'requestId': method, 'method': method},
              listingCancellation: scope,
              onEvent: (_) {
                if (!started.isCompleted) started.complete();
              });
      final read = scoped('listObjects', readScope, readStarted);
      final mutation = scoped('copyObject', mutationScope, mutationStarted);
      final readDone = expectLater(read, throwsA(isA<ListingCancelled>()));
      final mutationDone =
          expectLater(mutation, throwsA(isA<ListingCancelled>()));
      await Future.wait([readStarted.future, mutationStarted.future])
          .timeout(const Duration(seconds: 5));
      readScope.cancel();
      await readDone.timeout(const Duration(seconds: 1));
      expect(host.liveProcessCount, 1);
      expect(mutationScope.isCancelled, isFalse);
      expect(readScope.outcomeUnknown, isFalse);
      mutationScope.cancel();
      await mutationDone.timeout(const Duration(seconds: 1));
      expect(mutationScope.outcomeUnknown, isTrue);
      expect(host.liveProcessCount, 0);
    });

    for (final method in ['listBuckets', 'listObjects']) {
      test('interrupts an in-flight $method and releases its process slot',
          () async {
        final started = Completer<void>();
        final pending = send('hung', method, event: (_) => started.complete());
        final cancelled =
            expectLater(pending, throwsA(isA<ListingCancelled>()));
        await started.future.timeout(const Duration(seconds: 5));
        expect(host.liveProcessCount, 1);
        host.cancelListings();
        await cancelled.timeout(const Duration(seconds: 1));
        expect(host.liveProcessCount, 0);
        expect((await send('retry', 'health')).payload['ok'], true);
        expect(host.liveProcessCount, 1);
      });
    }

    test('cancellation before process acquisition prevents dispatch', () async {
      final pending = send('early', 'listObjects');
      final cancelled = expectLater(pending, throwsA(isA<ListingCancelled>()));
      host.cancelListings();
      await cancelled.timeout(const Duration(seconds: 1));
      expect(host.liveProcessCount, 0);
      expect((await send('next', 'health')).payload['ok'], true);
    });

    test('cancels active and queued listings while preserving the upload owner',
        () async {
      final uploadStarted = Completer<void>();
      var uploadFinished = false;
      final upload =
          send('upload', 'startUpload', event: (_) => uploadStarted.complete())
              .then((response) {
        uploadFinished = true;
        return response;
      });
      await uploadStarted.future.timeout(const Duration(seconds: 5));
      final listingStarted = Completer<void>();
      final listing = send('active', 'listObjects',
          event: (_) => listingStarted.complete());
      final activeCancelled =
          expectLater(listing, throwsA(isA<ListingCancelled>()));
      await listingStarted.future.timeout(const Duration(seconds: 5));
      final queued = send('queued', 'listBuckets');
      final queuedCancelled =
          expectLater(queued, throwsA(isA<ListingCancelled>()));
      final health = send('health', 'health');
      expect(host.queuedRequestCount, 2);
      host.cancelListings();
      host.cancelListings();
      await Future.wait([activeCancelled, queuedCancelled])
          .timeout(const Duration(seconds: 1));
      expect((await health.timeout(const Duration(seconds: 5))).payload['ok'],
          true);
      expect(uploadFinished, false);
      expect(host.queuedRequestCount, 0);
      expect(
          (await send('stop-upload', 'cancelTransfer',
                  params: {'jobId': 'upload-job'}))
              .payload['ok'],
          true);
      await upload.timeout(const Duration(seconds: 1));
    });
  }, skip: Platform.isWindows);
}
