import 'dart:math' as math;
import 'dart:ui' show lerpDouble;

import 'package:flutter/material.dart';

import 'banner_activity_spec.dart';
import 'living_glyph_painter.dart' show GlyphPalette;

class BucketActivityIndicator extends StatefulWidget {
  const BucketActivityIndicator({
    super.key,
    required this.animation,
    required this.spec,
  });

  final BucketActivityAnimation animation;
  final BannerActivitySpec spec;

  @override
  State<BucketActivityIndicator> createState() => _BucketActivityState();
}

class _BucketActivityState extends State<BucketActivityIndicator>
    with SingleTickerProviderStateMixin {
  late final _clock = AnimationController(vsync: this);
  double _departure = .52;

  bool get _waiting =>
      widget.spec.isWorking || widget.spec.phase == BannerActivityPhase.paused;

  @override
  void initState() {
    super.initState();
    _configure();
  }

  @override
  void didUpdateWidget(BucketActivityIndicator oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.animation != widget.animation) {
      _departure = .52;
    } else if (!_waiting && oldWidget.spec.isWorking) {
      _departure = _clock.value;
    }
    if (oldWidget.animation != widget.animation ||
        oldWidget.spec.phase != widget.spec.phase ||
        oldWidget.spec.animate != widget.spec.animate) {
      _configure();
    }
  }

  void _configure() {
    _clock.stop();
    if (!_waiting) {
      if (widget.spec.animate) {
        _clock
          ..duration = const Duration(milliseconds: 720)
          ..forward(from: 0);
      } else {
        _clock.value = 1;
      }
    } else if (widget.spec.animate &&
        widget.spec.phase != BannerActivityPhase.paused) {
      final period = switch (widget.animation) {
        BucketActivityAnimation.clockSet => 1000,
        BucketActivityAnimation.shieldScan => 1080,
        BucketActivityAnimation.hangTag => 1200,
        BucketActivityAnimation.boltThrow => 1050,
        BucketActivityAnimation.levelMatch => 1320,
      };
      _clock
        ..duration = Duration(
            milliseconds: widget.spec.phase == BannerActivityPhase.stopping
                ? period * 2
                : period)
        ..repeat();
    } else {
      _clock.value =
          widget.animation == BucketActivityAnimation.levelMatch ? 0 : .52;
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
    final palette = GlyphPalette.resolve(Theme.of(context).colorScheme, spec);
    return ExcludeSemantics(
      child: RepaintBoundary(
        child: TweenAnimationBuilder<double>(
          tween: Tween<double>(end: (spec.count ?? 0).toDouble()),
          duration:
              spec.animate ? const Duration(milliseconds: 580) : Duration.zero,
          builder: (context, level, _) => CustomPaint(
            size: const Size(28, 32),
            painter: BucketActivityPainter(
              animation: widget.animation,
              phase: spec.phase,
              clock: _clock,
              waiting: _waiting,
              departure: _departure,
              level: level,
              count: spec.count ?? 0,
              ink: palette.line,
              accent: _waiting ? palette.live : palette.mark,
              surface: spec.background,
            ),
          ),
        ),
      ),
    );
  }
}

/// Each glyph fits the same status-card slot. When a result arrives the
/// working pose is frozen and the chosen handoff runs once.
class BucketActivityPainter extends CustomPainter {
  BucketActivityPainter({
    required this.animation,
    required this.phase,
    required this.clock,
    required this.waiting,
    required this.departure,
    required this.level,
    required this.count,
    required this.ink,
    required this.accent,
    required this.surface,
  }) : super(repaint: clock);

  final BucketActivityAnimation animation;
  final BannerActivityPhase phase;
  final Animation<double> clock;
  final bool waiting;
  final double departure, level;
  final int count;
  final Color ink, accent, surface;

  bool get _succeeded => phase == BannerActivityPhase.succeeded;

  static const _tau = 2 * math.pi;
  static const _center = Offset(14, 16);

  static double _beat(double value, double start, double end,
          [Curve curve = Curves.easeInOutCubic]) =>
      curve.transform(((value - start) / (end - start)).clamp(0.0, 1.0));

  static Paint _pen(Color color, [double width = 1.5]) => Paint()
    ..color = color
    ..style = PaintingStyle.stroke
    ..strokeCap = StrokeCap.round
    ..strokeJoin = StrokeJoin.round
    ..strokeWidth = width;

  static Paint _fill(Color color) => Paint()..color = color;

  static void _line(Canvas canvas, double x1, double y1, double x2, double y2,
          Color color,
          [double width = 1.5]) =>
      canvas.drawLine(Offset(x1, y1), Offset(x2, y2), _pen(color, width));

  static void _stroke(Canvas canvas, Path path, double reveal, Paint pen) {
    if (reveal <= 0) return;
    if (reveal >= 1) {
      canvas.drawPath(path, pen);
      return;
    }
    final metric = path.computeMetrics().first;
    canvas.drawPath(metric.extractPath(0, metric.length * reveal), pen);
  }

  void _mark(Canvas canvas, Offset at, double reveal, {double scale = 1}) {
    if (reveal == 0) return;
    canvas.save();
    canvas.translate(at.dx, at.dy);
    canvas.scale(scale);
    final pen = _pen(accent, 1.85);
    if (_succeeded) {
      _stroke(
          canvas,
          Path()
            ..moveTo(-4.4, -.6)
            ..lineTo(-1.3, 2.6)
            ..lineTo(4.6, -3.6),
          reveal,
          pen);
    } else {
      _stroke(
          canvas,
          Path()
            ..moveTo(-3.45, -3.45)
            ..lineTo(3.45, 3.45),
          _beat(reveal, 0, .65),
          pen);
      _stroke(
          canvas,
          Path()
            ..moveTo(3.45, -3.45)
            ..lineTo(-3.45, 3.45),
          _beat(reveal, .26, 1),
          pen);
    }
    canvas.restore();
  }

  @override
  void paint(Canvas canvas, Size size) {
    canvas.translate((size.width - 28) / 2, (size.height - 32) / 2);
    final work = waiting ? clock.value : departure;
    final finish = waiting ? 0.0 : clock.value;
    switch (animation) {
      case BucketActivityAnimation.levelMatch:
        _levelMatch(canvas, work, finish);
      case BucketActivityAnimation.clockSet:
        _clockSet(canvas, work, finish);
      case BucketActivityAnimation.shieldScan:
        _shieldScan(canvas, work, finish);
      case BucketActivityAnimation.hangTag:
        _hangTag(canvas, work, finish);
      case BucketActivityAnimation.boltThrow:
        _boltThrow(canvas, work, finish);
    }
  }

  static Path _pail(double x, double top, double height) => Path()
    ..moveTo(x - 5.5, top)
    ..lineTo(x + 5.5, top)
    ..lineTo(x + 3.96, top + height)
    ..lineTo(x - 3.96, top + height)
    ..close();

  void _levelMatch(Canvas canvas, double t, double f) {
    const x = 19.5;
    const top = 17.0;
    const floor = 27.5;
    final source = _pail(8.5, 4.5, 10);
    final target = _pail(x, top, floor - top);
    canvas.drawPath(source, _pen(ink));
    for (final y in [8.0, 11.0]) {
      _line(canvas, 5.6, y, 11.2, y, ink);
    }

    final solid = _succeeded ? _beat(f, .02, .42) : 0.0;
    final dashInk = accent.withValues(alpha: 1 - _beat(solid, .38, 1));
    if (solid < 1) {
      final outline = target.computeMetrics().first;
      const period = 3.8;
      final shift = t * period;
      for (var d = -period + shift; d < outline.length; d += period) {
        final start = math.max(0.0, d);
        final end = math.min(outline.length, d + 1.5);
        if (end > start) {
          canvas.drawPath(outline.extractPath(start, end), _pen(dashInk, 1.2));
        }
      }
    }
    _stroke(canvas, target, solid, _pen(ink));

    // A level step corresponds to a reported copy. The copy workflow
    // deliberately has no overall progress percentage or estimated total.
    final delivered = _succeeded ? count.toDouble() : level;
    final steps = lerpDouble(level, delivered, _beat(f, 0, .25))!;
    final first = _beat(steps, .56, .96);
    final second = _beat(steps, 1.56, 1.96);
    final y = lerpDouble(lerpDouble(26.7, 24, first), 21, second)!;
    final lift = _beat(f, .28, .66);
    if (first > 0) {
      canvas.save();
      canvas.clipPath(target);
      canvas.drawRect(Rect.fromLTRB(x - 6, y, x + 6, floor),
          _fill(accent.withValues(alpha: .2 * (1 - solid))));
      canvas.restore();
      if (second > 0) _line(canvas, 16.6, 24, 22.4, 24, ink);
      final half = 2.9 * math.min(1, first * 3);
      _line(canvas, x - half, y, x + half, y, Color.lerp(accent, ink, lift)!);
    }
    final delivery = steps - steps.floor();
    if (waiting && delivery > .04 && delivery < .64) {
      final across = _beat(delivery, .04, .34);
      final drop = _beat(delivery, .32, .6, Curves.easeInQuad);
      final alpha = _beat(delivery, .04, .12) * (1 - _beat(delivery, .56, .64));
      canvas.drawCircle(
          Offset(lerpDouble(12.6, x, across)!,
              lerpDouble(9.6, steps < 1 ? 26 : 24, drop)!),
          1.1,
          _fill(accent.withValues(alpha: alpha)));
    }
    final reveal = _beat(f, .56, 1);
    if (_succeeded && count > 0 && f > .2 && reveal < .32) {
      canvas.drawCircle(
          Offset(lerpDouble(x, 17.52, lift)!, lerpDouble(y, 8.78, lift)!),
          lerpDouble(1.1, .7, lift)!,
          _fill(accent.withValues(
              alpha: _beat(f, .2, .38) * (1 - _beat(reveal, 0, .32)))));
    }
    _mark(canvas, const Offset(20.6, 9.2), reveal, scale: .7);
  }

  void _clockSet(Canvas canvas, double t, double f) {
    canvas.drawCircle(_center, 10.25, _pen(ink));
    final tuck = _beat(f, .02, .24);
    final tick = (t * 4).floor();
    final turn =
        -math.pi / 2 + (tick + _beat(t * 4 - tick, .12, .62)) * math.pi / 2;
    if (tuck < 1) {
      for (var i = 0; i < 4; i++) {
        final angle = i * math.pi / 2;
        final d = Offset(math.cos(angle), math.sin(angle));
        final r = 7.4 + 1.5 * tuck;
        canvas.drawLine(_center + d * r, _center + d * (r + 1.1),
            _pen(ink.withValues(alpha: 1 - tuck), 1.3));
      }
      final tip =
          _center + Offset(math.cos(turn), math.sin(turn)) * (6.3 * (1 - tuck));
      canvas.drawLine(_center, tip, _pen(accent, 1.7));
    }
    final hub = 1.3 * (1 - _beat(f, .16, .3));
    if (hub > 0) canvas.drawCircle(_center, hub, _fill(ink));
    _mark(canvas, const Offset(14, 16.75), _beat(f, .32, .8), scale: 1.05);
  }

  void _shieldScan(Canvas canvas, double t, double f) {
    canvas.drawPath(
        Path()
          ..moveTo(14, 5.4)
          ..lineTo(22.2, 8.2)
          ..lineTo(22.2, 15.2)
          ..cubicTo(22.2, 20.6, 18.6, 24.3, 14, 26.8)
          ..cubicTo(9.4, 24.3, 5.8, 20.6, 5.8, 15.2)
          ..lineTo(5.8, 8.2)
          ..close(),
        _pen(ink));
    const center = Offset(14, 16.2);
    final y = lerpDouble(10.6, 21.2, (1 - math.cos(_tau * t)) / 2)!;
    final half = 5.6 - 2.1 * math.pow(math.max(0, (y - 15.2) / 6), 1.8);
    final handoff = _beat(f, .02, .26);
    if (handoff < 1) {
      final start = center +
          (_succeeded ? const Offset(-4.4, -.6) : const Offset(-3.45, -3.45));
      canvas.drawLine(
          Offset.lerp(Offset(14 - half, y), start, handoff)!,
          Offset.lerp(Offset(14 + half, y), start, handoff)!,
          _pen(accent, 1.6));
    }
    _mark(canvas, center, _beat(f, .25, .75));
  }

  void _hangTag(Canvas canvas, double t, double f) {
    final leave = _beat(f, .04, .47);
    if (leave < 1) {
      final color = ink.withValues(alpha: 1 - leave);
      final live = accent.withValues(alpha: 1 - leave);
      canvas.save();
      canvas
        ..translate(14, 16)
        ..scale(1 - .4 * leave)
        ..translate(-14, -16)
        ..translate(10, 9)
        ..rotate(-.34 * math.sin(_tau * t) * (1 - t));
      canvas.drawPath(
          Path()
            ..moveTo(-3.3, -3.3)
            ..lineTo(3.8, -3.3)
            ..lineTo(13.4, 7.2)
            ..quadraticBezierTo(14.2, 8, 13.3, 8.9)
            ..lineTo(6.4, 15.2)
            ..quadraticBezierTo(5.6, 15.9, 4.9, 15)
            ..lineTo(-3.3, 5.2)
            ..close(),
          _pen(color, 1.6));
      canvas.drawCircle(Offset.zero, 1.15, _fill(live));
      _line(canvas, 4.6, 9, 8.8, 5.2, live, 1.65);
      canvas.restore();
    }
    final sweep = _beat(f, .26, .74);
    if (sweep > 0) {
      canvas.drawArc(Rect.fromCircle(center: _center, radius: 10.25),
          -math.pi / 2, _tau * sweep, false, _pen(ink));
    }
    _mark(canvas, const Offset(14, 16.75), _beat(f, .43, 1), scale: 1.05);
  }

  void _boltThrow(Canvas canvas, double t, double f) {
    final tuck = _beat(f, .16, .34);
    final step = (t * 3).floor();
    final local = t * 3 - step;
    final angle = -math.pi / 2 + (step + _beat(local, .1, .6)) * _tau / 3;
    canvas.save();
    if (_succeeded) {
      canvas.translate(
          .5 * math.sin(math.pi * _beat(f, .16, .3, Curves.linear)), 0);
    }
    canvas.drawRRect(
        RRect.fromLTRBR(4.6, 5.4, 23.4, 26.6, const Radius.circular(3)),
        _pen(ink));
    if (tuck < 1) {
      for (final y in [10.2, 21.8]) {
        _line(canvas, 4.6, y - 1.1, 4.6, y + 1.1,
            ink.withValues(alpha: 1 - tuck), 2.2);
      }
    }
    canvas.save();
    canvas.clipRect(const Rect.fromLTRB(0, 0, 22.65, 32));
    for (final (i, y) in [11.7, 20.3].indexed) {
      final offset = i * .05;
      final travel = _succeeded
          ? _beat(f, .02 + offset, .15 + offset, Curves.easeInQuad)
          : .45 * math.sin(math.pi * _beat(f, 0, .22, Curves.linear));
      final click =
          1.9 * math.sin(math.pi * _beat(local, .1, .8, Curves.linear));
      final reach = lerpDouble(click, 9, travel)!;
      final alpha = _succeeded ? 1.0 : 1 - _beat(f, .18, .32);
      _line(canvas, 15 + reach, y, 18.5 + reach, y,
          accent.withValues(alpha: alpha), 1.6);
    }
    canvas.restore();
    final radius = 4.25 * (1 - tuck);
    if (radius > .4) {
      final opacity = 1 - _beat(tuck, .7, 1, Curves.linear);
      canvas.drawCircle(
          _center, radius, _fill(surface.withValues(alpha: opacity)));
      canvas.drawCircle(_center, radius, _pen(ink.withValues(alpha: opacity)));
      for (var i = 0; i < 3; i++) {
        final spoke = angle + i * _tau / 3;
        final tip =
            _center + Offset(math.cos(spoke), math.sin(spoke)) * (.81 * radius);
        canvas.drawLine(
            _center, tip, _pen(ink.withValues(alpha: opacity), 1.2));
      }
    }
    _mark(canvas, const Offset(14, 15.5), _beat(f, .38, .82));
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant BucketActivityPainter oldDelegate) =>
      oldDelegate.animation != animation ||
      oldDelegate.phase != phase ||
      oldDelegate.clock != clock ||
      oldDelegate.waiting != waiting ||
      oldDelegate.departure != departure ||
      oldDelegate.level != level ||
      oldDelegate.count != count ||
      oldDelegate.ink != ink ||
      oldDelegate.accent != accent ||
      oldDelegate.surface != surface;
}
