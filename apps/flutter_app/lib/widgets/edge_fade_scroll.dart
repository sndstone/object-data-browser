import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

/// Horizontal scroller that fades whichever edge has more content, so a
/// clipped row of options reads as scrollable.
class EdgeFadeScroll extends StatefulWidget {
  const EdgeFadeScroll({super.key, required this.child});
  final Widget child;
  @override
  State<EdgeFadeScroll> createState() => _EdgeFadeScrollState();
}

class _EdgeFadeScrollState extends State<EdgeFadeScroll> {
  final _controller = ScrollController();
  bool _before = false, _after = false;

  @override
  void initState() {
    super.initState();
    _controller.addListener(_update);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _update() {
    if (!_controller.hasClients) return;
    final position = _controller.position;
    final before = position.extentBefore > 0.5;
    final after = position.extentAfter > 0.5;
    if (before != _before || after != _after) {
      setState(() {
        _before = before;
        _after = after;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _update();
    });
    final scroller = NotificationListener<ScrollMetricsNotification>(
      onNotification: (_) {
        _update();
        return false;
      },
      child: SingleChildScrollView(
        controller: _controller,
        scrollDirection: Axis.horizontal,
        child: widget.child,
      ),
    );
    // Keep the render-object identity stable while bypassing opaque masking.
    return _ConditionalShaderMask(
      enabled: _before || _after,
      blendMode: BlendMode.dstIn,
      shaderCallback: (bounds) {
        final fade = bounds.width == 0 ? 0.0 : (28 / bounds.width).clamp(0, .3);
        return LinearGradient(
          colors: [
            _before ? Colors.transparent : Colors.black,
            Colors.black,
            Colors.black,
            _after ? Colors.transparent : Colors.black,
          ],
          stops: [0, fade.toDouble(), 1 - fade.toDouble(), 1],
        ).createShader(bounds);
      },
      child: scroller,
    );
  }
}

/// Fades the top/bottom edge of a vertical scrollable [child] while more
/// content lies beyond it, so a panel clipped mid-row reads as scrollable
/// instead of cut off.
class VerticalEdgeFade extends StatefulWidget {
  const VerticalEdgeFade({super.key, required this.child, this.extent = 24});
  final Widget child;
  final double extent;
  @override
  State<VerticalEdgeFade> createState() => VerticalEdgeFadeState();
}

class VerticalEdgeFadeState extends State<VerticalEdgeFade> {
  bool _before = false, _after = false;

  @visibleForTesting
  bool get fadesTop => _before;
  @visibleForTesting
  bool get fadesBottom => _after;

  bool _onMetrics(ScrollMetrics metrics) {
    if (metrics.axis != Axis.vertical) return false;
    final before = metrics.extentBefore > 0.5;
    final after = metrics.extentAfter > 0.5;
    if (before != _before || after != _after) {
      setState(() {
        _before = before;
        _after = after;
      });
    }
    return false;
  }

  @override
  Widget build(BuildContext context) => _ConditionalShaderMask(
        enabled: _before || _after,
        blendMode: BlendMode.dstIn,
        shaderCallback: (bounds) {
          final fade = bounds.height == 0
              ? 0.0
              : (widget.extent / bounds.height).clamp(0.0, .3);
          return LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [
              _before ? Colors.transparent : Colors.black,
              Colors.black,
              Colors.black,
              _after ? Colors.transparent : Colors.black,
            ],
            stops: [0, fade, 1 - fade, 1],
          ).createShader(bounds);
        },
        child: NotificationListener<ScrollMetricsNotification>(
          onNotification: (n) => n.depth == 0 && _onMetrics(n.metrics),
          child: NotificationListener<ScrollNotification>(
            onNotification: (n) => n.depth == 0 && _onMetrics(n.metrics),
            child: widget.child,
          ),
        ),
      );
}

class _ConditionalShaderMask extends ShaderMask {
  const _ConditionalShaderMask(
      {required this.enabled,
      required super.shaderCallback,
      required super.blendMode,
      required super.child});
  final bool enabled;
  @override
  RenderShaderMask createRenderObject(BuildContext context) =>
      _ConditionalRenderShaderMask(
          enabled: enabled,
          shaderCallback: shaderCallback,
          blendMode: blendMode);
  @override
  void updateRenderObject(BuildContext context, RenderShaderMask renderObject) {
    super.updateRenderObject(context, renderObject);
    (renderObject as _ConditionalRenderShaderMask).enabled = enabled;
  }
}

class _ConditionalRenderShaderMask extends RenderShaderMask {
  _ConditionalRenderShaderMask(
      {required bool enabled,
      required super.shaderCallback,
      required super.blendMode})
      : _enabled = enabled;
  bool _enabled;
  set enabled(bool value) {
    if (_enabled == value) return;
    _enabled = value;
    markNeedsCompositingBitsUpdate();
    markNeedsPaint();
  }

  @override
  bool get alwaysNeedsCompositing => _enabled && super.alwaysNeedsCompositing;
  @override
  void paint(PaintingContext context, Offset offset) {
    if (_enabled) {
      super.paint(context, offset);
    } else {
      layer = null;
      if (child != null) context.paintChild(child!, offset);
    }
  }
}
