import 'dart:convert';

/// Canonical JSON is used only in memory. Never log its result: documents
/// contain key material. Map order is ignored; list order remains significant.
String canonicalKeyFileJson(Object? value) {
  Object? sorted(Object? item) {
    if (item is Map) {
      final names = item.keys.cast<String>().toList()..sort();
      return {for (final name in names) name: sorted(item[name])};
    }
    if (item is List) return item.map(sorted).toList();
    return item;
  }

  return jsonEncode(sorted(value));
}

int keyFileRevision(Map<String, Object?> entry) => entry['rev'] as int? ?? 0;

/// State-based join of validated key documents. Entries form a total order:
/// revision, device, live-before-deleted, then ascending canonical JSON.
/// Unknown top-level fields that differ are chosen by canonical JSON order,
/// so the whole join is commutative, associative and idempotent.
Map<String, Object?> mergeKeyFileDocuments(
  Map<String, Object?> local,
  Map<String, Object?> remote,
) {
  final winners = <String, ({Map<String, Object?> raw, bool removed})>{};
  var clock = 0;
  void add(Map<String, Object?> document) {
    final documentClock = document['clock'] as int? ?? 0;
    if (documentClock > clock) clock = documentClock;
    for (final removed in [false, true]) {
      for (final value
          in document[removed ? 'removed' : 'keys'] as List? ?? []) {
        final raw = Map<String, Object?>.from(value as Map);
        final id = raw['id'] as String;
        final rev = keyFileRevision(raw);
        if (rev > clock) clock = rev;
        final old = winners[id];
        var take = old == null;
        if (old != null) {
          var order = rev.compareTo(keyFileRevision(old.raw));
          if (order == 0) {
            order = (raw['by'] as String? ?? '')
                .compareTo(old.raw['by'] as String? ?? '');
          }
          if (order == 0 && removed != old.removed) {
            order = removed ? -1 : 1;
          }
          if (order == 0) {
            order = -canonicalKeyFileJson(raw)
                .compareTo(canonicalKeyFileJson(old.raw));
          }
          take = order > 0;
        }
        if (take) winners[id] = (raw: raw, removed: removed);
      }
    }
  }

  add(local);
  add(remote);
  final ids = winners.keys.toList()..sort();
  // Fields this build does not know may differ between the two documents.
  // Pick by canonical JSON rather than by side, so both devices agree.
  final top = <String, Object?>{...remote};
  for (final entry in local.entries) {
    if (!top.containsKey(entry.key) ||
        canonicalKeyFileJson(entry.value)
                .compareTo(canonicalKeyFileJson(top[entry.key])) >
            0) {
      top[entry.key] = entry.value;
    }
  }
  return {
    ...top,
    'clock': clock,
    'keys': [
      for (final id in ids)
        if (!winners[id]!.removed) winners[id]!.raw
    ],
    'removed': [
      for (final id in ids)
        if (winners[id]!.removed) winners[id]!.raw
    ],
  };
}

/// Canonicalizes entry order and supplies legacy defaults without changing
/// revision stamps. Used when comparing semantic documents before a write.
String normalizedKeyFileJson(Map<String, Object?> document) =>
    canonicalKeyFileJson(mergeKeyFileDocuments(document, document));
