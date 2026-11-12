import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../services/diagnostic_safety.dart';
import '../theme/app_motion.dart';

void submitAppForm(BuildContext context) =>
    context.findAncestorStateOfType<_AppFormDialogState>()?._submit();

/// A keyboard-aware form surface with retained drafts and a save-in-place
/// lifecycle. The same route and controllers survive window resizing.
class AppFormDialog<T> extends StatefulWidget {
  const AppFormDialog({
    super.key,
    required this.title,
    required this.child,
    required this.value,
    this.onSave,
    this.valid = true,
    this.dirty = false,
    this.editor = false,
    this.width = 560,
    this.submitLabel = 'Save',
    this.extraActions = const [],
  });

  final String title, submitLabel;
  final Widget child;
  final T Function() value;
  final Future<void> Function(T)? onSave;
  final bool valid, dirty, editor;
  final double width;
  final List<Widget> extraActions;

  @override
  State<AppFormDialog<T>> createState() => _AppFormDialogState<T>();
}

class _AppFormDialogState<T> extends State<AppFormDialog<T>> {
  bool _busy = false, _confirming = false;
  String? _error;

  Future<void> _cancel() async {
    if (_busy || _confirming) return;
    if (widget.dirty) {
      _confirming = true;
      final discard = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          scrollable: true,
          title: const Text('Discard changes?'),
          content: const Text('Your unsaved changes will be lost.'),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const Text('Keep editing')),
            FilledButton(
                onPressed: () => Navigator.pop(context, true),
                child: const Text('Discard')),
          ],
        ),
      );
      _confirming = false;
      if (discard != true) return;
    }
    if (mounted) Navigator.pop(context);
  }

  Future<void> _submit() async {
    if (_busy || !widget.valid) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final value = widget.value();
      await widget.onSave?.call(value);
      if (mounted) Navigator.pop(context, value);
    } catch (error) {
      if (mounted) setState(() => _error = DiagnosticSafety.text('$error'));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);
    final phone = media.size.width < 700 || media.size.height < 500;
    final full = phone && widget.editor;
    final height = math.max(
        120.0,
        media.size.height -
            media.viewInsets.bottom -
            media.padding.vertical -
            (full ? 0 : 32));
    return PopScope<T>(
      canPop: !_busy && !widget.dirty,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _cancel();
      },
      child: CallbackShortcuts(
        bindings: {
          const SingleActivator(LogicalKeyboardKey.escape): _cancel,
          const SingleActivator(LogicalKeyboardKey.enter, control: true):
              _submit,
          const SingleActivator(LogicalKeyboardKey.enter, meta: true): _submit,
        },
        child: Dialog(
          alignment: phone ? Alignment.bottomCenter : Alignment.center,
          insetPadding: full ? EdgeInsets.zero : const EdgeInsets.all(16),
          insetAnimationDuration:
              AppMotion.duration(context, milliseconds: 180),
          child: ConstrainedBox(
            constraints: BoxConstraints(
                maxWidth: full ? media.size.width : widget.width,
                maxHeight: height),
            child: SizedBox(
              height: full ? height : null,
              child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Padding(
                      padding: const EdgeInsets.fromLTRB(24, 16, 12, 12),
                      child: Row(children: [
                        Expanded(
                            child: Text(widget.title,
                                style: Theme.of(context).textTheme.titleLarge)),
                        IconButton(
                            tooltip: 'Close',
                            onPressed: _busy ? null : _cancel,
                            icon: const Icon(Icons.close)),
                      ]),
                    ),
                    const Divider(height: 1),
                    Flexible(
                      child: SingleChildScrollView(
                        padding: const EdgeInsets.all(24),
                        child: Column(
                            mainAxisSize: MainAxisSize.min,
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              AbsorbPointer(
                                  absorbing: _busy, child: widget.child),
                              if (_error != null)
                                Padding(
                                    padding: const EdgeInsets.only(top: 16),
                                    child: Semantics(
                                        liveRegion: true,
                                        child: Text(_error!,
                                            style: TextStyle(
                                                color: Theme.of(context)
                                                    .colorScheme
                                                    .error)))),
                            ]),
                      ),
                    ),
                    const Divider(height: 1),
                    Padding(
                      padding: const EdgeInsets.all(16),
                      child: OverflowBar(
                          spacing: 8,
                          overflowSpacing: 8,
                          alignment: MainAxisAlignment.end,
                          children: [
                            ...widget.extraActions.map((action) =>
                                AbsorbPointer(absorbing: _busy, child: action)),
                            TextButton(
                                onPressed: _busy ? null : _cancel,
                                child: const Text('Cancel')),
                            FilledButton(
                                onPressed:
                                    _busy || !widget.valid ? null : _submit,
                                child: _busy
                                    ? const SizedBox(
                                        width: 18,
                                        height: 18,
                                        child: CircularProgressIndicator(
                                            strokeWidth: 2))
                                    : Text(widget.submitLabel)),
                          ]),
                    ),
                  ]),
            ),
          ),
        ),
      ),
    );
  }
}
