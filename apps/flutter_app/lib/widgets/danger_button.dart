import 'package:flutter/material.dart';

class DangerButton extends StatelessWidget {
  const DangerButton({super.key, required this.onPressed, required this.child});
  final VoidCallback? onPressed;
  final Widget child;
  @override
  Widget build(BuildContext context) => FilledButton(
      onPressed: onPressed,
      style: FilledButton.styleFrom(
          backgroundColor: Theme.of(context).colorScheme.error,
          foregroundColor: Theme.of(context).colorScheme.onError),
      child: child);
}
