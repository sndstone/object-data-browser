import 'package:flutter/widgets.dart';

/// What the status banner is reporting, other than file transfers (those
/// use the transfer status indicators).
enum BannerActivityKind {
  /// Listing objects/buckets/versions, loading a bucket or admin state.
  listing,

  /// Deleting objects, emptying or deleting a bucket.
  deleting,

  /// Benchmark runs and benchmark data tools (put test data, delete all).
  benchmark,

  /// Short mutations: create bucket/folder, versioning, access preset,
  /// presigned URL, profile test, engine or profile switch.
  action,

  /// Writing a file: event log, diagnostics or profile export.
  exporting,

  /// A plain message with no running work behind it.
  message,
}

enum BannerActivityPhase {
  working,
  paused,
  stopping,
  succeeded,
  info,
  warning,
  failed,
  cancelled,
}

/// Everything an activity indicator needs; it never reads the controller.
@immutable
class BannerActivitySpec {
  const BannerActivitySpec({
    required this.kind,
    required this.phase,
    required this.foreground,
    required this.background,
    this.progress,
    this.count,
    this.animate = true,
  });

  final BannerActivityKind kind;
  final BannerActivityPhase phase;

  /// 0..1 when known (benchmarks); null for indeterminate work.
  final double? progress;

  /// Items involved when known: objects loaded so far while listing, or
  /// objects being deleted.
  final int? count;

  /// False when animations are disabled or reduced motion is requested;
  /// indicators then render a static, still-distinct state.
  final bool animate;

  /// Banner text colour and banner fill the indicator is painted on.
  final Color foreground, background;

  bool get isWorking =>
      phase == BannerActivityPhase.working ||
      phase == BannerActivityPhase.stopping;
}
