import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:s3_browser_crossplat/app/s3_browser_app.dart';
import 'package:s3_browser_crossplat/controllers/app_controller.dart';
import 'package:s3_browser_crossplat/models/domain_models.dart';
import 'package:s3_browser_crossplat/services/encryption_key_store.dart';
import 'package:s3_browser_crossplat/services/mock_engine_service.dart';
import 'package:s3_browser_crossplat/settings/settings_sections.dart';
import 'package:s3_browser_crossplat/settings/client_encryption_editor.dart';
import 'package:s3_browser_crossplat/settings/encryption_settings.dart';
import 'package:s3_browser_crossplat/theme/app_theme.dart';
import 'package:s3_browser_crossplat/widgets/app_select_field.dart';

const _profile = EndpointProfile(
  id: 'legibility',
  name: 'Studio storage',
  endpointUrl: 'https://s3.eu-central-1.example.com',
  region: 'eu-central-1',
  accessKey: 'fixture',
  secretKey: 'fixture',
  pathStyle: true,
  verifyTls: true,
);

// Inspect the rendered size, including Material's floating-label transform,
// the preference scaler and any inherited span style. Icon glyphs are not UI
// copy; editable/user values are not subject to the caption-size assertion.
int _checkParagraphs(RenderObject root, {required bool checkSize}) {
  var checked = 0;
  void walk(RenderObject object) {
    if (object is RenderOffstage && object.offstage) return;
    if (object is RenderOpacity && object.opacity == 0) return;
    if (object is RenderAnimatedOpacity && object.opacity.value == 0) return;
    if (object is RenderParagraph && object.hasSize) {
      final matrix = object.getTransformTo(null).storage;
      final paintScale =
          math.sqrt(matrix[0] * matrix[0] + matrix[1] * matrix[1]);
      void spans(InlineSpan span, TextStyle inherited) {
        if (span is! TextSpan) return;
        final style = inherited.merge(span.style);
        final text = span.text;
        final family = style.fontFamily ?? '';
        if (text != null &&
            text.trim().isNotEmpty &&
            text != _profile.name &&
            text != _profile.endpointUrl &&
            !family.toLowerCase().contains('icons')) {
          checked++;
          if (checkSize) {
            final effectiveSize =
                object.textScaler.scale(style.fontSize ?? 14) * paintScale;
            expect(effectiveSize, greaterThanOrEqualTo(12 - 0.01),
                reason: 'Small settings text: "$text" ($effectiveSize px)');
          }
        }
        for (final child in span.children ?? const <InlineSpan>[]) {
          spans(child, style);
        }
      }

      spans(object.text, const TextStyle());
    }
    object.visitChildren(walk);
  }

  walk(root);
  return checked;
}

Future<void> _inspectSection(WidgetTester tester, String section,
    {required int scale}) async {
  final content = find.byKey(ValueKey('settings-content-$section'));
  expect(content, findsOneWidget);
  final scrollable =
      find.descendant(of: content, matching: find.byType(Scrollable)).first;
  final position = tester.state<ScrollableState>(scrollable).position;
  position.jumpTo(0);
  await tester.pump(const Duration(milliseconds: 350));
  var checked = 0;
  for (var page = 0; page < 80; page++) {
    expect(tester.takeException(), isNull,
        reason: '$section, scale $scale, page $page');
    checked +=
        _checkParagraphs(tester.renderObject(content), checkSize: scale == 100);
    if (position.extentAfter < 1) break;
    position.jumpTo(math.min(position.maxScrollExtent,
        position.pixels + position.viewportDimension * .75));
    await tester.pump(const Duration(milliseconds: 350));
    expect(page, lessThan(79), reason: 'Settings scroll must reach its end');
  }
  expect(checked, greaterThan(0), reason: 'Must inspect settings paragraphs');
}

void main() {
  test('field captions and helpers have readable sizes and AA contrast', () {
    for (final desktop in [true, false]) {
      for (final dark in [false, true]) {
        final theme = dark
            ? AppTheme.dark(scalePercent: 100, desktopCompact: desktop)
            : AppTheme.light(scalePercent: 100, desktopCompact: desktop);
        final fields = theme.inputDecorationTheme;
        final minimum = desktop ? 12.5 : 13.0;
        expect(fields.labelStyle!.fontSize!, greaterThanOrEqualTo(minimum));
        expect(fields.floatingLabelStyle!.fontSize! * .75,
            greaterThanOrEqualTo(minimum));
        expect(fields.helperStyle!.fontSize!, greaterThanOrEqualTo(minimum));
        final text = fields.helperStyle!.color!.computeLuminance();
        for (final background in [
          theme.colorScheme.surface,
          theme.colorScheme.surfaceContainerHighest
        ]) {
          final surface = background.computeLuminance();
          final contrast =
              (math.max(text, surface) + .05) / (math.min(text, surface) + .05);
          expect(contrast, greaterThanOrEqualTo(4.5));
        }
      }
    }
  });

  for (final size in [
    const Size(1000, 760),
    const Size(1280, 860),
    const Size(390, 844)
  ]) {
    for (final scale in [100, 150]) {
      testWidgets('Vault protection and secret dialogs ${size.width}, $scale%',
          (tester) async {
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = size;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final controller = AppController(
            engineService: MockEngineService(),
            initialSettings: AppSettings.fromJson({'enableAnimations': false}),
            initialProfiles: const []);
        addTearDown(controller.dispose);
        Widget app(Widget child) => MaterialApp(
              theme: AppTheme.dark(
                  scalePercent: scale, desktopCompact: size.width >= 700),
              home: Scaffold(body: child),
            );
        for (final policy in ClientEncryptionPolicy.values) {
          for (final names in [false, true]) {
            await tester.pumpWidget(app(SingleChildScrollView(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: VaultProtectionControls(
                  policy: policy,
                  encryptNames: names,
                  onPolicyChanged: (_) {},
                  onNamesChanged: (_) {},
                ),
              ),
            )));
            await tester.pump();
            expect(tester.takeException(), isNull);
            expect(
                _checkParagraphs(
                    tester.renderObject(find.byType(VaultProtectionControls)),
                    checkSize: scale == 100),
                greaterThan(0));
          }
        }
        // Exercise wrapping generated secrets and passphrase actions in the
        // same small and large viewports as the settings sections.
        for (final passphrase in [false, true]) {
          await tester.pumpWidget(app(Builder(
              builder: (context) => TextButton(
                    onPressed: () => passphrase
                        ? showEncryptionKeyFileDialog(context, controller,
                            action: 'Create key file')
                        : showEncryptionKeyDialog(context, controller),
                    child: const Text('Open'),
                  ))));
          await tester.tap(find.text('Open'));
          await tester.pumpAndSettle();
          if (passphrase) {
            await tester.ensureVisible(find.text('Generate passphrase'));
            await tester.tap(find.text('Generate passphrase'));
            await tester.pumpAndSettle();
          }
          expect(tester.takeException(), isNull);
          // Tear down the route without attempting persistence.
          await tester.pumpWidget(const SizedBox.shrink());
        }
      });
      for (final dark in [false, true]) {
        testWidgets(
            'Settings ${size.width}x${size.height}, $scale%, dark=$dark',
            (tester) async {
          debugDefaultTargetPlatformOverride =
              size.width < 700 ? TargetPlatform.android : TargetPlatform.macOS;
          tester.view.devicePixelRatio = 1;
          tester.view.physicalSize = size;
          addTearDown(tester.view.resetPhysicalSize);
          addTearDown(tester.view.resetDevicePixelRatio);
          final directory = (await tester.runAsync(
              () => Directory.systemTemp.createTemp('settings-legibility-')))!;
          addTearDown(() => directory.delete(recursive: true));
          final controller = AppController(
            engineService: MockEngineService(),
            initialSettings: AppSettings.fromJson({
              'defaultEngineId': 'python',
              'enableAnimations': false,
              'uiScalePercent': scale,
              'darkMode': dark,
            }),
            initialProfiles: const [_profile],
            encryptionKeyStore:
                EncryptionKeyStore(File('${directory.path}/keys.age')),
          );
          try {
            await controller.initialize();
            controller.selectTab(WorkspaceTab.settings);
            await tester.pumpWidget(S3BrowserApp(controller: controller));
            await tester.pump(const Duration(milliseconds: 400));
            for (final section in settingsSections) {
              controller.setSettingsSection(section);
              await tester.pump(const Duration(milliseconds: 400));
              // The key-file status checks real I/O. Alternate the real and
              // widget zones so its continuation can also rebuild the UI.
              await tester.runAsync(
                  () => Future<void>.delayed(const Duration(milliseconds: 10)));
              await tester.pump(const Duration(milliseconds: 400));
              await _inspectSection(tester, section, scale: scale);
              if (section == 'Connections') {
                await tester.ensureVisible(find.text(_profile.name).last);
                await tester.pump(const Duration(milliseconds: 350));
                await tester.tap(find.text(_profile.name).last);
                await tester.pump(const Duration(milliseconds: 350));
                for (final group in [
                  'Bucket access and endpoint capabilities',
                  'Advanced transport'
                ]) {
                  await tester.ensureVisible(find.text(group));
                  await tester.pump(const Duration(milliseconds: 350));
                  await tester.tap(find.text(group));
                  await tester.pump(const Duration(milliseconds: 350));
                }
                await _inspectSection(tester, section, scale: scale);
                // Exercise the other provider forms, including service-account
                // actions and captions, without opening native file pickers.
                for (final type in [
                  EndpointProfileType.azureBlob,
                  EndpointProfileType.googleCloudStorage
                ]) {
                  final picker =
                      tester.widget<AppSelectField<EndpointProfileType>>(
                          find.byWidgetPredicate(
                              (w) => w is AppSelectField<EndpointProfileType>));
                  picker.onChanged!(type);
                  await tester.pump(const Duration(milliseconds: 400));
                  await _inspectSection(tester, section, scale: scale);
                }
              }
            }
          } finally {
            await tester.pumpWidget(const SizedBox.shrink());
            controller.dispose();
            // Flutter checks this before tearDown callbacks run.
            debugDefaultTargetPlatformOverride = null;
          }
        });
      }
    }
  }
}
