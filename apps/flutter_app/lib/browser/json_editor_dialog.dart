import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import '../widgets/app_form_dialog.dart';

class JsonEditorDialog extends StatefulWidget {
  const JsonEditorDialog(
      {super.key,
      required this.title,
      required this.initialValue,
      this.onSave});
  final String title, initialValue;
  final Future<void> Function(String)? onSave;
  @override
  State<JsonEditorDialog> createState() => _JsonEditorDialogState();
}

class _JsonEditorDialogState extends State<JsonEditorDialog> {
  late final TextEditingController _text =
      TextEditingController(text: widget.initialValue);
  String? _error;
  Timer? _timer;
  bool _pending = false;
  @override
  void initState() {
    super.initState();
    _validate();
  }

  void _validate() {
    _pending = false;
    try {
      jsonDecode(_text.text);
      _error = null;
    } on FormatException catch (e) {
      final offset = (e.offset ?? 0).clamp(0, _text.text.length);
      final before = _text.text.substring(0, offset);
      _error =
          'Line ${'\n'.allMatches(before).length + 1}, column ${offset - before.lastIndexOf('\n')}: ${e.message}';
    }
  }

  void _changed(String _) {
    _timer?.cancel();
    setState(() => _pending = true);
    if (_text.text.length < 10000) {
      setState(_validate);
      return;
    }
    _timer = Timer(const Duration(milliseconds: 150), () {
      if (mounted) setState(_validate);
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    _text.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AppFormDialog<String>(
        title: widget.title,
        editor: true,
        width: 840,
        dirty: _text.text != widget.initialValue,
        valid: _error == null && !_pending,
        value: () =>
            const JsonEncoder.withIndent('  ').convert(jsonDecode(_text.text)),
        onSave: widget.onSave,
        extraActions: [
          TextButton(
              onPressed: _error != null || _pending
                  ? null
                  : () {
                      _text.text = const JsonEncoder.withIndent('  ')
                          .convert(jsonDecode(_text.text));
                      setState(_validate);
                    },
              child: const Text('Format'))
        ],
        child: TextField(
            controller: _text,
            autofocus: true,
            autocorrect: false,
            enableSuggestions: false,
            minLines: 12,
            maxLines: null,
            keyboardType: TextInputType.multiline,
            style: const TextStyle(fontFamily: 'monospace'),
            decoration: InputDecoration(
                errorText: _error,
                errorMaxLines: 4,
                helperText: '⌘/Ctrl+Enter to save'),
            onChanged: _changed),
      );
}
