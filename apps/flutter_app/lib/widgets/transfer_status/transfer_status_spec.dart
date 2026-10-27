import 'package:flutter/widgets.dart';

/// Lifecycle shown by the transfer status indicator in the status banner.
///
/// `preparing` covers the long pre-transfer stage (sizing, hashing and
/// opening source files) before any bytes have been reported.
enum TransferStatusPhase {
  preparing,
  transferring,
  paused,
  cancelling,
  completed,
  failed,
  cancelled,
}

enum TransferStatusDirection { upload, download }

/// Everything an indicator needs; it never reads the controller directly.
@immutable
class TransferStatusSpec {
  const TransferStatusSpec({
    required this.phase,
    required this.direction,
    required this.foreground,
    required this.background,
    this.progress,
    this.animate = true,
    this.itemCount = 1,
    this.copy = false,
  });

  final TransferStatusPhase phase;
  final TransferStatusDirection direction;

  /// 0..1, or null when the amount of work is not known yet.
  final double? progress;

  /// False when the user disabled animations or the platform requests
  /// reduced motion. Indicators must then render a static, still-distinct
  /// state.
  final bool animate;

  /// Banner text colour and banner fill the indicator is painted on.
  final Color foreground, background;

  /// Files or objects in the transfer; more than one selects the multipart
  /// segments indicator.
  final int itemCount;

  /// A bucket copy: shown with the segments indicator and a copy glyph.
  final bool copy;

  int? get percent =>
      progress == null ? null : (progress!.clamp(0.0, 1.0) * 100).round();

  bool get isWorking =>
      phase == TransferStatusPhase.preparing ||
      phase == TransferStatusPhase.transferring ||
      phase == TransferStatusPhase.cancelling;
}
