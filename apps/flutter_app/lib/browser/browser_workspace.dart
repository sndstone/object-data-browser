import '../widgets/empty_state.dart';
import 'json_editor_dialog.dart';
import 'tag_editor_dialog.dart';
import '../widgets/copyable_value.dart';
import '../utils/format.dart';
import '../widgets/setting_fields.dart';
import '../widgets/danger_button.dart';
import 'dart:io';
import 'dart:math' as math;

import 'package:desktop_drop/desktop_drop.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_widget_from_html_core/flutter_widget_from_html_core.dart';

import '../controllers/app_controller.dart';
import '../logs/structured_log_list.dart';
import '../models/domain_models.dart';
import '../services/app_platform.dart';
import '../services/source_preview.dart';
import '../theme/app_theme.dart';
import '../theme/breakpoints.dart';
import '../widgets/app_select_field.dart';
import '../widgets/compact_selector.dart';
import '../widgets/source_code_preview.dart';
import 'object_panel.dart';
import '../theme/app_motion.dart';

const _bucketActionBarKey = ValueKey('bucket-panel-actions');
const _bucketListKey = ValueKey('bucket-panel-scroll');

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
  bool _dragging = false;
  @override
  void initState() {
    super.initState();
    if (controller.pendingObjectSearchFocus) {
      _mobileSection = _MobileBrowserSection.objects;
    }
    controller.objectSearchFocus.addListener(_searchRequested);
    controller.inspectorToggleRequest.addListener(_toggleInspector);
    controller.deleteSelectionRequest.addListener(_deleteRequested);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && controller.pendingInspectorToggle) _toggleInspector();
    });
  }

  void _deleteRequested() {
    if (mounted) _confirmDeleteObjects(context);
  }

  void _toggleInspector() {
    if (!mounted) return;
    controller.pendingInspectorToggle = false;
    if (MediaQuery.sizeOf(context).width >= 1000) {
      controller.updateSettings(controller.settings.copyWith(
          browserInspectorVisible:
              !controller.settings.browserInspectorVisible));
    } else {
      _showInspectorDialog(context);
    }
  }

  void _searchRequested() {
    if (mounted) setState(() => _mobileSection = _MobileBrowserSection.objects);
  }

  @override
  void dispose() {
    controller.objectSearchFocus.removeListener(_searchRequested);
    controller.inspectorToggleRequest.removeListener(_toggleInspector);
    controller.deleteSelectionRequest.removeListener(_deleteRequested);
    super.dispose();
  }

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
      final minSize = desktopCompact ? 220.0 : 280.0;
      final maxSize = math.max(
        minSize,
        constraints.maxWidth * (desktopCompact ? 0.32 : 0.42),
      );
      return rawSize.clamp(
        minSize,
        maxSize,
      );
    }
    final minSize =
        math.max(220.0, MediaQuery.textScalerOf(context).scale(160));
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
              if (!Platform.isIOS)
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
    final duration = AppMotion.duration(context,
        enabled: controller.settings.enableAnimations, milliseconds: 260);

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 20),
      child: Column(
        children: [
          SizedBox(
            width: double.infinity,
            child: CompactSelector<_MobileBrowserSection>(
              dense: true,
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
          Expanded(
              child: DirectionalSwitcher(
            position: effectiveSection.index,
            duration: duration,
            layoutBuilder: (current, previous) => Stack(
                alignment: Alignment.topCenter,
                fit: StackFit.expand,
                children: [...previous, if (current != null) current]),
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
          )),
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
        final sizeClass = Breakpoints.sizeClass(width);
        if (sizeClass == WindowSizeClass.phone) {
          return _mobileBrowserShell(context);
        }

        // Tablet range (and a desktop window resized into it): keep buckets
        // and objects side by side, with inspector access through the info
        // button used by compact object controls.
        final tablet = sizeClass == WindowSizeClass.tablet;
        final smallDesktop = sizeClass == WindowSizeClass.smallDesktop;
        final compactRightInspector = desktopCompact && smallDesktop;
        final inspectorOnRight = !tablet &&
            !smallDesktop &&
            !compactRightInspector &&
            _settings.browserInspectorLayout == BrowserInspectorLayout.right;
        final showDockedInspector =
            !tablet && controller.settings.browserInspectorVisible;
        final inspectorSize =
            _resolveInspectorSize(context, constraints, inspectorOnRight);
        final roomy = width >= Breakpoints.desktopWide;
        final outerPadding =
            tablet ? 10.0 : (desktopCompact && !roomy ? 10.0 : 12.0);
        const panelGap = 8.0;
        final bucketPanelWidth =
            tablet ? 252.0 : (desktopCompact && !roomy ? 264.0 : 272.0);
        final Widget objectAndInspector;
        if (tablet) {
          objectAndInspector = _objectPanel(context, compact: true);
        } else if (!showDockedInspector) {
          objectAndInspector = _objectPanel(context, compact: false);
        } else if (inspectorOnRight) {
          objectAndInspector = Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(child: _objectPanel(context, compact: false)),
              _resizeHandle(Axis.horizontal),
              SizedBox(
                width: inspectorSize,
                child: _inspectorPanel(context, compact: false),
              ),
            ],
          );
        } else {
          objectAndInspector = Column(
            children: [
              Expanded(child: _objectPanel(context, compact: false)),
              _resizeHandle(Axis.vertical),
              SizedBox(
                height: inspectorSize,
                child: _inspectorPanel(context, compact: false),
              ),
            ],
          );
        }

        return AnimatedPadding(
          duration: AppMotion.duration(context,
              enabled: controller.settings.enableAnimations, milliseconds: 220),
          curve: Curves.easeOutCubic,
          padding: EdgeInsets.all(outerPadding),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SizedBox(
                width: bucketPanelWidth,
                child: _bucketPanel(context, compact: false),
              ),
              const SizedBox(width: panelGap),
              Expanded(
                child: objectAndInspector,
              ),
            ],
          ),
        );
      },
    );

    if (AppPlatform.isMobile ||
        Breakpoints.isPhone(MediaQuery.sizeOf(context).width)) {
      return content;
    }

    return DropTarget(
      onDragEntered: (_) => setState(() => _dragging = true),
      onDragExited: (_) => setState(() => _dragging = false),
      onDragDone: (detail) async {
        setState(() => _dragging = false);
        final files = detail.files.map((file) => file.path).toList();
        await _uploadPaths(files);
      },
      child: Stack(children: [
        content,
        if (_dragging)
          Positioned.fill(
              child: IgnorePointer(
                  child: ColoredBox(
                      color: Theme.of(context)
                          .colorScheme
                          .primaryContainer
                          .withValues(alpha: .9),
                      child: const Center(
                          child: Text(
                              'Drop files to upload into the current prefix'))))),
      ]),
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

  Future<void> _showObjectContextMenu(
    BuildContext context,
    ObjectEntry object,
    Offset position,
  ) async {
    controller.clearObjectSelection();
    await controller.setSelectedObject(
      object,
      openFolderOnSelect: false,
      loadArtifacts: false,
    );
    if (!context.mounted) {
      return;
    }
    final selected = await showMenu<String>(
      context: context,
      position: RelativeRect.fromLTRB(
        position.dx,
        position.dy,
        position.dx,
        position.dy,
      ),
      items: [
        PopupMenuItem(
          value: object.isFolder ? 'open-folder' : 'inspect',
          child: ListTile(
            contentPadding: EdgeInsets.zero,
            leading: Icon(
              object.isFolder ? Icons.folder_open_outlined : Icons.info_outline,
            ),
            title: Text(object.isFolder ? 'Open folder' : 'Inspect object'),
          ),
        ),
        if (!object.isFolder) ...[
          const PopupMenuItem(
            value: 'download',
            child: ListTile(
              contentPadding: EdgeInsets.zero,
              leading: Icon(Icons.download_outlined),
              title: Text('Download'),
            ),
          ),
          const PopupMenuItem(
            value: 'presign',
            child: ListTile(
              contentPadding: EdgeInsets.zero,
              leading: Icon(Icons.link),
              title: Text('Generate presigned URL'),
            ),
          ),
        ],
        const PopupMenuItem(value: 'copy-key', child: Text('Copy key')),
        const PopupMenuItem(value: 'copy-uri', child: Text('Copy s3:// URI')),
        if (!object.isFolder &&
            controller.selectedProfile?.endpointType !=
                EndpointProfileType.azureBlob)
          const PopupMenuItem(
              value: 'copy-url', child: Text('Copy presigned URL')),
        const PopupMenuDivider(),
        PopupMenuItem(
          value: 'delete',
          child: ListTile(
            iconColor: Theme.of(context).colorScheme.error,
            textColor: Theme.of(context).colorScheme.error,
            contentPadding: EdgeInsets.zero,
            leading: Icon(
              Icons.delete_outline,
              color: Theme.of(context).colorScheme.error,
            ),
            title: Text(
              object.isFolder ? 'Delete folder marker' : 'Delete object',
            ),
          ),
        ),
      ],
    );

    switch (selected) {
      case 'copy-key':
        await copyValue(controller, 'Key', object.key);
        return;
      case 'copy-uri':
        await copyValue(controller, 'S3 URI',
            's3://${controller.selectedBucket?.name}/${object.key}');
        return;
      case 'copy-url':
        await controller.generateSelectedPresignedUrl();
        final bundle = controller.selectedObjectDetails?.presignedUrl;
        if (bundle != null &&
            controller.bannerSeverity != BannerSeverity.error) {
          await copyValue(controller, 'Presigned URL', bundle.url);
        }
        return;
      case 'open-folder':
        await controller.openFolder(object);
        return;
      case 'inspect':
        await controller.setSelectedObject(object, openFolderOnSelect: false);
        return;
      case 'download':
        await controller.startSampleDownload();
        return;
      case 'presign':
        await controller.generateSelectedPresignedUrl();
        return;
      case 'delete':
        if (!context.mounted) return;
        await _confirmDeleteObjects(context);
        return;
      default:
        return;
    }
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
          width: isHorizontal ? 10.0 : double.infinity,
          height: isHorizontal ? double.infinity : 10.0,
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

  Future<void> _confirmDeleteObjects(BuildContext context) async {
    final keys = controller.objectSelection.isEmpty
        ? [
            if (controller.selectedObject != null)
              controller.selectedObject!.key
          ]
        : controller.objectSelection.keys.toList();
    if (keys.isEmpty) return;
    final profileId = controller.selectedProfile?.id;
    final bucketName = controller.selectedBucket?.name;
    final engineId = controller.activeEngineId;
    final confirmed = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
                title: Text('Delete ${keys.length} object(s)?'),
                content: Text(
                    'Bucket: $bucketName\n${keys.take(5).join('\n')}${keys.length > 5 ? '\n…' : ''}\n\nIn versioned buckets this may create delete markers. Permanent deletion cannot always be undone.'),
                actions: [
                  TextButton(
                      onPressed: () => Navigator.pop(context, false),
                      child: const Text('Cancel')),
                  DangerButton(
                      onPressed: () => Navigator.pop(context, true),
                      child: Text('Delete ${keys.length} object(s)'))
                ]));
    if (confirmed == true &&
        controller.selectedProfile?.id == profileId &&
        controller.selectedBucket?.name == bucketName &&
        controller.activeEngineId == engineId) {
      await controller.deleteObjectKeys(keys);
    }
  }

  Future<void> _confirmDeleteAll(BuildContext context) async {
    final profileId = controller.selectedProfile?.id;
    final engine = controller.activeEngineId;
    final config = controller.deleteAllConfig;
    final selectedBucket = controller.selectedBucket?.name;
    final bucket = config.bucketName.trim();
    if (profileId == null ||
        bucket.isEmpty ||
        controller.deleteAllState.running) {
      return;
    }
    var typed = '';
    final accepted = await showDialog<bool>(
        context: context,
        builder: (context) => StatefulBuilder(
            builder: (context, update) => AlertDialog(
                  title: const Text('Delete all objects?'),
                  content: SingleChildScrollView(
                      child: Column(mainAxisSize: MainAxisSize.min, children: [
                    Text(
                        'Bucket: $bucket\nEngine: $engine\nBatch size: ${config.batchSize}\n\nThis deletes every object. Type the bucket name to confirm.'),
                    TextField(
                        autofocus: true,
                        decoration: const InputDecoration(
                            labelText: 'Bucket name confirmation'),
                        onChanged: (v) => update(() => typed = v)),
                  ])),
                  actions: [
                    TextButton(
                        onPressed: () => Navigator.pop(context, false),
                        child: const Text('Cancel')),
                    DangerButton(
                        onPressed: typed.trim() == bucket
                            ? () => Navigator.pop(context, true)
                            : null,
                        child: const Text('Delete all objects'))
                  ],
                )));
    if (accepted == true &&
        controller.selectedProfile?.id == profileId &&
        controller.activeEngineId == engine &&
        controller.selectedBucket?.name == selectedBucket &&
        identical(controller.deleteAllConfig, config) &&
        !controller.deleteAllState.running) {
      await controller.runDeleteAllTool();
    }
  }

  Widget _objectPanel(BuildContext context, {required bool compact}) {
    final panel = ObjectPanel(
        controller: controller,
        onUpload: () => _showUploadPicker(context),
        onDelete: () => _confirmDeleteObjects(context),
        onCreatePrefix: () => _showCreatePrefixDialog(context),
        onInspector: () {
          if (MediaQuery.sizeOf(context).width >= 1000) {
            controller.updateSettings(controller.settings.copyWith(
                browserInspectorVisible:
                    !controller.settings.browserInspectorVisible));
          } else {
            _showInspectorDialog(context);
          }
        },
        onContextMenu: (object, position) =>
            _showObjectContextMenu(context, object, position));
    return panel;
  }

  Widget _inspectorPanel(BuildContext context, {required bool compact}) {
    final phone = Breakpoints.isPhone(MediaQuery.sizeOf(context).width);
    // Object versioning and presigned URLs are S3-only features.
    final isAzure = controller.selectedProfile?.endpointType ==
        EndpointProfileType.azureBlob;
    final contextualTabs = controller.selectedObject == null
        ? [
            BrowserInspectorTab.bucketInfo,
            BrowserInspectorTab.bucketAdmin,
            BrowserInspectorTab.versions
          ]
        : [
            BrowserInspectorTab.objectDetails,
            BrowserInspectorTab.objectPreview,
            BrowserInspectorTab.versions,
          ];
    contextualTabs.addAll([
      if (!contextualTabs.contains(BrowserInspectorTab.bucketInfo))
        BrowserInspectorTab.bucketInfo,
      if (!contextualTabs.contains(BrowserInspectorTab.bucketAdmin))
        BrowserInspectorTab.bucketAdmin,
      BrowserInspectorTab.tools,
      BrowserInspectorTab.eventsAndDebug,
      if (controller.selectedObject != null && !isAzure)
        BrowserInspectorTab.presign,
    ]);
    final availableTabs = contextualTabs
        .where(
          (entry) =>
              !isAzure ||
              (entry != BrowserInspectorTab.versions &&
                  entry != BrowserInspectorTab.presign),
        )
        .toList();
    final tab = availableTabs.contains(controller.inspectorTab)
        ? controller.inspectorTab
        : availableTabs.first;
    final desktopCompact = _desktopCompact(context);
    final panelBody = DirectionalSwitcher(
      position: tab.index,
      duration: AppMotion.duration(context,
          enabled: controller.settings.enableAnimations),
      child: KeyedSubtree(
          key: ValueKey(tab),
          child: switch (tab) {
            BrowserInspectorTab.bucketAdmin => _bucketAdminView(context),
            BrowserInspectorTab.bucketInfo => _bucketInfoView(context),
            BrowserInspectorTab.objectDetails => _objectDetailsView(context),
            BrowserInspectorTab.objectPreview => controller.selectedObject ==
                    null
                ? const Center(child: Text('Select an object to preview.'))
                : _adaptivePanelListView(context,
                    key: const ValueKey('object-preview'),
                    children: [
                        _objectPreviewSection(
                            context, controller.selectedObject!)
                      ]),
            BrowserInspectorTab.versions => _versionsView(context),
            BrowserInspectorTab.presign => _presignView(context),
            BrowserInspectorTab.tools => _toolsView(context),
            BrowserInspectorTab.eventsAndDebug => _eventsAndDebugView(context),
          }),
    );

    return Card(
      clipBehavior: Clip.antiAlias,
      child: Padding(
        padding: EdgeInsets.all(desktopCompact && !phone ? 12 : 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(children: [
              Expanded(
                  child: Text(
                      controller.selectedObject?.name ?? 'Bucket inspector',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.titleLarge)),
              if (controller.selectedObject != null)
                IconButton(
                    tooltip: 'Back to bucket',
                    onPressed: controller.clearSelectedObject,
                    icon: const Icon(Icons.arrow_back)),
              IconButton(
                  tooltip: 'Hide inspector',
                  onPressed: () {
                    controller.updateSettings(controller.settings
                        .copyWith(browserInspectorVisible: false));
                    if (phone) {
                      setState(
                          () => _mobileSection = _MobileBrowserSection.objects);
                    }
                    if (Navigator.of(context).canPop()) {
                      Navigator.of(context).pop();
                    }
                  },
                  icon: const Icon(Icons.close)),
            ]),
            const SizedBox(height: 12),
            CompactSelector<InspectorGroup>(
                expand: true,
                selected: tab.group,
                dense: true,
                options: [
                  for (final group in InspectorGroup.values)
                    if (availableTabs.any((t) => t.group == group))
                      CompactSelectorOption(
                          value: group,
                          label: switch (group) {
                            InspectorGroup.object => 'Object',
                            InspectorGroup.bucket => 'Bucket',
                            InspectorGroup.diagnostics => 'Diagnostics'
                          })
                ],
                onChanged: (group) {
                  final tabs =
                      availableTabs.where((t) => t.group == group).toList();
                  final remembered = controller.inspectorGroupTabs[group];
                  controller.setInspectorTab(
                      tabs.contains(remembered) ? remembered! : tabs.first);
                }),
            const SizedBox(height: 6),
            CompactSelector<BrowserInspectorTab>(
              selected: tab,
              wrap: false,
              dense: true,
              onChanged: controller.setInspectorTab,
              options: availableTabs
                  .where((t) => t.group == tab.group)
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
      BrowserInspectorTab.objectPreview => Icons.preview_outlined,
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
      BrowserInspectorTab.objectPreview => 'Preview',
      BrowserInspectorTab.versions => 'Versions',
      BrowserInspectorTab.presign => 'Share link',
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
        Wrap(spacing: 8, runSpacing: 8, children: [
          OutlinedButton(
              onPressed: () => _showJsonEditorDialog(context,
                  title: 'Lifecycle JSON',
                  initialValue: admin.lifecycleJson,
                  onSave: controller.saveBucketLifecycle),
              child: const Text('Edit lifecycle')),
          OutlinedButton(
              onPressed: () => _showJsonEditorDialog(context,
                  title: 'Policy JSON',
                  initialValue: admin.policyJson,
                  onSave: controller.saveBucketPolicy),
              child: const Text('Edit policy')),
          OutlinedButton(
              onPressed: () => _showJsonEditorDialog(context,
                  title: 'Encryption JSON',
                  initialValue: admin.encryptionJson,
                  onSave: controller.saveBucketEncryption),
              child: const Text('Edit encryption')),
        ]),
        const SizedBox(height: 12),
        _inlineStat('Selected bucket', admin.bucketName),
        const Divider(height: 16),
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
              : formatDateTime(bucket.createdAt!),
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
        const Divider(height: 16),
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
        const Divider(height: 16),
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
                padding: const EdgeInsets.all(10),
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
        _inlineStat('Last modified', formatDateTime(object.modifiedAt)),
        _inlineStat('Size', formatBytes(object.size)),
        const Divider(height: 16),
        Text('Metadata', style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 8),
        ...details.metadata.entries.map(
          (entry) => CopyableValue(
              label: entry.key, value: entry.value, controller: controller),
        ),
        const Divider(height: 16),
        Text('Headers', style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 8),
        ...details.headers.entries.map(
          (entry) => CopyableValue(
              label: entry.key, value: entry.value, controller: controller),
        ),
        const Divider(height: 16),
        Text('Tags', style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 8),
        ...details.tags.entries.map(
          (entry) => CopyableValue(
              label: entry.key, value: entry.value, controller: controller),
        ),
      ],
    );
  }

  Widget _objectPreviewSection(BuildContext context, ObjectEntry object) {
    final preview = controller.selectedObjectPreview;
    final theme = Theme.of(context);
    final canExpand = preview != null &&
        !preview.loading &&
        preview.supported &&
        (preview.kind == ObjectPreviewKind.image ||
            preview.kind == ObjectPreviewKind.text);
    final titleRow = Row(
      children: [
        Text('Preview', style: theme.textTheme.titleMedium),
        const Spacer(),
        if (canExpand)
          IconButton(
            tooltip: 'Open preview',
            onPressed: () => _showExpandedPreview(context, object, preview),
            icon: const Icon(Icons.open_in_full),
          ),
        IconButton(
          tooltip: 'Reload preview',
          onPressed: controller.refreshSelectedObjectPreview,
          icon: const Icon(Icons.refresh),
        ),
      ],
    );
    if (preview == null || preview.key != object.key) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          titleRow,
          const SizedBox(height: 8),
          const Text('Preview not loaded.'),
        ],
      );
    }
    if (preview.loading) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          titleRow,
          const SizedBox(height: 8),
          const LinearProgressIndicator(),
          const SizedBox(height: 8),
          Text(preview.message),
        ],
      );
    }

    final Widget body;
    if (!preview.supported || preview.kind == ObjectPreviewKind.unsupported) {
      body = Text(preview.message);
    } else if (preview.kind == ObjectPreviewKind.image && preview.url != null) {
      body = ClipRRect(
        borderRadius: BorderRadius.circular(8),
        child: Container(
          constraints: const BoxConstraints(maxHeight: 260),
          width: double.infinity,
          color: theme.colorScheme.surfaceContainerHighest,
          child: Image.network(
            preview.url!,
            fit: BoxFit.contain,
            loadingBuilder: (context, child, loadingProgress) {
              if (loadingProgress == null) {
                return child;
              }
              return const Center(child: CircularProgressIndicator());
            },
            errorBuilder: (context, error, stackTrace) =>
                const Center(child: Text('Not supported.')),
          ),
        ),
      );
    } else if (preview.kind == ObjectPreviewKind.text) {
      final text = preview.text ?? '';
      final visibleText =
          text.length > 12000 ? '${text.substring(0, 12000)}\n...' : text;
      final language = sourcePreviewLanguage(object.key, preview.contentType);
      body = Container(
        width: double.infinity,
        constraints: const BoxConstraints(maxHeight: 280),
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: theme.colorScheme.outlineVariant),
          color: theme.colorScheme.surface,
        ),
        child: SingleChildScrollView(
          child: language == null
              ? SelectableText(
                  visibleText.isEmpty ? '(empty file)' : visibleText,
                  style: theme.textTheme.bodySmall?.copyWith(
                    fontFamily: 'monospace',
                  ),
                )
              : SourceCodePreview(
                  source: visibleText.isEmpty ? '(empty file)' : visibleText,
                  language: language,
                  textStyle: theme.textTheme.bodySmall,
                ),
        ),
      );
    } else if (preview.kind == ObjectPreviewKind.video && preview.url != null) {
      body = Container(
        width: double.infinity,
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: theme.colorScheme.outlineVariant),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Icon(Icons.play_circle_outline, size: 32),
            const SizedBox(height: 8),
            const Text('Video preview URL generated.'),
            const SizedBox(height: 8),
            SelectableText(
              preview.url!,
              maxLines: 3,
            ),
          ],
        ),
      );
    } else {
      body = const Text('Not supported.');
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        titleRow,
        if (preview.contentType != null) ...[
          const SizedBox(height: 4),
          Text(
            preview.contentType!,
            style: theme.textTheme.bodySmall,
          ),
        ],
        const SizedBox(height: 8),
        body,
        if (preview.message.isNotEmpty) ...[
          const SizedBox(height: 8),
          Text(
            preview.message,
            style: theme.textTheme.bodySmall,
          ),
        ],
      ],
    );
  }

  Future<void> _showExpandedPreview(
    BuildContext context,
    ObjectEntry object,
    ObjectPreview preview,
  ) async {
    final mediaSize = MediaQuery.sizeOf(context);
    final canRenderHtml = preview.kind == ObjectPreviewKind.text &&
        isHtmlPreview(object.key, preview.contentType);
    var renderHtml = false;
    await showDialog<void>(
      context: context,
      builder: (dialogContext) {
        return StatefulBuilder(
          builder: (dialogContext, setDialogState) {
            final theme = Theme.of(dialogContext);
            return Dialog(
              insetPadding: const EdgeInsets.all(24),
              clipBehavior: Clip.antiAlias,
              child: ConstrainedBox(
                constraints: BoxConstraints(
                  maxWidth: math.min(mediaSize.width - 48, 1100),
                  maxHeight: mediaSize.height * 0.88,
                ),
                child: Column(
                  children: [
                    Padding(
                      padding: const EdgeInsets.fromLTRB(20, 14, 10, 12),
                      child: Row(
                        children: [
                          Icon(
                            preview.kind == ObjectPreviewKind.image
                                ? Icons.image_outlined
                                : Icons.description_outlined,
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  object.key,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: theme.textTheme.titleMedium,
                                ),
                                if (preview.contentType != null)
                                  Text(
                                    preview.contentType!,
                                    style: theme.textTheme.bodySmall,
                                  ),
                              ],
                            ),
                          ),
                          if (canRenderHtml) ...[
                            OutlinedButton.icon(
                              key: const ValueKey('html-render-toggle'),
                              onPressed: () => setDialogState(
                                () => renderHtml = !renderHtml,
                              ),
                              icon: Icon(renderHtml
                                  ? Icons.code
                                  : Icons.web_asset_outlined),
                              label: Text(
                                renderHtml ? 'View source' : 'Render page',
                              ),
                            ),
                            const SizedBox(width: 4),
                          ],
                          IconButton(
                            tooltip: 'Close preview',
                            onPressed: () => Navigator.of(dialogContext).pop(),
                            icon: const Icon(Icons.close),
                          ),
                        ],
                      ),
                    ),
                    const Divider(height: 1),
                    Expanded(
                      child: preview.kind == ObjectPreviewKind.image &&
                              preview.url != null
                          ? ColoredBox(
                              color: theme.colorScheme.surfaceContainerHighest,
                              child: InteractiveViewer(
                                minScale: 0.5,
                                maxScale: 5,
                                child: Center(
                                  child: Image.network(
                                    preview.url!,
                                    fit: BoxFit.contain,
                                    loadingBuilder:
                                        (context, child, loadingProgress) {
                                      if (loadingProgress == null) return child;
                                      return const CircularProgressIndicator();
                                    },
                                    errorBuilder:
                                        (context, error, stackTrace) =>
                                            const Text(
                                      'Could not load image preview.',
                                    ),
                                  ),
                                ),
                              ),
                            )
                          : DirectionalSwitcher(
                              position: renderHtml ? 1 : 0,
                              duration: AppMotion.duration(dialogContext,
                                  enabled: controller.settings.enableAnimations,
                                  milliseconds: 220),
                              child: renderHtml
                                  ? _expandedHtmlPreview(preview)
                                  : _expandedSourcePreview(
                                      dialogContext,
                                      object,
                                      preview,
                                    ),
                            ),
                    ),
                    if (preview.truncated)
                      Container(
                        width: double.infinity,
                        padding: const EdgeInsets.symmetric(
                          horizontal: 20,
                          vertical: 10,
                        ),
                        color: theme.colorScheme.surfaceContainerHigh,
                        child: Text(
                          'Preview is limited to the first ${preview.loadedBytes} bytes.',
                          style: theme.textTheme.bodySmall,
                        ),
                      ),
                  ],
                ),
              ),
            );
          },
        );
      },
    );
  }

  Widget _expandedSourcePreview(
    BuildContext context,
    ObjectEntry object,
    ObjectPreview preview,
  ) {
    final theme = Theme.of(context);
    final source =
        (preview.text ?? '').isEmpty ? '(empty file)' : preview.text!;
    final language = sourcePreviewLanguage(object.key, preview.contentType);
    return Scrollbar(
      key: const ValueKey('expanded-source-preview'),
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(20),
        child: SizedBox(
          width: double.infinity,
          child: language == null
              ? SelectableText(
                  source,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    fontFamily: 'monospace',
                  ),
                )
              : SourceCodePreview(
                  source: source,
                  language: language,
                  textStyle: theme.textTheme.bodyMedium,
                ),
        ),
      ),
    );
  }

  Widget _expandedHtmlPreview(ObjectPreview preview) {
    final previewUri = Uri.tryParse(preview.url ?? '');
    return ColoredBox(
      key: const ValueKey('expanded-html-preview'),
      color: Colors.white,
      child: Scrollbar(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: SelectionArea(
            child: HtmlWidget(
              preview.text ?? '',
              key: const ValueKey('rendered-html-page'),
              baseUrl: previewUri?.resolve('.'),
              onTapUrl: (_) async => true,
            ),
          ),
        ),
      ),
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
              onPressed: hasSelectedObject
                  ? () => _confirmDeleteObjects(context)
                  : null,
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
              child: AppSelectField<BrowserFilterMode>(
                value: options.filterMode,
                decoration: const InputDecoration(labelText: 'Filter mode'),
                items: const [
                  AppSelectItem(
                    value: BrowserFilterMode.prefix,
                    label: 'Prefix',
                  ),
                  AppSelectItem(
                    value: BrowserFilterMode.text,
                    label: 'Text',
                  ),
                  AppSelectItem(
                    value: BrowserFilterMode.regex,
                    label: 'Regex',
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
            title:
                Text(version.key, maxLines: 1, overflow: TextOverflow.ellipsis),
            subtitle:
                Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(
                  '${formatBytes(version.size)} · ${formatDateTime(version.modifiedAt)} · ${version.storageClass}'),
              CopyableValue(
                  label: 'Version ID',
                  value: version.versionId,
                  controller: controller,
                  monospace: true,
                  shorten: true),
            ]),
            trailing: Chip(
                label: Text(version.deleteMarker
                    ? 'Delete marker'
                    : version.latest
                        ? 'Latest'
                        : 'Prior'),
                backgroundColor: version.latest
                    ? Theme.of(context).colorScheme.primaryContainer
                    : null),
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
          min: 1,
          max: 10080,
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
          CopyableValue(
              label: 'Presigned URL',
              value: bundle.url,
              controller: controller),
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
        const SizedBox(height: 4),
        Text(
          'Generates test objects on the selected engine.',
          style: Theme.of(context).textTheme.bodySmall,
        ),
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
          min: 0,
          max: 5368709120,
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
          label: const Text('Run put test data'),
        ),
        ListTile(
          contentPadding: EdgeInsets.zero,
          title: Text(controller.putTestDataState.label),
          subtitle: Text(controller.putTestDataState.lastStatus),
        ),
        const Divider(height: 16),
        Text('Delete all', style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 4),
        Text(
          'Deletes every object in the bucket, running on the selected engine.',
          style: Theme.of(context).textTheme.bodySmall,
        ),
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
                min: 1,
                max: 1000,
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
                min: 1,
                max: 1000,
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
                min: 0,
                max: 2147483647,
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
          onPressed: controller.deleteAllState.running
              ? null
              : () => _confirmDeleteAll(context),
          icon: const Icon(Icons.delete_sweep_outlined),
          label: const Text('Run delete all'),
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
        const Divider(height: 16),
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
              subtitle: Text(formatDateTime(event.timestamp)),
            ),
          ),
        if ((details?.debugLogExcerpt ?? const <String>[]).isNotEmpty) ...[
          const Divider(height: 16),
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
    return ListView(key: key, primary: false, children: children);
  }

  Widget _inlineStat(String label, String value) {
    final theme = Theme.of(context);
    if (['Key', 'ETag', 'Bucket', 'Bucket name'].contains(label)) {
      return CopyableValue(label: label, value: value, controller: controller);
    }
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
      backgroundColor: enabled
          ? Theme.of(context).colorScheme.primaryContainer
          : Colors.transparent,
      labelStyle: TextStyle(
          color: enabled
              ? Theme.of(context).colorScheme.onPrimaryContainer
              : Theme.of(context).colorScheme.onSurfaceVariant),
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
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Align(
            alignment: Alignment.centerRight,
            child: IconButton(
                tooltip: 'Copy value',
                onPressed: () => copyValue(controller, 'Value', value),
                icon: const Icon(Icons.copy_outlined))),
        SourceCodePreview(source: value, language: 'json')
      ]),
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
    return SettingTextField(
        key: ValueKey(label),
        label: label,
        value: initialValue,
        onCommit: onSubmitted);
  }

  Widget _numberField(
      {required String label,
      required int initialValue,
      required ValueChanged<int> onSubmitted,
      int min = 1,
      int max = 2147483647}) {
    return SettingNumberField(
        key: ValueKey(label),
        label: label,
        value: initialValue,
        min: min,
        max: max,
        onCommit: onSubmitted);
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
    final profileId = controller.selectedProfile?.id;
    final engineId = controller.activeEngineId;
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
          DangerButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(force ? 'Force delete' : 'Delete'),
          ),
        ],
      ),
    );
    if (confirmed == true &&
        controller.selectedProfile?.id == profileId &&
        controller.activeEngineId == engineId) {
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
                    AppSelectField<String>(
                      value: destinations.contains(selectedDestination)
                          ? selectedDestination
                          : null,
                      decoration: const InputDecoration(
                        labelText: 'Destination bucket',
                      ),
                      items: destinations
                          .map(
                            (bucketName) => AppSelectItem(
                              value: bucketName,
                              label: bucketName,
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
    final value = await showDialog<String>(
        context: context,
        builder: (_) =>
            JsonEditorDialog(title: title, initialValue: initialValue));
    if (value != null) await onSave(value);
  }

  Future<void> _showTagEditorDialog(BuildContext context,
      {required Map<String, String> initialTags}) async {
    final value = await showDialog<Map<String, String>>(
        context: context,
        builder: (_) => TagEditorDialog(initialTags: initialTags));
    if (value != null) await controller.saveBucketTags(value);
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
        PopupMenuItem(
          value: 'delete',
          child: ListTile(
            iconColor: Theme.of(context).colorScheme.error,
            textColor: Theme.of(context).colorScheme.error,
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.delete_outline),
            title: const Text('Delete bucket'),
          ),
        ),
        PopupMenuItem(
          value: 'force-delete',
          child: ListTile(
            iconColor: Theme.of(context).colorScheme.error,
            textColor: Theme.of(context).colorScheme.error,
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.delete_forever_outlined),
            title: const Text('Force delete bucket'),
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

    final bucketListContent = ListView(
      key: _bucketListKey,
      controller: _bucketScrollController,
      padding: EdgeInsets.zero,
      primary: false,
      physics: const AlwaysScrollableScrollPhysics(),
      children: [
        if (buckets.isEmpty)
          EmptyState(
              icon: Icons.storage_outlined,
              title: hasProfile
                  ? 'No buckets loaded yet for this endpoint.'
                  : 'No connection configured',
              message: hasProfile
                  ? 'Refresh this connection to list its buckets.'
                  : 'Create a profile to connect to your storage.',
              action: TextButton(
                  onPressed: hasProfile
                      ? controller.refreshBuckets
                      : controller.openConnectionSettings,
                  child:
                      Text(hasProfile ? 'Refresh buckets' : 'Create profile')))
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
                    child: GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onSecondaryTapDown: (details) => _showBucketMenu(
                        context,
                        bucket,
                        details.globalPosition,
                      ),
                      child: InkWell(
                        borderRadius: BorderRadius.circular(8),
                        child: ListTile(
                          dense: desktopCompact,
                          leading: Icon(
                            Icons.folder_rounded,
                            color: selected
                                ? Theme.of(context).colorScheme.primary
                                : Theme.of(context)
                                    .colorScheme
                                    .onSurfaceVariant,
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
          mainAxisSize: MainAxisSize.max,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                    child: Text('Buckets',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.titleLarge)),
                if (isRefreshing)
                  OutlinedButton.icon(
                    onPressed: () => controller.cancelAction('refresh-buckets'),
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
            Expanded(
              child: bucketListViewport,
            ),
          ],
        ),
      ),
    );
  }
}
