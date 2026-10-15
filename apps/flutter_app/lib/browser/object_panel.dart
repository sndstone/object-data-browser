import '../widgets/empty_state.dart';
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../controllers/app_controller.dart';
import '../models/domain_models.dart';
import '../theme/app_motion.dart';
import 'object_table.dart';
import 'empty_bucket_state.dart';
import '../utils/format.dart';
import '../widgets/app_menu.dart';

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
  final Future<void> Function(ObjectEntry, Rect) onContextMenu;

  @override
  State<ObjectPanel> createState() => _ObjectPanelState();
}

class _ObjectPanelState extends State<ObjectPanel> {
  bool _viewExpanded = false;
  late final TextEditingController _search =
      TextEditingController(text: controller.objectFilterValue);
  final FocusNode _searchFocus = FocusNode();
  Timer? _debounce;
  late String _externalValue;
  late Object _searchContext;
  Object get _contextSignature => (
        controller.selectedProfile?.id,
        controller.selectedBucket?.name,
        controller.currentPrefix,
        controller.objectFilterMode
      );
  @override
  void initState() {
    super.initState();
    _externalValue = controller.objectFilterValue;
    _searchContext = _contextSignature;
    controller.objectSearchFocus.addListener(_focusSearch);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && controller.pendingObjectSearchFocus) _focusSearch();
    });
  }

  void _focusSearch() {
    controller.pendingObjectSearchFocus = false;
    _searchFocus.requestFocus();
  }

  @override
  void didUpdateWidget(covariant ObjectPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (_searchContext != _contextSignature) {
      _searchContext = _contextSignature;
      _debounce?.cancel();
      _externalValue = controller.objectFilterValue;
      _search.text = _externalValue;
    } else if (_externalValue != controller.objectFilterValue) {
      _externalValue = controller.objectFilterValue;
      if (_search.text != _externalValue) {
        _debounce?.cancel();
        _search.text = _externalValue;
      }
    }
  }

  void _apply(String value) {
    _debounce?.cancel();
    controller.applyObjectFilter(value);
  }

  /// Clears the field and, when a filter is active, the applied filter too,
  /// keeping focus in the field so typing can continue.
  void _clearSearch() {
    _debounce?.cancel();
    _search.clear();
    if (controller.objectFilterValue.isNotEmpty ||
        controller.objectFilterError != null) {
      _apply('');
    }
    _searchFocus.requestFocus();
  }

  @override
  void dispose() {
    _debounce?.cancel();
    controller.objectSearchFocus.removeListener(_focusSearch);
    _search.dispose();
    _searchFocus.dispose();
    super.dispose();
  }

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
    final objects = c.pagedVisibleObjects;
    final busy = c.isBusy('refresh-objects');
    return CallbackShortcuts(
        bindings: {
          const SingleActivator(LogicalKeyboardKey.delete): () {
            if (FocusManager.instance.primaryFocus?.context?.widget
                is! EditableText) {
              onDelete();
            }
          },
          const SingleActivator(LogicalKeyboardKey.escape):
              c.clearObjectSelection,
        },
        child: Card(
            child: Padding(
                padding: const EdgeInsets.all(12),
                child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      _toolbar(context, hasBucket: hasBucket, busy: busy),
                      ClipRect(
                          child: MotionSize(
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
                      if (busy || c.filteringObjects)
                        const LinearProgressIndicator(minHeight: 2),
                      Expanded(
                          child: objects.isEmpty &&
                                  hasBucket &&
                                  c.objects.isEmpty &&
                                  !busy &&
                                  c.objectFilterError == null
                              ? EmptyBucketState(
                                  destination:
                                      '${c.selectedBucket!.name}/${c.currentPrefix}',
                                  isRoot: c.currentPrefix.isEmpty,
                                  onUpload:
                                      c.isBusy('upload') ? null : onUpload,
                                )
                              : objects.isEmpty
                                  ? EmptyState(
                                      icon: Icons.folder_open_outlined,
                                      title: c.selectedProfile == null
                                          ? 'No connection configured'
                                          : !hasBucket
                                              ? 'No bucket open'
                                              : c.objects.isEmpty
                                                  ? 'No objects in this prefix'
                                                  : 'No matching objects',
                                      message: c.selectedProfile == null
                                          ? 'Create an endpoint profile to connect to your storage.'
                                          : !hasBucket
                                              ? 'Pick a bucket or refresh the list for this endpoint.'
                                              : c.objects.isEmpty
                                                  ? 'Upload files to get started.'
                                                  : 'Change the filter or load more keys.',
                                      action: TextButton(
                                          onPressed: c.selectedProfile == null
                                              ? () => c.selectTab(
                                                  WorkspaceTab.settings)
                                              : !hasBucket
                                                  ? c.refreshBuckets
                                                  : c.objects.isEmpty
                                                      ? onUpload
                                                      : _clearSearch,
                                          child: Text(c.selectedProfile == null
                                              ? 'Create profile'
                                              : !hasBucket
                                                  ? 'Refresh buckets'
                                                  : c.objects.isEmpty
                                                      ? 'Upload files'
                                                      : 'Clear filter')))
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
                                          c.toggleObjectSelection(o,
                                              range: range),
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

  /// One toolbar row: location, filter and actions. When objects are
  /// selected the action cluster swaps in place for selection actions, so
  /// the list below never moves.
  Widget _toolbar(BuildContext context,
      {required bool hasBucket, required bool busy}) {
    final c = controller;
    return LayoutBuilder(builder: (context, constraints) {
      final wide = constraints.maxWidth >= 900;
      Widget actionsFor(double available) => SizedBox(
          height: 48,
          child: AnimatedSwitcher(
              duration: AppMotion.duration(context,
                  enabled: c.settings.enableAnimations, milliseconds: 160),
              layoutBuilder: (current, previous) => Stack(
                  alignment: Alignment.centerRight,
                  children: [...previous, if (current != null) current]),
              child:
                  c.objectSelection.keys.isNotEmpty || c.selectedObject != null
                      ? KeyedSubtree(
                          key: const ValueKey('selection-actions'),
                          child: _selectionActions(context,
                              labeled: available >=
                                  MediaQuery.textScalerOf(context).scale(600)))
                      : KeyedSubtree(
                          key: const ValueKey('browse-actions'),
                          child: _browseActions(context,
                              hasBucket: hasBucket, busy: busy))));
      final inspector = IconButton(
          tooltip: 'Inspector',
          onPressed: onInspector,
          icon: const Icon(Icons.view_sidebar_outlined));
      if (wide) {
        // The search keeps a fixed width so swapping the action cluster
        // never resizes it; the action area scrolls if it runs out of room.
        final searchWidth =
            (constraints.maxWidth * .34).clamp(220.0, 460.0).toDouble();
        return Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Row(children: [
              ConstrainedBox(
                  constraints:
                      BoxConstraints(maxWidth: constraints.maxWidth * .25),
                  child: _breadcrumbBar(context, hasBucket: hasBucket)),
              const SizedBox(width: 8),
              SizedBox(
                  width: searchWidth,
                  child: _searchField(context, hasBucket: hasBucket)),
              const SizedBox(width: 8),
              Expanded(
                  child: LayoutBuilder(
                      builder: (context, area) => Align(
                          alignment: Alignment.centerRight,
                          child: SingleChildScrollView(
                              scrollDirection: Axis.horizontal,
                              reverse: true,
                              child: actionsFor(area.maxWidth))))),
              inspector,
            ]));
      }
      // Narrower panels: location and actions share the first row, the
      // filter spans the second. Both rows keep a fixed height.
      if (constraints.maxWidth < 560) {
        // Phones: location, filter, then a full-width action row.
        return Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(children: [
                    Expanded(
                        child: _breadcrumbBar(context, hasBucket: hasBucket)),
                    inspector,
                  ]),
                  _searchField(context, hasBucket: hasBucket),
                  const SizedBox(height: 6),
                  Align(
                      alignment: Alignment.centerLeft,
                      child: SingleChildScrollView(
                          scrollDirection: Axis.horizontal,
                          child: actionsFor(constraints.maxWidth))),
                ]));
      }
      return Padding(
          padding: const EdgeInsets.only(bottom: 6),
          child:
              Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Row(children: [
              ConstrainedBox(
                  constraints:
                      BoxConstraints(maxWidth: constraints.maxWidth * .4),
                  child: _breadcrumbBar(context, hasBucket: hasBucket)),
              Expanded(
                  child: LayoutBuilder(
                      builder: (context, area) => Align(
                          alignment: Alignment.centerRight,
                          child: SingleChildScrollView(
                              scrollDirection: Axis.horizontal,
                              reverse: true,
                              child: actionsFor(area.maxWidth))))),
              inspector,
            ]),
            const SizedBox(height: 6),
            _searchField(context, hasBucket: hasBucket),
          ]));
    });
  }

  Widget _browseActions(BuildContext context,
      {required bool hasBucket, required bool busy}) {
    final c = controller;
    return Row(mainAxisSize: MainAxisSize.min, children: [
      FilledButton.icon(
          onPressed: hasBucket && !c.isBusy('upload') ? onUpload : null,
          icon: const Icon(Icons.upload_file),
          label: const Text('Upload')),
      const SizedBox(width: 8),
      OutlinedButton.icon(
        onPressed: () => setState(() => _viewExpanded = !_viewExpanded),
        icon: Icon(_viewExpanded ? Icons.expand_less : Icons.tune),
        label: const Text('View tools'),
      ),
      IconButton(
          tooltip: busy ? 'Cancel listing' : 'Refresh object list',
          onPressed: busy
              ? () => c.cancelAction('refresh-objects')
              : hasBucket
                  ? c.refreshObjects
                  : null,
          icon: Icon(busy ? Icons.stop_circle_outlined : Icons.refresh)),
    ]);
  }

  /// Selection actions; without room for labels the same actions render as
  /// icon buttons with tooltips.
  Widget _selectionActions(BuildContext context, {required bool labeled}) {
    final c = controller;
    final theme = Theme.of(context);
    final keys = c.objectSelection.keys;
    final object = c.selectedObject;
    final String label;
    if (keys.isNotEmpty) {
      final bytes = c.objects
          .where((o) => keys.contains(o.key))
          .fold<int>(0, (sum, o) => sum + o.size);
      label = '${keys.length} selected · ${formatBytes(bytes)}';
    } else {
      label = object!.name;
    }
    final single = keys.isEmpty && object != null && !object.isFolder;
    final canDownload = keys.isNotEmpty || single;
    final canShare = single &&
        c.selectedProfile?.endpointType != EndpointProfileType.azureBlob;
    return DecoratedBox(
        decoration: BoxDecoration(
            color: theme.colorScheme.primaryContainer.withValues(alpha: .55),
            borderRadius: BorderRadius.circular(10)),
        child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              IconButton(
                  tooltip: keys.isNotEmpty ? 'Clear selection' : 'Deselect',
                  onPressed: keys.isNotEmpty
                      ? c.clearObjectSelection
                      : c.clearSelectedObject,
                  icon: const Icon(Icons.close)),
              ConstrainedBox(
                  constraints: BoxConstraints(maxWidth: labeled ? 220 : 160),
                  child: Text(label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.labelLarge?.copyWith(
                          color: theme.colorScheme.onPrimaryContainer,
                          fontWeight: FontWeight.w700))),
              const SizedBox(width: 10),
              if (labeled) ...[
                OutlinedButton.icon(
                    onPressed: canDownload && !c.isBusy('download')
                        ? c.startSampleDownload
                        : null,
                    icon: const Icon(Icons.download),
                    label: const Text('Download')),
                if (canShare) ...[
                  const SizedBox(width: 6),
                  OutlinedButton.icon(
                      onPressed: c.isBusy('presign')
                          ? null
                          : c.generateSelectedPresignedUrl,
                      icon: const Icon(Icons.link),
                      label: const Text('Share link')),
                ],
                const SizedBox(width: 2),
                TextButton.icon(
                    style: TextButton.styleFrom(
                        foregroundColor: theme.colorScheme.error),
                    onPressed: c.isBusy('delete-object') ? null : onDelete,
                    icon: const Icon(Icons.delete_outline),
                    label: const Text('Delete')),
              ] else ...[
                IconButton(
                    tooltip: 'Download',
                    onPressed: canDownload && !c.isBusy('download')
                        ? c.startSampleDownload
                        : null,
                    icon: const Icon(Icons.download)),
                if (canShare)
                  IconButton(
                      tooltip: 'Share link',
                      onPressed: c.isBusy('presign')
                          ? null
                          : c.generateSelectedPresignedUrl,
                      icon: const Icon(Icons.link)),
                IconButton(
                    tooltip: 'Delete',
                    color: theme.colorScheme.error,
                    onPressed: c.isBusy('delete-object') ? null : onDelete,
                    icon: const Icon(Icons.delete_outline)),
              ],
            ])));
  }

  /// Bucket name is the breadcrumb root, so the panel needs no separate
  /// title row.
  Widget _breadcrumbBar(BuildContext context, {required bool hasBucket}) {
    final c = controller;
    final theme = Theme.of(context);
    final parts =
        c.currentPrefix.split('/').where((p) => p.isNotEmpty).toList();
    final separator = Text('/',
        style: theme.textTheme.titleSmall
            ?.copyWith(color: theme.colorScheme.onSurfaceVariant));
    // Loose alignment keeps short paths left-aligned; long paths scroll
    // with the current folder in view.
    return Align(
        alignment: Alignment.centerLeft,
        child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            reverse: true,
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              Tooltip(
                  message: 'Go to bucket root',
                  child: TextButton(
                      style: TextButton.styleFrom(
                          padding: const EdgeInsets.symmetric(horizontal: 6)),
                      onPressed: hasBucket && parts.isNotEmpty
                          ? () => c.refreshObjects(prefix: '')
                          : null,
                      child: Text(c.selectedBucket?.name ?? 'Objects',
                          style: theme.textTheme.titleMedium?.copyWith(
                              fontWeight: FontWeight.w700,
                              color: parts.isEmpty
                                  ? theme.colorScheme.onSurface
                                  : null)))),
              for (var i = 0; i < parts.length; i++) ...[
                separator,
                TextButton(
                    style: TextButton.styleFrom(
                        padding: const EdgeInsets.symmetric(horizontal: 6)),
                    onPressed: i == parts.length - 1
                        ? null
                        : () => c.refreshObjects(
                            prefix: '${parts.take(i + 1).join('/')}/'),
                    child: Text(parts[i],
                        style: i == parts.length - 1
                            ? theme.textTheme.titleSmall?.copyWith(
                                color: theme.colorScheme.onSurface,
                                fontWeight: FontWeight.w700)
                            : null)),
              ],
              if (parts.isNotEmpty) separator,
            ])));
  }

  Widget _searchField(BuildContext context, {required bool hasBucket}) {
    final c = controller;
    return TextFormField(
        key: const ValueKey('object-search'),
        controller: _search,
        focusNode: _searchFocus,
        onChanged: (value) {
          _debounce?.cancel();
          if (c.objectFilterMode != BrowserFilterMode.prefix) {
            _debounce =
                Timer(const Duration(milliseconds: 250), () => _apply(value));
          }
        },
        enabled: hasBucket,
        decoration: InputDecoration(
            hintText: switch (c.objectFilterMode) {
              BrowserFilterMode.prefix => 'Navigate to prefix',
              BrowserFilterMode.text => 'Search loaded objects',
              BrowserFilterMode.regex => 'Regular expression',
            },
            errorText: c.objectFilterError,
            // The shortcut hint gives way to a clear button once there is
            // something to clear.
            suffixIcon: ValueListenableBuilder<TextEditingValue>(
              valueListenable: _search,
              builder: (context, value, _) => value.text.isNotEmpty && hasBucket
                  ? IconButton(
                      key: const ValueKey('object-search-clear'),
                      tooltip: 'Clear filter',
                      onPressed: _clearSearch,
                      icon: const Icon(Icons.close, size: 18))
                  : Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 12),
                      child: Center(
                        widthFactor: 1,
                        heightFactor: 1,
                        child: ExcludeSemantics(
                          child: Text(
                            Theme.of(context).platform == TargetPlatform.macOS
                                ? '⌘K'
                                : 'Ctrl K',
                            style: Theme.of(context).textTheme.labelSmall,
                          ),
                        ),
                      ),
                    ),
            ),
            prefixIconConstraints: const BoxConstraints(minHeight: 48),
            prefixIcon: Padding(
              padding: const EdgeInsets.only(left: 4, right: 10),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  PopupMenuButton<BrowserFilterMode>(
                    key: const ValueKey('object-search-mode'),
                    tooltip: 'Search mode',
                    enabled: hasBucket,
                    position: PopupMenuPosition.under,
                    offset: const Offset(0, AppMenuStyle.anchorGap),
                    popUpAnimationStyle: AppMenuStyle.animation,
                    onSelected: (mode) {
                      _debounce?.cancel();
                      c.setObjectFilterMode(mode);
                    },
                    itemBuilder: (_) => [
                      for (final (mode, label) in const [
                        (BrowserFilterMode.prefix, 'Prefix'),
                        (BrowserFilterMode.text, 'Text'),
                        (BrowserFilterMode.regex, 'Regex'),
                      ])
                        appMenuItem(
                            value: mode,
                            label: label,
                            selected: mode == c.objectFilterMode),
                    ],
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 8, vertical: 12),
                      child: Row(mainAxisSize: MainAxisSize.min, children: [
                        Text(
                            switch (c.objectFilterMode) {
                              BrowserFilterMode.prefix => 'Prefix',
                              BrowserFilterMode.text => 'Text',
                              BrowserFilterMode.regex => 'Regex',
                            },
                            style: Theme.of(context).textTheme.labelLarge),
                        const SizedBox(width: 4),
                        const Icon(Icons.expand_more, size: 16),
                      ]),
                    ),
                  ),
                  Container(
                      width: 1,
                      height: 22,
                      color: Theme.of(context).colorScheme.outlineVariant),
                ],
              ),
            )),
        onFieldSubmitted: _apply);
  }
}
