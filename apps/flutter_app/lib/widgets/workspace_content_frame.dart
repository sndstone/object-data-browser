import 'package:flutter/material.dart';

/// Keeps expensive workspace content stable during unrelated progress events.
/// Theme, MediaQuery and layout dependencies still invalidate descendants.
class WorkspaceContentFrame extends StatefulWidget {
  const WorkspaceContentFrame(
      {super.key, required this.signature, required this.builder});
  final Object signature;
  final Widget Function() builder;
  @override
  State<WorkspaceContentFrame> createState() => _WorkspaceContentFrameState();
}

class _WorkspaceContentFrameState extends State<WorkspaceContentFrame> {
  Object? _signature;
  Widget? _child;
  @override
  Widget build(BuildContext context) {
    if (_child == null || _signature != widget.signature) {
      _signature = widget.signature;
      _child = widget.builder();
    }
    return _child!;
  }
}
