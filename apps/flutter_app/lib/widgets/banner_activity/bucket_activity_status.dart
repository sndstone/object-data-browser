import 'package:flutter/material.dart';

import '../../controllers/app_controller.dart';
import '../../theme/app_motion.dart';
import 'banner_activity_spec.dart';
import 'bucket_activity_indicator.dart';

/// Keeps the running status visible when a dialog covers the main banner.
class BucketActivityStatus extends StatelessWidget {
  const BucketActivityStatus({
    super.key,
    required this.controller,
    required this.animation,
    this.padding = EdgeInsets.zero,
  });

  final AppController controller;
  final BucketActivityAnimation animation;
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: controller,
        builder: (context, _) {
          final activity = controller.bannerActivity;
          final message = controller.bannerMessage;
          if (activity == null ||
              activity.bucketAnimation != animation ||
              message == null ||
              (activity.phase != BannerActivityPhase.working &&
                  activity.phase != BannerActivityPhase.stopping)) {
            return const SizedBox.shrink();
          }
          final theme = Theme.of(context);
          final colors = theme.colorScheme;
          return Padding(
            padding: padding,
            child: Material(
              color: colors.inverseSurface,
              borderRadius: BorderRadius.circular(10),
              child: Padding(
                padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                child: Row(
                  children: [
                    BucketActivityIndicator(
                      animation: animation,
                      spec: BannerActivitySpec(
                        kind: activity.kind,
                        phase: activity.phase,
                        count: activity.count,
                        animate: AppMotion.duration(context,
                                enabled: controller.settings.enableAnimations) >
                            Duration.zero,
                        foreground: colors.onInverseSurface,
                        background: colors.inverseSurface,
                      ),
                    ),
                    const SizedBox(width: 12),
                    Flexible(
                      child: Text(
                        activity.phase == BannerActivityPhase.stopping
                            ? 'Stopping bucket copy…'
                            : controller.visibleTransferText(message),
                        style: theme.textTheme.bodyMedium
                            ?.copyWith(color: colors.onInverseSurface),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          );
        },
      );
}
