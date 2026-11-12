import 'dart:async';

/// Local cancellation, distinct from a provider timeout or engine failure.
class ListingCancelled implements Exception {
  const ListingCancelled();
}

/// Detaches callers from stalled reads and observes late responses/errors.
/// Transport owners must additionally abort the underlying work when possible.
class ListingCancellation {
  final _cancelled = Completer<void>();
  final Set<void Function()> _listeners = {};
  bool get isCancelled => _cancelled.isCompleted;
  Future<void> get whenCancelled => _cancelled.future;
  int get activeListenerCount => _listeners.length;

  /// Returns a release function so completed work retains no transport closure.
  void Function() onCancel(void Function() callback) {
    if (isCancelled) {
      callback();
      return () {};
    }
    _listeners.add(callback);
    return () => _listeners.remove(callback);
  }

  void cancel() {
    if (!isCancelled) {
      _cancelled.complete();
      final listeners = _listeners.toList();
      _listeners.clear();
      for (final listener in listeners) {
        listener();
      }
    }
  }

  Future<T> wait<T>(Future<T> request) async {
    final cancelled = Completer<T>();
    final release =
        onCancel(() => cancelled.completeError(const ListingCancelled()));
    try {
      final result = await Future.any([
        request,
        cancelled.future,
      ]);
      if (isCancelled) throw const ListingCancelled();
      return result;
    } catch (_) {
      // Cancellation can arrive after a response/error is queued but before
      // this continuation runs. It must still win over that stale outcome.
      if (isCancelled) throw const ListingCancelled();
      rethrow;
    } finally {
      release();
    }
  }
}

/// Cancels read-only browser listing requests, never transfer workers.
abstract interface class ListingCancellationRegistrant {
  void cancelListings();
}

/// Read-only requests that can belong to a browser listing and its inspector.
bool isCancellableListingMethod(String method) => const {
      'testProfile',
      'getCapabilities',
      'listBuckets',
      'listObjects',
      'listObjectVersions',
      'getObjectDetails',
      'getBucketAdminState',
    }.contains(method);
