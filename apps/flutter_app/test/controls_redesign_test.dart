import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:s3_browser_crossplat/benchmark/operation_mix_bar.dart';
import 'package:s3_browser_crossplat/browser/object_table.dart';
import 'package:s3_browser_crossplat/theme/app_theme.dart';
import 'package:s3_browser_crossplat/widgets/app_slider.dart';
import 'package:s3_browser_crossplat/widgets/app_switch.dart';

import 'gui_226_test.dart' as gui;

Widget _host(Widget child) => MaterialApp(
      theme: AppTheme.light(scalePercent: 100, desktopCompact: true),
      home: Scaffold(
        body: Center(child: SizedBox(width: 480, child: child)),
      ),
    );

void main() {
  testWidgets('object actions menu opens from its button, not the row centre',
      (tester) async {
    final c = await gui.frame(tester);
    c.selectedObject = null;
    c.clearObjectSelection();
    c.clearBanner();
    await tester.pumpAndSettle();
    final object = c.pagedVisibleObjects.firstWhere((o) => !o.isFolder);
    final row = find.descendant(
        of: find.byType(ObjectTable), matching: find.text(object.name));
    await tester.ensureVisible(row);
    await tester.pumpAndSettle();
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: Offset.zero);
    addTearDown(mouse.removePointer);
    await mouse.moveTo(tester.getCenter(row));
    await tester.pumpAndSettle();

    final button = find.byTooltip('Object actions for ${object.name}');
    final buttonRect = tester.getRect(button);
    await tester.tap(button);
    await tester.pumpAndSettle();

    final first = tester
        .getRect(find.widgetWithText(PopupMenuItem<String>, 'Inspect object'));
    expect(first.top, greaterThan(buttonRect.bottom));
    expect(first.top - buttonRect.bottom, lessThan(16));
    expect((first.right - buttonRect.right).abs(), lessThan(1));
    expect(first.height, 40);
    // Destructive rows carry no keyboard hint.
    expect(find.text('Delete object'), findsOneWidget);
    expect(find.text('Del'), findsNothing);
    await gui.closeFrame(tester);
  });

  testWidgets('switch tile toggles from the row and reports its state',
      (tester) async {
    var value = false;
    await tester.pumpWidget(_host(StatefulBuilder(
      builder: (context, setState) => AppSwitchTile(
        value: value,
        onChanged: (v) => setState(() => value = v),
        title: const Text('Compact desktop rows'),
      ),
    )));
    expect(find.text('OFF'), findsOneWidget);
    await tester.tap(find.text('Compact desktop rows'));
    await tester.pumpAndSettle();
    expect(value, isTrue);
    expect(tester.getSemantics(find.byType(AppSwitchTile)),
        isSemantics(hasToggledState: true, isToggled: true));

    await tester.pumpWidget(_host(const AppSwitchTile(
      value: false,
      onChanged: null,
      title: Text('Disabled'),
    )));
    await tester.tap(find.text('Disabled'));
    await tester.pumpAndSettle();
  });

  testWidgets('step blocks pick values by tap, keyboard and reset',
      (tester) async {
    var value = 100;
    await tester.pumpWidget(_host(StatefulBuilder(
      builder: (context, setState) => AppSettingSlider(
        title: 'UI scale',
        style: AppSliderStyle.stepBlocks,
        min: 60,
        max: 150,
        step: 5,
        unit: '%',
        defaultValue: 100,
        value: value,
        onChanged: (v) => setState(() => value = v),
      ),
    )));
    expect(find.text('100%'), findsOneWidget);
    final blocks = find.byType(AppStepBlocks);
    await tester.tapAt(tester.getRect(blocks).centerRight - const Offset(2, 0));
    await tester.pump();
    expect(value, 150);

    await tester.tapAt(tester.getRect(blocks).centerLeft + const Offset(2, 0));
    await tester.pump();
    expect(value, 60);

    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pump();
    expect(value, 65);

    await tester.tap(find.text('Reset'));
    await tester.pump();
    expect(value, 100);
  });

  testWidgets('ruler slider snaps to steps from its minimum', (tester) async {
    var value = 360;
    await tester.pumpWidget(_host(StatefulBuilder(
      builder: (context, setState) => AppSettingSlider(
        title: 'Inspector panel size',
        min: 240,
        max: 560,
        step: 20,
        unit: 'px',
        defaultValue: 360,
        value: value,
        onChanged: (v) => setState(() => value = v),
      ),
    )));
    final slider = tester.getRect(find.byType(Slider));
    await tester
        .tapAt(Offset(slider.left + slider.width * 0.52, slider.center.dy));
    await tester.pump();
    expect((value - 240) % 20, 0);
    expect(value, inInclusiveRange(380, 420));
  });

  testWidgets('operation mix bar keeps the shares at 100', (tester) async {
    var mix = const OperationMix(40, 45, 15);
    await tester.pumpWidget(_host(StatefulBuilder(
      builder: (context, setState) => OperationMixBar(
        mix: mix,
        onChanged: (m) => setState(() => mix = m),
      ),
    )));
    final bar = tester.getRect(find
        .descendant(
            of: find.byType(OperationMixBar),
            matching: find.byType(GestureDetector))
        .first);
    final firstDivider = Offset(bar.left + bar.width * 0.40, bar.center.dy);
    await tester.dragFrom(firstDivider, Offset(bar.width * 0.2, 0));
    await tester.pump();
    expect(mix.write, inInclusiveRange(55, 62));
    expect(mix.delete, 15);
    expect(mix.write + mix.read + mix.delete, 100);

    // The read/delete divider cannot pass the write/read divider.
    final secondDivider = Offset(
        bar.left + bar.width * (mix.write + mix.read) / 100, bar.center.dy);
    await tester.dragFrom(secondDivider, Offset(-bar.width, 0));
    await tester.pump();
    expect(mix.read, 0);
    expect(mix.write + mix.read + mix.delete, 100);

    await tester.tap(find.text('Read heavy'));
    await tester.pump();
    expect([mix.write, mix.read, mix.delete], [10, 85, 5]);
  });
}
