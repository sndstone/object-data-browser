import 'package:flutter/material.dart';

class TagEditorDialog extends StatefulWidget {
  const TagEditorDialog({super.key, required this.initialTags});
  final Map<String, String> initialTags;
  @override
  State<TagEditorDialog> createState() => _TagEditorDialogState();
}

class _TagEditorDialogState extends State<TagEditorDialog> {
  late final List<(TextEditingController, TextEditingController)> _rows = widget
      .initialTags.entries
      .map((e) => (
            TextEditingController(text: e.key),
            TextEditingController(text: e.value)
          ))
      .toList();
  final List<TextEditingController> _retired = [];
  String? get _error {
    if (_rows.length > 50) return 'Use at most 50 tags.';
    final keys = <String>{};
    for (final row in _rows) {
      final key = row.$1.text.trim();
      if (key.isEmpty) return 'Tag keys cannot be empty.';
      if (!keys.add(key)) return 'Duplicate tag key: $key';
      if (key.length > 128 || row.$2.text.length > 256) {
        return 'Keys allow 128 characters; values allow 256.';
      }
    }
    return null;
  }

  @override
  void dispose() {
    for (final row in _rows) {
      row.$1.dispose();
      row.$2.dispose();
    }
    for (final c in _retired) {
      c.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
          title: const Text('Bucket tags'),
          content: SizedBox(
              width: 560,
              child: SingleChildScrollView(
                  child: Column(mainAxisSize: MainAxisSize.min, children: [
                for (final row in _rows)
                  Padding(
                      key: ObjectKey(row.$1),
                      padding: const EdgeInsets.only(bottom: 8),
                      child: Row(children: [
                        Expanded(
                            child: TextField(
                                controller: row.$1,
                                decoration:
                                    const InputDecoration(labelText: 'Key'),
                                onChanged: (_) => setState(() {}))),
                        const SizedBox(width: 8),
                        Expanded(
                            child: TextField(
                                controller: row.$2,
                                decoration:
                                    const InputDecoration(labelText: 'Value'),
                                onChanged: (_) => setState(() {}))),
                        IconButton(
                            tooltip: 'Remove tag',
                            onPressed: () => setState(() {
                                  _rows.remove(row);
                                  _retired.addAll([row.$1, row.$2]);
                                }),
                            icon: const Icon(Icons.remove_circle_outline)),
                      ])),
                if (_error != null)
                  Text(_error!,
                      style: TextStyle(
                          color: Theme.of(context).colorScheme.error)),
                TextButton.icon(
                    onPressed: _rows.length >= 50
                        ? null
                        : () => setState(() => _rows.add((
                              TextEditingController(),
                              TextEditingController()
                            ))),
                    icon: const Icon(Icons.add),
                    label: const Text('Add tag')),
              ]))),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('Cancel')),
            FilledButton(
                onPressed: _error != null
                    ? null
                    : () => Navigator.pop(context, {
                          for (final row in _rows)
                            row.$1.text.trim(): row.$2.text
                        }),
                child: const Text('Save'))
          ]);
}
