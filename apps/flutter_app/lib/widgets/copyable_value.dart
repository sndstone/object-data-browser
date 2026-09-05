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
  Widget build(BuildContext context) => Row(children: [
        Expanded(
            child: Tooltip(
                message: value,
                child: SelectableText(
                    '$label: ${shorten && value.length > 24 ? '${value.substring(0, 12)}…${value.substring(value.length - 6)}' : value}',
                    style: monospace
                        ? const TextStyle(fontFamily: 'monospace')
                        : null))),
        IconButton(
            tooltip: 'Copy $label',
            onPressed: () => copyValue(controller, label, value),
            icon: const Icon(Icons.copy_outlined, size: 18)),
      ]);
}
