import 'package:flutter/material.dart';

/// Shared geometry and motion for every menu in the app, matching the
/// [AppSelectField] panel used by the engine and profile selectors.
class AppMenuStyle {
  static const double itemHeight = 40;
  static const double verticalPadding = 6;
  static const double radius = 10;
  static const double anchorGap = 4;
  static const EdgeInsets itemPadding = EdgeInsets.symmetric(horizontal: 12);
  static const AnimationStyle animation = AnimationStyle(
    duration: Duration(milliseconds: 180),
    reverseDuration: Duration(milliseconds: 120),
    curve: Curves.easeOutCubic,
    reverseCurve: Curves.easeInCubic,
  );

  static Color selectedBackground(ThemeData theme) =>
      theme.colorScheme.primaryContainer.withValues(alpha: 0.55);
  /// Soft drop shadow for anchored panels drawn outside a [Material]. Popup
  /// menus get the equivalent from elevation 6 in the theme.
  static List<BoxShadow> shadows(ThemeData theme) {
    final dark = theme.brightness == Brightness.dark;
    return [
      BoxShadow(
        color: Colors.black.withValues(alpha: dark ? 0.45 : 0.12),
        blurRadius: 18,
        offset: const Offset(0, 6),
      ),
      BoxShadow(
        color: Colors.black.withValues(alpha: dark ? 0.35 : 0.08),
        blurRadius: 4,
        offset: const Offset(0, 1),
      ),
    ];
  }

  static Color highlightBackground(ThemeData theme) =>
      theme.colorScheme.onSurface.withValues(alpha: 0.08);
}

/// One menu row: optional 16 px icon, label, and a check when selected.
/// Every row in a menu shares the same label inset whether or not it has an
/// icon, so callers pass icons for all rows of a menu or for none.
class AppMenuRow extends StatelessWidget {
  const AppMenuRow({
    super.key,
    required this.label,
    this.icon,
    this.selected = false,
    this.destructive = false,
    this.enabled = true,
  });

  final String label;
  final IconData? icon;
  final bool selected;
  final bool destructive;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final foreground = !enabled
        ? scheme.onSurfaceVariant.withValues(alpha: 0.5)
        : destructive
        ? scheme.error
        : selected
        ? scheme.onPrimaryContainer
        : scheme.onSurface;
    return Row(
      children: [
        if (icon != null) ...[
          Icon(icon, size: 16, color: foreground),
          const SizedBox(width: 8),
        ],
        Expanded(
          child: Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: foreground,
              fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
            ),
          ),
        ),
        if (selected) ...[
          const SizedBox(width: 8),
          Icon(Icons.check_rounded, size: 16, color: scheme.primary),
        ],
      ],
    );
  }
}

/// A 40 px [PopupMenuItem] rendered with [AppMenuRow].
PopupMenuItem<T> appMenuItem<T>({
  Key? key,
  required T value,
  required String label,
  IconData? icon,
  bool selected = false,
  bool destructive = false,
  bool enabled = true,
}) {
  return PopupMenuItem<T>(
    key: key,
    value: value,
    enabled: enabled,
    height: AppMenuStyle.itemHeight,
    padding: EdgeInsets.zero,
    child: Builder(
      builder: (context) => Container(
        height: AppMenuStyle.itemHeight,
        padding: AppMenuStyle.itemPadding,
        color: selected
            ? AppMenuStyle.selectedBackground(Theme.of(context))
            : null,
        child: AppMenuRow(
          label: label,
          icon: icon,
          selected: selected,
          destructive: destructive,
          enabled: enabled,
        ),
      ),
    ),
  );
}

PopupMenuDivider appMenuDivider() =>
    const PopupMenuDivider(height: AppMenuStyle.verticalPadding * 2 + 1);

/// Opens a menu with the shared style.
///
/// [anchor] is a global rectangle. Pass the trigger button's bounds to open
/// the menu just below it, aligned to the button's leading or trailing edge,
/// or a zero-size rectangle at the pointer for right-click menus.
Future<T?> showAppMenu<T>({
  required BuildContext context,
  required Rect anchor,
  required List<PopupMenuEntry<T>> items,
}) {
  final overlay =
      Overlay.of(context, rootOverlay: true).context.findRenderObject()
          as RenderBox;
  final topLeft = overlay.globalToLocal(anchor.topLeft);
  final bottomRight = overlay.globalToLocal(anchor.bottomRight);
  final gap = anchor.isEmpty ? 0.0 : AppMenuStyle.anchorGap;
  final target = Rect.fromLTRB(
    topLeft.dx,
    bottomRight.dy + gap,
    bottomRight.dx,
    bottomRight.dy + gap,
  );
  return showMenu<T>(
    context: context,
    position: RelativeRect.fromRect(target, Offset.zero & overlay.size),
    items: items,
    popUpAnimationStyle: AppMenuStyle.animation,
  );
}

/// Global bounds of the widget that owns [context], for [showAppMenu].
Rect globalRectOf(BuildContext context) {
  final box = context.findRenderObject() as RenderBox;
  return box.localToGlobal(Offset.zero) & box.size;
}
