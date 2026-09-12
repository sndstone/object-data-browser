import 'dart:async';
import '../services/listing_cancellation.dart';

/// An action owns its cancellation across nested async requests. Zone values
/// keep simultaneous actions separate without adding mutable global selection.
class ActionScope extends ListingCancellation {
  ActionScope({this.engineId}) {
    final parent = current;
    if (parent != null) {
      parent.whenCancelled.then((_) => cancel());
      if (parent.isCancelled) cancel();
    }
  }
  bool listingCancelled = false;
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
