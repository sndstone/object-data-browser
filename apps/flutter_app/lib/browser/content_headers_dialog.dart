import 'package:flutter/material.dart';

class ContentHeadersDialog extends StatefulWidget {
  const ContentHeadersDialog({super.key, required this.headers});
  final Map<String, String> headers;
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
    return AlertDialog(
        title: const Text('Content headers'),
        content: SizedBox(
            width: 520,
            child: SingleChildScrollView(
                child: Column(mainAxisSize: MainAxisSize.min, children: [
              for (final entry in fields.entries)
                TextField(
                    controller: entry.value,
                    decoration: InputDecoration(labelText: entry.key),
                    onChanged: (_) => setState(() {})),
              const SizedBox(height: 12),
              const Text(
                  'Other headers are preserved. Clear a value to remove it. S3 applies changes by copying to the same object key.'),
              if (!valid)
                const Text('Header values cannot contain line breaks.'),
            ]))),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Cancel')),
          FilledButton(
              onPressed: valid
                  ? () => Navigator.pop(
                      context, fields.map((k, v) => MapEntry(k, v.text)))
                  : null,
              child: const Text('Apply'))
        ]);
  }
}
