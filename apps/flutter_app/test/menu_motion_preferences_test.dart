import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:s3_browser_crossplat/widgets/app_menu.dart';
import 'package:s3_browser_crossplat/widgets/app_select_field.dart';

void main() {
  Widget host({required bool reduced}) => MaterialApp(
        theme: ThemeData(platform: TargetPlatform.macOS),
        home: MediaQuery(
          data: MediaQueryData(
              size: const Size(800, 600), disableAnimations: reduced),
          child: Scaffold(
            body: Center(
              child: SizedBox(
                width: 280,
                height: 48,
                child: AppSelectField<String>(
                  value: 'one',
                  items: const [
                    AppSelectItem(value: 'one', label: 'One'),
                    AppSelectItem(value: 'two', label: 'Two'),
                  ],
                  onChanged: (_) {},
                ),
              ),
            ),
          ),
        ),
      );

  testWidgets('menus respect reduced motion in both directions',
      (tester) async {
    await tester.pumpWidget(host(reduced: true));
    final context = tester.element(find.byType(AppSelectField<String>));
    expect(AppMenuStyle.animationFor(context).duration, Duration.zero);
    expect(AppMenuStyle.animationFor(context).reverseDuration, Duration.zero);
    await tester.tap(find.text('One'));
    await tester.pump();
    expect(find.text('Two'), findsOneWidget);
    final fade = tester.widgetList<FadeTransition>(find.byType(FadeTransition));
    expect(fade.every((widget) => widget.opacity.value == 1), isTrue);
    await tester.tap(find.text('Two'));
    await tester.pump();
    expect(find.text('Two'), findsNothing);
  });

  testWidgets('enabling reduced motion settles a menu already opening',
      (tester) async {
    await tester.pumpWidget(host(reduced: false));
    await tester.tap(find.text('One'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 40));
    await tester.pumpWidget(host(reduced: true));
    final fade = tester.widgetList<FadeTransition>(find.byType(FadeTransition));
    expect(fade.every((widget) => widget.opacity.value == 1), isTrue);
    expect(find.text('Two'), findsOneWidget);
    await tester.tap(find.text('Two'));
    await tester.pump();
    expect(find.text('Two'), findsNothing);
  });
}
