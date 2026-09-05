import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

class NavigationItem extends StatefulWidget {
  const NavigationItem(
      {super.key,
      required this.label,
      required this.selected,
      required this.onActivate,
      required this.child});
  final String label;
  final bool selected;
  final VoidCallback onActivate;
  final Widget child;
  @override
  State<NavigationItem> createState() => _NavigationItemState();
}

class _NavigationItemState extends State<NavigationItem> {
  bool _focused = false;
  @override
  Widget build(BuildContext context) => MergeSemantics(
      child: Semantics(
          excludeSemantics: true,
          onTap: widget.onActivate,
          button: true,
          selected: widget.selected,
          label: widget.label,
          child: FocusableActionDetector(
              onShowFocusHighlight: (v) => setState(() => _focused = v),
              shortcuts: const {
                SingleActivator(LogicalKeyboardKey.enter): ActivateIntent(),
                SingleActivator(LogicalKeyboardKey.space): ActivateIntent()
              },
              actions: {
                ActivateIntent: CallbackAction<ActivateIntent>(onInvoke: (_) {
                  widget.onActivate();
                  return null;
                })
              },
              child: Container(
                  foregroundDecoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(6),
                      border: _focused
                          ? Border.all(
                              color: Theme.of(context).colorScheme.primary,
                              width: 2)
                          : null),
                  child: widget.child))));
}
