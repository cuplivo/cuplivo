import 'dart:io';

import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:flutter/foundation.dart' show debugPrint;

import '../../utils/app_directories.dart';

part 'app_database.g.dart';

@TableIndex(name: 'idx_conversations_updated_at', columns: {#updatedAt})
@TableIndex(name: 'idx_conversations_assistant', columns: {#assistantId})
class ConversationRows extends Table {
  TextColumn get id => text()();
  TextColumn get title => text()();
  DateTimeColumn get createdAt => dateTime()();
  DateTimeColumn get updatedAt => dateTime()();
  BoolColumn get isPinned => boolean().withDefault(const Constant(false))();
  TextColumn get assistantId => text().nullable()();
  IntColumn get truncateIndex => integer().withDefault(const Constant(-1))();
  TextColumn get versionSelectionsJson =>
      text().withDefault(const Constant('{}'))();
  TextColumn get summary => text().nullable()();
  IntColumn get lastSummarizedMessageCount =>
      integer().withDefault(const Constant(0))();
  TextColumn get chatSuggestionsJson =>
      text().withDefault(const Constant('[]'))();
  TextColumn get parentConversationId => text().nullable()();

  /// 'normal' | 'group' — group public transcripts use kind=group.
  TextColumn get conversationKind =>
      text().withDefault(const Constant('normal'))();

  @override
  Set<Column<Object>> get primaryKey => {id};
}

@TableIndex(
  name: 'idx_messages_conversation_order',
  columns: {#conversationId, #messageOrder},
)
@TableIndex(
  name: 'idx_messages_conversation_timestamp',
  columns: {#conversationId, #timestamp},
)
@TableIndex(name: 'idx_messages_group', columns: {#groupId})
@TableIndex(name: 'idx_messages_subgroup', columns: {#subgroupId})
class MessageRows extends Table {
  TextColumn get id => text()();
  TextColumn get conversationId =>
      text().references(ConversationRows, #id, onDelete: KeyAction.cascade)();
  TextColumn get role => text()();
  TextColumn get content => text()();
  DateTimeColumn get timestamp => dateTime()();
  TextColumn get modelId => text().nullable()();
  TextColumn get providerId => text().nullable()();
  IntColumn get totalTokens => integer().nullable()();
  BoolColumn get isStreaming => boolean().withDefault(const Constant(false))();
  TextColumn get reasoningText => text().nullable()();
  DateTimeColumn get reasoningStartAt => dateTime().nullable()();
  DateTimeColumn get reasoningFinishedAt => dateTime().nullable()();
  TextColumn get translation => text().nullable()();
  TextColumn get reasoningSegmentsJson => text().nullable()();
  TextColumn get groupId => text().nullable()();
  TextColumn get subgroupId => text().nullable()();
  IntColumn get version => integer().withDefault(const Constant(0))();
  IntColumn get promptTokens => integer().nullable()();
  IntColumn get completionTokens => integer().nullable()();
  IntColumn get cachedTokens => integer().nullable()();
  IntColumn get durationMs => integer().nullable()();
  IntColumn get messageOrder => integer()();
  BoolColumn get isPreset => boolean().withDefault(const Constant(false))();

  /// Speaker assistant id for group chats; null for user messages / 1:1.
  TextColumn get speakerAssistantId => text().nullable()();

  @override
  Set<Column<Object>> get primaryKey => {id};
}

class AssistantRows extends Table {
  //--- Identifier & Display ---
  TextColumn get id => text()();
  TextColumn get name => text()();
  TextColumn get avatar => text().nullable()();
  BoolColumn get useAssistantAvatar =>
      boolean().withDefault(const Constant(false))();
  BoolColumn get useAssistantName =>
      boolean().withDefault(const Constant(false))();
  TextColumn get background => text().nullable()();

  // --- Model Selection ---
  TextColumn get chatModelProvider => text().nullable()();
  TextColumn get chatModelId => text().nullable()();

  // --- Request Params ---
  RealColumn get temperature => real().nullable()();
  RealColumn get topP => real().nullable()();
  IntColumn get contextMessageSize =>
      integer().withDefault(const Constant(64))();
  BoolColumn get limitContextMessages =>
      boolean().withDefault(const Constant(true))();
  BoolColumn get streamOutput => boolean().withDefault(const Constant(true))();
  IntColumn get thinkingBudget => integer().nullable()();
  IntColumn get maxTokens => integer().nullable()();
  TextColumn get customHeadersJson =>
      text().withDefault(const Constant('[]'))();
  TextColumn get customBodyJson => text().withDefault(const Constant('[]'))();

  // --- Messages ---
  TextColumn get systemPrompt => text().withDefault(const Constant(''))();
  TextColumn get messageTemplate =>
      text().withDefault(const Constant('{{ message }}'))();
  TextColumn get presetMessagesJson =>
      text().withDefault(const Constant('[]'))();

  // --- Extended Functionality ---
  BoolColumn get searchEnabled =>
      boolean().withDefault(const Constant(false))();
  TextColumn get mcpServerIdsJson => text().withDefault(const Constant('[]'))();
  TextColumn get localToolIdsJson => text().withDefault(const Constant('[]'))();
  TextColumn get skillIdsJson => text().withDefault(const Constant('[]'))();
  TextColumn get regexRulesJson => text().withDefault(const Constant('[]'))();

  // --- Proactive Care ("Ta的来信") ---
  BoolColumn get enableProactiveCare =>
      boolean().withDefault(const Constant(false))();
  DateTimeColumn get proactiveCareNextMessageAt => dateTime().nullable()();
  TextColumn get proactiveCarePrompt =>
      text().withDefault(const Constant(''))();
  TextColumn get proactiveCareDecisionPrompt =>
      text().withDefault(const Constant(''))();

  // --- Memory ---
  BoolColumn get enableMemory => boolean().withDefault(const Constant(false))();
  TextColumn get memoryMode =>
      text().withDefault(const Constant('injection'))();
  BoolColumn get enableRecentChatsReference =>
      boolean().withDefault(const Constant(false))();
  IntColumn get recentChatsSummaryMessageCount =>
      integer().withDefault(const Constant(5))();
  TextColumn get memoryRecordPrompt => text().withDefault(const Constant(''))();

  // --- File Processing ---
  TextColumn get docxMode => text().withDefault(const Constant('extract'))();
  TextColumn get pdfMode => text().withDefault(const Constant('extract'))();
  TextColumn get otherOfficeMode =>
      text().withDefault(const Constant('direct'))();
  // OCR processing mode: 'auto' | 'always' | 'never'
  TextColumn get ocrMode => text().withDefault(const Constant('auto'))();

  // --- Time Injection ---
  BoolColumn get enableTimeInjection =>
      boolean().withDefault(const Constant(false))();

  // --- Handoff / Delegation ---
  BoolColumn get discoverable => boolean().withDefault(const Constant(false))();
  TextColumn get handoffId => text().nullable()();
  TextColumn get handoffDescription => text().nullable()();

  // --- Sort & Timestamp ---
  IntColumn get sortOrder => integer()();
  DateTimeColumn get createdAt => dateTime()();
  DateTimeColumn get updatedAt => dateTime()();

  @override
  Set<Column<Object>> get primaryKey => {id};
}

class ConversationMcpServerRows extends Table {
  TextColumn get conversationId =>
      text().references(ConversationRows, #id, onDelete: KeyAction.cascade)();
  TextColumn get serverId => text()();
  IntColumn get ordinal => integer()();

  @override
  Set<Column<Object>> get primaryKey => {conversationId, serverId};
}

class ToolEventRows extends Table {
  TextColumn get messageId =>
      text().references(MessageRows, #id, onDelete: KeyAction.cascade)();
  TextColumn get eventsJson => text()();

  @override
  Set<Column<Object>> get primaryKey => {messageId};
}

class GeminiThoughtSignatureRows extends Table {
  TextColumn get messageId =>
      text().references(MessageRows, #id, onDelete: KeyAction.cascade)();
  TextColumn get signature => text()();

  @override
  Set<Column<Object>> get primaryKey => {messageId};
}

class CacheRows extends Table {
  TextColumn get type => text()(); // e.g., 'ocr'
  TextColumn get key => text()();
  TextColumn get value => text()();
  DateTimeColumn get updatedAt => dateTime()();

  @override
  Set<Column<Object>> get primaryKey => {type, key};
}

class ChatStorageMetaRows extends Table {
  TextColumn get key => text()();
  TextColumn get value => text()();

  @override
  Set<Column<Object>> get primaryKey => {key};
}

/// Recoverable payloads for locally-deleted entities.
///
/// Each row = one top-level entity bundle. For a conversation, the bundle
/// nests its messages + toolEvents + geminiSigs + MCP server links. For a
/// message, the bundle nests its toolEvents/sigs.
///
/// NOT backed up — excluded structurally (backup export never queries this
/// table). Subject to a user-configurable byte cap (default 10 MB); oldest
/// rows are evicted when over cap, never the current write batch.
class DeletedRecordRows extends Table {
  TextColumn get id => text()();
  TextColumn get type =>
      text()(); // conversation|message|assistant|worldBook|quickPhrase|mcpServer|memory
  TextColumn get recoveryJson => text()();
  IntColumn get size => integer()(); // bytes(utf8(recoveryJson)) + 256
  DateTimeColumn get createdAt => dateTime()(); // deletion time
  TextColumn get batchId =>
      text()(); // shared by rows from the same delete operation

  @override
  Set<Column<Object>> get primaryKey => {id, type};
}

/// Id-only tombstones for sync/backup, with no payload.
///
/// `origin='local'` rows are written on every local delete (dual-write with
/// [DeletedRecordRows]) and are the source of `deleted.json`. `origin='remote'`
/// rows are written when a sync peer or backup's `deleted.json` declares an id
/// that still exists locally; the UI marks these as "远端已删除".
///
/// Unified 5000-row FIFO by [deletedAt], regardless of origin. The `origin`
/// column prevents sync echo: `deleted.json` is generated from
/// `origin='local'` rows only.
class DeletionMarkerRows extends Table {
  TextColumn get id => text()();
  TextColumn get type => text()();
  TextColumn get origin => text()(); // 'local' | 'remote'
  DateTimeColumn get deletedAt => dateTime()();

  @override
  Set<Column<Object>> get primaryKey => {id, type, origin};
}

// ===== Multi-assistant group chat (schema v13) =====
// Layered model: the public transcript lives in ConversationRows
// (conversation_kind='group') + MessageRows.speakerAssistantId; GroupChatRows
// holds metadata + per-round runtime state; GroupChatMemberRows is the M:N
// membership join (same shape as ConversationMcpServerRows). The Director
// session is ephemeral — rebuilt from the public transcript on every call,
// never persisted (the v13 `director_message_rows` table was dropped in v14).
// See docs/adr/0015 and CONTEXT.md.
// Sync rule: any new group-related table must be wired into clearAllData
// (child-before-parent FK order), _exportChatsToFile and _restoreFromBackupFile
// in the same change.
@TableIndex(name: 'idx_group_chats_updated_at', columns: {#updatedAt})
class GroupChatRows extends Table {
  TextColumn get id => text()();
  TextColumn get name => text()();
  TextColumn get avatar => text().nullable()();
  TextColumn get conversationId => text().unique().references(
    ConversationRows,
    #id,
    onDelete: KeyAction.cascade,
  )();
  TextColumn get directorModelProvider => text().nullable()();
  TextColumn get directorModelId => text().nullable()();
  TextColumn get directorSystemPrompt =>
      text().withDefault(const Constant(''))();
  IntColumn get maxAssistantMessagesPerRound =>
      integer().withDefault(const Constant(3))();
  TextColumn get assistantDetailInjectionMode =>
      text().withDefault(const Constant('endOfEveryUserMessage'))();
  IntColumn get assistantDetailInjectionN =>
      integer().withDefault(const Constant(5))();
  BoolColumn get injectGroupMembersIntoAssistantSystemPrompt =>
      boolean().withDefault(const Constant(true))();
  TextColumn get pendingCapAssistantMessageId => text().nullable()();
  IntColumn get assistantMessagesThisRound =>
      integer().withDefault(const Constant(0))();
  DateTimeColumn get createdAt => dateTime()();
  DateTimeColumn get updatedAt => dateTime()();

  @override
  Set<Column<Object>> get primaryKey => {id};
}

class GroupChatMemberRows extends Table {
  TextColumn get groupChatId =>
      text().references(GroupChatRows, #id, onDelete: KeyAction.cascade)();
  TextColumn get memberKey => text()();
  TextColumn get assistantId => text().nullable()();
  IntColumn get sortOrder => integer()();

  @override
  Set<Column<Object>> get primaryKey => {groupChatId, memberKey};
}

@DriftDatabase(
  tables: [
    ConversationRows,
    MessageRows,
    AssistantRows,
    ConversationMcpServerRows,
    ToolEventRows,
    GeminiThoughtSignatureRows,
    CacheRows,
    ChatStorageMetaRows,
    DeletedRecordRows,
    DeletionMarkerRows,
    GroupChatRows,
    GroupChatMemberRows,
  ],
)
class AppDatabase extends _$AppDatabase {
  AppDatabase(super.executor);

  static const databaseFileName = 'kelivo.sqlite';

  factory AppDatabase.open({File? file}) {
    final databaseFile = file;
    if (databaseFile != null) {
      return AppDatabase(_openExecutor(databaseFile));
    }
    return AppDatabase(
      LazyDatabase(() async {
        final dir = await AppDirectories.getAppDataDirectory();
        if (!await dir.exists()) {
          await dir.create(recursive: true);
        }
        return _openExecutor(File('${dir.path}/$databaseFileName'));
      }),
    );
  }

  static QueryExecutor _openExecutor(File file) {
    return NativeDatabase.createInBackground(
      file,
      setup: (database) {
        database.execute('PRAGMA journal_mode = WAL;');
        database.execute('PRAGMA foreign_keys = ON;');
        database.execute('PRAGMA busy_timeout = 5000;');
      },
      readPool: 1,
    );
  }

  @override
  // Migrations follow the original per-version pattern. Individual addColumn /
  // createTable steps are wrapped in silent try/catch for idempotent replay,
  // so a genuinely failed ALTER can leave user_version advanced while the
  // column stays missing (real incidents on schema v8 and v12). The schema
  // self-heal below repairs such gaps on every open; without it the gap is
  // permanent because later upgrades skip the failed step's `from < N` block.
  // See docs/adr/0017-schema-self-heal.md.
  int get schemaVersion => 16;

  /// Whether [table] has a physical column named [column] (sqlite name).
  Future<bool> _hasColumn(String table, String column) async {
    final rows = await customSelect('PRAGMA table_info($table)').get();
    for (final row in rows) {
      final name =
          row.readNullable<String>('name') ?? row.data['name']?.toString();
      if (name == column) return true;
    }
    return false;
  }

  Future<bool> _hasTable(String table) async {
    final rows = await customSelect(
      "SELECT 1 AS ok FROM sqlite_master WHERE type = 'table' AND name = ?",
      variables: [Variable.withString(table)],
    ).get();
    return rows.isNotEmpty;
  }

  /// Add a column only when missing. Prefer this over bare addColumn+catch so
  /// we never advance past a migration while leaving the schema incomplete.
  Future<void> _ensureColumn(
    String table,
    String column,
    String alterSql,
  ) async {
    if (!await _hasTable(table)) return;
    if (await _hasColumn(table, column)) return;
    debugPrint('schema heal: ADD COLUMN $table.$column');
    await customStatement(alterSql);
  }

  Future<void> _ensureTable(
    TableInfo<Table, dynamic> table,
    String tableName,
  ) async {
    if (await _hasTable(tableName)) return;
    final m = createMigrator();
    try {
      await m.createTable(table);
      debugPrint('schema heal: CREATE TABLE $tableName');
    } catch (e) {
      // Heal runs on every open and is idempotent; a failure here is retried
      // on the next launch, so do not fail startup over it.
      debugPrint('schema heal: CREATE TABLE $tableName failed: $e');
    }
  }

  /// Repair incomplete upgrades where user_version already advanced but some
  /// ALTER TABLE / CREATE TABLE steps were skipped/failed (silent catch).
  ///
  /// Covers every column/table added by the v5–v13 migrations that are wrapped
  /// in silent try/catch — missing these makes inserts crash with
  /// "table X has no column named Y". Runs in beforeOpen (rescues existing
  /// broken DBs whose user_version already passed the failed step) and at the
  /// end of onUpgrade (rescues gaps created by the upgrade in this session).
  ///
  /// MIRROR CONSTRAINT: when adding a new column/table to a migration, update
  /// this heal set and the regression tests in the same change. See AGENTS.md
  /// §3.20.
  Future<void> _healSchemaIfNeeded() async {
    // --- assistant_rows (v5–v12) ---
    await _ensureColumn(
      'assistant_rows',
      'memory_mode',
      "ALTER TABLE assistant_rows ADD COLUMN memory_mode TEXT NOT NULL DEFAULT 'injection'",
    );
    await _ensureColumn(
      'assistant_rows',
      'docx_mode',
      "ALTER TABLE assistant_rows ADD COLUMN docx_mode TEXT NOT NULL DEFAULT 'extract'",
    );
    await _ensureColumn(
      'assistant_rows',
      'pdf_mode',
      "ALTER TABLE assistant_rows ADD COLUMN pdf_mode TEXT NOT NULL DEFAULT 'extract'",
    );
    await _ensureColumn(
      'assistant_rows',
      'other_office_mode',
      "ALTER TABLE assistant_rows ADD COLUMN other_office_mode TEXT NOT NULL DEFAULT 'direct'",
    );
    // OCR mode (schema v15)
    await _ensureColumn(
      'assistant_rows',
      'ocr_mode',
      "ALTER TABLE assistant_rows ADD COLUMN ocr_mode TEXT NOT NULL DEFAULT 'auto'",
    );
    await _ensureColumn(
      'assistant_rows',
      'enable_proactive_care',
      'ALTER TABLE assistant_rows ADD COLUMN enable_proactive_care INTEGER NOT NULL DEFAULT 0',
    );
    await _ensureColumn(
      'assistant_rows',
      'proactive_care_next_message_at',
      'ALTER TABLE assistant_rows ADD COLUMN proactive_care_next_message_at INTEGER NULL',
    );
    await _ensureColumn(
      'assistant_rows',
      'proactive_care_prompt',
      "ALTER TABLE assistant_rows ADD COLUMN proactive_care_prompt TEXT NOT NULL DEFAULT ''",
    );
    await _ensureColumn(
      'assistant_rows',
      'proactive_care_decision_prompt',
      "ALTER TABLE assistant_rows ADD COLUMN proactive_care_decision_prompt TEXT NOT NULL DEFAULT ''",
    );
    await _ensureColumn(
      'assistant_rows',
      'skill_ids_json',
      "ALTER TABLE assistant_rows ADD COLUMN skill_ids_json TEXT NOT NULL DEFAULT '[]'",
    );
    await _ensureColumn(
      'assistant_rows',
      'enable_time_injection',
      'ALTER TABLE assistant_rows ADD COLUMN enable_time_injection INTEGER NOT NULL DEFAULT 0',
    );
    // Handoff columns (schema v12) — missing these causes:
    // SqliteException: table assistant_rows has no column named discoverable
    await _ensureColumn(
      'assistant_rows',
      'discoverable',
      'ALTER TABLE assistant_rows ADD COLUMN discoverable INTEGER NOT NULL DEFAULT 0',
    );
    await _ensureColumn(
      'assistant_rows',
      'handoff_id',
      'ALTER TABLE assistant_rows ADD COLUMN handoff_id TEXT NULL',
    );
    await _ensureColumn(
      'assistant_rows',
      'handoff_description',
      'ALTER TABLE assistant_rows ADD COLUMN handoff_description TEXT NULL',
    );

    // --- message_rows ---
    await _ensureColumn(
      'message_rows',
      'subgroup_id',
      'ALTER TABLE message_rows ADD COLUMN subgroup_id TEXT NULL',
    );
    await _ensureColumn(
      'message_rows',
      'is_preset',
      'ALTER TABLE message_rows ADD COLUMN is_preset INTEGER NOT NULL DEFAULT 0',
    );
    await _ensureColumn(
      'message_rows',
      'speaker_assistant_id',
      'ALTER TABLE message_rows ADD COLUMN speaker_assistant_id TEXT NULL',
    );

    // --- conversation_rows ---
    await _ensureColumn(
      'conversation_rows',
      'parent_conversation_id',
      'ALTER TABLE conversation_rows ADD COLUMN parent_conversation_id TEXT NULL',
    );
    await _ensureColumn(
      'conversation_rows',
      'conversation_kind',
      "ALTER TABLE conversation_rows ADD COLUMN conversation_kind TEXT NOT NULL DEFAULT 'normal'",
    );
    await customStatement(
      "UPDATE conversation_rows SET conversation_kind = 'normal' "
      "WHERE conversation_kind IS NULL OR conversation_kind = ''",
    );

    // --- tables created by v11/v13 migrations ---
    // NOTE: director_message_rows is deliberately NOT healed — schema v14
    // dropped it (the Director session is ephemeral, never persisted).
    await _ensureTable(groupChatRows, 'group_chat_rows');
    await _ensureTable(groupChatMemberRows, 'group_chat_member_rows');
    await _ensureTable(deletedRecordRows, 'deleted_record_rows');
    await _ensureTable(deletionMarkerRows, 'deletion_marker_rows');

    // Pending-cap columns on group_chat_rows if an older partial create existed.
    await _ensureColumn(
      'group_chat_rows',
      'pending_cap_assistant_message_id',
      'ALTER TABLE group_chat_rows ADD COLUMN pending_cap_assistant_message_id TEXT NULL',
    );
    await _ensureColumn(
      'group_chat_rows',
      'assistant_messages_this_round',
      'ALTER TABLE group_chat_rows ADD COLUMN assistant_messages_this_round INTEGER NOT NULL DEFAULT 0',
    );
    // Schema v16 — group-context injection into member assistant system prompts.
    await _ensureColumn(
      'group_chat_rows',
      'inject_group_members_into_assistant_system_prompt',
      'ALTER TABLE group_chat_rows ADD COLUMN inject_group_members_into_assistant_system_prompt INTEGER NOT NULL DEFAULT 1',
    );
  }

  @override
  MigrationStrategy get migration => MigrationStrategy(
    beforeOpen: (details) async {
      await customStatement('PRAGMA foreign_keys = ON;');
      await customStatement('PRAGMA busy_timeout = 5000;');
      // Always self-heal: user_version may already be 14 while individual
      // addColumn/createTable steps were skipped (silent catch) during an
      // earlier upgrade. Idempotent and cheap (PRAGMA lookups only when the
      // schema is intact).
      await _healSchemaIfNeeded();
    },
    onUpgrade: (migrator, from, to) async {
      if (from < 2) {
        await migrator.createTable(assistantRows);
        await migrator.createTable(cacheRows);
      }
      if (from < 3) {
        try {
          await migrator.addColumn(assistantRows, assistantRows.memoryMode);
        } catch (_) {
          // The column may already exist (due to migration replay or partial failure retry); simply ignore it.
        }
      }
      if (from < 4) {
        try {
          await migrator.addColumn(messageRows, messageRows.subgroupId);
        } catch (_) {
          // The column may already exist (due to migration replay or partial failure retry); simply ignore it.
        }
      }
      if (from < 5) {
        try {
          await migrator.addColumn(assistantRows, assistantRows.docxMode);
        } catch (_) {}
        try {
          await migrator.addColumn(assistantRows, assistantRows.pdfMode);
        } catch (_) {}
        try {
          await migrator.addColumn(
            assistantRows,
            assistantRows.otherOfficeMode,
          );
        } catch (_) {}
      }
      if (from < 6) {
        try {
          await migrator.addColumn(
            assistantRows,
            assistantRows.enableProactiveCare,
          );
        } catch (_) {}
        try {
          await migrator.addColumn(
            assistantRows,
            assistantRows.proactiveCareNextMessageAt,
          );
        } catch (_) {}
        try {
          await migrator.addColumn(
            assistantRows,
            assistantRows.proactiveCarePrompt,
          );
        } catch (_) {}
        try {
          await migrator.addColumn(
            assistantRows,
            assistantRows.proactiveCareDecisionPrompt,
          );
        } catch (_) {}
      }
      if (from < 7) {
        try {
          await migrator.addColumn(assistantRows, assistantRows.skillIdsJson);
        } catch (_) {}
        await customStatement(
          "UPDATE assistant_rows SET skill_ids_json = '[]' WHERE skill_ids_json IS NULL",
        );
      }
      if (from < 8) {
        try {
          await migrator.addColumn(messageRows, messageRows.isPreset);
        } catch (_) {}
      }
      if (from < 9) {
        try {
          await migrator.addColumn(
            assistantRows,
            assistantRows.enableTimeInjection,
          );
        } catch (_) {}
      }
      if (from < 11) {
        try {
          await migrator.createTable(deletedRecordRows);
          await migrator.createTable(deletionMarkerRows);
        } catch (_) {
          // Tables may already exist (migration replay / partial retry).
        }
      }
      if (from < 12) {
        try {
          await migrator.addColumn(
            conversationRows,
            conversationRows.parentConversationId,
          );
        } catch (_) {}
        try {
          await migrator.addColumn(assistantRows, assistantRows.discoverable);
        } catch (_) {}
        try {
          await migrator.addColumn(assistantRows, assistantRows.handoffId);
        } catch (_) {}
        try {
          await migrator.addColumn(
            assistantRows,
            assistantRows.handoffDescription,
          );
        } catch (_) {}
      }
      if (from < 13) {
        try {
          await migrator.createTable(groupChatRows);
        } catch (_) {
          // table may already exist on migration replay
        }
        try {
          await migrator.createTable(groupChatMemberRows);
        } catch (_) {}
        try {
          await migrator.addColumn(
            conversationRows,
            conversationRows.conversationKind,
          );
        } catch (_) {
          // column may already exist on migration replay
        }
        try {
          await migrator.addColumn(messageRows, messageRows.speakerAssistantId);
        } catch (_) {
          // column may already exist on migration replay
        }
        await customStatement(
          "UPDATE conversation_rows SET conversation_kind = 'normal' "
          "WHERE conversation_kind IS NULL OR conversation_kind = ''",
        );
      }
      if (from < 14) {
        // The Director session is ephemeral (rebuilt from the public
        // transcript); the v13 table is unused by the live flow.
        await customStatement('DROP TABLE IF EXISTS director_message_rows');
      }
      if (from < 15) {
        try {
          await migrator.addColumn(assistantRows, assistantRows.ocrMode);
        } catch (_) {
          // The column may already exist (migration replay / partial retry).
        }
      }
      if (from < 16) {
        try {
          await migrator.addColumn(
            groupChatRows,
            groupChatRows.injectGroupMembersIntoAssistantSystemPrompt,
          );
        } catch (_) {
          // The column may already exist (migration replay / partial retry).
        }
      }
      // Final pass: heal any column/table that still did not land.
      await _healSchemaIfNeeded();
    },
  );
}
