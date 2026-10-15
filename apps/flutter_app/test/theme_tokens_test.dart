import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:s3_browser_crossplat/theme/app_theme.dart';
import 'package:s3_browser_crossplat/widgets/app_slider.dart';
import 'package:s3_browser_crossplat/widgets/app_switch.dart';

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

  testWidgets('switch and ruler labels use legible sizes', (tester) async {
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: Column(children: [
      AppRulerSlider(
          value: 100,
          min: 50,
          max: 200,
          step: 10,
          defaultValue: 100,
          onChanged: (_) {}),
      AppSwitch(value: false, onChanged: (_) {}),
    ]))));
    expect(tester.takeException(), isNull);
    final off = tester.widget<Text>(find.text('OFF'));
    expect(off.style!.fontSize, greaterThanOrEqualTo(11));
    expect(tester.getSize(find.byType(AppSwitch)).width,
        greaterThanOrEqualTo(AppSwitch.width));
    final ruler = find.descendant(
        of: find.byType(AppRulerSlider), matching: find.byType(CustomPaint));
    expect(tester.getSize(ruler.last).height, greaterThanOrEqualTo(26));
  });

  test('terminal log colours stay readable and distinct in both themes', () {
    for (final theme in [
      AppTheme.light(scalePercent: 100, desktopCompact: false),
      AppTheme.dark(scalePercent: 100, desktopCompact: false),
    ]) {
      final t = theme.extension<AppTerminalColors>()!;
      expect(_contrast(t.foreground, t.background), greaterThanOrEqualTo(7));
      expect(_contrast(t.muted, t.background), greaterThanOrEqualTo(4.5));
      if (theme.brightness == Brightness.dark) {
        // The panel edge must be visible against the dark card surface.
        expect(_contrast(t.border, theme.colorScheme.surface),
            greaterThan(_contrast(t.background, theme.colorScheme.surface)));
      }
    }
  });
}
