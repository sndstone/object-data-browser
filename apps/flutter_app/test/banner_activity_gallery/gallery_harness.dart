// Renders a banner activity design family into review images.
//
//   DESIGN_GALLERY=1 flutter test test/banner_activity_gallery
//
// Output under <repo>/.tmp/banner-activity-designs/<id>/:
//   sheet.png              every kind and phase, light + dark, 2x
//   journey/frame_###.png  each kind working → succeeded (20 fps)
import 'dart:io';
import 'dart:ui' show ImageByteFormat;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:s3_browser_crossplat/theme/app_theme.dart';
import 'package:s3_browser_crossplat/widgets/banner_activity/banner_activity_indicator.dart';
import 'package:s3_browser_crossplat/widgets/banner_activity/banner_activity_spec.dart';

final bool galleryEnabled = Platform.environment['DESIGN_GALLERY'] == '1';

typedef BannerActivityBuilder = Widget Function(
    BuildContext context, BannerActivitySpec spec);

/// A rendered indicator family.
class BannerActivityDesign {
  const BannerActivityDesign(
      {required this.id,
      required this.name,
      required this.author,
      required this.summary,
      required this.builder});
  final String id, name, author, summary;
  final BannerActivityBuilder builder;
}

/// The shipped mix: living glyphs, with trace tiles for benchmark and export.
final shippedDesign = BannerActivityDesign(
    id: 'shipped',
    name: 'Living Glyphs + Trace Tile',
    author: 'Opus 5.5 + gpt-6.1-sol',
    summary: 'Listing, deleting, quick actions and messages use living glyphs; '
        'benchmarks and exports use the trace tile.',
    builder: (context, spec) => BannerActivityIndicator(spec: spec));

const _bannerWidth = 520.0;

typedef _Case = (
  String title,
  BannerActivityKind kind,
  BannerActivityPhase phase,
  double? progress,
  int? count,
  String message,
  bool animate,
);

const _k = BannerActivityKind.values;
const _p = BannerActivityPhase.values;

final List<_Case> _galleryCases = [
  (
    'Listing · working',
    _k[0],
    _p[0],
    null,
    null,
    'Listing buckets for Production…',
    true
  ),
  (
    'Listing · working with count',
    _k[0],
    _p[0],
    null,
    3200,
    'Listing all objects in media-archive…',
    true
  ),
  (
    'Listing · done',
    _k[0],
    _p[3],
    null,
    1000,
    'Listed first 1000 objects in media-archive.',
    true
  ),
  (
    'Listing · cancelled',
    _k[0],
    _p[7],
    null,
    1800,
    'Listing cancelled. Keeping the results already loaded.',
    true
  ),
  ('Deleting · working', _k[1], _p[0], null, 12, 'Deleting 12 objects…', true),
  ('Deleting · done', _k[1], _p[3], null, 12, 'Deleted 12 objects.', true),
  (
    'Deleting · partial',
    _k[1],
    _p[5],
    null,
    12,
    'Deleted 10 objects; 2 failed.',
    true
  ),
  (
    'Benchmark · running 35%',
    _k[2],
    _p[0],
    .35,
    null,
    'Benchmark running on media-archive',
    true
  ),
  ('Benchmark · paused', _k[2], _p[1], .35, null, 'Benchmark paused', true),
  (
    'Benchmark · stopping',
    _k[2],
    _p[2],
    .35,
    null,
    'Stopping benchmark…',
    true
  ),
  ('Benchmark · done', _k[2], _p[3], 1, null, 'Benchmark complete', true),
  (
    'Action · working',
    _k[3],
    _p[0],
    null,
    null,
    'Creating bucket media-archive…',
    true
  ),
  (
    'Action · done',
    _k[3],
    _p[3],
    null,
    null,
    'Created bucket media-archive.',
    true
  ),
  (
    'Action · failed',
    _k[3],
    _p[6],
    null,
    null,
    'AccessDenied: bucket creation denied',
    true
  ),
  ('Export · working', _k[4], _p[0], null, null, 'Exporting event log…', true),
  (
    'Export · done',
    _k[4],
    _p[3],
    null,
    null,
    'Event log exported to ~/Downloads.',
    true
  ),
  ('Message · info', _k[5], _p[4], null, null, 'Using Rust engine.', true),
  (
    'Message · warning',
    _k[5],
    _p[5],
    null,
    null,
    'Open the original connection before retrying.',
    true
  ),
  (
    'Message · error',
    _k[5],
    _p[6],
    null,
    null,
    'Initialization failed: connection refused',
    true
  ),
  (
    'Listing · reduced motion',
    _k[0],
    _p[0],
    null,
    3200,
    'Listing all objects in media-archive…',
    false
  ),
  (
    'Deleting · reduced motion',
    _k[1],
    _p[0],
    null,
    12,
    'Deleting 12 objects…',
    false
  ),
  (
    'Action · reduced motion',
    _k[3],
    _p[0],
    null,
    null,
    'Creating bucket media-archive…',
    false
  ),
];

/// Mirrors the app's status banner layout around the indicator.
class GalleryBanner extends StatelessWidget {
  const GalleryBanner(
      {super.key,
      required this.design,
      required this.kind,
      required this.phase,
      required this.message,
      this.progress,
      this.count,
      this.animate = true,
      this.width = _bannerWidth,
      this.compact = false});
  final BannerActivityDesign design;
  final BannerActivityKind kind;
  final BannerActivityPhase phase;
  final String message;
  final double? progress;
  final int? count;
  final bool animate;
  final double width;

  /// Leading indicator and message only, for side-by-side clips.
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final (background, foreground) = switch (phase) {
      BannerActivityPhase.succeeded => (
          colors.primaryContainer,
          colors.onPrimaryContainer
        ),
      BannerActivityPhase.warning => (
          colors.tertiaryContainer,
          colors.onTertiaryContainer
        ),
      BannerActivityPhase.failed => (
          colors.errorContainer,
          colors.onErrorContainer
        ),
      _ => (colors.inverseSurface, colors.onInverseSurface),
    };
    final spec = BannerActivitySpec(
        kind: kind,
        phase: phase,
        progress: progress,
        count: count,
        animate: animate,
        foreground: foreground,
        background: background);
    return Material(
        color: background,
        borderRadius: BorderRadius.circular(10),
        child: SizedBox(
            width: width,
            child: Padding(
                padding: const EdgeInsets.fromLTRB(12, 6, 4, 6),
                child: Row(children: [
                  design.builder(context, spec),
                  const SizedBox(width: 12),
                  Expanded(
                      child: Text(message,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(color: foreground))),
                  if (!compact) ...[
                    TextButton(
                        onPressed: () {},
                        style:
                            TextButton.styleFrom(foregroundColor: foreground),
                        child: const Text('Details')),
                    IconButton(
                        onPressed: () {},
                        icon: Icon(Icons.close, color: foreground)),
                  ] else
                    const SizedBox(height: 40, width: 8),
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

Widget _sheet(BannerActivityDesign design) {
  Widget column(bool dark) => _themed(
      dark,
      Builder(
          builder: (context) =>
              Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                for (final (
                      title,
                      kind,
                      phase,
                      progress,
                      count,
                      message,
                      animate
                    ) in _galleryCases) ...[
                  Text(title,
                      style: Theme.of(context).textTheme.labelSmall?.copyWith(
                          color:
                              Theme.of(context).colorScheme.onSurfaceVariant)),
                  const SizedBox(height: 4),
                  GalleryBanner(
                      design: design,
                      kind: kind,
                      phase: phase,
                      progress: progress,
                      count: count,
                      message: message,
                      animate: animate),
                  const SizedBox(height: 10),
                ]
              ])));
  return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _themed(
            false,
            Builder(
                builder: (context) => Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text('${design.name} · ${design.author}',
                              style: Theme.of(context).textTheme.titleMedium),
                          const SizedBox(height: 4),
                          SizedBox(
                              width: _bannerWidth * 2 + 32,
                              child: Text(design.summary,
                                  style:
                                      Theme.of(context).textTheme.bodySmall)),
                        ]))),
        Row(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [column(false), column(true)]),
      ]);
}

/// One journey segment: a kind working, then its successful result.
typedef _Segment = (
  BannerActivityKind kind,
  int workingMs,
  int doneMs,
  String working,
  String done
);

const List<_Segment> _segments = [
  (
    BannerActivityKind.listing,
    1800,
    800,
    'Listing all objects in media-archive…',
    'Listed 4800 objects in media-archive.'
  ),
  (
    BannerActivityKind.deleting,
    1600,
    800,
    'Deleting 12 objects…',
    'Deleted 12 objects.'
  ),
  (
    BannerActivityKind.benchmark,
    1800,
    800,
    'Benchmark running on media-archive',
    'Benchmark complete'
  ),
  (
    BannerActivityKind.action,
    1200,
    800,
    'Creating bucket media-archive…',
    'Created bucket media-archive.'
  ),
  (
    BannerActivityKind.exporting,
    1200,
    800,
    'Exporting event log…',
    'Event log exported to ~/Downloads.'
  ),
];

/// Banner state at time [t] of the journey, or null after it ends.
({
  BannerActivityKind kind,
  BannerActivityPhase phase,
  double? progress,
  int? count,
  String message,
})? journeyAt(Duration t) {
  var ms = t.inMilliseconds;
  for (final (kind, working, done, workingText, doneText) in _segments) {
    if (ms < working) {
      final f = ms / working;
      return (
        kind: kind,
        phase: BannerActivityPhase.working,
        progress: kind == BannerActivityKind.benchmark ? f : null,
        count: switch (kind) {
          BannerActivityKind.listing => (f * 4800).round() ~/ 200 * 200,
          BannerActivityKind.deleting => 12,
          _ => null,
        },
        message: workingText,
      );
    }
    ms -= working;
    if (ms < done) {
      return (
        kind: kind,
        phase: BannerActivityPhase.succeeded,
        progress: kind == BannerActivityKind.benchmark ? 1.0 : null,
        count: switch (kind) {
          BannerActivityKind.listing => 4800,
          BannerActivityKind.deleting => 12,
          _ => null,
        },
        message: doneText,
      );
    }
    ms -= done;
  }
  return null;
}

const journeyFrame = Duration(milliseconds: 50); // 20 fps

Future<void> captureGallery(
    WidgetTester tester, BannerActivityDesign design) async {
  debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
  addTearDown(() => debugDefaultTargetPlatformOverride = null);
  await _loadFonts();
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = const Size(1200, 2000);
  addTearDown(tester.view.reset);
  final out = Directory('../../.tmp/banner-activity-designs/${design.id}');
  if (out.existsSync()) out.deleteSync(recursive: true);

  final sheetKey = GlobalKey();
  await tester.pumpWidget(MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: _theme(false),
      home: Align(
          alignment: Alignment.topLeft,
          child: RepaintBoundary(key: sheetKey, child: _sheet(design)))));
  for (var i = 0; i < 20; i++) {
    await tester.pump(const Duration(milliseconds: 35));
  }
  await _capture(tester, sheetKey, File('${out.path}/sheet.png'));

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
                    final s = journeyAt(t)!;
                    return Row(mainAxisSize: MainAxisSize.min, children: [
                      for (final dark in [false, true])
                        _themed(
                            dark,
                            GalleryBanner(
                                // A new banner per activity, like the app.
                                key: ValueKey('journey-${s.kind.name}-$dark'),
                                design: design,
                                kind: s.kind,
                                phase: s.phase,
                                progress: s.progress,
                                count: s.count,
                                message: s.message)),
                    ]);
                  })))));
  var frame = 0;
  while (journeyAt(elapsed.value + journeyFrame) != null) {
    await _capture(
        tester,
        journeyKey,
        File('${out.path}/journey/'
            'frame_${frame.toString().padLeft(3, '0')}.png'));
    frame++;
    elapsed.value += journeyFrame;
    await tester.pump(journeyFrame);
  }
  await tester.pumpWidget(const SizedBox.shrink());
  debugDefaultTargetPlatformOverride = null;
}

/// Every design's journey stacked and labelled, for one comparison GIF.
Future<void> captureComparison(
    WidgetTester tester, List<BannerActivityDesign> designs) async {
  debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
  addTearDown(() => debugDefaultTargetPlatformOverride = null);
  await _loadFonts();
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = const Size(1200, 2000);
  addTearDown(tester.view.reset);
  final out = Directory('../../.tmp/banner-activity-designs/comparison');
  if (out.existsSync()) out.deleteSync(recursive: true);
  final key = GlobalKey();
  final elapsed = ValueNotifier(Duration.zero);
  await tester.pumpWidget(MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: _theme(false),
      home: Align(
          alignment: Alignment.topLeft,
          child: RepaintBoundary(
              key: key,
              child: ValueListenableBuilder<Duration>(
                  valueListenable: elapsed,
                  builder: (context, t, _) {
                    final s = journeyAt(t)!;
                    return Column(mainAxisSize: MainAxisSize.min, children: [
                      for (final (i, design) in designs.indexed)
                        Row(mainAxisSize: MainAxisSize.min, children: [
                          for (final dark in [false, true])
                            _themed(
                                dark,
                                Builder(
                                    builder: (context) => Column(
                                            crossAxisAlignment:
                                                CrossAxisAlignment.start,
                                            children: [
                                              Text(
                                                  dark
                                                      ? ''
                                                      : '${i + 1} · ${design.name} — ${design.author}',
                                                  style: Theme.of(context)
                                                      .textTheme
                                                      .titleSmall),
                                              const SizedBox(height: 6),
                                              GalleryBanner(
                                                  key: ValueKey(
                                                      '${design.id}-${s.kind.name}-$dark'),
                                                  design: design,
                                                  kind: s.kind,
                                                  phase: s.phase,
                                                  progress: s.progress,
                                                  count: s.count,
                                                  message: s.message),
                                            ]))),
                        ]),
                    ]);
                  })))));
  var frame = 0;
  while (journeyAt(elapsed.value + journeyFrame) != null) {
    await _capture(
        tester,
        key,
        File('${out.path}/journey/'
            'frame_${frame.toString().padLeft(3, '0')}.png'));
    frame++;
    elapsed.value += journeyFrame;
    await tester.pump(journeyFrame);
  }
  await tester.pumpWidget(const SizedBox.shrink());
  debugDefaultTargetPlatformOverride = null;
}

/// Per-situation clip state at time [t], or null when the clip ends.
typedef ClipState = ({
  BannerActivityPhase phase,
  double? progress,
  int? count,
  String message,
});

ClipState? clipAt(BannerActivityKind kind, Duration t) {
  final ms = t.inMilliseconds;
  ClipState state(BannerActivityPhase phase, String message,
          {double? progress, int? count}) =>
      (phase: phase, progress: progress, count: count, message: message);
  switch (kind) {
    case BannerActivityKind.listing:
      if (ms < 2200) {
        return state(BannerActivityPhase.working, 'Listing all objects…',
            count: (ms / 2200 * 4800).round() ~/ 200 * 200);
      }
      return ms < 3400
          ? state(BannerActivityPhase.succeeded, 'Listed 4800 objects.',
              count: 4800)
          : null;
    case BannerActivityKind.deleting:
      if (ms < 2000) {
        return state(BannerActivityPhase.working, 'Deleting 12 objects…',
            count: 12);
      }
      return ms < 3200
          ? state(BannerActivityPhase.succeeded, 'Deleted 12 objects.',
              count: 12)
          : null;
    case BannerActivityKind.benchmark:
      if (ms < 1400) {
        return state(BannerActivityPhase.working, 'Benchmark running',
            progress: ms / 1400 * .6);
      }
      if (ms < 2200) {
        return state(BannerActivityPhase.paused, 'Benchmark paused',
            progress: .6);
      }
      if (ms < 3200) {
        return state(BannerActivityPhase.working, 'Benchmark running',
            progress: .6 + (ms - 2200) / 1000 * .4);
      }
      return ms < 4400
          ? state(BannerActivityPhase.succeeded, 'Benchmark complete',
              progress: 1)
          : null;
    case BannerActivityKind.action:
      if (ms < 1600) {
        return state(BannerActivityPhase.working, 'Creating bucket…');
      }
      return ms < 2800
          ? state(BannerActivityPhase.succeeded, 'Created bucket.')
          : null;
    case BannerActivityKind.exporting:
      if (ms < 1600) {
        return state(BannerActivityPhase.working, 'Exporting event log…');
      }
      return ms < 2800
          ? state(BannerActivityPhase.succeeded, 'Event log exported.')
          : null;
    case BannerActivityKind.message:
      return null;
  }
}

const _clipWidth = 300.0;

/// One short clip per situation (light and dark side by side) plus a still
/// of the static messages, for the per-situation comparison page.
Future<void> captureClips(
    WidgetTester tester, BannerActivityDesign design) async {
  debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
  addTearDown(() => debugDefaultTargetPlatformOverride = null);
  await _loadFonts();
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = const Size(1200, 1200);
  addTearDown(tester.view.reset);
  const root = '../../.tmp/banner-activity-designs/clips';
  for (final kind in BannerActivityKind.values) {
    if (kind == BannerActivityKind.message) continue;
    final out = Directory('$root/${kind.name}/${design.id}');
    if (out.existsSync()) out.deleteSync(recursive: true);
    final key = GlobalKey();
    final elapsed = ValueNotifier(Duration.zero);
    await tester.pumpWidget(MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: _theme(false),
        home: Align(
            alignment: Alignment.topLeft,
            child: RepaintBoundary(
                key: key,
                child: ValueListenableBuilder<Duration>(
                    valueListenable: elapsed,
                    builder: (context, t, _) {
                      final s = clipAt(kind, t)!;
                      return Row(mainAxisSize: MainAxisSize.min, children: [
                        for (final dark in [false, true])
                          _themed(
                              dark,
                              GalleryBanner(
                                  key: ValueKey('clip-$dark'),
                                  design: design,
                                  kind: kind,
                                  phase: s.phase,
                                  progress: s.progress,
                                  count: s.count,
                                  message: s.message,
                                  width: _clipWidth,
                                  compact: true)),
                      ]);
                    })))));
    var frame = 0;
    while (clipAt(kind, elapsed.value + journeyFrame) != null) {
      await _capture(tester, key,
          File('${out.path}/frame_${frame.toString().padLeft(3, '0')}.png'));
      frame++;
      elapsed.value += journeyFrame;
      await tester.pump(journeyFrame);
    }
    await tester.pumpWidget(const SizedBox.shrink());
  }

  final key = GlobalKey();
  const messages = [
    (BannerActivityPhase.info, 'Using Rust engine.'),
    (BannerActivityPhase.succeeded, 'Created bucket.'),
    (BannerActivityPhase.warning, 'Deleted 10; 2 failed.'),
    (BannerActivityPhase.failed, 'Connection refused'),
    (BannerActivityPhase.cancelled, 'Listing cancelled.'),
  ];
  await tester.pumpWidget(MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: _theme(false),
      home: Align(
          alignment: Alignment.topLeft,
          child: RepaintBoundary(
              key: key,
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                for (final dark in [false, true])
                  _themed(
                      dark,
                      Column(mainAxisSize: MainAxisSize.min, children: [
                        for (final (i, (phase, message)) in messages.indexed)
                          Padding(
                              padding: EdgeInsets.only(top: i == 0 ? 0 : 8),
                              child: GalleryBanner(
                                  design: design,
                                  kind: phase == BannerActivityPhase.cancelled
                                      ? BannerActivityKind.listing
                                      : BannerActivityKind.message,
                                  phase: phase,
                                  message: message,
                                  width: _clipWidth,
                                  compact: true)),
                      ])),
              ])))));
  for (var i = 0; i < 20; i++) {
    await tester.pump(const Duration(milliseconds: 35));
  }
  await _capture(tester, key, File('$root/message/${design.id}.png'));
  await tester.pumpWidget(const SizedBox.shrink());
  debugDefaultTargetPlatformOverride = null;
}
