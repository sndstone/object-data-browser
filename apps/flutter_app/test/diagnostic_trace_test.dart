import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:s3_browser_crossplat/services/diagnostic_safety.dart';
import 'package:s3_browser_crossplat/services/engine_service.dart';
import 'improvements_test.dart' as fixture;

void main() {
  test('trace bounds UTF-8 bytes, depth and collection lengths', () {
    final cases = <Object?>[
      List.generate(10000, (i) => {'key': '$i', 'value': '😀' * 1000}),
      {for (var i = 0; i < 10000; i++) 'key$i': i},
      '😀\n' * 10000,
    ];
    var deep = <String, Object?>{'leaf': true};
    for (var i = 0; i < 100; i++) {
      deep = {'nested': deep};
    }
    cases.add(deep);
    final cycle = <Object?>[];
    cycle.add(cycle);
    cases.add(cycle);
    for (final value in cases) {
      final bounded = DiagnosticSafety.trace(value, maxBytes: 1024);
      expect(utf8.encode(jsonEncode(bounded)).length, lessThanOrEqualTo(1024));
      expect((bounded as Map)['truncated'], true);
    }
    final list = DiagnosticSafety.trace(List.filled(100, 1)) as Map;
    expect((list['value'] as List).length, DiagnosticSafety.traceMaxItems);
    final nested = DiagnosticSafety.trace({
      'a': {'b': 1}
    }, maxDepth: 1) as Map;
    expect(nested['value'], {'a': null});
  });

  test('trace redacts whole keys and strings before shortening', () {
    final value = DiagnosticSafety.trace({
      'secretAccessKey': 'do-not-retain',
      'nested': {'sessionToken': 'also-secret'},
      'url': 'https://example.test/object?X-Amz-Signature=hidden&other=value',
      'text': '${'x' * 200} password=hidden-value ${'y' * 10000}',
      '${'x' * 10000}secretKey': 'oversized-key-value',
    }, maxBytes: 2048);
    final encoded = jsonEncode(value);
    expect(encoded, contains('[redacted]'));
    expect(encoded, contains('"truncated":true'));
    for (final secret in [
      'do-not-retain',
      'also-secret',
      'hidden',
      'hidden-value',
      'oversized-key-value'
    ]) {
      expect(encoded, isNot(contains(secret)));
    }
    expect(utf8.encode(encoded).length, lessThanOrEqualTo(2048));
  });

  test('controller bounds retained engine trace payloads', () async {
    final engine = _LoggingEngine();
    final c = fixture.controller(engine, fixture.Repository());
    addTearDown(c.dispose);
    await c.initialize();
    await c.updateSettings(c.settings.copyWith(enableApiLogging: true));
    engine.sink!(EngineLogRecord(
        level: 'API',
        category: 'Fixture',
        message: 'bounded trace',
        traceHead: {
          'authorization': 'head-secret'
        },
        traceBody: {
          'password': 'body-secret',
          'items': List.generate(10000, (i) => {'key': 'value$i'})
        }));
    final entry = c.eventLog.first;
    final encoded = jsonEncode(entry.traceBody);
    expect(utf8.encode(encoded).length,
        lessThanOrEqualTo(DiagnosticSafety.traceMaxBytes));
    expect(encoded, contains('"truncated":true'));
    expect(encoded, isNot(contains('body-secret')));
    expect(jsonEncode(entry.traceHead), isNot(contains('head-secret')));
  });

  test('small traces preserve their structure and redact credentials', () {
    expect(
        DiagnosticSafety.trace({
          'items': [1, 2],
          'password': 'secret'
        }),
        {
          'items': [1, 2],
          'password': '[redacted]'
        });
  });
}

class _LoggingEngine extends fixture.TestingEngine
    implements EngineLogSinkRegistrant {
  EngineLogCallback? sink;
  @override
  void setLogSink(EngineLogCallback? sink) {
    this.sink = sink;
  }
}
