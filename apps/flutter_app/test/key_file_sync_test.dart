import 'package:flutter_test/flutter_test.dart';
import 'support/key_file_sync_scenarios.dart' as checks;

void main() {
  for (final entry in checks.scenarios.entries) {
    test(entry.key, entry.value);
  }
}
