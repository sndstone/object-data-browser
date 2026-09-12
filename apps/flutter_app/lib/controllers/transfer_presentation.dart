import '../models/domain_models.dart';

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
