import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:s3_browser_crossplat/app/s3_browser_app.dart';
import 'package:s3_browser_crossplat/models/domain_models.dart';
import 'package:s3_browser_crossplat/settings/settings_workspace.dart';
import 'package:s3_browser_crossplat/theme/app_motion.dart';
import 'improvements_test.dart' as fixture;

void main() {
  testWidgets('push direction follows the visible menu layout', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1440, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final c = fixture.controller(fixture.TestingEngine(), fixture.Repository());
    addTearDown(c.dispose);
    await c.initialize();
    c.clearBanner();
    c.settings = c.settings.copyWith(enableAnimations: true);
    await tester.pumpWidget(S3BrowserApp(controller: c));
    await tester.pumpAndSettle();
    final shell = tester
        .widget<DirectionalSwitcher>(find.byType(DirectionalSwitcher).first);
    expect(shell.replaceContent, isTrue);
    expect(shell.axis, Axis.vertical);
    expect(shell.duration, const Duration(milliseconds: 300));
    final inspector = tester.widget<DirectionalSwitcher>(
        find.byKey(const ValueKey('inspector-content-replacement')));
    expect(inspector.axis, Axis.horizontal);
    final browserBounds = tester.getRect(find.byKey(const ValueKey('browser')));
    c.selectTab(WorkspaceTab.settings);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    final enteringSettings =
        tester.getRect(find.byKey(const ValueKey('settings')));
    expect(enteringSettings.left, closeTo(browserBounds.left, .001));
    expect(enteringSettings.top, greaterThan(browserBounds.top));
    await tester.pumpAndSettle();
    final sectionFinder = find.descendant(
        of: find.byType(SettingsWorkspace),
        matching: find.byType(DirectionalSwitcher));
    var section = tester.widget<DirectionalSwitcher>(sectionFinder);
    expect(section.replaceContent, isTrue);
    expect(section.axis, Axis.vertical);
    expect(section.duration, const Duration(milliseconds: 300));
    for (final (width, expectedAxis) in [
      (1100.0, Axis.vertical),
      (900.0, Axis.horizontal),
      (390.0, Axis.horizontal),
    ]) {
      await tester.binding.setSurfaceSize(Size(width, 900));
      await tester.pumpAndSettle();
      final responsiveShell = tester
          .widget<DirectionalSwitcher>(find.byType(DirectionalSwitcher).first);
      expect(responsiveShell.axis, expectedAxis,
          reason: 'The transition follows the visible menu at width $width');
      expect(tester.widget<DirectionalSwitcher>(sectionFinder).axis,
          Axis.vertical);
    }
    await c.updateSettings(c.settings.copyWith(enableAnimations: false));
    await tester.pumpAndSettle();
    section = tester.widget<DirectionalSwitcher>(sectionFinder);
    expect(section.duration, Duration.zero);
    expect(
        tester
            .widget<DirectionalSwitcher>(find.byType(DirectionalSwitcher).first)
            .duration,
        Duration.zero);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
