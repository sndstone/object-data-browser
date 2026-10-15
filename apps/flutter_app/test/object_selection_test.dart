import 'package:flutter_test/flutter_test.dart';
import 'package:s3_browser_crossplat/controllers/object_selection.dart';
import 'package:s3_browser_crossplat/models/domain_models.dart';

void main() {
  test('large mixed delete batches only confirm the successful keys', () {
    final keys = List.generate(100000, (i) => 'folder/object-$i');
    final failures = [
      for (var i = 1; i < keys.length; i += 2)
        BatchOperationFailure(
            target: keys[i], code: 'AccessDenied', message: 'Denied')
    ];
    final result = ObjectSelection.confirmedDeletes(
        keys,
        BatchOperationResult(
            successCount: 50000, failureCount: 50000, failures: failures));
    expect(result.length, 50000);
    expect(
        result.containsAll([for (var i = 0; i < keys.length; i += 2) keys[i]]),
        isTrue);
  });

  test('a foreign or repeated failure cannot confirm any deletes', () {
    for (final targets in [
      ['b', 'unknown'],
      ['b', 'b']
    ]) {
      final result = ObjectSelection.confirmedDeletes(
          ['a', 'b', 'c'],
          BatchOperationResult(successCount: 1, failureCount: 2, failures: [
            for (final target in targets)
              BatchOperationFailure(
                  target: target, code: 'AccessDenied', message: 'Denied')
          ]));
      expect(result, isEmpty);
    }
  });
}
