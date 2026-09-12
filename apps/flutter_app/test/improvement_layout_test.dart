import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:s3_browser_crossplat/app/s3_browser_app.dart';
import 'package:s3_browser_crossplat/models/domain_models.dart';
import 'package:s3_browser_crossplat/settings/settings_sections.dart';
import 'improvements_test.dart' as fixture;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    final icons = FontLoader('MaterialIcons')
      ..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'));
    await icons.load();
    for (final family in ['Inter', 'Sora']) {
      final loader = FontLoader(family)
        ..addFont(rootBundle.load('assets/fonts/$family.ttf'));
      await loader.load();
    }
  });
  for (final width in [390.0, 700.0, 1000.0, 1360.0, 1500.0]) {
    for (final dark in [false, true]) {
      for (final scale in [130, 200]) {
        testWidgets('settings at $width dark=$dark text=$scale',
            (tester) async {
          tester.view.devicePixelRatio = 1;
          tester.view.physicalSize = Size(width, 1100);
          await tester.binding.setSurfaceSize(Size(width, 1100));
          addTearDown(() async {
            tester.view.resetPhysicalSize();
            tester.view.resetDevicePixelRatio();
            await tester.binding.setSurfaceSize(null);
          });
          final c =
              fixture.controller(fixture.TestingEngine(), fixture.Repository());
          await c.initialize();
          c.settings =
              c.settings.copyWith(darkMode: dark, uiScalePercent: scale);
          c.activeTab = WorkspaceTab.settings;
          c.clearBanner();
          final key = GlobalKey();
          await tester.pumpWidget(
              RepaintBoundary(key: key, child: S3BrowserApp(controller: c)));
          await tester.pumpAndSettle();
          for (final section in settingsSections) {
            c.setSettingsSection(section);
            await tester.pumpAndSettle();
            expect(tester.takeException(), isNull, reason: section);
            if (section == 'Connections') {
              final connection = find.ancestor(
                  of: find.byIcon(Icons.chevron_right),
                  matching: find.byType(ListTile));
              await tester.ensureVisible(connection);
              await tester.pumpAndSettle();
              await tester.tap(connection);
              await tester.pumpAndSettle();
              final name = find.widgetWithText(TextField, 'Profile name');
              expect(name, findsOneWidget);
              await tester.ensureVisible(name);
              await tester.pumpAndSettle();
              await tester.tap(name);
              await tester.sendKeyEvent(LogicalKeyboardKey.tab);
              expect(FocusManager.instance.primaryFocus, isNotNull);
              expect(tester.takeException(), isNull,
                  reason: 'Expanded connection editor');
            }
            if (Platform.environment['IMPROVEMENT_CAPTURE'] == '1' &&
                scale == 200 &&
                !dark &&
                (width == 390 || width == 1500) &&
                (section == 'Connections' ||
                    section == 'Transfers & Storage')) {
              await tester.runAsync(() async {
                final image = await (key.currentContext!.findRenderObject()
                        as RenderRepaintBoundary)
                    .toImage();
                final bytes =
                    await image.toByteData(format: ui.ImageByteFormat.png);
                final file = File(
                    '../../.tmp/improvement-review/${width.toInt()}-${section.split(' ').first}.png');
                await file.parent.create(recursive: true);
                await file.writeAsBytes(bytes!.buffer.asUint8List());
                image.dispose();
              });
            }
          }
          await tester.pumpWidget(const SizedBox.shrink());
          c.dispose();
        });
      }
    }
  }
}
