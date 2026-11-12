import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import '../widgets/app_form_dialog.dart';

class TagEditorDialog extends StatefulWidget {
  const TagEditorDialog(
      {super.key,
      required this.initialTags,
      this.title = 'Edit tags',
      this.onSave});
  final Map<String, String> initialTags;
  final String title;
  final Future<void> Function(Map<String, String>)? onSave;
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
      final key = row.$1.text;
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

  Map<String, String> get _value =>
      {for (final row in _rows) row.$1.text: row.$2.text};

  @override
  Widget build(BuildContext context) => AppFormDialog<Map<String, String>>(
        title: widget.title,
        dirty: !mapEquals(_value, widget.initialTags),
        valid: _error == null,
        value: () => _value,
        onSave: widget.onSave,
        child: LayoutBuilder(builder: (context, constraints) {
          final stacked = constraints.maxWidth < 450 ||
              MediaQuery.textScalerOf(context).scale(14) > 20;
          return Column(mainAxisSize: MainAxisSize.min, children: [
            for (final row in _rows)
              Padding(
                  key: ObjectKey(row.$1),
                  padding: const EdgeInsets.only(bottom: 16),
                  child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Expanded(
                            child: stacked
                                ? Column(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                        _field(row.$1, 'Key'),
                                        const SizedBox(height: 12),
                                        _field(row.$2, 'Value')
                                      ])
                                : Row(children: [
                                    Expanded(child: _field(row.$1, 'Key')),
                                    const SizedBox(width: 12),
                                    Expanded(child: _field(row.$2, 'Value'))
                                  ])),
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
                  style: TextStyle(color: Theme.of(context).colorScheme.error)),
            TextButton.icon(
                onPressed: _rows.length >= 50
                    ? null
                    : () => setState(() => _rows.add(
                        (TextEditingController(), TextEditingController()))),
                icon: const Icon(Icons.add),
                label: const Text('Add tag')),
          ]);
        }),
      );

  Widget _field(TextEditingController controller, String label) => TextField(
      controller: controller,
      autocorrect: false,
      enableSuggestions: false,
      decoration: InputDecoration(labelText: label),
      onChanged: (_) => setState(() {}));
}
