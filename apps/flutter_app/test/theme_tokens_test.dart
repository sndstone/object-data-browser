import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:s3_browser_crossplat/theme/app_theme.dart';

double _contrast(Color a, Color b) {
  final la = a.computeLuminance(), lb = b.computeLuminance();
  return (math.max(la, lb) + 0.05) / (math.min(la, lb) + 0.05);
}

void main() {
  test('benchmark operation colours keep contrast in light and dark themes',
      () {
    for (final theme in [
      AppTheme.light(scalePercent: 100, desktopCompact: false),
      AppTheme.dark(scalePercent: 100, desktopCompact: false),
    ]) {
      final colors = theme.extension<AppOperationColors>()!;
      expect(
          colors,
          theme.brightness == Brightness.dark
              ? AppOperationColors.dark
              : AppOperationColors.light);
      for (final op in ['PUT', 'GET', 'DELETE', 'POST', 'HEAD', 'LIST']) {
        final ratio =
            _contrast(colors.forOperation(op), theme.colorScheme.surface);
        expect(ratio, greaterThanOrEqualTo(4.5),
            reason: '$op on ${theme.brightness.name} surface');
      }
    }
    expect(AppOperationColors.light.forOperation('get'),
        AppOperationColors.light.get);
  });
}
