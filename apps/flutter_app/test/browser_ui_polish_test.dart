import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:s3_browser_crossplat/app/s3_browser_app.dart';
import 'package:s3_browser_crossplat/models/domain_models.dart';
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

    await tester.tap(clear);
    await tester.pumpAndSettle();
    expect(c.objectFilterValue, isEmpty);
    expect(clear, findsNothing);
    expect(find.text('No matching objects'), findsNothing);
    expect(tester.takeException(), isNull);

    await tester.pumpWidget(const SizedBox.shrink());
    c.dispose();
  });
}
