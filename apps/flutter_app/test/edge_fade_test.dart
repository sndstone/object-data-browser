import 'package:flutter/material.dart';
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
}
