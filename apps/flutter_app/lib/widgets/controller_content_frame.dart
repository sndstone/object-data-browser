import 'package:flutter/material.dart';

/// Rebuilds route content only when the controller changes displayed data.
/// Parent/local state and inherited theme/layout changes still rebuild normally.
class ControllerContentFrame extends StatefulWidget {
  const ControllerContentFrame({
    super.key,
    required this.controller,
    required this.signature,
    required this.builder,
  });

  final Listenable controller;
  final Object Function() signature;
  final WidgetBuilder builder;

  @override
  State<ControllerContentFrame> createState() => _ControllerContentFrameState();
}

class _ControllerContentFrameState extends State<ControllerContentFrame> {
  Object? _signature;

  @override
  void initState() {
    super.initState();
    _signature = widget.signature();
    widget.controller.addListener(_changed);
  }

  void _changed() {
    final signature = widget.signature();
    if (_signature == signature) return;
    setState(() => _signature = signature);
  }

  @override
  void didUpdateWidget(ControllerContentFrame oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller.removeListener(_changed);
      widget.controller.addListener(_changed);
    }
    _signature = widget.signature();
  }

  @override
  void dispose() {
    widget.controller.removeListener(_changed);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.builder(context);
}
