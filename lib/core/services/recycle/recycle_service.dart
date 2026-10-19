import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart';
import 'package:flutter/foundation.dart';

import '../../database/app_database.dart';
import '../../database/business_data.dart';
import '../../database/chat_database_repository.dart';
import '../../database/schema_columns.dart';
import 'recycle_store.dart';

export 'recycle_store.dart';

/// What happened to one restore attempt.
enum RecycleRestoreOutcome {
  /// The rows are back, and the entries that staged them are retired.
  restored,

  /// A conversation with that id is present again: bringing the staged subtree
  /// back would either merge two histories or overwrite one of them, and
  /// neither is what "recover the thing I deleted" means.
  skippedExisting,

  /// The staged body is gone or no longer parses.
  unreadable,

  /// This build cannot restore that kind of entry.
  unsupported,

  /// The write itself failed; the entry is untouched and can be retried.
  failed,
}

/// The recycle bin's one policy point: what gets staged, and what a restore
/// writes back.
///
/// It exists so the two halves of the feature cannot drift: a staged
/// conversation is read from exactly the tables a restore writes to, and a
/// staged row keeps the clock a restore has to reason about. Callers on the
/// deletion and merge paths only stage; the bin page only lists and restores.
///
/// Every staging call is best effort by contract. A bin that cannot be written
/// logs and returns: it is a safety net under a delete the user asked for, not
/// a condition of it.
final class RecycleService {
  RecycleService(this._database, {RecycleStore? store})
    : _store = store ?? RecycleStore();

  /// Tables a conversation delete cascades into, each with the column that ties
  /// its rows to the conversation. `conversation_rows` keys on the id itself.
  ///
  /// This list is the whole of a conversation snapshot: a table that is not
  /// here is not recovered, which is why it names the cascade targets
  /// explicitly rather than walking foreign keys.
  static const List<({String table, String column})> _conversationTables = [
    (table: 'conversation_rows', column: 'id'),
    (table: 'conversation_mcp_server_rows', column: 'conversation_id'),
    (table: 'message_rows', column: 'conversation_id'),
    (table: 'message_part_rows', column: 'conversation_id'),
    (table: 'provider_artifact_rows', column: 'conversation_id'),
    (table: 'message_prompt_rows', column: 'conversation_id'),
    (table: 'message_asset_rows', column: 'conversation_id'),
  ];

  final AppDatabase _database;
  final RecycleStore _store;
  final Set<Future<void>> _pending = <Future<void>>{};

  /// Stages the whole subtree of a conversation that is about to be deleted.
  ///
  /// Called from inside the delete's transaction, before the row goes, so what
  /// is staged is what the cascade is about to remove. The capture is part of
  /// that transaction; the write is [detached][_detach], because the delete is
  /// something the user is waiting for and the bin is only its safety net.
  Future<void> stageConversationDeletion(
    String conversationId, {
    required RecycleOrigin origin,
    RecycleGroup? group,
  }) async {
    if (conversationId.isEmpty) return;
    try {
      final tables = await _readConversationSubtree(conversationId);
      // No conversation row means there is nothing this id owns to preserve.
      if (tables == null) return;
      final title = tables['conversation_rows']!.first['title'];
      _detach(
        () => _store.stageRows(
          type: RecycleEntryType.conversation,
          origin: origin,
          reason: RecycleReason.deleted,
          key: conversationId,
          title: title is String ? title : '',
          tables: tables,
          group: group,
        ),
      );
    } catch (error) {
      debugPrint(
        'recycle: staging conversation $conversationId failed: $error',
      );
    }
  }

  /// Stages one business entity row — an assistant, provider, world book,
  /// memory entry, or any other user-managed row of its kind.
  Future<void> stageEntityRow(
    BusinessEntityKind kind,
    String id, {
    required RecycleOrigin origin,
    required RecycleReason reason,
    RecycleGroup? group,
  }) async {
    if (id.isEmpty) return;
    try {
      final rows = await _entityRows(kind, id);
      if (rows.isEmpty) return;
      final row = rows.first;
      final payload = row['payload'];
      _detach(
        () => _store.stageRows(
          type: RecycleEntryType.businessEntity,
          origin: origin,
          reason: reason,
          key: id,
          title: payload is String ? _entityTitle(payload, id) : id,
          kindWire: kind.wireName,
          tables: {
            kind.tableName: [row],
          },
          group: group,
        ),
      );
    } catch (error) {
      debugPrint('recycle: staging ${kind.wireName} $id failed: $error');
    }
  }

  /// Stages one synced preference row.
  Future<void> stagePreferenceRow(
    String key, {
    required RecycleOrigin origin,
    required RecycleReason reason,
    RecycleGroup? group,
  }) async {
    if (key.isEmpty) return;
    try {
      final row = await _database
          .customSelect(
            'SELECT * FROM preference_rows WHERE key = ?;',
            variables: <Variable<Object>>[Variable<String>(key)],
          )
          .getSingleOrNull();
      if (row == null) return;
      _detach(
        () => _store.stageRows(
          type: RecycleEntryType.preference,
          origin: origin,
          reason: reason,
          key: key,
          title: key,
          tables: {
            'preference_rows': [Map<String, Object?>.from(row.data)],
          },
          group: group,
        ),
      );
    } catch (error) {
      debugPrint('recycle: staging preference $key failed: $error');
    }
  }

  /// Waits for every bin write this service has started.
  ///
  /// Production never needs this — the writes are the bin's own business — but
  /// a test that asserts what the bin holds after an operation has to let that
  /// operation's net finish first.
  @visibleForTesting
  Future<void> settle() async {
    while (_pending.isNotEmpty) {
      await Future.wait<void>(_pending.toList());
    }
  }

  /// Starts a bin write without putting it on the caller's path.
  ///
  /// By the time this is called the rows are already captured, so the write
  /// touches nothing but the filesystem. Detaching it is what keeps a delete
  /// (and a first sync session's applies) at database speed: the operation must
  /// not wait for a net held under it.
  void _detach(Future<void> Function() write) {
    final pending = write().catchError((Object error, StackTrace stack) {
      debugPrint('recycle: a background write failed: $error');
    });
    _pending.add(pending);
    unawaited(pending.whenComplete(() => _pending.remove(pending)));
  }

  /// A conversation's whole subtree, read in **one** statement.
  ///
  /// SQLite builds the rows as JSON from the same schema-fact column lists the
  /// sync apply writes through, so the statement stays schema-owned instead of
  /// carrying a hand-written column list that can drift from it. One round trip
  /// is the point: this runs inside the deletion's transaction, and every
  /// `await` on that path is a turn the user's delete pays for.
  ///
  /// Returns null when there is no conversation row — nothing this id owns.
  Future<Map<String, List<Map<String, Object?>>>?> _readConversationSubtree(
    String conversationId,
  ) async {
    final projections = <String>[
      for (final entry in _conversationTables)
        "'${entry.table}', (SELECT COALESCE(json_group_array("
            'json_object(${[for (final column in currentSchemaColumns[entry.table]!) "'$column', $column"].join(', ')})), json_array()) '
            'FROM ${entry.table} WHERE ${entry.column} = ?)',
    ];
    final row = await _database
        .customSelect(
          'SELECT json_object(${projections.join(', ')}) AS subtree;',
          variables: <Variable<Object>>[
            for (final _ in _conversationTables)
              Variable<String>(conversationId),
          ],
        )
        .getSingleOrNull();
    if (row == null) return null;
    final Object? decoded;
    try {
      decoded = jsonDecode(row.read<String>('subtree'));
    } on FormatException {
      return null;
    }
    if (decoded is! Map) return null;
    final tables = <String, List<Map<String, Object?>>>{};
    for (final entry in _conversationTables) {
      final value = decoded[entry.table];
      if (value is! List) continue;
      final rows = <Map<String, Object?>>[
        for (final item in value)
          if (item is Map)
            item.map(
              (key, value) => MapEntry(key.toString(), value as Object?),
            ),
      ];
      if (rows.isNotEmpty) tables[entry.table] = rows;
    }
    return tables.containsKey('conversation_rows') ? tables : null;
  }

  /// Every staged entry, newest first, one per recovered identity.
  Future<List<RecycleEntry>> list() => _store.list();

  /// Bytes the bin currently holds.
  Future<int> totalBytes() => _store.totalBytes();

  /// Drops expired entries and evicts oldest-first until the caps hold.
  Future<int> evict() => _store.evict();

  /// Removes one entry for good.
  Future<void> purge(RecycleEntry entry) => _store.purge(entry);

  /// Empties the bin.
  Future<void> clear() => _store.clear();

  /// What one entry holds, for the detail view: the staged tables, or null when
  /// the body is unreadable (or is a moved file, which [bodyFile] serves).
  Future<Map<String, List<Map<String, Object?>>>?> readTables(
    RecycleEntry entry,
  ) => _store.readTables(entry);

  /// The moved file of a workspace-file entry, or null when it is gone.
  Future<File?> bodyFile(RecycleEntry entry) => _store.bodyFile(entry);

  /// Brings one entry back, and retires every entry that staged the same
  /// identity so a recovered row cannot also be recovered twice.
  ///
  /// A restore is a fresh local write: the rows it reinserts are stamped with
  /// the current clock where a clock decides the next comparison. Restoring the
  /// *old* clock would let the very version that won last time win again, and
  /// the recovered content would silently disappear at the next sync session.
  Future<RecycleRestoreOutcome> restore(RecycleEntry entry) async {
    try {
      final RecycleRestoreOutcome outcome;
      switch (entry.type) {
        case RecycleEntryType.conversation:
          outcome = await _restoreConversation(entry);
        case RecycleEntryType.businessEntity:
          outcome = await _restoreEntity(entry);
        case RecycleEntryType.preference:
          outcome = await _restorePreference(entry);
        case RecycleEntryType.workspaceFile:
          // Files are restored by the workspace-file side of sync, which owns
          // the path gates that keep a landed file inside its root.
          outcome = RecycleRestoreOutcome.unsupported;
      }
      if (outcome == RecycleRestoreOutcome.restored) {
        await _store.purgeKey(entry.type, entry.key);
      }
      return outcome;
    } catch (error, stack) {
      debugPrint('recycle: restoring ${entry.id} failed: $error\n$stack');
      return RecycleRestoreOutcome.failed;
    }
  }

  Future<RecycleRestoreOutcome> _restoreConversation(RecycleEntry entry) async {
    final tables = await _store.readTables(entry);
    if (tables == null) return RecycleRestoreOutcome.unreadable;
    final conversationId = entry.key;
    if (_singleRow(tables, 'conversation_rows') == null) {
      return RecycleRestoreOutcome.unreadable;
    }
    return _database.transaction(() async {
      final existing = await _database
          .customSelect(
            'SELECT 1 FROM conversation_rows WHERE id = ?;',
            variables: <Variable<Object>>[Variable<String>(conversationId)],
          )
          .getSingleOrNull();
      if (existing != null) return RecycleRestoreOutcome.skippedExisting;
      final now = DateTime.now().toUtc().microsecondsSinceEpoch;
      await _insertRow(
        'conversation_rows',
        tables['conversation_rows']!.first,
        conflictTarget: const ['id'],
        overrides: <String, Object?>{'updated_at': now},
      );
      for (final row in tables['message_rows'] ?? const []) {
        // A conversation deleted mid-stream leaves a streaming flag behind;
        // restoring it would strand the message with no writer on this device.
        await _insertRow(
          'message_rows',
          row,
          conflictTarget: const ['id'],
          overrides: const <String, Object?>{'is_streaming': 0},
        );
      }
      for (final row in tables['message_part_rows'] ?? const []) {
        // part_id is an autoincrement surrogate that a part inserted since the
        // deletion may already own. A part's real identity is (revision,
        // ordinal), so the surrogate is left to SQLite.
        await _insertRow(
          'message_part_rows',
          row,
          conflictTarget: const ['revision_id', 'ordinal'],
          omit: const <String>{'part_id'},
        );
      }
      for (final row in tables['provider_artifact_rows'] ?? const []) {
        await _insertRow(
          'provider_artifact_rows',
          row,
          conflictTarget: const ['revision_id', 'kind'],
        );
      }
      for (final row in tables['message_prompt_rows'] ?? const []) {
        await _insertRow(
          'message_prompt_rows',
          row,
          conflictTarget: const ['revision_id'],
        );
      }
      final assets = await _existingAssetIds(
        tables['message_asset_rows'] ?? const [],
      );
      for (final row in tables['message_asset_rows'] ?? const []) {
        // Asset rows and files are garbage-collected on their own schedule. A
        // reference whose asset is gone cannot be written back (the foreign key
        // refuses it) and would render as a broken attachment anyway.
        if (!assets.contains(row['asset_id'])) continue;
        await _insertRow(
          'message_asset_rows',
          row,
          conflictTarget: const ['revision_id', 'asset_id', 'kind'],
        );
      }
      for (final row in tables['conversation_mcp_server_rows'] ?? const []) {
        await _insertRow(
          'conversation_mcp_server_rows',
          row,
          conflictTarget: const ['conversation_id', 'server_id'],
        );
      }
      // The tombstone recorded the deletion this restore undoes; leaving it
      // behind would keep announcing a removal for a conversation that is back.
      await _database.customStatement(
        'DELETE FROM tombstone_rows WHERE scope = ? AND entity_id = ?;',
        <Object?>[
          ChatDatabaseRepository.tombstoneScopeConversation,
          conversationId,
        ],
      );
      return RecycleRestoreOutcome.restored;
    });
  }

  Future<RecycleRestoreOutcome> _restoreEntity(RecycleEntry entry) async {
    final kind = _kindForWire(entry.kindWire);
    if (kind == null) return RecycleRestoreOutcome.unsupported;
    final tables = await _store.readTables(entry);
    if (tables == null) return RecycleRestoreOutcome.unreadable;
    final row = _singleRow(tables, kind.tableName);
    if (row == null) return RecycleRestoreOutcome.unreadable;
    final now = DateTime.now().toUtc().microsecondsSinceEpoch;
    await _database.transaction(() async {
      await _insertRow(
        kind.tableName,
        row,
        conflictTarget: kind.extensionKind == null
            ? <String>[kind.idColumn]
            : const <String>['kind', 'id'],
        overrides: <String, Object?>{
          'updated_at': now,
          // An extension kind travels under its own kind value, never another:
          // the table's primary key is (kind, id).
          if (kind.extensionKind != null) 'kind': kind.extensionKind!,
        },
      );
    });
    return RecycleRestoreOutcome.restored;
  }

  Future<RecycleRestoreOutcome> _restorePreference(RecycleEntry entry) async {
    final tables = await _store.readTables(entry);
    if (tables == null) return RecycleRestoreOutcome.unreadable;
    final row = _singleRow(tables, 'preference_rows');
    if (row == null) return RecycleRestoreOutcome.unreadable;
    await _database.customStatement(
      'INSERT INTO preference_rows (key, value, updated_at) VALUES (?, ?, ?) '
      'ON CONFLICT(key) DO UPDATE SET value = excluded.value, '
      'updated_at = excluded.updated_at;',
      <Object?>[
        row['key'],
        row['value'],
        DateTime.now().toUtc().microsecondsSinceEpoch,
      ],
    );
    return RecycleRestoreOutcome.restored;
  }

  Future<List<Map<String, Object?>>> _entityRows(
    BusinessEntityKind kind,
    String id,
  ) async {
    final rows = await _database
        .customSelect(
          'SELECT * FROM ${kind.tableName} WHERE ${kind.idColumn} = ?'
          '${kind.extensionKind == null ? '' : ' AND kind = ?'};',
          variables: <Variable<Object>>[
            Variable<String>(id),
            if (kind.extensionKind != null)
              Variable<String>(kind.extensionKind!),
          ],
        )
        .get();
    return [for (final row in rows) Map<String, Object?>.from(row.data)];
  }

  Future<Set<String>> _existingAssetIds(List<Map<String, Object?>> rows) async {
    final wanted = <String>{
      for (final row in rows)
        if (row['asset_id'] is String) row['asset_id']! as String,
    };
    if (wanted.isEmpty) return const <String>{};
    final placeholders = List.filled(wanted.length, '?').join(', ');
    final found = await _database
        .customSelect(
          'SELECT id FROM asset_rows WHERE id IN ($placeholders);',
          variables: <Variable<Object>>[
            for (final id in wanted) Variable<String>(id),
          ],
        )
        .get();
    return {for (final row in found) row.read<String>('id')};
  }

  /// Writes one snapshot row through the schema-column allowlist — the same
  /// discipline the sync apply uses, so a bin file can never steer SQL. Columns
  /// the row does not carry (a snapshot written by an older build) take their
  /// schema default.
  Future<void> _insertRow(
    String table,
    Map<String, Object?> row, {
    required List<String> conflictTarget,
    Map<String, Object?> overrides = const <String, Object?>{},
    Set<String> omit = const <String>{},
  }) async {
    final allowed = currentSchemaColumns[table];
    if (allowed == null) throw StateError('recycle_unknown_table:$table');
    final effective = <String, Object?>{
      for (final column in allowed)
        if (!omit.contains(column))
          if (overrides.containsKey(column) || row.containsKey(column))
            column: overrides.containsKey(column)
                ? overrides[column]
                : row[column],
    };
    for (final target in conflictTarget) {
      if (!effective.containsKey(target)) {
        throw StateError('recycle_missing_key:$table');
      }
    }
    final updates = <String>[
      for (final column in effective.keys)
        if (!conflictTarget.contains(column)) '$column = excluded.$column',
    ];
    final conflict = conflictTarget.join(', ');
    await _database.customStatement(
      'INSERT INTO $table (${effective.keys.join(', ')}) '
      'VALUES (${List.filled(effective.length, '?').join(', ')}) '
      'ON CONFLICT($conflict) DO '
      '${updates.isEmpty ? 'NOTHING' : 'UPDATE SET ${updates.join(', ')}'};',
      effective.values.toList(growable: false),
    );
  }

  static Map<String, Object?>? _singleRow(
    Map<String, List<Map<String, Object?>>> tables,
    String table,
  ) {
    final rows = tables[table];
    if (rows == null || rows.isEmpty) return null;
    return rows.first;
  }

  /// The wire name behind an entity kind, including kinds this build does not
  /// sync: an entry staged by a build that did sync them stays restorable.
  static BusinessEntityKind? _kindForWire(String? wire) {
    if (wire == null) return null;
    for (final kind in BusinessEntityKind.values) {
      if (kind.wireName == wire) return kind;
    }
    return null;
  }

  /// A label for the bin list, from the row's own payload. Falls back to the id:
  /// the bin has no l10n of its own, and an id is still an honest handle.
  static String _entityTitle(String payload, String id) {
    try {
      final decoded = jsonDecode(payload);
      if (decoded is Map) {
        for (final field in const ['name', 'title', 'label', 'key', 'id']) {
          final value = decoded[field];
          if (value is String && value.trim().isNotEmpty) return value;
        }
      }
    } catch (_) {
      // A payload that does not parse is not a reason to lose the row.
    }
    return id;
  }
}
