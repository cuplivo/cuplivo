import 'package:flutter/foundation.dart';

import '../../services/dsh_surface_harvest.dart';

/// One row derived from a harvested official-WebUI surface entry.
///
/// Both R5 and R7 render labels the harvest read from the live DSH UI. The
/// label is the remote's own text and is displayed verbatim; [id] is a stable
/// slug used only for the widget keys (`dsh-sidebar-entry-<id>` /
/// `dsh-rail-entry-<id>`), never for display and never as a landing selector —
/// the landing scripts click the label (and, for rail cards, the language-
/// neutral [kind]), see `DshSurfaceHarvest`.
@immutable
class HarnessSurfaceEntry {
  const HarnessSurfaceEntry({required this.id, required this.label, this.kind});

  final String id;
  final String label;

  /// Right-rail page-type kind (e.g. `bw-diff`); null for sidebar rows.
  final String? kind;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is HarnessSurfaceEntry &&
          other.id == id &&
          other.label == label &&
          other.kind == kind;

  @override
  int get hashCode => Object.hash(id, label, kind);

  @override
  String toString() => kind == null
      ? 'HarnessSurfaceEntry($id)'
      : 'HarnessSurfaceEntry($id, $kind)';
}

/// Stable key suffix for a harvested label.
///
/// The label is remote UI text, so it may be Chinese, English, or a mix; the
/// slug keeps letters/digits of any of those scripts (plus `-`/`_`), turns
/// whitespace and punctuation into `-`, lowercases ASCII, and collapses runs.
/// The result is deterministic for a label and independent of widget order, so
/// an e2e selector stays valid across launches. Labels that slug to nothing
/// (punctuation only) return `'entry'`; callers dedupe collisions.
String dshSurfaceEntryId(String label) {
  final normalized = label.trim().toLowerCase();
  final buffer = StringBuffer();
  var separatorPending = false;
  for (final rune in normalized.runes) {
    if (_isIdRune(rune)) {
      if (separatorPending && buffer.isNotEmpty) buffer.write('-');
      buffer.writeCharCode(rune);
      separatorPending = false;
    } else {
      separatorPending = true;
    }
  }
  return _collapseDashes(buffer.toString());
}

/// Whether one code point belongs in an id: ASCII letters/digits, CJK
/// ideographs, kana, Hangul, and `-`/`_`.
bool _isIdRune(int rune) {
  if (rune >= 0x30 && rune <= 0x39) return true; // 0-9
  if (rune >= 0x61 && rune <= 0x7A) return true; // a-z
  if (rune >= 0x41 && rune <= 0x5A) return true; // A-Z (lowercased by caller)
  if (rune == 0x2D || rune == 0x5F) return true; // - _
  if (rune >= 0x3040 && rune <= 0x30FF) return true; // kana
  if (rune >= 0x3400 && rune <= 0x9FFF) return true; // CJK
  if (rune >= 0xAC00 && rune <= 0xD7AF) return true; // Hangul
  return false;
}

String _collapseDashes(String value) {
  final collapsed = value.replaceAll(RegExp(r'-+'), '-');
  final trimmed = collapsed.replaceAll(RegExp(r'^-+|-+$'), '');
  return trimmed.isEmpty ? 'entry' : trimmed;
}

/// Turns harvested surface entries into surface rows in the official order.
///
/// Keeps the exact label text (the landing scripts and the e2e anchors depend
/// on it) and the rail's [DshSurfaceEntry.kind], drops empty/over-long labels,
/// removes labels repeated in [excludedLabels] and entries whose language-neutral
/// [DshSurfaceEntry.kind] is in [excludedKinds] — the built-in cards Cuplivo
/// renders natively, which the official surface also lists in the same
/// harvested region; the kind exclusion keeps that de-duplication working when
/// the Host renders the same card in another UI language — and dedupes id
/// collisions with a numeric suffix. Order is
/// preserved; nothing is invented and a label Cuplivo does not know still
/// renders generically.
List<HarnessSurfaceEntry> dshHarvestedEntries(
  Iterable<DshSurfaceEntry> entries, {
  Set<String> excludedLabels = const <String>{},
  Set<String> excludedKinds = const <String>{},
}) {
  final excluded = <String>{for (final label in excludedLabels) label.trim()}
    ..remove('');
  final excludedKinds = <String>{for (final kind in excludedKinds) kind.trim()}
    ..remove('');
  final seenLabels = <String>{};
  final seenIds = <String>{};
  final rows = <HarnessSurfaceEntry>[];
  for (final entry in entries) {
    final label = entry.label.trim();
    if (label.isEmpty || label.length > 80) continue;
    if (excluded.contains(label)) continue;
    final kind = entry.kind?.trim();
    if (kind != null && excludedKinds.contains(kind)) continue;
    if (!seenLabels.add(label)) continue;
    final base = dshSurfaceEntryId(label);
    var id = base;
    var suffix = 2;
    while (!seenIds.add(id)) {
      id = '$base-$suffix';
      suffix++;
    }
    rows.add(HarnessSurfaceEntry(id: id, label: label, kind: entry.kind));
  }
  return List<HarnessSurfaceEntry>.unmodifiable(rows);
}
