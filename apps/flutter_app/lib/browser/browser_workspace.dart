import 'storage_preset_dialog.dart';
import 'bucket_copy_dialog.dart';
import 'storage_admin_dialog.dart';
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
import '../widgets/app_menu.dart';
import '../widgets/app_select_field.dart';
import '../widgets/app_switch.dart';
import '../widgets/compact_selector.dart';
import '../widgets/underline_tabs.dart';
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

  static const double _rightInspectorMinWidth = 1180;

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
          return _responsiveLayout(context,
              phone: true, child: _mobileBrowserShell(context));
        }

        // Tablet range (and a desktop window resized into it): keep buckets
        // and objects side by side, with inspector access through the info
        // button used by compact object controls.
        final tablet = sizeClass == WindowSizeClass.tablet;
        // Wide windows are short on height, not width, so the inspector
        // docks beside the list once the object panel keeps enough room.
        final inspectorOnRight = !tablet &&
            width >= _rightInspectorMinWidth &&
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

        return _responsiveLayout(context,
            phone: false,
            child: AnimatedPadding(
              duration: AppMotion.duration(context,
                  enabled: controller.settings.enableAnimations,
                  milliseconds: 220),
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
            ));
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

  Widget _responsiveLayout(BuildContext context,
          {required bool phone, required Widget child}) =>
      ResponsiveLayoutTransition(
        layoutKey: phone,
        duration: AppMotion.duration(context,
            enabled: controller.settings.enableAnimations, milliseconds: 240),
        child: child,
      );

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
    Rect anchor,
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
    final selected = await showAppMenu<String>(
      context: context,
      anchor: anchor,
      items: [
        appMenuItem(
          value: object.isFolder ? 'open-folder' : 'inspect',
          icon:
              object.isFolder ? Icons.folder_open_outlined : Icons.info_outline,
          label: object.isFolder ? 'Open folder' : 'Inspect object',
        ),
        if (!object.isFolder) ...[
          appMenuItem(
            value: 'download',
            icon: Icons.download_outlined,
            label: 'Download',
          ),
          appMenuItem(
            value: 'presign',
            icon: Icons.link,
            label: 'Generate presigned URL',
          ),
        ],
        appMenuDivider(),
        appMenuItem(
          value: 'copy-key',
          icon: Icons.content_copy_outlined,
          label: 'Copy key',
        ),
        appMenuItem(
          value: 'copy-uri',
          icon: Icons.storage_outlined,
          label: 'Copy s3:// URI',
        ),
        if (!object.isFolder &&
            controller.selectedProfile?.endpointType !=
                EndpointProfileType.azureBlob)
          appMenuItem(
            value: 'copy-url',
            icon: Icons.add_link,
            label: 'Copy presigned URL',
          ),
        appMenuDivider(),
        appMenuItem(
          value: 'delete',
          icon: Icons.delete_outline,
          destructive: true,
          label: object.isFolder ? 'Delete folder marker' : 'Delete object',
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
        if (!mounted || !context.mounted) return;
        // Use the workspace width, which can be narrower than the window
        // because of the navigation rail or UI scaling.
        final width = context.size?.width ?? MediaQuery.sizeOf(context).width;
        if (Breakpoints.isPhone(width)) {
          setState(() => _mobileSection = _MobileBrowserSection.inspector);
        } else if (width < Breakpoints.smallDesktop) {
          await _showInspectorDialog(context);
        } else {
          await controller.updateSettings(
              controller.settings.copyWith(browserInspectorVisible: true));
        }
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
          child: AnimatedBuilder(
            animation: controller,
            builder: (context, _) => _inspectorPanel(context, compact: false),
          ),
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
                    if (controller.selectedProfile?.endpointType ==
                        EndpointProfileType.s3Compatible)
                      const Text(
                          'After normal retries, a confirmed never-versioned bucket may require overwriting a stuck key with an empty object before deleting it. Failed recovery is reported, including any empty object left behind. Versioned and suspended buckets never use this fallback.'),
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
    // Tabs for the current context sit in the row; bucket and diagnostic
    // views stay one click away in the overflow menu.
    final primaryTabs = controller.selectedObject == null
        ? const [
            BrowserInspectorTab.bucketInfo,
            BrowserInspectorTab.bucketAdmin,
            BrowserInspectorTab.versions,
          ]
        : const [
            BrowserInspectorTab.objectDetails,
            BrowserInspectorTab.objectPreview,
            BrowserInspectorTab.versions,
            BrowserInspectorTab.presign,
          ];
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
            const SizedBox(height: 8),
            UnderlineTabs<BrowserInspectorTab>(
              selected: tab,
              onChanged: controller.setInspectorTab,
              overflowTooltip: 'More inspector views',
              tabs: [
                for (final entry in availableTabs)
                  if (primaryTabs.contains(entry))
                    UnderlineTab(value: entry, label: _inspectorLabel(entry)),
              ],
              overflow: [
                for (final entry in availableTabs)
                  if (!primaryTabs.contains(entry))
                    UnderlineTab(value: entry, label: _inspectorLabel(entry)),
              ],
            ),
            const SizedBox(height: 12),
            Expanded(child: panelBody),
          ],
        ),
      ),
    );
  }

  String _inspectorLabel(BrowserInspectorTab entry) {
    return switch (entry) {
      BrowserInspectorTab.bucketAdmin => 'Bucket config',
      BrowserInspectorTab.bucketInfo => 'Bucket info',
      BrowserInspectorTab.objectDetails => 'Details',
      BrowserInspectorTab.objectPreview => 'Preview',
      BrowserInspectorTab.versions => controller.versions.isEmpty
          ? 'Versions'
          : 'Versions · ${controller.versions.length}',
      BrowserInspectorTab.presign => 'Share',
      BrowserInspectorTab.tools => 'Tools',
      BrowserInspectorTab.eventsAndDebug => 'Events & Debug',
    };
  }

  List<Widget> _configurationWarnings(BucketAdminState admin) => [
        for (final entry in admin.sections.entries)
          if (entry.value is Map &&
              !{'supported', 'missing', 'absent', 'available'}
                  .contains((entry.value as Map)['state']))
            Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Text(
                    '${entry.key}: ${(entry.value as Map)['state'] ?? 'unknown'} — ${(entry.value as Map)['message'] ?? 'Configuration could not be read.'}')),
      ];

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
        ..._configurationWarnings(admin),
        Wrap(spacing: 8, runSpacing: 8, children: [
          FilledButton.tonal(
              onPressed: () => showDialog<void>(
                  context: context,
                  builder: (_) => StoragePresetDialog(
                      controller: controller, lifecycle: false)),
              child: const Text('Access presets')),
          FilledButton.tonal(
              onPressed: () => showDialog<void>(
                  context: context,
                  builder: (_) => StoragePresetDialog(
                      controller: controller, lifecycle: true)),
              child: const Text('Lifecycle presets')),
          OutlinedButton(
              onPressed: () => showDialog<void>(
                  context: context,
                  builder: (_) => StorageAdminDialog(controller: controller)),
              child: const Text('Advanced administration')),
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
        if (admin != null) ..._configurationWarnings(admin),
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
                  : '${admin.objectLockMode} - ${admin.objectLockRetentionYears ?? admin.objectLockRetentionDays ?? 0} ${admin.objectLockRetentionYears != null ? 'year' : 'day'} retention',
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
    if (object == null) {
      return const EmptyState(
          icon: Icons.info_outline,
          title: 'No object selected',
          message:
              'Select an object to inspect its metadata, headers and tags.');
    }
    if (details == null) {
      if (controller.isBusy('select-object')) {
        return const Center(
            key: ValueKey('object-details-loading'),
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              CircularProgressIndicator(),
              SizedBox(height: 12),
              Text('Loading object details…'),
            ]));
      }
      if (object.isFolder) {
        return const EmptyState(
            icon: Icons.folder_outlined,
            title: 'Prefix selected',
            message:
                'Prefixes have no metadata, headers or tags of their own.');
      }
      // Loading finished without details: the read failed and the error is
      // in the event log.
      return EmptyState(
          icon: Icons.error_outline,
          title: 'Details unavailable',
          message: 'The object details could not be read. '
              'Events & Debug has the error.',
          action: TextButton.icon(
              key: const ValueKey('object-details-retry'),
              onPressed: () => controller.setSelectedObject(object,
                  openFolderOnSelect: false),
              icon: const Icon(Icons.refresh),
              label: const Text('Retry')));
    }

    return _adaptivePanelListView(
      context,
      key: const ValueKey('object-details'),
      children: [
        Align(
            alignment: Alignment.centerLeft,
            child: OutlinedButton(
                onPressed: () => showDialog<void>(
                    context: context,
                    builder: (_) => StorageAdminDialog(
                        controller: controller, objectKey: object.key)),
                child: const Text('Manage object'))),
        _inlineStat('Key', object.key),
        _inlineStat('Size', formatBytes(object.size)),
        _inlineStat('Last modified', formatDateTime(object.modifiedAt)),
        _inlineStat('Content type', controller.objectContentType(object)),
        _inlineStat('Storage class', object.storageClass),
        if (object.etag != null && object.etag!.isNotEmpty)
          _inlineStat('ETag', object.etag!),
        const Divider(height: 16),
        ..._detailSection(context, 'Metadata', details.metadata,
            empty: 'No user metadata'),
        const Divider(height: 16),
        ..._detailSection(context, 'Headers', details.headers,
            empty: 'No headers returned'),
        const Divider(height: 16),
        ..._detailSection(context, 'Tags', details.tags, empty: 'No tags'),
      ],
    );
  }

  /// A titled key/value section that says so when it has no entries, so an
  /// empty section is not mistaken for one that failed to load.
  List<Widget> _detailSection(
      BuildContext context, String title, Map<String, String> entries,
      {required String empty}) {
    final theme = Theme.of(context);
    return [
      Text(title, style: theme.textTheme.titleMedium),
      const SizedBox(height: 8),
      if (entries.isEmpty)
        Text(empty,
            style: theme.textTheme.bodySmall
                ?.copyWith(color: theme.colorScheme.onSurfaceVariant))
      else
        ...entries.entries.map(
          (entry) => CopyableValue(
              label: entry.key, value: entry.value, controller: controller),
        ),
    ];
  }

  /// The inline text preview stops here to keep the inspector responsive;
  /// the expanded preview shows all loaded text.
  static const _inlinePreviewCharLimit = 12000;

  Widget _objectPreviewSection(BuildContext context, ObjectEntry object) {
    final preview = controller.selectedObjectPreview;
    final theme = Theme.of(context);
    final canExpand = preview != null &&
        !preview.loading &&
        preview.supported &&
        (preview.kind == ObjectPreviewKind.image ||
            preview.kind == ObjectPreviewKind.text);
    final loaded =
        preview != null && preview.key == object.key && !preview.loading;
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
        // Before the first load the body offers 'Load preview' instead.
        if (loaded)
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
          Text('Preview not loaded yet.', style: theme.textTheme.bodyMedium),
          const SizedBox(height: 4),
          TextButton.icon(
              key: const ValueKey('object-preview-load'),
              onPressed: controller.refreshSelectedObjectPreview,
              icon: const Icon(Icons.visibility_outlined),
              label: const Text('Load preview')),
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
    var inlineCut = false;
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
            errorBuilder: (context, error, stackTrace) => const Padding(
                padding: EdgeInsets.all(16),
                child: Center(child: Text('Could not load image preview.'))),
          ),
        ),
      );
    } else if (preview.kind == ObjectPreviewKind.text) {
      final text = preview.text ?? '';
      inlineCut = text.length > _inlinePreviewCharLimit;
      final visibleText = inlineCut
          ? '${text.substring(0, _inlinePreviewCharLimit)}\n...'
          : text;
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
        if (inlineCut)
          Container(
            key: const ValueKey('inline-preview-truncated'),
            width: double.infinity,
            margin: const EdgeInsets.only(top: 8),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            decoration: BoxDecoration(
              color: theme.colorScheme.surfaceContainerHigh,
              borderRadius: BorderRadius.circular(8),
            ),
            child: Text(
              'Showing the first ${formatCount(_inlinePreviewCharLimit)} '
              'characters here. Open preview to read all loaded text.',
              style: theme.textTheme.bodySmall,
            ),
          ),
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
                                // Long keys ellipsize; the full key stays
                                // available on hover and to screen readers.
                                Tooltip(
                                  message: object.key,
                                  child: Text(
                                    object.key,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: theme.textTheme.titleMedium,
                                  ),
                                ),
                                if (preview.contentType != null)
                                  Text(
                                    preview.contentType!,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
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
                          'Preview is limited to the first ${formatBytes(preview.loadedBytes)} of this object.',
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
              label: const Text('Download current object'),
            ),
            OutlinedButton.icon(
              onPressed: hasSelectedObject
                  ? () => _confirmDeleteObjects(context)
                  : null,
              icon: const Icon(Icons.delete_outline),
              label: const Text('Delete current object'),
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
        AppSwitchTile(
          value: options.showVersions,
          onChanged: (value) {
            controller.updateVersionBrowserOptions(
              options.copyWith(showVersions: value),
            );
          },
          title: const Text('Show versions'),
        ),
        AppSwitchTile(
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
        const Text(
            'Select a version below to inspect, download, share, restore or delete that exact version.'),
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
            onTap: () => showDialog<void>(
                context: context,
                builder: (_) => StorageAdminDialog(
                    controller: controller,
                    objectKey: version.key,
                    versionId: version.versionId,
                    deleteMarker: version.deleteMarker)),
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
        if (controller.versionCursor.hasMore)
          OutlinedButton(
              onPressed: controller.loadMoreVersions,
              child: const Text('Load more versions')),
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
        AppSwitchTile(
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
    if (['Key', 'ETag', 'Bucket', 'Bucket name'].contains(label)) {
      return CopyableValue(label: label, value: value, controller: controller);
    }
    return LabeledValue(label: label, child: SelectableText(value));
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
                    AppSwitchTile(
                      value: enableVersioning,
                      onChanged: (value) =>
                          setState(() => enableVersioning = value),
                      title: const Text('Enable versioning'),
                    ),
                    AppSwitchTile(
                      value: enableObjectLock,
                      onChanged: (value) =>
                          setState(() => enableObjectLock = value),
                      title: const Text('Enable object lock'),
                    ),
                    const Align(
                      alignment: Alignment.centerLeft,
                      child: Text(
                        'Object Lock enables versioning. Existing S3 buckets can also enable it through advanced administration when supported by the endpoint.',
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
    await showDialog<void>(
        context: context,
        builder: (_) => BucketCopyDialog(
            controller: controller, sourceBucket: sourceBucket));
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
    Rect anchor,
  ) async {
    // Versioning, lifecycle, policy, encryption, and tagging are S3-only
    // bucket admin features.
    final isAzure = widget.controller.selectedProfile?.endpointType ==
        EndpointProfileType.azureBlob;
    final selected = await showAppMenu<String>(
      context: context,
      anchor: anchor,
      items: [
        appMenuItem(
          value: 'open',
          icon: Icons.folder_open_outlined,
          label: 'Open bucket',
        ),
        appMenuItem(
          value: 'copy',
          icon: Icons.copy_all_outlined,
          label: 'Copy bucket',
        ),
        if (!isAzure) ...[
          appMenuDivider(),
          appMenuItem(
            value: bucket.versioningEnabled
                ? 'suspend-versioning'
                : 'enable-versioning',
            icon: bucket.versioningEnabled
                ? Icons.pause_circle_outline
                : Icons.history_toggle_off_rounded,
            label: bucket.versioningEnabled
                ? 'Suspend versioning'
                : 'Enable versioning',
          ),
          appMenuItem(
            value: 'lifecycle',
            icon: Icons.schedule_outlined,
            label: 'Lifecycle policy',
          ),
          appMenuItem(
            value: 'policy',
            icon: Icons.policy_outlined,
            label: 'Bucket policy',
          ),
          appMenuItem(
            value: 'encryption',
            icon: Icons.lock_outline,
            label: 'Bucket encryption',
          ),
          appMenuItem(
            value: 'tags',
            icon: Icons.sell_outlined,
            label: 'Bucket tagging',
          ),
        ],
        appMenuDivider(),
        appMenuItem(
          value: 'delete',
          icon: Icons.delete_outline,
          destructive: true,
          label: 'Delete bucket',
        ),
        appMenuItem(
          value: 'force-delete',
          icon: Icons.delete_forever_outlined,
          destructive: true,
          label: 'Force delete bucket',
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
                return _BucketRowHover(
                    builder: (hovered) => Padding(
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
                                details.globalPosition & Size.zero,
                              ),
                              child: InkWell(
                                borderRadius: BorderRadius.circular(8),
                                child: ListTile(
                                  dense: desktopCompact,
                                  contentPadding: const EdgeInsets.symmetric(
                                      horizontal: 10),
                                  minLeadingWidth: 20,
                                  horizontalTitleGap: 10,
                                  minVerticalPadding: 8,
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
                                  title: Row(children: [
                                    Flexible(
                                      child: Tooltip(
                                        message: bucket.name,
                                        waitDuration:
                                            const Duration(milliseconds: 600),
                                        child: Text(
                                          bucket.name,
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                          style: Theme.of(context)
                                              .textTheme
                                              .bodyMedium
                                              ?.copyWith(
                                                  fontWeight: FontWeight.w600),
                                        ),
                                      ),
                                    ),
                                    if (bucket.versioningEnabled) ...[
                                      const SizedBox(width: 6),
                                      const _StatusBadge(
                                        label: 'Versioned',
                                        tooltip:
                                            'Versioning is enabled for this bucket',
                                      ),
                                    ],
                                  ]),
                                  subtitle: Text(
                                    '${bucket.region} · ${formatCount(bucket.objectCountHint)} objects',
                                    style: Theme.of(context)
                                        .textTheme
                                        .bodySmall
                                        ?.copyWith(
                                            color: Theme.of(context)
                                                .colorScheme
                                                .onSurfaceVariant),
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                  // Actions appear on hover, focus and touch so
                                  // bucket names keep the row's full width.
                                  // Right-click opens the same menu.
                                  trailing: hovered || AppPlatform.isMobile
                                      ? Builder(
                                          // The menu opens from this
                                          // button's bounds.
                                          builder: (buttonContext) =>
                                              IconButton(
                                            tooltip: 'Bucket actions',
                                            visualDensity:
                                                VisualDensity.compact,
                                            onPressed: () => _showBucketMenu(
                                              context,
                                              bucket,
                                              globalRectOf(buttonContext),
                                            ),
                                            icon: const Icon(Icons.more_horiz),
                                          ),
                                        )
                                      : null,
                                  onTap: () => widget.onOpenBucket(bucket),
                                ),
                              ),
                            ),
                          ),
                        ));
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
                Container(
                  margin: const EdgeInsets.only(left: 6, right: 6),
                  padding:
                      const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                  decoration: BoxDecoration(
                    color: Theme.of(context).colorScheme.primaryContainer,
                    borderRadius: BorderRadius.circular(5),
                  ),
                  child: Text('${buckets.length}',
                      style: Theme.of(context).textTheme.labelSmall),
                ),
                if (isRefreshing)
                  IconButton(
                    onPressed: () => controller.cancelAction('refresh-buckets'),
                    icon: const Icon(Icons.stop_circle_outlined, size: 18),
                    tooltip: 'Cancel bucket listing',
                  )
                else
                  IconButton(
                    tooltip: 'Refresh buckets',
                    onPressed: hasProfile ? controller.refreshBuckets : null,
                    icon: const Icon(Icons.refresh),
                  ),
                IconButton(
                  key: _bucketActionBarKey,
                  tooltip: isCreatingBucket ? 'Creating bucket…' : 'New bucket',
                  onPressed: hasProfile && !isCreatingBucket
                      ? widget.onCreateBucket
                      : null,
                  icon: isCreatingBucket
                      ? widget.inlineSpinnerBuilder()
                      : const Icon(Icons.add),
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

class _BucketRowHover extends StatefulWidget {
  const _BucketRowHover({required this.builder});
  final Widget Function(bool active) builder;
  @override
  State<_BucketRowHover> createState() => _BucketRowHoverState();
}

class _BucketRowHoverState extends State<_BucketRowHover> {
  bool _hover = false, _focus = false;
  @override
  Widget build(BuildContext context) => MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: Focus(
          canRequestFocus: false,
          skipTraversal: true,
          onFocusChange: (v) => setState(() => _focus = v),
          child: widget.builder(_hover || _focus)));
}

class _StatusBadge extends StatelessWidget {
  const _StatusBadge({required this.label, required this.tooltip});
  final String label, tooltip;
  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Tooltip(
      message: tooltip,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
        decoration: BoxDecoration(
          color: scheme.tertiaryContainer,
          borderRadius: BorderRadius.circular(4),
        ),
        child: Text(
          label,
          style: Theme.of(context).textTheme.labelSmall?.copyWith(
              color: scheme.onTertiaryContainer, fontWeight: FontWeight.w700),
        ),
      ),
    );
  }
}
