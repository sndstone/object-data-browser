import 'package:flutter/widgets.dart';

import 'banner_activity_spec.dart';
import 'bucket_activity_indicator.dart';
import 'living_glyph_indicator.dart';
import 'trace_tile_indicator.dart';

/// Banner status for everything except file transfers: benchmarks and
/// exports use the trace tile, every other situation a living glyph.
class BannerActivityIndicator extends StatelessWidget {
  const BannerActivityIndicator(
      {super.key, required this.spec, this.bucketAnimation});
  final BannerActivitySpec spec;
  final BucketActivityAnimation? bucketAnimation;

  @override
  Widget build(BuildContext context) {
    if (bucketAnimation case final animation?) {
      return BucketActivityIndicator(animation: animation, spec: spec);
    }
    return switch (spec.kind) {
      BannerActivityKind.benchmark ||
      BannerActivityKind.exporting =>
        TraceTileIndicator(
            key: const ValueKey('banner-activity-tile'), spec: spec),
      _ => LivingGlyphIndicator(
          key: const ValueKey('banner-activity-glyph'), spec: spec),
    };
  }
}
