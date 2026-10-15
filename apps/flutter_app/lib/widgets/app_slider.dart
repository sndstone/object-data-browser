import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../theme/app_motion.dart';

/// A slim vertical bar thumb with a ring in the surface colour, used by the
/// app-wide slider theme and [AppRulerSlider].
class AppBarThumbShape extends SliderComponentShape {
  const AppBarThumbShape({this.width = 4, this.height = 20});

  final double width;
  final double height;

  @override
  Size getPreferredSize(bool isEnabled, bool isDiscrete) =>
      Size(width + 6, height);

  @override
  void paint(
    PaintingContext context,
    Offset center, {
    required Animation<double> activationAnimation,
    required Animation<double> enableAnimation,
    required bool isDiscrete,
    required TextPainter labelPainter,
    required RenderBox parentBox,
    required SliderThemeData sliderTheme,
    required TextDirection textDirection,
    required double value,
    required double textScaleFactor,
    required Size sizeWithOverflow,
  }) {
    final canvas = context.canvas;
    final grow = 2 * activationAnimation.value;
    final bar = RRect.fromRectAndRadius(
      Rect.fromCenter(center: center, width: width + grow, height: height),
      Radius.circular((width + grow) / 2),
    );
    final ringColor = sliderTheme.overlappingShapeStrokeColor;
    if (ringColor != null) {
      canvas.drawRRect(bar.inflate(3), Paint()..color = ringColor);
    }
    final color = ColorTween(
      begin: sliderTheme.disabledThumbColor,
      end: sliderTheme.thumbColor,
    ).evaluate(enableAnimation);
    canvas.drawRRect(bar, Paint()..color = color ?? sliderTheme.thumbColor!);
  }
}

/// Builds the shared slider theme: a 4 px track that spans the full width of
/// the slider, a bar thumb, and no division dots.
SliderThemeData appSliderTheme(ColorScheme scheme) {
  return SliderThemeData(
    trackHeight: 4,
    activeTrackColor: scheme.primary,
    inactiveTrackColor: scheme.outlineVariant,
    disabledActiveTrackColor: scheme.onSurface.withValues(alpha: 0.38),
    disabledInactiveTrackColor: scheme.onSurface.withValues(alpha: 0.12),
    thumbColor: scheme.primary,
    disabledThumbColor: scheme.onSurface.withValues(alpha: 0.38),
    overlappingShapeStrokeColor: scheme.surface,
    overlayColor: scheme.primary.withValues(alpha: 0.12),
    thumbShape: const AppBarThumbShape(),
    overlayShape: const RoundSliderOverlayShape(overlayRadius: 14),
    tickMarkShape: SliderTickMarkShape.noTickMark,
    trackShape: const RoundedRectSliderTrackShape(),
    padding: EdgeInsets.zero,
    showValueIndicator: ShowValueIndicator.never,
  );
}

/// A slider with a ruler beneath the track: one tick per step, with labels
/// at the minimum, the default and the maximum.
class AppRulerSlider extends StatelessWidget {
  const AppRulerSlider({
    super.key,
    required this.value,
    required this.min,
    required this.max,
    required this.step,
    required this.onChanged,
    this.defaultValue,
    this.formatLabel,
    this.semanticLabel,
  });

  final double value;
  final double min;
  final double max;
  final double step;
  final double? defaultValue;
  final ValueChanged<double>? onChanged;
  final String Function(double value)? formatLabel;
  final String? semanticLabel;

  int get _divisions => math.max(1, ((max - min) / step).round());

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final format = formatLabel ?? (v) => v.round().toString();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SizedBox(
          height: 24,
          child: Semantics(
            label: semanticLabel,
            child: SliderTheme(
              data: appSliderTheme(theme.colorScheme),
              child: Slider(
                value: value.clamp(min, max),
                min: min,
                max: max,
                divisions: _divisions,
                semanticFormatterCallback: (v) => format(v),
                onChanged: onChanged,
              ),
            ),
          ),
        ),
        const SizedBox(height: 4),
        SizedBox(
          // Tick marks (8px) + gap + one line of 12px labels.
          height: 26,
          child: CustomPaint(
            painter: _RulerPainter(
              min: min,
              max: max,
              divisions: _divisions,
              value: value,
              defaultValue: defaultValue,
              format: format,
              tick: theme.colorScheme.outline,
              major: theme.colorScheme.onSurfaceVariant,
              active: theme.colorScheme.primary,
              textStyle: theme.textTheme.labelSmall!.copyWith(
                fontSize: 12,
                height: 1.2,
                fontWeight: FontWeight.w600,
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _RulerPainter extends CustomPainter {
  _RulerPainter({
    required this.min,
    required this.max,
    required this.divisions,
    required this.value,
    required this.defaultValue,
    required this.format,
    required this.tick,
    required this.major,
    required this.active,
    required this.textStyle,
  });

  final double min, max, value;
  final double? defaultValue;
  final int divisions;
  final String Function(double) format;
  final Color tick, major, active;
  final TextStyle textStyle;

  @override
  void paint(Canvas canvas, Size size) {
    final step = (max - min) / divisions;
    for (var i = 0; i <= divisions; i++) {
      final v = min + i * step;
      final x = size.width * i / divisions;
      final isMajor =
          i == 0 ||
          i == divisions ||
          (defaultValue != null && (v - defaultValue!).abs() < step / 2);
      final paint = Paint()
        ..strokeWidth = 1
        ..color = v <= value + step / 2 ? active : (isMajor ? major : tick);
      canvas.drawLine(Offset(x, 0), Offset(x, isMajor ? 8 : 5), paint);
      if (isMajor) {
        final painter = TextPainter(
          text: TextSpan(
            text: format(v),
            style: textStyle.copyWith(color: major),
          ),
          textDirection: TextDirection.ltr,
        )..layout();
        final dx = i == 0
            ? 0.0
            : i == divisions
            ? x - painter.width
            : x - painter.width / 2;
        painter.paint(canvas, Offset(dx, 10));
      }
    }
  }

  @override
  bool shouldRepaint(_RulerPainter old) =>
      old.value != value ||
      old.min != min ||
      old.max != max ||
      old.divisions != divisions ||
      old.defaultValue != defaultValue ||
      old.active != active ||
      old.tick != tick;
}

/// A stepped value picker where every allowed value is a block. The current
/// value is solid, values below it are tinted, and the default block carries
/// a small underline.
class AppStepBlocks extends StatefulWidget {
  const AppStepBlocks({
    super.key,
    required this.value,
    required this.min,
    required this.max,
    required this.step,
    required this.onChanged,
    required this.semanticLabel,
    this.defaultValue,
    this.formatValue,
  });

  final int value;
  final int min;
  final int max;
  final int step;
  final int? defaultValue;
  final ValueChanged<int>? onChanged;
  final String semanticLabel;
  final String Function(int value)? formatValue;

  @override
  State<AppStepBlocks> createState() => _AppStepBlocksState();
}

class _AppStepBlocksState extends State<AppStepBlocks> {
  bool _focused = false;

  int get _count => ((widget.max - widget.min) ~/ widget.step) + 1;
  int get _index =>
      ((widget.value.clamp(widget.min, widget.max) - widget.min) / widget.step)
          .round();
  bool get _enabled => widget.onChanged != null;

  String _format(int v) => widget.formatValue?.call(v) ?? '$v';

  void _setIndex(int index) {
    final next = widget.min + index.clamp(0, _count - 1) * widget.step;
    if (next != widget.value) {
      widget.onChanged?.call(next);
    }
  }

  void _fromPosition(double dx, double width) {
    if (width <= 0) return;
    _setIndex((dx / width * _count).floor());
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final duration = AppMotion.duration(context, milliseconds: 110);
    final current = _index;
    final defaultIndex = widget.defaultValue == null
        ? -1
        : ((widget.defaultValue! - widget.min) / widget.step).round();

    final blocks = LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth;
        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTapDown: _enabled
              ? (d) => _fromPosition(d.localPosition.dx, width)
              : null,
          onHorizontalDragStart: _enabled
              ? (d) => _fromPosition(d.localPosition.dx, width)
              : null,
          onHorizontalDragUpdate: _enabled
              ? (d) => _fromPosition(d.localPosition.dx, width)
              : null,
          child: SizedBox(
            height: 24,
            child: Row(
              children: [
                for (var i = 0; i < _count; i++) ...[
                  if (i > 0) const SizedBox(width: 3),
                  Expanded(
                    child: AnimatedContainer(
                      duration: duration,
                      decoration: BoxDecoration(
                        color: i == current
                            ? scheme.primary
                            : i < current
                            ? Color.lerp(
                                scheme.primaryContainer,
                                scheme.primary,
                                0.7,
                              )
                            : scheme.outlineVariant,
                        borderRadius: BorderRadius.horizontal(
                          left: Radius.circular(i == 0 ? 6 : 3),
                          right: Radius.circular(i == _count - 1 ? 6 : 3),
                        ),
                      ),
                      foregroundDecoration: i == defaultIndex
                          ? BoxDecoration(
                              border: Border(
                                bottom: BorderSide(
                                  width: 3,
                                  color: i <= current
                                      ? scheme.onPrimary.withValues(alpha: 0.6)
                                      : scheme.outline,
                                ),
                              ),
                            )
                          : null,
                    ),
                  ),
                ],
              ],
            ),
          ),
        );
      },
    );

    Widget result = Opacity(opacity: _enabled ? 1 : 0.42, child: blocks);
    if (_focused) {
      result = DecoratedBox(
        position: DecorationPosition.foreground,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
            color: scheme.primary.withValues(alpha: 0.7),
            width: 2,
            strokeAlign: BorderSide.strokeAlignOutside,
          ),
        ),
        child: result,
      );
    }

    return Semantics(
      slider: true,
      enabled: _enabled,
      label: widget.semanticLabel,
      value: _format(widget.value),
      increasedValue: current < _count - 1
          ? _format(widget.min + (current + 1) * widget.step)
          : null,
      decreasedValue: current > 0
          ? _format(widget.min + (current - 1) * widget.step)
          : null,
      onIncrease: _enabled && current < _count - 1
          ? () => _setIndex(current + 1)
          : null,
      onDecrease: _enabled && current > 0 ? () => _setIndex(current - 1) : null,
      child: FocusableActionDetector(
        enabled: _enabled,
        mouseCursor: _enabled
            ? SystemMouseCursors.click
            : SystemMouseCursors.basic,
        onShowFocusHighlight: (value) => setState(() => _focused = value),
        shortcuts: const {
          SingleActivator(LogicalKeyboardKey.arrowRight): _StepIntent(1),
          SingleActivator(LogicalKeyboardKey.arrowUp): _StepIntent(1),
          SingleActivator(LogicalKeyboardKey.arrowLeft): _StepIntent(-1),
          SingleActivator(LogicalKeyboardKey.arrowDown): _StepIntent(-1),
          SingleActivator(LogicalKeyboardKey.pageUp): _StepIntent(4),
          SingleActivator(LogicalKeyboardKey.pageDown): _StepIntent(-4),
          SingleActivator(LogicalKeyboardKey.home): _StepIntent.first(),
          SingleActivator(LogicalKeyboardKey.end): _StepIntent.last(),
        },
        actions: {
          _StepIntent: CallbackAction<_StepIntent>(
            onInvoke: (intent) {
              _setIndex(switch (intent.absolute) {
                -1 => 0,
                1 => _count - 1,
                _ => current + intent.delta,
              });
              return null;
            },
          ),
        },
        child: ExcludeSemantics(child: result),
      ),
    );
  }
}

class _StepIntent extends Intent {
  const _StepIntent(this.delta) : absolute = 0;
  const _StepIntent.first() : delta = 0, absolute = -1;
  const _StepIntent.last() : delta = 0, absolute = 1;
  final int delta;
  final int absolute;
}

enum AppSliderStyle { ruler, stepBlocks }

/// A labelled setting slider: title, optional description, a Reset link when
/// the value differs from its default, a fixed-width value chip, and the
/// control itself.
class AppSettingSlider extends StatelessWidget {
  const AppSettingSlider({
    super.key,
    required this.title,
    required this.value,
    required this.min,
    required this.max,
    required this.step,
    required this.unit,
    required this.onChanged,
    this.subtitle,
    this.defaultValue,
    this.style = AppSliderStyle.ruler,
  });

  final String title;
  final String? subtitle;
  final int value;
  final int min;
  final int max;
  final int step;
  final int? defaultValue;

  /// Appended to values: `%` attaches directly, other units after a space.
  final String unit;
  final ValueChanged<int>? onChanged;
  final AppSliderStyle style;

  String format(int v) => unit == '%' ? '$v%' : '$v $unit';

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final clamped = value.clamp(min, max);
    final canReset =
        defaultValue != null && clamped != defaultValue && onChanged != null;
    final chip = Container(
      constraints: const BoxConstraints(minWidth: 58),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: scheme.primaryContainer,
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        format(clamped),
        textAlign: TextAlign.center,
        style: theme.textTheme.labelMedium?.copyWith(
          color: scheme.onPrimaryContainer,
          fontWeight: FontWeight.w800,
          fontFeatures: const [FontFeature.tabularFigures()],
        ),
      ),
    );
    final control = switch (style) {
      AppSliderStyle.stepBlocks => AppStepBlocks(
        value: clamped,
        min: min,
        max: max,
        step: step,
        defaultValue: defaultValue,
        onChanged: onChanged,
        semanticLabel: title,
        formatValue: format,
      ),
      AppSliderStyle.ruler => AppRulerSlider(
        value: clamped.toDouble(),
        min: min.toDouble(),
        max: max.toDouble(),
        step: step.toDouble(),
        defaultValue: defaultValue?.toDouble(),
        semanticLabel: title,
        formatLabel: (v) => format(v.round()),
        onChanged: onChanged == null
            ? null
            : (v) => onChanged!(min + ((v - min) / step).round() * step),
      ),
    };
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(title, style: theme.textTheme.bodyLarge),
                    if (subtitle != null) ...[
                      const SizedBox(height: 2),
                      Text(
                        subtitle!,
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              const SizedBox(width: 12),
              Visibility(
                visible: canReset,
                maintainSize: true,
                maintainAnimation: true,
                maintainState: true,
                child: TextButton(
                  onPressed: canReset ? () => onChanged!(defaultValue!) : null,
                  style: TextButton.styleFrom(
                    minimumSize: const Size(0, 28),
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                  child: Text(
                    'Reset',
                    semanticsLabel:
                        'Reset $title to ${format(defaultValue ?? min)}',
                  ),
                ),
              ),
              const SizedBox(width: 4),
              chip,
            ],
          ),
          const SizedBox(height: 12),
          control,
          if (style == AppSliderStyle.stepBlocks) ...[
            const SizedBox(height: 6),
            DefaultTextStyle.merge(
              style: theme.textTheme.labelSmall?.copyWith(
                fontWeight: FontWeight.w600,
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [Text(format(min)), Text(format(max))],
              ),
            ),
          ],
        ],
      ),
    );
  }
}
