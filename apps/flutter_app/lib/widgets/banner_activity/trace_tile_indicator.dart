import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'banner_activity_spec.dart';

/// Benchmark and export banners: an outline tool inside a rounded tile with a
/// travelling border trace, or a determinate perimeter for benchmarks.
class TraceTileIndicator extends StatefulWidget {
  const TraceTileIndicator({super.key, required this.spec});
  final BannerActivitySpec spec;

  @override
  State<TraceTileIndicator> createState() => _TraceTileState();
}

class _TraceTileState extends State<TraceTileIndicator>
    with SingleTickerProviderStateMixin {
  late final AnimationController _clock;
  BannerActivitySpec? _previous;
  double _departure = .22;

  @override
  void initState() {
    super.initState();
    _clock = AnimationController(vsync: this);
    _configure();
  }

  void _configure() {
    _clock.stop();
    if (!widget.spec.animate) {
      _previous = null;
      _clock.value = 1;
    } else if (widget.spec.phase == BannerActivityPhase.working) {
      _previous = null;
      _clock.duration = Duration(
        milliseconds: switch (widget.spec.kind) {
          BannerActivityKind.deleting => 1800,
          BannerActivityKind.exporting => 1200,
          _ => 1450,
        },
      );
      _clock.repeat();
    } else if (widget.spec.phase == BannerActivityPhase.stopping) {
      // One final lap slows to rest; stopping never loops indefinitely.
      _clock.duration = const Duration(milliseconds: 1600);
      _clock.forward(from: 0);
    } else if (_previous != null) {
      _clock.duration = const Duration(milliseconds: 340);
      _clock.forward(from: 0);
    } else {
      _clock.value = 1;
    }
  }

  @override
  void didUpdateWidget(covariant TraceTileIndicator oldWidget) {
    super.didUpdateWidget(oldWidget);
    final old = oldWidget.spec;
    final spec = widget.spec;
    if (old.phase != spec.phase ||
        old.kind != spec.kind ||
        old.animate != spec.animate) {
      _departure = old.phase == BannerActivityPhase.working
          ? (old.animate ? _clock.value : .22)
          : .22;
      _previous = old;
      _configure();
    }
  }

  @override
  void dispose() {
    _clock.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final spec = widget.spec;
    final wide = spec.kind == BannerActivityKind.listing ||
        spec.kind == BannerActivityKind.deleting ||
        spec.kind == BannerActivityKind.benchmark;
    final amount = spec.kind == BannerActivityKind.benchmark
        ? '${(_progress(spec) * 100).round()}%'
        : spec.count == null
            ? null
            : _abbreviate(spec.count!);
    final caption = switch (spec.phase) {
      BannerActivityPhase.working => switch (spec.kind) {
          BannerActivityKind.listing => 'LIST',
          BannerActivityKind.deleting => 'DELETE',
          BannerActivityKind.benchmark => 'BENCH',
          _ => 'WORK',
        },
      BannerActivityPhase.paused => 'PAUSED',
      BannerActivityPhase.stopping => 'STOP…',
      BannerActivityPhase.succeeded => 'DONE',
      BannerActivityPhase.info => 'INFO',
      BannerActivityPhase.warning => 'NOTICE',
      BannerActivityPhase.failed => 'ERROR',
      BannerActivityPhase.cancelled => 'STOPPED',
    };
    final showAmount = amount != null &&
        (spec.isWorking || spec.phase == BannerActivityPhase.paused);
    return Semantics(
      label: _semantics(spec),
      child: ExcludeSemantics(
        child: SizedBox(
          width: wide ? 90 : 32,
          height: 32,
          child: Row(
            children: [
              RepaintBoundary(
                child: CustomPaint(
                  size: const Size(32, 32),
                  painter: _TilePainter(
                    spec: spec,
                    previous: _previous,
                    departure: _departure,
                    clock: _clock,
                    accent: _legible(
                      Theme.of(context).colorScheme.inversePrimary,
                      spec,
                    ),
                  ),
                ),
              ),
              if (wide) ...[
                const SizedBox(width: 8),
                Expanded(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      if (showAmount)
                        Text(
                          amount,
                          maxLines: 1,
                          textScaler: TextScaler.noScaling,
                          style: TextStyle(
                            color: spec.foreground,
                            fontSize: 12,
                            height: 1.15,
                            fontWeight: FontWeight.w600,
                            fontFeatures: const [FontFeature.tabularFigures()],
                          ),
                        ),
                      Text(
                        caption,
                        maxLines: 1,
                        textScaler: TextScaler.noScaling,
                        style: TextStyle(
                          color: spec.foreground,
                          fontSize: 9,
                          height: 1.3,
                          letterSpacing: .5,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

double _progress(BannerActivitySpec spec) {
  final value = spec.progress ?? 0;
  return value.isFinite ? value.clamp(0.0, 1.0) : 0;
}

String _abbreviate(int count) {
  final value = math.max(0, count);
  for (final unit in [(1000000000, 'b'), (1000000, 'm'), (1000, 'k')]) {
    if (value >= unit.$1) {
      final number = value / unit.$1;
      return '${number.toStringAsFixed(number < 10 ? 1 : 0)}${unit.$2}';
    }
  }
  return '$value';
}

String _semantics(BannerActivitySpec spec) {
  final name = switch (spec.kind) {
    BannerActivityKind.listing => 'Listing',
    BannerActivityKind.deleting => 'Deleting',
    BannerActivityKind.benchmark => 'Benchmark',
    BannerActivityKind.action => 'Action',
    BannerActivityKind.exporting => 'Export',
    BannerActivityKind.message => 'Message',
  };
  final detail = spec.kind == BannerActivityKind.benchmark
      ? ', ${(_progress(spec) * 100).round()} percent'
      : spec.count == null
          ? ''
          : ', ${spec.count} objects${spec.kind == BannerActivityKind.listing ? ' loaded' : ''}';
  return '$name, ${spec.phase.name}$detail';
}

double _contrast(Color a, Color b) {
  final x = a.computeLuminance();
  final y = b.computeLuminance();
  return (math.max(x, y) + .05) / (math.min(x, y) + .05);
}

Color _legible(Color candidate, BannerActivitySpec spec) =>
    _contrast(candidate, spec.background) >= 3 ? candidate : spec.foreground;

class _TilePainter extends CustomPainter {
  _TilePainter({
    required this.spec,
    required this.previous,
    required this.departure,
    required this.clock,
    required this.accent,
  }) : super(repaint: clock);

  final BannerActivitySpec spec;
  final BannerActivitySpec? previous;
  final double departure;
  final Animation<double> clock;
  final Color accent;

  bool get _transition =>
      previous != null &&
      spec.animate &&
      spec.phase != BannerActivityPhase.working &&
      spec.phase != BannerActivityPhase.stopping;

  @override
  void paint(Canvas canvas, Size size) {
    final t = _transition ? Curves.easeInOutCubic.transform(clock.value) : 1.0;
    final tile = RRect.fromRectAndRadius(
      const Rect.fromLTWH(2, 2, 28, 28),
      const Radius.circular(7),
    );
    final terminal =
        !spec.isWorking && spec.phase != BannerActivityPhase.paused;
    final wasTerminal = previous != null &&
        !previous!.isWorking &&
        previous!.phase != BannerActivityPhase.paused;
    final fill = _transition
        ? (wasTerminal ? 1.0 : 0.0) * (1 - t) + (terminal ? 1.0 : 0.0) * t
        : terminal
            ? 1.0
            : 0.0;
    // Keep the frame at >= 3:1; the brighter trace carries the motion.
    var track = Color.alphaBlend(
      spec.foreground.withValues(alpha: .5),
      spec.background,
    );
    if (_contrast(track, spec.background) < 3) track = spec.foreground;
    canvas.drawRRect(
      tile,
      Paint()
        ..color = track
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.4,
    );
    if (fill > 0) {
      canvas.save();
      canvas.clipRRect(tile);
      // The result rises from the bottom, preserving the original frame.
      canvas.drawRect(
        Rect.fromLTRB(1, 31 - 30 * fill, 31, 31),
        Paint()..color = spec.foreground,
      );
      canvas.restore();
    }
    final motion = spec.animate ? clock.value : .22;
    if (spec.isWorking || spec.phase == BannerActivityPhase.paused) {
      final path = Path()..addRRect(tile);
      final metric = path.computeMetrics().first;
      if (spec.kind == BannerActivityKind.benchmark) {
        canvas.drawPath(
          metric.extractPath(0, metric.length * _progress(spec)),
          _pen(accent, 2.3),
        );
        if (spec.phase == BannerActivityPhase.stopping && motion < 1) {
          // A final highlight catches the known progress, then settles.
          final end = metric.length * _progress(spec);
          final reach = Curves.easeOutCubic.transform(motion);
          canvas.drawPath(
            metric.extractPath(
              math.max(0, end * reach - 10 * (1 - reach)),
              end * reach,
            ),
            _pen(spec.foreground, 3.5 - 1.2 * reach),
          );
        }
      } else if (spec.phase != BannerActivityPhase.paused) {
        final stopping = spec.phase == BannerActivityPhase.stopping;
        final head = stopping
            ? departure + .7 * Curves.easeOutCubic.transform(motion)
            : motion;
        final length = stopping ? .26 * (1 - motion) + .04 : .26;
        final start = (head % 1) * metric.length;
        final end = start + metric.length * length;
        final pen = _pen(accent, 2.3);
        canvas.drawPath(
            metric.extractPath(start, math.min(end, metric.length)), pen);
        if (end > metric.length) {
          canvas.drawPath(metric.extractPath(0, end - metric.length), pen);
        }
      }
    }
    if (_transition && t < 1) {
      _glyphLayer(canvas, previous!, departure, 1 - t, fill);
    }
    _glyphLayer(canvas, spec, motion, t, fill);
  }

  Paint _pen(Color color, [double width = 1.5]) => Paint()
    ..color = color
    ..style = PaintingStyle.stroke
    ..strokeWidth = width
    ..strokeCap = StrokeCap.round
    ..strokeJoin = StrokeJoin.round;

  void _glyphLayer(Canvas canvas, BannerActivitySpec state, double motion,
      double opacity, double fill) {
    if (opacity <= 0) return;
    // Draw both sides of the rising fill in contrasting ink.
    for (final inside in [false, true]) {
      canvas.save();
      canvas.clipRect(inside
          ? Rect.fromLTRB(0, 31 - 30 * fill, 32, 32)
          : Rect.fromLTRB(0, 0, 32, 31 - 30 * fill));
      final color = (inside ? spec.background : spec.foreground)
          .withValues(alpha: opacity);
      _glyph(canvas, state, motion, _pen(color));
      canvas.restore();
    }
  }

  void _glyph(Canvas canvas, BannerActivitySpec state, double t, Paint pen) {
    void line(double x, double y, double x2, double y2) =>
        canvas.drawLine(Offset(x, y), Offset(x2, y2), pen);
    void path(List<Offset> points) {
      final p = Path()..moveTo(points.first.dx, points.first.dy);
      for (final point in points.skip(1)) {
        p.lineTo(point.dx, point.dy);
      }
      canvas.drawPath(p, pen);
    }

    switch (state.phase) {
      case BannerActivityPhase.succeeded:
        path(const [Offset(10, 16), Offset(14, 20), Offset(22, 12)]);
        return;
      case BannerActivityPhase.failed:
        line(12, 12, 20, 20);
        line(20, 12, 12, 20);
        return;
      case BannerActivityPhase.cancelled:
        canvas.drawCircle(const Offset(16, 16), 7, pen);
        line(11, 21, 21, 11);
        return;
      case BannerActivityPhase.warning:
        path(const [
          Offset(16, 8),
          Offset(24, 23),
          Offset(8, 23),
          Offset(16, 8)
        ]);
        line(16, 13, 16, 17);
        line(16, 20, 16, 20.2);
        return;
      case BannerActivityPhase.info:
        canvas.drawCircle(const Offset(16, 16), 7, pen);
        line(16, 15, 16, 20);
        line(16, 12, 16, 12.2);
        return;
      case BannerActivityPhase.paused:
        line(13, 11, 13, 21);
        line(19, 11, 19, 21);
        return;
      case BannerActivityPhase.stopping:
        canvas.drawRRect(
            RRect.fromRectAndRadius(
                const Rect.fromLTWH(12, 12, 8, 8), const Radius.circular(1.5)),
            pen);
        return;
      case BannerActivityPhase.working:
        break;
    }
    final wave = state.animate ? math.sin(t * math.pi * 2) : 0.0;
    switch (state.kind) {
      case BannerActivityKind.listing:
        for (var i = 0; i < 3; i++) {
          final y = 11.0 + i * 5;
          line(14, y, 23, y);
          canvas.drawCircle(Offset(9.5, y), .7, pen);
        }
        final row = state.animate ? (t * 3).floor().clamp(0, 2) : 1;
        line(14, 11.0 + row * 5, 17 + 5 * (state.animate ? (t * 3) % 1 : .6),
            11.0 + row * 5);
        canvas.drawCircle(
            Offset(9.5, 11.0 + row * 5), 1.5, Paint()..color = pen.color);
      case BannerActivityKind.deleting:
        path(const [
          Offset(11, 14),
          Offset(12, 23),
          Offset(20, 23),
          Offset(21, 14)
        ]);
        final lift = math.max(0.0, wave) * 1.7;
        line(10, 11 - lift, 22, 11 - lift);
        path([
          Offset(14, 11 - lift),
          Offset(14, 9 - lift),
          Offset(18, 9 - lift),
          Offset(18, 11 - lift)
        ]);
        line(15, 16, 15, 20);
        line(18, 16, 18, 20);
      case BannerActivityKind.benchmark:
        canvas.drawArc(
            const Rect.fromLTWH(9, 10, 14, 14), math.pi, math.pi, false, pen);
        final angle = math.pi * (.22 + .56 * _progress(state)) + .08 * wave;
        line(16, 18, 16 - math.cos(angle) * 6, 18 - math.sin(angle) * 6);
        line(10, 23, 22, 23);
      case BannerActivityKind.action:
        canvas.save();
        canvas.translate(16, 16);
        canvas.rotate(state.animate ? t * math.pi / 2 : 0);
        line(-6, 0, 6, 0);
        line(0, -6, 0, 6);
        canvas.restore();
        path(const [Offset(9, 12), Offset(9, 9), Offset(12, 9)]);
        path(const [Offset(20, 23), Offset(23, 23), Offset(23, 20)]);
      case BannerActivityKind.exporting:
        path(const [
          Offset(9, 19),
          Offset(9, 23),
          Offset(23, 23),
          Offset(23, 19)
        ]);
        final y = wave * 1.8;
        line(16, 19 + y, 16, 9 + y);
        path([Offset(12, 13 + y), Offset(16, 9 + y), Offset(20, 13 + y)]);
      case BannerActivityKind.message:
        canvas.drawCircle(const Offset(16, 16), 6, pen);
        line(16, 14, 16, 20);
        line(16, 11, 16, 11.2);
    }
  }

  @override
  bool shouldRepaint(covariant _TilePainter oldDelegate) =>
      oldDelegate.spec != spec ||
      oldDelegate.previous != previous ||
      oldDelegate.departure != departure ||
      oldDelegate.accent != accent ||
      oldDelegate.clock != clock;
}
