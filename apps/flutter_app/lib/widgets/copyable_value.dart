import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../controllers/app_controller.dart';
import '../models/domain_models.dart';
import '../services/app_platform.dart';

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
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
                fontWeight: FontWeight.w600)));
    return LayoutBuilder(builder: (context, constraints) {
      final stacked = constraints.maxWidth < 300;
      final value = DefaultTextStyle.merge(
          style: theme.textTheme.bodyMedium, child: child);
      final body = stacked
          ? Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [labelText, const SizedBox(height: 2), value])
          : Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              SizedBox(
                  width: (constraints.maxWidth * .34).clamp(84.0, 140.0),
                  child: labelText),
              const SizedBox(width: 12),
              Expanded(child: value),
            ]);
      return ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 40),
          child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Row(children: [
                Expanded(child: body),
                if (trailing != null) trailing!,
              ])));
    });
  }
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
  Widget build(BuildContext context) => LabeledValue(
      label: label,
      trailing: IconButton(
          tooltip: 'Copy $label',
          constraints: const BoxConstraints.tightFor(width: 32, height: 32),
          padding: EdgeInsets.zero,
          // Desktop rows keep an even rhythm; touch keeps a full-size target.
          style: IconButton.styleFrom(
              tapTargetSize: AppPlatform.isMobile
                  ? MaterialTapTargetSize.padded
                  : MaterialTapTargetSize.shrinkWrap),
          onPressed: () => copyValue(controller, label, value),
          icon: const Icon(Icons.copy_outlined, size: 18)),
      child: Tooltip(
          message: value,
          child: SelectableText(
              shorten && value.length > 24
                  ? '${value.substring(0, 12)}…${value.substring(value.length - 6)}'
                  : value,
              style: monospace
                  ? const TextStyle(fontFamily: 'monospace')
                  : null)));
}
