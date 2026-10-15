import 'dart:ui' show Tristate;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter/rendering.dart' show RenderParagraph;
import 'package:flutter_test/flutter_test.dart';
import 'package:s3_browser_crossplat/app/s3_browser_app.dart';
import 'package:s3_browser_crossplat/models/domain_models.dart';
import 'package:s3_browser_crossplat/utils/format.dart';
import 'improvements_test.dart' as fixture;

Future<void> _pumpApp(WidgetTester tester, dynamic controller,
    {Size size = const Size(1440, 900)}) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = size;
  await tester.binding.setSurfaceSize(size);
  addTearDown(() async {
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
    await tester.binding.setSurfaceSize(null);
  });
  await tester.pumpWidget(S3BrowserApp(controller: controller));
  await tester.pumpAndSettle();
}

void main() {
  inspectorMain();
  keyboardNavMain();
  phoneNavMain();
  listingErrorMain();
  footerMain();
  previewReloadMain();
  inlinePreviewMain();
  detailsFailureMain();
  viewToolsMain();
  testWidgets('object filter shows a clear button that resets the filter',
      (tester) async {
    final c = fixture.controller(fixture.TestingEngine(), fixture.Repository());
    await c.initialize();
    c.clearBanner();
    c.setObjectFilterMode(BrowserFilterMode.text);
    await _pumpApp(tester, c);

    final clear = find.byKey(const ValueKey('object-search-clear'));
    expect(clear, findsNothing, reason: 'nothing to clear yet');
    expect(
        find.text('⌘K').evaluate().length +
            find.text('Ctrl K').evaluate().length,
        1);

    await tester.enterText(
        find.byKey(const ValueKey('object-search')), 'no-such-object-xyz');
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pumpAndSettle();
    expect(c.objectFilterValue, 'no-such-object-xyz');
    expect(clear, findsOneWidget);
    expect(find.text('No matching objects'), findsOneWidget);
    final summary = find.byKey(const ValueKey('object-listing-summary'));
    expect(tester.widget<Text>(summary).data,
        startsWith('No matches · ${formatCount(c.objects.length)} loaded'));

    await tester.tap(clear);
    await tester.pumpAndSettle();
    expect(c.objectFilterValue, isEmpty);
    expect(clear, findsNothing);
    expect(find.text('No matching objects'), findsNothing);
    expect(tester.widget<Text>(summary).data, isNot(contains('–0')),
        reason: 'no empty 0–0 range once rows are visible');
    expect(tester.widget<Text>(summary).data,
        contains('${formatCount(c.objects.length)} loaded'));
    expect(tester.takeException(), isNull);

    await tester.pumpWidget(const SizedBox.shrink());
    c.dispose();
  });
}

/// Returns the mock details with no user metadata or tags.
class _BareDetailsEngine extends fixture.TestingEngine {
  @override
  Future<ObjectDetails> getObjectDetails(
      {required String engineId,
      required EndpointProfile profile,
      required String bucketName,
      required String key}) async {
    final details = await super.getObjectDetails(
        engineId: engineId, profile: profile, bucketName: bucketName, key: key);
    return details.copyWith(metadata: const {}, tags: const {});
  }
}

void inspectorMain() {
  testWidgets('inspector names empty metadata, header and tag sections',
      (tester) async {
    final c = fixture.controller(_BareDetailsEngine(), fixture.Repository());
    await c.initialize();
    c.clearBanner();
    await _pumpApp(tester, c);

    final file = c.pagedVisibleObjects.firstWhere((o) => !o.isFolder);
    await tester.tap(find.text(file.name));
    await tester.pumpAndSettle();
    final details = c.selectedObjectDetails!;
    expect(details.tags, isEmpty);
    await tester.dragUntilVisible(find.text('No tags'),
        find.byKey(const ValueKey('object-details')), const Offset(0, -200));
    await tester.pumpAndSettle();
    for (final (entries, placeholder) in [
      (details.metadata, 'No user metadata'),
      (details.headers, 'No headers returned'),
      (details.tags, 'No tags'),
    ]) {
      expect(find.text(placeholder),
          entries.isEmpty ? findsOneWidget : findsNothing);
    }
    expect(details.headers, isNotEmpty);
    expect(find.text('No user metadata'), findsOneWidget);
    expect(find.text('No tags'), findsOneWidget);
    expect(tester.takeException(), isNull);

    await tester.pumpWidget(const SizedBox.shrink());
    c.dispose();
  });
}

void viewToolsMain() {
  testWidgets('view tools expose expanded and toggled states', (tester) async {
    final handle = tester.ensureSemantics();
    final c = fixture.controller(fixture.TestingEngine(), fixture.Repository());
    await c.initialize();
    c.clearBanner();
    await _pumpApp(tester, c);

    final viewTools = find.byKey(const ValueKey('object-view-tools'));
    Tristate expanded() => tester
        .getSemantics(viewTools)
        .getSemanticsData()
        .flagsCollection
        .isExpanded;
    expect(expanded(), Tristate.isFalse);
    await tester.tap(viewTools);
    await tester.pumpAndSettle();
    expect(expanded(), Tristate.isTrue);

    final flatViewButton = find.widgetWithText(TextButton, 'Flat view');
    Tristate flatView() => tester
        .getSemantics(flatViewButton)
        .getSemanticsData()
        .flagsCollection
        .isToggled;
    final before = c.flatView;
    expect(flatView(), before ? Tristate.isTrue : Tristate.isFalse);
    await tester.tap(flatViewButton);
    await tester.pumpAndSettle();
    expect(c.flatView, !before);
    expect(flatView(), before ? Tristate.isFalse : Tristate.isTrue);
    expect(tester.takeException(), isNull);

    await tester.pumpWidget(const SizedBox.shrink());
    c.dispose();
    handle.dispose();
  });
}

class _FailingDetailsEngine extends fixture.TestingEngine {
  bool fail = true;
  @override
  Future<ObjectDetails> getObjectDetails(
      {required String engineId,
      required EndpointProfile profile,
      required String bucketName,
      required String key}) async {
    if (fail) {
      throw const EngineException(
          code: ErrorCode.unknown, message: 'Fixture details failure');
    }
    return super.getObjectDetails(
        engineId: engineId, profile: profile, bucketName: bucketName, key: key);
  }
}

void detailsFailureMain() {
  testWidgets('failed object details offer a retry instead of a select hint',
      (tester) async {
    final engine = _FailingDetailsEngine();
    final c = fixture.controller(engine, fixture.Repository());
    await c.initialize();
    c.clearBanner();
    await _pumpApp(tester, c);

    final file = c.pagedVisibleObjects.firstWhere((o) => !o.isFolder);
    await tester.tap(find.text(file.name));
    await tester.pumpAndSettle();
    expect(c.selectedObject?.key, file.key);
    expect(c.selectedObjectDetails, isNull);
    expect(find.text('Details unavailable'), findsOneWidget);
    expect(find.textContaining('Select an object'), findsNothing);

    engine.fail = false;
    await tester.tap(find.byKey(const ValueKey('object-details-retry')));
    await tester.pumpAndSettle();
    expect(c.selectedObjectDetails, isNotNull);
    expect(find.text('Details unavailable'), findsNothing);
    expect(find.text('Metadata'), findsOneWidget);
    expect(tester.takeException(), isNull);

    await tester.pumpWidget(const SizedBox.shrink());
    c.dispose();
  });
}

void inlinePreviewMain() {
  testWidgets('inline text preview says when it cuts long text short',
      (tester) async {
    final c = fixture.controller(fixture.TestingEngine(), fixture.Repository());
    await c.initialize();
    c.clearBanner();
    await _pumpApp(tester, c);
    final file = c.pagedVisibleObjects.firstWhere((o) => !o.isFolder);
    await c.setSelectedObject(file);
    final notice = find.byKey(const ValueKey('inline-preview-truncated'));

    for (final (length, expected) in [
      (12000, findsNothing),
      (12001, findsOneWidget)
    ]) {
      c.selectedObjectPreview = ObjectPreview(
          key: file.key,
          kind: ObjectPreviewKind.text,
          loading: false,
          supported: true,
          message: '',
          contentType: 'text/plain',
          text: 'a' * length,
          loadedBytes: length);
      c.setInspectorTab(BrowserInspectorTab.objectDetails);
      c.setInspectorTab(BrowserInspectorTab.objectPreview);
      await tester.pumpAndSettle();
      expect(notice, expected, reason: '$length characters');
    }
    expect(find.textContaining('first 12,000 characters'), findsOneWidget);
    expect(find.byTooltip('Open preview'), findsOneWidget);
    expect(tester.takeException(), isNull);

    await tester.pumpWidget(const SizedBox.shrink());
    c.dispose();
  });
}

void previewReloadMain() {
  testWidgets('preview offers Load preview first and reload once loaded',
      (tester) async {
    final c = fixture.controller(fixture.TestingEngine(), fixture.Repository());
    await c.initialize();
    c.clearBanner();
    await _pumpApp(tester, c);
    final file = c.pagedVisibleObjects.firstWhere((o) => !o.isFolder);
    await c.setSelectedObject(file);

    c.selectedObjectPreview = null;
    c.setInspectorTab(BrowserInspectorTab.objectPreview);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('object-preview-load')), findsOneWidget);
    expect(find.byTooltip('Reload preview'), findsNothing);

    c.selectedObjectPreview = ObjectPreview(
        key: file.key,
        kind: ObjectPreviewKind.text,
        loading: false,
        supported: true,
        message: '',
        text: 'hello');
    c.setInspectorTab(BrowserInspectorTab.objectDetails);
    c.setInspectorTab(BrowserInspectorTab.objectPreview);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('object-preview-load')), findsNothing);
    expect(find.byTooltip('Reload preview'), findsOneWidget);
    expect(tester.takeException(), isNull);

    await tester.pumpWidget(const SizedBox.shrink());
    c.dispose();
  });
}

void footerMain() {
  for (final width in const [1000.0, 1440.0]) {
    testWidgets('object list footer stays on one row at ${width.toInt()} px',
        (tester) async {
      final c =
          fixture.controller(fixture.TestingEngine(), fixture.Repository());
      await c.initialize();
      // A second listing page gives more rows than one page shows.
      await c.listAllObjectsForCurrentBucket(all: false);
      c.clearBanner();
      await _pumpApp(tester, c, size: Size(width, 640));
      expect(c.objectPageCount, greaterThan(1));
      expect(c.objectCursor.hasMore, isTrue);

      final summary = find.byKey(const ValueKey('object-listing-summary'));
      final row = [
        summary,
        find.byKey(const ValueKey('object-page-previous')),
        find.byKey(const ValueKey('object-page-next')),
        find.byKey(const ValueKey('object-load-more')),
      ];
      final centerY = tester.getCenter(summary).dy;
      for (final item in row) {
        expect(item, findsOneWidget);
        expect(tester.getCenter(item).dy, moreOrLessEquals(centerY, epsilon: 1),
            reason: '$item shares the footer row');
      }
      expect(tester.takeException(), isNull);

      await tester.pumpWidget(const SizedBox.shrink());
      c.dispose();
    });
  }
}

class _FailingListingEngine extends fixture.TestingEngine {
  bool fail = true;
  @override
  Future<ObjectListResult> listObjects(
      {required String engineId,
      required EndpointProfile profile,
      required String bucketName,
      required String prefix,
      required bool flat,
      ListCursor? cursor}) async {
    if (fail) {
      throw const EngineException(
          code: ErrorCode.authFailed, message: 'Fixture listing denied');
    }
    return super.listObjects(
        engineId: engineId,
        profile: profile,
        bucketName: bucketName,
        prefix: prefix,
        flat: flat,
        cursor: cursor);
  }
}

void listingErrorMain() {
  testWidgets('a failed listing shows an error with retry, not an empty bucket',
      (tester) async {
    final engine = _FailingListingEngine();
    final c = fixture.controller(engine, fixture.Repository());
    await c.initialize();
    c.clearBanner();
    await _pumpApp(tester, c);

    expect(c.selectedBucket, isNotNull);
    expect(c.objects, isEmpty);
    expect(c.objectListingError, contains('Fixture listing denied'));
    expect(find.byKey(const ValueKey('object-listing-error')), findsOneWidget);
    expect(find.text('Could not list objects'), findsOneWidget);
    expect(find.textContaining('Fixture listing denied'), findsWidgets);
    expect(find.textContaining('empty'), findsNothing);

    engine.fail = false;
    await tester.tap(find.byKey(const ValueKey('object-listing-retry')));
    await tester.pumpAndSettle();
    expect(c.objectListingError, isNull);
    expect(c.objects, isNotEmpty);
    expect(find.byKey(const ValueKey('object-listing-error')), findsNothing);
    expect(tester.takeException(), isNull);

    await tester.pumpWidget(const SizedBox.shrink());
    c.dispose();
  });
}

void phoneNavMain() {
  testWidgets('phone navigation labels fit at 390 px with 130% text',
      (tester) async {
    tester.platformDispatcher.textScaleFactorTestValue = 1.3;
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    final c = fixture.controller(fixture.TestingEngine(), fixture.Repository());
    await c.initialize();
    c.clearBanner();
    await _pumpApp(tester, c, size: const Size(390, 844));

    final nav = find.byType(NavigationBar);
    expect(nav, findsOneWidget);
    expect(tester.takeException(), isNull);
    final navRect = tester.getRect(nav);
    // Icons are RichText too; only the destination labels matter here.
    final labels = find.descendant(
        of: nav,
        matching: find.byWidgetPredicate((w) =>
            w is RichText &&
            const {'Jobs', 'Buckets', 'Benchmark', 'Event Log', 'Settings'}
                .contains(w.text.toPlainText())));
    expect(labels.evaluate().length, greaterThanOrEqualTo(3));
    for (final element in labels.evaluate()) {
      final paragraph = element.renderObject! as RenderParagraph;
      final text = paragraph.text.toPlainText();
      expect(paragraph.maxLines, 1, reason: '$text cannot wrap');
      expect(paragraph.overflow, TextOverflow.ellipsis);
      final rect = tester.getRect(find.byElementPredicate((e) => e == element));
      expect(rect.left >= navRect.left - .5 && rect.right <= navRect.right + .5,
          isTrue,
          reason: '$text stays inside the navigation bar');
      expect(rect.bottom, lessThanOrEqualTo(navRect.bottom + .5));
    }
    expect(tester.takeException(), isNull);

    await tester.pumpWidget(const SizedBox.shrink());
    c.dispose();
  });
}

void keyboardNavMain() {
  testWidgets('arrow keys move between object rows and Enter selects',
      (tester) async {
    final c = fixture.controller(fixture.TestingEngine(), fixture.Repository());
    await c.initialize();
    c.clearBanner();
    await _pumpApp(tester, c);
    final rows = c.pagedVisibleObjects;
    final target = rows.indexWhere((o) => !o.isFolder, 1);
    expect(target, greaterThan(0));

    // Focus the first row, as Tab traversal would.
    Focus.of(tester.element(find.text(rows.first.name))).requestFocus();
    await tester.pump();
    for (var i = 0; i < target + 1; i++) {
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pumpAndSettle();
    }
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(c.selectedObject?.key, rows[target].key);
    expect(tester.takeException(), isNull);

    await tester.pumpWidget(const SizedBox.shrink());
    c.dispose();
  });
}
