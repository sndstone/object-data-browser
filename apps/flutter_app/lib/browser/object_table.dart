import '../utils/format.dart';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter/semantics.dart';
import '../models/domain_models.dart';
import '../services/app_platform.dart';

/// Lazy rows, real batch checkboxes and an independent inspection focus.
class ObjectTable extends StatelessWidget {
  const ObjectTable(
      {super.key,
      required this.objects,
      required this.selectedKey,
      required this.selectedKeys,
      required this.compactRows,
      required this.sortField,
      required this.descending,
      required this.onSort,
      required this.onToggle,
      required this.contentTypeFor,
      required this.onSelect,
      required this.onShowContextMenu});
  final List<ObjectEntry> objects;
  final String? selectedKey;
  final Set<String> selectedKeys;
  final bool compactRows;
  final BrowserObjectSortField sortField;
  final bool descending;
  final ValueChanged<BrowserObjectSortField> onSort;
  final void Function(ObjectEntry object, bool range) onToggle;
  final String Function(ObjectEntry) contentTypeFor;
  final ValueChanged<ObjectEntry> onSelect;
  final Future<void> Function(ObjectEntry, Offset) onShowContextMenu;

  @override
  Widget build(BuildContext context) =>
      LayoutBuilder(builder: (context, constraints) {
        final narrow = constraints.maxWidth < 520;
        final height = math.max(
            AppPlatform.isMobile || !compactRows ? 52.0 : 38.0,
            MediaQuery.textScalerOf(context).scale(16) + 22);
        return Column(children: [
          Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              child: narrow
                  ? Wrap(spacing: 4, children: [
                      _sortHeader('Name', BrowserObjectSortField.name),
                      _sortHeader(
                          'Modified', BrowserObjectSortField.lastModified),
                      _sortHeader('Size', BrowserObjectSortField.size),
                    ])
                  : Row(children: [
                      const SizedBox(width: 48),
                      Expanded(
                          child: Align(
                              alignment: Alignment.centerLeft,
                              child: _sortHeader(
                                  'Name', BrowserObjectSortField.name))),
                      if (!narrow)
                        SizedBox(
                            width: 165,
                            child: _sortHeader('Modified',
                                BrowserObjectSortField.lastModified)),
                      SizedBox(
                          width: 96,
                          child:
                              _sortHeader('Size', BrowserObjectSortField.size)),
                      const SizedBox(width: 48)
                    ])),
          const Divider(height: 1),
          Expanded(
              child: ListView.builder(
                  key: const ValueKey('object-panel-list'),
                  itemExtent: height,
                  itemCount: objects.length,
                  itemBuilder: (context, index) {
                    final object = objects[index];
                    final inspected = object.key == selectedKey;
                    final checked = selectedKeys.contains(object.key);
                    final theme = Theme.of(context);
                    void toggle() => onToggle(
                        object, HardwareKeyboard.instance.isShiftPressed);
                    return _HoverRow(
                        builder: (active) => Semantics(
                            selected: checked || inspected,
                            label: object.isFolder
                                ? 'Folder ${object.name}'
                                : null,
                            child: Material(
                                color: checked || inspected
                                    ? theme.colorScheme.primaryContainer
                                    : Colors.transparent,
                                child: Builder(builder: (rowContext) {
                                  void actions() {
                                    final box = rowContext.findRenderObject()
                                        as RenderBox;
                                    onShowContextMenu(
                                        object,
                                        box.localToGlobal(
                                            box.size.center(Offset.zero)));
                                  }

                                  return CallbackShortcuts(
                                      bindings: {
                                        const SingleActivator(
                                            LogicalKeyboardKey.space): toggle,
                                        const SingleActivator(
                                                LogicalKeyboardKey.enter):
                                            () => onSelect(object),
                                        const SingleActivator(
                                            LogicalKeyboardKey.f10,
                                            shift: true): actions,
                                      },
                                      child: InkWell(
                                          onTap: () {
                                            if (HardwareKeyboard
                                                .instance.isShiftPressed) {
                                              toggle();
                                            } else {
                                              onSelect(object);
                                            }
                                          },
                                          onLongPress: actions,
                                          onSecondaryTapDown: (details) =>
                                              onShowContextMenu(object,
                                                  details.globalPosition),
                                          child: Padding(
                                              padding:
                                                  const EdgeInsets.symmetric(
                                                      horizontal: 8),
                                              child: Row(children: [
                                                SizedBox(
                                                    width: 48,
                                                    child: object.isFolder
                                                        ? const Icon(Icons
                                                            .folder_outlined)
                                                        : Checkbox(
                                                            value: checked,
                                                            semanticLabel:
                                                                'Select ${object.name}',
                                                            onChanged: (_) =>
                                                                toggle())),
                                                if (!object.isFolder)
                                                  Padding(
                                                      padding:
                                                          const EdgeInsets.only(
                                                              right: 8),
                                                      child: Icon(
                                                          objectTypeIcon(
                                                              object.key,
                                                              contentTypeFor(
                                                                  object)),
                                                          size: 18)),
                                                Expanded(
                                                    child: Tooltip(
                                                        message: object.key,
                                                        child: Text(object.name,
                                                            maxLines: 1,
                                                            overflow:
                                                                TextOverflow
                                                                    .ellipsis))),
                                                if (!narrow)
                                                  SizedBox(
                                                      width: 165,
                                                      child: Tooltip(
                                                          message:
                                                              '${object.modifiedAt.toIso8601String()} · ${formatRelative(object.modifiedAt)}',
                                                          child: Text(
                                                              formatDateTime(object
                                                                  .modifiedAt),
                                                              style: theme
                                                                  .textTheme
                                                                  .bodySmall))),
                                                SizedBox(
                                                    width: 96,
                                                    child: Text(
                                                        object.isFolder
                                                            ? '—'
                                                            : formatBytes(
                                                                object.size),
                                                        textAlign:
                                                            TextAlign.right,
                                                        style: theme
                                                            .textTheme.bodySmall
                                                            ?.copyWith(
                                                                fontFeatures: const [
                                                              FontFeature
                                                                  .tabularFigures()
                                                            ]))),
                                                SizedBox(
                                                    width: 48,
                                                    child: Opacity(
                                                        opacity: AppPlatform
                                                                    .isMobile ||
                                                                active ||
                                                                checked ||
                                                                inspected
                                                            ? 1
                                                            : 0,
                                                        child: IconButton(
                                                            tooltip:
                                                                'Object actions for ${object.name}',
                                                            icon: const Icon(
                                                                Icons
                                                                    .more_horiz),
                                                            onPressed:
                                                                actions))),
                                              ]))));
                                }))));
                  })),
        ]);
      });
  Widget _sortHeader(String label, BrowserObjectSortField field) {
    final active = sortField == field;
    return Semantics(
        sortKey: OrdinalSortKey(field.index.toDouble()),
        button: true,
        selected: active,
        child: Tooltip(
            message:
                'Sort by $label${active ? (descending ? ' · descending; switch to ascending' : ' · ascending; switch to descending') : ''}',
            child: TextButton(
                onPressed: () => onSort(field),
                style: TextButton.styleFrom(
                    padding: const EdgeInsets.symmetric(horizontal: 4),
                    minimumSize: const Size(48, 48)),
                child: Row(mainAxisSize: MainAxisSize.min, children: [
                  Flexible(child: Text(label, overflow: TextOverflow.ellipsis)),
                  const SizedBox(width: 4),
                  Icon(
                      active
                          ? (descending
                              ? Icons.arrow_downward
                              : Icons.arrow_upward)
                          : Icons.unfold_more,
                      size: 16),
                ]))));
  }

  static IconData objectTypeIcon(String key, String contentType) {
    final ext = key.split('.').last.toLowerCase();
    if (contentType.startsWith('image/') ||
        ['png', 'jpg', 'jpeg', 'gif', 'webp', 'svg'].contains(ext)) {
      return Icons.image_outlined;
    }
    if (contentType.startsWith('video/') ||
        ['mp4', 'mov', 'webm'].contains(ext)) {
      return Icons.movie_outlined;
    }
    if (['zip', 'gz', 'tar', '7z', 'rar'].contains(ext)) {
      return Icons.archive_outlined;
    }
    if ([
      'json',
      'html',
      'css',
      'js',
      'ts',
      'py',
      'dart',
      'go',
      'rs',
      'java',
      'yaml',
      'xml'
    ].contains(ext)) {
      return Icons.code;
    }
    if (contentType.startsWith('text/') ||
        ['pdf', 'doc', 'docx', 'txt', 'md'].contains(ext)) {
      return Icons.description_outlined;
    }
    return Icons.insert_drive_file_outlined;
  }
}

class _HoverRow extends StatefulWidget {
  const _HoverRow({required this.builder});
  final Widget Function(bool active) builder;
  @override
  State<_HoverRow> createState() => _HoverRowState();
}

class _HoverRowState extends State<_HoverRow> {
  bool _hover = false, _focus = false;
  @override
  Widget build(BuildContext context) => MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: Focus(
          onFocusChange: (v) => setState(() => _focus = v),
          child: widget.builder(_hover || _focus)));
}
