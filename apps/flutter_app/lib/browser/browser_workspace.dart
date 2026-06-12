import 'dart:io';
import 'dart:math' as math;

import 'package:desktop_drop/desktop_drop.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../controllers/app_controller.dart';
import '../logs/structured_log_list.dart';
import '../models/domain_models.dart';
import '../theme/app_theme.dart';
import '../theme/breakpoints.dart';
import '../widgets/compact_selector.dart';

const _bucketActionBarKey = ValueKey('bucket-panel-actions');
const _bucketListKey = ValueKey('bucket-panel-scroll');
const _objectListKey = ValueKey('object-panel-list');

enum _MobileBrowserSection {
  buckets,
  objects,
  inspector,
}

class BrowserWorkspace extends StatefulWidget {
  const BrowserWorkspace({
    super.key,
    required this.controller,
    required this.compact,
  });

  final AppController controller;
  final bool compact;

  @override
  State<BrowserWorkspace> createState() => _BrowserWorkspaceState();
}

class _BrowserWorkspaceState extends State<BrowserWorkspace> {
  AppController get controller => widget.controller;
  double? _pendingInspectorSize;
  _MobileBrowserSection _mobileSection = _MobileBrowserSection.buckets;

  AppSettings get _settings => controller.settings;

  bool _desktopCompact(BuildContext context) {
    return AppTheme.isDesktopPlatform(Theme.of(context).platform);
  }

  double _resolveInspectorSize(
    BuildContext context,
    BoxConstraints constraints,
    bool inspectorOnRight,
  ) {
    final desktopCompact = _desktopCompact(context);
    final rawSize =
        _pendingInspectorSize ?? _settings.browserInspectorSize.toDouble();
    if (inspectorOnRight) {
      final minSize = desktopCompact ? 260.0 : 280.0;
      final maxSize = math.max(
        minSize,
        constraints.maxWidth * (desktopCompact ? 0.38 : 0.42),
      );
      return rawSize.clamp(
        minSize,
        maxSize,
      );
    }
    final minSize = desktopCompact ? 140.0 : 160.0;
    final maxSize = math.max(
      minSize,
      constraints.maxHeight * (desktopCompact ? 0.29 : 0.32),
    );
    return rawSize.clamp(
      minSize,
      maxSize,
    );
  }

  void _updateInspectorSize(double nextSize) {
    setState(() {
      _pendingInspectorSize = nextSize;
    });
  }

  Future<void> _persistInspectorSize() async {
    final nextSize = _pendingInspectorSize?.round();
    if (nextSize == null || nextSize == _settings.browserInspectorSize) {
      return;
    }
    await controller.updateSettings(
      _settings.copyWith(browserInspectorSize: nextSize),
    );
  }

  Future<void> _pickFilesAndUpload() async {
    final picked = await FilePicker.platform.pickFiles(
      allowMultiple: true,
    );
    if (picked == null) {
      return;
    }
    final paths =
        picked.files.map((file) => file.path).whereType<String>().toList();
    if (paths.isEmpty) {
      return;
    }
    await controller.startSampleUpload(paths);
  }

  Future<void> _pickFolderAndUpload() async {
    final folderPath = await FilePicker.platform.getDirectoryPath(
      dialogTitle: 'Select folder to upload',
    );
    if (folderPath == null || folderPath.trim().isEmpty) {
      return;
    }
    final folder = Directory(folderPath);
    if (!await folder.exists()) {
      controller.showBannerMessage(
        'Selected folder is not available.',
        category: 'Transfers',
      );
      return;
    }

    final List<File> files;
    try {
      files = await folder
          .list(recursive: true, followLinks: false)
          .where((entity) => entity is File)
          .cast<File>()
          .toList();
    } on FileSystemException catch (error) {
      controller.showBannerMessage(
        'Could not read selected folder: ${error.message}',
        category: 'Transfers',
      );
      return;
    }
    files.sort((left, right) => left.path.compareTo(right.path));
    if (files.isEmpty) {
      controller.showBannerMessage(
        'Selected folder does not contain uploadable files.',
        category: 'Transfers',
      );
      return;
    }

    final folderName = _pathName(folder.path);
    final filePaths = files.map((file) => file.path).toList(growable: false);
    final objectKeyByPath = <String, String>{
      for (final file in files)
        file.path: _joinObjectKeyParts([
          folderName,
          _relativePathInside(folder.path, file.path),
        ]),
    };
    await controller.startSampleUpload(
      filePaths,
      objectKeyByPath: objectKeyByPath,
    );
  }

  Future<void> _uploadPaths(List<String> paths) async {
    final filePaths = <String>[];
    final objectKeyByPath = <String, String>{};
    for (final path in paths) {
      final type = await FileSystemEntity.type(path, followLinks: false);
      if (type == FileSystemEntityType.directory) {
        final folder = Directory(path);
        final folderName = _pathName(folder.path);
        await for (final entity
            in folder.list(recursive: true, followLinks: false)) {
          if (entity is! File) {
            continue;
          }
          filePaths.add(entity.path);
          objectKeyByPath[entity.path] = _joinObjectKeyParts([
            folderName,
            _relativePathInside(folder.path, entity.path),
          ]);
        }
      } else if (type == FileSystemEntityType.file) {
        filePaths.add(path);
      }
    }
    filePaths.sort();
    if (filePaths.isEmpty) {
      return;
    }
    await controller.startSampleUpload(
      filePaths,
      objectKeyByPath: objectKeyByPath,
    );
  }

  Future<void> _showUploadPicker(BuildContext context) async {
    final selected = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(
                leading: const Icon(Icons.file_upload_outlined),
                title: const Text('Upload files'),
                onTap: () => Navigator.of(context).pop('files'),
              ),
              ListTile(
                leading: const Icon(Icons.drive_folder_upload_outlined),
                title: const Text('Upload folder'),
                onTap: () => Navigator.of(context).pop('folder'),
              ),
            ],
          ),
        ),
      ),
    );
    if (!mounted || selected == null) {
      return;
    }
    if (selected == 'folder') {
      await _pickFolderAndUpload();
    } else {
      await _pickFilesAndUpload();
    }
  }

  String _pathName(String path) {
    final normalized = path.replaceAll('\\', '/');
    final trimmed = normalized.endsWith('/')
        ? normalized.substring(0, normalized.length - 1)
        : normalized;
    final name = trimmed.split('/').last.trim();
    return name.isEmpty ? 'folder' : name;
  }

  String _relativePathInside(String rootPath, String filePath) {
    final root = rootPath.replaceAll('\\', '/').replaceFirst(RegExp(r'/$'), '');
    final file = filePath.replaceAll('\\', '/');
    if (file.startsWith('$root/')) {
      return file.substring(root.length + 1);
    }
    return _pathName(filePath);
  }

  String _joinObjectKeyParts(List<String> parts) {
    return parts
        .expand((part) => part.replaceAll('\\', '/').split('/'))
        .map((part) => part.trim())
        .where((part) => part.isNotEmpty && part != '.')
        .join('/');
  }

  Future<void> _openBucket(BucketSummary bucket,
      {required bool compact}) async {
    await controller.setSelectedBucket(bucket);
    if (compact && mounted) {
      setState(() {
        _mobileSection = _MobileBrowserSection.objects;
      });
    }
  }

  Widget _mobileBrowserShell(BuildContext context) {
    final hasProfile = controller.selectedProfile != null;
    final hasBucket = controller.selectedBucket != null;
    final effectiveSection = !hasProfile
        ? _MobileBrowserSection.buckets
        : (!hasBucket && _mobileSection != _MobileBrowserSection.buckets)
            ? _MobileBrowserSection.buckets
            : _mobileSection;
    final duration = controller.settings.enableAnimations
        ? const Duration(milliseconds: 260)
        : Duration.zero;

    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 20),
      child: Column(
        children: [
          SizedBox(
            width: double.infinity,
            child: CompactSelector<_MobileBrowserSection>(
              selected: effectiveSection,
              expand: true,
              options: const [
                CompactSelectorOption(
                  value: _MobileBrowserSection.buckets,
                  icon: Icons.storage_outlined,
                  label: 'Buckets',
                ),
                CompactSelectorOption(
                  value: _MobileBrowserSection.objects,
                  icon: Icons.topic_outlined,
                  label: 'Objects',
                ),
                CompactSelectorOption(
                  value: _MobileBrowserSection.inspector,
                  icon: Icons.manage_search_outlined,
                  label: 'Inspect',
                ),
              ],
              onChanged: (section) {
                setState(() {
                  _mobileSection = section;
                });
              },
            ),
          ),
          const SizedBox(height: 14),
          AnimatedSwitcher(
            duration: duration,
            switchInCurve: Curves.easeOutCubic,
            switchOutCurve: Curves.easeInCubic,
            layoutBuilder: (currentChild, previousChildren) {
              return Stack(
                alignment: Alignment.topCenter,
                children: [
                  ...previousChildren,
                  if (currentChild != null) currentChild,
                ],
              );
            },
            transitionBuilder: (child, animation) {
              final curved = CurvedAnimation(
                parent: animation,
                curve: Curves.easeOutCubic,
                reverseCurve: Curves.easeInCubic,
              );
              return FadeTransition(
                opacity: curved,
                child: SlideTransition(
                  position: Tween<Offset>(
                    begin: const Offset(0, -0.04),
                    end: Offset.zero,
                  ).animate(curved),
                  child: ScaleTransition(
                    alignment: Alignment.topCenter,
                    scale: Tween<double>(
                      begin: 0.96,
                      end: 1,
                    ).animate(curved),
                    child: child,
                  ),
                ),
              );
            },
            child: KeyedSubtree(
              key: ValueKey(effectiveSection),
              child: switch (effectiveSection) {
                _MobileBrowserSection.buckets =>
                  _bucketPanel(context, compact: true),
                _MobileBrowserSection.objects =>
                  _objectPanel(context, compact: true),
                _MobileBrowserSection.inspector =>
                  _inspectorPanel(context, compact: true),
              },
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final content = LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth;
        final desktopCompact = _desktopCompact(context);
        if (width < Breakpoints.phone ||
            (!desktopCompact && width < Breakpoints.touchPhone)) {
          return _mobileBrowserShell(context);
        }

        // Tablet range (and a desktop window resized into it): keep the
        // bucket panel and object list side by side, with the inspector
        // docked below the objects so it stays reachable.
        final tablet = !Breakpoints.isDesktop(width);
        final inspectorOnRight = !tablet &&
            _settings.browserInspectorLayout == BrowserInspectorLayout.right;
        final inspectorSize =
            _resolveInspectorSize(context, constraints, inspectorOnRight);
        final roomy = width >= Breakpoints.desktopWide;
        final outerPadding =
            tablet ? 10.0 : (desktopCompact && !roomy ? 10.0 : 14.0);
        final panelGap = tablet ? 8.0 : (desktopCompact && !roomy ? 8.0 : 10.0);
        final bucketPanelWidth =
            tablet ? 252.0 : (desktopCompact && !roomy ? 284.0 : 300.0);

        return Padding(
          padding: EdgeInsets.all(outerPadding),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SizedBox(
                width: bucketPanelWidth,
                child: _bucketPanel(context, compact: false),
              ),
              SizedBox(width: panelGap),
              Expanded(
                child: inspectorOnRight
                    ? Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Expanded(
                              child: _objectPanel(context, compact: false)),
                          _resizeHandle(Axis.horizontal),
                          SizedBox(
                            width: inspectorSize,
                            child: _inspectorPanel(context, compact: false),
                          ),
                        ],
                      )
                    : Column(
                        children: [
                          Expanded(
                              child:
                                  _objectPanel(context, compact: tablet)),
                          _resizeHandle(Axis.vertical),
                          SizedBox(
                            height: inspectorSize,
                            child: _inspectorPanel(context, compact: false),
                          ),
                        ],
                      ),
              ),
            ],
          ),
        );
      },
    );

    if (Platform.isAndroid ||
        Breakpoints.isPhone(MediaQuery.sizeOf(context).width)) {
      return content;
    }

    return DropTarget(
      onDragDone: (detail) async {
        final files = detail.files.map((file) => file.path).toList();
        await _uploadPaths(files);
      },
      child: content,
    );
  }

  Future<void> _showCreatePrefixDialog(BuildContext context) async {
    final value = await showDialog<String>(
      context: context,
      builder: (context) => const _CreatePrefixDialog(),
    );

    final prefix = value?.trim();
    if (prefix == null || prefix.isEmpty) {
      return;
    }
    await controller.createFolderMarker(prefix);
  }

  Future<void> _showMobileObjectActions(BuildContext context) async {
    final hasBucket = controller.selectedBucket != null;
    final hasSelectedObject = controller.selectedObject != null;
    final rootContext = context;
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Object actions',
                style: Theme.of(context).textTheme.titleLarge,
              ),
              const SizedBox(height: 8),
              Text(
                'Choose an action for the current bucket or selected object.',
                style: Theme.of(context).textTheme.bodyMedium,
              ),
              const SizedBox(height: 18),
              Wrap(
                spacing: 10,
                runSpacing: 10,
                children: [
                  OutlinedButton.icon(
                    onPressed: hasBucket
                        ? () {
                            Navigator.of(context).pop();
                            controller.refreshObjects();
                          }
                        : null,
                    icon: const Icon(Icons.refresh),
                    label: const Text('Refresh'),
                  ),
                  OutlinedButton.icon(
                    onPressed: () {
                      Navigator.of(context).pop();
                      _showInspectorDialog(rootContext);
                    },
                    icon: const Icon(Icons.info_outline),
                    label: const Text('Inspector'),
                  ),
                  OutlinedButton.icon(
                    onPressed: hasBucket
                        ? () {
                            Navigator.of(context).pop();
                            _showCreatePrefixDialog(rootContext);
                          }
                        : null,
                    icon: const Icon(Icons.create_new_folder_outlined),
                    label: const Text('Create prefix'),
                  ),
                  OutlinedButton.icon(
                    onPressed: hasSelectedObject
                        ? () {
                            Navigator.of(context).pop();
                            controller.deleteSelectedObject();
                          }
                        : null,
                    icon: const Icon(Icons.delete_outline),
                    label: const Text('Delete'),
                  ),
                  OutlinedButton.icon(
                    onPressed: hasBucket
                        ? () {
                            Navigator.of(context).pop();
                            controller.showAllObjectsNow();
                          }
                        : null,
                    icon: const Icon(Icons.unfold_more),
                    label: const Text('Show loaded rows'),
                  ),
                  OutlinedButton.icon(
                    onPressed: hasBucket &&
                            controller.objectCursor.hasMore &&
                            !controller.isBusy('refresh-objects')
                        ? () {
                            Navigator.of(context).pop();
                            controller.listAllObjectsForCurrentBucket();
                          }
                        : null,
                    icon: const Icon(Icons.playlist_add_check),
                    label: const Text('List all'),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              SwitchListTile(
                value: controller.flatView,
                onChanged: hasBucket
                    ? (value) {
                        Navigator.of(context).pop();
                        controller.toggleFlatView(value);
                      }
                    : null,
                contentPadding: EdgeInsets.zero,
                title: const Text('Flat view'),
                subtitle: const Text('Show objects as a single list.'),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _showInspectorDialog(BuildContext context) async {
    await showDialog<void>(
      context: context,
      builder: (context) => Dialog(
        insetPadding: const EdgeInsets.all(24),
        clipBehavior: Clip.antiAlias,
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxWidth: math.min(MediaQuery.sizeOf(context).width - 48, 920),
            maxHeight: MediaQuery.sizeOf(context).height * 0.88,
          ),
          child: _inspectorPanel(context, compact: false),
        ),
      ),
    );
  }

  Widget _resizeHandle(Axis axis) {
    final isHorizontal = axis == Axis.horizontal;
    final desktopCompact = _desktopCompact(context);
    return MouseRegion(
      cursor: isHorizontal
          ? SystemMouseCursors.resizeLeftRight
          : SystemMouseCursors.resizeUpDown,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onPanUpdate: (details) {
          final current = _pendingInspectorSize?.toDouble() ??
              _settings.browserInspectorSize.toDouble();
          _updateInspectorSize(
            current + (isHorizontal ? -details.delta.dx : -details.delta.dy),
          );
        },
        onPanEnd: (_) => _persistInspectorSize(),
        child: SizedBox(
          width: isHorizontal ? (desktopCompact ? 10 : 14) : double.infinity,
          height: isHorizontal ? double.infinity : (desktopCompact ? 10 : 14),
          child: Center(
            child: Container(
              width: isHorizontal ? (desktopCompact ? 3 : 4) : 48,
              height: isHorizontal ? (desktopCompact ? 48 : 56) : 3,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(999),
                color: Theme.of(context).colorScheme.outlineVariant,
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _bucketPanel(BuildContext context, {required bool compact}) {
    return BrowserBucketPanel(
      controller: controller,
      compact: compact,
      onCreateBucket: () => _showCreateBucketDialog(context),
      onDeleteBucket: (bucketName, {force = false}) =>
          _confirmDeleteBucket(context, bucketName, force: force),
      onEditBucketLifecycle: (bucket) => _showJsonEditorDialog(
        context,
        title: 'Lifecycle JSON',
        initialValue: controller.adminState?.bucketName == bucket.name
            ? controller.adminState!.lifecycleJson
            : '{\n  "Rules": []\n}',
        onSave: controller.saveBucketLifecycle,
      ),
      onEditBucketPolicy: (bucket) => _showJsonEditorDialog(
        context,
        title: 'Policy JSON',
        initialValue: controller.adminState?.bucketName == bucket.name
            ? controller.adminState!.policyJson
            : '{}',
        onSave: controller.saveBucketPolicy,
      ),
      onEditBucketEncryption: (bucket) => _showJsonEditorDialog(
        context,
        title: 'Encryption JSON',
        initialValue: controller.adminState?.bucketName == bucket.name
            ? controller.adminState!.encryptionJson
            : '{}',
        onSave: controller.saveBucketEncryption,
      ),
      onEditBucketTags: (bucket) => _showTagEditorDialog(
        context,
        initialTags: controller.adminState?.bucketName == bucket.name
            ? controller.adminState!.tags
            : const <String, String>{},
      ),
      onToggleBucketVersioning: (bucket, enabled) async {
        if (controller.selectedBucket?.name != bucket.name) {
          await controller.setSelectedBucket(bucket);
        }
        await controller.setBucketVersioning(enabled);
      },
      onOpenBucket: (bucket) => _openBucket(bucket, compact: compact),
      onCopyBucket: (bucket) => _showCopyBucketDialog(context, bucket),
      inlineSpinnerBuilder: _inlineSpinner,
      inlineStatBuilder: _inlineStat,
    );
  }

  Widget _objectPanel(BuildContext context, {required bool compact}) {
    final width = MediaQuery.sizeOf(context).width;
    final phone = Breakpoints.isPhone(width);
    final mobileTablet = !phone && Platform.isAndroid;
    final desktopCompact = _desktopCompact(context);
    final compactDesktop = compact && !phone;
    final denseObjectControls = phone || mobileTablet || desktopCompact;
    final availableWidth = width - (phone ? 32 : (desktopCompact ? 48 : 64));
    final phonePanelHeight =
        (MediaQuery.sizeOf(context).height * 0.78).clamp(560.0, 920.0);
    final hasProfile = controller.selectedProfile != null;
    final hasBucket = controller.selectedBucket != null;
    final hasSelectedObject = controller.selectedObject != null;
    final objects = controller.pagedVisibleObjects;
    final filteredObjectCount = controller.visibleObjects.length;
    final loadedObjectCount = controller.objects.length;
    final currentPrefix = controller.currentPrefix;
    final isRefreshingObjects = controller.isBusy('refresh-objects');
    final isUploading = controller.isBusy('upload');
    final isDownloading = controller.isBusy('download');
    final isDeleting = controller.isBusy('delete-object');
    final isSelectingObject = controller.isBusy('select-object');
    final panelPadding = denseObjectControls ? 12.0 : 16.0;
    final controlSpacing = denseObjectControls ? 8.0 : 12.0;
    final mobileControlSpacing = phone ? 8.0 : controlSpacing;
    final mobileFilterWidth = (availableWidth * 0.34).clamp(112.0, 156.0);

    Widget filterModeControl({double? width}) {
      final child = DropdownButtonFormField<BrowserFilterMode>(
        initialValue: controller.objectFilterMode,
        isExpanded: true,
        decoration: const InputDecoration(
          labelText: 'Filter',
        ),
        items: const [
          DropdownMenuItem(
            value: BrowserFilterMode.prefix,
            child: Text('Prefix'),
          ),
          DropdownMenuItem(
            value: BrowserFilterMode.text,
            child: Text('Text'),
          ),
          DropdownMenuItem(
            value: BrowserFilterMode.regex,
            child: Text('Regex'),
          ),
        ],
        onChanged: hasBucket
            ? (value) {
                if (value != null) {
                  controller.setObjectFilterMode(value);
                }
              }
            : null,
      );
      return width == null ? child : SizedBox(width: width, child: child);
    }

    Widget filterValueControl({double? width}) {
      final child = TextFormField(
        key: ValueKey(
          'object-filter-${controller.objectFilterMode.name}-${controller.objectFilterValue}',
        ),
        initialValue: controller.objectFilterValue,
        enabled: hasBucket,
        decoration: InputDecoration(
          labelText: switch (controller.objectFilterMode) {
            BrowserFilterMode.prefix => 'Prefix',
            BrowserFilterMode.text => 'Search text',
            BrowserFilterMode.regex => 'Regex',
          },
          prefixIcon: Icon(
            switch (controller.objectFilterMode) {
              BrowserFilterMode.prefix => Icons.folder_open_outlined,
              BrowserFilterMode.text => Icons.search,
              BrowserFilterMode.regex => Icons.code,
            },
          ),
        ),
        onFieldSubmitted: (value) async {
          await controller.applyObjectFilter(value);
        },
      );
      return width == null ? child : SizedBox(width: width, child: child);
    }

    Widget sortFieldControl({double? width}) {
      final child = DropdownButtonFormField<BrowserObjectSortField>(
        initialValue: controller.objectSortField,
        isExpanded: true,
        decoration: const InputDecoration(
          labelText: 'Sort by',
        ),
        items: const [
          DropdownMenuItem(
            value: BrowserObjectSortField.lastModified,
            child: Text('Last modified'),
          ),
          DropdownMenuItem(
            value: BrowserObjectSortField.name,
            child: Text('Name'),
          ),
          DropdownMenuItem(
            value: BrowserObjectSortField.size,
            child: Text('Object size'),
          ),
          DropdownMenuItem(
            value: BrowserObjectSortField.contentType,
            child: Text('Content type'),
          ),
        ],
        onChanged: hasBucket
            ? (value) {
                if (value != null) {
                  controller.setObjectSortField(value);
                }
              }
            : null,
      );
      return width == null ? child : SizedBox(width: width, child: child);
    }

    Widget sortDirectionButton({bool compactButton = false}) {
      return IconButton(
        tooltip: controller.objectSortDescending
            ? 'Sort descending'
            : 'Sort ascending',
        onPressed: hasBucket ? controller.toggleObjectSortDirection : null,
        icon: Icon(
          controller.objectSortDescending
              ? Icons.arrow_downward
              : Icons.arrow_upward,
        ),
        constraints: compactButton
            ? const BoxConstraints.tightFor(width: 40, height: 40)
            : null,
        padding: compactButton ? EdgeInsets.zero : null,
        visualDensity:
            compactButton ? VisualDensity.compact : VisualDensity.standard,
      );
    }

    Widget mobileUploadButton() {
      return IconButton.filled(
        tooltip: isUploading ? 'Uploading...' : 'Upload',
        onPressed:
            hasBucket && !isUploading ? () => _showUploadPicker(context) : null,
        icon: isUploading ? _inlineSpinner() : const Icon(Icons.upload_file),
        constraints: const BoxConstraints.tightFor(width: 40, height: 40),
        padding: EdgeInsets.zero,
        visualDensity: VisualDensity.compact,
      );
    }

    Widget mobileDownloadButton() {
      return IconButton.filledTonal(
        tooltip: isDownloading ? 'Downloading...' : 'Download',
        onPressed: hasSelectedObject && !isDownloading
            ? controller.startSampleDownload
            : null,
        icon: isDownloading ? _inlineSpinner() : const Icon(Icons.download),
        constraints: const BoxConstraints.tightFor(width: 40, height: 40),
        padding: EdgeInsets.zero,
        visualDensity: VisualDensity.compact,
      );
    }

    Widget compactInspectorButton() {
      return IconButton.filledTonal(
        tooltip: 'Inspector',
        onPressed: () => _showInspectorDialog(context),
        icon: const Icon(Icons.info_outline),
        constraints: const BoxConstraints.tightFor(width: 40, height: 40),
        padding: EdgeInsets.zero,
        visualDensity: VisualDensity.compact,
      );
    }

    final Widget listView = objects.isEmpty
        ? Center(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Text(
                hasBucket
                    ? 'No objects were returned for this bucket and prefix.'
                    : 'Select a bucket to load objects.',
                textAlign: TextAlign.center,
              ),
            ),
          )
        : KeyedSubtree(
            key: _objectListKey,
            child: _ObjectTable(
              objects: objects,
              selectedKey: controller.selectedObject?.key,
              contentTypeFor: controller.objectContentType,
              onSelect: controller.setSelectedObject,
            ),
          );

    final panel = Card(
      clipBehavior: Clip.antiAlias,
      child: Padding(
        padding: EdgeInsets.all(panelPadding),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  Icons.folder_copy_outlined,
                  color: Theme.of(context).colorScheme.primary,
                  size: 22,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    controller.selectedBucket?.name ?? 'Objects',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                ),
                if (hasBucket)
                  Chip(
                    visualDensity: VisualDensity.compact,
                    label: Text('$filteredObjectCount objects'),
                  ),
              ],
            ),
            const SizedBox(height: 14),
            if (!hasProfile)
              const Text(
                'Create and select an endpoint profile to browse objects.',
              )
            else if (!hasBucket)
              const Text(
                'Select a bucket to browse objects.',
              )
            else
              Wrap(
                spacing: denseObjectControls ? 6 : 8,
                runSpacing: denseObjectControls ? 6 : 8,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  ActionChip(
                    visualDensity: denseObjectControls
                        ? VisualDensity.compact
                        : VisualDensity.standard,
                    avatar: const Icon(Icons.home_outlined, size: 16),
                    label: const Text('Root'),
                    onPressed: () => controller.refreshObjects(prefix: ''),
                  ),
                  if (currentPrefix.isNotEmpty)
                    ActionChip(
                      visualDensity: denseObjectControls
                          ? VisualDensity.compact
                          : VisualDensity.standard,
                      avatar:
                          const Icon(Icons.subdirectory_arrow_left, size: 16),
                      label: Text(currentPrefix),
                      onPressed: controller.navigateUp,
                    ),
                ],
              ),
            const SizedBox(height: 12),
            if (phone || compactDesktop)
              Column(
                children: [
                  Row(
                    children: [
                      filterModeControl(width: mobileFilterWidth),
                      SizedBox(width: mobileControlSpacing),
                      Expanded(child: filterValueControl()),
                    ],
                  ),
                  SizedBox(height: mobileControlSpacing),
                  Row(
                    children: [
                      Expanded(child: sortFieldControl()),
                      SizedBox(width: mobileControlSpacing),
                      sortDirectionButton(compactButton: true),
                      SizedBox(width: mobileControlSpacing),
                      mobileUploadButton(),
                      SizedBox(width: mobileControlSpacing),
                      mobileDownloadButton(),
                      SizedBox(width: mobileControlSpacing),
                      if (compactDesktop) ...[
                        compactInspectorButton(),
                        SizedBox(width: mobileControlSpacing),
                      ],
                      IconButton.filledTonal(
                        tooltip: 'More actions',
                        onPressed: hasBucket || compactDesktop
                            ? () => _showMobileObjectActions(context)
                            : null,
                        icon: const Icon(Icons.tune),
                        constraints: const BoxConstraints.tightFor(
                            width: 40, height: 40),
                        padding: EdgeInsets.zero,
                        visualDensity: VisualDensity.compact,
                      ),
                    ],
                  ),
                ],
              )
            else
              Wrap(
                spacing: controlSpacing,
                runSpacing: controlSpacing,
                children: [
                  filterModeControl(width: denseObjectControls ? 144 : 168),
                  filterValueControl(width: denseObjectControls ? 200 : 240),
                  sortFieldControl(width: denseObjectControls ? 176 : 220),
                  sortDirectionButton(),
                  FilledButton.icon(
                    onPressed: hasBucket && !isUploading
                        ? () => _showUploadPicker(context)
                        : null,
                    icon: isUploading
                        ? _inlineSpinner()
                        : const Icon(Icons.upload_file),
                    label: Text(isUploading ? 'Uploading...' : 'Upload'),
                  ),
                  OutlinedButton.icon(
                    onPressed: hasSelectedObject && !isDownloading
                        ? controller.startSampleDownload
                        : null,
                    icon: isDownloading
                        ? _inlineSpinner()
                        : const Icon(Icons.download),
                    label: Text(isDownloading ? 'Downloading...' : 'Download'),
                  ),
                  OutlinedButton.icon(
                    onPressed: hasSelectedObject && !isDeleting
                        ? controller.deleteSelectedObject
                        : null,
                    icon: isDeleting
                        ? _inlineSpinner()
                        : const Icon(Icons.delete_outline),
                    label: Text(isDeleting ? 'Deleting...' : 'Delete'),
                  ),
                  OutlinedButton.icon(
                    onPressed: hasBucket
                        ? () => _showCreatePrefixDialog(context)
                        : null,
                    icon: const Icon(Icons.create_new_folder_outlined),
                    label: const Text('Create prefix'),
                  ),
                  OutlinedButton.icon(
                    onPressed: hasBucket ? controller.showAllObjectsNow : null,
                    icon: const Icon(Icons.unfold_more),
                    label: const Text('Show loaded rows'),
                  ),
                  FilterChip(
                    selected: controller.flatView,
                    onSelected: hasBucket ? controller.toggleFlatView : null,
                    showCheckmark: false,
                    avatar: Icon(
                      controller.flatView
                          ? Icons.view_list
                          : Icons.view_list_outlined,
                      size: 18,
                    ),
                    label: const Text('Flat view'),
                  ),
                  if (isRefreshingObjects)
                    OutlinedButton.icon(
                      onPressed: controller.cancelListing,
                      icon: const Icon(Icons.stop_circle_outlined, size: 18),
                      label: const Text('Cancel'),
                    )
                  else
                    IconButton(
                      tooltip: 'Refresh object list',
                      onPressed: hasBucket ? controller.refreshObjects : null,
                      icon: const Icon(Icons.refresh),
                    ),
                ],
              ),
            const SizedBox(height: 10),
            if (isRefreshingObjects || isSelectingObject)
              const Padding(
                padding: EdgeInsets.only(bottom: 12),
                child: LinearProgressIndicator(),
              ),
            if (hasBucket)
              Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: Wrap(
                  spacing: controlSpacing,
                  runSpacing: controlSpacing,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    Text(
                      _objectListingStatus(
                        filteredObjectCount: filteredObjectCount,
                        loadedObjectCount: loadedObjectCount,
                        compact: phone || compactDesktop,
                      ),
                    ),
                    if (!compactDesktop) ...[
                      FilterChip(
                        selected: controller.listAllKeys,
                        onSelected: hasBucket &&
                                controller.objectCursor.hasMore &&
                                !isRefreshingObjects
                            ? (_) => controller.listAllObjectsForCurrentBucket()
                            : null,
                        avatar: Icon(
                          controller.objectCursor.hasMore
                              ? Icons.playlist_add_check
                              : Icons.done_all,
                          size: 18,
                        ),
                        label: Text(
                          controller.objectCursor.hasMore
                              ? 'List all'
                              : 'All listed',
                        ),
                      ),
                      if (!controller.showAllObjects &&
                          controller.objectPageCount > 1) ...[
                        SizedBox(
                          width: 180,
                          child: DropdownButtonFormField<int>(
                            initialValue: controller.objectPage
                                .clamp(1, controller.objectPageCount)
                                .toInt(),
                            decoration:
                                const InputDecoration(labelText: 'Page'),
                            items: List<DropdownMenuItem<int>>.generate(
                              controller.objectPageCount,
                              (index) => DropdownMenuItem<int>(
                                value: index + 1,
                                child: Text(
                                  'Page ${index + 1}',
                                ),
                              ),
                            ),
                            onChanged: (value) {
                              if (value != null) {
                                controller.setObjectPage(value);
                              }
                            },
                          ),
                        ),
                        OutlinedButton.icon(
                          onPressed: controller.objectPage > 1
                              ? controller.previousObjectPage
                              : null,
                          icon: const Icon(Icons.chevron_left),
                          label: const Text('Prev'),
                        ),
                        OutlinedButton.icon(
                          onPressed:
                              controller.objectPage < controller.objectPageCount
                                  ? controller.nextObjectPage
                                  : null,
                          icon: const Icon(Icons.chevron_right),
                          label: const Text('Next'),
                        ),
                      ],
                      if (controller.showAllObjects)
                        OutlinedButton.icon(
                          onPressed: () => controller.setShowAllObjects(false),
                          icon: const Icon(Icons.grid_view_outlined),
                          label: const Text('Use pages'),
                        ),
                    ],
                    Text(
                      '${AppController.objectPageSize} per page',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ],
                ),
              ),
            if (!phone && !Platform.isAndroid && !compactDesktop) ...[
              Container(
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.surface,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(
                    color: Theme.of(context).colorScheme.outlineVariant,
                  ),
                ),
                padding: EdgeInsets.all(desktopCompact ? 10 : 12),
                child: Row(
                  children: [
                    const Icon(Icons.cloud_upload_outlined),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(hasBucket
                          ? (Platform.isAndroid
                              ? 'Use the system picker or share sheet to add files on Android.'
                              : 'Drag and drop files here to upload them into the current bucket prefix.')
                          : 'Uploads are enabled after you select an endpoint profile and bucket.'),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 12),
            ],
            if (phone || compactDesktop)
              Expanded(child: listView)
            else if (compact)
              SizedBox(
                height: (MediaQuery.sizeOf(context).height *
                        (mobileTablet ? 0.58 : 0.42))
                    .clamp(mobileTablet ? 360.0 : 280.0,
                        mobileTablet ? 760.0 : 520.0),
                child: listView,
              )
            else
              Expanded(child: listView),
          ],
        ),
      ),
    );

    if (phone) {
      return SizedBox(
        height: phonePanelHeight,
        child: panel,
      );
    }

    return panel;
  }

  String _objectListingStatus({
    required int filteredObjectCount,
    required int loadedObjectCount,
    bool compact = false,
  }) {
    if (compact) {
      final range = controller.showAllObjects
          ? 'All $filteredObjectCount loaded'
          : '${controller.currentObjectPageStart}-${controller.currentObjectPageEnd} of $filteredObjectCount';
      if (filteredObjectCount == loadedObjectCount) {
        return range;
      }
      return '$range - $loadedObjectCount total';
    }

    final range = controller.showAllObjects
        ? 'Showing all $filteredObjectCount loaded'
        : 'Showing ${controller.currentObjectPageStart}-${controller.currentObjectPageEnd} of $filteredObjectCount loaded';
    final listingState =
        controller.objectCursor.hasMore ? 'more available' : 'all loaded';
    if (filteredObjectCount == loadedObjectCount) {
      return '$range - $listingState';
    }
    return '$range - $loadedObjectCount loaded total - $listingState';
  }

  Widget _inspectorPanel(BuildContext context, {required bool compact}) {
    final phone = Breakpoints.isPhone(MediaQuery.sizeOf(context).width);
    // Object versioning and presigned URLs are S3-only features.
    final isAzure = controller.selectedProfile?.endpointType ==
        EndpointProfileType.azureBlob;
    final availableTabs = BrowserInspectorTab.values
        .where(
          (entry) =>
              !isAzure ||
              (entry != BrowserInspectorTab.versions &&
                  entry != BrowserInspectorTab.presign),
        )
        .toList();
    final tab = availableTabs.contains(controller.inspectorTab)
        ? controller.inspectorTab
        : BrowserInspectorTab.objectDetails;
    final desktopCompact = _desktopCompact(context);
    final panelBody = AnimatedSwitcher(
      duration: const Duration(milliseconds: 220),
      child: switch (tab) {
        BrowserInspectorTab.bucketAdmin => _bucketAdminView(context),
        BrowserInspectorTab.bucketInfo => _bucketInfoView(context),
        BrowserInspectorTab.objectDetails => _objectDetailsView(context),
        BrowserInspectorTab.versions => _versionsView(context),
        BrowserInspectorTab.presign => _presignView(context),
        BrowserInspectorTab.tools => _toolsView(context),
        BrowserInspectorTab.eventsAndDebug => _eventsAndDebugView(context),
      },
    );

    return Card(
      clipBehavior: Clip.antiAlias,
      child: Padding(
        padding: EdgeInsets.all(desktopCompact && !phone ? 12 : 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Inspector', style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 12),
            CompactSelector<BrowserInspectorTab>(
              selected: tab,
              wrap: true,
              dense: true,
              onChanged: controller.setInspectorTab,
              options: availableTabs
                  .map(
                    (entry) => CompactSelectorOption(
                      value: entry,
                      icon: _inspectorIcon(entry),
                      label: _inspectorLabel(entry),
                    ),
                  )
                  .toList(),
            ),
            const SizedBox(height: 12),
            if (phone)
              panelBody
            else if (compact)
              SizedBox(
                height: (MediaQuery.sizeOf(context).height * 0.62)
                    .clamp(420.0, 920.0),
                child: panelBody,
              )
            else
              Expanded(child: panelBody),
          ],
        ),
      ),
    );
  }

  IconData _inspectorIcon(BrowserInspectorTab entry) {
    return switch (entry) {
      BrowserInspectorTab.bucketAdmin => Icons.admin_panel_settings_outlined,
      BrowserInspectorTab.bucketInfo => Icons.info_outline,
      BrowserInspectorTab.objectDetails => Icons.article_outlined,
      BrowserInspectorTab.versions => Icons.history,
      BrowserInspectorTab.presign => Icons.link,
      BrowserInspectorTab.tools => Icons.build_circle_outlined,
      BrowserInspectorTab.eventsAndDebug => Icons.bug_report_outlined,
    };
  }

  String _inspectorLabel(BrowserInspectorTab entry) {
    return switch (entry) {
      BrowserInspectorTab.bucketAdmin => 'Bucket config',
      BrowserInspectorTab.bucketInfo => 'Bucket info',
      BrowserInspectorTab.objectDetails => 'Object',
      BrowserInspectorTab.versions => 'Versions',
      BrowserInspectorTab.presign => 'Presign',
      BrowserInspectorTab.tools => 'Tools',
      BrowserInspectorTab.eventsAndDebug => 'Events & Debug',
    };
  }

  Widget _bucketAdminView(BuildContext context) {
    final admin = controller.adminState;
    if (admin == null) {
      return const Center(
          child: Text('Select a bucket to inspect configuration details.'));
    }

    return _adaptivePanelListView(
      context,
      key: const ValueKey('bucket-admin'),
      children: [
        Text(
          'Manage bucket actions from the bucket list context menu.',
          style: Theme.of(context).textTheme.bodyMedium,
        ),
        const SizedBox(height: 12),
        _inlineStat('Selected bucket', admin.bucketName),
        _inlineStat(
          'Action surface',
          'Right-click the bucket or use the overflow menu in the bucket list.',
        ),
        const Divider(height: 28),
        Text('Lifecycle JSON', style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 8),
        _jsonBlock(admin.lifecycleJson),
        const SizedBox(height: 12),
        Text('Policy JSON', style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 8),
        _jsonBlock(admin.policyJson),
        const SizedBox(height: 12),
        Text('CORS JSON', style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 8),
        _jsonBlock(admin.corsJson),
        const SizedBox(height: 12),
        Text('Encryption JSON', style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 8),
        _jsonBlock(admin.encryptionJson),
      ],
    );
  }

  Widget _bucketInfoView(BuildContext context) {
    final bucket = controller.selectedBucket;
    final admin = controller.adminState;
    if (bucket == null) {
      return const Center(
        child: Text('Select a bucket to inspect bucket details.'),
      );
    }

    return _adaptivePanelListView(
      context,
      key: const ValueKey('bucket-info'),
      children: [
        Text(bucket.name, style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 12),
        if (admin != null)
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              _pill('Versioning', admin.versioningEnabled),
              _pill('Object lock', admin.objectLockEnabled),
              _pill('Lifecycle', admin.lifecycleEnabled),
              _pill('Policy', admin.policyAttached),
              _pill('CORS', admin.corsEnabled),
              _pill('Encryption', admin.encryptionEnabled),
            ],
          ),
        if (admin != null) const SizedBox(height: 12),
        _inlineStat('Bucket name', bucket.name),
        _inlineStat(
            'Region', bucket.region.isEmpty ? 'Unknown' : bucket.region),
        _inlineStat(
          'Created',
          bucket.createdAt == null
              ? 'Unknown'
              : _formatDateTime(bucket.createdAt!),
        ),
        _inlineStat('Approx objects', '~${bucket.objectCountHint}'),
        _inlineStat(
          'Current prefix',
          controller.currentPrefix.isEmpty ? 'Root' : controller.currentPrefix,
        ),
        _inlineStat('Visible objects', '${controller.visibleObjects.length}'),
        if (admin != null) ...[
          _inlineStat('Versioning state', admin.versioningStatus),
          if (admin.objectLockEnabled)
            _inlineStat(
              'Object lock',
              admin.objectLockMode == null
                  ? 'Enabled'
                  : '${admin.objectLockMode} - ${admin.objectLockRetentionDays ?? 0} day retention',
            ),
          _inlineStat('Encryption', admin.encryptionSummary),
          _inlineStat('Bucket tags', '${admin.tags.length} tags'),
          _inlineStat(
              'Lifecycle rules', '${admin.lifecycleRules.length} rules'),
          _inlineStat(
            'Bucket policy',
            admin.policyAttached ? 'Attached' : 'Not attached',
          ),
          _inlineStat(
            'CORS',
            admin.corsEnabled ? 'Configured' : 'Not configured',
          ),
        ] else
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(
              'Bucket configuration details are still loading.',
              style: Theme.of(context).textTheme.bodyMedium,
            ),
          ),
        const Divider(height: 28),
        Text('Bucket tags', style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 8),
        if (admin == null)
          const Text('Loading tags...')
        else if (admin.tags.isEmpty)
          const Text('No bucket tags configured.')
        else
          ...admin.tags.entries.map(
            (entry) => ListTile(
              contentPadding: EdgeInsets.zero,
              dense: true,
              title: Text(entry.key),
              trailing: Text(entry.value),
            ),
          ),
        const Divider(height: 28),
        Text('Lifecycle rules', style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 8),
        if (admin == null)
          const Text('Loading lifecycle rules...')
        else if (admin.lifecycleRules.isEmpty)
          const Text('No lifecycle rules configured.')
        else
          ...admin.lifecycleRules.map(
            (rule) => Card(
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Text(
                          rule.id,
                          style: Theme.of(context).textTheme.titleSmall,
                        ),
                        const Spacer(),
                        Chip(
                          label: Text(rule.enabled ? 'Enabled' : 'Disabled'),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Text('Prefix: ${rule.prefix}'),
                    if (rule.expirationDays != null)
                      Text('Expiration: ${rule.expirationDays} days'),
                    if (rule.transitionStorageClass != null)
                      Text(
                        'Transition: ${rule.transitionStorageClass} after ${rule.transitionDays} days',
                      ),
                    if (rule.nonCurrentExpirationDays != null)
                      Text(
                        'Non-current expiration: ${rule.nonCurrentExpirationDays} days',
                      ),
                    if (rule.abortIncompleteMultipartUploadDays != null)
                      Text(
                        'Abort incomplete multipart uploads after ${rule.abortIncompleteMultipartUploadDays} days',
                      ),
                  ],
                ),
              ),
            ),
          ),
      ],
    );
  }

  Widget _objectDetailsView(BuildContext context) {
    final details = controller.selectedObjectDetails;
    final object = controller.selectedObject;
    if (details == null || object == null) {
      return const Center(
          child:
              Text('Select an object to inspect metadata, headers, and tags.'));
    }

    return _adaptivePanelListView(
      context,
      key: const ValueKey('object-details'),
      children: [
        _inlineStat('Key', object.key),
        _inlineStat('Storage class', object.storageClass),
        _inlineStat('Last modified', _formatDateTime(object.modifiedAt)),
        _inlineStat('Size', _formatBytes(object.size)),
        const Divider(height: 28),
        Text('Metadata', style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 8),
        ...details.metadata.entries.map(
          (entry) => ListTile(
            contentPadding: EdgeInsets.zero,
            dense: true,
            title: Text(entry.key),
            trailing: Text(entry.value),
          ),
        ),
        const Divider(height: 28),
        Text('Headers', style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 8),
        ...details.headers.entries.map(
          (entry) => ListTile(
            contentPadding: EdgeInsets.zero,
            dense: true,
            title: Text(entry.key),
            trailing: Text(entry.value),
          ),
        ),
        const Divider(height: 28),
        Text('Tags', style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 8),
        ...details.tags.entries.map(
          (entry) => ListTile(
            contentPadding: EdgeInsets.zero,
            dense: true,
            title: Text(entry.key),
            trailing: Text(entry.value),
          ),
        ),
      ],
    );
  }

  Widget _versionsView(BuildContext context) {
    final options = controller.versionBrowserOptions;
    final versions = controller.visibleVersions;
    final hasSelectedObject = controller.selectedObject != null;

    return _adaptivePanelListView(
      context,
      key: const ValueKey('versions'),
      children: [
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            FilledButton.icon(
              onPressed: () {
                controller.updateVersionBrowserOptions(
                  options.copyWith(
                    filterMode: BrowserFilterMode.prefix,
                    filterValue: '',
                  ),
                );
              },
              icon: const Icon(Icons.visibility_outlined),
              label: const Text('Show all versions'),
            ),
            OutlinedButton.icon(
              onPressed: controller.refreshObjects,
              icon: const Icon(Icons.refresh),
              label: const Text('Refresh versions'),
            ),
            OutlinedButton.icon(
              onPressed:
                  hasSelectedObject ? controller.startSampleDownload : null,
              icon: const Icon(Icons.download),
              label: const Text('Download selected'),
            ),
            OutlinedButton.icon(
              onPressed:
                  hasSelectedObject ? controller.deleteSelectedObject : null,
              icon: const Icon(Icons.delete_outline),
              label: const Text('Delete selected'),
            ),
          ],
        ),
        const SizedBox(height: 12),
        if (!hasSelectedObject)
          const Padding(
            padding: EdgeInsets.only(bottom: 12),
            child:
                Text('Showing all versioned objects in the selected bucket.'),
          ),
        Row(
          children: [
            Expanded(
              flex: 2,
              child: DropdownButtonFormField<BrowserFilterMode>(
                initialValue: options.filterMode,
                decoration: const InputDecoration(labelText: 'Filter mode'),
                items: const [
                  DropdownMenuItem(
                    value: BrowserFilterMode.prefix,
                    child: Text('Prefix'),
                  ),
                  DropdownMenuItem(
                    value: BrowserFilterMode.text,
                    child: Text('Text'),
                  ),
                  DropdownMenuItem(
                    value: BrowserFilterMode.regex,
                    child: Text('Regex'),
                  ),
                ],
                onChanged: (value) {
                  if (value != null) {
                    controller.updateVersionBrowserOptions(
                      options.copyWith(filterMode: value),
                    );
                  }
                },
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              flex: 3,
              child: TextFormField(
                key: ValueKey(
                  'version-filter-${options.filterMode.name}-${options.filterValue}',
                ),
                initialValue: options.filterValue,
                decoration: InputDecoration(
                  labelText: switch (options.filterMode) {
                    BrowserFilterMode.prefix => 'Version filter (prefix)',
                    BrowserFilterMode.text => 'Version filter (text)',
                    BrowserFilterMode.regex => 'Version filter (regex)',
                  },
                  prefixIcon: const Icon(Icons.filter_alt_outlined),
                ),
                onFieldSubmitted: (value) {
                  controller.updateVersionBrowserOptions(
                    options.copyWith(filterValue: value),
                  );
                },
              ),
            ),
          ],
        ),
        SwitchListTile(
          value: options.showVersions,
          onChanged: (value) {
            controller.updateVersionBrowserOptions(
              options.copyWith(showVersions: value),
            );
          },
          title: const Text('Show versions'),
        ),
        SwitchListTile(
          value: options.showDeleteMarkers,
          onChanged: (value) {
            controller.updateVersionBrowserOptions(
              options.copyWith(showDeleteMarkers: value),
            );
          },
          title: const Text('Show delete markers'),
        ),
        ListTile(
          contentPadding: EdgeInsets.zero,
          title: Text('Displayed entries: ${controller.displayedVersionCount}'),
          subtitle: Text(
            'Delete markers: ${controller.visibleDeleteMarkerCount}',
          ),
        ),
        const Divider(height: 20),
        ...versions.map(
          (version) => ListTile(
            contentPadding: EdgeInsets.zero,
            dense: true,
            title: Text(version.versionId),
            subtitle: Text(
              '${version.key}\n${version.storageClass} - ${_formatBytes(version.size)} - ${_formatDateTime(version.modifiedAt)}',
            ),
            isThreeLine: true,
            trailing: Text(
              version.deleteMarker
                  ? 'Delete marker'
                  : (version.latest ? 'Latest' : 'Prior'),
            ),
          ),
        ),
      ],
    );
  }

  Widget _presignView(BuildContext context) {
    final bundle = controller.selectedObjectDetails?.presignedUrl;
    return _adaptivePanelListView(
      context,
      key: const ValueKey('presign'),
      children: [
        _numberField(
          label: 'Expiration (minutes)',
          initialValue: controller.settings.defaultPresignMinutes,
          onSubmitted: (value) {
            controller.updateSettings(
              controller.settings.copyWith(defaultPresignMinutes: value),
            );
          },
        ),
        const SizedBox(height: 12),
        FilledButton.icon(
          onPressed: controller.generateSelectedPresignedUrl,
          icon: const Icon(Icons.link),
          label: const Text('Generate presigned URL'),
        ),
        const SizedBox(height: 16),
        if (bundle == null)
          const Text(
              'Generate a URL for the selected object to show the curl helper and expiration details.')
        else ...[
          _inlineStat('Expires', '${bundle.expirationMinutes} minutes'),
          const SizedBox(height: 8),
          SelectableText(bundle.url),
          const SizedBox(height: 16),
          Text('curl helper', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 8),
          _jsonBlock(bundle.curlCommand),
        ],
      ],
    );
  }

  Widget _toolsView(BuildContext context) {
    final testData = controller.testDataConfig;
    final deleteAll = controller.deleteAllConfig;

    return _adaptivePanelListView(
      context,
      key: const ValueKey('tools'),
      children: [
        Text('Put test data', style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 8),
        _textField(
          label: 'Bucket',
          initialValue: testData.bucketName,
          onSubmitted: (value) {
            controller
                .updateTestDataConfig(testData.copyWith(bucketName: value));
          },
        ),
        const SizedBox(height: 8),
        _textField(
          label: 'Prefix',
          initialValue: testData.prefix,
          onSubmitted: (value) {
            controller.updateTestDataConfig(testData.copyWith(prefix: value));
          },
        ),
        const SizedBox(height: 8),
        _numberField(
          label: 'Object size (bytes)',
          initialValue: testData.objectSizeBytes,
          onSubmitted: (value) {
            controller.updateTestDataConfig(
              testData.copyWith(objectSizeBytes: value),
            );
          },
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            Expanded(
              child: _numberField(
                label: 'Objects',
                initialValue: testData.objectCount,
                onSubmitted: (value) {
                  controller.updateTestDataConfig(
                      testData.copyWith(objectCount: value));
                },
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: _numberField(
                label: 'Versions',
                initialValue: testData.versions,
                onSubmitted: (value) {
                  controller
                      .updateTestDataConfig(testData.copyWith(versions: value));
                },
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        _numberField(
          label: 'Threads',
          initialValue: testData.threads,
          onSubmitted: (value) {
            controller.updateTestDataConfig(testData.copyWith(threads: value));
          },
        ),
        FilledButton.icon(
          onPressed: controller.runPutTestDataTool,
          icon: const Icon(Icons.data_object),
          label: const Text('Run put-testdata.py'),
        ),
        ListTile(
          contentPadding: EdgeInsets.zero,
          title: Text(controller.putTestDataState.label),
          subtitle: Text(controller.putTestDataState.lastStatus),
        ),
        const Divider(height: 28),
        Text('Delete all', style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 8),
        _textField(
          label: 'Bucket',
          initialValue: deleteAll.bucketName,
          onSubmitted: (value) {
            controller
                .updateDeleteAllConfig(deleteAll.copyWith(bucketName: value));
          },
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            Expanded(
              child: _numberField(
                label: 'Batch size',
                initialValue: deleteAll.batchSize,
                onSubmitted: (value) {
                  controller.updateDeleteAllConfig(
                      deleteAll.copyWith(batchSize: value));
                },
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: _numberField(
                label: 'Workers',
                initialValue: deleteAll.maxWorkers,
                onSubmitted: (value) {
                  controller.updateDeleteAllConfig(
                      deleteAll.copyWith(maxWorkers: value));
                },
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            Expanded(
              child: _numberField(
                label: 'Connections',
                initialValue: deleteAll.maxConnections,
                onSubmitted: (value) {
                  controller.updateDeleteAllConfig(
                    deleteAll.copyWith(maxConnections: value),
                  );
                },
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: _numberField(
                label: 'Pipeline size',
                initialValue: deleteAll.pipelineSize,
                onSubmitted: (value) {
                  controller.updateDeleteAllConfig(
                      deleteAll.copyWith(pipelineSize: value));
                },
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            Expanded(
              child: _numberField(
                label: 'List max keys',
                initialValue: deleteAll.listMaxKeys,
                onSubmitted: (value) {
                  controller.updateDeleteAllConfig(
                      deleteAll.copyWith(listMaxKeys: value));
                },
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: _numberField(
                label: 'Delete delay (ms)',
                initialValue: deleteAll.deletionDelayMs,
                onSubmitted: (value) {
                  controller.updateDeleteAllConfig(
                    deleteAll.copyWith(deletionDelayMs: value),
                  );
                },
              ),
            ),
          ],
        ),
        SwitchListTile(
          value: deleteAll.immediateDeletion,
          onChanged: (value) {
            controller.updateDeleteAllConfig(
              deleteAll.copyWith(immediateDeletion: value),
            );
          },
          title: const Text('Immediate deletion'),
        ),
        FilledButton.icon(
          onPressed: controller.runDeleteAllTool,
          icon: const Icon(Icons.delete_sweep_outlined),
          label: const Text('Run delete-all.py'),
        ),
        ListTile(
          contentPadding: EdgeInsets.zero,
          title: Text(controller.deleteAllState.label),
          subtitle: Text(controller.deleteAllState.lastStatus),
        ),
      ],
    );
  }

  Widget _eventsAndDebugView(BuildContext context) {
    final details = controller.selectedObjectDetails;
    final scopedEvents = controller.bucketScopedEvents.where((entry) {
      if (details == null) {
        return true;
      }
      return entry.objectKey == null || entry.objectKey == details.key;
    }).toList();
    final debugEvents = details?.debugEvents ?? const <DiagnosticEvent>[];

    return _adaptivePanelListView(
      context,
      key: const ValueKey('events-and-debug'),
      children: [
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            FilledButton.icon(
              onPressed: controller.isBusy('export-diagnostics')
                  ? null
                  : controller.exportDiagnostics,
              icon: const Icon(Icons.download_for_offline_outlined),
              label: Text(
                controller.isBusy('export-diagnostics')
                    ? 'Exporting...'
                    : 'Export debug log',
              ),
            ),
            OutlinedButton.icon(
              onPressed: controller.clearDiagnostics,
              icon: const Icon(Icons.clear_all),
              label: const Text('Clear object logs'),
            ),
          ],
        ),
        const SizedBox(height: 16),
        Text('Trace log', style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 8),
        StructuredLogList(
          entries: scopedEvents,
          textScalePercent: controller.settings.logTextScalePercent,
          emptyMessage: 'No bucket-scoped trace events recorded yet.',
          embedded: true,
        ),
        const Divider(height: 28),
        Text('Object debug events',
            style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 8),
        if (debugEvents.isEmpty)
          const Text('No object-specific debug events recorded.')
        else
          ...debugEvents.map(
            (event) => ListTile(
              contentPadding: EdgeInsets.zero,
              dense: true,
              title: Text('[${event.level}] ${event.message}'),
              subtitle: Text(_formatDateTime(event.timestamp)),
            ),
          ),
        if ((details?.debugLogExcerpt ?? const <String>[]).isNotEmpty) ...[
          const Divider(height: 28),
          Text('Debug excerpt', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 8),
          _jsonBlock((details?.debugLogExcerpt ?? const <String>[]).join('\n')),
        ],
      ],
    );
  }

  Widget _adaptivePanelListView(
    BuildContext context, {
    required Key key,
    required List<Widget> children,
  }) {
    final phone = Breakpoints.isPhone(MediaQuery.sizeOf(context).width);
    return ListView(
      key: key,
      shrinkWrap: phone,
      primary: false,
      physics: phone
          ? const NeverScrollableScrollPhysics()
          : const AlwaysScrollableScrollPhysics(),
      children: children,
    );
  }

  Widget _inlineStat(String label, String value) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: RichText(
        text: TextSpan(
          style: theme.textTheme.bodyMedium?.copyWith(
            height: 1.35,
            color: theme.colorScheme.onSurface,
          ),
          children: [
            TextSpan(
              text: '$label: ',
              style: TextStyle(
                fontWeight: FontWeight.w700,
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            TextSpan(text: value),
          ],
        ),
      ),
    );
  }

  Widget _pill(String label, bool enabled) {
    return Chip(
      avatar: Icon(
        enabled ? Icons.check_circle : Icons.block,
        size: 16,
      ),
      label: Text(label),
    );
  }

  Widget _jsonBlock(String value) {
    final desktopCompact = _desktopCompact(context);
    return Container(
      width: double.infinity,
      padding: EdgeInsets.all(desktopCompact ? 10 : 12),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(desktopCompact ? 12 : 14),
        color: const Color(0x11000000),
      ),
      child: SelectableText(value),
    );
  }

  Widget _inlineSpinner() {
    return const SizedBox(
      width: 18,
      height: 18,
      child: CircularProgressIndicator(strokeWidth: 2),
    );
  }

  Widget _textField({
    required String label,
    required String initialValue,
    required ValueChanged<String> onSubmitted,
  }) {
    return TextFormField(
      initialValue: initialValue,
      decoration: InputDecoration(labelText: label),
      onFieldSubmitted: onSubmitted,
    );
  }

  Widget _numberField({
    required String label,
    required int initialValue,
    required ValueChanged<int> onSubmitted,
  }) {
    return TextFormField(
      initialValue: '$initialValue',
      keyboardType: TextInputType.number,
      decoration: InputDecoration(labelText: label),
      onFieldSubmitted: (value) {
        final parsed = int.tryParse(value);
        if (parsed != null) {
          onSubmitted(parsed);
        }
      },
    );
  }

  String _formatBytes(int value) {
    if (value >= 1024 * 1024 * 1024) {
      return '${(value / (1024 * 1024 * 1024)).toStringAsFixed(1)} GiB';
    }
    if (value >= 1024 * 1024) {
      return '${(value / (1024 * 1024)).toStringAsFixed(1)} MiB';
    }
    if (value >= 1024) {
      return '${(value / 1024).toStringAsFixed(1)} KiB';
    }
    return '$value B';
  }

  String _formatDateTime(DateTime value) {
    final twoDigitMonth = value.month.toString().padLeft(2, '0');
    final twoDigitDay = value.day.toString().padLeft(2, '0');
    final twoDigitHour = value.hour.toString().padLeft(2, '0');
    final twoDigitMinute = value.minute.toString().padLeft(2, '0');
    return '${value.year}-$twoDigitMonth-$twoDigitDay $twoDigitHour:$twoDigitMinute';
  }

  Future<void> _showCreateBucketDialog(BuildContext context) async {
    final nameController = TextEditingController();
    var enableVersioning = false;
    var enableObjectLock = false;

    await showDialog<void>(
      context: context,
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setState) {
            return AlertDialog(
              title: const Text('New bucket'),
              content: SizedBox(
                width: 420,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    TextField(
                      controller: nameController,
                      decoration: const InputDecoration(
                        labelText: 'Bucket name',
                      ),
                    ),
                    const SizedBox(height: 12),
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      value: enableVersioning,
                      onChanged: (value) =>
                          setState(() => enableVersioning = value),
                      title: const Text('Enable versioning'),
                    ),
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      value: enableObjectLock,
                      onChanged: (value) =>
                          setState(() => enableObjectLock = value),
                      title: const Text('Enable object lock'),
                    ),
                    const Align(
                      alignment: Alignment.centerLeft,
                      child: Text(
                        'Object lock must be enabled when the bucket is created.',
                      ),
                    ),
                  ],
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(context).pop(),
                  child: const Text('Cancel'),
                ),
                FilledButton(
                  onPressed: () async {
                    final bucketName = nameController.text.trim();
                    if (bucketName.isEmpty) {
                      return;
                    }
                    Navigator.of(context).pop();
                    await controller.createBucket(
                      bucketName: bucketName,
                      enableVersioning: enableVersioning,
                      enableObjectLock: enableObjectLock,
                    );
                  },
                  child: const Text('Create'),
                ),
              ],
            );
          },
        );
      },
    );

    nameController.dispose();
  }

  Future<void> _confirmDeleteBucket(
    BuildContext context,
    String bucketName, {
    bool force = false,
  }) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(force ? 'Force delete bucket' : 'Delete bucket'),
        content: Text(
          force
              ? 'Delete every object found in "$bucketName" with the delete-all tool, then delete the bucket itself?'
              : 'Delete "$bucketName"? If the bucket is not empty, use Force delete instead.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(force ? 'Force delete' : 'Delete'),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      await controller.deleteBucketByName(bucketName, force: force);
    }
  }

  Future<void> _showCopyBucketDialog(
    BuildContext context,
    BucketSummary sourceBucket,
  ) async {
    final destinationController = TextEditingController();
    var createDestination = false;
    final initialDestinations = controller.buckets
        .where((bucket) => bucket.name != sourceBucket.name)
        .map((bucket) => bucket.name)
        .toList();
    String? selectedDestination =
        initialDestinations.isEmpty ? null : initialDestinations.first;
    destinationController.text = selectedDestination ?? '';

    await showDialog<void>(
      context: context,
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setState) {
            final destinations = controller.buckets
                .where((bucket) => bucket.name != sourceBucket.name)
                .map((bucket) => bucket.name)
                .toList();
            return AlertDialog(
              title: Text('Copy ${sourceBucket.name}'),
              content: SizedBox(
                width: 420,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    DropdownButtonFormField<String>(
                      initialValue: destinations.contains(selectedDestination)
                          ? selectedDestination
                          : null,
                      decoration: const InputDecoration(
                        labelText: 'Destination bucket',
                      ),
                      items: destinations
                          .map(
                            (bucketName) => DropdownMenuItem(
                              value: bucketName,
                              child: Text(bucketName),
                            ),
                          )
                          .toList(),
                      onChanged: (value) {
                        setState(() {
                          selectedDestination = value;
                          destinationController.text = value ?? '';
                        });
                      },
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: destinationController,
                      decoration: const InputDecoration(
                        labelText: 'Or enter a new destination bucket',
                      ),
                      onChanged: (value) {
                        setState(() {
                          selectedDestination =
                              value.trim().isEmpty ? null : value;
                        });
                      },
                    ),
                    const SizedBox(height: 12),
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      value: createDestination,
                      onChanged: (value) =>
                          setState(() => createDestination = value),
                      title: const Text('Create destination if missing'),
                    ),
                    const Align(
                      alignment: Alignment.centerLeft,
                      child: Text(
                        'Copies bucket contents only. Lifecycle, policy, encryption, and tagging stay independent.',
                      ),
                    ),
                  ],
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(context).pop(),
                  child: const Text('Cancel'),
                ),
                FilledButton(
                  onPressed: () async {
                    final destinationBucketName =
                        destinationController.text.trim();
                    if (destinationBucketName.isEmpty) {
                      return;
                    }
                    Navigator.of(context).pop();
                    await controller.copyBucketContents(
                      sourceBucketName: sourceBucket.name,
                      destinationBucketName: destinationBucketName,
                      createDestinationIfMissing: createDestination,
                    );
                  },
                  child: const Text('Copy bucket'),
                ),
              ],
            );
          },
        );
      },
    );

    destinationController.dispose();
  }

  Future<void> _showJsonEditorDialog(
    BuildContext context, {
    required String title,
    required String initialValue,
    required Future<void> Function(String value) onSave,
  }) async {
    final controllerText = TextEditingController(text: initialValue);
    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: SizedBox(
          width: 560,
          child: TextField(
            controller: controllerText,
            minLines: 12,
            maxLines: 20,
            decoration: const InputDecoration(
              border: OutlineInputBorder(),
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () async {
              Navigator.of(context).pop();
              await onSave(controllerText.text.trim());
            },
            child: const Text('Save'),
          ),
        ],
      ),
    );
    controllerText.dispose();
  }

  Future<void> _showTagEditorDialog(
    BuildContext context, {
    required Map<String, String> initialTags,
  }) async {
    final controllerText = TextEditingController(
      text: initialTags.entries
          .map((entry) => '${entry.key}=${entry.value}')
          .join('\n'),
    );
    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Bucket tags'),
        content: SizedBox(
          width: 460,
          child: TextField(
            controller: controllerText,
            minLines: 8,
            maxLines: 16,
            decoration: const InputDecoration(
              labelText: 'One key=value pair per line',
              border: OutlineInputBorder(),
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () async {
              final tags = <String, String>{};
              for (final line in controllerText.text.split('\n')) {
                final trimmed = line.trim();
                if (trimmed.isEmpty) {
                  continue;
                }
                final separator = trimmed.indexOf('=');
                if (separator <= 0) {
                  continue;
                }
                tags[trimmed.substring(0, separator).trim()] =
                    trimmed.substring(separator + 1).trim();
              }
              Navigator.of(context).pop();
              await controller.saveBucketTags(tags);
            },
            child: const Text('Save'),
          ),
        ],
      ),
    );
    controllerText.dispose();
  }
}

class _CreatePrefixDialog extends StatefulWidget {
  const _CreatePrefixDialog();

  @override
  State<_CreatePrefixDialog> createState() => _CreatePrefixDialogState();
}

class _CreatePrefixDialogState extends State<_CreatePrefixDialog> {
  final TextEditingController _nameController = TextEditingController();

  @override
  void dispose() {
    _nameController.dispose();
    super.dispose();
  }

  void _submit() {
    final value = _nameController.text.trim();
    if (value.isEmpty) {
      return;
    }
    Navigator.of(context).pop(value);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Create prefix'),
      content: SizedBox(
        width: 420,
        child: TextField(
          controller: _nameController,
          autofocus: true,
          decoration: const InputDecoration(
            labelText: 'Prefix name',
            hintText: 'reports/2026',
          ),
          onSubmitted: (_) => _submit(),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: _submit,
          child: const Text('Create'),
        ),
      ],
    );
  }
}

class _ObjectTable extends StatelessWidget {
  const _ObjectTable({
    required this.objects,
    required this.selectedKey,
    required this.contentTypeFor,
    required this.onSelect,
  });

  final List<ObjectEntry> objects;
  final String? selectedKey;
  final String Function(ObjectEntry object) contentTypeFor;
  final ValueChanged<ObjectEntry> onSelect;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final headerStyle = theme.textTheme.labelSmall?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
      fontWeight: FontWeight.w800,
    );
    return LayoutBuilder(
      builder: (context, constraints) {
        final narrow = constraints.maxWidth < 520;
        final veryNarrow = constraints.maxWidth < 380;
        // Wide desktop panels get extra detail columns.
        final showStorageClass = constraints.maxWidth >= 860;
        final showEtag = constraints.maxWidth >= 1100;
        final selectWidth = narrow ? 26.0 : 32.0;
        final modifiedWidth = veryNarrow ? 72.0 : (narrow ? 86.0 : 128.0);
        final sizeWidth = veryNarrow ? 52.0 : (narrow ? 64.0 : 86.0);
        final typeWidth = veryNarrow ? 48.0 : (narrow ? 62.0 : 84.0);
        const storageClassWidth = 110.0;
        const etagWidth = 150.0;
        final horizontalPadding = narrow ? 4.0 : 8.0;
        final nameGap = narrow ? 6.0 : 10.0;

        return Column(
          children: [
            Container(
              height: narrow ? 32 : 34,
              padding: EdgeInsets.symmetric(horizontal: horizontalPadding),
              decoration: BoxDecoration(
                border: Border(
                  bottom: BorderSide(color: theme.colorScheme.outlineVariant),
                ),
              ),
              child: Row(
                children: [
                  SizedBox(width: selectWidth),
                  Expanded(
                    child: Text('Name', style: headerStyle),
                  ),
                  SizedBox(
                    width: modifiedWidth,
                    child: Text('Modified', style: headerStyle),
                  ),
                  SizedBox(
                    width: sizeWidth,
                    child: Text('Size', style: headerStyle),
                  ),
                  SizedBox(
                    width: typeWidth,
                    child: Text('Type', style: headerStyle),
                  ),
                  if (showStorageClass)
                    SizedBox(
                      width: storageClassWidth,
                      child: Text('Storage class', style: headerStyle),
                    ),
                  if (showEtag)
                    SizedBox(
                      width: etagWidth,
                      child: Text('ETag', style: headerStyle),
                    ),
                ],
              ),
            ),
            Expanded(
              child: ListView.separated(
                primary: false,
                physics: const AlwaysScrollableScrollPhysics(),
                itemCount: objects.length,
                separatorBuilder: (_, __) => Divider(
                  height: 1,
                  color:
                      theme.colorScheme.outlineVariant.withValues(alpha: 0.55),
                ),
                itemBuilder: (context, index) {
                  final object = objects[index];
                  final selected = selectedKey == object.key;
                  return Material(
                    color: selected
                        ? theme.colorScheme.primaryContainer
                            .withValues(alpha: 0.72)
                        : Colors.transparent,
                    borderRadius: BorderRadius.circular(6),
                    child: InkWell(
                      borderRadius: BorderRadius.circular(6),
                      onTap: () => onSelect(object),
                      child: Container(
                        height: narrow ? 36 : 38,
                        padding:
                            EdgeInsets.symmetric(horizontal: horizontalPadding),
                        child: Row(
                          children: [
                            SizedBox(
                              width: selectWidth,
                              child: Icon(
                                selected
                                    ? Icons.check_box
                                    : Icons.check_box_outline_blank,
                                size: narrow ? 16 : 18,
                                color: selected
                                    ? theme.colorScheme.primary
                                    : theme.colorScheme.outline,
                              ),
                            ),
                            Expanded(
                              child: Row(
                                children: [
                                  Icon(
                                    object.isFolder
                                        ? Icons.folder
                                        : Icons.insert_drive_file_outlined,
                                    size: narrow ? 16 : 18,
                                    color: object.isFolder
                                        ? theme.colorScheme.onSurfaceVariant
                                        : theme.colorScheme.primary,
                                  ),
                                  SizedBox(width: nameGap),
                                  Expanded(
                                    child: Text(
                                      object.name,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style:
                                          theme.textTheme.bodyMedium?.copyWith(
                                        color: theme.colorScheme.onSurface,
                                        fontWeight: selected
                                            ? FontWeight.w700
                                            : FontWeight.w500,
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            SizedBox(
                              width: modifiedWidth,
                              child: Text(
                                _formatTableDateTime(
                                  object.modifiedAt,
                                  compact: narrow,
                                ),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: theme.textTheme.bodySmall,
                              ),
                            ),
                            SizedBox(
                              width: sizeWidth,
                              child: Text(
                                object.isFolder
                                    ? '--'
                                    : _formatTableBytes(
                                        object.size,
                                        compact: narrow,
                                      ),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: theme.textTheme.bodySmall,
                              ),
                            ),
                            SizedBox(
                              width: typeWidth,
                              child: Text(
                                object.isFolder
                                    ? 'Folder'
                                    : _shortObjectType(contentTypeFor(object)),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: theme.textTheme.bodySmall,
                              ),
                            ),
                            if (showStorageClass)
                              SizedBox(
                                width: storageClassWidth,
                                child: Text(
                                  object.isFolder ||
                                          object.storageClass.isEmpty
                                      ? '--'
                                      : object.storageClass,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: theme.textTheme.bodySmall,
                                ),
                              ),
                            if (showEtag)
                              SizedBox(
                                width: etagWidth,
                                child: Text(
                                  object.isFolder
                                      ? '--'
                                      : _shortEtag(object.etag),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: theme.textTheme.bodySmall,
                                ),
                              ),
                          ],
                        ),
                      ),
                    ),
                  );
                },
              ),
            ),
          ],
        );
      },
    );
  }

  static String _shortEtag(String? value) {
    if (value == null || value.isEmpty) {
      return '--';
    }
    return value.replaceAll('"', '');
  }

  static String _shortObjectType(String value) {
    if (value.contains('/')) {
      return value.split('/').last;
    }
    return value.isEmpty ? '--' : value;
  }

  static String _formatTableBytes(int value, {bool compact = false}) {
    if (value >= 1024 * 1024 * 1024) {
      return '${(value / (1024 * 1024 * 1024)).toStringAsFixed(1)}${compact ? 'G' : ' GB'}';
    }
    if (value >= 1024 * 1024) {
      return '${(value / (1024 * 1024)).toStringAsFixed(1)}${compact ? 'M' : ' MB'}';
    }
    if (value >= 1024) {
      return '${(value / 1024).toStringAsFixed(1)}${compact ? 'K' : ' KB'}';
    }
    return compact ? '$value' : '$value B';
  }

  static String _formatTableDateTime(DateTime value, {bool compact = false}) {
    final month = value.month.toString().padLeft(2, '0');
    final day = value.day.toString().padLeft(2, '0');
    final hour = value.hour.toString().padLeft(2, '0');
    final minute = value.minute.toString().padLeft(2, '0');
    if (compact) {
      return '$month-$day $hour:$minute';
    }
    return '${value.year}-$month-$day $hour:$minute';
  }
}

class BrowserBucketPanel extends StatefulWidget {
  const BrowserBucketPanel({
    super.key,
    required this.controller,
    required this.compact,
    required this.onCreateBucket,
    required this.onDeleteBucket,
    required this.onEditBucketLifecycle,
    required this.onEditBucketPolicy,
    required this.onEditBucketEncryption,
    required this.onEditBucketTags,
    required this.onToggleBucketVersioning,
    required this.onOpenBucket,
    required this.onCopyBucket,
    required this.inlineSpinnerBuilder,
    required this.inlineStatBuilder,
  });

  final AppController controller;
  final bool compact;
  final VoidCallback onCreateBucket;
  final Future<void> Function(String bucketName, {bool force}) onDeleteBucket;
  final Future<void> Function(BucketSummary bucket) onEditBucketLifecycle;
  final Future<void> Function(BucketSummary bucket) onEditBucketPolicy;
  final Future<void> Function(BucketSummary bucket) onEditBucketEncryption;
  final Future<void> Function(BucketSummary bucket) onEditBucketTags;
  final Future<void> Function(BucketSummary bucket, bool enabled)
      onToggleBucketVersioning;
  final Future<void> Function(BucketSummary bucket) onOpenBucket;
  final Future<void> Function(BucketSummary bucket) onCopyBucket;
  final Widget Function() inlineSpinnerBuilder;
  final Widget Function(String label, String value) inlineStatBuilder;

  @override
  State<BrowserBucketPanel> createState() => _BrowserBucketPanelState();
}

class _BrowserBucketPanelState extends State<BrowserBucketPanel> {
  final ScrollController _bucketScrollController = ScrollController();
  String _bucketSearchQuery = '';

  Future<void> _showBucketMenu(
    BuildContext context,
    BucketSummary bucket,
    Offset position,
  ) async {
    // Versioning, lifecycle, policy, encryption, and tagging are S3-only
    // bucket admin features.
    final isAzure = widget.controller.selectedProfile?.endpointType ==
        EndpointProfileType.azureBlob;
    final selected = await showMenu<String>(
      context: context,
      position: RelativeRect.fromLTRB(
        position.dx,
        position.dy,
        position.dx,
        position.dy,
      ),
      items: [
        const PopupMenuItem(
          value: 'open',
          child: ListTile(
            contentPadding: EdgeInsets.zero,
            leading: Icon(Icons.folder_open_outlined),
            title: Text('Open bucket'),
          ),
        ),
        if (!isAzure) ...[
          PopupMenuItem(
            value: bucket.versioningEnabled
                ? 'suspend-versioning'
                : 'enable-versioning',
            child: ListTile(
              contentPadding: EdgeInsets.zero,
              leading: Icon(
                bucket.versioningEnabled
                    ? Icons.pause_circle_outline
                    : Icons.history_toggle_off_rounded,
              ),
              title: Text(
                bucket.versioningEnabled
                    ? 'Suspend versioning'
                    : 'Enable versioning',
              ),
            ),
          ),
          const PopupMenuDivider(),
          const PopupMenuItem(
            value: 'lifecycle',
            child: ListTile(
              contentPadding: EdgeInsets.zero,
              leading: Icon(Icons.schedule_outlined),
              title: Text('Lifecycle policy'),
            ),
          ),
          const PopupMenuItem(
            value: 'policy',
            child: ListTile(
              contentPadding: EdgeInsets.zero,
              leading: Icon(Icons.policy_outlined),
              title: Text('Bucket policy'),
            ),
          ),
          const PopupMenuItem(
            value: 'encryption',
            child: ListTile(
              contentPadding: EdgeInsets.zero,
              leading: Icon(Icons.lock_outline),
              title: Text('Bucket encryption'),
            ),
          ),
          const PopupMenuItem(
            value: 'tags',
            child: ListTile(
              contentPadding: EdgeInsets.zero,
              leading: Icon(Icons.sell_outlined),
              title: Text('Bucket tagging'),
            ),
          ),
        ],
        const PopupMenuItem(
          value: 'copy',
          child: ListTile(
            contentPadding: EdgeInsets.zero,
            leading: Icon(Icons.copy_all_outlined),
            title: Text('Copy bucket'),
          ),
        ),
        const PopupMenuDivider(),
        const PopupMenuItem(
          value: 'delete',
          child: ListTile(
            contentPadding: EdgeInsets.zero,
            leading: Icon(Icons.delete_outline),
            title: Text('Delete bucket'),
          ),
        ),
        const PopupMenuItem(
          value: 'force-delete',
          child: ListTile(
            contentPadding: EdgeInsets.zero,
            leading: Icon(Icons.delete_forever_outlined),
            title: Text('Force delete bucket'),
          ),
        ),
      ],
    );
    if (!mounted || selected == null) {
      return;
    }
    if (selected == 'open') {
      await widget.onOpenBucket(bucket);
      return;
    }
    if (widget.controller.selectedBucket?.name != bucket.name) {
      await widget.controller.setSelectedBucket(bucket);
    }
    switch (selected) {
      case 'enable-versioning':
        await widget.onToggleBucketVersioning(bucket, true);
        return;
      case 'suspend-versioning':
        await widget.onToggleBucketVersioning(bucket, false);
        return;
      case 'lifecycle':
        await widget.onEditBucketLifecycle(bucket);
        return;
      case 'policy':
        await widget.onEditBucketPolicy(bucket);
        return;
      case 'encryption':
        await widget.onEditBucketEncryption(bucket);
        return;
      case 'tags':
        await widget.onEditBucketTags(bucket);
        return;
      case 'copy':
        await widget.onCopyBucket(bucket);
        return;
      case 'delete':
        await widget.onDeleteBucket(bucket.name);
        return;
      case 'force-delete':
        await widget.onDeleteBucket(bucket.name, force: true);
        return;
      default:
        return;
    }
  }

  @override
  void dispose() {
    _bucketScrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final controller = widget.controller;
    final desktopCompact =
        AppTheme.isDesktopPlatform(Theme.of(context).platform);
    final profile = controller.selectedProfile;
    final buckets = controller.buckets;
    final visibleBuckets = _bucketSearchQuery.isEmpty
        ? buckets
        : buckets
            .where(
              (bucket) =>
                  bucket.name
                      .toLowerCase()
                      .contains(_bucketSearchQuery.toLowerCase()) ||
                  bucket.region
                      .toLowerCase()
                      .contains(_bucketSearchQuery.toLowerCase()),
            )
            .toList();
    final hasProfile = profile != null;
    final isRefreshing = controller.isBusy('refresh-buckets');
    final isCreatingBucket = controller.isBusy('create-bucket');
    final isDeletingBucket = controller.isBusy('delete-bucket');

    final bucketListContent = ListView(
      key: _bucketListKey,
      controller: _bucketScrollController,
      padding: EdgeInsets.zero,
      primary: false,
      physics: const AlwaysScrollableScrollPhysics(),
      children: [
        if (buckets.isEmpty && hasProfile)
          const Padding(
            padding: EdgeInsets.only(bottom: 12),
            child: Text('No buckets loaded yet for this endpoint.'),
          )
        else if (visibleBuckets.isEmpty && hasProfile)
          const Padding(
            padding: EdgeInsets.only(bottom: 12),
            child: Text('No buckets match this search.'),
          )
        else
          ...visibleBuckets.map(
            (bucket) => Builder(
              builder: (context) {
                final selected = controller.selectedBucket?.name == bucket.name;
                return Padding(
                  padding: const EdgeInsets.only(bottom: 3),
                  child: Material(
                    color: selected
                        ? Theme.of(context)
                            .colorScheme
                            .primaryContainer
                            .withValues(alpha: 0.72)
                        : Colors.transparent,
                    borderRadius: BorderRadius.circular(8),
                    child: InkWell(
                      borderRadius: BorderRadius.circular(8),
                      onSecondaryTapDown: (details) => _showBucketMenu(
                        context,
                        bucket,
                        details.globalPosition,
                      ),
                      child: ListTile(
                        dense: desktopCompact,
                        leading: Icon(
                          Icons.folder_rounded,
                          color: selected
                              ? Theme.of(context).colorScheme.primary
                              : Theme.of(context).colorScheme.onSurfaceVariant,
                          size: 20,
                        ),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(8),
                        ),
                        selected: selected,
                        title: Text(
                          bucket.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: Theme.of(context).textTheme.titleMedium,
                        ),
                        subtitle: Text(
                          '${bucket.region}  -  ${bucket.objectCountHint} objects',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        trailing: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            if (bucket.versioningEnabled)
                              const Padding(
                                padding: EdgeInsets.only(right: 4),
                                child: Icon(Icons.history_toggle_off_rounded),
                              ),
                            IconButton(
                              tooltip: 'Bucket actions',
                              onPressed: () async {
                                final box =
                                    context.findRenderObject() as RenderBox?;
                                if (box == null) {
                                  return;
                                }
                                await _showBucketMenu(
                                  context,
                                  bucket,
                                  box.localToGlobal(
                                    Offset(
                                      box.size.width - 24,
                                      box.size.height / 2,
                                    ),
                                  ),
                                );
                              },
                              icon: const Icon(Icons.more_horiz),
                            ),
                          ],
                        ),
                        onTap: () => widget.onOpenBucket(bucket),
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
      ],
    );

    final bucketListViewport = Scrollbar(
      controller: _bucketScrollController,
      thumbVisibility: true,
      interactive: true,
      child: bucketListContent,
    );

    return Card(
      clipBehavior: Clip.antiAlias,
      child: Padding(
        padding: EdgeInsets.all(desktopCompact ? 12 : 16),
        child: Column(
          mainAxisSize: widget.compact ? MainAxisSize.min : MainAxisSize.max,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Text('Buckets', style: Theme.of(context).textTheme.titleLarge),
                const Spacer(),
                if (isRefreshing)
                  OutlinedButton.icon(
                    onPressed: controller.cancelListing,
                    icon: const Icon(Icons.stop_circle_outlined, size: 18),
                    label: const Text('Cancel'),
                  )
                else
                  IconButton(
                    tooltip: 'Refresh buckets',
                    onPressed: hasProfile ? controller.refreshBuckets : null,
                    icon: const Icon(Icons.refresh),
                  ),
              ],
            ),
            const SizedBox(height: 12),
            TextField(
              enabled: hasProfile,
              decoration: const InputDecoration(
                hintText: 'Search buckets...',
                prefixIcon: Icon(Icons.search),
                contentPadding: EdgeInsets.fromLTRB(12, 12, 12, 10),
              ),
              onChanged: (value) {
                setState(() {
                  _bucketSearchQuery = value.trim();
                });
              },
            ),
            const SizedBox(height: 12),
            Wrap(
              key: _bucketActionBarKey,
              spacing: desktopCompact ? 10 : 12,
              runSpacing: desktopCompact ? 10 : 12,
              children: [
                FilledButton.icon(
                  onPressed: hasProfile && !isCreatingBucket
                      ? widget.onCreateBucket
                      : null,
                  icon: isCreatingBucket
                      ? widget.inlineSpinnerBuilder()
                      : const Icon(Icons.add_circle_outline),
                  label: Text(isCreatingBucket ? 'Creating...' : 'New bucket'),
                ),
                if (controller.selectedBucket != null)
                  TextButton.icon(
                    onPressed: hasProfile && !isDeletingBucket
                        ? () => widget.onDeleteBucket(
                              controller.selectedBucket!.name,
                            )
                        : null,
                    icon: isDeletingBucket
                        ? widget.inlineSpinnerBuilder()
                        : const Icon(Icons.delete_forever_outlined),
                    label: const Text('Delete selected'),
                  ),
              ],
            ),
            if (!hasProfile)
              const Padding(
                padding: EdgeInsets.only(top: 8),
                child: Text(
                  'No endpoint profile is selected. Create one in Settings, save it, then come back here to list buckets.',
                ),
              ),
            const SizedBox(height: 12),
            if (widget.compact)
              SizedBox(
                height: (MediaQuery.sizeOf(context).height * 0.34)
                    .clamp(240.0, 360.0),
                child: bucketListViewport,
              )
            else
              Expanded(
                child: bucketListViewport,
              ),
          ],
        ),
      ),
    );
  }
}
