import 'package:flutter_test/flutter_test.dart';
import 'package:s3_browser_crossplat/models/domain_models.dart';
import 'package:s3_browser_crossplat/services/bounded_lines.dart';

void main() {
  test('performance options round trip and old settings retain defaults', () {
    final defaults = AppSettings.fromJson({});
    expect(defaults.performance.progressIntervalMs, 100);
    final changed = defaults.copyWith(
        performance: defaults.performance.copyWith(
            engineIdleSeconds: 0,
            progressIntervalMs: 500,
            listingWindowObjects: 10000,
            copyTimeoutSeconds: 600));
    expect(AppSettings.fromJson(changed.toJson()).performance.toJson(),
        changed.performance.toJson());
    final bounded = PerformanceSettings.fromJson({
      'engineIdleSeconds': -1,
      'progressIntervalMs': 99999,
      'listingWindowObjects': 0,
      'copyTimeoutSeconds': 0
    });
    expect(bounded.engineIdleSeconds, 0);
    expect(bounded.progressIntervalMs, 2000);
    expect(bounded.listingWindowObjects, 1000);
    expect(bounded.copyTimeoutSeconds, 5);
  });
  test('protocol bound applies across chunks before a newline', () async {
    final lines = boundedLines(
        Stream.fromIterable([
          [65, 66],
          [67, 68],
          [69]
        ]),
        maximumBytes: 4);
    await expectLater(lines.toList(), throwsFormatException);
  });
  test('diagnostic truncation recovers at the next line', () async {
    final lines = boundedLines(
        Stream.fromIterable([
          [65, 66, 67],
          [68, 69, 10, 70, 10]
        ]),
        maximumBytes: 4,
        truncate: true);
    expect(await lines.toList(), ['ABCD [truncated]', 'F']);
  });
  test('line decoding retains chunked UTF8 and CRLF', () async {
    final lines = boundedLines(
        Stream.fromIterable([
          [0xc3],
          [0xa9, 13, 10, 65]
        ]),
        maximumBytes: 4);
    expect(await lines.toList(), ['é', 'A']);
  });
}
