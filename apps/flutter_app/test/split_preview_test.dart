import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:s3_browser_crossplat/app/s3_browser_app.dart';
import 'package:s3_browser_crossplat/browser/object_preview_dialog.dart';
import 'package:s3_browser_crossplat/models/domain_models.dart';
import 'package:s3_browser_crossplat/theme/app_motion.dart';
import 'improvements_test.dart' as fixture;

final _modified = DateTime(2026, 10, 27, 9, 42);

ObjectEntry document() => ObjectEntry(
    key: 'site/releases/index.html',
    name: 'index.html',
    size: 112 * 1024,
    storageClass: 'STANDARD',
    modifiedAt: _modified,
    isFolder: false);

const htmlSource = '<h1>Field notes</h1><p>Selectable sample</p>';
ObjectPreview preview() => ObjectPreview.ready(
    key: document().key,
    kind: ObjectPreviewKind.text,
    contentType: 'text/html',
    text: htmlSource,
    message: 'Preview loaded.',
    loadedBytes: 64 * 1024,
    truncated: true);

Future<void> viewport(WidgetTester tester, Size size) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = size;
  await tester.binding.setSurfaceSize(size);
  addTearDown(() async {
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
    await tester.binding.setSurfaceSize(null);
  });
}

void main() {
  testWidgets('details disclose metadata and open the existing bounded preview',
      (tester) async {
    await viewport(tester, const Size(1500, 1000));
    final c = fixture.controller(fixture.TestingEngine(), fixture.Repository());
    addTearDown(c.dispose);
    await c.initialize();
    c.settings =
        c.settings.copyWith(enableAnimations: false, uiScalePercent: 100);
    c.selectedObject = document();
    c.selectedObjectDetails = ObjectDetails(
        key: document().key,
        metadata: const {'owner': 'synthetic-team'},
        headers: const {'Cache-Control': 'max-age=3600'},
        tags: const {'release': 'autumn'},
        debugEvents: const [],
        apiCalls: const []);
    c.selectedObjectPreview = preview();
    c.inspectorTab = BrowserInspectorTab.objectDetails;
    c.clearBanner();
    await tester.pumpWidget(S3BrowserApp(controller: c));
    await tester.pumpAndSettle();
    expect(find.text('synthetic-team'), findsNothing);
    await tester.tap(find.text('Metadata'));
    await tester.pumpAndSettle();
    expect(find.text('synthetic-team'), findsOneWidget);
    await tester.tap(find.byTooltip('Open preview'));
    await tester.pumpAndSettle();
    expect(find.byType(ObjectPreviewDialog), findsOneWidget);
    expect(c.inspectorTab, BrowserInspectorTab.objectDetails);
    expect(find.byKey(const ValueKey('preview-context-rail')), findsOneWidget);
    expect(find.byKey(const ValueKey('expanded-preview-truncated')),
        findsOneWidget);
    expect(
        find.byKey(const ValueKey('expanded-source-preview')), findsOneWidget);
    expect(find.text('Preview loaded.'), findsNothing,
        reason: 'No repeated success status');
    await tester.tap(find.byTooltip('Close preview'));
    await tester.pumpAndSettle();
    expect(find.text('synthetic-team'), findsOneWidget,
        reason: 'Expansion is retained');
    c.setInspectorTab(BrowserInspectorTab.objectPreview);
    await tester.pumpAndSettle();
    c.setInspectorTab(BrowserInspectorTab.objectDetails);
    await tester.pumpAndSettle();
    expect(find.text('synthetic-team'), findsOneWidget,
        reason: 'Disclosure choices survive inspector navigation');
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  for (final (size, scale) in [
    (const Size(1100, 800), 1.0),
    (const Size(390, 844), 1.0),
    (const Size(800, 600), 2.0),
  ]) {
    testWidgets('preview adapts and preserves identity at $size text=$scale',
        (tester) async {
      await viewport(tester, size);
      final c =
          fixture.controller(fixture.TestingEngine(), fixture.Repository());
      addTearDown(c.dispose);
      c.settings = c.settings.copyWith(enableAnimations: false);
      await tester.pumpWidget(MaterialApp(
          builder: (context, child) => MediaQuery(
              data: MediaQuery.of(context)
                  .copyWith(textScaler: TextScaler.linear(scale)),
              child: child!),
          home: Scaffold(
              body: Builder(
                  builder: (context) => TextButton(
                      onPressed: () => showDialog<void>(
                          context: context,
                          builder: (_) => ObjectPreviewDialog(
                              controller: c,
                              object: document(),
                              preview: preview())),
                      child: const Text('Show fixture'))))));
      await tester.tap(find.text('Show fixture'));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('rendered-html-page')), findsNothing);
      expect(find.byKey(const ValueKey('source-code-xml')), findsOneWidget);
      final source = find.byKey(const ValueKey('source-code-xml'));
      final sourceArea = find.byKey(const ValueKey('expanded-source-preview'));
      expect(tester.getTopLeft(source).dy - tester.getTopLeft(sourceArea).dy,
          closeTo(12, .1),
          reason: 'Short documents start at the top, not in the center');
      final editable = tester.state<EditableTextState>(
          find.descendant(of: source, matching: find.byType(EditableText)));
      expect(
          editable.renderEditable
              .getLocalRectForCaret(const TextPosition(offset: 0))
              .top,
          closeTo(
              editable.renderEditable
                  .getLocalRectForCaret(
                      const TextPosition(offset: htmlSource.length))
                  .top,
              .1),
          reason: 'A source line scrolls horizontally without wrapping');
      await tester.tap(find.text('Render page'));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('rendered-html-page')), findsOneWidget);
      // Selection changes behind the dialog cannot change its object context.
      c.selectedObject = ObjectEntry(
          key: 'other.txt',
          name: 'other.txt',
          size: 1,
          storageClass: 'STANDARD',
          modifiedAt: _modified,
          isFolder: false);
      expect(find.text('site/releases/index.html'), findsOneWidget);
      if (size.width < 700 || scale > 1.5) {
        expect(
            find.byKey(const ValueKey('preview-context-rail')), findsNothing);
        await tester.tap(find.text('File details'));
        await tester.pumpAndSettle();
        expect(find.text('STANDARD'), findsOneWidget);
      } else {
        expect(
            find.byKey(const ValueKey('preview-context-rail')), findsOneWidget);
      }
      expect(tester.takeException(), isNull);
      await tester.tap(find.byTooltip('Close preview'));
      await tester.pumpAndSettle();
      expect(find.byType(ObjectPreviewDialog), findsNothing);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }

  testWidgets('image preview preserves pan/zoom with usable fit controls',
      (tester) async {
    await viewport(tester, const Size(1100, 800));
    final c = fixture.controller(fixture.TestingEngine(), fixture.Repository());
    addTearDown(c.dispose);
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: ObjectPreviewDialog(
                controller: c,
                object: document(),
                preview: ObjectPreview.ready(
                    key: document().key,
                    kind: ObjectPreviewKind.image,
                    message: '',
                    contentType: 'image/png')))));
    await tester.pumpAndSettle();
    final viewer = find.byType(InteractiveViewer);
    expect(viewer, findsOneWidget);
    await tester.tap(find.byTooltip('Zoom in'));
    await tester.pumpAndSettle();
    expect(
        tester
            .widget<InteractiveViewer>(viewer)
            .transformationController!
            .value
            .getMaxScaleOnAxis(),
        1.25);
    await tester.tap(find.byTooltip('Fit image'));
    await tester.pumpAndSettle();
    expect(
        tester
            .widget<InteractiveViewer>(viewer)
            .transformationController!
            .value
            .getMaxScaleOnAxis(),
        1);
    expect(find.text('Render page'), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
      'HTML mode motion respects reduced motion and copied text stays exact',
      (tester) async {
    final c = fixture.controller(fixture.TestingEngine(), fixture.Repository());
    addTearDown(c.dispose);
    String? copied;
    tester.binding.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') {
        copied = (call.arguments as Map)['text'] as String;
      }
      return null;
    });
    addTearDown(() => tester.binding.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null));
    for (final reduced in [false, true]) {
      await tester.pumpWidget(MaterialApp(
          home: MediaQuery(
              data: MediaQueryData(
                  size: const Size(1100, 800), disableAnimations: reduced),
              child: Scaffold(
                  body: ObjectPreviewDialog(
                      controller: c,
                      object: document(),
                      preview: preview())))));
      await tester.pumpAndSettle();
      final switcher = find.descendant(
          of: find.byType(ObjectPreviewDialog),
          matching: find.byType(DirectionalSwitcher));
      expect(tester.widget<DirectionalSwitcher>(switcher).duration,
          reduced ? Duration.zero : const Duration(milliseconds: 220));
    }
    // Verify the exact loaded source rather than line-number/display text.
    tester
        .widget<IconButton>(
            find.widgetWithIcon(IconButton, Icons.copy_outlined).last)
        .onPressed!();
    await tester.pump();
    expect(copied, htmlSource);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
