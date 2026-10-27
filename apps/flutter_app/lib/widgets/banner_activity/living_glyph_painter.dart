import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'banner_activity_spec.dart';

bool isResult(BannerActivityPhase phase) => switch (phase) {
      BannerActivityPhase.working ||
      BannerActivityPhase.paused ||
      BannerActivityPhase.stopping =>
        false,
      _ => true,
    };

/// Working loop length per kind; stopping runs the same loop 1.6x slower.
Duration loopPeriod(BannerActivityKind kind) => Duration(
      milliseconds: switch (kind) {
        BannerActivityKind.listing => 1000,
        BannerActivityKind.deleting => 1500,
        BannerActivityKind.benchmark => 1400,
        BannerActivityKind.action => 1500,
        BannerActivityKind.exporting => 1600,
        BannerActivityKind.message => 1500,
      },
    );

/// Loop position shown when nothing moves (paused or reduced motion): the
/// most legible moment of each motion.
double restFrame(BannerActivityKind kind) => switch (kind) {
      BannerActivityKind.listing => 1,
      BannerActivityKind.deleting => .42,
      BannerActivityKind.benchmark => 0,
      BannerActivityKind.action || BannerActivityKind.message => .1375,
      BannerActivityKind.exporting => .5,
    };

/// One glyph state: what to draw and where its loop stood.
@immutable
class GlyphFrame {
  const GlyphFrame({
    required this.kind,
    required this.phase,
    required this.t,
    required this.progress,
  });

  final BannerActivityKind kind;
  final BannerActivityPhase phase;
  final double t, progress;

  @override
  bool operator ==(Object other) =>
      other is GlyphFrame &&
      other.kind == kind &&
      other.phase == phase &&
      other.t == t &&
      other.progress == progress;

  @override
  int get hashCode => Object.hash(kind, phase, t, progress);
}

double _contrast(Color a, Color b) {
  final la = a.computeLuminance();
  final lb = b.computeLuminance();
  return (math.max(la, lb) + .05) / (math.min(la, lb) + .05);
}

/// Outlines use the banner text colour; the moving part of each glyph uses
/// the live accent, and a success check uses the primary colour, each only
/// when it keeps 3:1 against the banner.
@immutable
class GlyphPalette {
  const GlyphPalette({
    required this.line,
    required this.live,
    required this.mark,
  });

  final Color line, live, mark;

  static GlyphPalette resolve(ColorScheme scheme, BannerActivitySpec spec) {
    final fg = spec.foreground;
    final bg = spec.background;
    Color legible(Color candidate) =>
        _contrast(candidate, bg) >= 3 ? candidate : fg;
    return GlyphPalette(
      line: fg,
      live: spec.phase == BannerActivityPhase.paused
          ? fg
          : legible(scheme.inversePrimary),
      mark: spec.phase == BannerActivityPhase.succeeded
          ? legible(scheme.primary)
          : fg,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is GlyphPalette &&
      other.line == line &&
      other.live == live &&
      other.mark == mark;

  @override
  int get hashCode => Object.hash(line, live, mark);
}

Paint _pen(Color color, [double width = 1.5]) => Paint()
  ..color = color
  ..style = PaintingStyle.stroke
  ..strokeWidth = width
  ..strokeCap = StrokeCap.round
  ..strokeJoin = StrokeJoin.round;

Paint _fill(Color color) => Paint()..color = color;

double _interval(double t, double begin, double end,
        [Curve curve = Curves.linear]) =>
    curve.transform(((t - begin) / (end - begin)).clamp(0.0, 1.0));

const _center = Offset(14, 16);

class LivingGlyphPainter extends CustomPainter {
  LivingGlyphPainter({
    required this.clock,
    required this.frame,
    required this.from,
    required this.palette,
    required this.animate,
  }) : super(repaint: clock);

  final Animation<double> clock;

  /// The current state; its loop position is read from [clock].
  final GlyphFrame frame;

  /// The departing state during a result morph.
  final GlyphFrame? from;
  final GlyphPalette palette;
  final bool animate;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.translate((size.width - 28) / 2, (size.height - 32) / 2);
    final t = clock.value;
    if (!isResult(frame.phase)) {
      _paintKind(canvas, frame, t);
      return;
    }
    final departing = from;
    if (departing == null) {
      _paintStatus(canvas, frame.phase, 1);
      return;
    }
    // The working glyph contracts and fades toward the centre while the
    // result ring draws itself around it and the mark strokes in.
    final out = _interval(t, 0, .45, Curves.easeIn);
    if (out < 1) {
      _layer(canvas, 1 - out, 1 - .4 * out, () {
        if (isResult(departing.phase)) {
          _paintStatus(canvas, departing.phase, 1);
        } else {
          _paintKind(canvas, departing, departing.t);
        }
      });
    }
    _paintStatus(canvas, frame.phase, t);
  }

  void _layer(Canvas canvas, double opacity, double scale, VoidCallback draw) {
    canvas.saveLayer(
      const Rect.fromLTWH(-4, -4, 36, 40),
      Paint()..color = Color.fromRGBO(0, 0, 0, opacity.clamp(0.0, 1.0)),
    );
    canvas
      ..translate(_center.dx, _center.dy)
      ..scale(scale)
      ..translate(-_center.dx, -_center.dy);
    draw();
    canvas.restore();
  }

  void _paintKind(Canvas canvas, GlyphFrame f, double t) {
    switch (f.kind) {
      case BannerActivityKind.listing:
        _listing(canvas, t);
      case BannerActivityKind.deleting:
        _deleting(canvas, t);
      case BannerActivityKind.benchmark:
        _benchmark(canvas, t, f.progress, f.phase);
      case BannerActivityKind.action:
      case BannerActivityKind.message:
        _action(canvas, t);
      case BannerActivityKind.exporting:
        _exporting(canvas, t);
    }
  }

  // Listing: a list sheet with a header; a new row slides in under the
  // header and pushes the others down.
  void _listing(Canvas canvas, double t) {
    final line = palette.line;
    final live = palette.live;
    final pen = _pen(line);
    canvas.drawRRect(
      RRect.fromLTRBR(4.75, 5.25, 23.25, 26.75, const Radius.circular(3)),
      pen,
    );
    canvas.drawLine(const Offset(4.75, 10.5), const Offset(23.25, 10.5), pen);
    final s = _interval(t, 0, .55, Curves.easeInOutCubic);
    canvas.save();
    canvas.clipRect(const Rect.fromLTRB(5.5, 11.25, 22.5, 26));
    for (var i = 0; i < 4; i++) {
      final y = 14.75 + (i - 1 + s) * 4.6;
      final Color color;
      var dx = 0.0;
      if (i == 0) {
        color = live.withValues(alpha: s);
        dx = -(1 - s) * 7;
      } else if (i == 1) {
        color = Color.lerp(live, line, s)!;
      } else {
        color = line;
      }
      canvas.drawCircle(Offset(8.75 + dx, y), 1.2, _fill(color));
      canvas.drawLine(
          Offset(11.75 + dx, y), Offset(19.75 + dx, y), _pen(color));
    }
    canvas.restore();
  }

  // Deleting: an open bin; small items drop in one at a time and the bin
  // settles gently as each one lands.
  void _deleting(Canvas canvas, double t) {
    var settle = 0.0;
    for (var k = 0; k < 2; k++) {
      final q = (t + k * .5) % 1;
      settle = math.max(settle, math.sin(math.pi * _interval(q, .56, .78)));
    }
    canvas.save();
    canvas.translate(0, .7 * settle);
    final pen = _pen(palette.line);
    canvas.drawLine(const Offset(5.25, 12), const Offset(22.75, 12), pen);
    canvas.drawPath(
      Path()
        ..moveTo(7.4, 12)
        ..lineTo(8.6, 25)
        ..quadraticBezierTo(8.8, 26.75, 10.5, 26.75)
        ..lineTo(17.5, 26.75)
        ..quadraticBezierTo(19.2, 26.75, 19.4, 25)
        ..lineTo(20.6, 12),
      pen,
    );
    canvas.drawLine(const Offset(12, 15.75), const Offset(12, 23), pen);
    canvas.drawLine(const Offset(16, 15.75), const Offset(16, 23), pen);
    canvas.restore();
    // Items vanish behind the rim.
    canvas.save();
    canvas.clipRect(const Rect.fromLTRB(0, -4, 28, 11.1));
    for (var k = 0; k < 2; k++) {
      final q = (t + k * .5) % 1;
      // Appear and settle at the top, then drop.
      final fall = _interval(q, .2, .6, Curves.easeInQuad);
      final y =
          -3.5 + 2.5 * _interval(q, 0, .18, Curves.easeOutCubic) + 16 * fall;
      final alpha = _interval(q, 0, .14);
      final x = k == 0 ? 11.75 : 16.25;
      canvas.save();
      canvas.translate(x, y);
      canvas.rotate((k == 0 ? 1 : -1) * .55 * fall);
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromCenter(center: Offset.zero, width: 5, height: 5),
          const Radius.circular(1.2),
        ),
        _fill(palette.live.withValues(alpha: alpha)),
      );
      canvas.restore();
    }
    canvas.restore();
  }

  // Benchmark: a 270-degree dial whose arc fills with progress; the needle
  // jitters while running, sags back while stopping and rests when paused.
  // Pause and stop marks sit in the dial's open foot.
  void _benchmark(
      Canvas canvas, double t, double progress, BannerActivityPhase phase) {
    const c = _center;
    const r = 10.25;
    const start = .75 * math.pi;
    const sweep = 1.5 * math.pi;
    final line = palette.line;
    final rect = Rect.fromCircle(center: c, radius: r);
    canvas.drawArc(rect, start, sweep, false, _pen(line));
    for (var k = 1; k < 4; k++) {
      final a = start + k * sweep / 4;
      final d = Offset(math.cos(a), math.sin(a));
      canvas.drawLine(c + d * (r - 3.4), c + d * (r - 2.3), _pen(line, 1.2));
    }
    final p = progress.clamp(0.0, 1.0);
    if (p > 0) {
      canvas.drawArc(rect, start, sweep * p, false, _pen(palette.live, 3));
    }
    var shown = p;
    var jitter = 0.0;
    if (phase == BannerActivityPhase.stopping) {
      shown = p * (1 - .55 * Curves.easeInOutSine.transform(t));
    } else if (phase == BannerActivityPhase.working && animate) {
      jitter = .075 *
          (math.sin(2 * math.pi * 3 * t) + .45 * math.sin(2 * math.pi * 7 * t));
    }
    final a = start + sweep * shown + jitter;
    canvas.drawLine(
      c,
      c + Offset(math.cos(a), math.sin(a)) * (r - 3.6),
      _pen(line, 2),
    );
    canvas.drawCircle(c, 2, _fill(line));
    if (phase == BannerActivityPhase.paused) {
      final pen = _pen(line, 1.75);
      canvas.drawLine(const Offset(12.25, 21), const Offset(12.25, 24.5), pen);
      canvas.drawLine(const Offset(15.75, 21), const Offset(15.75, 24.5), pen);
    } else if (phase == BannerActivityPhase.stopping) {
      canvas.drawRRect(
        RRect.fromLTRBR(12.25, 21, 15.75, 24.5, const Radius.circular(.8)),
        _fill(line),
      );
    }
  }

  // Action: a gear clicks round one tooth at a time with a spark on each
  // click.
  void _action(Canvas canvas, double t) {
    const g = Offset(12.5, 17.5);
    final step = (t * 2).floor();
    final local = (t * 2) % 1;
    final turn = _interval(local, 0, .55, Curves.easeInOutCubic);
    final rotation = (step + turn) * math.pi / 4;
    const outer = 9.0, inner = 7.0;
    final gear = Path();
    for (var i = 0; i < 8; i++) {
      final a = rotation + i * math.pi / 4;
      Offset at(double angle, double radius) =>
          g + Offset(math.cos(angle), math.sin(angle)) * radius;
      final points = [
        at(a - .32, inner),
        at(a - .18, outer),
        at(a + .18, outer),
        at(a + .32, inner),
      ];
      if (i == 0) {
        gear.moveTo(points.first.dx, points.first.dy);
      } else {
        gear.lineTo(points.first.dx, points.first.dy);
      }
      for (final p in points.skip(1)) {
        gear.lineTo(p.dx, p.dy);
      }
    }
    gear.close();
    canvas.drawPath(gear, _pen(palette.line));
    canvas.drawCircle(g, 2.9, _pen(palette.live, 1.75));
    final pulse = math.sin(math.pi * _interval(local, 0, .6));
    final radius = 2 + 1.8 * pulse;
    const s = Offset(23, 5.5);
    final star = Path();
    for (var i = 0; i < 8; i++) {
      final a = -math.pi / 2 + i * math.pi / 4;
      final d = i.isEven ? radius : radius * .32;
      final p = s + Offset(math.cos(a), math.sin(a)) * d;
      if (i == 0) {
        star.moveTo(p.dx, p.dy);
      } else {
        star.lineTo(p.dx, p.dy);
      }
    }
    star.close();
    canvas.drawPath(star, _fill(palette.live));
  }

  // Exporting: a page slides down into an in-tray; the tray's slot lights
  // as it is received.
  void _exporting(Canvas canvas, double t) {
    final line = palette.line;
    final live = palette.live;
    final enter = _interval(t, 0, .16, Curves.easeOutCubic);
    final sink = _interval(t, .24, .86, Curves.easeInOutCubic);
    final top = -2 + 4 * enter + 16 * sink;
    final flash = math.sin(math.pi * _interval(t, .66, 1));
    canvas.save();
    canvas.clipRect(const Rect.fromLTRB(0, -4, 28, 17.2));
    final doc = Path()
      ..moveTo(9, top)
      ..lineTo(15.5, top)
      ..lineTo(19, top + 3.5)
      ..lineTo(19, top + 13)
      ..lineTo(9, top + 13)
      ..close();
    final color = live.withValues(alpha: enter);
    canvas.drawPath(doc, _pen(color));
    canvas.drawPath(
      Path()
        ..moveTo(15.5, top)
        ..lineTo(15.5, top + 3.5)
        ..lineTo(19, top + 3.5),
      _pen(color),
    );
    canvas.drawLine(
        Offset(11.75, top + 7), Offset(16.25, top + 7), _pen(color, 1.3));
    canvas.drawLine(
        Offset(11.75, top + 9.75), Offset(14.75, top + 9.75), _pen(color, 1.3));
    canvas.restore();
    final pen = _pen(line);
    canvas.drawPath(
      Path()
        ..moveTo(4, 18)
        ..lineTo(4, 25)
        ..quadraticBezierTo(4, 26.75, 5.75, 26.75)
        ..lineTo(22.25, 26.75)
        ..quadraticBezierTo(24, 26.75, 24, 25)
        ..lineTo(24, 18),
      pen,
    );
    canvas.drawPath(
      Path()
        ..moveTo(4, 18)
        ..lineTo(8.5, 18)
        ..lineTo(10.25, 21.5)
        ..lineTo(17.75, 21.5)
        ..lineTo(19.5, 18)
        ..lineTo(24, 18),
      _pen(Color.lerp(line, live, flash)!),
    );
  }

  /// Shared result glyphs: a ring (a triangle for warnings) with a check,
  /// cross, ! or i. [reveal] draws them in from 0 to 1.
  void _paintStatus(Canvas canvas, BannerActivityPhase phase, double reveal) {
    final ringT = _interval(reveal, .12, .72, Curves.easeInOutCubic);
    final markT = _interval(reveal, .42, 1, Curves.easeOutCubic);
    final opacity = _interval(reveal, .12, .3);
    final scale = .84 + .16 * _interval(reveal, .12, .8, Curves.easeOutBack);
    if (opacity <= 0) return;
    _layer(canvas, opacity, scale, () {
      final line = palette.line;
      final mark = _pen(palette.mark, 2);
      final warning = phase == BannerActivityPhase.warning;
      if (warning) {
        final triangle = Path()
          ..moveTo(14, 5)
          ..lineTo(24.75, 25.25)
          ..lineTo(3.25, 25.25)
          ..close();
        _partial(canvas, triangle, ringT, _pen(line));
      } else if (ringT >= 1) {
        canvas.drawCircle(_center, 10.25, _pen(line));
      } else if (ringT > 0) {
        canvas.drawArc(
          Rect.fromCircle(center: _center, radius: 10.25),
          -math.pi / 2,
          2 * math.pi * ringT,
          false,
          _pen(line),
        );
      }
      if (markT <= 0) return;
      void dot(Offset at) {
        final grow = _interval(markT, .55, 1, Curves.easeOutBack);
        if (grow > 0) {
          canvas.drawCircle(at, 1.25 * grow, _fill(palette.mark));
        }
      }

      switch (phase) {
        case BannerActivityPhase.succeeded:
          _partial(
            canvas,
            Path()
              ..moveTo(9.5, 16.25)
              ..lineTo(12.75, 19.5)
              ..lineTo(18.75, 12.75),
            markT,
            mark,
          );
        case BannerActivityPhase.cancelled:
          final a = _interval(markT, 0, .6);
          final b = _interval(markT, .4, 1);
          _partial(
              canvas,
              Path()
                ..moveTo(10.5, 12.5)
                ..lineTo(17.5, 19.5),
              a,
              mark);
          _partial(
              canvas,
              Path()
                ..moveTo(17.5, 12.5)
                ..lineTo(10.5, 19.5),
              b,
              mark);
        case BannerActivityPhase.info:
          dot(const Offset(14, 11.25));
          _partial(
              canvas,
              Path()
                ..moveTo(14, 14.75)
                ..lineTo(14, 20.75),
              markT,
              mark);
        case BannerActivityPhase.warning:
          _partial(
              canvas,
              Path()
                ..moveTo(14, 12.25)
                ..lineTo(14, 18.25),
              markT,
              mark);
          dot(const Offset(14, 21.75));
        case BannerActivityPhase.failed:
          _partial(
              canvas,
              Path()
                ..moveTo(14, 10.75)
                ..lineTo(14, 16.75),
              markT,
              mark);
          dot(const Offset(14, 20.5));
        case BannerActivityPhase.working:
        case BannerActivityPhase.paused:
        case BannerActivityPhase.stopping:
          break;
      }
    });
  }

  void _partial(Canvas canvas, Path path, double fraction, Paint paint) {
    if (fraction <= 0) return;
    if (fraction >= 1) {
      canvas.drawPath(path, paint);
      return;
    }
    final metrics = path.computeMetrics().toList();
    final total = metrics.fold<double>(0, (sum, m) => sum + m.length);
    var remaining = total * fraction;
    for (final metric in metrics) {
      if (remaining <= 0) break;
      canvas.drawPath(
          metric.extractPath(0, math.min(remaining, metric.length)), paint);
      remaining -= metric.length;
    }
  }

  @override
  bool shouldRepaint(covariant LivingGlyphPainter oldDelegate) =>
      oldDelegate.frame != frame ||
      oldDelegate.from != from ||
      oldDelegate.palette != palette ||
      oldDelegate.animate != animate ||
      oldDelegate.clock != clock;
}
