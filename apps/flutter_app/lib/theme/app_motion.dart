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
      this.layoutBuilder});
  final int position;
  final Duration duration;
  final Widget child;
  final Axis axis;
  final AnimatedSwitcherLayoutBuilder? layoutBuilder;
  @override
  State<DirectionalSwitcher> createState() => _DirectionalSwitcherState();
}

class _DirectionalSwitcherState extends State<DirectionalSwitcher> {
  double _direction = 1;
  @override
  void didUpdateWidget(DirectionalSwitcher oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.position != oldWidget.position) {
      _direction = widget.position > oldWidget.position ? 1 : -1;
    }
  }

  @override
  Widget build(BuildContext context) {
    final direction = widget.axis == Axis.horizontal &&
            Directionality.of(context) == TextDirection.rtl
        ? -_direction
        : _direction;
    return ClipRect(
        child: AnimatedSwitcher(
            duration: widget.duration,
            switchInCurve: Curves.easeOutCubic,
            switchOutCurve: Curves.easeInCubic,
            layoutBuilder:
                widget.layoutBuilder ?? AnimatedSwitcher.defaultLayoutBuilder,
            transitionBuilder: (child, animation) {
              final incoming = child.key == widget.child.key &&
                  animation.status != AnimationStatus.reverse;
              final offset = direction * (incoming ? .045 : -.045);
              return FadeTransition(
                  opacity: animation,
                  child: SlideTransition(
                      key: const ValueKey('directional-slide'),
                      position: Tween<Offset>(
                              begin: widget.axis == Axis.horizontal
                                  ? Offset(offset, 0)
                                  : Offset(0, offset),
                              end: Offset.zero)
                          .animate(animation),
                      child: IgnorePointer(
                          ignoring: !incoming,
                          child: ExcludeSemantics(
                              excluding: !incoming, child: child))));
            },
            child: widget.child));
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
