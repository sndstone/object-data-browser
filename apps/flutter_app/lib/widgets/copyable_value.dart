import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../controllers/app_controller.dart';
import '../models/domain_models.dart';
import '../services/app_platform.dart';
import '../theme/app_motion.dart';

Future<void> copyValue(
    AppController controller, String label, String value) async {
  await Clipboard.setData(ClipboardData(text: value));
  if (AppPlatform.isMobile) await HapticFeedback.selectionClick();
  controller.showBannerMessage('$label copied.',
      severity: BannerSeverity.success);
}

/// A label/value row with a fixed label column so consecutive rows line up
/// like a definition list. Narrow panels stack the label above the value.
class LabeledValue extends StatelessWidget {
  const LabeledValue(
      {super.key, required this.label, required this.child, this.trailing});
  final String label;
  final Widget child;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final labelText = Tooltip(
        message: label,
        child: Text(label,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
                fontWeight: FontWeight.w600)));
    return LayoutBuilder(builder: (context, constraints) {
      final stacked = constraints.maxWidth < 280;
      final value = DefaultTextStyle.merge(
          style: theme.textTheme.bodyMedium, child: child);
      final body = stacked
          ? Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [labelText, const SizedBox(height: 2), value])
          : Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              SizedBox(
                  width: (constraints.maxWidth * .38).clamp(84.0, 148.0),
                  child: labelText),
              const SizedBox(width: 12),
              Expanded(child: value),
            ]);
      return ConstrainedBox(
          constraints:
              BoxConstraints(minHeight: AppPlatform.isMobile ? 44 : 32),
          child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Row(children: [
                Expanded(child: body),
                if (trailing != null) trailing!,
              ])));
    });
  }
}

/// Reveals a copy action over its content, including keyboard focus.
/// The action keeps its space so labels never jump on hover.
class HoverCopyRegion extends StatefulWidget {
  const HoverCopyRegion(
      {super.key,
      required this.label,
      required this.value,
      required this.controller,
      required this.builder});
  final String label, value;
  final AppController controller;
  final Widget Function(BuildContext context, Widget copyAction) builder;
  @override
  State<HoverCopyRegion> createState() => _HoverCopyRegionState();
}

class _HoverCopyRegionState extends State<HoverCopyRegion> {
  bool _hovered = false;
  bool _focused = false;
  @override
  Widget build(BuildContext context) => MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: Focus(
          canRequestFocus: false,
          skipTraversal: true,
          onFocusChange: (value) => setState(() => _focused = value),
          child: widget.builder(
              context,
              AnimatedOpacity(
                  opacity: AppPlatform.isMobile || _hovered || _focused ? 1 : 0,
                  duration: AppMotion.duration(context,
                      enabled: widget.controller.settings.enableAnimations,
                      milliseconds: 120),
                  child: IconButton(
                      tooltip: 'Copy ${widget.label}',
                      constraints: BoxConstraints.tightFor(
                          width: AppPlatform.isMobile ? 44 : 32,
                          height: AppPlatform.isMobile ? 44 : 32),
                      padding: EdgeInsets.zero,
                      style: IconButton.styleFrom(
                          tapTargetSize: AppPlatform.isMobile
                              ? MaterialTapTargetSize.padded
                              : MaterialTapTargetSize.shrinkWrap),
                      onPressed: () => copyValue(
                          widget.controller, widget.label, widget.value),
                      icon: const Icon(Icons.copy_outlined, size: 16))))));
}

class CopyableValue extends StatelessWidget {
  const CopyableValue(
      {super.key,
      required this.label,
      required this.value,
      required this.controller,
      this.monospace = false,
      this.shorten = false});
  final String label, value;
  final AppController controller;
  final bool monospace, shorten;
  @override
  Widget build(BuildContext context) => HoverCopyRegion(
      label: label,
      value: value,
      controller: controller,
      builder: (context, copyAction) => LabeledValue(
          label: label,
          trailing: copyAction,
          child: Tooltip(
              message: value,
              child: SelectableText(
                  monospace &&
                          label.toLowerCase() == 'last-modified' &&
                          value.contains('T')
                      ? value.replaceFirst('T', '\n')
                      : shorten && value.length > 24
                          ? '${value.substring(0, 12)}…${value.substring(value.length - 6)}'
                          : value,
                  style: monospace
                      ? const TextStyle(fontFamily: 'monospace')
                      : null))));
}
