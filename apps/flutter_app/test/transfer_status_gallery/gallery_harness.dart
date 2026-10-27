// Renders the transfer status indicators into review images.
//
//   DESIGN_GALLERY=1 flutter test test/transfer_status_gallery
//
// Output per variant under <repo>/.tmp/transfer-status-designs/<id>/:
//   sheet-upload.png, sheet-download.png   every phase, light + dark, 2x
//   journey-upload/frame_###.png           preparing → transferring → done
//   journey-download/frame_###.png         (25 fps)
import 'dart:io';
import 'dart:ui' show ImageByteFormat;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:s3_browser_crossplat/theme/app_theme.dart';
import 'package:s3_browser_crossplat/widgets/transfer_status/transfer_status_indicator.dart';
import 'package:s3_browser_crossplat/widgets/transfer_status/transfer_status_spec.dart';

final bool galleryEnabled = Platform.environment['DESIGN_GALLERY'] == '1';

const _bannerWidth = 520.0;

/// A rendered indicator variant; [itemCount] selects file scan or segments.
class GalleryVariant {
  const GalleryVariant(this.id, this.name, this.itemCount);
  final String id, name;
  final int itemCount;
  String noun(TransferStatusDirection direction) =>
      direction == TransferStatusDirection.upload
          ? (itemCount > 1 ? '$itemCount files' : 'report.pdf')
          : (itemCount > 1 ? '$itemCount objects' : 'backup.tar');
}

const fileScanVariant = GalleryVariant('file_scan', 'File Scan', 1);
const segmentsVariant = GalleryVariant('segments', 'Multipart Segments', 3);

String _verb(TransferStatusDirection d) =>
    d == TransferStatusDirection.upload ? 'Upload' : 'Download';

/// Banner copy mirrors the app: the indicator carries the percent.
String galleryMessage(
    GalleryVariant v, TransferStatusDirection d, TransferStatusPhase phase) {
  final noun = v.noun(d);
  final verb = _verb(d);
  return switch (phase) {
    TransferStatusPhase.preparing => 'Preparing ${verb.toLowerCase()} · $noun',
    TransferStatusPhase.transferring =>
      '${d == TransferStatusDirection.upload ? 'Uploading' : 'Downloading'} $noun',
    TransferStatusPhase.paused => '$verb paused · $noun',
    TransferStatusPhase.cancelling => 'Stopping ${verb.toLowerCase()}…',
    TransferStatusPhase.completed => '$verb complete · $noun',
    TransferStatusPhase.failed => '$verb failed · $noun',
    TransferStatusPhase.cancelled => '$verb cancelled · $noun',
  };
}

const _cases = <(String, TransferStatusPhase, double?, bool)>[
  ('Preparing', TransferStatusPhase.preparing, null, true),
  ('Transferring 7%', TransferStatusPhase.transferring, .07, true),
  ('Transferring 42%', TransferStatusPhase.transferring, .42, true),
  ('Paused 63%', TransferStatusPhase.paused, .63, true),
  ('Cancelling', TransferStatusPhase.cancelling, .63, true),
  ('Completed', TransferStatusPhase.completed, 1, true),
  ('Failed 18%', TransferStatusPhase.failed, .18, true),
  ('Cancelled 54%', TransferStatusPhase.cancelled, .54, true),
  ('Preparing, reduced motion', TransferStatusPhase.preparing, null, false),
];

/// Mirrors the app's status banner layout around the indicator.
class GalleryBanner extends StatelessWidget {
  const GalleryBanner(
      {super.key,
      required this.variant,
      required this.direction,
      required this.phase,
      required this.progress,
      this.animate = true});
  final GalleryVariant variant;
  final TransferStatusDirection direction;
  final TransferStatusPhase phase;
  final double? progress;
  final bool animate;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final (background, foreground) = switch (phase) {
      TransferStatusPhase.completed => (
          colors.primaryContainer,
          colors.onPrimaryContainer
        ),
      TransferStatusPhase.failed => (
          colors.errorContainer,
          colors.onErrorContainer
        ),
      _ => (colors.inverseSurface, colors.onInverseSurface),
    };
    final spec = TransferStatusSpec(
        phase: phase,
        direction: direction,
        progress: progress,
        animate: animate,
        itemCount: variant.itemCount,
        foreground: foreground,
        background: background);
    return Material(
        color: background,
        borderRadius: BorderRadius.circular(10),
        child: SizedBox(
            width: _bannerWidth,
            child: Padding(
                padding: const EdgeInsets.fromLTRB(12, 6, 4, 6),
                child: Row(children: [
                  TransferStatusIndicator(spec: spec),
                  const SizedBox(width: 12),
                  Expanded(
                      child: Text(galleryMessage(variant, direction, phase),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(color: foreground))),
                  TextButton(
                      onPressed: () {},
                      style: TextButton.styleFrom(foregroundColor: foreground),
                      child: const Text('Details')),
                  IconButton(
                      onPressed: () {},
                      icon: Icon(Icons.close, color: foreground)),
                ]))));
  }
}

Future<void> _loadFonts() async {
  final icons = FontLoader('MaterialIcons')
    ..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'));
  await icons.load();
  for (final family in ['Inter', 'Sora']) {
    final loader = FontLoader(family)
      ..addFont(rootBundle.load('assets/fonts/$family.ttf'));
    await loader.load();
  }
}

ThemeData _theme(bool dark) => dark
    ? AppTheme.dark(scalePercent: 100, desktopCompact: true)
    : AppTheme.light(scalePercent: 100, desktopCompact: true);

Future<void> _capture(WidgetTester tester, GlobalKey key, File file) async {
  await tester.runAsync(() async {
    final image =
        await (key.currentContext!.findRenderObject() as RenderRepaintBoundary)
            .toImage(pixelRatio: 2);
    final bytes = await image.toByteData(format: ImageByteFormat.png);
    await file.parent.create(recursive: true);
    await file.writeAsBytes(bytes!.buffer.asUint8List());
    image.dispose();
  });
}

Widget _themed(bool dark, Widget child) => Theme(
    data: _theme(dark),
    child: Builder(
        builder: (context) => Container(
            color: Theme.of(context).colorScheme.surface,
            padding: const EdgeInsets.all(16),
            child: DefaultTextStyle(
                style: Theme.of(context).textTheme.bodyMedium!,
                child: child))));

Widget _sheet(GalleryVariant variant, TransferStatusDirection direction) {
  Widget column(bool dark) => _themed(
      dark,
      Builder(
          builder: (context) =>
              Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                if (!dark)
                  Text('${variant.name} · ${_verb(direction)}',
                      style: Theme.of(context).textTheme.titleMedium)
                else
                  const SizedBox(height: 22),
                const SizedBox(height: 8),
                for (final (title, phase, progress, animate) in _cases) ...[
                  Text(title,
                      style: Theme.of(context).textTheme.labelSmall?.copyWith(
                          color:
                              Theme.of(context).colorScheme.onSurfaceVariant)),
                  const SizedBox(height: 4),
                  GalleryBanner(
                      variant: variant,
                      direction: direction,
                      phase: phase,
                      progress: progress,
                      animate: animate),
                  const SizedBox(height: 12),
                ]
              ])));
  return Row(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [column(false), column(true)]);
}

/// Journey timeline: preparing → transferring → completed.
(TransferStatusPhase, double?) journeyAt(Duration t) {
  final ms = t.inMilliseconds;
  if (ms < 2000) return (TransferStatusPhase.preparing, null);
  if (ms < 4400) {
    return (
      TransferStatusPhase.transferring,
      Curves.easeInOut.transform((ms - 2000) / 2400)
    );
  }
  return (TransferStatusPhase.completed, 1.0);
}

const journeyLength = Duration(milliseconds: 5600);
const journeyFrame = Duration(milliseconds: 40); // 25 fps

Future<void> captureGallery(
    WidgetTester tester, List<GalleryVariant> variants) async {
  debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
  addTearDown(() => debugDefaultTargetPlatformOverride = null);
  await _loadFonts();
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = const Size(1200, 1400);
  addTearDown(tester.view.reset);
  for (final variant in variants) {
    final out = Directory('../../.tmp/transfer-status-designs/${variant.id}');
    if (out.existsSync()) out.deleteSync(recursive: true);
    for (final direction in TransferStatusDirection.values) {
      final key = GlobalKey();
      await tester.pumpWidget(MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: _theme(false),
          home: Align(
              alignment: Alignment.topLeft,
              child: RepaintBoundary(
                  key: key, child: _sheet(variant, direction)))));
      // Let entrance transitions finish and loops reach mid-cycle.
      for (var i = 0; i < 20; i++) {
        await tester.pump(const Duration(milliseconds: 35));
      }
      await _capture(
          tester, key, File('${out.path}/sheet-${direction.name}.png'));

      final journeyKey = GlobalKey();
      final elapsed = ValueNotifier(Duration.zero);
      await tester.pumpWidget(MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: _theme(false),
          home: Align(
              alignment: Alignment.topLeft,
              child: RepaintBoundary(
                  key: journeyKey,
                  child: ValueListenableBuilder<Duration>(
                      valueListenable: elapsed,
                      builder: (context, t, _) {
                        final (phase, progress) = journeyAt(t);
                        return Row(mainAxisSize: MainAxisSize.min, children: [
                          for (final dark in [false, true])
                            _themed(
                                dark,
                                GalleryBanner(
                                    key: ValueKey('journey-$dark'),
                                    variant: variant,
                                    direction: direction,
                                    phase: phase,
                                    progress: progress)),
                        ]);
                      })))));
      var frame = 0;
      while (elapsed.value < journeyLength) {
        await _capture(
            tester,
            journeyKey,
            File('${out.path}/journey-${direction.name}/'
                'frame_${frame.toString().padLeft(3, '0')}.png'));
        frame++;
        elapsed.value += journeyFrame;
        await tester.pump(journeyFrame);
      }
    }
  }
  await tester.pumpWidget(const SizedBox.shrink());
  debugDefaultTargetPlatformOverride = null;
}
