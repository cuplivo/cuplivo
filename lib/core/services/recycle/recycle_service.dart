import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart';
import 'package:flutter/foundation.dart';

import '../../database/app_database.dart';
import '../../database/business_data.dart';
import '../../database/chat_database_repository.dart';
import '../../database/composer_draft_store.dart';
import '../../database/schema_columns.dart';
import '../../../utils/app_directories.dart';
import '../sync/workspace_content_index.dart';
import 'recycle_store.dart';

export 'recycle_store.dart';

/// What happened to one restore attempt.
enum RecycleRestoreOutcome {
  /// The rows are back, and the entries that staged them are retired.
  restored,

  /// The entry's identity is present again, so a restore would have to replace
  /// whatever is there now rather than bring something back. For a conversation
  /// that would either merge two histories or overwrite one; for a business row
  /// or a preference the live row is not the version this entry lost to; for a
  /// workspace file the path is occupied. Nothing is written.
  skippedExisting,

  /// The staged body is gone or no longer parses.
  unreadable,

  /// A workspace file whose workspace is gone, so there is no folder to put it
  /// back into. Refused rather than recreated: a directory no `workspace_rows`
  /// row describes is one the app never lists and the next sync round removes
  /// as an orphan, so recreating it would only lose the file a second time.
  workspaceGone,

  /// This build cannot restore that kind of entry.
  unsupported,

  /// The write itself failed; the entry is untouched and can be retried.
  failed,
}

/// What a delete's transaction captured, for
/// [RecycleService.stageCapturedConversation]: the subtree still encoded, plus
/// the two facts the caller decided rather than read.
///
/// A record instead of six parameters, and no store type in it: the capture
/// crosses the transaction boundary, so what travels has to be inert.
typedef RecycleConversationCapture = ({
  String id,
  String subtree,
  RecycleOrigin origin,
  RecycleGroup? group,
});

/// What one per-type restore did, and the entry it staged as a *result*.
///
/// [keepEntryId] is the version a restore displaced: an `overwritten` row the
/// restore put back replaces the live row, and the live row goes into the bin so
/// the act stays reversible. It is the one entry the retire step must not delete
/// — the restore produced it, it is not one of the entries the restore retired.
typedef _RestoreResult = ({RecycleRestoreOutcome outcome, String? keepEntryId});

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
  RecycleService(
    this._database, {
    RecycleStore? store,
    Future<Directory> Function(String workspaceId)? workspaceRoot,
  }) : _store = store ?? RecycleStore(),
       // ignore: prefer_initializing_formals
       _workspaceRoot = workspaceRoot;

  /// Where one managed workspace's files live, or null when this build has no
  /// workspace content plane wired.
  ///
  /// Injected for the reason the sync side injects it — a test hosts both peers
  /// in one process — and so this service never learns how the app lays its data
  /// directory out. Null makes a file restore [unsupported] rather than guessing
  /// a path.
  final Future<Directory> Function(String workspaceId)? _workspaceRoot;

  /// Tables a conversation snapshot recovers, each with the column that ties its
  /// rows to the conversation — and, for a table that hosts more than one kind
  /// of row, the `kind` that picks this conversation's own.
  ///
  /// This list is the whole of a conversation snapshot: a table that is not here
  /// is not recovered. It is deliberately **not** an exhaustive map of what a
  /// delete removes: `generation_run_rows` goes with the messages it targets and
  /// is not staged, because a run is bookkeeping for a stream that is happening
  /// now rather than history a user could want back (ADR-0016, "Not in scope").
  static const List<({String table, String column, String? kind})>
  _conversationTables = [
    (table: 'conversation_rows', column: 'id', kind: null),
    (
      table: 'conversation_mcp_server_rows',
      column: 'conversation_id',
      kind: null,
    ),
    (table: 'message_rows', column: 'conversation_id', kind: null),
    (table: 'message_part_rows', column: 'conversation_id', kind: null),
    (table: 'provider_artifact_rows', column: 'conversation_id', kind: null),
    (table: 'message_prompt_rows', column: 'conversation_id', kind: null),
    (table: 'message_asset_rows', column: 'conversation_id', kind: null),
    // The composer draft is one device-local row keyed by the conversation id,
    // removed by the same delete: it is text the user typed and never sent, so
    // losing it is losing part of the conversation they deleted by accident. It
    // is the only extension row a conversation owns, and the kind is named
    // rather than implied — the id column alone would sweep up any future
    // device-local row keyed the same way.
    (
      table: 'extension_entity_rows',
      column: 'id',
      kind: ComposerDraftStore.kind,
    ),
  ];

  final AppDatabase _database;
  final RecycleStore _store;
  final Set<Future<void>> _pending = <Future<void>>{};

  /// Reads the whole subtree of a conversation that is about to be deleted,
  /// still encoded, for [stageCapturedConversation].
  ///
  /// Called from inside the delete's transaction, before the row goes, so what
  /// is captured is what the cascade is about to remove — that is the whole
  /// reason the query cannot be moved out. It is also the *only* part that has
  /// to be there: this method awaits one statement and returns a string, and the
  /// caller stages it after the transaction returns. Decoding its JSON into row
  /// maps and encoding the bin entry are work proportional to the conversation
  /// (measured at ~11 ms/MB), so neither belongs on a path the user is waiting
  /// on with a write transaction open.
  ///
  /// Null when the id owns no conversation row: there is nothing to preserve.
  Future<RecycleConversationCapture?> captureConversationDeletion(
    String conversationId, {
    required RecycleOrigin origin,
    RecycleGroup? group,
  }) async {
    if (conversationId.isEmpty) return null;
    try {
      final subtree = await _readConversationSubtree(conversationId);
      if (subtree == null) return null;
      return (
        id: conversationId,
        subtree: subtree,
        origin: origin,
        group: group,
      );
    } catch (error) {
      debugPrint(
        'recycle: capturing conversation $conversationId failed: $error',
      );
      return null;
    }
  }

  /// Stages a capture [captureConversationDeletion] took inside the delete's
  /// transaction.
  ///
  /// The caller runs this *after* that transaction has committed, and the write
  /// is [detached][_detach] on top of that, so neither the decode nor the
  /// encode nor the filesystem is on the delete's path. The pair is one
  /// operation in two halves; the delete funnel
  /// (`ChatDatabaseRepository.deleteConversation`) is its only caller, which is
  /// what keeps the halves together.
  void stageCapturedConversation(RecycleConversationCapture capture) {
    _detach(() async {
      final tables = _decodeConversationSubtree(capture.subtree);
      // No conversation row means there is nothing this id owns to preserve.
      if (tables == null) return;
      final title = tables['conversation_rows']!.first['title'];
      await _store.stageRows(
        type: RecycleEntryType.conversation,
        origin: capture.origin,
        reason: RecycleReason.deleted,
        key: capture.id,
        title: title is String ? title : '',
        tables: tables,
        group: capture.group,
      );
    });
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

  /// Stages one workspace file a sync round is about to replace or remove.
  ///
  /// Awaited, unlike the row paths, and for a mechanical reason rather than a
  /// stylistic one: staging a file *moves* it out of the workspace, so the
  /// caller's own rename or delete cannot proceed until the old version is
  /// safely on the bin's side. Null means the move failed — an unwritable bin,
  /// a described-but-unreadable file — which is the caller's cue to fall back to
  /// its ordinary delete instead of assuming the file is preserved.
  Future<RecycleEntry?> stageWorkspaceFile({
    required String workspaceId,
    required String relPath,
    required File source,
    required RecycleOrigin origin,
    required RecycleReason reason,
  }) async {
    final staged = await _stageWorkspaceFile(
      workspaceId: workspaceId,
      relPath: relPath,
      source: source,
      origin: origin,
      reason: reason,
    );
    // This path is awaited rather than detached, so nothing else will notice
    // that the burst ended, and the caller is already paying for a file move:
    // one scan for the whole burst is the price of the caps holding.
    await _sweepWhenSettled();
    return staged;
  }

  /// The move alone: no sweep, and a failure turned into null.
  ///
  /// Split out for the one caller that has to write something *after* the move
  /// and before the sweep — a restore, whose own entry the sweep may evict.
  Future<RecycleEntry?> _stageWorkspaceFile({
    required String workspaceId,
    required String relPath,
    required File source,
    required RecycleOrigin origin,
    required RecycleReason reason,
  }) async {
    if (workspaceId.isEmpty || relPath.isEmpty) return null;
    try {
      return await _store.stageFile(
        workspaceId: workspaceId,
        relPath: relPath,
        source: source,
        origin: origin,
        reason: reason,
        title: relPath,
      );
    } catch (error) {
      debugPrint(
        'recycle: staging the workspace file "$relPath" failed: $error',
      );
      return null;
    }
  }

  /// Waits for every bin write this service has started, and for the sweep those
  /// writes scheduled.
  ///
  /// Production never needs this — the writes are the bin's own business — but
  /// a test that asserts what the bin holds after an operation has to let that
  /// operation's net finish first. The sweep is part of the net: staging
  /// coalesces eviction instead of running it per entry, so a test that asserts
  /// the caps would otherwise read a bin that has not been swept yet.
  @visibleForTesting
  Future<void> settle() async {
    while (_pending.isNotEmpty || _sweeping != null) {
      await Future.wait<void>([
        ..._pending,
        if (_sweeping case final sweep?) sweep,
      ]);
    }
    await _store.settle();
  }

  /// Starts a bin write on the next event-loop turn, off the caller's stack.
  ///
  /// By the time this is called the rows are already captured, so the write
  /// touches nothing but the filesystem. Two things have to be true for a
  /// delete (or a first sync session's applies) to stay at database speed: the
  /// work must not be on the caller's path, and it must not hold the caller's
  /// transaction open. Invoking [write] here would do both — an `async` body
  /// runs synchronously up to its first `await`, and this closure's first
  /// statement is a `jsonDecode` proportional to the conversation — so the
  /// closure is scheduled instead of called, and it starts only after the
  /// caller's own turn (transaction included) has finished.
  void _detach(Future<void> Function() write) {
    final pending = Future<void>.delayed(Duration.zero, write).catchError((
      Object error,
      StackTrace stack,
    ) {
      debugPrint('recycle: a background write failed: $error');
    });
    _pending.add(pending);
    unawaited(
      pending.whenComplete(() {
        _pending.remove(pending);
        unawaited(_sweepWhenSettled());
      }),
    );
  }

  /// The sweep with the filesystem right now, so [settle] can wait for it.
  Future<void>? _sweeping;

  /// Runs the sweep staging asked for once the burst's last write has landed.
  ///
  /// A burst is what the service knows about: an assistant's cascade launches one
  /// write per conversation, so the bin's eviction waits for the last of them
  /// instead of scanning the whole bin once per entry. A single staged entry is a
  /// burst of one, and sweeps immediately.
  Future<void> _sweepWhenSettled() {
    if (_pending.isNotEmpty) return Future<void>.value(); // still writing
    final sweep = _store.sweepIfPending().whenComplete(() {
      _sweeping = null;
    });
    _sweeping = sweep;
    return sweep;
  }

  /// A conversation's whole subtree, read in **one** statement.
  ///
  /// SQLite builds the rows as JSON from the same schema-fact column lists the
  /// sync apply writes through, so the statement stays schema-owned instead of
  /// carrying a hand-written column list that can drift from it. One round trip
  /// is the point: this runs inside the deletion's transaction, and every
  /// `await` on that path is a turn the user's delete pays for.
  ///
  /// Returns the JSON as SQLite built it, still encoded:
  /// [_decodeConversationSubtree] turns it into row maps *outside* that
  /// transaction. Decoding used to happen here, which put work proportional to
  /// the whole conversation — a few tens of a millisecond per megabyte, measured
  /// — on the delete's own path.
  Future<String?> _readConversationSubtree(String conversationId) async {
    final projections = <String>[
      for (final entry in _conversationTables)
        "'${entry.table}', (SELECT COALESCE(json_group_array("
            'json_object(${[for (final column in currentSchemaColumns[entry.table]!) "'$column', $column"].join(', ')})), json_array()) '
            'FROM ${entry.table} WHERE ${entry.column} = ?'
            '${entry.kind == null ? '' : ' AND kind = ?'})',
    ];
    final row = await _database
        .customSelect(
          'SELECT json_object(${projections.join(', ')}) AS subtree;',
          variables: <Variable<Object>>[
            for (final entry in _conversationTables) ...[
              Variable<String>(conversationId),
              if (entry.kind case final kind?) Variable<String>(kind),
            ],
          ],
        )
        .getSingleOrNull();
    return row?.read<String>('subtree');
  }

  /// The staged tables of one captured subtree, or null when the capture holds
  /// no conversation row (nothing this id owns) or no longer parses.
  Map<String, List<Map<String, Object?>>>? _decodeConversationSubtree(
    String subtree,
  ) {
    final Object? decoded;
    try {
      decoded = jsonDecode(subtree);
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
  ///
  /// What a restore finds alive decides what it may do, and the two cases come
  /// from what the entry records rather than from a preference: an entry staged
  /// by a *deletion* is refused when its identity is back (the live row is not
  /// the version this entry lost to, so replacing it would discard content
  /// nothing asked to replace), while an entry staged by a *losing last-write-wins
  /// comparison* exists only to replace the live row and cannot be refused
  /// without making itself unrecoverable — restoring it puts the live version
  /// into the bin, so the act can be undone in turn.
  Future<RecycleRestoreOutcome> restore(RecycleEntry entry) async {
    try {
      final (:outcome, :keepEntryId) = switch (entry.type) {
        RecycleEntryType.conversation => await _restoreConversation(entry),
        RecycleEntryType.businessEntity => await _restoreEntity(entry),
        RecycleEntryType.preference => await _restorePreference(entry),
        RecycleEntryType.workspaceFile => await _restoreWorkspaceFile(entry),
      };
      if (outcome == RecycleRestoreOutcome.restored) {
        await _store.purgeKey(entry.type, entry.key, exceptId: keepEntryId);
      }
      return outcome;
    } catch (error, stack) {
      debugPrint('recycle: restoring ${entry.id} failed: $error\n$stack');
      return RecycleRestoreOutcome.failed;
    }
  }

  Future<_RestoreResult> _restoreConversation(RecycleEntry entry) async {
    final tables = await _store.readTables(entry);
    if (tables == null) return _not(RecycleRestoreOutcome.unreadable);
    final conversationId = entry.key;
    if (_singleRow(tables, 'conversation_rows') == null) {
      return _not(RecycleRestoreOutcome.unreadable);
    }
    return _database.transaction(() async {
      final existing = await _database
          .customSelect(
            'SELECT 1 FROM conversation_rows WHERE id = ?;',
            variables: <Variable<Object>>[Variable<String>(conversationId)],
          )
          .getSingleOrNull();
      if (existing != null) return _not(RecycleRestoreOutcome.skippedExisting);
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
      final drafts = tables['extension_entity_rows'] ?? const [];
      if (drafts.isNotEmpty && !await _hasDraft(conversationId)) {
        // A draft that came back on its own wins: the composer is state the user
        // is in the middle of, and replacing what they have typed would be a
        // worse surprise than an older unsent message staying lost.
        for (final row in drafts) {
          await _insertRow(
            'extension_entity_rows',
            await _pruneDraftPaths(row),
            conflictTarget: const ['kind', 'id'],
          );
        }
      }
      // The local tombstone recorded the deletion this restore undoes, so it goes
      // with it. It is bookkeeping, not a signal: nothing on the sync path reads
      // tombstones — an announced deletion is derived from the checkpoint
      // (ADR-0003, protocol v8) — so removing the row is not what keeps the
      // conversation from being announced again. The restored row's clock is.
      await _database.customStatement(
        'DELETE FROM tombstone_rows WHERE scope = ? AND entity_id = ?;',
        <Object?>[
          ChatDatabaseRepository.tombstoneScopeConversation,
          conversationId,
        ],
      );
      return _not(RecycleRestoreOutcome.restored);
    });
  }

  Future<_RestoreResult> _restoreEntity(RecycleEntry entry) async {
    final kind = _kindForWire(entry.kindWire);
    if (kind == null) return _not(RecycleRestoreOutcome.unsupported);
    final tables = await _store.readTables(entry);
    if (tables == null) return _not(RecycleRestoreOutcome.unreadable);
    final row = _singleRow(tables, kind.tableName);
    if (row == null) return _not(RecycleRestoreOutcome.unreadable);
    final now = DateTime.now().toUtc().microsecondsSinceEpoch;
    final live = <Map<String, Object?>>[];
    final skipped = await _database.transaction(() async {
      live.addAll(await _entityRows(kind, entry.key));
      // A row a *deletion* staged that exists again is not this entry's to
      // replace: nothing here is the version it lost to, so writing over it
      // would discard whatever is there now. The same refusal a conversation and
      // a workspace file get. A row a *losing comparison* staged is the other
      // case, and the only one where the live row is exactly what this entry
      // has to replace.
      if (live.isNotEmpty && entry.reason == RecycleReason.deleted) return true;
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
      return false;
    });
    if (skipped) return _not(RecycleRestoreOutcome.skippedExisting);
    if (live.isEmpty || live.first['payload'] == row['payload']) {
      // Nothing was displaced: a restore that wrote what was already there owes
      // the bin no second entry.
      return _not(RecycleRestoreOutcome.restored);
    }
    final displaced = live.first;
    final payload = displaced['payload'];
    final staged = await _store.stageRows(
      type: RecycleEntryType.businessEntity,
      origin: RecycleOrigin.local,
      reason: RecycleReason.overwritten,
      key: entry.key,
      title: payload is String ? _entityTitle(payload, entry.key) : entry.key,
      kindWire: kind.wireName,
      tables: {
        kind.tableName: [displaced],
      },
    );
    return (outcome: RecycleRestoreOutcome.restored, keepEntryId: staged?.id);
  }

  Future<_RestoreResult> _restorePreference(RecycleEntry entry) async {
    final tables = await _store.readTables(entry);
    if (tables == null) return _not(RecycleRestoreOutcome.unreadable);
    final row = _singleRow(tables, 'preference_rows');
    if (row == null) return _not(RecycleRestoreOutcome.unreadable);
    final live = <Map<String, Object?>>[];
    final skipped = await _database.transaction(() async {
      final existing = await _database
          .customSelect(
            'SELECT * FROM preference_rows WHERE key = ?;',
            variables: <Variable<Object>>[Variable<String>(entry.key)],
          )
          .getSingleOrNull();
      if (existing != null) live.add(Map<String, Object?>.from(existing.data));
      // Same rule as [_restoreEntity]: a deleted row that is back is left alone.
      if (live.isNotEmpty && entry.reason == RecycleReason.deleted) return true;
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
      return false;
    });
    if (skipped) return _not(RecycleRestoreOutcome.skippedExisting);
    if (live.isEmpty || live.first['value'] == row['value']) {
      return _not(RecycleRestoreOutcome.restored);
    }
    final staged = await _store.stageRows(
      type: RecycleEntryType.preference,
      origin: RecycleOrigin.local,
      reason: RecycleReason.overwritten,
      key: entry.key,
      title: entry.title,
      tables: {
        'preference_rows': [live.first],
      },
    );
    return (outcome: RecycleRestoreOutcome.restored, keepEntryId: staged?.id);
  }

  /// Puts one staged workspace file back inside its workspace.
  ///
  /// The same four gates a sync landing goes through, and the same functions —
  /// a restore is a file arriving at a path that came from the wire just as much
  /// as a fetch is, so two containment rules here would be one too many. What
  /// differs is the stamp: a restore is a *fresh local write*, so the mtime is
  /// the current clock. Keeping the staged (older) one would hand the file back
  /// to the very comparison that removed it, and the peer's next plan would
  /// delete it again.
  ///
  /// What it finds at the path decides what it may do, and [RecycleEntry.reason]
  /// says which case it is — decision 5's split, for a file. An entry staged by
  /// a *deletion* is refused when the path is occupied again: the file there is
  /// one this entry never lost to. An entry staged by a *losing comparison* is
  /// the one case that must overwrite, because the landing path is occupied by
  /// construction — the merge moved the old version out and then renamed the
  /// new one in — so refusing it would make the entry permanently
  /// unrestorable. The live version goes into the bin first, which is what makes
  /// the restore undoable in turn.
  Future<_RestoreResult> _restoreWorkspaceFile(RecycleEntry entry) async {
    final resolver = _workspaceRoot;
    final workspaceId = entry.workspaceId;
    final relPath = entry.relPath;
    if (resolver == null || workspaceId == null || relPath == null) {
      return _not(RecycleRestoreOutcome.unsupported);
    }
    if (!isSafeWorkspaceId(workspaceId)) {
      return _not(RecycleRestoreOutcome.unsupported);
    }
    // The row is what owns the folder. A file put back into a folder no row
    // describes is one the app never lists, and the next sync round removes it
    // as an orphan — restoring it would lose it again, more quietly. Asked
    // through [_entityRows] rather than by name, so the workspace kind's own
    // table and its extension filter are the one place they already are.
    if ((await _entityRows(
      BusinessEntityKind.workspace,
      workspaceId,
    )).isEmpty) {
      return _not(RecycleRestoreOutcome.workspaceGone);
    }
    final root = await resolver(workspaceId);
    final target = workspacePathWithin(root.path, relPath);
    if (target == null) return _not(RecycleRestoreOutcome.unsupported);
    final file = File(target);
    final source = await _store.bodyFile(entry);
    if (source == null) return _not(RecycleRestoreOutcome.unreadable);
    // Asked *before* the directory is created: `create(recursive: true)` follows
    // the symlinks of the ancestors it finds, so a directory in the tree that
    // points outside the workspace would otherwise already have redirected the
    // write by the time anything was checked.
    final existing = await nearestExistingAncestor(file.parent);
    if (!await isReallyInsideWorkspace(root, existing)) {
      return _not(RecycleRestoreOutcome.unsupported);
    }
    String? keepEntryId;
    if (await file.exists()) {
      if (entry.reason == RecycleReason.deleted) {
        return _not(RecycleRestoreOutcome.skippedExisting);
      }
      // Moved, not copied, and before a byte is written: the version at the path
      // is the only copy of itself, so a bin that cannot take it stops the
      // restore instead of being written over. The move is also what frees the
      // path.
      final displaced = await _stageWorkspaceFile(
        workspaceId: workspaceId,
        relPath: relPath,
        source: file,
        origin: RecycleOrigin.local,
        reason: RecycleReason.overwritten,
      );
      if (displaced == null) return _not(RecycleRestoreOutcome.failed);
      keepEntryId = displaced.id;
    }
    await file.parent.create(recursive: true);
    await source.copy(target);
    await file.setLastModified(DateTime.now());
    // After the bytes are back, not inside the staging: this sweep is what could
    // evict the very entry being restored, and it no longer has to be waited for
    // here — the caps hold a moment later either way.
    await _sweepWhenSettled();
    return (outcome: RecycleRestoreOutcome.restored, keepEntryId: keepEntryId);
  }

  /// Whether the conversation already has a composer draft, so a restore leaves
  /// it alone.
  Future<bool> _hasDraft(String conversationId) async {
    final row = await _database
        .customSelect(
          'SELECT 1 FROM extension_entity_rows WHERE kind = ? AND id = ?;',
          variables: <Variable<Object>>[
            const Variable<String>(ComposerDraftStore.kind),
            Variable<String>(conversationId),
          ],
        )
        .getSingleOrNull();
    return row != null;
  }

  /// One staged draft row with the attachment paths that still resolve.
  ///
  /// A conversation's delete empties the draft's private attachment directory on
  /// its way out, so the files behind `images` and `documents` are gone by the
  /// time anything is restored: a chip pointing at one would come back as a
  /// broken attachment. The row is otherwise written exactly as staged — the
  /// text, the selection, the citation — and a row with nothing to drop comes
  /// back untouched.
  Future<Map<String, Object?>> _pruneDraftPaths(
    Map<String, Object?> row,
  ) async {
    final payload = row['payload'];
    if (payload is! String) return row;
    final Object? decoded;
    try {
      decoded = jsonDecode(payload);
    } on FormatException {
      return row;
    }
    if (decoded is! Map) return row;
    var dropped = false;
    for (final mode in const ['compose', 'edit', 'pending']) {
      final input = decoded[mode];
      if (input is! Map) continue;
      for (final field in const ['images', 'documents']) {
        final items = input[field];
        if (items is! List) continue;
        final kept = <Object?>[];
        for (final item in items) {
          final path = item is Map ? item['path'] : null;
          if (path is! String || await _fileExists(path)) {
            kept.add(item);
          } else {
            dropped = true;
          }
        }
        if (kept.length != items.length) input[field] = kept;
      }
    }
    return dropped ? {...row, 'payload': jsonEncode(decoded)} : row;
  }

  static Future<bool> _fileExists(String path) async {
    try {
      return await File(path).exists();
    } catch (_) {
      // A path the filesystem refuses to even be asked about is one this restore
      // cannot point at.
      return false;
    }
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

  /// A result that staged nothing: the restore refused, or wrote over content
  /// that was not there to displace.
  static _RestoreResult _not(RecycleRestoreOutcome outcome) =>
      (outcome: outcome, keepEntryId: null);

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
