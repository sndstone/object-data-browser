import 'package:flutter/material.dart';

import 'transfer_status_spec.dart';

/// Single-file transfers: a reading beam sweeps a folded document while the
/// source is prepared, or a destination materialises for downloads. The beam
/// settles into a directional level gauge when the transfer starts.
class FileScanIndicator extends StatefulWidget {
  const FileScanIndicator({super.key, required this.spec});
  final TransferStatusSpec spec;

  @override
  State<FileScanIndicator> createState() => _FileScanState();
}

class _FileScanState extends State<FileScanIndicator>
    with SingleTickerProviderStateMixin {
  late final AnimationController _scan;
  double _departureScan = .5;

  @override
  void initState() {
    super.initState();
    _scan = AnimationController(vsync: this);
    _configureScan();
  }

  void _configureScan() {
    _scan.stop();
    final phase = widget.spec.phase;
    if (widget.spec.animate &&
        (phase == TransferStatusPhase.preparing ||
            phase == TransferStatusPhase.cancelling)) {
      _scan.duration = Duration(
        milliseconds: phase == TransferStatusPhase.preparing ? 1050 : 1900,
      );
      _scan.repeat(
        reverse: phase != TransferStatusPhase.preparing ||
            widget.spec.direction == TransferStatusDirection.upload,
      );
    } else {
      _scan.value = .5;
    }
  }

  @override
  void didUpdateWidget(covariant FileScanIndicator oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.spec.phase == TransferStatusPhase.preparing &&
        widget.spec.phase != TransferStatusPhase.preparing) {
      _departureScan = _scan.value;
    }
    if (oldWidget.spec.phase != widget.spec.phase ||
        oldWidget.spec.direction != widget.spec.direction ||
        oldWidget.spec.animate != widget.spec.animate) {
      _configureScan();
    }
  }

  @override
  void dispose() {
    _scan.dispose();
    super.dispose();
  }

  String _semantics(TransferStatusSpec spec) {
    final upload = spec.direction == TransferStatusDirection.upload;
    final direction = upload ? 'Upload' : 'Download';
    final amount = spec.percent == null ? '' : ', ${spec.percent} percent';
    return switch (spec.phase) {
      TransferStatusPhase.preparing => upload
          ? 'Preparing upload, scanning file'
          : 'Preparing download, requesting metadata and creating destination file',
      TransferStatusPhase.transferring =>
        '${upload ? 'Uploading' : 'Downloading'}$amount',
      TransferStatusPhase.paused => '$direction paused$amount',
      TransferStatusPhase.cancelling => 'Cancelling $direction',
      TransferStatusPhase.completed => '$direction completed',
      TransferStatusPhase.failed => '$direction failed$amount',
      TransferStatusPhase.cancelled => '$direction cancelled',
    };
  }

  @override
  Widget build(BuildContext context) {
    final spec = widget.spec;
    final duration =
        spec.animate ? const Duration(milliseconds: 320) : Duration.zero;
    return Semantics(
      label: _semantics(spec),
      child: ExcludeSemantics(
        child: SizedBox(
          width: 92,
          height: 32,
          child: TweenAnimationBuilder<double>(
            tween: Tween<double>(end: (spec.progress ?? 0).clamp(0.0, 1.0)),
            duration: duration,
            curve: Curves.easeOutCubic,
            builder: (context, progress, _) {
              final numeric = spec.phase == TransferStatusPhase.transferring ||
                  spec.phase == TransferStatusPhase.paused;
              final caption = switch (spec.phase) {
                TransferStatusPhase.preparing =>
                  spec.direction == TransferStatusDirection.upload
                      ? 'SCAN'
                      : 'PREP',
                TransferStatusPhase.transferring ||
                TransferStatusPhase.paused =>
                  spec.progress == null ? '—' : '${(progress * 100).round()}%',
                TransferStatusPhase.cancelling => 'STOP…',
                TransferStatusPhase.completed => 'DONE',
                TransferStatusPhase.failed => 'ERROR',
                TransferStatusPhase.cancelled => 'STOP',
              };
              return Row(
                children: [
                  RepaintBoundary(
                    child: TweenAnimationBuilder<double>(
                      tween: Tween<double>(
                        end:
                            spec.phase == TransferStatusPhase.preparing ? 0 : 1,
                      ),
                      duration: duration,
                      curve: Curves.easeInOutCubic,
                      builder: (context, handoff, _) => AnimatedSwitcher(
                        duration: duration,
                        child: CustomPaint(
                          // Keep one painted document through the hand-off;
                          // cross-fade only when changing to another phase.
                          key: ValueKey(
                            spec.phase == TransferStatusPhase.preparing ||
                                    spec.phase ==
                                        TransferStatusPhase.transferring
                                ? 'active'
                                : spec.phase.name,
                          ),
                          size: const Size(30, 32),
                          painter: _DocumentPainter(
                            spec: spec,
                            progress: progress,
                            scan: _scan,
                            handoff: handoff,
                            departureScan: _departureScan,
                          ),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: AnimatedSwitcher(
                      duration: duration,
                      // Sequential swap: the old caption is gone before the
                      // new one appears, so "PREP" and "0%" never overlap.
                      switchInCurve:
                          const Interval(.5, 1, curve: Curves.easeOut),
                      switchOutCurve:
                          const Interval(.5, 1, curve: Curves.easeIn),
                      child: Align(
                        key: ValueKey(spec.phase),
                        alignment: Alignment.centerLeft,
                        child: Text(
                          caption,
                          maxLines: 1,
                          textScaler: TextScaler.noScaling,
                          style: DefaultTextStyle.of(context).style.copyWith(
                            color: spec.foreground,
                            fontSize: numeric ? 14 : 10,
                            fontWeight: FontWeight.w600,
                            letterSpacing: numeric ? 0 : .7,
                            fontFeatures: const [FontFeature.tabularFigures()],
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              );
            },
          ),
        ),
      ),
    );
  }
}

class _DocumentPainter extends CustomPainter {
  _DocumentPainter({
    required this.spec,
    required this.progress,
    required this.scan,
    required this.handoff,
    required this.departureScan,
  }) : super(repaint: scan);

  final TransferStatusSpec spec;
  final double progress;
  final Animation<double> scan;
  final double handoff;
  final double departureScan;

  @override
  void paint(Canvas canvas, Size size) {
    final foreground = spec.foreground;
    final pen = Paint()
      ..color = foreground
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    final page = Path()
      ..moveTo(6, 2)
      ..lineTo(18, 2)
      ..lineTo(25, 9)
      ..lineTo(25, 28)
      ..quadraticBezierTo(25, 30, 23, 30)
      ..lineTo(6, 30)
      ..quadraticBezierTo(4, 30, 4, 28)
      ..lineTo(4, 4)
      ..quadraticBezierTo(4, 2, 6, 2)
      ..close();
    final fold = Path()
      ..moveTo(18, 2)
      ..lineTo(18, 9)
      ..lineTo(25, 9);
    final phase = spec.phase;
    final gauge = phase == TransferStatusPhase.transferring ||
        phase == TransferStatusPhase.paused;
    final upload = spec.direction == TransferStatusDirection.upload;
    final fillRect = Rect.fromLTRB(
      4,
      upload ? 30 - 28 * progress : 2,
      25,
      upload ? 30 : 2 + 28 * progress,
    );
    final preparing = phase == TransferStatusPhase.preparing;
    final blending = phase == TransferStatusPhase.transferring && handoff < 1;
    final beamPosition = Curves.easeInOutSine.transform(
      preparing ? scan.value : departureScan,
    );
    final startY = upload ? 10 + 16 * beamPosition : 3 + 26 * beamPosition;
    final levelY = upload ? fillRect.top : fillRect.bottom;
    final beamY = startY + (levelY - startY) * handoff;
    if (gauge) {
      canvas.save();
      canvas.clipPath(page);
      canvas.drawRect(
        fillRect,
        Paint()..color = foreground.withValues(alpha: blending ? handoff : 1),
      );
      canvas.restore();
    }
    if ((preparing || blending) && !upload) {
      // A destination takes shape from the top down. Dotted edges keep the
      // entire page legible at full contrast before the solid edge arrives.
      for (final outline in [page, fold]) {
        for (final metric in outline.computeMetrics()) {
          for (double offset = 0; offset < metric.length; offset += 4) {
            canvas.drawPath(metric.extractPath(offset, offset + 1.5), pen);
          }
        }
      }
      canvas.save();
      final revealedY = preparing ? startY : startY + (30 - startY) * handoff;
      canvas.clipRect(Rect.fromLTRB(0, 0, 30, revealedY));
      canvas.drawPath(page, pen);
      canvas.drawPath(fold, pen);
      canvas.restore();
    } else {
      canvas.drawPath(page, pen);
      canvas.drawPath(fold, pen);
    }
    if (gauge) {
      canvas.save();
      canvas.clipRect(fillRect);
      canvas.drawPath(
        fold,
        pen
          ..color =
              Color.lerp(foreground, spec.background, blending ? handoff : 1)!,
      );
      canvas.restore();
      pen.color = foreground;
    }
    if (preparing || blending || phase == TransferStatusPhase.cancelling) {
      final stopping = phase == TransferStatusPhase.cancelling;
      final opacity = blending ? 1 - handoff : 1.0;
      final beamColor = foreground.withValues(alpha: opacity);
      pen.color = beamColor;
      if (upload || stopping) {
        for (final y in [13.0, 18.0, 23.0]) {
          canvas.drawLine(Offset(9, y), Offset(y == 23 ? 16 : 20, y), pen);
        }
      }
      final t = Curves.easeInOutSine.transform(scan.value);
      final y = stopping ? 20 + 4 * t : (preparing ? startY : beamY);
      final beam = Rect.fromLTWH(2, y - 6, 26, 6);
      canvas.save();
      canvas.clipPath(page);
      canvas.drawRect(
        beam,
        Paint()
          ..shader = LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [
              foreground.withValues(alpha: 0),
              foreground.withValues(alpha: (stopping ? .1 : .3) * opacity),
            ],
          ).createShader(beam),
      );
      canvas.restore();
      final left = stopping ? 7.0 : (upload ? 1.0 : 4.0);
      final right = stopping ? 22.0 : (upload ? 28.0 : 25.0);
      // Contract the upload's scanning beam to the document's fill boundary.
      final inset = blending && upload ? 3 * handoff : 0.0;
      canvas.drawLine(Offset(left + inset, y), Offset(right - inset, y),
          pen..strokeWidth = 2);
      if (stopping) {
        canvas.drawLine(const Offset(10, 14), const Offset(19, 14), pen);
      } else if (upload) {
        canvas.drawCircle(
            Offset(1 + inset, y), 1.6, Paint()..color = beamColor);
        canvas.drawCircle(
            Offset(28 - inset, y), 1.6, Paint()..color = beamColor);
      }
      if (!blending) return;
    }

    void stamp(Color color) {
      pen
        ..color = color.withValues(alpha: blending ? handoff : 1)
        ..strokeWidth = 2;
      switch (phase) {
        case TransferStatusPhase.transferring:
          final tip = upload ? 13.0 : 23.0;
          final tail = upload ? 23.0 : 13.0;
          final shoulder = upload ? 17.0 : 19.0;
          canvas.drawLine(Offset(14.5, tail), Offset(14.5, tip), pen);
          canvas.drawPath(
            Path()
              ..moveTo(10.5, shoulder)
              ..lineTo(14.5, tip)
              ..lineTo(18.5, shoulder),
            pen,
          );
        case TransferStatusPhase.paused:
          canvas.drawLine(const Offset(11.5, 14), const Offset(11.5, 23), pen);
          canvas.drawLine(const Offset(17.5, 14), const Offset(17.5, 23), pen);
        case TransferStatusPhase.completed:
          canvas.drawPath(
            Path()
              ..moveTo(9, 18)
              ..lineTo(13, 22)
              ..lineTo(21, 13),
            pen,
          );
        case TransferStatusPhase.failed:
          canvas.drawLine(const Offset(14.5, 13), const Offset(14.5, 19), pen);
          canvas.drawCircle(
              const Offset(14.5, 23), 1.1, Paint()..color = color);
        case TransferStatusPhase.cancelled:
          canvas.drawLine(const Offset(10, 14), const Offset(19, 23), pen);
          canvas.drawLine(const Offset(19, 14), const Offset(10, 23), pen);
        case TransferStatusPhase.preparing:
        case TransferStatusPhase.cancelling:
          break;
      }
    }

    stamp(foreground);
    if (gauge) {
      canvas.save();
      canvas.clipRect(fillRect);
      stamp(spec.background);
      canvas.restore();
    }
  }

  @override
  bool shouldRepaint(covariant _DocumentPainter oldDelegate) =>
      oldDelegate.spec != spec ||
      oldDelegate.progress != progress ||
      oldDelegate.handoff != handoff ||
      oldDelegate.departureScan != departureScan;
}
