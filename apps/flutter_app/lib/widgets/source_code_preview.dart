import 'package:flutter/material.dart';
import 'package:highlight/highlight.dart' show Node, highlight;

class SourceCodePreview extends StatelessWidget {
  const SourceCodePreview({
    super.key,
    required this.source,
    required this.language,
    this.textStyle,
  });

  final String source;
  final String language;
  final TextStyle? textStyle;

  @override
  Widget build(BuildContext context) {
    final baseStyle = (textStyle ?? Theme.of(context).textTheme.bodyMedium)
        ?.copyWith(fontFamily: 'monospace');
    final nodes = highlight.parse(source, language: language).nodes ?? const [];
    return SelectableText.rich(
      TextSpan(
        style: baseStyle,
        children: nodes.map((node) => _spanForNode(context, node)).toList(),
      ),
      key: ValueKey('source-code-$language'),
      style: baseStyle,
    );
  }

  TextSpan _spanForNode(BuildContext context, Node node) {
    final style = _styleForClass(Theme.of(context).colorScheme, node.className);
    if (node.value != null) {
      return TextSpan(text: node.value, style: style);
    }
    return TextSpan(
      style: style,
      children: (node.children ?? const [])
          .map((child) => _spanForNode(context, child))
          .toList(),
    );
  }

  TextStyle? _styleForClass(ColorScheme colors, String? className) {
    return switch (className) {
      'comment' || 'quote' => TextStyle(
          color: colors.onSurfaceVariant,
          fontStyle: FontStyle.italic,
        ),
      'keyword' || 'selector-tag' || 'doctag' => TextStyle(
          color: colors.primary,
          fontWeight: FontWeight.w600,
        ),
      'string' ||
      'regexp' ||
      'addition' ||
      'attribute' =>
        TextStyle(color: colors.tertiary),
      'number' ||
      'literal' ||
      'symbol' ||
      'bullet' =>
        TextStyle(color: colors.secondary),
      'title' ||
      'section' ||
      'name' ||
      'selector-id' ||
      'selector-class' =>
        TextStyle(color: colors.primary, fontWeight: FontWeight.w700),
      'type' ||
      'built_in' ||
      'builtin-name' ||
      'class' =>
        TextStyle(color: colors.secondary, fontWeight: FontWeight.w600),
      'attr' ||
      'variable' ||
      'template-variable' ||
      'params' =>
        TextStyle(color: colors.tertiary),
      'meta' || 'meta-keyword' => TextStyle(color: colors.outline),
      'deletion' => TextStyle(color: colors.error),
      _ => null,
    };
  }
}
