import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// A single option shown by [AppSelectField].
class AppSelectItem<T> {
  const AppSelectItem({
    required this.value,
    required this.label,
    this.icon,
    this.enabled = true,
  });

  final T value;
  final String label;
  final IconData? icon;
  final bool enabled;
}

/// Drop-in replacement for [DropdownButtonFormField] whose menu visibly
/// spawns from the field it belongs to.
///
/// The menu panel is anchored directly below the field (same width) and
/// grows downward with a fade + vertical expansion. When there is not
/// enough room below the field, it anchors above the field and grows
/// upward instead. Tapping outside or pressing Escape closes the menu.
class AppSelectField<T> extends StatefulWidget {
  const AppSelectField({
    super.key,
    required this.items,
    required this.onChanged,
    this.value,
    this.decoration,
    this.style,
    this.isExpanded = true,
    this.menuMaxHeight = 320,
  });

  final List<AppSelectItem<T>> items;

  /// Called with the tapped value. A null callback disables the field,
  /// mirroring [DropdownButtonFormField.onChanged] semantics.
  final ValueChanged<T?>? onChanged;
  final T? value;
  final InputDecoration? decoration;
  final TextStyle? style;
  final bool isExpanded;
  final double menuMaxHeight;

  @override
  State<AppSelectField<T>> createState() => _AppSelectFieldState<T>();
}

class _AppSelectFieldState<T> extends State<AppSelectField<T>>
    with SingleTickerProviderStateMixin, WidgetsBindingObserver {
  static const double _itemHeight = 40;
  static const double _menuVerticalPadding = 6;
  static const double _anchorGap = 4;

  final OverlayPortalController _overlayController = OverlayPortalController();
  final LayerLink _layerLink = LayerLink();
  final FocusNode _focusNode = FocusNode(debugLabel: 'AppSelectField');
  final FocusNode _menuFocusNode = FocusNode(debugLabel: 'AppSelectFieldMenu');
  ScrollController? _menuScrollController;

  late final AnimationController _animationController;
  late final CurvedAnimation _expandAnimation;

  bool _openUpward = false;
  double _menuWidth = 0;
  double _menuHeight = 0;
  int _highlightedIndex = -1;

  bool get _enabled => widget.onChanged != null && widget.items.isNotEmpty;
  bool get _isOpen => _overlayController.isShowing;

  /// True while the close animation is running; the overlay is still showing
  /// but the menu is logically closed.
  bool get _isClosing =>
      _isOpen && _animationController.status == AnimationStatus.reverse;

  /// Whether the menu should be presented as open (drives the suffix arrow
  /// and the focused decoration state).
  bool get _showsOpen => _isOpen && !_isClosing;

  @override
  void initState() {
    super.initState();
    _animationController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 180),
      reverseDuration: const Duration(milliseconds: 120),
    );
    _expandAnimation = CurvedAnimation(
      parent: _animationController,
      curve: Curves.easeOutCubic,
      reverseCurve: Curves.easeInCubic,
    );
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didChangeMetrics() {
    // Menu geometry (width, height, flip direction) is computed at open time
    // and would go stale on window resize; closing is the simplest correct
    // behavior.
    if (_isOpen) {
      _closeMenu(immediately: true);
    }
  }

  @override
  void didUpdateWidget(covariant AppSelectField<T> oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!_enabled && _isOpen) {
      _closeMenu(immediately: true);
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _expandAnimation.dispose();
    _animationController.dispose();
    _focusNode.dispose();
    _menuFocusNode.dispose();
    _menuScrollController?.dispose();
    super.dispose();
  }

  double get _estimatedMenuHeight {
    final contentHeight =
        widget.items.length * _itemHeight + _menuVerticalPadding * 2;
    return contentHeight.clamp(_itemHeight, widget.menuMaxHeight).toDouble();
  }

  void _toggleMenu() {
    // A tap during the close animation counts as a reopen: _isOpen stays true
    // until hide() completes, so only treat the menu as open when it is not
    // already closing.
    if (_showsOpen) {
      _closeMenu();
    } else {
      _openMenu();
    }
  }

  void _openMenu() {
    if (!_enabled || _showsOpen) {
      return;
    }
    final renderBox = context.findRenderObject() as RenderBox?;
    if (renderBox == null || !renderBox.hasSize) {
      return;
    }
    final overlayBox = Overlay.of(context, rootOverlay: true)
        .context
        .findRenderObject() as RenderBox?;
    // Work in the overlay's coordinate space so the flip math stays correct
    // when the overlay does not start at the global origin.
    final overlayHeight =
        overlayBox?.size.height ?? MediaQuery.sizeOf(context).height;
    final fieldGlobalTopLeft = renderBox.localToGlobal(Offset.zero);
    final fieldTopLeft = overlayBox == null
        ? fieldGlobalTopLeft
        : overlayBox.globalToLocal(fieldGlobalTopLeft);
    final fieldBottom = fieldTopLeft.dy + renderBox.size.height;

    _menuWidth = renderBox.size.width;
    _menuHeight = _estimatedMenuHeight;

    final spaceBelow = overlayHeight - fieldBottom - _anchorGap - 8;
    final spaceAbove = fieldTopLeft.dy - _anchorGap - 8;
    // Context-aware direction: prefer opening downward from the field; only
    // flip upward when the menu does not fit below but fits better above.
    _openUpward = spaceBelow < _menuHeight && spaceAbove > spaceBelow;
    final availableSpace = (_openUpward ? spaceAbove : spaceBelow)
        .clamp(_itemHeight, widget.menuMaxHeight)
        .toDouble();
    _menuHeight = _menuHeight.clamp(_itemHeight, availableSpace).toDouble();

    final reopening = _isOpen;
    if (!reopening) {
      _menuScrollController?.dispose();
      _menuScrollController = ScrollController(
        initialScrollOffset: _initialScrollOffset(),
      );
    }

    setState(() {
      _highlightedIndex = widget.items.indexWhere(
        (item) => item.enabled && item.value == widget.value,
      );
    });
    _focusNode.requestFocus();
    if (!reopening) {
      _overlayController.show();
      _animationController.forward(from: 0);
    } else {
      // Cancel the in-flight close animation and expand again.
      _animationController.forward();
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _isOpen) {
        _menuFocusNode.requestFocus();
      }
    });
  }

  double _initialScrollOffset() {
    final selectedIndex =
        widget.items.indexWhere((item) => item.value == widget.value);
    if (selectedIndex < 0) {
      return 0;
    }
    final contentHeight =
        widget.items.length * _itemHeight + _menuVerticalPadding * 2;
    if (contentHeight <= _menuHeight) {
      return 0;
    }
    // Center the selected item in the visible menu when possible.
    final target = selectedIndex * _itemHeight -
        (_menuHeight - _itemHeight) / 2 +
        _menuVerticalPadding;
    return target.clamp(0.0, contentHeight - _menuHeight);
  }

  void _closeMenu({bool immediately = false}) {
    if (!_isOpen) {
      return;
    }
    if (immediately || !mounted) {
      _animationController.value = 0;
      _overlayController.hide();
      if (mounted) {
        setState(() {});
      }
      return;
    }
    if (_isClosing) {
      return;
    }
    // Rebuild so the suffix arrow and focused state reflect the closed menu
    // as soon as the close animation starts.
    setState(() {});
    _animationController.reverse().whenComplete(() {
      // Skipped when a reopen interrupted the reverse animation
      // (isDismissed is false in that case).
      if (mounted && _isOpen && _animationController.isDismissed) {
        setState(() {
          _overlayController.hide();
        });
      }
    });
  }

  void _selectItem(AppSelectItem<T> item) {
    _closeMenu();
    widget.onChanged?.call(item.value);
  }

  KeyEventResult _handleKeyEvent(KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    final key = event.logicalKey;
    if (!_showsOpen) {
      if (event is KeyDownEvent &&
          (key == LogicalKeyboardKey.enter ||
              key == LogicalKeyboardKey.space ||
              key == LogicalKeyboardKey.arrowDown ||
              key == LogicalKeyboardKey.arrowUp)) {
        _openMenu();
        return KeyEventResult.handled;
      }
      return KeyEventResult.ignored;
    }
    if (key == LogicalKeyboardKey.escape) {
      _closeMenu();
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowDown) {
      _moveHighlight(1);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowUp) {
      _moveHighlight(-1);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.enter || key == LogicalKeyboardKey.space) {
      if (_highlightedIndex >= 0 && _highlightedIndex < widget.items.length) {
        final item = widget.items[_highlightedIndex];
        if (item.enabled) {
          _selectItem(item);
        }
      }
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  void _moveHighlight(int delta) {
    if (widget.items.isEmpty) {
      return;
    }
    var index = _highlightedIndex;
    for (var i = 0; i < widget.items.length; i++) {
      index = (index + delta) % widget.items.length;
      if (widget.items[index].enabled) {
        break;
      }
    }
    if (index == _highlightedIndex || !widget.items[index].enabled) {
      return;
    }
    setState(() {
      _highlightedIndex = index;
    });
    _revealIndex(index);
  }

  void _revealIndex(int index) {
    final controller = _menuScrollController;
    if (controller == null || !controller.hasClients) {
      return;
    }
    final itemTop = _menuVerticalPadding + index * _itemHeight;
    final itemBottom = itemTop + _itemHeight;
    final viewTop = controller.offset;
    final viewBottom = viewTop + _menuHeight;
    double? target;
    if (itemTop < viewTop) {
      target = itemTop - _menuVerticalPadding;
    } else if (itemBottom > viewBottom) {
      target = itemBottom + _menuVerticalPadding - _menuHeight;
    }
    if (target != null) {
      controller.jumpTo(
        target.clamp(0.0, controller.position.maxScrollExtent),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final selected = widget.items.cast<AppSelectItem<T>?>().firstWhere(
          (item) => item!.value == widget.value,
          orElse: () => null,
        );
    final baseDecoration = widget.decoration ?? const InputDecoration();
    final decoration =
        baseDecoration.applyDefaults(theme.inputDecorationTheme).copyWith(
              enabled: _enabled,
              suffixIcon: baseDecoration.suffixIcon ??
                  Icon(
                    _showsOpen && !_openUpward
                        ? Icons.arrow_drop_up
                        : Icons.arrow_drop_down,
                    color: _enabled
                        ? theme.colorScheme.onSurfaceVariant
                        : theme.colorScheme.onSurfaceVariant
                            .withValues(alpha: 0.45),
                  ),
            );
    final textStyle = widget.style ??
        theme.textTheme.bodyMedium
            ?.copyWith(color: theme.colorScheme.onSurface);
    final valueText = selected == null
        ? const SizedBox.shrink()
        : Text(
            selected.label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: _enabled
                ? textStyle
                : textStyle?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant
                        .withValues(alpha: 0.6),
                  ),
          );

    return OverlayPortal(
      controller: _overlayController,
      overlayChildBuilder: _buildMenuOverlay,
      overlayLocation: OverlayChildLocation.rootOverlay,
      child: CompositedTransformTarget(
        link: _layerLink,
        child: Focus(
          focusNode: _focusNode,
          canRequestFocus: _enabled,
          onKeyEvent: (node, event) => _handleKeyEvent(event),
          child: MouseRegion(
            cursor:
                _enabled ? SystemMouseCursors.click : SystemMouseCursors.basic,
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: _enabled ? _toggleMenu : null,
              child: InputDecorator(
                decoration: decoration,
                isEmpty: selected == null,
                isFocused: _showsOpen || _focusNode.hasFocus,
                child: widget.isExpanded
                    ? Align(
                        alignment: AlignmentDirectional.centerStart,
                        child: valueText,
                      )
                    : valueText,
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildMenuOverlay(BuildContext overlayContext) {
    final theme = Theme.of(context);
    return Stack(
      children: [
        // Tap-outside barrier.
        Positioned.fill(
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: _closeMenu,
          ),
        ),
        CompositedTransformFollower(
          link: _layerLink,
          showWhenUnlinked: false,
          targetAnchor: _openUpward ? Alignment.topLeft : Alignment.bottomLeft,
          followerAnchor:
              _openUpward ? Alignment.bottomLeft : Alignment.topLeft,
          offset: Offset(0, _openUpward ? -_anchorGap : _anchorGap),
          child: Align(
            alignment: _openUpward ? Alignment.bottomLeft : Alignment.topLeft,
            child: SizedBox(
              width: _menuWidth,
              child: AnimatedBuilder(
                animation: _expandAnimation,
                builder: (context, child) {
                  return FadeTransition(
                    opacity: _expandAnimation,
                    child: ClipRect(
                      child: Align(
                        // Grow downward from the field (or upward when the
                        // menu is anchored above it).
                        alignment: _openUpward
                            ? Alignment.bottomCenter
                            : Alignment.topCenter,
                        heightFactor: _expandAnimation.value,
                        child: child,
                      ),
                    ),
                  );
                },
                child: _buildMenuPanel(theme),
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildMenuPanel(ThemeData theme) {
    return Focus(
      focusNode: _menuFocusNode,
      onKeyEvent: (node, event) => _handleKeyEvent(event),
      child: Material(
        color: theme.colorScheme.surface,
        elevation: 6,
        shadowColor: theme.colorScheme.shadow,
        borderRadius: BorderRadius.circular(10),
        clipBehavior: Clip.antiAlias,
        child: DecoratedBox(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(10),
            border: Border.all(
              color: theme.colorScheme.outlineVariant.withValues(alpha: 0.9),
            ),
          ),
          child: ConstrainedBox(
            constraints: BoxConstraints(maxHeight: _menuHeight),
            child: ListView.builder(
              controller: _menuScrollController,
              padding:
                  const EdgeInsets.symmetric(vertical: _menuVerticalPadding),
              shrinkWrap: true,
              itemExtent: _itemHeight,
              itemCount: widget.items.length,
              itemBuilder: (context, index) {
                return _menuItem(theme, widget.items[index], index);
              },
            ),
          ),
        ),
      ),
    );
  }

  Widget _menuItem(ThemeData theme, AppSelectItem<T> item, int index) {
    final isSelected = item.value == widget.value;
    final isHighlighted = index == _highlightedIndex;
    final foreground = !item.enabled
        ? theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.5)
        : isSelected
            ? theme.colorScheme.onPrimaryContainer
            : theme.colorScheme.onSurface;
    return Material(
      color: isSelected
          ? theme.colorScheme.primaryContainer.withValues(alpha: 0.55)
          : isHighlighted
              ? theme.colorScheme.onSurface.withValues(alpha: 0.08)
              : Colors.transparent,
      child: InkWell(
        onTap: item.enabled ? () => _selectItem(item) : null,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: Row(
            children: [
              if (item.icon != null) ...[
                Icon(item.icon, size: 16, color: foreground),
                const SizedBox(width: 8),
              ],
              Expanded(
                child: Text(
                  item.label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: foreground,
                    fontWeight: isSelected ? FontWeight.w700 : FontWeight.w500,
                  ),
                ),
              ),
              if (isSelected) ...[
                const SizedBox(width: 8),
                Icon(
                  Icons.check_rounded,
                  size: 16,
                  color: theme.colorScheme.primary,
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
