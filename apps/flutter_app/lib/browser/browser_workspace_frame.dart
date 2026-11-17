import 'package:flutter/material.dart';
import '../controllers/app_controller.dart';
import 'browser_content_signature.dart';
import 'browser_workspace.dart';

/// The shell still refreshes its status banner for job/log events, but the
/// browser subtree only changes for data it actually displays. Inherited
/// theme, text scale and layout changes continue to flow through Flutter.
class BrowserWorkspaceFrame extends StatefulWidget {
  const BrowserWorkspaceFrame(
      {super.key, required this.controller, required this.compact});
  final AppController controller;
  final bool compact;
  @override
  State<BrowserWorkspaceFrame> createState() => _BrowserWorkspaceFrameState();
}

class _BrowserWorkspaceFrameState extends State<BrowserWorkspaceFrame> {
  Object? _signature;
  Widget? _child;
  @override
  Widget build(BuildContext context) {
    final c = widget.controller;
    final signature = browserContentSignature(c, compact: widget.compact);
    if (_signature != signature || _child == null) {
      _signature = signature;
      _child = BrowserWorkspace(controller: c, compact: widget.compact);
    }
    return _child!;
  }
}
