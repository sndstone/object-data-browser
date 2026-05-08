import 'package:flutter/material.dart';

class CompactSelectorOption<T> {
  const CompactSelectorOption({
    required this.value,
    required this.label,
    this.icon,
  });

  final T value;
  final String label;
  final IconData? icon;
}

class CompactSelector<T> extends StatelessWidget {
  const CompactSelector({
    super.key,
    required this.options,
    required this.selected,
    required this.onChanged,
    this.wrap = false,
    this.expand = false,
    this.dense = false,
  });

  final List<CompactSelectorOption<T>> options;
  final T selected;
  final ValueChanged<T> onChanged;
  final bool wrap;
  final bool expand;
  final bool dense;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final radius = BorderRadius.circular(8);
    final children = options
        .map(
          (option) => expand
              ? Expanded(child: _item(context, option))
              : _item(context, option),
        )
        .toList();

    final content = wrap
        ? Wrap(
            spacing: 6,
            runSpacing: 6,
            children: children,
          )
        : Row(
            mainAxisSize: expand ? MainAxisSize.max : MainAxisSize.min,
            children: children);

    return DecoratedBox(
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        borderRadius: radius,
        border: Border.all(
          color: theme.colorScheme.outlineVariant,
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.all(3),
        child: wrap || expand
            ? content
            : SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: content,
              ),
      ),
    );
  }

  Widget _item(BuildContext context, CompactSelectorOption<T> option) {
    final theme = Theme.of(context);
    final isSelected = option.value == selected;
    final foreground = isSelected
        ? theme.colorScheme.onPrimaryContainer
        : theme.colorScheme.onSurfaceVariant;
    final background = isSelected
        ? theme.colorScheme.primaryContainer.withValues(alpha: 0.95)
        : Colors.transparent;
    final padding = dense
        ? const EdgeInsets.symmetric(horizontal: 9, vertical: 6)
        : const EdgeInsets.symmetric(horizontal: 12, vertical: 7);

    return Tooltip(
      message: option.label,
      waitDuration: const Duration(milliseconds: 550),
      child: Material(
        color: background,
        borderRadius: BorderRadius.circular(6),
        child: InkWell(
          borderRadius: BorderRadius.circular(6),
          onTap: () => onChanged(option.value),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 160),
            curve: Curves.easeOutCubic,
            constraints: BoxConstraints(minHeight: dense ? 30 : 34),
            padding: padding,
            child: Row(
              mainAxisSize: expand ? MainAxisSize.max : MainAxisSize.min,
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                if (option.icon != null) ...[
                  Icon(option.icon, size: dense ? 10 : 11, color: foreground),
                  SizedBox(width: dense ? 4 : 5),
                ],
                Flexible(
                  child: Text(
                    option.label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    textAlign: TextAlign.center,
                    style: theme.textTheme.labelLarge?.copyWith(
                      color: foreground,
                      fontWeight:
                          isSelected ? FontWeight.w800 : FontWeight.w700,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
