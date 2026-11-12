import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:s3_browser_crossplat/widgets/banner_activity/banner_activity_spec.dart';
import 'package:s3_browser_crossplat/widgets/banner_activity/living_glyph_indicator.dart';
import 'package:s3_browser_crossplat/widgets/banner_activity/living_glyph_painter.dart';

void main() {
  Widget host(BannerActivityPhase phase, {bool animate = true}) => MaterialApp(
        home: LivingGlyphIndicator(
          spec: BannerActivitySpec(
            kind: BannerActivityKind.action,
            phase: phase,
            foreground: Colors.white,
            background: Colors.black,
            animate: animate,
          ),
        ),
      );

  LivingGlyphPainter painter(WidgetTester tester) => tester
      .widgetList<CustomPaint>(find.byType(CustomPaint))
      .map((widget) => widget.painter)
      .whereType<LivingGlyphPainter>()
      .single;

  Future<List<int>> pixels(LivingGlyphPainter painter) async {
    final recorder = ui.PictureRecorder();
    painter.paint(Canvas(recorder), const Size(28, 32));
    final picture = recorder.endRecording();
    final image = await picture.toImage(28, 32);
    final data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
    final result = data!.buffer.asUint8List().toList();
    image.dispose();
    picture.dispose();
    return result;
  }

  testWidgets('an interrupted result starts at the exact visible composite',
      (tester) async {
    await tester.pumpWidget(host(BannerActivityPhase.working));
    await tester.pump(const Duration(milliseconds: 350));
    await tester.pumpWidget(host(BannerActivityPhase.succeeded));
    await tester.pump(const Duration(milliseconds: 180));
    final before = await tester.runAsync(() => pixels(painter(tester)));
    await tester.pumpWidget(host(BannerActivityPhase.failed));
    expect(painter(tester).fromSnapshot, isNotNull);
    final after = await tester.runAsync(() => pixels(painter(tester)));
    expect(after, orderedEquals(before!));
    await tester.pumpAndSettle();
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('completed glyph blends back into working from its visible pose',
      (tester) async {
    await tester.pumpWidget(host(BannerActivityPhase.working));
    await tester.pump(const Duration(milliseconds: 200));
    await tester.pumpWidget(host(BannerActivityPhase.succeeded));
    await tester.pump(const Duration(milliseconds: 220));
    final before = await tester.runAsync(() => pixels(painter(tester)));
    await tester.pumpWidget(host(BannerActivityPhase.working));
    final after = await tester.runAsync(() => pixels(painter(tester)));
    expect(after, orderedEquals(before!));
    await tester.pump(const Duration(milliseconds: 220));
    expect(painter(tester).handoff!.value, closeTo(.5, .001));
    await tester.pump(const Duration(milliseconds: 250));
    expect(painter(tester).handoff!.value, 1);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('pause and resume retain the working loop position',
      (tester) async {
    await tester.pumpWidget(host(BannerActivityPhase.working));
    await tester.pump(const Duration(milliseconds: 360));
    final before = painter(tester).clock.value;
    await tester.pumpWidget(host(BannerActivityPhase.paused));
    expect(painter(tester).clock.value, before);
    await tester.pump(const Duration(milliseconds: 300));
    expect(painter(tester).clock.value, before);
    await tester.pumpWidget(host(BannerActivityPhase.working));
    expect(painter(tester).clock.value, before);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('disabled motion renders the result immediately without snapshot',
      (tester) async {
    await tester.pumpWidget(host(BannerActivityPhase.working));
    await tester.pumpWidget(host(BannerActivityPhase.failed, animate: false));
    expect(painter(tester).fromSnapshot, isNull);
    expect(painter(tester).clock.value, 1);
    await tester.pumpAndSettle();
  });
}
