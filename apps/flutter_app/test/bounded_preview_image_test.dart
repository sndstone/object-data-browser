import 'dart:async';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:s3_browser_crossplat/services/preview_image_loader.dart';
import 'package:s3_browser_crossplat/widgets/bounded_preview_image.dart';

class DeferredImageLoader extends PreviewImageLoader {
  final requests = <String, Completer<PreviewImageData>>{};
  @override
  Future<PreviewImageData> load(String location,
          {String? etag, bool cache = true}) =>
      requests
          .putIfAbsent(location, () => Completer<PreviewImageData>())
          .future;
}

void main() {
  testWidgets('changing image identity hides the prior image while loading',
      (tester) async {
    final value = (await tester.runAsync(() async {
      final picture = ui.PictureRecorder();
      ui.Canvas(picture).drawRect(
          const Rect.fromLTWH(0, 0, 1, 1), Paint()..color = Colors.red);
      final recorded = picture.endRecording();
      final image = await recorded.toImage(1, 1);
      final data = await image.toByteData(format: ui.ImageByteFormat.png);
      image.dispose();
      recorded.dispose();
      return PreviewImageData(data!.buffer.asUint8List(), 1, 1);
    }))!;
    final loader = DeferredImageLoader();
    Widget preview(String url) => MaterialApp(
        home: SizedBox(
            width: 100,
            height: 100,
            child: BoundedPreviewImage(url: url, loader: loader)));
    await tester.pumpWidget(preview('a'));
    loader.requests['a']!.complete(value);
    await tester.pump();
    expect(find.byType(Image), findsOneWidget);
    await tester.pumpWidget(preview('b'));
    expect(find.byType(Image), findsNothing);
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    loader.requests['b']!.complete(value);
    await tester.pump();
    expect(find.byType(Image), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });
}
