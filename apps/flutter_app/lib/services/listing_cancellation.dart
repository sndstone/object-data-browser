import 'dart:async';

/// Local cancellation, distinct from a provider timeout or engine failure.
class ListingCancelled implements Exception {
  const ListingCancelled();
}

/// Detaches callers from stalled reads and observes late responses/errors.
/// Transport owners must additionally abort the underlying work when possible.
class ListingCancellation {
  final _cancelled = Completer<void>();
  bool get isCancelled => _cancelled.isCompleted;

  void cancel() {
    if (!isCancelled) _cancelled.complete();
  }

  Future<T> wait<T>(Future<T> request) async {
    try {
      final result = await Future.any([
        request,
        _cancelled.future.then<T>((_) => throw const ListingCancelled()),
      ]);
      if (isCancelled) throw const ListingCancelled();
      return result;
    } catch (_) {
      // Cancellation can arrive after a response/error is queued but before
      // this continuation runs. It must still win over that stale outcome.
      if (isCancelled) throw const ListingCancelled();
      rethrow;
    }
  }
}

/// Cancels read-only browser listing requests, never transfer workers.
abstract interface class ListingCancellationRegistrant {
  void cancelListings();
}

/// Read-only requests that can belong to a browser listing and its inspector.
bool isCancellableListingMethod(String method) => const {
      'listBuckets',
      'listObjects',
      'listObjectVersions',
      'getObjectDetails',
      'getBucketAdminState',
    }.contains(method);
