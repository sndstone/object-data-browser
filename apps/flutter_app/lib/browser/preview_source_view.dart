import 'dart:math' as math;
import 'package:flutter/material.dart';
import '../services/source_preview.dart';
import '../widgets/source_code_preview.dart';

/// A bounded, selectable source document with a fixed line-number gutter.
/// Only presentation is changed: no additional bytes are requested.
class PreviewSourceView extends StatefulWidget {
  const PreviewSourceView(
      {super.key,
      required this.source,
      required this.objectKey,
      this.contentType,
      this.compact = false});
  final String source, objectKey;
  final String? contentType;
  final bool compact;
  @override
  State<PreviewSourceView> createState() => _PreviewSourceViewState();
}

class _PreviewSourceViewState extends State<PreviewSourceView> {
  final _vertical = ScrollController();
  final _horizontal = ScrollController();
  @override
  void dispose() {
    _vertical.dispose();
    _horizontal.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final source = widget.source.isEmpty ? '(empty file)' : widget.source;
    final style = (widget.compact
            ? theme.textTheme.bodySmall
            : theme.textTheme.bodyMedium)!
        .copyWith(fontFamily: 'monospace', height: 1.65);
    final language =
        sourcePreviewLanguage(widget.objectKey, widget.contentType);
    if (language == null) {
      return Scrollbar(
          controller: _vertical,
          child: SingleChildScrollView(
              controller: _vertical,
              padding: const EdgeInsets.all(12),
              child: SelectableText(source, style: style)));
    }
    final lines = source.split('\n').length;
    final code =
        SourceCodePreview(source: source, language: language, textStyle: style);
    final painter = TextPainter(
        text: code.highlightedSpan(context),
        textDirection: Directionality.of(context),
        textScaler: MediaQuery.textScalerOf(context))
      ..layout();
    final sourceWidth = painter.width + 24;
    painter.dispose();
    final numberPainter = TextPainter(
        text: TextSpan(text: '8' * lines.toString().length, style: style),
        textDirection: Directionality.of(context),
        textScaler: MediaQuery.textScalerOf(context))
      ..layout();
    final gutter = math.max(28.0, numberPainter.width + 16);
    numberPainter.dispose();
    return LayoutBuilder(
        builder: (context, constraints) => Scrollbar(
              controller: _vertical,
              child: SingleChildScrollView(
                  controller: _vertical,
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        SizedBox(
                            width: gutter,
                            child: ExcludeSemantics(
                                child: Padding(
                                    padding: const EdgeInsets.only(right: 10),
                                    child: Text(
                                        List.generate(lines, (n) => '${n + 1}')
                                            .join('\n'),
                                        textAlign: TextAlign.right,
                                        style: style.copyWith(
                                            color: theme
                                                .colorScheme.onSurfaceVariant
                                                .withValues(alpha: .65)))))),
                        Expanded(
                            child: Scrollbar(
                                controller: _horizontal,
                                notificationPredicate: (notification) =>
                                    notification.metrics.axis ==
                                    Axis.horizontal,
                                child: SingleChildScrollView(
                                    controller: _horizontal,
                                    scrollDirection: Axis.horizontal,
                                    child: SizedBox(
                                        width: math.max(sourceWidth,
                                            constraints.maxWidth - gutter),
                                        child: Padding(
                                            padding: const EdgeInsets.only(
                                                right: 12),
                                            child: code))))),
                      ])),
            ));
  }
}
