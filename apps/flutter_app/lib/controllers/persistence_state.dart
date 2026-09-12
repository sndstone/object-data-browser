/// Durable save state is separate from connection health and session usability.
class PersistenceState {
  final Map<String, bool> _profiles = {};
  String? warning;
  bool? profileSaved(String id) => _profiles[id];
  void recordProfile(String id, bool saved) => _profiles[id] = saved;
  void record(bool saved) {
    warning = saved
        ? null
        : 'Applied for this session; could not save. Retry saving when storage is available.';
  }
}
