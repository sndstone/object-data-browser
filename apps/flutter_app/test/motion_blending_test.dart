import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:s3_browser_crossplat/theme/app_motion.dart';

void main() {
  testWidgets('reversing reuses panel state and preserves visible opacity',
      (tester) async {
    Widget frame(int index, {bool reduced = false}) => MaterialApp(
          home: Scaffold(
              body: DirectionalSwitcher(
            position: index,
            duration:
                reduced ? Duration.zero : const Duration(milliseconds: 240),
            child: TextField(key: ValueKey(index)),
          )),
        );
    await tester.pumpWidget(frame(0));
    final original = tester.state(find.byKey(const ValueKey(0)));
    await tester.enterText(find.byType(TextField), 'Keep this draft');
    await tester.pumpWidget(frame(1));
    await tester.pump(const Duration(milliseconds: 40));
    double opacity(int key) => tester
        .widget<Opacity>(find
            .ancestor(
                of: find.byKey(ValueKey(key)), matching: find.byType(Opacity))
            .first)
        .opacity;
    final visible = opacity(0);
    await tester.pumpWidget(frame(0));
    expect(opacity(0), closeTo(visible, .0001));
    expect(tester.state(find.byKey(const ValueKey(0))), same(original));
    await tester.pumpWidget(frame(0, reduced: true));
    await tester.pump();
    expect(find.byKey(const ValueKey(1)), findsNothing);
    expect(opacity(0), 1);
    expect(tester.state(find.byKey(const ValueKey(0))), same(original));
    expect(find.text('Keep this draft'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  for (final axis in Axis.values) {
    for (final direction in TextDirection.values) {
      testWidgets(
          'clipped push $axis $direction keeps a shared seam and reverses',
          (tester) async {
        Widget frame(int index, {bool reduced = false}) => MaterialApp(
              home: Directionality(
                textDirection: direction,
                child: DirectionalSwitcher(
                  axis: axis,
                  replaceContent: true,
                  position: index,
                  duration: reduced
                      ? Duration.zero
                      : const Duration(milliseconds: 300),
                  child: SizedBox(key: ValueKey(index)),
                ),
              ),
            );
        Rect rect(int index) => tester.getRect(find.byKey(ValueKey(index)));
        await tester.pumpWidget(frame(0));
        final viewport = rect(0);
        await tester.pumpWidget(frame(1));
        await tester.pump(const Duration(milliseconds: 150));
        final old = rect(0), incoming = rect(1);
        final reverse =
            axis == Axis.horizontal && direction == TextDirection.rtl;
        if (axis == Axis.horizontal) {
          expect(reverse ? incoming.right : old.right,
              closeTo(reverse ? old.left : incoming.left, .001));
          expect(incoming.left,
              reverse ? lessThan(viewport.left) : greaterThan(viewport.left));
          expect(old.top, viewport.top);
        } else {
          expect(old.bottom, closeTo(incoming.top, .001));
          expect(incoming.top, greaterThan(viewport.top));
          expect(old.left, viewport.left);
        }
        expect(old.size, viewport.size);
        expect(incoming.size, viewport.size);
        expect(find.byType(Opacity), findsNothing,
            reason: 'Opaque push panels keep text crisp');
        await tester.pumpWidget(frame(0));
        expect(rect(0), old);
        expect(rect(1), incoming);
        await tester.pump(const Duration(milliseconds: 150));
        expect((rect(0).center - viewport.center).distance,
            lessThan((old.center - viewport.center).distance));
        await tester.pumpWidget(frame(0, reduced: true));
        await tester.pump();
        expect(find.byKey(const ValueKey(1)), findsNothing);
        expect(rect(0), viewport);
      });
    }
  }

  testWidgets('a push preserves draft state through an interrupted return',
      (tester) async {
    Widget frame(int index) => MaterialApp(
            home: Scaffold(
                body: DirectionalSwitcher(
          replaceContent: true,
          position: index,
          duration: const Duration(milliseconds: 300),
          child: TextField(key: ValueKey(index)),
        )));
    await tester.pumpWidget(frame(0));
    final state = tester.state(find.byKey(const ValueKey(0)));
    await tester.enterText(find.byType(TextField), 'Preserved draft');
    await tester.pumpWidget(frame(1));
    await tester.pump(const Duration(milliseconds: 100));
    final outgoing = tester.widget<IgnorePointer>(find
        .ancestor(
            of: find.byKey(const ValueKey(0)),
            matching: find.byType(IgnorePointer))
        .first);
    expect(outgoing.ignoring, isTrue);
    await tester.pumpWidget(frame(0));
    await tester.pumpAndSettle();
    expect(tester.state(find.byKey(const ValueKey(0))), same(state));
    expect(find.text('Preserved draft'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('desktop fade through clears outgoing text before incoming text',
      (tester) async {
    Widget frame(int index) => MaterialApp(
            home: DirectionalSwitcher(
          position: index,
          fadeThrough: true,
          duration: const Duration(milliseconds: 240),
          child: Text('Panel $index', key: ValueKey(index)),
        ));
    await tester.pumpWidget(frame(0));
    await tester.pumpWidget(frame(1));
    await tester.pump(const Duration(milliseconds: 84));
    for (final opacity in tester.widgetList<Opacity>(find.byType(Opacity))) {
      expect(opacity.opacity, lessThan(.01));
    }
    await tester.pumpAndSettle();
    expect(find.text('Panel 0'), findsNothing);
    expect(find.text('Panel 1'), findsOneWidget);
  });
}
