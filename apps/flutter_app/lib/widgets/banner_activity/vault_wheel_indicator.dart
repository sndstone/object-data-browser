import 'dart:math' as math;

import 'package:flutter/material.dart';

enum VaultWheelPhase { locked, unlocking, unlocked }

/// The wheel waits closed during verification and opens only after success.
class VaultWheelIndicator extends StatefulWidget {
  const VaultWheelIndicator({
    super.key,
    required this.phase,
    required this.animate,
    required this.foreground,
    required this.accent,
    required this.background,
  });

  final VaultWheelPhase phase;
  final bool animate;
  final Color foreground, accent, background;

  @override
  State<VaultWheelIndicator> createState() => _VaultWheelIndicatorState();
}

class _VaultWheelIndicatorState extends State<VaultWheelIndicator>
    with SingleTickerProviderStateMixin {
  late final _clock = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1050),
  );

  @override
  void initState() {
    super.initState();
    _configure();
  }

  @override
  void didUpdateWidget(VaultWheelIndicator oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.phase != widget.phase ||
        oldWidget.animate != widget.animate) {
      _configure();
    }
  }

  void _configure() {
    _clock.stop();
    switch (widget.phase) {
      case VaultWheelPhase.locked:
        _clock.value = 0;
      case VaultWheelPhase.unlocking:
        _clock.value = 0;
        if (widget.animate) _clock.repeat(reverse: true);
      case VaultWheelPhase.unlocked:
        if (widget.animate) {
          _clock.forward(from: 0);
        } else {
          _clock.value = 1;
        }
    }
  }

  @override
  void dispose() {
    _clock.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ExcludeSemantics(
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            RepaintBoundary(
              child: CustomPaint(
                size: const Size(28, 32),
                painter: VaultWheelPainter(
                  clock: _clock,
                  phase: widget.phase,
                  foreground: widget.foreground,
                  accent: widget.accent,
                  background: widget.background,
                ),
              ),
            ),
            const SizedBox(width: 6),
            SizedBox(
              width: 42,
              child: Text(
                switch (widget.phase) {
                  VaultWheelPhase.locked => 'LOCK',
                  VaultWheelPhase.unlocking => 'TURN',
                  VaultWheelPhase.unlocked => 'DONE',
                },
                style: Theme.of(context).textTheme.labelSmall?.copyWith(
                      color: widget.foreground,
                      fontWeight: FontWeight.w700,
                    ),
              ),
            ),
          ],
        ),
      );
}

class VaultWheelPainter extends CustomPainter {
  VaultWheelPainter({
    required this.clock,
    required this.phase,
    required this.foreground,
    required this.accent,
    required this.background,
  }) : super(repaint: clock);

  final Animation<double> clock;
  final VaultWheelPhase phase;
  final Color foreground, accent, background;

  static double _beat(double t, double start, double end) =>
      Curves.easeInOutCubic
          .transform(((t - start) / (end - start)).clamp(0, 1).toDouble());

  static Paint _pen(Color color, [double width = 1.5]) => Paint()
    ..color = color
    ..style = PaintingStyle.stroke
    ..strokeWidth = width
    ..strokeCap = StrokeCap.round
    ..strokeJoin = StrokeJoin.round;

  @override
  void paint(Canvas canvas, Size size) {
    final opening = phase == VaultWheelPhase.unlocked ? clock.value : 0.0;
    final shell =
        RRect.fromLTRBR(4.6, 5.4, 23.4, 26.6, const Radius.circular(3));
    canvas.drawRRect(shell, _pen(foreground));
    _paintCheck(canvas, opening);

    final fold = _beat(opening, .57, .94);
    if (fold == 1) return;
    final opacity = 1 - _beat(fold, .83, 1);
    final ink = foreground.withValues(alpha: opacity);
    final surface = background.withValues(alpha: opacity);
    final movingInk = accent.withValues(alpha: opacity);
    final turn = fold * math.pi / 2;
    final depth = math.sin(turn);
    final squash = math.cos(turn);
    final hinge = 5.7 - 1.1 * fold;
    final front = hinge + 16.6 * squash;
    final thickness = 1.6 * depth * (1 - fold);
    final width = front + thickness - hinge;
    final door = RRect.fromLTRBR(
      hinge,
      6.5,
      front + thickness,
      25.5,
      Radius.circular(math.min(2.1, width / 2)),
    );
    canvas.drawRRect(door, Paint()..color = surface);
    canvas.drawRRect(door, _pen(ink));
    if (thickness > .35) {
      canvas.drawLine(Offset(front, 7.8), Offset(front, 24.2), _pen(ink, 1.1));
    }
    for (final y in [10.2, 21.8]) {
      canvas.drawLine(
          Offset(4.6, y - 1.1), Offset(4.6, y + 1.1), _pen(ink, 2.2));
    }

    final boltAlpha = 1 - _beat(fold, 0, .55);
    for (final (y, pull) in [
      (11.7, _beat(opening, .33, .46)),
      (20.3, _beat(opening, .42, .55)),
    ]) {
      final end = 17.7 - 3.7 * pull;
      final color = pull > 0 && pull < 1 ? accent : foreground;
      canvas.drawLine(
        Offset(hinge + (end - 3) * squash, y),
        Offset(hinge + end * squash, y),
        _pen(color.withValues(alpha: opacity * boltAlpha), 1.55),
      );
    }
    final wheelAngle = phase == VaultWheelPhase.unlocking
        ? -.34 * Curves.easeInOutSine.transform(clock.value)
        : -.34 * _beat(opening, .03, .15) +
            3.24 * _beat(opening, .15, .45) -
            .28 * _beat(opening, .45, .57);
    final wheel = Offset(hinge + 8.3 * squash - 1.1 * depth * (1 - fold), 16);
    final rim =
        Rect.fromCenter(center: wheel, width: 8.5 * squash, height: 8.5);
    canvas.drawOval(rim, Paint()..color = surface);
    canvas.drawOval(rim, _pen(ink));
    final spins =
        (opening > .03 && opening < .57) || phase == VaultWheelPhase.unlocking;
    for (var spoke = 0; spoke < 3; spoke++) {
      final angle = -math.pi / 2 + spoke * 2 * math.pi / 3 + wheelAngle;
      canvas.drawLine(
        wheel,
        wheel + Offset(3.45 * squash * math.cos(angle), 3.45 * math.sin(angle)),
        _pen(spins ? movingInk : ink, 1.2),
      );
    }
  }

  void _paintCheck(Canvas canvas, double opening) {
    final reveal = _beat(opening, .74, .96);
    if (reveal == 0) return;
    final x = 14 + 2.7 * (1 - _beat(opening, .74, .94));
    final pop = 1 + .09 * math.sin(math.pi * _beat(opening, .86, 1));
    canvas.save();
    canvas.translate(x, 16);
    canvas.scale(pop);
    final path = Path()
      ..moveTo(-4.4, -.6)
      ..lineTo(-1.3, 2.6)
      ..lineTo(4.6, -3.6);
    final pen = _pen(accent, 1.85);
    if (reveal == 1) {
      canvas.drawPath(path, pen);
    } else {
      final segment = path.computeMetrics().first;
      canvas.drawPath(segment.extractPath(0, segment.length * reveal), pen);
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant VaultWheelPainter oldDelegate) =>
      phase != oldDelegate.phase ||
      clock != oldDelegate.clock ||
      foreground != oldDelegate.foreground ||
      accent != oldDelegate.accent ||
      background != oldDelegate.background;
}
