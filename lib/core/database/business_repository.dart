import 'dart:convert';

import 'package:drift/drift.dart';

import '../models/memory_entry.dart';
import '../services/sync/sync_merge.dart';
import '../services/sync/sync_models.dart';
import 'app_database.dart';
import 'business_data.dart';
import 'business_settings_router.dart';
import 'schema_columns.dart';

final class BusinessRepository {
  BusinessRepository(this._database);

  static const migrationReceiptKey = 'business_migration_complete_v1';

  final AppDatabase _database;

  /// Used by cross-domain coordinators to fail closed unless both
  /// repositories are backed by the exact same Drift database instance.
  bool sharesDatabaseIdentity(Object identity) =>
      identical(_database, identity);

  Future<List<BusinessEntityValue>> readEntities(BusinessEntityKind kind) =>
      _readEntities(kind);

  Future<List<BusinessEntityValue>> readMemoriesForAssistant(
    String assistantId,
  ) async {
    final normalizedId = assistantId.trim();
    if (normalizedId.isEmpty) return const <BusinessEntityValue>[];
    return _readEntities(
      BusinessEntityKind.assistantMemory,
      assistantId: normalizedId,
    );
  }

  Future<void> replaceEntities(
    BusinessEntityKind kind,
    List<BusinessEntityValue> rows,
  ) async {
    _validateRows(kind, rows);
    await _database.transaction(() => _replaceEntities(kind, rows));
  }

  Future<void> synchronizeEntities(
    BusinessEntityKind kind,
    List<BusinessEntityValue> rows,
  ) async {
    _validateRows(kind, rows);
    await _database.transaction(() async {
      final existing = await _readEntities(kind);
      final existingById = <String, BusinessEntityValue>{
        for (final row in existing) row.id: row,
      };
      final retainedIds = rows.map((row) => row.id).toSet();
      for (final row in existing) {
        if (!retainedIds.contains(row.id)) {
          _assertDecodablePayload(kind, row);
          await _deleteEntity(kind, row.id);
        }
      }
      final updatedAt = DateTime.now().toUtc().microsecondsSinceEpoch;
      for (final row in rows) {
        final previous = existingById[row.id];
        if (previous != null && _sameEntity(previous, row)) continue;
        await _upsertEntity(kind, row, updatedAt: updatedAt);
      }
    });
  }

  Future<void> upsertEntity(
    BusinessEntityKind kind,
    BusinessEntityValue row,
  ) async {
    _validateRows(kind, <BusinessEntityValue>[row]);
    await _upsertEntity(
      kind,
      row,
      updatedAt: DateTime.now().toUtc().microsecondsSinceEpoch,
    );
  }

  Future<void> deleteEntity(BusinessEntityKind kind, String id) async {
    if (id.isEmpty) return;
    await _deleteEntity(kind, id);
  }

  Future<Object?> getPreference(String key) async {
    final row = await _database
        .customSelect(
          'SELECT value FROM preference_rows WHERE key = ?;',
          variables: <Variable<Object>>[Variable<String>(key)],
          readsFrom: {_database.preferenceRows},
        )
        .getSingleOrNull();
    if (row == null) return null;
    return _decodePreference(key, row.read<String>('value'));
  }

  Future<void> setPreference(String key, Object value) async {
    if (key.isEmpty) throw ArgumentError.value(key, 'key');
    final normalized = _normalizePreference(key, value);
    await _database.customStatement(
      'INSERT INTO preference_rows (key, value, updated_at) VALUES (?, ?, ?) '
      'ON CONFLICT(key) DO UPDATE SET value = excluded.value, '
      'updated_at = excluded.updated_at;',
      <Object?>[
        key,
        jsonEncode(normalized),
        DateTime.now().toUtc().microsecondsSinceEpoch,
      ],
    );
  }

  Future<void> removePreference(String key) => _database.customStatement(
    'DELETE FROM preference_rows WHERE key = ?;',
    <Object?>[key],
  );

  Future<Map<String, Object>> preferenceSnapshot() async {
    final rows = await _database
        .customSelect(
          'SELECT key, value FROM preference_rows ORDER BY key;',
          readsFrom: {_database.preferenceRows},
        )
        .get();
    return Map<String, Object>.unmodifiable({
      for (final row in rows)
        row.read<String>('key'): _decodePreference(
          row.read<String>('key'),
          row.read<String>('value'),
        ),
    });
  }

  Future<BusinessSnapshot> readSnapshot() =>
      _database.transaction(_readSnapshot);

  Future<void> replaceSnapshot(
    BusinessSnapshot snapshot, {
    bool writeReceipt = false,
  }) async {
    final preferences = _validateSnapshot(snapshot);
    await _database.transaction(
      () => _replaceSnapshot(
        snapshot,
        preferences: preferences,
        writeReceipt: writeReceipt,
      ),
    );
  }

  /// Replaces business state, validates the persisted projection and only
  /// then publishes the migration receipt, all within one SQLite transaction.
  Future<void> replaceSnapshotForMigration(
    BusinessSnapshot snapshot, {
    required void Function(BusinessSnapshot persisted) validatePersisted,
  }) async {
    final preferences = _validateSnapshot(snapshot);
    await _database.transaction(() async {
      await _replaceSnapshot(
        snapshot,
        preferences: preferences,
        writeReceipt: false,
      );
      validatePersisted(await _readSnapshot());
      await _writeMigrationReceipt();
    });
  }

  /// Returns false when `PRAGMA wal_checkpoint(FULL)` reports `busy != 0`.
  Future<bool> checkpoint() async {
    final row = await _database
        .customSelect('PRAGMA wal_checkpoint(FULL);')
        .getSingle();
    return row.read<int>('busy') == 0;
  }

  Future<void> transformSnapshot(
    BusinessSnapshot Function(BusinessSnapshot current) transform, {
    bool writeReceipt = false,
  }) => _database.transaction(() async {
    final next = transform(await _readSnapshot());
    final preferences = _validateSnapshot(next);
    await _replaceSnapshot(
      next,
      preferences: preferences,
      writeReceipt: writeReceipt,
    );
  });

  Future<BusinessSnapshot> _readSnapshot() async {
    final entities = <BusinessEntityKind, List<BusinessEntityValue>>{};
    for (final kind in BusinessEntityKind.values) {
      entities[kind] = await _readEntities(kind);
    }
    return BusinessSnapshot(
      entities: entities,
      preferences: await preferenceSnapshot(),
    );
  }

  static Map<String, Object> _validateSnapshot(BusinessSnapshot snapshot) {
    for (final kind in BusinessEntityKind.values) {
      _validateRows(kind, snapshot.entities[kind]!);
    }
    final preferences = <String, Object>{};
    for (final entry in snapshot.preferences.entries) {
      if (entry.key.isEmpty) throw ArgumentError.value(entry.key, 'key');
      preferences[entry.key] = _normalizePreference(entry.key, entry.value);
    }
    return preferences;
  }

  Future<void> _replaceSnapshot(
    BusinessSnapshot snapshot, {
    required Map<String, Object> preferences,
    required bool writeReceipt,
  }) async {
    for (final kind in BusinessEntityKind.values) {
      await _replaceEntities(kind, snapshot.entities[kind]!);
    }
    await _replacePreferences(preferences);
    if (writeReceipt) await _writeMigrationReceipt();
  }

  Future<void> clearAll() async {
    await _database.transaction(() async {
      for (final kind in BusinessEntityKind.values) {
        await _clearEntities(kind);
      }
      await _database.customStatement('DELETE FROM preference_rows;');
    });
  }

  Future<bool> hasMigrationReceipt() async {
    final row = await _database
        .customSelect(
          'SELECT value FROM chat_storage_meta_rows WHERE key = ?;',
          variables: const <Variable<Object>>[
            Variable<String>(migrationReceiptKey),
          ],
          readsFrom: {_database.chatStorageMetaRows},
        )
        .getSingleOrNull();
    if (row == null) return false;
    if (row.read<String>('value') != 'true') {
      throw StateError('business_migration_receipt');
    }
    return true;
  }

  Future<void> writeMigrationReceipt() =>
      _database.transaction(_writeMigrationReceipt);

  Future<void> clearMigrationReceipt() => _database.customStatement(
    'DELETE FROM chat_storage_meta_rows WHERE key = ?;',
    <Object?>[migrationReceiptKey],
  );

  Future<List<BusinessEntityValue>> _readEntities(
    BusinessEntityKind kind, {
    String? assistantId,
  }) async {
    final isMemory = kind == BusinessEntityKind.assistantMemory;
    final filter = kind.extensionKind != null
        ? ' WHERE kind = ?'
        : assistantId == null
        ? ''
        : ' WHERE assistant_id = ?';
    final rows = await _database
        .customSelect(
          'SELECT ${kind.idColumn} AS entity_id, sort_order, payload'
          '${isMemory ? ', assistant_id' : ''} FROM ${kind.tableName}'
          '$filter ORDER BY sort_order, ${kind.idColumn};',
          variables: kind.extensionKind != null
              ? <Variable<Object>>[Variable<String>(kind.extensionKind!)]
              : assistantId == null
              ? const <Variable<Object>>[]
              : <Variable<Object>>[Variable<String>(assistantId)],
        )
        .get();
    return List<BusinessEntityValue>.unmodifiable(
      rows.map(
        (row) => BusinessEntityValue(
          id: row.read<String>('entity_id'),
          sortOrder: row.read<int>('sort_order'),
          payload: row.read<String>('payload'),
          assistantId: isMemory ? row.read<String>('assistant_id') : null,
        ),
      ),
    );
  }

  Future<void> _clearEntities(
    BusinessEntityKind kind,
  ) => _database.customStatement(
    'DELETE FROM ${kind.tableName}${kind.extensionKind == null ? '' : ' WHERE kind = ?'};',
    <Object?>[if (kind.extensionKind != null) kind.extensionKind],
  );

  Future<void> _replaceEntities(
    BusinessEntityKind kind,
    List<BusinessEntityValue> rows,
  ) async {
    await _clearEntities(kind);
    final updatedAt = DateTime.now().toUtc().microsecondsSinceEpoch;
    for (final row in rows) {
      await _upsertEntity(kind, row, updatedAt: updatedAt);
    }
  }

  Future<void> _upsertEntity(
    BusinessEntityKind kind,
    BusinessEntityValue row, {
    required int updatedAt,
  }) {
    if (kind.extensionKind != null) {
      return _database.customStatement(
        'INSERT INTO extension_entity_rows '
        '(kind, id, sort_order, payload, updated_at) VALUES (?, ?, ?, ?, ?) '
        'ON CONFLICT(kind, id) DO UPDATE SET sort_order = excluded.sort_order, '
        'payload = excluded.payload, updated_at = excluded.updated_at;',
        <Object?>[
          kind.extensionKind,
          row.id,
          row.sortOrder,
          row.payload,
          updatedAt,
        ],
      );
    }
    if (kind == BusinessEntityKind.assistantMemory) {
      return _database.customStatement(
        'INSERT INTO assistant_memory_rows '
        '(id, sort_order, assistant_id, payload, updated_at) '
        'VALUES (?, ?, ?, ?, ?) ON CONFLICT(id) DO UPDATE SET '
        'sort_order = excluded.sort_order, '
        'assistant_id = excluded.assistant_id, payload = excluded.payload, '
        'updated_at = excluded.updated_at;',
        <Object?>[
          row.id,
          row.sortOrder,
          row.assistantId,
          row.payload,
          updatedAt,
        ],
      );
    }
    if (kind == BusinessEntityKind.memoryEntry) {
      final Object? decoded;
      try {
        decoded = jsonDecode(row.payload);
      } on FormatException {
        throw ArgumentError.value(row.payload, 'payload');
      }
      if (decoded is! Map) {
        throw ArgumentError.value(row.payload, 'payload');
      }
      final payload = decoded.map(
        (key, value) => MapEntry(key.toString(), value),
      );
      final content = payload['content'];
      if (content is! String) {
        throw ArgumentError.value(row.payload, 'payload');
      }
      final scope = payload['scope'];
      if (scope is! String) {
        throw ArgumentError.value(row.payload, 'payload');
      }
      final type = payload['type'];
      if (type is! String) {
        throw ArgumentError.value(row.payload, 'payload');
      }
      final status = payload['status'] is String
          ? payload['status'] as String
          : 'active';
      final createdAt = payload['createdAt'];
      final entryUpdatedAt = payload['updatedAt'];
      if (createdAt is! num || entryUpdatedAt is! num) {
        throw ArgumentError.value(row.payload, 'payload');
      }
      final rawAssistantId = payload['assistantId'];
      final assistantId = rawAssistantId is String ? rawAssistantId : null;
      return _database.customStatement(
        'INSERT INTO memory_entry_rows '
        '(id, sort_order, scope, assistant_id, type, status, content, '
        'content_normalized, entry_created_at, entry_updated_at, payload, '
        'updated_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?) '
        'ON CONFLICT(id) DO UPDATE SET '
        'sort_order = excluded.sort_order, scope = excluded.scope, '
        'assistant_id = excluded.assistant_id, type = excluded.type, '
        'status = excluded.status, content = excluded.content, '
        'content_normalized = excluded.content_normalized, '
        'entry_created_at = excluded.entry_created_at, '
        'entry_updated_at = excluded.entry_updated_at, '
        'payload = excluded.payload, updated_at = excluded.updated_at;',
        <Object?>[
          row.id,
          row.sortOrder,
          scope,
          assistantId,
          type,
          status,
          content,
          normalizeMemoryContent(content),
          createdAt.toInt(),
          entryUpdatedAt.toInt(),
          row.payload,
          updatedAt,
        ],
      );
    }
    return _database.customStatement(
      'INSERT INTO ${kind.tableName} '
      '(${kind.idColumn}, sort_order, payload, updated_at) '
      'VALUES (?, ?, ?, ?) ON CONFLICT(${kind.idColumn}) DO UPDATE SET '
      'sort_order = excluded.sort_order, payload = excluded.payload, '
      'updated_at = excluded.updated_at;',
      <Object?>[row.id, row.sortOrder, row.payload, updatedAt],
    );
  }

  /// Treats the named conversations as already extracted through their current
  /// max message_order and clears their injection hash (§6.7).
  ///
  /// Scoped to the conversations a merge restore actually touched: bumping the
  /// watermark of an untouched local conversation would silently skip one round
  /// of background extraction for messages the user just sent.
  Future<void> applyPostMergeMemoryConversationState(
    Iterable<String> conversationIds,
  ) async {
    final ids = conversationIds.where((id) => id.isNotEmpty).toSet();
    if (ids.isEmpty) return;
    final placeholders = List.filled(ids.length, '?').join(', ');
    await _database.customStatement('''
UPDATE conversation_rows SET
  injected_memory_hash = NULL,
  last_memory_extracted_order = COALESCE(
    (SELECT MAX(m.message_order)
     FROM message_rows m
     WHERE m.conversation_id = conversation_rows.id),
    -1
  )
WHERE id IN ($placeholders);
''', ids.toList(growable: false));
  }

  /// The `content_normalized` projection must match the model's rule exactly,
  /// or dedupe lookups silently miss rows that differ only in whitespace.
  static String normalizeMemoryContent(String content) =>
      MemoryEntry.normalizeContent(content);

  Future<void> _deleteEntity(BusinessEntityKind kind, String id) =>
      _database.customStatement(
        'DELETE FROM ${kind.tableName} WHERE ${kind.idColumn} = ?'
        '${kind.extensionKind == null ? '' : ' AND kind = ?'};',
        <Object?>[id, if (kind.extensionKind != null) kind.extensionKind],
      );

  Future<void> _replacePreferences(Map<String, Object> preferences) async {
    await _database.customStatement('DELETE FROM preference_rows;');
    final updatedAt = DateTime.now().toUtc().microsecondsSinceEpoch;
    for (final entry in preferences.entries) {
      await _database.customStatement(
        'INSERT INTO preference_rows (key, value, updated_at) '
        'VALUES (?, ?, ?);',
        <Object?>[entry.key, jsonEncode(entry.value), updatedAt],
      );
    }
  }

  Future<void> _writeMigrationReceipt() => _database.customStatement(
    'INSERT INTO chat_storage_meta_rows (key, value) VALUES (?, ?) '
    'ON CONFLICT(key) DO UPDATE SET value = excluded.value;',
    <Object?>[migrationReceiptKey, 'true'],
  );

  static void _validateRows(
    BusinessEntityKind kind,
    List<BusinessEntityValue> rows,
  ) {
    final ids = <String>{};
    for (final row in rows) {
      if (row.id.isEmpty) throw ArgumentError.value(row.id, 'id');
      if (row.sortOrder < 0) {
        throw ArgumentError.value(row.sortOrder, 'sortOrder');
      }
      if (!ids.add(row.id)) throw ArgumentError.value(row.id, 'duplicateId');
      final Object? decoded;
      try {
        decoded = jsonDecode(row.payload);
      } on FormatException {
        throw ArgumentError.value(row.payload, 'payload');
      }
      if (decoded is! Map) {
        throw ArgumentError.value(row.payload, 'payload');
      }
      if (kind == BusinessEntityKind.assistantMemory) {
        final assistantId = row.assistantId;
        if (assistantId == null || assistantId.trim().isEmpty) {
          throw ArgumentError.value(assistantId, 'assistantId');
        }
        if (decoded['assistantId'] != assistantId) {
          throw ArgumentError.value(row.payload, 'payload');
        }
      }
    }
  }

  /// Refuses to drop an existing row whose payload no longer decodes: the
  /// caller's snapshot may be missing the row precisely because it failed to
  /// read it, and deleting it would physically erase the surviving data.
  static void _assertDecodablePayload(
    BusinessEntityKind kind,
    BusinessEntityValue row,
  ) {
    final Object? decoded;
    try {
      decoded = jsonDecode(row.payload);
    } on FormatException {
      throw StateError(
        'business_entity_undecodable:${kind.tableName}:${row.id}',
      );
    }
    if (decoded is! Map) {
      throw StateError(
        'business_entity_undecodable:${kind.tableName}:${row.id}',
      );
    }
  }

  static bool _sameEntity(
    BusinessEntityValue left,
    BusinessEntityValue right,
  ) =>
      left.id == right.id &&
      left.sortOrder == right.sortOrder &&
      left.payload == right.payload &&
      left.assistantId == right.assistantId;

  // ---------------------------------------------------------------------------
  // LAN sync (ADR-0002, slice 2)
  //
  // Business rows travel as raw column maps, exactly like conversation
  // subtrees: storage format is wire format, so no translation layer can drift
  // from the schema. Merge is per row, on the row's own clock (`updated_at`,
  // ties to the higher deviceId), which is why an applied row keeps the
  // *peer's* `updated_at` instead of being stamped with `DateTime.now()` — that
  // clock is the entire basis for the next session's comparison.
  //
  // Deletions are not part of the payload: like message rows, they are derived
  // from the plan by diffing against the per-peer checkpoint, so no extra
  // tombstone bookkeeping is written on the hot path of every entity edit.
  //
  // SQL is built from [currentSchemaColumns] — schema facts — while the wire
  // row only ever supplies values, so a peer cannot smuggle a column or clause
  // in through a crafted key.
  // ---------------------------------------------------------------------------

  /// Entity kinds that never ride sync. Workspaces are host paths and local
  /// project directories by definition; a skill travels as a record plus its
  /// directory blob (slice 3), and a record without its body would only install
  /// a broken skill on the peer.
  static const syncExcludedKinds = <BusinessEntityKind>{
    BusinessEntityKind.workspace,
    BusinessEntityKind.skill,
  };

  /// Ids per `IN (...)` batch, well under SQLite's bound-variable limit.
  static const _syncIdBatch = 200;

  static final Map<String, BusinessEntityKind> _syncKindByTable = {
    for (final kind in BusinessEntityKind.values)
      if (!syncExcludedKinds.contains(kind)) kind.tableName: kind,
  };

  static Iterable<BusinessEntityKind> get _syncKinds => _syncKindByTable.values;

  /// The entity kind behind a wire kind (table) name, or null for a kind this
  /// build does not sync — an unknown name is ignored rather than fatal.
  static BusinessEntityKind? syncKindForWire(String wire) =>
      _syncKindByTable[wire];

  /// Every syncable entity row as a manifest ref: wire kind, row id, the row's
  /// mutation clock and a content hash of its payload. The hash is what makes
  /// "same clock, different content" visible, so a clock tie still exchanges
  /// rows and resolves by deviceId instead of silently diverging.
  Future<List<({String kindWire, String id, int updatedAtUs, String digest})>>
  syncEntityRefs() async {
    final refs =
        <({String kindWire, String id, int updatedAtUs, String digest})>[];
    for (final kind in _syncKinds) {
      final rows = await _database
          .customSelect(
            'SELECT ${kind.idColumn}, payload, updated_at FROM '
            '${kind.tableName};',
          )
          .get();
      for (final row in rows) {
        final id = row.read<String>(kind.idColumn);
        final payload = row.read<String>('payload');
        refs.add((
          kindWire: kind.tableName,
          id: id,
          updatedAtUs: row.read<int>('updated_at'),
          digest: businessContentDigest(payload),
        ));
      }
    }
    return refs;
  }

  /// Every synced preference as a manifest ref. Membership is decided by
  /// [BusinessKeyRegistry], the single authority — device-local keys never
  /// reach the wire.
  Future<List<({String key, int updatedAtUs, String digest})>>
  syncPreferenceRefs() async {
    final rows = await _database
        .customSelect('SELECT key, value, updated_at FROM preference_rows;')
        .get();
    return [
      for (final row in rows)
        if (BusinessKeyRegistry.classify(row.read<String>('key')) ==
            BusinessKeyDisposition.syncedPreference)
          (
            key: row.read<String>('key'),
            updatedAtUs: row.read<int>('updated_at'),
            digest: businessContentDigest(row.read<String>('value')),
          ),
    ];
  }

  /// The named entity rows, as raw column maps ready to travel.
  Future<List<Map<String, dynamic>>> syncReadEntityRows(
    String kindWire,
    Set<String> ids,
  ) async {
    final kind = syncKindForWire(kindWire);
    if (kind == null || ids.isEmpty) return const [];
    final rows = <Map<String, dynamic>>[];
    for (final batch in _batched(ids)) {
      final result = await _database
          .customSelect(
            'SELECT * FROM ${kind.tableName} WHERE ${kind.idColumn} IN '
            '(${List.filled(batch.length, '?').join(', ')});',
            variables: [for (final id in batch) Variable<String>(id)],
          )
          .get();
      rows.addAll([
        for (final row in result) Map<String, dynamic>.from(row.data),
      ]);
    }
    return rows;
  }

  /// The named preference rows, as raw column maps.
  Future<List<Map<String, dynamic>>> syncReadPreferenceRows(
    Set<String> keys,
  ) async {
    if (keys.isEmpty) return const [];
    final rows = <Map<String, dynamic>>[];
    for (final batch in _batched(keys)) {
      final result = await _database
          .customSelect(
            'SELECT * FROM preference_rows WHERE key IN '
            '(${List.filled(batch.length, '?').join(', ')});',
            variables: [for (final key in batch) Variable<String>(key)],
          )
          .get();
      rows.addAll([
        for (final row in result) Map<String, dynamic>.from(row.data),
      ]);
    }
    return rows;
  }

  /// Applies incoming business rows in one transaction, keeping only those that
  /// win their row's LWW comparison. Unknown kinds are skipped: a peer built
  /// with a kind this build does not know must not break the session.
  Future<SyncBusinessApplyOutcome> syncApplyBusinessRows({
    required Map<String, List<Map<String, dynamic>>> entities,
    required List<Map<String, dynamic>> preferences,
    required String myDeviceId,
    required String peerDeviceId,
  }) async {
    var entityRowsWritten = 0;
    var preferencesWritten = 0;
    await _database.transaction(() async {
      for (final entry in entities.entries) {
        final kind = syncKindForWire(entry.key);
        if (kind == null) continue;
        final columns = currentSchemaColumns[kind.tableName]!;
        for (final row in entry.value) {
          final id = row[kind.idColumn];
          if (id is! String || id.isEmpty) continue;
          final incomingAt = (row['updated_at'] as num?)?.toInt();
          if (incomingAt == null) continue;
          final localAt = await _syncEntityClock(kind, id);
          if (localAt != null &&
              !incomingBusinessRowWins(
                localUpdatedAtUs: localAt,
                incomingUpdatedAtUs: incomingAt,
                myDeviceId: myDeviceId,
                peerDeviceId: peerDeviceId,
              )) {
            continue;
          }
          await _upsertSyncRow(kind.tableName, columns, row, [kind.idColumn]);
          entityRowsWritten++;
        }
      }
      for (final row in preferences) {
        final key = row['key'];
        final value = row['value'];
        final incomingAt = (row['updated_at'] as num?)?.toInt();
        if (key is! String || value is! String || incomingAt == null) continue;
        // A peer must not make this device hold a key it never syncs.
        if (BusinessKeyRegistry.classify(key) !=
            BusinessKeyDisposition.syncedPreference) {
          continue;
        }
        final localAt = await _syncPreferenceClock(key);
        if (localAt != null &&
            !incomingBusinessRowWins(
              localUpdatedAtUs: localAt,
              incomingUpdatedAtUs: incomingAt,
              myDeviceId: myDeviceId,
              peerDeviceId: peerDeviceId,
            )) {
          continue;
        }
        await _upsertSyncRow(
          'preference_rows',
          currentSchemaColumns['preference_rows']!,
          row,
          const ['key'],
        );
        preferencesWritten++;
      }
    });
    return SyncBusinessApplyOutcome(
      entityRowsWritten: entityRowsWritten,
      preferencesWritten: preferencesWritten,
      changed: entityRowsWritten > 0 || preferencesWritten > 0,
    );
  }

  /// Deletes one entity row the peer no longer has. Returns false when there
  /// was nothing to delete (already gone), which is not an error.
  Future<bool> syncDeleteEntity(String kindWire, String id) async {
    final kind = syncKindForWire(kindWire);
    if (kind == null || id.isEmpty) return false;
    final statement = _database.customStatement(
      'DELETE FROM ${kind.tableName} WHERE ${kind.idColumn} = ?;',
      <Object?>[id],
    );
    await statement;
    return true;
  }

  /// Deletes one synced preference the peer no longer has.
  Future<bool> syncDeletePreference(String key) async {
    if (key.isEmpty) return false;
    if (BusinessKeyRegistry.classify(key) !=
        BusinessKeyDisposition.syncedPreference) {
      return false;
    }
    await _database.customStatement(
      'DELETE FROM preference_rows WHERE key = ?;',
      <Object?>[key],
    );
    return true;
  }

  Future<int?> _syncEntityClock(BusinessEntityKind kind, String id) async {
    final row = await _database
        .customSelect(
          'SELECT updated_at FROM ${kind.tableName} WHERE ${kind.idColumn} = ?;',
          variables: <Variable<Object>>[Variable<String>(id)],
        )
        .getSingleOrNull();
    return row?.read<int>('updated_at');
  }

  Future<int?> _syncPreferenceClock(String key) async {
    final row = await _database
        .customSelect(
          'SELECT updated_at FROM preference_rows WHERE key = ?;',
          variables: <Variable<Object>>[Variable<String>(key)],
        )
        .getSingleOrNull();
    return row?.read<int>('updated_at');
  }

  /// INSERT ... ON CONFLICT over an allowlisted column list. Values come from
  /// the wire row by column name, so a column the peer cannot name simply
  /// arrives as null and takes its schema default.
  Future<void> _upsertSyncRow(
    String table,
    List<String> columns,
    Map<String, dynamic> row,
    List<String> conflictTarget,
  ) async {
    final updates = columns
        .where((column) => !conflictTarget.contains(column))
        .map((column) => '$column = excluded.$column')
        .join(', ');
    await _database.customStatement(
      'INSERT INTO $table (${columns.join(', ')}) '
      'VALUES (${List.filled(columns.length, '?').join(', ')}) '
      'ON CONFLICT(${conflictTarget.join(', ')}) DO UPDATE SET $updates;',
      [for (final column in columns) row[column]],
    );
  }

  static Iterable<List<String>> _batched(Set<String> ids) sync* {
    final all = ids.toList(growable: false);
    for (var start = 0; start < all.length; start += _syncIdBatch) {
      final end = start + _syncIdBatch;
      yield all.sublist(start, end > all.length ? all.length : end);
    }
  }

  static Object _normalizePreference(String key, Object value) {
    if (value is bool || value is int || value is double || value is String) {
      jsonEncode(value);
      return value;
    }
    if (value is List && value.every((item) => item is String)) {
      return List<String>.unmodifiable(value.cast<String>());
    }
    throw ArgumentError.value(value, key);
  }

  static Object _decodePreference(String key, String encoded) {
    final Object? decoded;
    try {
      decoded = jsonDecode(encoded);
    } on FormatException {
      throw StateError('business_preference_value:$key');
    }
    if (decoded == null) throw StateError('business_preference_value:$key');
    try {
      return _normalizePreference(key, decoded);
    } on ArgumentError {
      throw StateError('business_preference_value:$key');
    }
  }
}
