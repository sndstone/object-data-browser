import 'package:flutter/material.dart';
import '../services/app_platform.dart';
import '../theme/breakpoints.dart';

class EmptyBucketState extends StatelessWidget {
  const EmptyBucketState({
    super.key,
    required this.destination,
    required this.isRoot,
    required this.onUpload,
  });

  final String destination;
  final bool isRoot;
  final VoidCallback? onUpload;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    // The workspace owns desktop drag and drop; phones use the file picker.
    final supportsDrop = !AppPlatform.isMobile &&
        !Breakpoints.isPhone(MediaQuery.sizeOf(context).width);
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.symmetric(vertical: 20, horizontal: 8),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 520),
          child: CustomPaint(
            foregroundPainter: _DashedBorder(theme.colorScheme.outlineVariant),
            child: Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 28),
              decoration: BoxDecoration(
                color: theme.colorScheme.surfaceContainerLow,
                borderRadius: BorderRadius.circular(10),
              ),
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                Container(
                  width: 52,
                  height: 52,
                  decoration: BoxDecoration(
                    color: theme.colorScheme.primaryContainer,
                    borderRadius: BorderRadius.circular(15),
                  ),
                  child: Icon(Icons.upload_file_outlined,
                      size: 26, color: theme.colorScheme.onPrimaryContainer),
                ),
                const SizedBox(height: 16),
                Text(
                    supportsDrop
                        ? 'Drop your files here'
                        : 'Upload your first files',
                    style: theme.textTheme.titleMedium,
                    textAlign: TextAlign.center),
                const SizedBox(height: 8),
                Text('Upload to $destination, or choose files below.',
                    style: theme.textTheme.bodySmall,
                    textAlign: TextAlign.center),
                const SizedBox(height: 18),
                FilledButton.icon(
                    onPressed: onUpload,
                    icon: const Icon(Icons.add),
                    label: const Text('Choose files')),
                const SizedBox(height: 12),
                Text(
                    isRoot
                        ? 'No objects in this bucket yet'
                        : 'No objects in this prefix yet',
                    style: theme.textTheme.bodySmall
                        ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                    textAlign: TextAlign.center),
              ]),
            ),
          ),
        ),
      ),
    );
  }
}

class _DashedBorder extends CustomPainter {
  const _DashedBorder(this.color);
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final outline = Path()
      ..addRRect(RRect.fromRectAndRadius(
          (Offset.zero & size).deflate(0.5), const Radius.circular(10)));
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1;
    for (final metric in outline.computeMetrics()) {
      for (double offset = 0; offset < metric.length; offset += 10) {
        canvas.drawPath(metric.extractPath(offset, offset + 5), paint);
      }
    }
  }

  @override
  bool shouldRepaint(_DashedBorder oldDelegate) => color != oldDelegate.color;
}
