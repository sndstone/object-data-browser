import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:s3_browser_crossplat/services/desktop_engine_host.dart';

void main() {
  test(
      'background benchmarks keep process affinity and reserve bounded pool slots',
      () async {
    final dir = await Directory.systemTemp.createTemp('benchmark-owner-');
    final script = File('${dir.path}/engine.sh');
    await script.writeAsString(r'''
while IFS= read -r line; do
 rid=$(printf '%s' "$line" | sed -n 's/.*"requestId":"\([^"]*\)".*/\1/p')
 status=running
 case "$line" in *stopBenchmark*) status=stopped ;; esac
 printf '{"requestId":"%s","ok":true,"result":{"id":"bench-%s","pid":"%s","status":"%s"}}\n' "$rid" "$$" "$$" "$status"
done
''');
    final host = DesktopEngineHost(maxProcesses: 2, maxProcessesPerEngine: 2);
    addTearDown(() async {
      host.dispose();
      await dir.delete(recursive: true);
    });
    var sequence = 0;
    Future<Map> send(String method, [String? runId]) async {
      final r = await host.send(executablePath: '/bin/sh', arguments: [
        script.path
      ], request: {
        'requestId': 'req-${++sequence}',
        'method': method,
        'params': {if (runId != null) 'runId': runId}
      });
      return r.payload['result'] as Map;
    }

    final a = await send('startBenchmark');
    final b = await send('startBenchmark');
    expect(a['pid'], isNot(b['pid']));
    expect(host.liveProcessCount, 2);
    var finished = false;
    final queued = send('health').then((r) {
      finished = true;
      return r;
    });
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(finished, isFalse);
    expect(host.queuedRequestCount, 1);
    expect(
        (await send('getBenchmarkStatus', a['id'] as String))['pid'], a['pid']);
    expect((await send('stopBenchmark', a['id'] as String))['pid'], a['pid']);
    expect((await queued)['pid'], a['pid']);
    expect(
        (await send('getBenchmarkStatus', b['id'] as String))['pid'], b['pid']);
    expect(host.liveProcessCount, 2);
  }, skip: Platform.isWindows);
}
