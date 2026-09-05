import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../controllers/app_controller.dart';
import '../models/domain_models.dart';
import '../theme/app_motion.dart';
import '../widgets/app_select_field.dart';
import 'object_table.dart';

class ObjectPanel extends StatefulWidget {
  const ObjectPanel(
      {super.key,
      required this.controller,
      required this.onUpload,
      required this.onDelete,
      required this.onCreatePrefix,
      required this.onInspector,
      required this.onContextMenu});
  final AppController controller;
  final VoidCallback onUpload, onDelete, onCreatePrefix, onInspector;
  final Future<void> Function(ObjectEntry, Offset) onContextMenu;

  @override
  State<ObjectPanel> createState() => _ObjectPanelState();
}

class _ObjectPanelState extends State<ObjectPanel> {
  bool _viewExpanded = false;
  AppController get controller => widget.controller;
  VoidCallback get onUpload => widget.onUpload;
  VoidCallback get onDelete => widget.onDelete;
  VoidCallback get onCreatePrefix => widget.onCreatePrefix;
  VoidCallback get onInspector => widget.onInspector;

  Future<void> _listAll(BuildContext context) async {
    final accepted = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
                title: const Text('List all object keys?'),
                content: const Text(
                    'This reads more listing pages and may incur request charges. Loading stops at 100,000 keys per window to bound memory; you can then continue with the next window. Text and regex search only the loaded window.'),
                actions: [
                  TextButton(
                      onPressed: () => Navigator.pop(context, false),
                      child: const Text('Cancel')),
                  FilledButton(
                      onPressed: () => Navigator.pop(context, true),
                      child: const Text('List all'))
                ]));
    if (accepted == true) await controller.listAllObjectsForCurrentBucket();
  }

  @override
  Widget build(BuildContext context) {
    final c = controller;
    final hasBucket = c.selectedBucket != null;
    final selectedCount = c.objectSelection.keys.length;
    final objects = c.pagedVisibleObjects;
    final busy = c.isBusy('refresh-objects');
    return CallbackShortcuts(
        bindings: {
          const SingleActivator(LogicalKeyboardKey.escape):
              c.clearObjectSelection,
        },
        child: Card(
            child: Padding(
                padding: const EdgeInsets.all(12),
                child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Row(children: [
                        Expanded(
                            child: Text(c.selectedBucket?.name ?? 'Objects',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: Theme.of(context).textTheme.titleLarge)),
                        IconButton(
                            tooltip: 'Inspector',
                            onPressed: onInspector,
                            icon: const Icon(Icons.info_outline))
                      ]),
                      SingleChildScrollView(
                          scrollDirection: Axis.horizontal,
                          child: Row(children: [
                            TextButton(
                                onPressed: hasBucket
                                    ? () => c.refreshObjects(prefix: '')
                                    : null,
                                child: const Text('Root')),
                            ..._breadcrumbs(c),
                          ])),
                      LayoutBuilder(builder: (context, constraints) {
                        final narrow = constraints.maxWidth < 450;
                        final search = TextFormField(
                            key: ValueKey(
                                'object-filter-${c.objectFilterMode.name}-${c.objectFilterValue}'),
                            initialValue: c.objectFilterValue,
                            enabled: hasBucket,
                            decoration: InputDecoration(
                                labelText: c.objectFilterMode ==
                                        BrowserFilterMode.prefix
                                    ? 'Navigate to prefix'
                                    : 'Search loaded objects',
                                hintText: c.objectFilterMode ==
                                        BrowserFilterMode.regex
                                    ? 'Regular expression'
                                    : null,
                                errorText: c.objectFilterError,
                                prefixIcon: const Icon(Icons.search)),
                            onFieldSubmitted: c.applyObjectFilter);
                        final mode = SizedBox(
                            width: narrow ? 108 : 140,
                            child: AppSelectField<BrowserFilterMode>(
                                value: c.objectFilterMode,
                                decoration:
                                    const InputDecoration(labelText: 'Filter'),
                                items: const [
                                  AppSelectItem(
                                      value: BrowserFilterMode.prefix,
                                      label: 'Prefix'),
                                  AppSelectItem(
                                      value: BrowserFilterMode.text,
                                      label: 'Text'),
                                  AppSelectItem(
                                      value: BrowserFilterMode.regex,
                                      label: 'Regex')
                                ],
                                onChanged: hasBucket
                                    ? (v) {
                                        if (v != null) c.setObjectFilterMode(v);
                                      }
                                    : null));
                        return Row(children: [
                          mode,
                          const SizedBox(width: 8),
                          Expanded(child: search)
                        ]);
                      }),
                      const SizedBox(height: 10),
                      Wrap(
                          spacing: 8,
                          runSpacing: 6,
                          crossAxisAlignment: WrapCrossAlignment.center,
                          children: [
                            FilledButton.icon(
                                onPressed: hasBucket && !c.isBusy('upload')
                                    ? onUpload
                                    : null,
                                icon: const Icon(Icons.upload_file),
                                label: const Text('Upload')),
                            OutlinedButton.icon(
                              onPressed: () => setState(
                                  () => _viewExpanded = !_viewExpanded),
                              icon: Icon(_viewExpanded
                                  ? Icons.expand_less
                                  : Icons.tune),
                              label: const Text('View tools'),
                            ),
                            IconButton(
                                tooltip: busy
                                    ? 'Cancel listing'
                                    : 'Refresh object list',
                                onPressed: busy
                                    ? c.cancelListing
                                    : hasBucket
                                        ? c.refreshObjects
                                        : null,
                                icon: Icon(busy
                                    ? Icons.stop_circle_outlined
                                    : Icons.refresh)),
                          ]),
                      ClipRect(
                          child: AnimatedSize(
                        alignment: Alignment.topCenter,
                        duration: AppMotion.duration(context,
                            enabled: c.settings.enableAnimations),
                        curve: Curves.easeOutCubic,
                        child: !_viewExpanded
                            ? const SizedBox(width: double.infinity)
                            : Padding(
                                padding:
                                    const EdgeInsets.symmetric(vertical: 8),
                                child: DecoratedBox(
                                  decoration: BoxDecoration(
                                      color: Theme.of(context)
                                          .colorScheme
                                          .surfaceContainerLow,
                                      borderRadius: BorderRadius.circular(12)),
                                  child: Padding(
                                      padding: const EdgeInsets.all(6),
                                      child: Wrap(
                                          spacing: 4,
                                          runSpacing: 4,
                                          children: [
                                            _tool(
                                                'Flat view',
                                                Icons.account_tree_outlined,
                                                hasBucket
                                                    ? () => c.toggleFlatView(
                                                        !c.flatView)
                                                    : null,
                                                selected: c.flatView),
                                            _tool(
                                                'Create prefix',
                                                Icons
                                                    .create_new_folder_outlined,
                                                hasBucket
                                                    ? onCreatePrefix
                                                    : null),
                                            _tool(
                                                'Select all loaded objects',
                                                Icons.select_all,
                                                hasBucket
                                                    ? c.selectAllLoadedObjects
                                                    : null),
                                            _tool(
                                                'Show loaded rows',
                                                Icons.view_agenda_outlined,
                                                () => c.setShowAllObjects(
                                                    !c.showAllObjects),
                                                selected: c.showAllObjects),
                                            _tool(
                                                'List all',
                                                Icons.cloud_download_outlined,
                                                c.objectCursor.hasMore && !busy
                                                    ? () => _listAll(context)
                                                    : null),
                                          ])),
                                ),
                              ),
                      )),
                      AnimatedSize(
                          duration: AppMotion.duration(context,
                              enabled: c.settings.enableAnimations),
                          curve: Curves.easeOutCubic,
                          alignment: Alignment.topCenter,
                          child: selectedCount > 0 || c.selectedObject != null
                              ? Padding(
                                  padding:
                                      const EdgeInsets.symmetric(vertical: 8),
                                  child: Wrap(
                                      spacing: 8,
                                      crossAxisAlignment:
                                          WrapCrossAlignment.center,
                                      children: [
                                        Text(
                                            selectedCount > 0
                                                ? '$selectedCount selected'
                                                : c.selectedObject!.name,
                                            maxLines: 1,
                                            overflow: TextOverflow.ellipsis),
                                        OutlinedButton.icon(
                                            onPressed: c.isBusy('download')
                                                ? null
                                                : c.startSampleDownload,
                                            icon: const Icon(Icons.download),
                                            label: const Text('Download')),
                                        TextButton.icon(
                                            onPressed: c.isBusy('delete-object')
                                                ? null
                                                : onDelete,
                                            icon: const Icon(
                                                Icons.delete_outline),
                                            label: const Text('Delete')),
                                        if (selectedCount > 0)
                                          IconButton(
                                              tooltip: 'Clear selection',
                                              onPressed: c.clearObjectSelection,
                                              icon: const Icon(Icons.close)),
                                      ]))
                              : const SizedBox.shrink()),
                      if (busy || c.filteringObjects)
                        const LinearProgressIndicator(minHeight: 2),
                      Expanded(
                          child: objects.isEmpty
                              ? Center(
                                  child: Text(!hasBucket
                                      ? 'Select a bucket to load objects.'
                                      : c.objects.isEmpty
                                          ? 'No objects in this bucket and prefix.'
                                          : 'No matches in loaded objects. Change your filter or load more keys.'))
                              : ObjectTable(
                                  objects: objects,
                                  selectedKey: c.selectedObject?.key,
                                  selectedKeys: c.objectSelection.keys,
                                  compactRows: c.settings.compactRows,
                                  sortField: c.objectSortField,
                                  descending: c.objectSortDescending,
                                  onSort: (field) {
                                    if (field == c.objectSortField) {
                                      c.toggleObjectSortDirection();
                                    } else {
                                      if (c.objectSortDescending) {
                                        c.toggleObjectSortDirection();
                                      }
                                      c.setObjectSortField(field);
                                    }
                                  },
                                  onToggle: (o, range) =>
                                      c.toggleObjectSelection(o, range: range),
                                  contentTypeFor: c.objectContentType,
                                  onSelect: c.setSelectedObject,
                                  onShowContextMenu: widget.onContextMenu)),
                      const Divider(height: 1),
                      Wrap(
                          spacing: 8,
                          crossAxisAlignment: WrapCrossAlignment.center,
                          children: [
                            Text(
                                '${c.currentObjectPageStart}–${c.currentObjectPageEnd} of ${c.visibleObjects.length} matching · ${c.objects.length} loaded${c.objectCursor.hasMore ? ' · more available' : ''}',
                                style: Theme.of(context).textTheme.bodySmall),
                            if (c.objectPageCount > 1 && !c.showAllObjects) ...[
                              IconButton(
                                  tooltip: 'Previous page',
                                  onPressed: c.objectPage > 1
                                      ? c.previousObjectPage
                                      : null,
                                  icon: const Icon(Icons.chevron_left)),
                              Text('${c.objectPage}/${c.objectPageCount}'),
                              IconButton(
                                  tooltip: 'Next page',
                                  onPressed: c.objectPage < c.objectPageCount
                                      ? c.nextObjectPage
                                      : null,
                                  icon: const Icon(Icons.chevron_right)),
                            ],
                            if (c.objectCursor.hasMore)
                              TextButton(
                                  onPressed: busy
                                      ? null
                                      : () => c.listAllObjectsForCurrentBucket(
                                          all: false,
                                          nextWindow: c.listingBudgetReached),
                                  child: Text(c.listingBudgetReached
                                      ? 'Next window (clear loaded)'
                                      : 'Load more')),
                          ]),
                    ]))));
  }

  Widget _tool(String label, IconData icon, VoidCallback? action,
          {bool selected = false}) =>
      Tooltip(
          message: label,
          child: TextButton.icon(
            onPressed: action,
            style: selected
                ? TextButton.styleFrom(
                    backgroundColor:
                        Theme.of(context).colorScheme.secondaryContainer)
                : null,
            icon: Icon(icon),
            label: Text(label),
          ));

  List<Widget> _breadcrumbs(AppController c) {
    final parts = c.currentPrefix.split('/');
    return [
      for (var i = 0; i < parts.length; i++)
        if (parts[i].isNotEmpty)
          TextButton(
              onPressed: () =>
                  c.refreshObjects(prefix: '${parts.take(i + 1).join('/')}/'),
              child: Text('${parts[i]} /'))
    ];
  }
}
