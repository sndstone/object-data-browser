import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:s3_browser_crossplat/widgets/edge_fade_scroll.dart';

void main() {
  testWidgets('vertical edge fade tracks clipped content', (tester) async {
    await tester.pumpWidget(MaterialApp(
        home: Center(
            child: SizedBox(
                height: 200,
                child: VerticalEdgeFade(
                    child: ListView(children: [
                  for (var i = 0; i < 30; i++)
                    SizedBox(height: 40, child: Text('Row $i')),
                ]))))));
    await tester.pump();
    final state =
        tester.state<VerticalEdgeFadeState>(find.byType(VerticalEdgeFade));
    expect(state.fadesTop, isFalse);
    expect(state.fadesBottom, isTrue);
    await tester.drag(find.byType(ListView), const Offset(0, -300));
    await tester.pumpAndSettle();
    expect(state.fadesTop, isTrue);
    expect(state.fadesBottom, isTrue);
    await tester.drag(find.byType(ListView), const Offset(0, -5000));
    await tester.pumpAndSettle();
    expect(state.fadesTop, isTrue);
    expect(state.fadesBottom, isFalse);
  });
  testWidgets(
      'opaque mask bypass preserves scroller state and drops shader layer',
      (tester) async {
    Widget host(double width) => MaterialApp(
        home: Scaffold(
            body: Center(
                child: SizedBox(
                    width: width,
                    height: 50,
                    child: const EdgeFadeScroll(
                        key: ValueKey('stable'),
                        child: SizedBox(
                            width: 500,
                            height: 40,
                            child: Text('Wide content')))))));
    await tester.pumpWidget(host(200));
    await tester.pump();
    await tester.pump();
    final scroll = tester.state<ScrollableState>(find.byType(Scrollable));
    final mask = find.byWidgetPredicate((widget) => widget is ShaderMask);
    final render = tester.renderObject<RenderShaderMask>(mask);
    expect(render.debugLayer, isA<ShaderMaskLayer>());
    scroll.position.jumpTo(80);
    await tester.pump();
    await tester.pumpWidget(host(600));
    await tester.pump();
    await tester.pump();
    expect(
        identical(
            tester.state<ScrollableState>(find.byType(Scrollable)), scroll),
        isTrue);
    expect(
        identical(tester.renderObject<RenderShaderMask>(mask), render), isTrue);
    expect(render.debugLayer, isNull);
  });
}
