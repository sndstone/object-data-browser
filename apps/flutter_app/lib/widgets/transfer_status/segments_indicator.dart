import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'transfer_status_spec.dart';

const _blockCount = 6;
const _blockWidth = 6.0;
const _blockGap = 2.0;
const _blockHeight = 16.0;
const _blockRadius = 2.0;
const _rowWidth = _blockCount * _blockWidth + (_blockCount - 1) * _blockGap;
const _rowHeight = 22.0;
const _height = 28.0;
const _glyphSlot = 18.0;
const _glyphGap = 6.0;
const _percentGap = 5.0;
const _switchDuration = Duration(milliseconds: 200);
const _progressDuration = Duration(milliseconds: 360);

/// Preparing and transferring share one loop so the hand-off is continuous.
const _flowLoop = Duration(milliseconds: 1300);

/// Preparing → transferring: the ripple settles into the resting parts.
const _handoffDuration = Duration(milliseconds: 460);

/// Leading banner indicator drawn as a row of multipart "parts".
class SegmentsIndicator extends StatefulWidget {
  const SegmentsIndicator({super.key, required this.spec});

  final TransferStatusSpec spec;

  @override
  State<SegmentsIndicator> createState() => _SegmentsIndicatorState();
}

class _SegmentsIndicatorState extends State<SegmentsIndicator>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(vsync: this)
    ..addListener(_trackHandoff);

  /// Progress of the preparing → transferring hand-off, advanced by the
  /// shared loop controller rather than a second ticker.
  final _handoff = _Handoff();
  double _lastValue = 0;

  @override
  void initState() {
    super.initState();
    _syncController(entering: true);
  }

  @override
  void didUpdateWidget(SegmentsIndicator oldWidget) {
    super.didUpdateWidget(oldWidget);
    final old = oldWidget.spec;
    final spec = widget.spec;
    if (old.phase != spec.phase || old.animate != spec.animate) {
      if (spec.animate &&
          old.animate &&
          old.phase == TransferStatusPhase.preparing &&
          spec.phase == TransferStatusPhase.transferring) {
        _handoff.start();
        _lastValue = _controller.value;
      } else {
        _handoff.finish();
      }
      _syncController(entering: true);
    }
  }

  void _trackHandoff() {
    final value = _controller.value;
    if (_handoff.running) {
      var delta = value - _lastValue;
      if (delta < 0) delta += 1;
      _handoff.advance(delta * _flowLoop.inMicroseconds);
    }
    _lastValue = value;
  }

  /// One controller drives everything: it loops for working phases and runs
  /// once as an entrance for terminal phases. It is idle otherwise.
  void _syncController({required bool entering}) {
    final spec = widget.spec;
    if (!spec.animate) {
      _controller
        ..stop()
        ..value = 1;
      return;
    }
    final loop = switch (spec.phase) {
      TransferStatusPhase.preparing ||
      TransferStatusPhase.transferring =>
        _flowLoop,
      TransferStatusPhase.cancelling => const Duration(milliseconds: 1700),
      _ => null,
    };
    if (loop != null) {
      // repeat() continues from the current value, so the shared flow loop
      // carries straight through the preparing → transferring hand-off.
      if (!_controller.isAnimating || _controller.duration != loop) {
        _controller
          ..duration = loop
          ..repeat();
      }
      return;
    }
    switch (spec.phase) {
      case TransferStatusPhase.completed ||
            TransferStatusPhase.failed ||
            TransferStatusPhase.cancelled:
        _controller.duration = const Duration(milliseconds: 720);
        if (entering) _controller.forward(from: 0);
      default:
        _controller
          ..stop()
          ..value = 1;
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final spec = widget.spec;
    final theme = Theme.of(context);
    final colors = _SegmentColors.resolve(theme.colorScheme, spec);
    final switchDuration = spec.animate ? _switchDuration : Duration.zero;
    final flowing = spec.phase == TransferStatusPhase.preparing ||
        spec.phase == TransferStatusPhase.transferring;

    final baseStyle = DefaultTextStyle.of(context).style;
    final percentStyle = baseStyle.copyWith(
      color: colors.text,
      fontSize: 12.5,
      fontWeight: FontWeight.w600,
      height: 1,
      letterSpacing: 0,
      fontFeatures: const [FontFeature.tabularFigures()],
    );
    final textScaler = MediaQuery.textScalerOf(context);
    final measure = TextPainter(
      text: TextSpan(text: '100%', style: percentStyle),
      textDirection: TextDirection.ltr,
      textScaler: textScaler,
      maxLines: 1,
    )..layout();
    final percentWidth = measure.width.ceilToDouble();
    measure.dispose();

    final showPercent = spec.phase != TransferStatusPhase.preparing &&
        spec.phase != TransferStatusPhase.completed &&
        spec.percent != null;

    final glyph = AnimatedSwitcher(
      duration: switchDuration,
      switchInCurve: Curves.easeOutBack,
      switchOutCurve: Curves.easeIn,
      transitionBuilder: (child, animation) => FadeTransition(
        opacity: animation,
        child: ScaleTransition(
          scale: Tween(begin: 0.6, end: 1.0).animate(animation),
          child: child,
        ),
      ),
      child: Icon(
        _glyphFor(spec),
        key: ValueKey(_glyphFor(spec)),
        size: 16,
        color: colors.glyph,
      ),
    );

    // Preparing and transferring share one painter (no cross-fade); the
    // hand-off is blended inside it. Completion also paints in place: its
    // sweep starts from the full row, so a cross-fade would only ghost the
    // old banner colours. Other phase changes cross-fade.
    final inPlace = flowing || spec.phase == TransferStatusPhase.completed;
    Widget row(double progress) => AnimatedSwitcher(
          duration: switchDuration,
          layoutBuilder: (current, previous) => Stack(
            alignment: Alignment.center,
            children: [...previous, if (current != null) current],
          ),
          child: CustomPaint(
            key: ValueKey((inPlace ? null : spec.phase, spec.animate)),
            size: const Size(_rowWidth, _rowHeight),
            painter: _SegmentPainter(
              animation: _controller,
              handoff: _handoff,
              phase: spec.phase,
              direction: spec.direction,
              progress: progress,
              animate: spec.animate,
              colors: colors,
            ),
          ),
        );

    // The slot opens in step with the hand-off and the number counts up
    // with the eased progress, so nothing pops in.
    Widget percent(double progress) => TweenAnimationBuilder<double>(
          tween: Tween(end: showPercent ? 1 : 0),
          duration: spec.animate
              ? (flowing ? _handoffDuration : _switchDuration)
              : Duration.zero,
          curve: Curves.easeInOutCubic,
          builder: (context, reveal, child) => SizedBox(
            width: (_percentGap + percentWidth) * reveal,
            child: ClipRect(
              child: OverflowBox(
                alignment: Alignment.centerRight,
                minWidth: _percentGap + percentWidth,
                maxWidth: _percentGap + percentWidth,
                child: Opacity(opacity: reveal * reveal, child: child),
              ),
            ),
          ),
          child: Text(
            '${(progress * 100).round()}%',
            textAlign: TextAlign.right,
            maxLines: 1,
            softWrap: false,
            style: percentStyle,
          ),
        );

    final body = TweenAnimationBuilder<double>(
      tween: Tween(end: (spec.progress ?? 0).clamp(0.0, 1.0)),
      duration: spec.animate ? _progressDuration : Duration.zero,
      curve: Curves.easeOutCubic,
      builder: (context, progress, _) => Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          RepaintBoundary(child: row(progress)),
          percent(progress),
        ],
      ),
    );

    return Semantics(
      container: true,
      label: _semanticLabel(spec),
      child: ExcludeSemantics(
        child: SizedBox(
          height: _height,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              SizedBox(
                width: _glyphSlot,
                height: _glyphSlot,
                child: Center(child: glyph),
              ),
              const SizedBox(width: _glyphGap),
              body,
            ],
          ),
        ),
      ),
    );
  }
}

IconData _glyphFor(TransferStatusSpec spec) {
  final upload = spec.direction == TransferStatusDirection.upload;
  final arrow = spec.copy
      ? Icons.copy_all_rounded
      : upload
          ? Icons.arrow_upward_rounded
          : Icons.arrow_downward_rounded;
  return switch (spec.phase) {
    TransferStatusPhase.preparing =>
      spec.animate ? arrow : Icons.hourglass_top_rounded,
    TransferStatusPhase.transferring => arrow,
    TransferStatusPhase.paused => Icons.pause_rounded,
    TransferStatusPhase.cancelling => Icons.stop_rounded,
    TransferStatusPhase.completed => Icons.check_circle_rounded,
    TransferStatusPhase.failed => Icons.error_rounded,
    TransferStatusPhase.cancelled => Icons.cancel_outlined,
  };
}

String _semanticLabel(TransferStatusSpec spec) {
  final upload = spec.direction == TransferStatusDirection.upload;
  if (spec.copy) {
    return switch (spec.phase) {
      TransferStatusPhase.completed => 'Bucket copy complete',
      TransferStatusPhase.failed => 'Bucket copy failed',
      TransferStatusPhase.cancelled => 'Bucket copy cancelled',
      _ => 'Copying bucket',
    };
  }
  final noun = upload ? 'upload' : 'download';
  final title = upload ? 'Upload' : 'Download';
  final percent = spec.percent;
  final at = percent == null ? '' : ' at $percent percent';
  return switch (spec.phase) {
    TransferStatusPhase.preparing => 'Preparing $noun',
    TransferStatusPhase.transferring =>
      '${upload ? 'Uploading' : 'Downloading'}, ${percent ?? 0} percent',
    TransferStatusPhase.paused => '$title paused$at',
    TransferStatusPhase.cancelling => 'Cancelling $noun',
    TransferStatusPhase.completed => '$title complete',
    TransferStatusPhase.failed => '$title failed$at',
    TransferStatusPhase.cancelled => '$title cancelled$at',
  };
}

double _contrast(Color a, Color b) {
  final la = a.computeLuminance();
  final lb = b.computeLuminance();
  return (math.max(la, lb) + 0.05) / (math.min(la, lb) + 0.05);
}

/// Hand-off state shared with the painter; advanced by the loop controller.
class _Handoff {
  double _elapsed = 0;
  bool _running = false;

  bool get running => _running;

  /// Eased 0 → 1 across the hand-off; 1 when idle.
  double get value => _running
      ? Curves.easeInOutCubic
          .transform(_elapsed / _handoffDuration.inMicroseconds)
      : 1;

  void start() {
    _elapsed = 0;
    _running = true;
  }

  void advance(double micros) {
    _elapsed += micros;
    if (_elapsed >= _handoffDuration.inMicroseconds) _running = false;
  }

  void finish() => _running = false;
}

@immutable
class _SegmentColors {
  const _SegmentColors({
    required this.accent,
    required this.done,
    required this.track,
    required this.dimTrack,
    required this.failure,
    required this.glyph,
    required this.text,
  });

  /// Filled parts and the scan highlight.
  final Color accent;

  /// Filled parts once the transfer is no longer making progress.
  final Color done;

  /// Pending parts.
  final Color track, dimTrack;

  /// The cracked part of a failed transfer.
  final Color failure;
  final Color glyph, text;

  static _SegmentColors resolve(ColorScheme scheme, TransferStatusSpec spec) {
    final fg = spec.foreground;
    final bg = spec.background;
    Color legible(Color candidate) =>
        _contrast(candidate, bg) >= 3 ? candidate : fg;

    final failed = spec.phase == TransferStatusPhase.failed;
    final accent = legible(switch (spec.phase) {
      TransferStatusPhase.completed => scheme.primary,
      TransferStatusPhase.failed => fg,
      _ => scheme.inversePrimary,
    });
    // On a failed banner the surviving parts step back so the cracked part
    // is the strongest mark. On light-on-dark banners the error tint is too
    // close to the text colour, so the crack uses the brighter text colour.
    final darkBanner = bg.computeLuminance() < fg.computeLuminance();
    final error = legible(scheme.error);
    return _SegmentColors(
      accent: accent,
      done: Color.alphaBlend(fg.withValues(alpha: failed ? 0.5 : 0.62), bg),
      track: Color.alphaBlend(fg.withValues(alpha: 0.24), bg),
      dimTrack: Color.alphaBlend(fg.withValues(alpha: 0.11), bg),
      failure: darkBanner && _contrast(fg, bg) > _contrast(error, bg) + 1
          ? fg
          : error,
      glyph: spec.phase == TransferStatusPhase.completed ? accent : fg,
      text: fg,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is _SegmentColors &&
      other.accent == accent &&
      other.done == done &&
      other.track == track &&
      other.dimTrack == dimTrack &&
      other.failure == failure &&
      other.glyph == glyph &&
      other.text == text;

  @override
  int get hashCode =>
      Object.hash(accent, done, track, dimTrack, failure, glyph, text);
}

class _SegmentPainter extends CustomPainter {
  _SegmentPainter({
    required this.animation,
    required this.handoff,
    required this.phase,
    required this.direction,
    required this.progress,
    required this.animate,
    required this.colors,
  }) : super(repaint: animation);

  final Animation<double> animation;
  final _Handoff handoff;
  final TransferStatusPhase phase;
  final TransferStatusDirection direction;
  final double progress;
  final bool animate;
  final _SegmentColors colors;

  static const _radius = Radius.circular(_blockRadius);

  bool get _upload => direction == TransferStatusDirection.upload;

  /// +1 when motion runs left → right (upload), -1 when mirrored (download).
  double get _flow => _upload ? 1 : -1;

  /// Upload parts lift; download parts drop.
  double get _lift => _upload ? -1 : 1;

  /// Maps a left → right travel position onto this direction's row.
  double _along(double position) =>
      _upload ? position : (_blockCount - 1) - position;

  Rect _block(Size size, int i, double height, {double dy = 0}) =>
      Rect.fromLTWH(
        i * (_blockWidth + _blockGap),
        (size.height - height) / 2 + dy,
        _blockWidth,
        height,
      );

  void _fill(Canvas canvas, Rect rect, Color color) => canvas.drawRRect(
        RRect.fromRectAndRadius(rect, _radius),
        Paint()..color = color,
      );

  /// A gaussian "ripple" centred on [centre] (in block units).
  static double _ripple(int i, double centre, [double width = 1.1]) {
    final d = i - centre;
    return math.exp(-(d * d) / width);
  }

  /// Ring length for looping ripples: a new ripple enters as one leaves.
  static const _loopLength = _blockCount + 1.5;

  /// Like [_ripple], but the distance wraps around [_loopLength] so a
  /// looping ripple never leaves the row empty.
  static double _loopRipple(int i, double centre, [double width = 1.1]) {
    final raw = (i - centre) % _loopLength;
    final d = math.min(raw, _loopLength - raw);
    return math.exp(-(d * d) / width);
  }

  @override
  void paint(Canvas canvas, Size size) {
    final t = animation.value;
    switch (phase) {
      case TransferStatusPhase.preparing:
        _paintFlow(canvas, size, t, blend: 0, pendingColor: colors.track);
      case TransferStatusPhase.transferring:
        _paintFlow(canvas, size, t,
            blend: animate ? handoff.value : 1, pendingColor: colors.track);
      case TransferStatusPhase.paused:
        _paintFlow(canvas, size, t, blend: 1, pendingColor: colors.dimTrack);
      case TransferStatusPhase.cancelling:
        _paintCancelling(canvas, size, animate ? t : null);
      case TransferStatusPhase.completed:
        _paintCompleted(canvas, size, t);
      case TransferStatusPhase.failed:
        _paintFailed(canvas, size, t);
      case TransferStatusPhase.cancelled:
        _paintCancelled(canvas, size, t);
    }
  }

  /// Preparing, transferring and paused in one geometry.
  ///
  /// At [blend] 0 parts are being lined up: a ripple travels along the row
  /// (left → right lifting for uploads, right → left dropping for
  /// downloads) and raises and lights each part in turn. At [blend] 1 the
  /// parts rest at full height and fill in order, the leading part filling
  /// in the transfer direction and gently pulsing. In between, heights,
  /// offsets and colours interpolate per part, so the last ripple pass
  /// settles into the resting row and the first partial fill emerges from
  /// it.
  void _paintFlow(
    Canvas canvas,
    Size size,
    double t, {
    required double blend,
    required Color pendingColor,
  }) {
    final moving = animate && phase != TransferStatusPhase.paused;
    final centre = _along(moving ? t * _loopLength : 1.6);
    final pulse = phase == TransferStatusPhase.transferring && animate
        ? blend * (0.5 - 0.5 * math.cos(2 * math.pi * t))
        : 0.0;
    final filled = progress * _blockCount;
    final lead = filled >= _blockCount ? -1 : filled.floor();
    // The hand-off lands on the leading part: it brightens and lifts once
    // as the ripple fades, then settles into the first partial fill.
    final landing = blend > 0 && blend < 1 ? math.sin(math.pi * blend) : 0.0;
    for (var i = 0; i < _blockCount; i++) {
      // Preparing geometry.
      final e = blend >= 1 ? 0.0 : _loopRipple(i, centre);
      final prepHeight = 8 + (_rowHeight - 8) * e;
      final prepDy = _lift * 1.5 * e;
      final prepColor = Color.lerp(colors.track, colors.accent, e)!;

      // Resting transfer geometry.
      final f = (filled - i).clamp(0.0, 1.0);
      final isLead = i == lead;
      final restHeight = _blockHeight + (isLead ? 1.5 * pulse : 0.0);
      final restColor = f >= 1
          ? colors.accent
          : isLead
              ? Color.lerp(pendingColor, colors.accent, 0.22 * pulse)!
              : pendingColor;

      final land = isLead ? landing : 0.0;
      final rect = _block(
        size,
        i,
        _lerp(prepHeight, restHeight, blend) + 3 * land,
        dy: _lerp(prepDy, 0, blend) + _lift * land,
      );
      final color = Color.lerp(prepColor, restColor, blend)!;
      _fill(canvas, rect, Color.lerp(color, colors.accent, 0.55 * land)!);
      if (f <= 0 || f >= 1 || blend <= 0) continue;

      final h = math.max(2.0, rect.height * f);
      final part = _upload
          ? Rect.fromLTRB(rect.left, rect.bottom - h, rect.right, rect.bottom)
          : Rect.fromLTRB(rect.left, rect.top, rect.right, rect.top + h);
      final alpha =
          (isLead && pulse > 0 ? 0.78 + 0.22 * pulse / blend : 1.0) * blend;
      canvas
        ..save()
        ..clipRRect(RRect.fromRectAndRadius(rect, _radius))
        ..drawRect(
          part,
          Paint()..color = colors.accent.withValues(alpha: alpha.clamp(0, 1)),
        )
        ..restore();
    }
  }

  static double _lerp(double a, double b, double t) => a + (b - a) * t;

  /// Winding down: completed parts are greyed and a slow ripple drains the
  /// row against the transfer direction (right → left for uploads).
  void _paintCancelling(Canvas canvas, Size size, double? t) {
    final filled = progress * _blockCount;
    final centre = _along(_loopLength * (1 - (t ?? 0.5)));
    for (var i = 0; i < _blockCount; i++) {
      final e = t == null ? 0.0 : _loopRipple(i, centre, 1.4);
      final f = (filled - i).clamp(0.0, 1.0);
      final base = f > 0.5 ? colors.done : colors.dimTrack;
      final height = _blockHeight - 6 * e;
      _fill(
        canvas,
        _block(size, i, height, dy: -_lift * 1.5 * e),
        Color.lerp(base, colors.dimTrack, 0.75 * e)!,
      );
    }
  }

  /// All parts fill, a highlight sweeps through in the transfer direction
  /// (lifting for uploads, dipping for downloads), and they fuse into one
  /// bar.
  void _paintCompleted(Canvas canvas, Size size, double t) {
    final sweep =
        _along(-1.8 + Curves.easeOut.transform(t) * (_blockCount + 3.6));
    final merge =
        Curves.easeInOutCubic.transform(((t - 0.4) / 0.6).clamp(0.0, 1.0));
    final gap = _blockGap * (1 - merge);
    final width = (_rowWidth - (_blockCount - 1) * gap) / _blockCount;
    final inner = Radius.circular(_blockRadius * (1 - merge));
    final paint = Paint()..color = colors.accent;
    for (var i = 0; i < _blockCount; i++) {
      final bump = t >= 1 ? 0.0 : 4 * _ripple(i, sweep) * (1 - merge);
      final height = _blockHeight - 6 * merge + bump;
      final rect = Rect.fromLTWH(
        i * (width + gap) - (merge > 0 && i > 0 ? 0.25 : 0),
        (size.height - height) / 2 + _lift * bump / 2,
        width + (merge > 0 && i > 0 ? 0.25 : 0),
        height,
      );
      final first = i == 0;
      final last = i == _blockCount - 1;
      canvas.drawRRect(
        RRect.fromRectAndCorners(
          rect,
          topLeft: first ? _radius : inner,
          bottomLeft: first ? _radius : inner,
          topRight: last ? _radius : inner,
          bottomRight: last ? _radius : inner,
        ),
        paint,
      );
    }
  }

  /// Parts before the failure step back, the failing part cracks apart and
  /// later parts fade back.
  void _paintFailed(Canvas canvas, Size size, double t) {
    final failing = math.min((progress * _blockCount).floor(), _blockCount - 1);
    final crack = Curves.easeOutBack.transform(t.clamp(0.0, 1.0));
    for (var i = 0; i < _blockCount; i++) {
      final rect = _block(size, i, _blockHeight);
      if (i < failing) {
        _fill(canvas, rect, colors.done);
      } else if (i > failing) {
        _fill(canvas, rect, colors.dimTrack);
      } else {
        _paintCrackedBlock(canvas, _block(size, i, _blockHeight + 2), crack);
      }
    }
  }

  void _paintCrackedBlock(Canvas canvas, Rect rect, double crack) {
    final rrect = RRect.fromRectAndRadius(rect, _radius);
    final paint = Paint()..color = colors.failure;
    final midY = rect.center.dy;
    // Diagonal fracture across the part.
    final upper = Path()
      ..moveTo(rect.left - 1, rect.top - 1)
      ..lineTo(rect.right + 1, rect.top - 1)
      ..lineTo(rect.right + 1, midY - 2.5)
      ..lineTo(rect.left - 1, midY + 2.5)
      ..close();
    final lower = Path()
      ..moveTo(rect.left - 1, midY + 2.5)
      ..lineTo(rect.right + 1, midY - 2.5)
      ..lineTo(rect.right + 1, rect.bottom + 1)
      ..lineTo(rect.left - 1, rect.bottom + 1)
      ..close();
    for (final (piece, sign) in [(upper, -1.0), (lower, 1.0)]) {
      canvas
        ..save()
        ..translate(0.8 * sign * crack, 2.2 * sign * crack)
        ..clipPath(piece)
        ..drawRRect(rrect, paint)
        ..restore();
    }
  }

  /// Parts fade back and a strike-through draws across the row in the
  /// transfer direction.
  void _paintCancelled(Canvas canvas, Size size, double t) {
    final filled = progress * _blockCount;
    for (var i = 0; i < _blockCount; i++) {
      final f = (filled - i).clamp(0.0, 1.0);
      _fill(canvas, _block(size, i, _blockHeight - 4),
          f > 0.5 ? colors.track : colors.dimTrack);
    }
    final reach =
        (size.width - 1) * Curves.easeOutCubic.transform(t.clamp(0.0, 1.0));
    final y = size.height / 2;
    final start = _upload ? 0.5 : size.width - 0.5;
    canvas.drawLine(
      Offset(start, y),
      Offset(start + _flow * reach, y),
      Paint()
        ..color = colors.done
        ..strokeWidth = 2
        ..strokeCap = StrokeCap.round,
    );
  }

  @override
  bool shouldRepaint(_SegmentPainter old) =>
      old.animation != animation ||
      old.handoff != handoff ||
      old.phase != phase ||
      old.direction != direction ||
      old.progress != progress ||
      old.animate != animate ||
      old.colors != colors;
}
