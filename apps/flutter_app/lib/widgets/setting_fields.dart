import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

class SettingTextField extends StatefulWidget {
  const SettingTextField(
      {super.key,
      required this.label,
      required this.value,
      required this.onCommit,
      this.validate,
      this.helper,
      this.unit,
      this.numeric = false,
      this.commitLabel = 'Saved'});
  final String label, value;

  /// Awaited before showing feedback. Return false or throw when a write fails.
  final FutureOr<Object?> Function(String) onCommit;
  final String commitLabel;
  final String? Function(String)? validate;
  final String? helper, unit;
  final bool numeric;
  @override
  State<SettingTextField> createState() => _SettingTextFieldState();
}

class _SettingTextFieldState extends State<SettingTextField> {
  late final TextEditingController _text =
      TextEditingController(text: widget.value);
  final FocusNode _focus = FocusNode();
  late String _saved = widget.value;
  String? _error;
  bool _showSaved = false;
  bool _committing = false;
  Timer? _timer;
  @override
  void initState() {
    super.initState();
    _focus.addListener(_blur);
  }

  void _blur() {
    if (!_focus.hasFocus) _commit();
  }

  @override
  void didUpdateWidget(covariant SettingTextField oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.value != widget.value) {
      if (!_committing) _saved = widget.value;
      if (!_focus.hasFocus) _text.text = widget.value;
    }
  }

  Future<void> _commit() async {
    if (_committing) return;
    final value = _text.text.trim();
    final error = widget.validate?.call(value);
    setState(() => _error = error);
    if (error != null || value == _saved) return;
    _committing = true;
    _timer?.cancel();
    setState(() => _showSaved = false);
    try {
      final result = await widget.onCommit(value);
      if (!mounted) return;
      if (result == false) {
        setState(() => _error = 'Could not save. Please retry.');
        return;
      }
      _saved = value;
      setState(() => _showSaved = true);
      _timer = Timer(const Duration(milliseconds: 1200), () {
        if (mounted) setState(() => _showSaved = false);
      });
    } catch (_) {
      if (mounted) setState(() => _error = 'Could not save. Please retry.');
    } finally {
      _committing = false;
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    _focus.removeListener(_blur);
    _focus.dispose();
    _text.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => CallbackShortcuts(
          bindings: {
            const SingleActivator(LogicalKeyboardKey.escape): () =>
                setState(() {
                  _text.text = _saved;
                  _error = null;
                }),
          },
          child: TextFormField(
              controller: _text,
              focusNode: _focus,
              keyboardType:
                  widget.numeric ? TextInputType.number : TextInputType.text,
              // Numeric settings are non-negative whole numbers; reject other
              // characters at entry instead of only on blur.
              inputFormatters: widget.numeric
                  ? [FilteringTextInputFormatter.digitsOnly]
                  : null,
              decoration: InputDecoration(
                  labelText: widget.label,
                  helperText: widget.helper,
                  errorText: _error,
                  suffixText: _showSaved ? widget.commitLabel : widget.unit),
              onFieldSubmitted: (_) => _commit()));
}

class SettingNumberField extends StatelessWidget {
  const SettingNumberField(
      {super.key,
      required this.label,
      required this.value,
      required this.onCommit,
      this.min = 1,
      this.max = 1000000,
      this.unit,
      this.helper,
      this.commitLabel = 'Saved'});
  final String label;
  final int value, min, max;
  final String? unit, helper;
  final FutureOr<Object?> Function(int) onCommit;
  final String commitLabel;
  @override
  Widget build(BuildContext context) => SettingTextField(
      label: label,
      value: '$value',
      unit: unit,
      helper: helper,
      numeric: true,
      commitLabel: commitLabel,
      onCommit: (v) => onCommit(int.parse(v)),
      validate: (v) {
        final n = int.tryParse(v);
        return n == null
            ? 'Enter a whole number.'
            : n < min || n > max
                ? 'Enter a value from $min to $max.'
                : null;
      });
}
