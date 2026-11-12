import 'package:flutter/material.dart';
import '../widgets/app_form_dialog.dart';

class ContentHeadersDialog extends StatefulWidget {
  const ContentHeadersDialog({super.key, required this.headers, this.onSave});
  final Map<String, String> headers;
  final Future<void> Function(Map<String, String>)? onSave;
  @override
  State<ContentHeadersDialog> createState() => _ContentHeadersDialogState();
}

class _ContentHeadersDialogState extends State<ContentHeadersDialog> {
  static const names = ['Content-Type', 'Cache-Control', 'Content-Disposition'];
  late final fields = {
    for (final name in names)
      name: TextEditingController(
          text: widget.headers.entries
                  .where((e) => e.key.toLowerCase() == name.toLowerCase())
                  .firstOrNull
                  ?.value ??
              '')
  };
  late final initial = fields.map((k, v) => MapEntry(k, v.text));
  @override
  void initState() {
    super.initState();
    initial;
  }

  @override
  void dispose() {
    for (final field in fields.values) {
      field.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final valid =
        fields.values.every((c) => !c.text.contains(RegExp(r'[\r\n]')));
    return AppFormDialog<Map<String, String>>(
      title: 'Content headers',
      valid: valid,
      dirty: fields.entries.any((e) => e.value.text != initial[e.key]),
      value: () => fields.map((k, v) => MapEntry(k, v.text)),
      onSave: widget.onSave,
      submitLabel: 'Apply',
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        for (final entry in fields.entries)
          Padding(
              padding: const EdgeInsets.only(bottom: 16),
              child: TextField(
                  controller: entry.value,
                  autocorrect: false,
                  enableSuggestions: false,
                  decoration: InputDecoration(labelText: entry.key),
                  onChanged: (_) => setState(() {}))),
        const Text(
            'Other headers, access permissions and Object Lock settings are preserved. Clear a value to remove it. S3 applies changes by copying to the same object key.'),
        if (!valid) const Text('Header values cannot contain line breaks.'),
      ]),
    );
  }
}
