import '../models/domain_models.dart';
import '../widgets/transfer_status/transfer_status_spec.dart';

/// Control acknowledgements may omit counters; preserve the transfer snapshot.
TransferJob mergeTransferControl(TransferJob? previous, TransferJob response) {
  if (previous == null) return response;
  return previous.copyWith(
    status: response.status,
    canPause: response.canPause,
    canResume: response.canResume,
    canCancel: response.canCancel,
    outputLines: [...previous.outputLines, ...response.outputLines],
  );
}

/// In-flight progress cannot undo a cancellation acknowledgement.
TransferJob preserveTransferCancellation(
    TransferJob? previous, TransferJob event) {
  if (previous == null) return event;
  if (const ['cancelled', 'canceled'].contains(previous.status)) {
    return previous;
  }
  if (previous.status == 'cancelling' &&
      const ['running', 'queued', 'paused'].contains(event.status)) {
    return event.copyWith(
        status: 'cancelling',
        canCancel: false,
        canPause: false,
        canResume: false);
  }
  return event;
}

/// Banner indicator phase. A running job stays `preparing` until the engine
/// reports bytes or progress, which covers the long source-preparation stage.
TransferStatusPhase transferStatusPhase(
    String status, double progress, int? bytesTransferred) {
  return switch (status.toLowerCase()) {
    'running' ||
    'queued' ||
    'active' =>
      progress <= 0 && (bytesTransferred ?? 0) <= 0
          ? TransferStatusPhase.preparing
          : TransferStatusPhase.transferring,
    'paused' => TransferStatusPhase.paused,
    'cancelling' => TransferStatusPhase.cancelling,
    'completed' => TransferStatusPhase.completed,
    'cancelled' || 'canceled' => TransferStatusPhase.cancelled,
    _ => TransferStatusPhase.failed,
  };
}

/// Banner copy for a transfer. The indicator shows the percent, so the
/// message does not repeat it.
String transferBannerMessage(TransferJob job) {
  final upload = job.direction != 'download';
  final verb = upload ? 'upload' : 'download';
  final title = upload ? 'Upload' : 'Download';
  final count = job.itemCount ?? 1;
  final items = '$count ${upload ? 'files' : 'objects'}';
  return switch (
      transferStatusPhase(job.status, job.progress, job.bytesTransferred)) {
    TransferStatusPhase.preparing =>
      count > 1 ? 'Preparing $verb of $items…' : 'Preparing $verb…',
    TransferStatusPhase.transferring => count > 1
        ? '${upload ? 'Uploading' : 'Downloading'} $items'
        : '$title in progress',
    TransferStatusPhase.paused => '$title paused',
    TransferStatusPhase.cancelling => 'Stopping $verb after in-flight work…',
    TransferStatusPhase.completed =>
      count > 1 ? '$title complete · $items' : '$title complete',
    TransferStatusPhase.failed => '$title failed',
    TransferStatusPhase.cancelled => '$title cancelled',
  };
}
