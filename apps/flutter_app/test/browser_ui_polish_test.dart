import 'dart:ui' show Tristate;

import 'package:flutter/material.dart';
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
