import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../theme/app_theme.dart';

/// Write, read and delete shares of a custom benchmark workload.
class OperationMix {
  const OperationMix(this.write, this.read, this.delete);
  final int write;
  final int read;
  final int delete;
}

/// One bar split into write, read and delete segments with two drag handles.
/// The three shares always sum to 100.
class OperationMixBar extends StatefulWidget {
  const OperationMixBar({
    super.key,
    required this.mix,
    required this.onChanged,
  });

  final OperationMix mix;
  final ValueChanged<OperationMix>? onChanged;

  static const presets = <(String, OperationMix)>[
    ('Balanced', OperationMix(33, 34, 33)),
    ('Read heavy', OperationMix(10, 85, 5)),
    ('Ingest', OperationMix(80, 15, 5)),
    ('Churn', OperationMix(45, 45, 10)),
  ];

  @override
  State<OperationMixBar> createState() => _OperationMixBarState();
}

class _OperationMixBarState extends State<OperationMixBar> {
  static const double _height = 34;
  static const double _handleWidth = 16;

  /// Boundary being dragged: 0 for write/read, 1 for read/delete.
  int? _dragging;

  OperationMix get mix => widget.mix;

  /// Moves the write/read boundary (0) or the read/delete boundary (1).
  OperationMix _moveBoundary(int handle, int position) {
    if (handle == 0) {
      final writeRead = mix.write + mix.read;
      final write = position.clamp(0, writeRead);
      return OperationMix(write, writeRead - write, mix.delete);
    }
    final boundary = position.clamp(mix.write, 100);
    return OperationMix(mix.write, boundary - mix.write, 100 - boundary);
  }

  OperationMix _step(int handle, int delta) => _moveBoundary(
        handle,
        (handle == 0 ? mix.write : mix.write + mix.read) + delta,
      );

  static String _describe(int handle, OperationMix m) => handle == 0
      ? 'Write ${m.write}%, read ${m.read}%'
      : 'Read ${m.read}%, delete ${m.delete}%';

  void _emit(OperationMix next) {
    if (next.write != mix.write ||
        next.read != mix.read ||
        next.delete != mix.delete) {
      widget.onChanged?.call(next);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final colors = [
      scheme.primary,
      theme.extension<AppStatusTheme>()?.running ?? scheme.secondary,
      scheme.error,
    ];
    final onColors = [
      scheme.onPrimary,
      scheme.brightness == Brightness.dark
          ? const Color(0xFF0D2340)
          : Colors.white,
      scheme.onError,
    ];
    const names = ['Write', 'Read', 'Delete'];
    const longNames = ['Write (PUT)', 'Read (GET)', 'Delete'];
    final values = [mix.write, mix.read, mix.delete];
    final enabled = widget.onChanged != null;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        LayoutBuilder(
          builder: (context, constraints) {
            final width = constraints.maxWidth;
            int percentAt(double dx) => (dx / width * 100).round();
            return GestureDetector(
              behavior: HitTestBehavior.opaque,
              onHorizontalDragStart: enabled
                  ? (details) {
                      final x = details.localPosition.dx;
                      final b0 = width * mix.write / 100;
                      final b1 = width * (mix.write + mix.read) / 100;
                      // Prefer the boundary under the pointer; when both sit
                      // together, pick the one that can move that way.
                      _dragging = (x - b0).abs() < (x - b1).abs()
                          ? 0
                          : (x - b0).abs() > (x - b1).abs()
                              ? 1
                              : (x < b0 ? 0 : 1);
                    }
                  : null,
              onHorizontalDragUpdate: enabled
                  ? (details) {
                      final handle = _dragging;
                      if (handle == null) return;
                      _emit(
                        _moveBoundary(
                          handle,
                          percentAt(details.localPosition.dx),
                        ),
                      );
                    }
                  : null,
              onHorizontalDragEnd: (_) => _dragging = null,
              onHorizontalDragCancel: () => _dragging = null,
              child: SizedBox(
                height: _height,
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(9),
                  child: Stack(
                    children: [
                      Row(
                        children: [
                          for (var i = 0; i < 3; i++)
                            if (values[i] > 0)
                              Expanded(
                                flex: values[i],
                                child: Container(
                                  color: colors[i],
                                  alignment: Alignment.centerLeft,
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 10,
                                  ),
                                  child: Text(
                                    values[i] >= 16
                                        ? '${names[i]} ${values[i]}%'
                                        : values[i] >= 7
                                            ? '${values[i]}%'
                                            : '',
                                    maxLines: 1,
                                    overflow: TextOverflow.clip,
                                    softWrap: false,
                                    style:
                                        theme.textTheme.labelMedium?.copyWith(
                                      color: onColors[i],
                                      fontWeight: FontWeight.w800,
                                      fontFeatures: const [
                                        FontFeature.tabularFigures(),
                                      ],
                                    ),
                                  ),
                                ),
                              ),
                        ],
                      ),
                      for (var h = 0; h < 2; h++)
                        Positioned(
                          left: width *
                                  (h == 0 ? mix.write : mix.write + mix.read) /
                                  100 -
                              _handleWidth / 2,
                          top: 0,
                          bottom: 0,
                          width: _handleWidth,
                          child: _MixHandle(
                            label: h == 0
                                ? 'Write and read split'
                                : 'Read and delete split',
                            value: _describe(h, mix),
                            increasedValue: _describe(h, _step(h, 1)),
                            decreasedValue: _describe(h, _step(h, -1)),
                            enabled: enabled,
                            onStep: (delta) => _emit(_step(h, delta)),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            );
          },
        ),
        const SizedBox(height: 10),
        Wrap(
          spacing: 16,
          runSpacing: 6,
          children: [
            for (var i = 0; i < 3; i++)
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    width: 10,
                    height: 10,
                    decoration: BoxDecoration(
                      color: colors[i],
                      borderRadius: BorderRadius.circular(3),
                    ),
                  ),
                  const SizedBox(width: 6),
                  Text(longNames[i], style: theme.textTheme.bodySmall),
                  const SizedBox(width: 4),
                  Text(
                    '${values[i]}%',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: scheme.onSurface,
                      fontWeight: FontWeight.w800,
                      fontFeatures: const [FontFeature.tabularFigures()],
                    ),
                  ),
                ],
              ),
          ],
        ),
        const SizedBox(height: 12),
        Wrap(
          spacing: 6,
          runSpacing: 6,
          children: [
            for (final (name, preset) in OperationMixBar.presets)
              OutlinedButton(
                onPressed: enabled ? () => _emit(preset) : null,
                style: OutlinedButton.styleFrom(
                  minimumSize: const Size(0, 30),
                  padding: const EdgeInsets.symmetric(horizontal: 10),
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  visualDensity: VisualDensity.compact,
                ),
                child: Text(name),
              ),
          ],
        ),
      ],
    );
  }
}

class _MixHandle extends StatefulWidget {
  const _MixHandle({
    required this.label,
    required this.value,
    required this.increasedValue,
    required this.decreasedValue,
    required this.enabled,
    required this.onStep,
  });

  final String label;
  final String value;
  final String increasedValue;
  final String decreasedValue;
  final bool enabled;
  final ValueChanged<int> onStep;

  @override
  State<_MixHandle> createState() => _MixHandleState();
}

class _MixHandleState extends State<_MixHandle> {
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Semantics(
      slider: true,
      label: widget.label,
      value: widget.value,
      increasedValue: widget.increasedValue,
      decreasedValue: widget.decreasedValue,
      onIncrease: widget.enabled ? () => widget.onStep(1) : null,
      onDecrease: widget.enabled ? () => widget.onStep(-1) : null,
      child: FocusableActionDetector(
        enabled: widget.enabled,
        mouseCursor: widget.enabled
            ? SystemMouseCursors.resizeLeftRight
            : SystemMouseCursors.basic,
        onShowFocusHighlight: (value) => setState(() => _focused = value),
        shortcuts: const {
          SingleActivator(LogicalKeyboardKey.arrowRight): _NudgeIntent(1),
          SingleActivator(LogicalKeyboardKey.arrowUp): _NudgeIntent(1),
          SingleActivator(LogicalKeyboardKey.arrowLeft): _NudgeIntent(-1),
          SingleActivator(LogicalKeyboardKey.arrowDown): _NudgeIntent(-1),
          SingleActivator(LogicalKeyboardKey.arrowRight, shift: true):
              _NudgeIntent(5),
          SingleActivator(LogicalKeyboardKey.arrowLeft, shift: true):
              _NudgeIntent(-5),
        },
        actions: {
          _NudgeIntent: CallbackAction<_NudgeIntent>(
            onInvoke: (intent) {
              widget.onStep(intent.delta);
              return null;
            },
          ),
        },
        child: Center(
          child: Container(
            width: 4,
            height: 20,
            decoration: BoxDecoration(
              color: scheme.surface,
              borderRadius: BorderRadius.circular(2),
              boxShadow: [
                BoxShadow(
                  color: _focused
                      ? scheme.primary
                      : Colors.black.withValues(alpha: 0.18),
                  spreadRadius: _focused ? 2 : 1,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _NudgeIntent extends Intent {
  const _NudgeIntent(this.delta);
  final int delta;
}
