import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:s3_browser_crossplat/services/desktop_engine_host.dart';

void main() {
  late Directory tempDir;
  late String scriptPath;
  late DesktopEngineHost host;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('engine_host_test');
    scriptPath = '${tempDir.path}${Platform.pathSeparator}engine.sh';
    // A fake sidecar engine: serves many requests from one stdin loop, echoes
    // the requestId, reports how many requests this process has handled, and
    // emits an event line plus a stderr diagnostic per request.
    await File(scriptPath).writeAsString('''
count=0
while IFS= read -r line; do
  count=\$((count+1))
  case "\$line" in
    *__die__*) echo "boom" >&2; exit 7 ;;
  esac
  rid=\$(printf '%s' "\$line" | sed -n 's/.*"requestId":"\\([^"]*\\)".*/\\1/p')
  printf '{"event":"testEvent","seq":%s}\\n' "\$count"
  printf 'diagnostic %s\\n' "\$count" >&2
  printf '{"requestId":"%s","ok":true,"result":{"count":%s}}\\n' "\$rid" "\$count"
done
''');
    host = DesktopEngineHost();
  });

  tearDown(() async {
    host.dispose();
    await tempDir.delete(recursive: true);
  });

  Future<DesktopEngineHostResponse> send(
    String requestId, {
    String method = 'noop',
    void Function(Map<String, Object?> event)? onEvent,
  }) {
    return host.send(
      executablePath: '/bin/sh',
      arguments: [scriptPath],
      request: <String, Object?>{
        'requestId': requestId,
        'method': method,
        'params': const <String, Object?>{},
      },
      onEvent: onEvent,
    );
  }

  test(
    'reuses one process across sequential requests',
    () async {
      final first = await send('req-1');
      final second = await send('req-2');
      expect(
        (first.payload['result'] as Map?)?['count'],
        1,
      );
      expect(
        (second.payload['result'] as Map?)?['count'],
        2,
        reason: 'A reused process should report a higher request count.',
      );
    },
    skip: Platform.isWindows,
  );

  test(
    'matches concurrent responses to requests by requestId',
    () async {
      final responses = await Future.wait([
        send('req-a'),
        send('req-b'),
      ]);
      expect(responses[0].payload['requestId'], 'req-a');
      expect(responses[1].payload['requestId'], 'req-b');
    },
    skip: Platform.isWindows,
  );

  test(
    'routes event lines to onEvent and keeps them out of the payload',
    () async {
      final events = <Map<String, Object?>>[];
      final response = await send('req-events', onEvent: events.add);
      expect(events, hasLength(1));
      expect(events.single['event'], 'testEvent');
      expect(response.payload['ok'], true);
    },
    skip: Platform.isWindows,
  );

  test(
    'captures stderr diagnostics per request',
    () async {
      final first = await send('req-1');
      final second = await send('req-2');
      expect(first.stderrOutput, contains('diagnostic 1'));
      expect(second.stderrOutput, contains('diagnostic 2'));
      expect(second.stderrOutput, isNot(contains('diagnostic 1')));
    },
    skip: Platform.isWindows,
  );

  test(
    'fails the pending request when the process dies and then respawns',
    () async {
      await expectLater(
        send('req-die', method: '__die__'),
        throwsA(isA<ProcessException>()),
      );
      final recovered = await send('req-after');
      expect(
        (recovered.payload['result'] as Map?)?['count'],
        1,
        reason: 'A fresh process should have been spawned after the crash.',
      );
    },
    skip: Platform.isWindows,
  );

  test(
    'dispose rejects further requests',
    () async {
      await send('req-1');
      host.dispose();
      await expectLater(send('req-2'), throwsA(isA<StateError>()));
    },
    skip: Platform.isWindows,
  );
}
