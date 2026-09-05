import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../controllers/app_controller.dart';
import '../models/domain_models.dart';

class AppShortcuts extends StatelessWidget {
  const AppShortcuts(
      {super.key, required this.controller, required this.child});
  final AppController controller;
  final Widget child;
  @override
  Widget build(BuildContext context) {
    final mac = Theme.of(context).platform == TargetPlatform.macOS;
    SingleActivator key(LogicalKeyboardKey key, {bool shift = false}) =>
        SingleActivator(key, meta: mac, control: !mac, shift: shift);
    final modifier = mac ? '⌘' : 'Ctrl+';
    final workspaces = [
      WorkspaceTab.browser,
      WorkspaceTab.tasks,
      if (Theme.of(context).platform != TargetPlatform.android &&
          Theme.of(context).platform != TargetPlatform.iOS)
        WorkspaceTab.benchmark,
      WorkspaceTab.eventLog,
      WorkspaceTab.settings
    ];
    return CallbackShortcuts(bindings: {
      key(LogicalKeyboardKey.keyK): controller.requestObjectSearchFocus,
      key(LogicalKeyboardKey.keyR): () {
        if (controller.activeTab == WorkspaceTab.browser) {
          controller.refreshObjects();
        }
      },
      key(LogicalKeyboardKey.keyI): controller.requestInspectorToggle,
      const SingleActivator(LogicalKeyboardKey.delete):
          controller.requestDeleteSelection,
      for (final (i, k) in [
        LogicalKeyboardKey.digit1,
        LogicalKeyboardKey.digit2,
        LogicalKeyboardKey.digit3,
        LogicalKeyboardKey.digit4,
        LogicalKeyboardKey.digit5
      ].indexed)
        if (i < workspaces.length)
          key(k): () => controller.selectTab(workspaces[i]),
      key(LogicalKeyboardKey.slash): () => showDialog<void>(
          context: context,
          builder: (context) => AlertDialog(
                  title: const Text('Keyboard shortcuts'),
                  content: Text(
                      '${modifier}K  Search objects\n${modifier}R  Refresh objects\n${modifier}I  Toggle inspector\n${modifier}1–5  Switch workspace\nDelete  Delete selection (outside text fields)\n$modifier/  Keyboard shortcuts'),
                  actions: [
                    TextButton(
                        onPressed: () => Navigator.pop(context),
                        child: const Text('Close'))
                  ])),
    }, child: Focus(autofocus: true, child: child));
  }
}
