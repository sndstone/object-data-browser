import 'package:flutter/material.dart';

/// Owns a dialog's text controllers. A closing dialog keeps building its
/// fields until the exit transition ends, so they are released with the route
/// rather than as soon as the dialog future completes.
class DialogControllers extends StatefulWidget {
  const DialogControllers(
      {super.key, required this.controllers, required this.child});
  final List<TextEditingController> controllers;
  final Widget child;
  @override
  State<DialogControllers> createState() => _DialogControllersState();
}

class _DialogControllersState extends State<DialogControllers> {
  @override
  void dispose() {
    for (final controller in widget.controllers) {
      controller.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
