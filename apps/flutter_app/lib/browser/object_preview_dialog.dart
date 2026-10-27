import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter_widget_from_html_core/flutter_widget_from_html_core.dart';
import '../controllers/app_controller.dart';
import '../models/domain_models.dart';
import '../services/source_preview.dart';
import '../theme/app_motion.dart';
import '../utils/format.dart';
import '../widgets/copyable_value.dart';
import 'preview_source_view.dart';

/// Preview data and identity are captured together. Changing the selection
/// behind the dialog cannot relabel the document being read.
class ObjectPreviewDialog extends StatefulWidget {
  const ObjectPreviewDialog(
      {super.key,
      required this.controller,
      required this.object,
      required this.preview});
  final AppController controller;
  final ObjectEntry object;
  final ObjectPreview preview;
  @override
  State<ObjectPreviewDialog> createState() => _ObjectPreviewDialogState();
}

class _ObjectPreviewDialogState extends State<ObjectPreviewDialog> {
  bool _renderHtml = false;
  final _imageTransform = TransformationController();
  ObjectPreview get preview => widget.preview;
  ObjectEntry get object => widget.object;
  bool get _image => preview.kind == ObjectPreviewKind.image;
  @override
  void dispose() {
    _imageTransform.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final media = MediaQuery.sizeOf(context);
    final phone = media.width < 600;
    return Dialog(
        insetPadding: EdgeInsets.all(phone ? 12 : 24),
        clipBehavior: Clip.antiAlias,
        child: ConstrainedBox(
            constraints: BoxConstraints(
                maxWidth: math.min(media.width - (phone ? 24 : 48), 1100),
                maxHeight: media.height * (phone ? .94 : .88)),
            child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Padding(
                      padding: const EdgeInsets.fromLTRB(14, 10, 8, 10),
                      child: Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Expanded(
                                child: HoverCopyRegion(
                                    label: 'object key',
                                    value: object.key,
                                    controller: widget.controller,
                                    builder: (context, copyAction) =>
                                        Row(children: [
                                          Icon(
                                              _image
                                                  ? Icons.image_outlined
                                                  : Icons.description_outlined,
                                              color: theme.colorScheme.primary,
                                              size: 18),
                                          const SizedBox(width: 8),
                                          Expanded(
                                              child: Column(
                                                  crossAxisAlignment:
                                                      CrossAxisAlignment.start,
                                                  children: [
                                                Text(object.name,
                                                    style: theme
                                                        .textTheme.titleMedium,
                                                    maxLines: 2,
                                                    overflow:
                                                        TextOverflow.ellipsis),
                                                Tooltip(
                                                    message: object.key,
                                                    child: Text(object.key,
                                                        maxLines: 2,
                                                        overflow: TextOverflow
                                                            .ellipsis,
                                                        style: theme
                                                            .textTheme.bodySmall
                                                            ?.copyWith(
                                                                color: theme
                                                                    .colorScheme
                                                                    .onSurfaceVariant))),
                                              ])),
                                          copyAction,
                                        ]))),
                            IconButton(
                                tooltip: 'Close preview',
                                onPressed: () => Navigator.of(context).pop(),
                                icon: const Icon(Icons.close, size: 20)),
                          ])),
                  const Divider(height: 1),
                  Expanded(
                      child: LayoutBuilder(builder: (context, constraints) {
                    final split = constraints.maxWidth >= 700 &&
                        MediaQuery.textScalerOf(context).scale(14) < 24;
                    if (!split) {
                      return Column(children: [
                        _narrowContext(context,
                            maxDetailsHeight:
                                math.min(150, constraints.maxHeight * .25)),
                        Expanded(child: _content(context)),
                      ]);
                    }
                    final railWidth =
                        (MediaQuery.textScalerOf(context).scale(14) / 14 * 158)
                            .clamp(158.0, 220.0);
                    return Row(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          SizedBox(
                              width: railWidth, child: _contextRail(context)),
                          const VerticalDivider(width: 1),
                          Expanded(child: _content(context)),
                        ]);
                  })),
                  if (preview.truncated) _limitNotice(context),
                  const Divider(height: 1),
                  Padding(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 14, vertical: 8),
                      child: Wrap(
                          alignment: WrapAlignment.spaceBetween,
                          spacing: 12,
                          runSpacing: 4,
                          children: [
                            Text(preview.contentType ?? 'Unknown content type',
                                style: theme.textTheme.bodySmall),
                            Text(
                                _image
                                    ? 'Pan and zoom'
                                    : _renderHtml
                                        ? 'Static HTML · scripts disabled'
                                        : 'Selectable source',
                                style: theme.textTheme.bodySmall?.copyWith(
                                    color: theme.colorScheme.onSurfaceVariant)),
                          ])),
                ])));
  }

  List<(String, String)> get _contextValues => [
        ('Content type', preview.contentType ?? 'Unknown'),
        ('Size', formatBytes(object.size)),
        ('Modified', formatDateTime(object.modifiedAt)),
        ('Storage', object.storageClass),
        ('Preview', '${formatBytes(preview.loadedBytes)} loaded'),
      ];

  Widget _contextRail(BuildContext context) => ListView(
          key: const ValueKey('preview-context-rail'),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
          children: [
            Text('Object', style: Theme.of(context).textTheme.titleSmall),
            const SizedBox(height: 8),
            for (final (label, value) in _contextValues)
              Padding(
                  padding: const EdgeInsets.only(bottom: 10),
                  child: _contextValue(context, label, value)),
          ]);

  Widget _contextValue(BuildContext context, String label, String value) =>
      HoverCopyRegion(
          label: label,
          value: value,
          controller: widget.controller,
          builder: (context, copyAction) =>
              Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Expanded(
                    child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                      Text(label,
                          style: Theme.of(context)
                              .textTheme
                              .bodySmall
                              ?.copyWith(
                                  color: Theme.of(context)
                                      .colorScheme
                                      .onSurfaceVariant)),
                      const SizedBox(height: 3),
                      SelectableText(value,
                          style: Theme.of(context).textTheme.bodySmall),
                    ])),
                copyAction,
              ]));

  Widget _narrowContext(BuildContext context,
          {required double maxDetailsHeight}) =>
      ExpansionTile(
          key: const ValueKey('preview-context-disclosure'),
          dense: true,
          tilePadding: const EdgeInsets.symmetric(horizontal: 14),
          title: Text('File details',
              style: Theme.of(context).textTheme.bodySmall),
          subtitle: Text(
              '${preview.contentType ?? 'Unknown type'} · ${formatBytes(object.size)}',
              style: Theme.of(context).textTheme.bodySmall,
              maxLines: 1,
              overflow: TextOverflow.ellipsis),
          children: [
            ConstrainedBox(
                constraints: BoxConstraints(maxHeight: maxDetailsHeight),
                child: SingleChildScrollView(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                    child: LayoutBuilder(
                        builder: (context, constraints) =>
                            Wrap(spacing: 12, runSpacing: 10, children: [
                              for (final (label, value) in _contextValues)
                                SizedBox(
                                    width: constraints.maxWidth < 360
                                        ? constraints.maxWidth
                                        : (constraints.maxWidth - 12) / 2,
                                    child: _contextValue(context, label, value))
                            ]))))
          ]);

  Widget _content(BuildContext context) {
    if (_image) {
      return Column(children: [
        Expanded(
            child: ColoredBox(
                color: Theme.of(context).colorScheme.surfaceContainerLowest,
                child: InteractiveViewer(
                    transformationController: _imageTransform,
                    minScale: .5,
                    maxScale: 5,
                    child: Center(
                        child: preview.url == null
                            ? const Text('Image unavailable.')
                            : Image.network(preview.url!,
                                fit: BoxFit.contain,
                                loadingBuilder: (context, child, progress) =>
                                    progress == null
                                        ? child
                                        : const CircularProgressIndicator(),
                                errorBuilder: (context, error, stack) =>
                                    const Text(
                                        'Could not load image preview.')))))),
        const Divider(height: 1),
        ValueListenableBuilder<Matrix4>(
            valueListenable: _imageTransform,
            builder: (context, transform, _) =>
                Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                  IconButton(
                      tooltip: 'Zoom out',
                      onPressed: () => _zoom(.8),
                      icon: const Icon(Icons.remove, size: 18)),
                  Text('${(transform.getMaxScaleOnAxis() * 100).round()}%',
                      style: Theme.of(context).textTheme.bodySmall),
                  IconButton(
                      tooltip: 'Zoom in',
                      onPressed: () => _zoom(1.25),
                      icon: const Icon(Icons.add, size: 18)),
                  IconButton(
                      tooltip: 'Fit image',
                      onPressed: () =>
                          _imageTransform.value = Matrix4.identity(),
                      icon: const Icon(Icons.fit_screen, size: 18)),
                ])),
      ]);
    }
    final canRender = isHtmlPreview(object.key, preview.contentType);
    return HoverCopyRegion(
        label: 'loaded text',
        value: preview.text ?? '',
        controller: widget.controller,
        builder: (context, copyAction) =>
            Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Padding(
                  padding: const EdgeInsets.fromLTRB(10, 5, 8, 5),
                  child: Row(children: [
                    Expanded(
                        child: canRender
                            ? Align(
                                alignment: Alignment.centerLeft,
                                child: TextButton.icon(
                                    key: const ValueKey('html-render-toggle'),
                                    onPressed: () => setState(
                                        () => _renderHtml = !_renderHtml),
                                    icon: Icon(
                                        _renderHtml
                                            ? Icons.code
                                            : Icons.web_asset_outlined,
                                        size: 17),
                                    label: Text(_renderHtml
                                        ? 'View source'
                                        : 'Render page')))
                            : Text(
                                sourcePreviewLanguage(
                                            object.key, preview.contentType)
                                        ?.toUpperCase() ??
                                    'Text',
                                style: Theme.of(context).textTheme.bodySmall)),
                    copyAction,
                  ])),
              const Divider(height: 1),
              Expanded(
                  child: DirectionalSwitcher(
                      position: _renderHtml ? 1 : 0,
                      layoutBuilder: (current, previous) => Stack(
                              fit: StackFit.expand,
                              children: [
                                ...previous,
                                if (current != null) current
                              ]),
                      duration: AppMotion.duration(context,
                          enabled: widget.controller.settings.enableAnimations,
                          milliseconds: 220),
                      child: _renderHtml
                          ? _renderedHtml()
                          : PreviewSourceView(
                              key: const ValueKey('expanded-source-preview'),
                              source: preview.text ?? '',
                              objectKey: object.key,
                              contentType: preview.contentType))),
            ]));
  }

  void _zoom(double factor) {
    final scale =
        (_imageTransform.value.getMaxScaleOnAxis() * factor).clamp(.5, 5.0);
    _imageTransform.value = Matrix4.diagonal3Values(scale, scale, 1);
  }

  Widget _renderedHtml() => ColoredBox(
      key: const ValueKey('expanded-html-preview'),
      color: Colors.white,
      child: Scrollbar(
          child: SingleChildScrollView(
              padding: const EdgeInsets.all(20),
              child: SelectionArea(
                  child: HtmlWidget(preview.text ?? '',
                      key: const ValueKey('rendered-html-page'),
                      textStyle: const TextStyle(color: Colors.black),
                      baseUrl: Uri.tryParse(preview.url ?? '')?.resolve('.'),
                      onTapUrl: (_) async => true)))));

  Widget _limitNotice(BuildContext context) => Container(
      key: const ValueKey('expanded-preview-truncated'),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
      decoration: BoxDecoration(
          border: Border(
              top: BorderSide(
                  color: Theme.of(context).colorScheme.outlineVariant))),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Icon(Icons.info_outline,
            size: 15, color: Theme.of(context).colorScheme.onSurfaceVariant),
        const SizedBox(width: 6),
        Expanded(
            child: Text(
                'Preview is limited to the first ${formatBytes(preview.loadedBytes)} of this object.',
                style: Theme.of(context).textTheme.bodySmall)),
      ]));
}
