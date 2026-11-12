import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:s3_browser_crossplat/theme/app_theme.dart';
import 'package:s3_browser_crossplat/widgets/underline_tabs.dart';

import 'gui_226_test.dart' as gui;

void main() {
  Future<void> host(WidgetTester tester,
      {required ValueNotifier<int> selected,
      bool reduced = false,
      TextDirection direction = TextDirection.ltr}) async {
    await tester.pumpWidget(MaterialApp(
      theme: AppTheme.light(scalePercent: 100, desktopCompact: true),
      home: MediaQuery(
        data: MediaQueryData(disableAnimations: reduced),
        child: Directionality(
          textDirection: direction,
          child: Scaffold(
            body: ValueListenableBuilder<int>(
              valueListenable: selected,
              builder: (context, value, child) => UnderlineTabs<int>(
                tabs: const [
                  UnderlineTab(value: 0, label: 'Objects'),
                  UnderlineTab(value: 1, label: 'Versions'),
                  UnderlineTab(value: 2, label: 'Metadata'),
                ],
                selected: value,
                onChanged: (value) => selected.value = value,
              ),
            ),
          ),
        ),
      ),
    ));
  }

  Rect underline(WidgetTester tester) =>
      tester.getRect(find.byKey(const ValueKey('tab-underline')));

  testWidgets('tab selection uses the original immediate highlight',
      (tester) async {
    final selected = ValueNotifier(0);
    addTearDown(selected.dispose);
    await host(tester, selected: selected);
    final first = underline(tester);
    selected.value = 2;
    await tester.pump();
    expect(underline(tester).left, greaterThan(first.left));
    expect(tester.binding.transientCallbackCount, 0);
    selected.value = 0;
    await tester.pump();
    expect(underline(tester), first);
    expect(tester.binding.transientCallbackCount, 0);
  });

  testWidgets('view tray stays visible while fading and collapsing',
      (tester) async {
    final c = await gui.frame(tester);
    c.settings = c.settings.copyWith(enableAnimations: true);
    c.changed();
    await tester.pumpAndSettle();
    final toggle = find.byKey(const ValueKey('object-view-tools'));
    await tester.tap(toggle);
    await tester.pumpAndSettle();
    final flat = find.text('Flat view');
    expect(flat, findsOneWidget);
    await tester.tap(toggle);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 80));
    expect(flat, findsOneWidget);
    final opacity = tester.widget<Opacity>(
        find.ancestor(of: flat, matching: find.byType(Opacity)).first);
    expect(opacity.opacity, inExclusiveRange(0, 1));
    final pointer = tester.widget<IgnorePointer>(
        find.ancestor(of: flat, matching: find.byType(IgnorePointer)).first);
    expect(pointer.ignoring, isTrue);
    await tester.pumpAndSettle();
    expect(flat, findsNothing);
    await gui.closeFrame(tester);
  });

  testWidgets('underline honors RTL and reduced motion', (tester) async {
    final selected = ValueNotifier(0);
    addTearDown(selected.dispose);
    await host(tester,
        selected: selected, reduced: true, direction: TextDirection.rtl);
    final first = underline(tester);
    selected.value = 2;
    await tester.pump();
    expect(underline(tester).left, lessThan(first.left));
    expect(tester.binding.transientCallbackCount, 0);
    expect(tester.takeException(), isNull);
  });
}
