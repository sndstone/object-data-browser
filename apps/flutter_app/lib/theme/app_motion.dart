import 'package:flutter/material.dart';

/// Motion has a purpose: orientation on navigation, continuity on resize.
/// No spring overshoot on data tables or progress updates.
class AppMotion {
  static Duration duration(BuildContext context,
          {bool enabled = true, int milliseconds = 240}) =>
      !enabled ||
              MediaQuery.disableAnimationsOf(context) ||
              MediaQuery.accessibleNavigationOf(context)
          ? Duration.zero
          : Duration(milliseconds: milliseconds);
  static Widget transition(Widget child, Animation<double> animation) =>
      FadeTransition(
          opacity: animation,
          child: SlideTransition(
              position:
                  Tween<Offset>(begin: const Offset(.025, 0), end: Offset.zero)
                      .animate(CurvedAnimation(
                          parent: animation,
                          curve: Curves.easeOutCubic,
                          reverseCurve: Curves.easeInCubic)),
              child: child));
}

/// Fade between responsive layouts without laying out the outgoing wide
/// layout in a newly narrow viewport. Keep state across resizes within a mode.
class ResponsiveLayoutTransition extends StatelessWidget {
  const ResponsiveLayoutTransition({
    super.key,
    required this.layoutKey,
    required this.duration,
    required this.child,
    this.animateSize = false,
  });
  final Object layoutKey;
  final Duration duration;
  final Widget child;
  final bool animateSize;

  @override
  Widget build(BuildContext context) {
    final transition = AnimatedSwitcher(
      duration: duration,
      switchInCurve: Curves.easeOutCubic,
      transitionBuilder: (child, animation) => FadeTransition(
        opacity: Tween<double>(begin: .65, end: 1).animate(animation),
        child: child,
      ),
      layoutBuilder: (current, previous) => current ?? const SizedBox.shrink(),
      child: KeyedSubtree(key: ValueKey(layoutKey), child: child),
    );
    return animateSize
        ? MotionSize(
            duration: duration,
            alignment: Alignment.topCenter,
            curve: Curves.easeOutCubic,
            child: transition)
        : transition;
  }
}

/// Ordered destinations enter from the direction being navigated toward;
/// the old panel leaves through the opposite edge. Reversing navigation
/// reverses both motions, including when the previous animation is in flight.
class DirectionalSwitcher extends StatefulWidget {
  const DirectionalSwitcher(
      {super.key,
      required this.position,
      required this.duration,
      required this.child,
      this.axis = Axis.horizontal,
      this.fadeThrough = false,
      this.replaceContent = false,
      this.replacementBackground,
      this.layoutBuilder});
  final int position;
  final Duration duration;
  final Widget child;
  final Axis axis;
  final bool fadeThrough;

  /// Push equally sized, opaque panels through one clipped viewport.
  /// [axis] follows the navigation layout; position changes set the direction.
  final bool replaceContent;
  final Color? replacementBackground;
  final AnimatedSwitcherLayoutBuilder? layoutBuilder;
  @override
  State<DirectionalSwitcher> createState() => _DirectionalSwitcherState();
}

// Each panel owns a retargetable trajectory. Reusing an outgoing panel on a
// quick reversal preserves both its state and its exact visible position.
class _PanelMotion {
  _PanelMotion(this.child, this.controller, this.fromOffset, this.fromOpacity);
  Widget child;
  final AnimationController controller;
  Offset fromOffset;
  Offset toOffset = Offset.zero;
  double fromOpacity;
  double toOpacity = 1;
  Curve opacityCurve = Curves.easeInOutCubic;
  Curve movementCurve = Curves.easeInOutCubic;
  double get t => movementCurve.transform(controller.value);
  Offset get offset => Offset.lerp(fromOffset, toOffset, t)!;
  double get opacity =>
      fromOpacity +
      (toOpacity - fromOpacity) * opacityCurve.transform(controller.value);
}

class _DirectionalSwitcherState extends State<DirectionalSwitcher>
    with TickerProviderStateMixin {
  final List<_PanelMotion> _panels = [];
  late _PanelMotion _current;

  _PanelMotion _create(Widget child, Offset offset, double opacity) {
    final controller = AnimationController(vsync: this, value: 1);
    final panel = _PanelMotion(child, controller, offset, opacity)
      ..toOffset = offset
      ..toOpacity = opacity;
    controller.addListener(() {
      if (mounted) setState(() {});
    });
    return panel;
  }

  @override
  void initState() {
    super.initState();
    _current = _create(widget.child, Offset.zero, 1);
    _panels.add(_current);
  }

  void _retarget(_PanelMotion panel, Offset offset, double opacity) {
    final visibleOffset = panel.offset;
    final visibleOpacity = panel.opacity;
    panel.controller.stop();
    panel.fromOffset = visibleOffset;
    panel.fromOpacity = visibleOpacity;
    panel.toOffset = offset;
    panel.toOpacity = opacity;
    panel.movementCurve = widget.replaceContent
        ? const Cubic(.65, 0, .35, 1)
        : Curves.easeInOutCubic;
    panel.opacityCurve = widget.replaceContent
        ? Curves.easeInOutCubic
        : opacity == 1
            ? Interval(widget.fadeThrough ? .35 : .25, 1,
                curve: Curves.easeOutCubic)
            : const Interval(0, .35, curve: Curves.easeOutCubic);
    panel.controller.duration = widget.duration;
    panel.controller.forward(from: 0).whenCompleteOrCancel(() {
      if (!mounted ||
          !_panels.contains(panel) ||
          panel.controller.isAnimating ||
          panel == _current) {
        return;
      }
      // A cancelled trajectory may already have been retargeted.
      if (panel.controller.value == 1 && _panels.contains(panel)) {
        setState(() => _panels.remove(panel));
        panel.controller.dispose();
      }
    });
  }

  @override
  void didUpdateWidget(DirectionalSwitcher oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.duration == Duration.zero) {
      final same = Widget.canUpdate(_current.child, widget.child);
      for (final panel in _panels.toList()) {
        if (!same || panel != _current) {
          _panels.remove(panel);
          panel.controller.dispose();
        }
      }
      if (same) {
        _current.controller.stop();
        _current.child = widget.child;
        _current.fromOffset = _current.toOffset = Offset.zero;
        _current.fromOpacity = _current.toOpacity = 1;
      } else {
        _current = _create(widget.child, Offset.zero, 1);
        _panels.add(_current);
      }
      return;
    }
    if (Widget.canUpdate(_current.child, widget.child)) {
      _current.child = widget.child;
      return;
    }
    var direction = widget.position >= oldWidget.position ? 1.0 : -1.0;
    if (widget.axis == Axis.horizontal &&
        Directionality.of(context) == TextDirection.rtl) {
      direction *= -1;
    }
    // Push offsets are fractions of the shared viewport. Both panels move
    // with one easing curve, meeting at a seam without overlapping their text.
    final distance = widget.replaceContent
        ? 1.0
        : widget.fadeThrough
            ? 0.0
            : 12.0;
    final travel = widget.axis == Axis.horizontal
        ? Offset(distance * direction, 0)
        : Offset(0, distance * direction);
    final returning =
        _panels.where((p) => Widget.canUpdate(p.child, widget.child));
    if (returning.isEmpty) {
      _current = _create(widget.child, travel, 0);
    } else {
      _current = returning.first;
    }
    _current.child = widget.child;
    if (!_panels.contains(_current)) _panels.add(_current);
    for (final panel in List<_PanelMotion>.of(_panels)) {
      _retarget(panel, panel == _current ? Offset.zero : -travel,
          panel == _current ? 1 : 0);
    }
  }

  @override
  Widget build(BuildContext context) {
    Widget panelWidget(_PanelMotion panel) {
      final incoming = panel == _current;
      final content = IgnorePointer(
        ignoring: !incoming,
        child: ExcludeFocus(
          excluding: !incoming,
          child: ExcludeSemantics(
            excluding: !incoming,
            child: RepaintBoundary(child: panel.child),
          ),
        ),
      );
      return KeyedSubtree(
        key: ObjectKey(panel),
        child: widget.replaceContent
            ? FractionalTranslation(
                translation: panel.offset,
                child: Material(
                  animationDuration: Duration.zero,
                  color: widget.replacementBackground ??
                      Theme.of(context).scaffoldBackgroundColor,
                  child: content,
                ),
              )
            : Transform.translate(
                offset: panel.offset,
                child:
                    Opacity(opacity: panel.opacity.clamp(0, 1), child: content),
              ),
      );
    }

    return ClipRect(
      child: widget.replaceContent
          ? Stack(fit: StackFit.expand, children: [
              ..._panels.where((p) => p != _current).map(panelWidget),
              panelWidget(_current),
            ])
          : (widget.layoutBuilder ?? AnimatedSwitcher.defaultLayoutBuilder)(
              panelWidget(_current),
              _panels.where((p) => p != _current).map(panelWidget).toList(),
            ),
    );
  }

  @override
  void dispose() {
    for (final panel in _panels) {
      panel.controller.dispose();
    }
    super.dispose();
  }
}

class PreferenceTextScaler extends TextScaler {
  const PreferenceTextScaler(this.platform, this.factor);
  final TextScaler platform;
  final double factor;
  @override
  double scale(double fontSize) {
    final scaled = platform.scale(fontSize);
    // An explicit OS accessibility enlargement must never be cancelled by a
    // legacy compact app preference.
    return scaled > fontSize
        ? scaled * (factor < 1 ? 1 : factor)
        : scaled * factor;
  }

  @override
  double get textScaleFactor => scale(14) / 14;
}

/// AnimatedSize with a direct layout path when motion is disabled. A zero
/// duration animation can notify its render object during performLayout.
class MotionSize extends StatelessWidget {
  const MotionSize(
      {super.key,
      required this.duration,
      required this.child,
      this.alignment = Alignment.center,
      this.curve = Curves.linear,
      this.clipBehavior = Clip.hardEdge});
  final Duration duration;
  final Widget child;
  final AlignmentGeometry alignment;
  final Curve curve;
  final Clip clipBehavior;
  @override
  Widget build(BuildContext context) => duration == Duration.zero
      ? child
      : AnimatedSize(
          duration: duration,
          alignment: alignment,
          curve: curve,
          clipBehavior: clipBehavior,
          child: child);
}
