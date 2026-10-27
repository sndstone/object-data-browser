import 'package:flutter/widgets.dart';

import 'file_scan_indicator.dart';
import 'segments_indicator.dart';
import 'transfer_status_spec.dart';

/// Banner status for a transfer: a single file (multipart or not) uses the
/// file-scan document; several files or objects use multipart segments.
class TransferStatusIndicator extends StatelessWidget {
  const TransferStatusIndicator({super.key, required this.spec});
  final TransferStatusSpec spec;

  @override
  Widget build(BuildContext context) => spec.itemCount > 1
      ? SegmentsIndicator(
          key: const ValueKey('transfer-status-segments'), spec: spec)
      : FileScanIndicator(
          key: const ValueKey('transfer-status-file'), spec: spec);
}
