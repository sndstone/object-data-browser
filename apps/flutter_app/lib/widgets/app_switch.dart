import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../theme/app_motion.dart';

/// The app's on/off control: a labelled track that reads ON or OFF opposite
/// the thumb, so the state does not depend on colour alone.
class AppSwitch extends StatefulWidget {
  const AppSwitch({
    super.key,
    required this.value,
    required this.onChanged,
    this.focusable = true,
    this.semanticLabel,
  });

  final bool value;

  /// A null callback disables the switch.
  final ValueChanged<bool>? onChanged;

  /// Set to false when an enclosing tile owns focus and semantics.
  final bool focusable;
  final String? semanticLabel;

  static const double width = 50;
  static const double height = 24;
  static const double _thumb = 18;
  static const double _inset = 2;

  @override
  State<AppSwitch> createState() => _AppSwitchState();
}

class _AppSwitchState extends State<AppSwitch> {
  bool _focused = false;

  bool get _enabled => widget.onChanged != null;

  void _toggle() => widget.onChanged?.call(!widget.value);

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final on = widget.value;
    final duration = AppMotion.duration(context, milliseconds: 170);
    const curve = Curves.easeOutCubic;
    const labelStyle = TextStyle(
      fontFamily: 'Inter',
      fontSize: 9.5,
      height: 1,
      fontWeight: FontWeight.w800,
      letterSpacing: 0.6,
    );

    Widget track = AnimatedContainer(
      duration: duration,
      curve: curve,
      width: AppSwitch.width,
      height: AppSwitch.height,
      decoration: BoxDecoration(
        color: on ? scheme.primary : scheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(AppSwitch.height / 2),
        border: Border.all(color: on ? scheme.primary : scheme.outline),
      ),
      child: Stack(
        children: [
          Positioned(
            left: 8,
            top: 0,
            bottom: 0,
            child: AnimatedOpacity(
              duration: duration,
              opacity: on ? 1 : 0,
              child: Center(
                child: Text(
                  'ON',
                  style: labelStyle.copyWith(color: scheme.onPrimary),
                ),
              ),
            ),
          ),
          Positioned(
            right: 6,
            top: 0,
            bottom: 0,
            child: AnimatedOpacity(
              duration: duration,
              opacity: on ? 0 : 1,
              child: Center(
                child: Text(
                  'OFF',
                  style: labelStyle.copyWith(color: scheme.onSurfaceVariant),
                ),
              ),
            ),
          ),
          AnimatedAlign(
            duration: duration,
            curve: curve,
            alignment: on ? Alignment.centerRight : Alignment.centerLeft,
            child: Padding(
              padding: const EdgeInsets.all(AppSwitch._inset - 1),
              child: AnimatedContainer(
                duration: duration,
                curve: curve,
                width: AppSwitch._thumb,
                height: AppSwitch._thumb,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: on ? scheme.onPrimary : scheme.onSurfaceVariant,
                ),
              ),
            ),
          ),
        ],
      ),
    );

    if (_focused) {
      track = DecoratedBox(
        position: DecorationPosition.foreground,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(AppSwitch.height / 2 + 3),
          border: Border.all(
            color: scheme.primary.withValues(alpha: 0.7),
            width: 2,
            strokeAlign: BorderSide.strokeAlignOutside,
          ),
        ),
        child: track,
      );
    }

    Widget result = Opacity(opacity: _enabled ? 1 : 0.42, child: track);
    if (!widget.focusable) {
      return ExcludeSemantics(child: result);
    }
    return Semantics(
      toggled: on,
      enabled: _enabled,
      label: widget.semanticLabel,
      onTap: _enabled ? _toggle : null,
      child: FocusableActionDetector(
        enabled: _enabled,
        mouseCursor: _enabled
            ? SystemMouseCursors.click
            : SystemMouseCursors.basic,
        onShowFocusHighlight: (value) => setState(() => _focused = value),
        shortcuts: const {
          SingleActivator(LogicalKeyboardKey.space): ActivateIntent(),
          SingleActivator(LogicalKeyboardKey.enter): ActivateIntent(),
        },
        actions: {
          ActivateIntent: CallbackAction<ActivateIntent>(
            onInvoke: (_) {
              _toggle();
              return null;
            },
          ),
        },
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: _enabled ? _toggle : null,
          child: ExcludeSemantics(child: result),
        ),
      ),
    );
  }
}

/// Drop-in replacement for [SwitchListTile] that uses [AppSwitch].
///
/// Tiles default to zero horizontal padding so their titles line up with the
/// fields, sliders and helper text around them in settings cards and dialogs.
class AppSwitchTile extends StatelessWidget {
  const AppSwitchTile({
    super.key,
    required this.value,
    required this.onChanged,
    required this.title,
    this.subtitle,
    this.contentPadding = EdgeInsets.zero,
    this.dense,
    this.visualDensity,
  });

  final bool value;
  final ValueChanged<bool>? onChanged;
  final Widget title;
  final Widget? subtitle;
  final EdgeInsetsGeometry? contentPadding;
  final bool? dense;
  final VisualDensity? visualDensity;

  @override
  Widget build(BuildContext context) {
    final enabled = onChanged != null;
    return MergeSemantics(
      child: Semantics(
        toggled: value,
        child: ListTile(
          enabled: enabled,
          contentPadding: contentPadding,
          dense: dense,
          visualDensity: visualDensity,
          title: title,
          subtitle: subtitle,
          trailing: AppSwitch(
            value: value,
            onChanged: onChanged,
            focusable: false,
          ),
          onTap: enabled ? () => onChanged!(!value) : null,
        ),
      ),
    );
  }
}
