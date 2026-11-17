import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../models/google_service_account.dart';
import '../widgets/dialog_controllers.dart';
import '../widgets/app_form_dialog.dart';

class GoogleServiceAccountEditor extends StatefulWidget {
  const GoogleServiceAccountEditor({
    super.key,
    required this.value,
    required this.onChanged,
  });
  final String value;
  final void Function(String json, GoogleServiceAccount identity) onChanged;

  @override
  State<GoogleServiceAccountEditor> createState() =>
      _GoogleServiceAccountEditorState();
}

class _GoogleServiceAccountEditorState
    extends State<GoogleServiceAccountEditor> {
  String? _error;

  bool _accept(String json) {
    if (!mounted) return false;
    try {
      final identity = GoogleServiceAccount.parse(json);
      widget.onChanged(json, identity);
      setState(() => _error = null);
      return true;
    } on FormatException catch (error) {
      setState(() => _error = error.message);
      return false;
    }
  }

  Future<void> _choose() async {
    try {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['json'],
      );
      if (!mounted || result == null) return;
      final path = result.files.single.path;
      if (path == null) throw const FileSystemException();
      final file = File(path);
      if (await file.length() > 1024 * 1024) {
        if (mounted) {
          setState(
            () => _error =
                'The service-account key file must be smaller than 1 MiB.',
          );
        }
        return;
      }
      final json = await file.readAsString();
      if (mounted) _accept(json);
    } catch (_) {
      if (mounted) {
        setState(
          () => _error = 'The service-account key file could not be read.',
        );
      }
    }
  }

  Future<void> _paste() async {
    final input = TextEditingController();
    await showDialog<void>(
      context: context,
      builder: (context) => DialogControllers(
        controllers: [input],
        child: StatefulBuilder(
          builder: (context, update) => AppFormDialog<void>(
            title: 'Service account key (JSON)',
            submitLabel: 'Accept key',
            dirty: input.text.isNotEmpty,
            value: () {},
            onSave: (_) async {
              // Parse before publishing, so invalid input stays in this form.
              final identity = GoogleServiceAccount.parse(input.text);
              widget.onChanged(input.text, identity);
              if (mounted) setState(() => _error = null);
              input.clear();
            },
            child: TextField(
              key: const ValueKey('google-service-account-json'),
              controller: input,
              minLines: 4,
              maxLines: 8,
              autocorrect: false,
              enableSuggestions: false,
              onChanged: (_) => update(() {}),
              decoration: const InputDecoration(labelText: 'Paste key JSON'),
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    GoogleServiceAccount? identity;
    try {
      identity = GoogleServiceAccount.parse(widget.value);
    } on FormatException {
      /* A metadata-only import has no key yet. */
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Service account key (JSON)',
            style: Theme.of(context).textTheme.titleSmall),
        const SizedBox(height: 18),
        if (identity != null) ...[
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: Icon(Icons.check_circle_outline,
                color: Theme.of(context).colorScheme.onSurfaceVariant),
            title: const Text('•••••••• — key stored securely on Save'),
          ),
          ListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Service account email'),
            subtitle: SelectableText(identity.email),
          ),
          ListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Project ID'),
            subtitle: SelectableText(identity.projectId),
          ),
        ],
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            // Primary only while a key is still needed; once one is stored,
            // Save is the form's primary action.
            if (identity == null)
              FilledButton(
                onPressed: _choose,
                child: const Text('Choose .json file'),
              )
            else
              OutlinedButton(
                onPressed: _choose,
                child: const Text('Replace from .json file'),
              ),
            TextButton(
              onPressed: _paste,
              child: Text(
                identity == null ? 'Paste JSON' : 'Replace by pasting JSON',
              ),
            ),
          ],
        ),
        if (_error != null)
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: Icon(Icons.error_outline,
                color: Theme.of(context).colorScheme.error),
            title: Text(_error!),
          ),
      ],
    );
  }
}
