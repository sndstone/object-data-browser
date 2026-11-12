import 'dart:convert';
import 'package:flutter/material.dart';
import '../widgets/app_form_dialog.dart';

class RenameDialog extends StatefulWidget {
  const RenameDialog(
      {super.key,
      required this.path,
      required this.onSave,
      this.directory = false});
  final String path;
  final bool directory;
  final Future<void> Function(String) onSave;
  @override
  State<RenameDialog> createState() => _RenameDialogState();
}

class _RenameDialogState extends State<RenameDialog> {
  late final String _parent =
      widget.path.substring(0, widget.path.lastIndexOf('/') + 1);
  late final String _original = widget.path.substring(_parent.length);
  late final _name = TextEditingController(text: _original);

  @override
  void initState() {
    super.initState();
    final dot = widget.directory ? -1 : _original.lastIndexOf('.');
    _name.selection = TextSelection(
        baseOffset: 0, extentOffset: dot > 0 ? dot : _original.length);
  }

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final name = _name.text, target = '$_parent${_name.text}';
    final error = name.isEmpty
        ? 'Enter a name.'
        : name.contains('/')
            ? 'Use a name without slashes.'
            : utf8.encode(target).length > 1024
                ? 'The full key exceeds 1,024 UTF-8 bytes.'
                : null;
    return AppFormDialog<String>(
      title: widget.directory ? 'Rename directory' : 'Rename object',
      width: 560,
      submitLabel: 'Rename',
      dirty: name != _original,
      valid: error == null && name != _original,
      value: () => target,
      onSave: widget.onSave,
      child: Builder(
          builder: (context) => Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    SelectableText(
                        _parent.isEmpty ? 'Parent: /' : 'Parent: $_parent'),
                    const SizedBox(height: 16),
                    TextField(
                        controller: _name,
                        autofocus: true,
                        autocorrect: false,
                        enableSuggestions: false,
                        textInputAction: TextInputAction.done,
                        decoration: InputDecoration(
                            labelText: 'New name', errorText: error),
                        onChanged: (_) => setState(() {}),
                        onSubmitted: (_) => submitAppForm(context)),
                    const SizedBox(height: 16),
                    Text(widget.directory
                        ? 'The destination must not already exist.'
                        : 'Renaming copies the object, then removes the source when safe. The destination must not already exist. Source version history is preserved.'),
                  ])),
    );
  }
}
