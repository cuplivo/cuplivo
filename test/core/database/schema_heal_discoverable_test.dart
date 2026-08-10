import 'dart:io';

import 'package:Cuplivo/core/database/app_database.dart';
import 'package:Cuplivo/core/database/chat_database_repository.dart';
import 'package:Cuplivo/core/models/assistant.dart';
import 'package:Cuplivo/core/models/chat_message.dart';
import 'package:Cuplivo/core/models/conversation.dart';
import 'package:Cuplivo/core/models/group_chat.dart';
import 'package:drift/drift.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart' as sqlite;

/// Reproduces: user_version already advanced while silent migration failures
/// left columns missing. The schema self-heal (see
/// docs/adr/0019-schema-self-heal.md) must repair these before Drift INSERTs
/// run, otherwise inserts crash with "table X has no column named Y".
///
/// Two real-incident shapes:
/// - v8 shape: user_version=14 (current) but `is_preset` never landed —
///   onUpgrade is skipped entirely (from == 14), only beforeOpen can rescue.
/// - v12 shape: user_version=13 but handoff columns never landed — the
///   original incident that motivated the heal.
void main() {
  late Directory tempDir;
  late File dbFile;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('cuplivo_heal_');
    dbFile = File(p.join(tempDir.path, AppDatabase.databaseFileName));
  });

  tearDown(() async {
    if (await tempDir.exists()) {
      await tempDir.delete(recursive: true);
    }
  });

  test(
    'heal adds is_preset on a v14 DB missing it (v8 incident shape)',
    () async {
      _createLegacyDb(
        dbFile,
        userVersion: 14,
        missingIsPreset: true,
        missingHandoffColumns: false,
      );

      final repo = ChatDatabaseRepository.open(file: dbFile);
      await repo.ensureReady();

      // Must succeed: heal adds is_preset (+ conversation_kind /
      // speaker_assistant_id) before Drift INSERT of the preset message.
      final conv = Conversation(title: 'Conv', assistantId: 'a1');
      await repo.putConversation(conv);
      await repo.putMessage(
        ChatMessage(
          role: 'assistant',
          content: 'preset content',
          conversationId: conv.id,
          isPreset: true,
        ),
      );

      final rows = await repo.db.select(repo.db.messageRows).get();
      expect(rows, hasLength(1));
      expect(rows.first.isPreset, isTrue);

      await repo.close();
    },
  );

  test('heal adds discoverable/handoff columns before assistant insert '
      '(v12 incident shape)', () async {
    _createLegacyDb(
      dbFile,
      userVersion: 13,
      missingIsPreset: false,
      missingHandoffColumns: true,
    );

    final repo = ChatDatabaseRepository.open(file: dbFile);
    await repo.ensureReady();

    // Must succeed: heal adds discoverable/handoff_* before Drift INSERT.
    await repo.putAssistant(
      Assistant(id: 'a1', name: 'Alpha', systemPrompt: 'hi'),
      sortOrder: 0,
    );
    final loaded = await repo.getAllAssistants();
    expect(loaded, hasLength(1));
    expect(loaded.first.name, 'Alpha');
    expect(loaded.first.discoverable, isFalse);

    await repo.close();
  });

  test(
    'heal also creates missing group/trash tables (v11/v13 table shape)',
    () async {
      _createLegacyDb(
        dbFile,
        userVersion: 14,
        missingIsPreset: false,
        missingHandoffColumns: false,
      );
      final repo = ChatDatabaseRepository.open(file: dbFile);
      await repo.ensureReady();

      // All healed tables must exist, not just the ones used by inserts.
      for (final table in [
        'group_chat_rows',
        'group_chat_member_rows',
        'deleted_record_rows',
        'deletion_marker_rows',
      ]) {
        final rows = await repo.db
            .customSelect(
              "SELECT COUNT(*) AS c FROM sqlite_master "
              "WHERE type = 'table' AND name = ?",
              variables: [Variable.withString(table)],
            )
            .get();
        expect(
          rows.single.read<int>('c'),
          1,
          reason: 'heal should create $table',
        );
      }

      await repo.close();
    },
  );

  test(
    'heal adds ocr_mode before assistant insert (v15 column shape)',
    () async {
      _createLegacyDb(
        dbFile,
        userVersion: 15,
        missingIsPreset: false,
        missingHandoffColumns: false,
        missingOcrMode: true,
      );

      final repo = ChatDatabaseRepository.open(file: dbFile);
      await repo.ensureReady();

      // Must succeed: heal adds ocr_mode before Drift INSERT.
      await repo.putAssistant(
        Assistant(id: 'a1', name: 'Alpha', systemPrompt: 'hi'),
        sortOrder: 0,
      );
      final loaded = await repo.getAllAssistants();
      expect(loaded, hasLength(1));
      expect(loaded.first.name, 'Alpha');
      expect(loaded.first.ocrMode, 'auto');

      await repo.close();
    },
  );

  test(
    'heal adds context_tokens before message insert (v17 column shape)',
    () async {
      _createLegacyDb(
        dbFile,
        userVersion: 17,
        missingIsPreset: false,
        missingHandoffColumns: false,
        missingOcrMode: false,
        missingContextTokens: true,
      );

      final repo = ChatDatabaseRepository.open(file: dbFile);
      await repo.ensureReady();

      // Must succeed: heal adds context_tokens before Drift INSERT, and the
      // value round-trips through the repository.
      final conv = Conversation(title: 'Conv', assistantId: 'a1');
      await repo.putConversation(conv);
      await repo.putMessage(
        ChatMessage(
          role: 'assistant',
          content: 'with context',
          conversationId: conv.id,
          contextTokens: 4321,
        ),
      );

      final rows = await repo.db.select(repo.db.messageRows).get();
      expect(rows, hasLength(1));
      expect(rows.first.contextTokens, 4321);

      await repo.close();
    },
  );

  test('heal adds inject_group_members column on group_chat_rows '
      '(v17 column shape)', () async {
    _createLegacyDb(
      dbFile,
      userVersion: 17,
      missingIsPreset: false,
      missingHandoffColumns: false,
    );
    // A partial group_chat_rows table missing the v17 column, as if a
    // silent migration failure left user_version at 17 without it.
    final raw = sqlite.sqlite3.open(dbFile.path);
    raw.execute('''
CREATE TABLE group_chat_rows (
  id TEXT NOT NULL PRIMARY KEY,
  name TEXT NOT NULL,
  avatar TEXT NULL,
  conversation_id TEXT NOT NULL UNIQUE,
  director_model_provider TEXT NULL,
  director_model_id TEXT NULL,
  director_system_prompt TEXT NOT NULL DEFAULT '',
  max_assistant_messages_per_round INTEGER NOT NULL DEFAULT 3,
  assistant_detail_injection_mode TEXT NOT NULL DEFAULT 'endOfEveryUserMessage',
  assistant_detail_injection_n INTEGER NOT NULL DEFAULT 5,
  pending_cap_assistant_message_id TEXT NULL,
  assistant_messages_this_round INTEGER NOT NULL DEFAULT 0,
  created_at INTEGER NOT NULL,
  updated_at INTEGER NOT NULL
);
''');
    raw.close();

    final repo = ChatDatabaseRepository.open(file: dbFile);
    await repo.ensureReady();

    // Must succeed: heal adds the column before Drift INSERT.
    final conv = Conversation(
      title: 'Group',
      assistantId: null,
      conversationKind: Conversation.kindGroup,
    );
    await repo.putConversation(conv);
    await repo.putGroupChat(
      GroupChat(
        name: 'G',
        conversationId: conv.id,
        injectGroupMembersIntoAssistantSystemPrompt: true,
      ),
    );
    final groups = await repo.getAllGroupChats();
    expect(groups, hasLength(1));
    expect(groups.first.injectGroupMembersIntoAssistantSystemPrompt, isTrue);

    await repo.close();
  });
}

/// Builds a v13-era DB shape (assistant/conversation/message tables only —
/// group/trash tables are never created, so they are always "missing" for the
/// heal) with selectable column gaps, mirroring what a silent migration
/// failure leaves behind: user_version already advanced past the failed step.
void _createLegacyDb(
  File dbFile, {
  required int userVersion,
  required bool missingIsPreset,
  required bool missingHandoffColumns,
  bool missingOcrMode = false,
  bool missingContextTokens = true,
}) {
  final raw = sqlite.sqlite3.open(dbFile.path);
  raw.execute('PRAGMA user_version = $userVersion;');
  final handoffColumns = missingHandoffColumns
      ? ''
      : '''
  discoverable INTEGER NOT NULL DEFAULT 0,
  handoff_id TEXT NULL,
  handoff_description TEXT NULL,
''';
  final ocrModeColumn = missingOcrMode
      ? ''
      : '''
  ocr_mode TEXT NOT NULL DEFAULT 'auto',
''';
  raw.execute('''
CREATE TABLE assistant_rows (
  id TEXT NOT NULL PRIMARY KEY,
  name TEXT NOT NULL,
  avatar TEXT NULL,
  use_assistant_avatar INTEGER NOT NULL DEFAULT 0,
  use_assistant_name INTEGER NOT NULL DEFAULT 0,
  background TEXT NULL,
  chat_model_provider TEXT NULL,
  chat_model_id TEXT NULL,
  temperature REAL NULL,
  top_p REAL NULL,
  context_message_size INTEGER NOT NULL DEFAULT 64,
  limit_context_messages INTEGER NOT NULL DEFAULT 1,
  stream_output INTEGER NOT NULL DEFAULT 1,
  thinking_budget INTEGER NULL,
  max_tokens INTEGER NULL,
  custom_headers_json TEXT NOT NULL DEFAULT '[]',
  custom_body_json TEXT NOT NULL DEFAULT '[]',
  system_prompt TEXT NOT NULL DEFAULT '',
  message_template TEXT NOT NULL DEFAULT '{{ message }}',
  preset_messages_json TEXT NOT NULL DEFAULT '[]',
  search_enabled INTEGER NOT NULL DEFAULT 0,
  mcp_server_ids_json TEXT NOT NULL DEFAULT '[]',
  local_tool_ids_json TEXT NOT NULL DEFAULT '[]',
  skill_ids_json TEXT NOT NULL DEFAULT '[]',
  regex_rules_json TEXT NOT NULL DEFAULT '[]',
  enable_proactive_care INTEGER NOT NULL DEFAULT 0,
  proactive_care_next_message_at INTEGER NULL,
  proactive_care_prompt TEXT NOT NULL DEFAULT '',
  proactive_care_decision_prompt TEXT NOT NULL DEFAULT '',
  enable_memory INTEGER NOT NULL DEFAULT 0,
  memory_mode TEXT NOT NULL DEFAULT 'injection',
  enable_recent_chats_reference INTEGER NOT NULL DEFAULT 0,
  recent_chats_summary_message_count INTEGER NOT NULL DEFAULT 5,
  memory_record_prompt TEXT NOT NULL DEFAULT '',
  docx_mode TEXT NOT NULL DEFAULT 'extract',
  pdf_mode TEXT NOT NULL DEFAULT 'extract',
  other_office_mode TEXT NOT NULL DEFAULT 'direct',
  $ocrModeColumn
  enable_time_injection INTEGER NOT NULL DEFAULT 0,
  $handoffColumns
  sort_order INTEGER NOT NULL,
  created_at INTEGER NOT NULL,
  updated_at INTEGER NOT NULL
);
''');
  raw.execute('''
CREATE TABLE conversation_rows (
  id TEXT NOT NULL PRIMARY KEY,
  title TEXT NOT NULL,
  created_at INTEGER NOT NULL,
  updated_at INTEGER NOT NULL,
  is_pinned INTEGER NOT NULL DEFAULT 0,
  assistant_id TEXT NULL,
  truncate_index INTEGER NOT NULL DEFAULT -1,
  version_selections_json TEXT NOT NULL DEFAULT '{}',
  summary TEXT NULL,
  last_summarized_message_count INTEGER NOT NULL DEFAULT 0,
  chat_suggestions_json TEXT NOT NULL DEFAULT '[]',
  parent_conversation_id TEXT NULL
);
''');
  final isPresetColumn = missingIsPreset
      ? ''
      : '''
  is_preset INTEGER NOT NULL DEFAULT 0,
''';
  final contextTokensColumn = missingContextTokens
      ? ''
      : '''
  context_tokens INTEGER NULL,
''';
  raw.execute('''
CREATE TABLE message_rows (
  id TEXT NOT NULL PRIMARY KEY,
  conversation_id TEXT NOT NULL,
  role TEXT NOT NULL,
  content TEXT NOT NULL,
  timestamp INTEGER NOT NULL,
  model_id TEXT NULL,
  provider_id TEXT NULL,
  total_tokens INTEGER NULL,
  is_streaming INTEGER NOT NULL DEFAULT 0,
  reasoning_text TEXT NULL,
  reasoning_start_at INTEGER NULL,
  reasoning_finished_at INTEGER NULL,
  translation TEXT NULL,
  reasoning_segments_json TEXT NULL,
  group_id TEXT NULL,
  subgroup_id TEXT NULL,
  version INTEGER NOT NULL DEFAULT 0,
  prompt_tokens INTEGER NULL,
  completion_tokens INTEGER NULL,
  cached_tokens INTEGER NULL,
  duration_ms INTEGER NULL,
  message_order INTEGER NOT NULL,
  $contextTokensColumn
  $isPresetColumn
  FOREIGN KEY (conversation_id) REFERENCES conversation_rows (id) ON DELETE CASCADE
);
''');
  raw.execute('''
CREATE TABLE conversation_mcp_server_rows (
  conversation_id TEXT NOT NULL,
  server_id TEXT NOT NULL,
  ordinal INTEGER NOT NULL,
  PRIMARY KEY (conversation_id, server_id)
);
''');
  raw.close();
}
