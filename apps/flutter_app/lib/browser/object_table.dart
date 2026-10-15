import '../utils/format.dart';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter/semantics.dart';
import '../models/domain_models.dart';
import '../services/app_platform.dart';
import '../widgets/app_menu.dart';
import '../widgets/edge_fade_scroll.dart';

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
  /// Opens the object menu. The rectangle is the trigger's global bounds, or
  /// a zero-size rectangle at the pointer for right-clicks.
  final Future<void> Function(ObjectEntry, Rect) onShowContextMenu;

  @override
  Widget build(BuildContext context) =>
      LayoutBuilder(builder: (context, constraints) {
        final narrow = constraints.maxWidth < 520;
        final height = math.max(
            AppPlatform.isMobile
                ? 52.0
                : compactRows
                    ? 38.0
                    : 44.0,
            MediaQuery.textScalerOf(context).scale(16) + 22);
        return Column(children: [
          Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              child: narrow
                  ? Wrap(spacing: 4, children: [
                      _sortHeader('Name', BrowserObjectSortField.name),
                      _sortHeader(
                          'Modified', BrowserObjectSortField.lastModified),
                      _sortHeader('Size', BrowserObjectSortField.size),
                    ])
                  // Header cells share the row's fixed leading slots and
                  // column widths so labels sit directly over their values.
                  : Row(children: [
                      const SizedBox(width: _checkSlot + _iconSlot),
                      Expanded(
                          child: Align(
                              alignment: Alignment.centerLeft,
                              child: _sortHeader(
                                  'Name', BrowserObjectSortField.name))),
                      SizedBox(
                          width: _modifiedWidth,
                          child: Align(
                              alignment: Alignment.centerLeft,
                              child: _sortHeader('Modified',
                                  BrowserObjectSortField.lastModified))),
                      SizedBox(
                          width: _sizeWidth,
                          child: Align(
                              alignment: Alignment.centerRight,
                              child: _sortHeader(
                                  'Size', BrowserObjectSortField.size,
                                  trailingAligned: true))),
                      const SizedBox(width: _actionSlot)
                    ])),
          const Divider(height: 1),
          Expanded(
              child: VerticalEdgeFade(child: ListView.builder(
                  key: const ValueKey('object-panel-list'),
                  itemExtent: height,
                  itemCount: objects.length,
                  itemBuilder: (context, index) {
                    final object = objects[index];
                    final inspected = object.key == selectedKey;
                    final checked = selectedKeys.contains(object.key);
                    final showActions =
                        selectedKeys.isEmpty && selectedKey == null;
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
                                    : active
                                        ? theme.colorScheme.surfaceContainerLow
                                        : Colors.transparent,
                                child: Builder(builder: (rowContext) {
                                  // Keyboard and long-press open the menu
                                  // from the row's action slot, where the
                                  // actions button sits.
                                  void actions() {
                                    final box = rowContext.findRenderObject()
                                        as RenderBox;
                                    final slot = Rect.fromLTWH(
                                        box.size.width - 8 - _actionSlot,
                                        0,
                                        _actionSlot,
                                        box.size.height);
                                    onShowContextMenu(
                                        object,
                                        slot.shift(
                                            box.localToGlobal(Offset.zero)));
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
                                              onShowContextMenu(
                                                  object,
                                                  details.globalPosition &
                                                      Size.zero),
                                          child: Padding(
                                              padding:
                                                  const EdgeInsets.symmetric(
                                                      horizontal: 8),
                                              child: Row(children: [
                                                // Fixed checkbox and icon slots keep
                                                // folder and file names aligned.
                                                SizedBox(
                                                    width: _checkSlot,
                                                    child: object.isFolder
                                                        ? null
                                                        : Checkbox(
                                                            value: checked,
                                                            semanticLabel:
                                                                'Select ${object.name}',
                                                            onChanged: (_) =>
                                                                toggle())),
                                                SizedBox(
                                                    width: _iconSlot,
                                                    child: Align(
                                                        alignment: Alignment
                                                            .centerLeft,
                                                        child: Icon(
                                                            object.isFolder
                                                                ? Icons
                                                                    .folder_outlined
                                                                : objectTypeIcon(
                                                                    object.key,
                                                                    contentTypeFor(
                                                                        object)),
                                                            size: 18,
                                                            color: theme
                                                                .colorScheme
                                                                .onSurfaceVariant))),
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
                                                      width: _modifiedWidth,
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
                                                    width: narrow
                                                        ? 72
                                                        : _sizeWidth,
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
                                                    width: _actionSlot,
                                                    child: Visibility(
                                                        visible: (AppPlatform
                                                                    .isMobile ||
                                                                narrow ||
                                                                active) &&
                                                            showActions,
                                                        maintainState: true,
                                                        maintainAnimation: true,
                                                        maintainSize: true,
                                                        // The menu opens from
                                                        // this button's bounds.
                                                        child: Builder(
                                                            builder: (buttonContext) => IconButton(
                                                                tooltip:
                                                                    'Object actions for ${object.name}',
                                                                icon: const Icon(
                                                                    Icons
                                                                        .more_horiz),
                                                                onPressed: () =>
                                                                    onShowContextMenu(
                                                                        object,
                                                                        globalRectOf(
                                                                            buttonContext)))))),
                                              ]))));
                                }))));
                  }))),
        ]);
      });
  static const double _checkSlot = 48;
  static const double _iconSlot = 26;
  static const double _modifiedWidth = 165;
  static const double _sizeWidth = 96;
  static const double _actionSlot = 48;

  Widget _sortHeader(String label, BrowserObjectSortField field,
      {bool trailingAligned = false}) {
    final active = sortField == field;
    final icon = Icon(
        active
            ? (descending ? Icons.arrow_downward : Icons.arrow_upward)
            : Icons.unfold_more,
        size: 16);
    final text = Flexible(child: Text(label, overflow: TextOverflow.ellipsis));
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
                    padding: EdgeInsets.zero, minimumSize: const Size(48, 40)),
                // Numeric columns are right-aligned, so their sort icon leads
                // and the label's last character sits over the values.
                child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: trailingAligned
                        ? [icon, const SizedBox(width: 4), text]
                        : [text, const SizedBox(width: 4), icon]))));
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
