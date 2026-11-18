import 'bucket_encryption_dialog.dart';
import '../settings/encryption_settings.dart';
import 'browser_content_signature.dart';
import '../widgets/controller_content_frame.dart';
import '../widgets/bounded_preview_image.dart';
import 'storage_preset_dialog.dart';
import 'bucket_copy_dialog.dart';
import 'storage_admin_dialog.dart';
import '../widgets/empty_state.dart';
import 'json_editor_dialog.dart';
import 'create_bucket_dialog.dart';
import 'rename_dialog.dart';
import '../widgets/app_form_dialog.dart';
import '../widgets/banner_activity/banner_activity_spec.dart';
import '../widgets/banner_activity/bucket_activity_status.dart';
import 'dart:convert' show utf8;
import 'tag_editor_dialog.dart';
import '../widgets/copyable_value.dart';
import '../utils/format.dart';
import '../widgets/setting_fields.dart';
import '../widgets/danger_button.dart';
import 'dart:io';
import 'dart:async';
import 'dart:math' as math;

import 'package:desktop_drop/desktop_drop.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

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
import 'object_table.dart' show ObjectTable;
import 'object_preview_dialog.dart';
import 'preview_source_view.dart';
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
  final Set<String> _expandedDetailSections = {};
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

  double _workspaceWidth = 0;

  void _toggleInspector() {
    if (!mounted) return;
    controller.pendingInspectorToggle = false;
    if (_workspaceWidth >= Breakpoints.smallDesktop) {
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

  Future<void> _pickFilesAndUpload({UploadTarget? target}) async {
    target ??= controller.captureUploadTarget();
    if (target == null) return;
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
    await controller.startSampleUpload(paths, target: target);
  }

  Future<void> _pickFolderAndUpload({UploadTarget? target}) async {
    target ??= controller.captureUploadTarget();
    if (target == null) return;
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
      target: target,
      objectKeyByPath: objectKeyByPath,
    );
  }

  Future<void> _uploadPaths(List<String> paths) async {
    final target = controller.captureUploadTarget();
    if (target == null) return;
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
      target: target,
      objectKeyByPath: objectKeyByPath,
    );
  }

  Future<void> _showUploadPicker(BuildContext context,
      {required bool compact}) async {
    final target = controller.captureUploadTarget();
    if (target == null) return;
    final selected = !compact
        ? await showAppMenu<String>(
            context: context,
            anchor: globalRectOf(context),
            items: [
              appMenuItem(
                  value: 'files',
                  label: 'Upload files',
                  icon: Icons.file_upload_outlined),
              if (!Platform.isIOS)
                appMenuItem(
                    value: 'folder',
                    label: 'Upload folder',
                    icon: Icons.drive_folder_upload_outlined),
            ],
          )
        : await showModalBottomSheet<String>(
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
      await _pickFolderAndUpload(target: target);
    } else {
      await _pickFilesAndUpload(target: target);
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
            replaceContent: true,
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
        _workspaceWidth = width;
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
            tablet ? 8.0 : (desktopCompact && !roomy ? 8.0 : 10.0);
        const panelGap = 8.0;
        final bucketPanelWidth =
            tablet ? 252.0 : (desktopCompact && !roomy ? 256.0 : 264.0);
        // Keep the object panel in one element slot while docking changes.
        // The inspector lays out at its final size while its viewport reveals
        // it, avoiding reflowing its fields through tiny intermediate widths.
        final axis = inspectorOnRight ? Axis.horizontal : Axis.vertical;
        final objectAndInspector = Flex(
          direction: axis,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(child: _objectPanel(context, compact: tablet)),
            TweenAnimationBuilder<double>(
              tween: Tween(end: showDockedInspector ? inspectorSize + 10 : 0),
              duration: AppMotion.duration(context,
                  enabled: controller.settings.enableAnimations,
                  milliseconds: 220),
              curve: Curves.easeInOutCubic,
              builder: (context, extent, child) => SizedBox(
                width: inspectorOnRight ? extent : null,
                height: inspectorOnRight ? null : extent,
                child: TickerMode(
                  enabled: extent > 0,
                  child: Offstage(
                    offstage: extent == 0,
                    child: ClipRect(
                      child: OverflowBox(
                        alignment: Alignment.topLeft,
                        minWidth: inspectorOnRight ? inspectorSize + 10 : null,
                        maxWidth: inspectorOnRight ? inspectorSize + 10 : null,
                        minHeight: inspectorOnRight ? null : inspectorSize + 10,
                        maxHeight: inspectorOnRight ? null : inspectorSize + 10,
                        child: IgnorePointer(
                          ignoring: !showDockedInspector,
                          child: ExcludeFocus(
                            excluding: !showDockedInspector,
                            child: ExcludeSemantics(
                              excluding: !showDockedInspector,
                              child: Opacity(
                                opacity:
                                    (extent / (inspectorSize + 10)).clamp(0, 1),
                                child: child,
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
              child: Flex(direction: axis, children: [
                _resizeHandle(axis),
                Expanded(child: _inspectorPanel(context, compact: false)),
              ]),
            ),
          ],
        );

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
    final profile = controller.selectedProfile?.id,
        bucket = controller.selectedBucket?.name;
    final prefix = controller.currentPrefix, engine = controller.activeEngineId;
    await showDialog<String>(
        context: context,
        builder: (_) => _CreatePrefixDialog(
              parentPrefix: prefix,
              onSave: (value) => controller.runFormAction(() async {
                if (controller.selectedProfile?.id != profile ||
                    controller.selectedBucket?.name != bucket ||
                    controller.currentPrefix != prefix ||
                    controller.activeEngineId != engine) {
                  throw StateError(
                      'The destination changed. Reopen this form in the target folder.');
                }
                await controller.createFolderMarker(value);
              }),
            ));
  }

  Future<void> _showObjectContextMenu(
    BuildContext context,
    ObjectEntry object,
    Rect anchor,
  ) async {
    final targetContext = (
      controller.activeEngineId,
      controller.selectedProfile,
      controller.selectedBucket?.name,
    );
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
          if (controller.isClientEncrypted(object))
            appMenuItem(
              value: 'encrypted-copy',
              icon: Icons.lock_outline,
              label: 'Download encrypted copy',
            ),
          appMenuItem(
            value: 'presign',
            icon: Icons.link,
            label: 'Generate presigned URL',
            enabled: controller.profileCapability('object.presign'),
          ),
        ],
        if (!object.isFolder &&
            (controller.selectedProfile?.endpointType ==
                    EndpointProfileType.awsS3 ||
                controller.selectedProfile?.endpointType.isGoogleCloudStorage ==
                    true))
          appMenuItem(
              value: 'rename',
              icon: Icons.drive_file_rename_outline,
              label: 'Rename object'),
        appMenuDivider(),
        appMenuItem(
          value: 'copy-key',
          icon: Icons.content_copy_outlined,
          label: 'Copy key',
        ),
        appMenuItem(
          value: 'copy-uri',
          icon: Icons.storage_outlined,
          label:
              controller.selectedProfile?.endpointType.isGoogleCloudStorage ==
                      true
                  ? 'Copy gs:// URI'
                  : 'Copy s3:// URI',
        ),
        if (!object.isFolder &&
            controller.selectedProfile?.endpointType !=
                EndpointProfileType.azureBlob)
          appMenuItem(
            value: 'copy-url',
            icon: Icons.add_link,
            label: 'Copy presigned URL',
            enabled: controller.profileCapability('object.presign'),
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

    if (selected == null) return;
    if (targetContext !=
        (
          controller.activeEngineId,
          controller.selectedProfile,
          controller.selectedBucket?.name,
        )) {
      return;
    }
    // The popup owns its target even if another asynchronous selection completed.
    await controller.setSelectedObject(object,
        openFolderOnSelect: false, loadArtifacts: false);
    switch (selected) {
      case 'rename':
        if (!context.mounted) return;
        await showDialog<String>(
            context: context,
            builder: (_) => RenameDialog(
                  path: controller.visibleObjectKey(object),
                  onSave: (target) =>
                      controller.renameObject(object.key, target),
                ));
        return;
      case 'copy-key':
        await copyValue(controller, 'Key', object.key);
        return;
      case 'copy-uri':
        await copyValue(
          controller,
          'S3 URI',
          '${controller.selectedProfile?.endpointType.isGoogleCloudStorage == true ? 'gs' : 's3'}://${controller.selectedBucket?.name}/${object.key}',
        );
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
        final width = _workspaceWidth;
        if (Breakpoints.isPhone(width)) {
          setState(() => _mobileSection = _MobileBrowserSection.inspector);
        } else if (width < Breakpoints.smallDesktop) {
          await _showInspectorDialog(context);
        } else {
          await controller.updateSettings(
              controller.settings.copyWith(browserInspectorVisible: true));
        }
        return;
      case 'encrypted-copy':
        await controller.startSampleDownload(
          key: object.key,
          encryptedCopy: true,
        );
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
          child: ControllerContentFrame(
            controller: controller,
            signature: () =>
                browserContentSignature(controller, compact: false),
            builder: (context) => _inspectorPanel(context, compact: false),
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
        animation: BucketActivityAnimation.clockSet,
        initialValue: controller.adminState?.bucketName == bucket.name
            ? controller.adminState!.lifecycleJson
            : '{\n  "Rules": []\n}',
        onSave: controller.saveBucketLifecycle,
      ),
      onEditBucketPolicy: (bucket) => _showJsonEditorDialog(
        context,
        title: 'Policy JSON',
        animation: BucketActivityAnimation.shieldScan,
        initialValue: controller.adminState?.bucketName == bucket.name
            ? controller.adminState!.policyJson
            : '{}',
        onSave: controller.saveBucketPolicy,
      ),
      onEditBucketEncryption: (bucket) =>
          showBucketEncryptionDialog(context, controller),
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

  Future<void> _confirmDeleteObjects(
    BuildContext context, {
    String? key,
  }) async {
    final keys = key != null
        ? [key]
        : controller.objectSelection.isEmpty
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
                scrollable: true,
                content: Text(
                  'Bucket: $bucketName\n${keys.take(5).map(controller.visibleStoredKey).join('\n')}${keys.length > 5 ? '\n…' : ''}\n\n${controller.selectedProfile?.endpointType.isGoogleCloudStorage == true ? 'Cloud Storage keeps noncurrent generations when versioning is enabled.' : 'In versioned buckets this may create delete markers.'} Permanent deletion cannot always be undone.',
                ),
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
        onUpload: (buttonContext) =>
            _showUploadPicker(buttonContext, compact: compact),
        onDelete: () => _confirmDeleteObjects(context),
        onCreatePrefix: () => _showCreatePrefixDialog(context),
        onInspector: _toggleInspector,
        onContextMenu: (object, position) =>
            _showObjectContextMenu(context, object, position));
    return panel;
  }

  Widget _inspectorPanel(BuildContext context, {required bool compact}) {
    final phone = Breakpoints.isPhone(MediaQuery.sizeOf(context).width);
    // Keep the existing Azure tabs; Cloud Storage exposes generations and signed links.
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
      if (controller.profileCapability('tools')) BrowserInspectorTab.tools,
      BrowserInspectorTab.eventsAndDebug,
      if (controller.selectedObject != null &&
          !isAzure &&
          controller.profileCapability('object.presign'))
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
          ];
    final desktopCompact = _desktopCompact(context);
    final panelBody = DirectionalSwitcher(
      key: const ValueKey('inspector-content-replacement'),
      axis: Axis.horizontal,
      replacementBackground: Theme.of(context).cardTheme.color,
      replaceContent: true,
      position: availableTabs.indexOf(tab),
      duration: AppMotion.duration(context,
          enabled: controller.settings.enableAnimations, milliseconds: 300),
      layoutBuilder: (current, previous) => Stack(
          fit: StackFit.expand,
          alignment: Alignment.topLeft,
          children: [...previous, if (current != null) current]),
      child: KeyedSubtree(
          key: ValueKey((tab, controller.selectedObject?.key)),
          child: switch (tab) {
            BrowserInspectorTab.bucketAdmin => _bucketAdminView(context),
            BrowserInspectorTab.bucketInfo => _bucketInfoView(context),
            BrowserInspectorTab.objectDetails => _objectDetailsView(context),
            BrowserInspectorTab.objectPreview =>
              controller.selectedObject == null
                  ? const Center(child: Text('Select an object to preview.'))
                  : _objectPreviewSection(context, controller.selectedObject!),
            BrowserInspectorTab.versions => _versionsView(context),
            BrowserInspectorTab.presign => _presignView(context),
            BrowserInspectorTab.tools => _toolsView(context),
            BrowserInspectorTab.eventsAndDebug => _eventsAndDebugView(context),
          }),
    );

    return Card(
      clipBehavior: Clip.antiAlias,
      child: Padding(
        padding: EdgeInsets.all(desktopCompact && !phone ? 10 : 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(children: [
              if (controller.selectedObject != null) ...[
                Icon(
                    ObjectTable.objectTypeIcon(
                        controller.visibleObjectKey(controller.selectedObject!),
                        controller
                            .objectContentType(controller.selectedObject!)),
                    size: 18,
                    color: Theme.of(context).colorScheme.primary),
                const SizedBox(width: 8),
              ],
              Expanded(
                  child: Text(
                      controller.selectedObject == null
                          ? 'Bucket inspector'
                          : controller
                              .visibleObjectName(controller.selectedObject!),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: controller.selectedObject == null
                          ? Theme.of(context).textTheme.titleLarge
                          : Theme.of(context).textTheme.titleMedium)),
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
            if (controller.selectedObject != null)
              Padding(
                  padding: const EdgeInsets.only(bottom: 4),
                  child: Text(
                      '${controller.objectContentType(controller.selectedObject!)} · ${formatBytes(controller.selectedObject!.size)}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color:
                              Theme.of(context).colorScheme.onSurfaceVariant))),
            const SizedBox(height: 4),
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
            const SizedBox(height: 6),
            Expanded(child: panelBody),
            if (controller.selectedObject != null &&
                !controller.selectedObject!.isFolder &&
                const [
                  BrowserInspectorTab.objectDetails,
                  BrowserInspectorTab.objectPreview
                ].contains(tab))
              _objectPreviewFooter(context, controller.selectedObject!),
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
      BrowserInspectorTab.versions =>
        controller.selectedProfile?.endpointType.isGoogleCloudStorage == true
            ? (controller.versions.isEmpty
                ? 'Generations'
                : 'Generations · ${controller.versions.length}')
            : controller.versions.isEmpty
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
        if (controller.selectedProfile?.endpointType.isGoogleCloudStorage ==
            true) ...[
          const Text(
            'Cloud Storage bucket administration is limited to versioning in this version.',
          ),
          AppSwitchTile(
            value: admin.versioningEnabled,
            title: const Text('Enable versioning'),
            onChanged: controller.profileCapability('bucket.admin_mutation')
                ? controller.setBucketVersioning
                : null,
          ),
        ],
        Wrap(spacing: 8, runSpacing: 8, children: [
          if (controller.selectedProfile?.endpointType.isGoogleCloudStorage !=
                  true &&
              controller.profileCapability('bucket.policy'))
            FilledButton.tonal(
              onPressed: () => showDialog<void>(
                  context: context,
                  builder: (_) => StoragePresetDialog(
                      controller: controller, lifecycle: false)),
              child: const Text('Access presets'),
            ),
          if (controller.selectedProfile?.endpointType.isGoogleCloudStorage !=
                  true &&
              controller.profileCapability('bucket.lifecycle'))
            FilledButton.tonal(
                onPressed: () => showDialog<void>(
                    context: context,
                    builder: (_) => StoragePresetDialog(
                        controller: controller, lifecycle: true)),
                child: const Text('Lifecycle presets')),
          if (controller.profileCapability('storage.admin'))
            OutlinedButton(
                onPressed: () => showDialog<void>(
                    context: context,
                    builder: (_) => StorageAdminDialog(controller: controller)),
                child: const Text('Advanced administration')),
          if (controller.profileCapability('bucket.lifecycle'))
            OutlinedButton(
                onPressed: () => _showJsonEditorDialog(context,
                    title: 'Lifecycle JSON',
                    animation: BucketActivityAnimation.clockSet,
                    initialValue: admin.lifecycleJson,
                    onSave: controller.saveBucketLifecycle),
                child: const Text('Edit lifecycle')),
          if (controller.profileCapability('bucket.policy'))
            OutlinedButton(
              onPressed: () => _showJsonEditorDialog(context,
                  title: 'Policy JSON',
                  animation: BucketActivityAnimation.shieldScan,
                  initialValue: admin.policyJson,
                  onSave: controller.saveBucketPolicy),
              child: const Text('Edit policy'),
            ),
          if (controller.profileCapability('bucket.encryption') ||
              controller.capabilities.any((c) =>
                  c.key == 'object.clientEncryption' &&
                  c.state == CapabilityState.supported))
            OutlinedButton(
                onPressed: () =>
                    showBucketEncryptionDialog(context, controller),
                child: const Text('Edit encryption')),
        ]),
        const SizedBox(height: 12),
        _inlineStat('Selected bucket', admin.bucketName),
        const Divider(height: 16),
        if (controller.profileCapability('bucket.lifecycle')) ...[
          Text('Lifecycle JSON',
              style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 8),
          _jsonBlock(admin.lifecycleJson),
        ],
        const SizedBox(height: 12),
        if (controller.profileCapability('bucket.policy')) ...[
          Text('Policy JSON', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 8),
          _jsonBlock(admin.policyJson),
        ],
        const SizedBox(height: 12),
        if (controller.profileCapability('bucket.cors')) ...[
          Text('CORS JSON', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 8),
          _jsonBlock(admin.corsJson),
        ],
        const SizedBox(height: 12),
        if (controller.profileCapability('bucket.encryption')) ...[
          Text('Encryption JSON',
              style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 8),
          _jsonBlock(admin.encryptionJson),
          const SizedBox(height: 12),
          TextButton(
              onPressed: () => showBucketEncryptionDialog(context, controller),
              child: const Text('Bucket encryption…')),
        ],
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
              if (controller
                      .selectedProfile?.endpointType.isGoogleCloudStorage !=
                  true)
                _pill('Object lock', admin.objectLockEnabled),
              if (controller.profileCapability('bucket.lifecycle'))
                _pill('Lifecycle', admin.lifecycleEnabled),
              if (controller.profileCapability('bucket.policy'))
                _pill('Policy', admin.policyAttached),
              if (controller.profileCapability('bucket.cors'))
                _pill('CORS', admin.corsEnabled),
              if (controller.profileCapability('bucket.encryption'))
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
          controller.currentPrefix.isEmpty
              ? 'Root'
              : controller.visiblePrefix(controller.currentPrefix),
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
          if (controller.profileCapability('bucket.encryption'))
            _inlineStat('Encryption', admin.encryptionSummary),
          if (controller.profileCapability('bucket.tagging'))
            _inlineStat('Bucket tags', '${admin.tags.length} tags'),
          if (controller.profileCapability('bucket.lifecycle'))
            _inlineStat(
              'Lifecycle rules',
              '${admin.lifecycleRules.length} rules',
            ),
          if (controller.profileCapability('bucket.policy'))
            _inlineStat(
              'Bucket policy',
              admin.policyAttached ? 'Attached' : 'Not attached',
            ),
          if (controller.profileCapability('bucket.cors'))
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
        if (controller.profileCapability('bucket.tagging')) ...[
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
        ],
        if (controller.profileCapability('bucket.lifecycle')) ...[
          const Divider(height: 16),
          Text('Lifecycle rules',
              style: Theme.of(context).textTheme.titleMedium),
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
        _inlineStat('Key', controller.visibleObjectKey(object)),
        _inlineStat('Size', formatBytes(object.size)),
        if (controller.isClientEncrypted(object)) ...[
          _inlineStat('Contents', 'Client-side encrypted (age)'),
          _inlineStat('Vault key', controller.clientRuleFor(object.key)!.label),
          if (controller.clientPlaintextSize(object.key) case final size?)
            _inlineStat('Plaintext size', formatBytes(size)),
          TextButton(
            onPressed: () => controller.startSampleDownload(
              key: object.key,
              encryptedCopy: true,
            ),
            child: const Text('Download encrypted copy'),
          ),
          if (controller.encryptionKeyStore?.isUnlocked != true)
            TextButton(
              onPressed: () async {
                await showEncryptionKeyFileDialog(context, controller);
                controller.refreshSelectedObjectPreview();
              },
              child: const Text('Unlock key file…'),
            ),
        ],
        _inlineStat('Last modified', formatDateTime(object.modifiedAt)),
        _inlineStat('Content type', controller.objectContentType(object)),
        _inlineStat('Storage class', object.storageClass),
        if (details.encryption case final encryption?) ...[
          _inlineStat('Encryption', encryption.modeLabel),
          if (encryption.kmsKeyId != null)
            CopyableValue(
              label: 'KMS key',
              value: encryption.kmsKeyId!,
              controller: controller,
              shorten: true,
            ),
          if (encryption.bucketKeyEnabled != null)
            _inlineStat(
              'Bucket key',
              encryption.bucketKeyEnabled! ? 'Enabled' : 'Disabled',
            ),
          if (encryption.encryptionScope != null)
            _inlineStat('Encryption scope', encryption.encryptionScope!),
          if (encryption.isCustomerKey)
            _inlineStat(
              'Customer key',
              controller.matchingEncryptionKey(encryption)?.label ??
                  'key not in key file',
            ),
        ],
        if (object.etag != null && object.etag!.isNotEmpty)
          _inlineStat('ETag', object.etag!),
        const Divider(height: 12),
        _detailSection(context, object, 'Metadata', details.metadata,
            empty: 'No user metadata'),
        _detailSection(context, object, 'Headers', details.headers,
            empty: 'No headers returned'),
        if (controller.profileCapability('object.tags'))
          _detailSection(context, object, 'Tags', details.tags,
              empty: 'No tags'),
        const SizedBox(height: 12),
        if (controller.profileCapability('storage.admin'))
          Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                  onPressed: () => showDialog<void>(
                      context: context,
                      builder: (_) => StorageAdminDialog(
                          controller: controller, objectKey: object.key)),
                  icon: const Icon(Icons.tune, size: 16),
                  label: const Text('Manage object'))),
      ],
    );
  }

  Widget _detailSection(BuildContext context, ObjectEntry object, String title,
          Map<String, String> entries, {required String empty}) =>
      ExpansionTile(
          key: ValueKey(
              'object-section-${controller.selectedProfile?.id}-${controller.selectedBucket?.name}-${object.key}-$title'),
          initiallyExpanded: _expandedDetailSections.contains(title),
          onExpansionChanged: (expanded) {
            // ExpansionTile owns its animation. Remember only these three
            // presentation choices, without notifying/rebuilding during restore.
            if (expanded) {
              _expandedDetailSections.add(title);
            } else {
              _expandedDetailSections.remove(title);
            }
          },
          dense: true,
          tilePadding: EdgeInsets.zero,
          childrenPadding: const EdgeInsets.only(bottom: 8),
          expandedCrossAxisAlignment: CrossAxisAlignment.stretch,
          title: Row(children: [
            Text(title, style: Theme.of(context).textTheme.bodyMedium),
            const SizedBox(width: 6),
            Text('· ${formatCount(entries.length)}',
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: Theme.of(context).colorScheme.onSurfaceVariant)),
          ]),
          children: entries.isEmpty
              ? [
                  Padding(
                      padding: const EdgeInsets.symmetric(vertical: 8),
                      child: Text(empty,
                          style: Theme.of(context).textTheme.bodySmall))
                ]
              : entries.entries
                  .map((entry) => CopyableValue(
                      label: entry.key,
                      value: entry.value,
                      controller: controller,
                      monospace: title == 'Headers'))
                  .toList());

  /// The inline text preview stops here to keep the inspector responsive;
  /// the expanded preview shows all loaded text.
  static const _inlinePreviewCharLimit = 12000;

  Widget _objectPreviewFooter(BuildContext context, ObjectEntry object) {
    final preview = controller.selectedObjectPreview;
    final matching = preview != null && preview.key == object.key;
    final loading = matching && preview.loading;
    final ready = matching &&
        !preview.loading &&
        preview.supported &&
        const [ObjectPreviewKind.text, ObjectPreviewKind.image]
            .contains(preview.kind);
    if (matching && !loading && !ready) return const SizedBox.shrink();
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      const Divider(height: 1),
      Tooltip(
          message: ready ? 'Open preview' : 'Load preview',
          child: TextButton.icon(
              key: ready || loading
                  ? null
                  : const ValueKey('object-preview-load'),
              onPressed: loading
                  ? null
                  : ready
                      ? () => _showExpandedPreview(context, object, preview)
                      : () {
                          controller.setInspectorTab(
                              BrowserInspectorTab.objectPreview);
                          controller.refreshSelectedObjectPreview();
                        },
              icon: loading
                  ? const SizedBox(
                      width: 15,
                      height: 15,
                      child: CircularProgressIndicator(strokeWidth: 2))
                  : Icon(ready ? Icons.open_in_full : Icons.visibility_outlined,
                      size: 17),
              label: Text(loading
                  ? 'Loading preview…'
                  : ready
                      ? 'Open preview'
                      : 'Load preview'))),
    ]);
  }

  Widget _objectPreviewSection(BuildContext context, ObjectEntry object) {
    final preview = controller.selectedObjectPreview;
    final stage = preview == null || preview.key != object.key
        ? 0
        : preview.loading
            ? 1
            : 2;
    return DirectionalSwitcher(
      key: const ValueKey('preview-content-replacement'),
      position: stage,
      duration: AppMotion.duration(context,
          enabled: controller.settings.enableAnimations, milliseconds: 260),
      layoutBuilder: (current, previous) => Stack(
          fit: StackFit.expand,
          children: [...previous, if (current != null) current]),
      child: KeyedSubtree(
          key: ValueKey((object.key, stage)),
          child: _objectPreviewContent(context, object)),
    );
  }

  Widget _objectPreviewContent(BuildContext context, ObjectEntry object) {
    final preview = controller.selectedObjectPreview;
    final theme = Theme.of(context);
    if (preview == null || preview.key != object.key) {
      return const Center(
          key: ValueKey('object-preview'),
          child: Text('Preview not loaded yet.'));
    }
    if (preview.loading) {
      return Column(
          key: const ValueKey('object-preview'),
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const LinearProgressIndicator(),
            const SizedBox(height: 12),
            Text(preview.message)
          ]);
    }
    final text = preview.text ?? '';
    final inlineCut = preview.kind == ObjectPreviewKind.text &&
        text.length > _inlinePreviewCharLimit;
    final visibleText =
        inlineCut ? '${text.substring(0, _inlinePreviewCharLimit)}\n…' : text;
    final Widget body;
    if (!preview.supported || preview.kind == ObjectPreviewKind.unsupported) {
      body = Center(
          child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(preview.message),
                  if (controller.isClientEncrypted(object)) ...[
                    if (controller.encryptionKeyStore?.isUnlocked != true &&
                        !AppPlatform.isMobile)
                      TextButton(
                        onPressed: () async {
                          await showEncryptionKeyFileDialog(
                              context, controller);
                          controller.refreshSelectedObjectPreview();
                        },
                        child: const Text('Unlock key file…'),
                      ),
                    TextButton(
                      onPressed: () => controller.startSampleDownload(
                        key: object.key,
                        encryptedCopy: true,
                      ),
                      child: const Text('Download encrypted copy'),
                    ),
                  ],
                ],
              )));
    } else if (preview.kind == ObjectPreviewKind.image &&
        (preview.url != null || preview.bytes != null)) {
      body = BoundedPreviewImage(
          url: preview.url,
          bytes: preview.bytes,
          etag: object.etag,
          maximumMegapixels:
              controller.settings.performance.imagePreviewMegapixels);
    } else if (preview.kind == ObjectPreviewKind.text) {
      body = PreviewSourceView(
          source: visibleText,
          objectKey: controller.visibleObjectKey(object),
          contentType: preview.contentType,
          compact: true);
    } else if (preview.kind == ObjectPreviewKind.video && preview.url != null) {
      body = SingleChildScrollView(
          padding: const EdgeInsets.all(12),
          child:
              Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            const Icon(Icons.play_circle_outline, size: 28),
            const SizedBox(height: 8),
            const Text('Video preview URL generated.'),
            const SizedBox(height: 8),
            SelectableText(preview.url!),
          ]));
    } else {
      body = const Center(child: Text('Not supported.'));
    }
    Widget content(Widget? copyAction) => Column(
            key: const ValueKey('object-preview'),
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(children: [
                Expanded(
                    child: Text(
                        sourcePreviewLanguage(
                                    controller.visibleObjectKey(object),
                                    preview.contentType)
                                ?.toUpperCase() ??
                            preview.contentType ??
                            'Preview',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodySmall?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant))),
                if (copyAction != null) copyAction,
                IconButton(
                    tooltip: 'Reload preview',
                    onPressed: controller.refreshSelectedObjectPreview,
                    icon: const Icon(Icons.refresh, size: 18)),
              ]),
              const Divider(height: 1),
              Expanded(
                  child: ColoredBox(
                      color: theme.colorScheme.surfaceContainerLowest,
                      child: body)),
              if (inlineCut || preview.truncated)
                Padding(
                    key: ValueKey(inlineCut
                        ? 'inline-preview-truncated'
                        : 'inline-preview-byte-limit'),
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    child: Text(
                        inlineCut
                            ? 'Showing the first ${formatCount(_inlinePreviewCharLimit)} characters. Open preview for all loaded text.'
                            : 'Limited to the first ${formatBytes(preview.loadedBytes)} of this object.',
                        style: theme.textTheme.bodySmall?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant))),
            ]);
    return preview.kind == ObjectPreviewKind.text && preview.supported
        ? HoverCopyRegion(
            label: 'loaded text',
            value: text,
            controller: controller,
            builder: (context, copyAction) => content(copyAction))
        : content(null);
  }

  Future<void> _showExpandedPreview(
          BuildContext context, ObjectEntry object, ObjectPreview preview) =>
      showDialog<void>(
          context: context,
          builder: (_) => ObjectPreviewDialog(
              controller: controller, object: object, preview: preview));

  Widget _versionsView(BuildContext context) {
    final options = controller.versionBrowserOptions;
    final versions = controller.visibleVersions;
    final object = controller.selectedObject;
    final hasSelectedObject = object != null;

    final controls = <Widget>[
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
            onPressed: hasSelectedObject &&
                    (!AppPlatform.isMobile ||
                        !controller.isClientEncrypted(object))
                ? () => controller.startSampleDownload(key: object.key)
                : null,
            icon: const Icon(Icons.download),
            label: const Text('Download current object'),
          ),
          OutlinedButton.icon(
            onPressed: hasSelectedObject
                ? () => _confirmDeleteObjects(context, key: object.key)
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
          child: Text('Showing all versioned objects in the selected bucket.'),
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
        title: Text(
            controller.selectedProfile?.endpointType.isGoogleCloudStorage ==
                    true
                ? 'Show generations'
                : 'Show versions'),
      ),
      if (controller.selectedProfile?.endpointType.isGoogleCloudStorage != true)
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
        subtitle:
            controller.selectedProfile?.endpointType.isGoogleCloudStorage ==
                    true
                ? const Text('Versions are Cloud Storage generations.')
                : Text(
                    'Delete markers: ${controller.visibleDeleteMarkerCount}',
                  ),
      ),
      const Divider(height: 20),
      if (controller.selectedProfile?.endpointType.isGoogleCloudStorage != true)
        const Text(
            'Select a version below to inspect, download, share, restore or delete that exact version.'),
    ];
    return ListView.builder(
      key: const ValueKey('versions'),
      primary: false,
      itemCount: controls.length +
          versions.length +
          (controller.versionCursor.hasMore ? 1 : 0),
      itemBuilder: (context, index) {
        if (index < controls.length) return controls[index];
        final versionIndex = index - controls.length;
        if (versionIndex == versions.length) {
          return OutlinedButton(
              onPressed: controller.loadMoreVersions,
              child: const Text('Load more versions'));
        }
        final version = versions[versionIndex];
        return ListTile(
          contentPadding: EdgeInsets.zero,
          dense: true,
          title: Text(controller.visibleStoredKey(version.key),
              maxLines: 1, overflow: TextOverflow.ellipsis),
          subtitle:
              Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(
                '${formatBytes(version.size)} · ${formatDateTime(version.modifiedAt)} · ${version.storageClass}'),
            CopyableValue(
                label: controller.selectedProfile?.endpointType
                            .isGoogleCloudStorage ==
                        true
                    ? 'Generation'
                    : 'Version ID',
                value: version.versionId,
                controller: controller,
                monospace: true,
                shorten: true),
          ]),
          onTap: () => controller
                      .selectedProfile?.endpointType.isGoogleCloudStorage ==
                  true
              ? showDialog<void>(
                  context: context,
                  builder: (dialogContext) => AlertDialog(
                    title: const Text('Cloud Storage generation'),
                    content: SelectableText(
                      '${controller.visibleStoredKey(version.key)}\nGeneration: ${version.versionId}\n${formatBytes(version.size)}',
                    ),
                    actions: [
                      TextButton(
                        onPressed: () => Navigator.pop(dialogContext),
                        child: const Text('Close'),
                      ),
                      TextButton(
                        onPressed: () async {
                          final confirmed = await showDialog<bool>(
                            context: dialogContext,
                            builder: (context) => AlertDialog(
                              title: const Text(
                                'Permanently delete generation?',
                              ),
                              content: const Text(
                                'This deletes this exact generation and cannot be undone.',
                              ),
                              actions: [
                                TextButton(
                                  onPressed: () =>
                                      Navigator.pop(context, false),
                                  child: const Text('Cancel'),
                                ),
                                TextButton(
                                  onPressed: () => Navigator.pop(context, true),
                                  child: const Text('Delete generation'),
                                ),
                              ],
                            ),
                          );
                          if (confirmed == true) {
                            await controller.deleteGeneration(version);
                            if (dialogContext.mounted) {
                              Navigator.pop(dialogContext);
                            }
                          }
                        },
                        child: const Text('Delete generation…'),
                      ),
                    ],
                  ),
                )
              : showDialog<void>(
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
        );
      },
    );
  }

  Widget _presignView(BuildContext context) {
    if (!controller.profileCapability('object.presign')) {
      return Center(
          child: Text(controller.profileCapabilityReason('object.presign')));
    }
    final bundle = controller.selectedObjectDetails?.presignedUrl;
    return _adaptivePanelListView(
      context,
      key: const ValueKey('presign'),
      children: [
        if (controller.selectedObject != null &&
            controller.isClientEncrypted(controller.selectedObject!))
          const Padding(
            padding: EdgeInsets.only(bottom: 12),
            child: Text(
              'This link returns the encrypted file. The recipient needs the vault key and the standard age tool to decrypt its contents.',
            ),
          ),
        _numberField(
          label: 'Expiration (minutes)',
          min: 1,
          max: 10080,
          initialValue: controller.settings.defaultPresignMinutes,
          onSubmitted: (value) {
            return controller.updateSettings(
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
    if (!controller.profileCapability('tools')) {
      return Center(child: Text(controller.profileCapabilityReason('tools')));
    }
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
            return null;
          },
        ),
        const SizedBox(height: 8),
        _textField(
          label: 'Prefix',
          initialValue: testData.prefix,
          onSubmitted: (value) {
            controller.updateTestDataConfig(testData.copyWith(prefix: value));
            return null;
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
            return null;
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
                  return null;
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
                  return null;
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
            return null;
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
            return null;
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
                  return null;
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
                  return null;
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
                  return null;
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
                  return null;
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
                  return null;
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
                  return null;
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

    return CustomScrollView(
      primary: false,
      key: const ValueKey('events-and-debug'),
      slivers: [
        SliverToBoxAdapter(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
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
            ],
          ),
        ),
        StructuredLogList(
          entries: scopedEvents,
          textScalePercent: controller.settings.logTextScalePercent,
          emptyMessage: 'No bucket-scoped trace events recorded yet.',
          sliver: true,
        ),
        SliverToBoxAdapter(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Divider(height: 16),
              Text('Object debug events',
                  style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(height: 8),
              if (debugEvents.isEmpty)
                const Text('No object-specific debug events recorded.'),
            ],
          ),
        ),
        if (debugEvents.isNotEmpty)
          SliverList.builder(
            itemCount: debugEvents.length,
            itemBuilder: (context, index) {
              final event = debugEvents[index];
              return ListTile(
                contentPadding: EdgeInsets.zero,
                dense: true,
                title: Text('[${event.level}] ${event.message}'),
                subtitle: Text(formatDateTime(event.timestamp)),
              );
            },
          ),
        SliverToBoxAdapter(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if ((details?.debugLogExcerpt ?? const <String>[])
                  .isNotEmpty) ...[
                const Divider(height: 16),
                Text('Debug excerpt',
                    style: Theme.of(context).textTheme.titleMedium),
                const SizedBox(height: 8),
                _jsonBlock(
                    (details?.debugLogExcerpt ?? const <String>[]).join('\n')),
              ],
            ],
          ),
        ),
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

  Widget _inlineStat(String label, String value) => CopyableValue(
      label: label,
      value: value,
      controller: controller,
      monospace: label == 'ETag');

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
    required FutureOr<Object?> Function(String) onSubmitted,
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
      required FutureOr<Object?> Function(int) onSubmitted,
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
    final profile = controller.selectedProfile;
    final engine = controller.activeEngineId;
    if (profile == null) return;
    await showDialog<String>(
        context: context,
        builder: (_) => CreateBucketDialog(
              provider: profile.endpointType,
              onSave: (name, versioning, lock) =>
                  controller.runFormAction(() async {
                if (controller.selectedProfile?.id != profile.id ||
                    controller.activeEngineId != engine) {
                  throw StateError(
                      'The endpoint changed. Reopen this form for the selected endpoint.');
                }
                await controller.createBucket(
                    bucketName: name,
                    enableVersioning: versioning,
                    enableObjectLock: lock);
              }),
            ));
  }

  Future<void> _confirmDeleteBucket(
    BuildContext context,
    String bucketName, {
    bool force = false,
  }) async {
    final profileId = controller.selectedProfile?.id;
    final engineId = controller.activeEngineId;
    final typed = TextEditingController();
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
          builder: (context, update) => AlertDialog(
                scrollable: true,
                title: Text(force ? 'Force delete bucket' : 'Delete bucket'),
                content: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      SelectableText(force
                          ? 'Delete every object and version in "$bucketName", then delete the bucket itself?'
                          : 'Delete "$bucketName"? The bucket must be empty.'),
                      if (force) ...[
                        const SizedBox(height: 16),
                        TextField(
                            controller: typed,
                            autocorrect: false,
                            enableSuggestions: false,
                            decoration: const InputDecoration(
                                labelText: 'Type the bucket name to confirm'),
                            onChanged: (_) => update(() {})),
                      ]
                    ]),
                actions: [
                  TextButton(
                    onPressed: () => Navigator.of(context).pop(false),
                    child: const Text('Cancel'),
                  ),
                  DangerButton(
                    onPressed: force && typed.text != bucketName
                        ? null
                        : () => Navigator.of(context).pop(true),
                    child: Text(force ? 'Force delete' : 'Delete'),
                  ),
                ],
              )),
    );
    typed.dispose();
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
    required BucketActivityAnimation animation,
  }) async {
    final profile = controller.selectedProfile?.id,
        bucket = controller.selectedBucket?.name;
    final engine = controller.activeEngineId;
    await showDialog<String>(
        context: context,
        builder: (_) => JsonEditorDialog(
              title: title,
              initialValue: initialValue,
              savingStatus: BucketActivityStatus(
                controller: controller,
                animation: animation,
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
              ),
              onSave: (value) => controller.runFormAction(() async {
                if (controller.selectedProfile?.id != profile ||
                    controller.selectedBucket?.name != bucket ||
                    controller.activeEngineId != engine) {
                  throw StateError(
                      'The target changed. Reopen this editor for the selected bucket.');
                }
                await onSave(value);
              }),
            ));
  }

  Future<void> _showTagEditorDialog(BuildContext context,
      {required Map<String, String> initialTags}) async {
    final profile = controller.selectedProfile?.id,
        bucket = controller.selectedBucket?.name;
    final engine = controller.activeEngineId;
    await showDialog<Map<String, String>>(
        context: context,
        builder: (_) => TagEditorDialog(
              initialTags: initialTags,
              savingStatus: BucketActivityStatus(
                controller: controller,
                animation: BucketActivityAnimation.hangTag,
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
              ),
              onSave: (value) => controller.runFormAction(() async {
                if (controller.selectedProfile?.id != profile ||
                    controller.selectedBucket?.name != bucket ||
                    controller.activeEngineId != engine) {
                  throw StateError(
                      'The target changed. Reopen this editor for the selected bucket.');
                }
                await controller.saveBucketTags(value);
              }),
            ));
  }
}

class _CreatePrefixDialog extends StatefulWidget {
  const _CreatePrefixDialog({required this.parentPrefix, required this.onSave});
  final String parentPrefix;
  final Future<void> Function(String) onSave;

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

  @override
  Widget build(BuildContext context) {
    final name = _nameController.text;
    final key = '${widget.parentPrefix}$name${name.endsWith('/') ? '' : '/'}';
    final tooLong = utf8.encode(key).length > 1024;
    return AppFormDialog<String>(
      title: 'Create prefix',
      width: 420,
      submitLabel: 'Create',
      dirty: name.isNotEmpty,
      valid: name.isNotEmpty && !tooLong,
      value: () => name,
      onSave: widget.onSave,
      child: Builder(
          builder: (context) => TextField(
              controller: _nameController,
              autofocus: true,
              autocorrect: false,
              enableSuggestions: false,
              textInputAction: TextInputAction.done,
              decoration: InputDecoration(
                  labelText: 'Prefix name',
                  hintText: 'reports/2026',
                  errorText: tooLong
                      ? 'The full key exceeds 1,024 UTF-8 bytes.'
                      : null),
              onChanged: (_) => setState(() {}),
              onSubmitted: (_) => submitAppForm(context))),
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
    // Native Cloud Storage retains versioning; advanced panels follow capabilities.
    final controller = widget.controller;
    final profileId = controller.selectedProfile?.id;
    final isAzure = controller.selectedProfile?.endpointType ==
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
        if (controller.canUnlockBucketVault(bucket.name))
          appMenuItem(
            value: 'unlock-vault',
            icon: Icons.lock_open_rounded,
            label: 'Unlock vault…',
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
          if (widget.controller.profileCapability('bucket.lifecycle'))
            appMenuItem(
              value: 'lifecycle',
              icon: Icons.schedule_outlined,
              label: 'Lifecycle policy',
            ),
          if (widget.controller.profileCapability('bucket.policy'))
            appMenuItem(
              value: 'policy',
              icon: Icons.policy_outlined,
              label: 'Bucket policy',
            ),
          if (widget.controller.profileCapability('bucket.encryption') ||
              widget.controller.capabilities.any((c) =>
                  c.key == 'object.clientEncryption' &&
                  c.state == CapabilityState.supported))
            appMenuItem(
              value: 'encryption',
              icon: Icons.lock_outline,
              label: 'Bucket encryption',
            ),
          if (widget.controller.profileCapability('bucket.tagging'))
            appMenuItem(
              value: 'tags',
              icon: Icons.sell_outlined,
              label: 'Bucket tagging',
            ),
        ],
        // Azure has no bucket default to edit, but vault encryption by this
        // app works there too and is set up in the same dialog.
        if (isAzure &&
            widget.controller.capabilities.any((c) =>
                c.key == 'object.clientEncryption' &&
                c.state == CapabilityState.supported))
          appMenuItem(
            value: 'encryption',
            icon: Icons.lock_outline,
            label: 'Bucket encryption',
          ),
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
          enabled: widget.controller.profileCapability('tools'),
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
    if (selected == 'unlock-vault') {
      // Unlocking opens the shared local key file. It doesn't need a listing
      // or a change to the bucket currently open in the browser.
      if (context.mounted &&
          controller.selectedProfile?.id == profileId &&
          controller.canUnlockBucketVault(bucket.name)) {
        await showEncryptionKeyFileDialog(context, controller);
      }
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
                                  minVerticalPadding: desktopCompact ? 4 : 8,
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
        padding: EdgeInsets.all(desktopCompact ? 10 : 16),
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
                contentPadding: EdgeInsets.fromLTRB(10, 8, 10, 8),
              ),
              onChanged: (value) {
                setState(() {
                  _bucketSearchQuery = value.trim();
                });
              },
            ),
            if (!hasProfile)
              const Flexible(
                  child: SingleChildScrollView(
                      child: Padding(
                padding: EdgeInsets.only(top: 8),
                child: Text(
                    'No endpoint profile is selected. Create one in Settings, save it, then come back here to list buckets.'),
              ))),
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
