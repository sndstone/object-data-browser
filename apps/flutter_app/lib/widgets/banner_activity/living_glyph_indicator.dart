import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'banner_activity_spec.dart';
import 'living_glyph_painter.dart';

const _glyphWidth = 28.0;
const _height = 32.0;
const _labelGap = 6.0;
const _labelWidth = 42.0;
const _morphDuration = Duration(milliseconds: 440);

/// Leading banner indicator: one living glyph per [BannerActivityKind].
class LivingGlyphIndicator extends StatefulWidget {
  const LivingGlyphIndicator({super.key, required this.spec});

  final BannerActivitySpec spec;

  @override
  State<LivingGlyphIndicator> createState() => _LivingGlyphState();
}

class _LivingGlyphState extends State<LivingGlyphIndicator>
    with SingleTickerProviderStateMixin {
  /// Drives the working loop, and runs once 0 → 1 for a result morph.
  late final AnimationController _clock = AnimationController(vsync: this);

  /// What was on screen when a result arrived; null when not morphing.
  GlyphFrame? _from;

  @override
  void initState() {
    super.initState();
    _configure(null);
  }

  @override
  void didUpdateWidget(LivingGlyphIndicator oldWidget) {
    super.didUpdateWidget(oldWidget);
    final old = oldWidget.spec;
    final spec = widget.spec;
    if (old.phase != spec.phase ||
        old.kind != spec.kind ||
        old.animate != spec.animate) {
      _configure(old);
    }
  }

  void _configure(BannerActivitySpec? old) {
    final spec = widget.spec;
    final departing = old == null
        ? null
        : GlyphFrame(
            kind: old.kind,
            phase: old.phase,
            t: _from == null ? _clock.value : 1,
            progress: (old.progress ?? 0).clamp(0.0, 1.0),
          );
    _clock.stop();
    _from = null;
    if (isResult(spec.phase)) {
      if (spec.animate && departing != null && old!.animate) {
        _from = departing;
        _clock
          ..duration = _morphDuration
          ..forward(from: 0);
      } else {
        _clock.value = 1;
      }
      return;
    }
    if (spec.animate && spec.phase != BannerActivityPhase.paused) {
      final stopping = spec.phase == BannerActivityPhase.stopping;
      final base = loopPeriod(spec.kind);
      _clock.duration = stopping ? base * 1.6 : base;
      _clock.repeat(
        reverse: stopping && spec.kind == BannerActivityKind.benchmark,
      );
    } else {
      _clock.value = restFrame(spec.kind);
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
    final label = _labelFor(spec);
    final glyph = RepaintBoundary(
      child: TweenAnimationBuilder<double>(
        tween: Tween<double>(end: (spec.progress ?? 0).clamp(0.0, 1.0)),
        duration:
            spec.animate ? const Duration(milliseconds: 320) : Duration.zero,
        curve: Curves.easeOutCubic,
        builder: (context, progress, _) => CustomPaint(
          size: const Size(_glyphWidth, _height),
          painter: LivingGlyphPainter(
            clock: _clock,
            frame: GlyphFrame(
              kind: spec.kind,
              phase: spec.phase,
              t: 0,
              progress: progress,
            ),
            from: _from,
            palette: palette,
            animate: spec.animate,
          ),
        ),
      ),
    );
    return Semantics(
      label: semanticsLabel(spec),
      child: ExcludeSemantics(
        child: SizedBox(
          width: label == null
              ? _glyphWidth
              : _glyphWidth + _labelGap + _labelWidth,
          height: _height,
          child: Row(
            children: [
              glyph,
              if (label != null) ...[
                const SizedBox(width: _labelGap),
                Expanded(child: label),
              ],
            ],
          ),
        ),
      ),
    );
  }

  /// Running count for listings, percent for benchmarks; null otherwise.
  Widget? _labelFor(BannerActivitySpec spec) {
    final style = DefaultTextStyle.of(context).style.copyWith(
      color: spec.foreground,
      fontSize: 14,
      fontWeight: FontWeight.w600,
      letterSpacing: 0,
      fontFeatures: const [FontFeature.tabularFigures()],
    );
    Widget text(String value) => Align(
          alignment: Alignment.centerLeft,
          child: Text(
            value,
            maxLines: 1,
            softWrap: false,
            overflow: TextOverflow.clip,
            textScaler: TextScaler.noScaling,
            style: style,
          ),
        );
    switch (spec.kind) {
      case BannerActivityKind.listing when spec.count != null:
        return text(abbreviateCount(spec.count!));
      case BannerActivityKind.benchmark when spec.progress != null:
        return TweenAnimationBuilder<double>(
          tween: Tween<double>(end: spec.progress!.clamp(0.0, 1.0)),
          duration:
              spec.animate ? const Duration(milliseconds: 320) : Duration.zero,
          curve: Curves.easeOutCubic,
          builder: (context, value, _) => text('${(value * 100).round()}%'),
        );
      default:
        return null;
    }
  }
}

/// 3.2k style: at most four characters so the label width stays stable.
String abbreviateCount(int count) {
  final n = math.max(0, count);
  String scaled(double value, String suffix) {
    if (value < 10) {
      final fixed = value.toStringAsFixed(1);
      return '${fixed.endsWith('.0') ? fixed.substring(0, fixed.length - 2) : fixed}$suffix';
    }
    return '${value.floor()}$suffix';
  }

  if (n < 1000) return '$n';
  if (n < 999950) return scaled((n / 100).floor() / 10, 'k');
  if (n < 999950000) return scaled((n / 100000).floor() / 10, 'M');
  return scaled((n / 100000000).floor() / 10, 'B');
}

String _grouped(int value) {
  final digits = value.abs().toString();
  final buffer = StringBuffer(value < 0 ? '-' : '');
  for (var i = 0; i < digits.length; i++) {
    if (i > 0 && (digits.length - i) % 3 == 0) buffer.write(',');
    buffer.write(digits[i]);
  }
  return buffer.toString();
}

String semanticsLabel(BannerActivitySpec spec) {
  final count = spec.count;
  final percent = spec.progress == null ? null : (spec.progress! * 100).round();
  final percentSuffix = percent == null ? '' : ', $percent percent';
  String objects(int n) => '${_grouped(n)} ${n == 1 ? 'object' : 'objects'}';
  final noun = switch (spec.kind) {
    BannerActivityKind.listing => 'Listing',
    BannerActivityKind.deleting => 'Delete',
    BannerActivityKind.benchmark => 'Benchmark',
    BannerActivityKind.action => 'Action',
    BannerActivityKind.exporting => 'Export',
    BannerActivityKind.message => 'Task',
  };
  final message = spec.kind == BannerActivityKind.message;
  return switch (spec.phase) {
    BannerActivityPhase.working => switch (spec.kind) {
        BannerActivityKind.listing =>
          count == null ? 'Listing' : 'Listing, ${objects(count)} loaded',
        BannerActivityKind.deleting =>
          count == null ? 'Deleting' : 'Deleting ${objects(count)}',
        BannerActivityKind.benchmark => 'Benchmark$percentSuffix',
        BannerActivityKind.exporting => 'Exporting',
        _ => 'Working',
      },
    BannerActivityPhase.paused => '$noun paused$percentSuffix',
    BannerActivityPhase.stopping =>
      'Stopping ${noun.toLowerCase()}$percentSuffix',
    BannerActivityPhase.succeeded => message
        ? 'Success'
        : switch (spec.kind) {
            BannerActivityKind.listing => count == null
                ? 'Listing complete'
                : 'Listing complete, ${objects(count)}',
            BannerActivityKind.deleting =>
              count == null ? 'Delete complete' : 'Deleted ${objects(count)}',
            _ => '$noun complete',
          },
    BannerActivityPhase.info => 'Information',
    BannerActivityPhase.warning => message ? 'Warning' : '$noun warning',
    BannerActivityPhase.failed => message ? 'Error' : '$noun failed',
    BannerActivityPhase.cancelled =>
      spec.kind == BannerActivityKind.listing && count != null
          ? 'Listing cancelled, ${objects(count)} loaded'
          : '$noun cancelled',
  };
}
