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
  static final Map<(String, String), List<Node>> _tokens = {};
  static final Map<Object, TextSpan> _spans = {};

  @override
  Widget build(BuildContext context) {
    final baseStyle = (textStyle ?? Theme.of(context).textTheme.bodyMedium)
        ?.copyWith(fontFamily: 'monospace');
    return SelectableText.rich(
      highlightedSpan(context),
      key: ValueKey('source-code-$language'),
      style: baseStyle,
    );
  }

  TextSpan highlightedSpan(BuildContext context) {
    final baseStyle = (textStyle ?? Theme.of(context).textTheme.bodyMedium)
        ?.copyWith(fontFamily: 'monospace');
    final key = (source, language);
    var nodes = _tokens[key];
    if (nodes == null) {
      nodes =
          highlight.parse(source, language: language).nodes ?? const <Node>[];
      // A handful of bounded previews, rather than a cache per opened object.
      if (_tokens.length >= 4) _tokens.remove(_tokens.keys.first);
      if (source.length <= 65536) _tokens[key] = nodes;
    }
    final spanKey =
        (source, language, baseStyle, Theme.of(context).colorScheme);
    final cached = _spans[spanKey];
    if (cached != null) return cached;
    final span = TextSpan(
      style: baseStyle,
      children: nodes.map((node) => _spanForNode(context, node)).toList(),
    );
    if (_spans.length >= 4) _spans.remove(_spans.keys.first);
    if (source.length <= 65536) _spans[spanKey] = span;
    return span;
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
