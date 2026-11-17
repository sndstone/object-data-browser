import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:s3_browser_crossplat/browser/browser_workspace.dart';
import 'package:s3_browser_crossplat/controllers/app_controller.dart';
import 'package:s3_browser_crossplat/models/domain_models.dart';
import 'package:s3_browser_crossplat/services/mock_engine_service.dart';
import 'package:s3_browser_crossplat/theme/app_theme.dart';

const _profile = EndpointProfile(
  id: 'upload-picker',
  name: 'Studio storage',
  endpointUrl: 'https://s3.example.com',
  region: 'eu-central-1',
  accessKey: 'fixture',
  secretKey: 'fixture',
  pathStyle: true,
  verifyTls: true,
);
const _bucket = BucketSummary(
    name: 'studio-assets',
    region: 'eu-central-1',
    objectCountHint: 1,
    versioningEnabled: false);

void main() {
  for (final size in [const Size(1280, 860), const Size(390, 844)]) {
    for (final empty in [false, true]) {
      testWidgets('Upload picker at ${size.width}, empty=$empty',
          (tester) async {
        // A narrow desktop window must use the same sheet as a phone.
        debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = size;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final controller = AppController(
          engineService: MockEngineService(),
          initialSettings: AppSettings.fromJson({
            'enableAnimations': false,
            'browserInspectorVisible': false,
          }),
          initialProfiles: const [_profile],
        )
          ..selectedProfile = _profile
          ..selectedBucket = _bucket
          ..buckets = const [_bucket]
          ..objects = empty
              ? const []
              : [
                  ObjectEntry(
                    key: 'file.txt',
                    name: 'file.txt',
                    size: 10,
                    storageClass: 'STANDARD',
                    modifiedAt: DateTime(2026),
                    isFolder: false,
                  )
                ];
        try {
          await tester.pumpWidget(MaterialApp(
            theme: AppTheme.light(scalePercent: 100, desktopCompact: true),
            home: Scaffold(
                body: BrowserWorkspace(
                    controller: controller, compact: size.width < 1000)),
          ));
          await tester.pump(const Duration(milliseconds: 400));
          if (size.width < 700) {
            await tester.tap(find.text('Objects'));
            await tester.pump(const Duration(milliseconds: 400));
          }
          final button = find.byKey(ValueKey(
              empty ? 'empty-bucket-upload-button' : 'object-upload-button'));
          await tester.ensureVisible(button);
          await tester.pump(const Duration(milliseconds: 350));
          final bottom = tester.getBottomLeft(button).dy;
          await tester.tap(button);
          await tester.pump(const Duration(milliseconds: 400));
          expect(find.text('Upload files'), findsOneWidget);
          expect(find.text('Upload folder'), findsOneWidget);
          if (size.width >= 1000) {
            expect(find.byType(BottomSheet), findsNothing);
            final entries = find.byType(PopupMenuItem<String>);
            expect(entries, findsNWidgets(2));
            expect(tester.getTopLeft(entries.first).dy,
                greaterThanOrEqualTo(bottom));
            await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
            await tester.sendKeyEvent(LogicalKeyboardKey.escape);
            await tester.pump(const Duration(milliseconds: 400));
            expect(entries, findsNothing);
            // Buttons retain their standard Enter/Space activation behavior.
            final label =
                find.descendant(of: button, matching: find.byType(Text)).first;
            Focus.of(tester.element(label)).requestFocus();
            await tester.pump();
            for (final key in [
              LogicalKeyboardKey.enter,
              LogicalKeyboardKey.space
            ]) {
              await tester.sendKeyEvent(key);
              await tester.pump(const Duration(milliseconds: 400));
              expect(entries, findsNWidgets(2));
              await tester.sendKeyEvent(LogicalKeyboardKey.escape);
              await tester.pump(const Duration(milliseconds: 400));
            }
          } else {
            expect(find.byType(BottomSheet), findsOneWidget);
            expect(find.byType(PopupMenuItem<String>), findsNothing);
            Navigator.of(tester.element(find.text('Upload folder'))).pop();
            await tester.pump(const Duration(milliseconds: 400));
          }
          expect(tester.takeException(), isNull);
        } finally {
          await tester.pumpWidget(const SizedBox.shrink());
          controller.dispose();
          debugDefaultTargetPlatformOverride = null;
        }
      });
    }
  }
}
