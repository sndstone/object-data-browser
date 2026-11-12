import 'package:flutter_test/flutter_test.dart';
import 'package:s3_browser_crossplat/services/transfer_log_accumulator.dart';

void main() {
  test('deltas preserve immutable history and reject gaps', () {
    final logs = TransferLogAccumulator();
    Map<String, Object?> delta(int start, List<String> lines) => {
          'id': 'job',
          'status': 'running',
          'outputStartLine': start,
          'outputLineCount': start + lines.length,
          'outputLines': lines
        };
    final first = logs.accept(delta(0, ['first']))!;
    final second = logs.accept(delta(1, ['second']))!;
    expect(first, ['first']);
    expect(second, ['first', 'second']);
    expect(() => second.add('mutation'), throwsUnsupportedError);
    expect(logs.accept(delta(0, ['first'])), ['first', 'second']);
    expect(logs.accept(delta(3, ['gap'])), isNull);
    expect(
        logs.accept({
          'id': 'job',
          'status': 'completed',
          'outputLines': ['first', 'second', 'final']
        }),
        ['first', 'second', 'final']);
    expect(second, ['first', 'second']);
  });
}
