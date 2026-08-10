import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:flutter/foundation.dart';

import '../database/app_database.dart';

/// Entity type constants for [DeletedRecordRows] and [DeletionMarkerRows].
class DeletionEntityType {
  const DeletionEntityType._();
  static const conversation = 'conversation';
  static const message = 'message';
  static const assistant = 'assistant';
  static const worldBook = 'worldBook';
  static const quickPhrase = 'quickPhrase';
  static const mcpServer = 'mcpServer';
  static const memory = 'memory';
  static const groupChat = 'groupChat';
  static const workspaceFile = 'workspaceFile';

  static const all = [
    conversation,
    message,
    assistant,
    worldBook,
    quickPhrase,
    mcpServer,
    memory,
    groupChat,
    workspaceFile,
  ];
}

/// Origin constants for [DeletionMarkerRows].
class DeletionOrigin {
  const DeletionOrigin._();
  static const local = 'local';
  static const remote = 'remote';
}

/// Default trash cap in bytes (10 MB).
const int defaultTrashCapBytes = 10 * 1024 * 1024;

/// Per-row size overhead added to UTF-8 payload bytes to approximate DB cost.
const int deletedRecordSizeOverhead = 256;

/// Maximum rows in [DeletionMarkerRows], regardless of origin (unified FIFO).
const int deletionMarkerRowCap = 5000;

/// Maximum entries per entity type in `deleted.json`.
const int deletedJsonPerTypeCap = 5000;

/// Manages the [DeletedRecordRows] and [DeletionMarkerRows] tables.
///
/// On every local delete, the caller must call [recordDeletion] BEFORE the
/// physical DELETE, passing the full entity bundle as [recoveryJson]. This
/// writes both a [DeletedRecordRows] entry (payload, for local restore) and a
/// [DeletionMarkerRows] entry with `origin='local'` (id-only, for sync/backup).
///
/// Remote declarations from a peer's or backup's `deleted.json` are written via
/// [recordRemoteDeletion], which only writes a [DeletionMarkerRows] entry with
/// `origin='remote'` (no payload — the entity is still alive locally).
class DeletedRecordsStore {
  final AppDatabase _db;

  DeletedRecordsStore(this._db);

  /// Records a local deletion: dual-writes [DeletedRecordRows] (payload) and
  /// [DeletionMarkerRows] (origin='local' tombstone), then evicts to cap.
  ///
  /// [batchId] is shared by all rows from the same delete operation (e.g. an
  /// assistant cascade writes N+1 rows with the same batchId). The eviction
  /// never touches rows with the current [batchId] ("never self-evict current
  /// batch").
  Future<void> recordDeletion({
    required String id,
    required String type,
    required String recoveryJson,
    required String batchId,
    required DateTime deletedAt,
  }) async {
    final size = utf8.encode(recoveryJson).length + deletedRecordSizeOverhead;
    await _db.transaction(() async {
      await _db
          .into(_db.deletedRecordRows)
          .insert(
            DeletedRecordRowsCompanion.insert(
              id: id,
              type: type,
              recoveryJson: recoveryJson,
              size: size,
              createdAt: deletedAt,
              batchId: batchId,
            ),
            mode: InsertMode.insertOrReplace,
          );
      await _db
          .into(_db.deletionMarkerRows)
          .insert(
            DeletionMarkerRowsCompanion.insert(
              id: id,
              type: type,
              origin: DeletionOrigin.local,
              deletedAt: deletedAt,
            ),
            mode: InsertMode.insertOrReplace,
          );
    });
    await _evictToCap(excludeBatchId: batchId, capBytes: _currentCapBytes);
    await _evictMarkers();
  }

  /// Records a marker-only local deletion for a filesystem entity
  /// (`type=workspaceFile`, id = mount-relative wire path). No
  /// [DeletedRecordRows] payload is written — files are physically gone and
  /// not recoverable (Skill precedent; see ADR-0021).
  ///
  /// Also removes any `origin='remote'` row for the same path: a local
  /// deletion supersedes a peer's declaration (the "offer local delete"
  /// purpose of the remote row is moot once the file is gone here).
  Future<void> recordFileDeletion({
    required String id,
    required DateTime deletedAt,
  }) async {
    await _db.transaction(() async {
      await _db
          .into(_db.deletionMarkerRows)
          .insert(
            DeletionMarkerRowsCompanion.insert(
              id: id,
              type: DeletionEntityType.workspaceFile,
              origin: DeletionOrigin.local,
              deletedAt: deletedAt,
            ),
            mode: InsertMode.insertOrReplace,
          );
      await (_db.delete(_db.deletionMarkerRows)..where(
            (t) =>
                t.id.equals(id) &
                t.type.equals(DeletionEntityType.workspaceFile) &
                t.origin.equals(DeletionOrigin.remote),
          ))
          .go();
    });
    await _evictMarkers();
  }

  /// Records a remote deletion declaration from a peer/backup's deleted.json.
  /// Only writes a [DeletionMarkerRows] entry with origin='remote'. No payload
  /// — the entity is still alive locally; the UI offers one-click local delete.
  Future<void> recordRemoteDeletion({
    required String id,
    required String type,
    required DateTime remoteDeletedAt,
  }) async {
    await _db
        .into(_db.deletionMarkerRows)
        .insert(
          DeletionMarkerRowsCompanion.insert(
            id: id,
            type: type,
            origin: DeletionOrigin.remote,
            deletedAt: remoteDeletedAt,
          ),
          mode: InsertMode.insertOrReplace,
        );
    await _evictMarkers();
  }

  /// Batch variant of [recordRemoteDeletion] for importing a full deleted.json.
  /// Only writes markers for ids that still exist locally (caller filters).
  Future<void> recordRemoteDeletions({
    required String type,
    required List<({String id, DateTime deletedAt})> entries,
  }) async {
    if (entries.isEmpty) return;
    await _db.batch((b) {
      for (final e in entries) {
        b.insert(
          _db.deletionMarkerRows,
          DeletionMarkerRowsCompanion.insert(
            id: e.id,
            type: type,
            origin: DeletionOrigin.remote,
            deletedAt: e.deletedAt,
          ),
          mode: InsertMode.insertOrReplace,
        );
      }
    });
    await _evictMarkers();
  }

  /// Returns all [DeletedRecordRows] ordered newest-first for UI display.
  Future<List<DeletedRecordRow>> listDeletedRecords() async {
    return (_db.select(
      _db.deletedRecordRows,
    )..orderBy([(t) => OrderingTerm.desc(t.createdAt)])).get();
  }

  /// Returns all [DeletionMarkerRows] with origin='remote', newest-first.
  Future<List<DeletionMarkerRow>> listRemoteDeletionMarkers() async {
    return (_db.select(_db.deletionMarkerRows)
          ..where((t) => t.origin.equals(DeletionOrigin.remote))
          ..orderBy([(t) => OrderingTerm.desc(t.deletedAt)]))
        .get();
  }

  /// Returns all [DeletionMarkerRows] of type workspaceFile (both origins),
  /// newest-first. Backs the trash-page "File Marks" section.
  Future<List<DeletionMarkerRow>> listFileDeletionMarkers() async {
    return (_db.select(_db.deletionMarkerRows)
          ..where((t) => t.type.equals(DeletionEntityType.workspaceFile))
          ..orderBy([(t) => OrderingTerm.desc(t.deletedAt)]))
        .get();
  }

  /// Returns a specific [DeletedRecordRow] by id+type, or null if not found.
  Future<DeletedRecordRow?> getDeletedRecord(String id, String type) async {
    return (_db.select(
      _db.deletedRecordRows,
    )..where((t) => t.id.equals(id) & t.type.equals(type))).getSingleOrNull();
  }

  /// Removes a [DeletedRecordRow] after successful restore. Also removes the
  /// matching deletion marker (via [TrashRestoreCoordinator]) so the entity
  /// won't appear as a false conflict in the Pending tab after restore.
  Future<void> purgeDeletedRecord(String id, String type) async {
    await (_db.delete(
      _db.deletedRecordRows,
    )..where((t) => t.id.equals(id) & t.type.equals(type))).go();
  }

  /// Removes a [DeletionMarkerRow] with origin='remote' after the user clicks
  /// "在本机也删除" (one-click local delete of a remote-deleted entity).
  /// The actual entity deletion is handled by the caller; this only removes
  /// the marker.
  Future<void> purgeRemoteMarker(String id, String type) async {
    await (_db.delete(_db.deletionMarkerRows)..where(
          (t) =>
              t.id.equals(id) &
              t.type.equals(type) &
              t.origin.equals(DeletionOrigin.remote),
        ))
        .go();
  }

  /// Removes a [DeletionMarkerRow] with origin='local' (user chose to "keep"
  /// an entity that was re-inserted by merge). Does NOT delete the entity.
  Future<void> purgeLocalMarker(String id, String type) async {
    await (_db.delete(_db.deletionMarkerRows)..where(
          (t) =>
              t.id.equals(id) &
              t.type.equals(type) &
              t.origin.equals(DeletionOrigin.local),
        ))
        .go();
  }

  /// Returns markers where the entity still exists locally (conflicts).
  /// [localIdsForType] is a callback that returns the set of live
  /// ids for a given entity type — injected by [TrashRestoreCoordinator].
  Future<List<DeletionMarkerRow>> listConflicts(
    Future<Set<String>> Function(String type) localIdsForType,
  ) async {
    final all = await (_db.select(
      _db.deletionMarkerRows,
    )..orderBy([(t) => OrderingTerm.desc(t.deletedAt)])).get();
    final byType = <String, List<DeletionMarkerRow>>{};
    for (final m in all) {
      byType.putIfAbsent(m.type, () => []).add(m);
    }
    final conflicts = <DeletionMarkerRow>[];
    for (final entry in byType.entries) {
      final localIds = await localIdsForType(entry.key);
      conflicts.addAll(entry.value.where((m) => localIds.contains(m.id)));
    }
    return conflicts;
  }

  /// Permanently deletes all [DeletedRecordRows] (empty trash).
  Future<void> clearAllDeletedRecords() async {
    await _db.delete(_db.deletedRecordRows).go();
  }

  /// Total bytes consumed by [DeletedRecordRows] (sum of [DeletedRecordRow.size]).
  Future<int> totalDeletedRecordsSize() async {
    final sizeSum = _db.deletedRecordRows.size.sum();
    final row = await (_db.selectOnly(
      _db.deletedRecordRows,
    )..addColumns([sizeSum])).getSingle();
    return row.read(sizeSum) ?? 0;
  }

  /// Count of [DeletedRecordRows].
  Future<int> deletedRecordsCount() async {
    final count = _db.deletedRecordRows.id.count();
    final row = await (_db.selectOnly(
      _db.deletedRecordRows,
    )..addColumns([count])).getSingle();
    return row.read(count) ?? 0;
  }

  /// Count of [DeletionMarkerRows] with origin='remote'.
  Future<int> remoteMarkerCount() async {
    final count = _db.deletionMarkerRows.id.count();
    final row =
        await (_db.selectOnly(_db.deletionMarkerRows)
              ..addColumns([count])
              ..where(
                _db.deletionMarkerRows.origin.equals(DeletionOrigin.remote),
              ))
            .getSingle();
    return row.read(count) ?? 0;
  }

  /// Evicts oldest [DeletedRecordRows] until total size <= [capBytes].
  /// Rows with [excludeBatchId] are never evicted (current write batch).
  Future<void> _evictToCap({
    required String excludeBatchId,
    required int capBytes,
  }) async {
    if (capBytes <= 0) return; // 0 = unlimited
    final total = await totalDeletedRecordsSize();
    if (total <= capBytes) return;

    final candidates =
        await (_db.select(_db.deletedRecordRows)
              ..where((t) => t.batchId.equals(excludeBatchId).not())
              ..orderBy([(t) => OrderingTerm.asc(t.createdAt)]))
            .get();

    var remaining = total;
    for (final row in candidates) {
      if (remaining <= capBytes) break;
      await (_db.delete(
        _db.deletedRecordRows,
      )..where((t) => t.id.equals(row.id) & t.type.equals(row.type))).go();
      remaining -= row.size;
    }
  }

  /// Evicts oldest [DeletionMarkerRows] until count <= [deletionMarkerRowCap].
  /// Unified FIFO — does not distinguish origin.
  Future<void> _evictMarkers() async {
    final count = _db.deletionMarkerRows.id.count();
    final row = await (_db.selectOnly(
      _db.deletionMarkerRows,
    )..addColumns([count])).getSingle();
    final total = row.read(count) ?? 0;
    if (total <= deletionMarkerRowCap) return;
    final over = total - deletionMarkerRowCap;
    final oldest =
        await (_db.select(_db.deletionMarkerRows)
              ..orderBy([(t) => OrderingTerm.asc(t.deletedAt)])
              ..limit(over))
            .get();
    for (final row in oldest) {
      await (_db.delete(_db.deletionMarkerRows)..where(
            (t) =>
                t.id.equals(row.id) &
                t.type.equals(row.type) &
                t.origin.equals(row.origin),
          ))
          .go();
    }
  }

  /// Immediate eviction to a new cap (called when user lowers the cap setting).
  /// No batch exclusion — there is no current write batch.
  Future<void> evictToCap(int capBytes) async {
    if (capBytes <= 0) return;
    final total = await totalDeletedRecordsSize();
    if (total <= capBytes) return;

    final candidates = await (_db.select(
      _db.deletedRecordRows,
    )..orderBy([(t) => OrderingTerm.asc(t.createdAt)])).get();

    var remaining = total;
    for (final row in candidates) {
      if (remaining <= capBytes) break;
      await (_db.delete(
        _db.deletedRecordRows,
      )..where((t) => t.id.equals(row.id) & t.type.equals(row.type))).go();
      remaining -= row.size;
    }
  }

  int _currentCapBytes = defaultTrashCapBytes;

  /// Updates the in-memory cap and triggers immediate eviction if lowered.
  Future<void> setCapMb(int capMb) async {
    final newCapBytes = capMb <= 0 ? 0 : capMb * 1024 * 1024;
    final oldCapBytes = _currentCapBytes;
    _currentCapBytes = newCapBytes;
    if (newCapBytes > 0 && newCapBytes < oldCapBytes) {
      await evictToCap(newCapBytes);
    }
  }
}

/// Builds the `deleted.json` payload for backup/sync export.
///
/// Contains `{type: [{id, deletedAt}, ...]}` grouped by entity type, capped at
/// [deletedJsonPerTypeCap] entries per type by most-recent deletedAt. Sourced
/// only from [DeletionMarkerRows] with `origin='local'` — remote markers are
/// never echoed back.
Future<String> buildDeletedJson(AppDatabase db) async {
  final result = <String, List<Map<String, dynamic>>>{};
  for (final type in DeletionEntityType.all) {
    final rows =
        await (db.select(db.deletionMarkerRows)
              ..where(
                (t) =>
                    t.type.equals(type) & t.origin.equals(DeletionOrigin.local),
              )
              ..orderBy([(t) => OrderingTerm.desc(t.deletedAt)])
              ..limit(deletedJsonPerTypeCap))
            .get();
    result[type] = rows
        .map((r) => {'id': r.id, 'deletedAt': r.deletedAt.toIso8601String()})
        .toList();
  }
  return jsonEncode(result);
}

/// Parses an incoming `deleted.json` and returns entries grouped by type.
///
/// Returns an empty map if [jsonStr] is null/empty/malformed (backward
/// compatible — old-format backups have no deleted.json).
Map<String, List<({String id, DateTime deletedAt})>> parseDeletedJson(
  String? jsonStr,
) {
  if (jsonStr == null || jsonStr.isEmpty) return const {};
  try {
    final decoded = jsonDecode(jsonStr) as Map<String, dynamic>;
    final result = <String, List<({String id, DateTime deletedAt})>>{};
    for (final entry in decoded.entries) {
      final type = entry.key;
      final list = entry.value;
      if (list is! List) continue;
      final parsed = <({String id, DateTime deletedAt})>[];
      for (final item in list) {
        if (item is! Map) continue;
        final id = item['id']?.toString();
        final deletedAtStr = item['deletedAt']?.toString();
        if (id == null || deletedAtStr == null) continue;
        try {
          final deletedAt = DateTime.parse(deletedAtStr);
          parsed.add((id: id, deletedAt: deletedAt));
        } catch (e) {
          debugPrint('parseDeletedJson: skipped malformed deletedAt: $e');
        }
      }
      if (parsed.isNotEmpty) result[type] = parsed;
    }
    return result;
  } catch (e) {
    debugPrint('parseDeletedJson: malformed deleted.json: $e');
    return const {};
  }
}
