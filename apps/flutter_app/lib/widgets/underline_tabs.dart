import 'package:flutter/material.dart';
import 'edge_fade_scroll.dart';
import 'navigation_item.dart';

class UnderlineTab<T> {
  const UnderlineTab({required this.value, required this.label});
  final T value;
  final String label;
}

/// A single row of text tabs with an underline indicator. Tabs that do not
/// belong in the row are offered through a trailing overflow menu; an active
/// overflow tab is shown in the row so the current view is always visible.
class UnderlineTabs<T> extends StatelessWidget {
  const UnderlineTabs({
    super.key,
    required this.tabs,
    required this.selected,
    required this.onChanged,
    this.overflow = const [],
    this.overflowTooltip = 'More views',
  });

  final List<UnderlineTab<T>> tabs;
  final List<UnderlineTab<T>> overflow;
  final T selected;
  final ValueChanged<T> onChanged;
  final String overflowTooltip;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final visible = [
      ...tabs,
      ...overflow.where((tab) => tab.value == selected),
    ];
    final hidden = overflow.where((tab) => tab.value != selected).toList();
    return DecoratedBox(
      decoration: BoxDecoration(
        border: Border(
          bottom: BorderSide(color: theme.colorScheme.outlineVariant),
        ),
      ),
      child: Row(children: [
        Expanded(
          child: EdgeFadeScroll(
            child: Row(children: [
              for (var i = 0; i < visible.length; i++)
                _tab(context, visible[i], i, visible.length),
            ]),
          ),
        ),
        if (hidden.isNotEmpty)
          PopupMenuButton<T>(
            tooltip: overflowTooltip,
            icon: const Icon(Icons.more_horiz),
            onSelected: onChanged,
            itemBuilder: (_) => [
              for (final tab in hidden)
                PopupMenuItem(value: tab.value, child: Text(tab.label)),
            ],
          ),
      ]),
    );
  }

  Widget _tab(BuildContext context, UnderlineTab<T> tab, int index, int count) {
    final theme = Theme.of(context);
    final active = tab.value == selected;
    final color =
        active ? theme.colorScheme.primary : theme.colorScheme.onSurfaceVariant;
    return NavigationItem(
      label: '${tab.label}, tab ${index + 1} of $count',
      selected: active,
      onActivate: () => onChanged(tab.value),
      child: InkWell(
        onTap: () => onChanged(tab.value),
        child: Container(
          constraints: const BoxConstraints(minHeight: 40),
          padding: const EdgeInsets.symmetric(horizontal: 10),
          alignment: Alignment.center,
          decoration: BoxDecoration(
            border: Border(
              bottom: BorderSide(
                color: active ? theme.colorScheme.primary : Colors.transparent,
                width: 2,
              ),
            ),
          ),
          child: Text(
            tab.label,
            maxLines: 1,
            style: theme.textTheme.labelLarge?.copyWith(
              color: color,
              fontWeight: active ? FontWeight.w800 : FontWeight.w600,
            ),
          ),
        ),
      ),
    );
  }
}
