import 'dart:async';
import '../services/listing_cancellation.dart';

/// An action owns its cancellation across nested async requests. Zone values
/// keep simultaneous actions separate without adding mutable global selection.
class ActionScope extends ListingCancellation {
  ActionScope({this.engineId, bool inheritParent = true}) {
    final parent = inheritParent ? current : null;
    if (parent != null) {
      _releaseParent = parent.onCancel(cancel);
      if (parent.isCancelled) cancel();
    }
  }
  bool listingCancelled = false;
  void Function()? _releaseParent;
  final Set<void Function()> _disposers = {};
  bool _disposed = false;
  void Function() onDispose(void Function() callback) {
    if (_disposed) {
      callback();
      return () {};
    }
    _disposers.add(callback);
    return () => _disposers.remove(callback);
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _releaseParent?.call();
    _releaseParent = null;
    final callbacks = _disposers.toList();
    _disposers.clear();
    for (final callback in callbacks) {
      callback();
    }
  }

  final String? engineId;
  static final Object _zoneKey = Object();
  static ActionScope? get current => Zone.current[_zoneKey] as ActionScope?;
  bool outcomeUnknown = false;
  void check() {
    if (isCancelled) throw const ListingCancelled();
  }

  Future<T> run<T>(Future<T> Function() operation) =>
      runZoned(operation, zoneValues: {_zoneKey: this});
}
