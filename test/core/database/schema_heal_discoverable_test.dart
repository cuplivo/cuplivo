import 'dart:io';

import 'package:Cuplivo/core/database/app_database.dart';
import 'package:Cuplivo/core/database/chat_database_repository.dart';
import 'package:Cuplivo/core/models/assistant.dart';
import 'package:Cuplivo/core/models/chat_message.dart';
import 'package:Cuplivo/core/models/conversation.dart';
import 'package:Cuplivo/core/models/group_chat.dart';
import 'package:drift/drift.dart' show Variable;
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

  test('heal adds per-message request metadata before message insert '
      '(v18 column shape)', () async {
    _createLegacyDb(
      dbFile,
      userVersion: 18,
      missingIsPreset: false,
      missingHandoffColumns: false,
      missingOcrMode: false,
      missingContextTokens: false,
      missingV15RequestMetadata: true,
    );

    final repo = ChatDatabaseRepository.open(file: dbFile);
    await repo.ensureReady();

    // Must succeed: heal adds request_allow_images_api_routing /
    // request_extra_body_json before the Drift INSERT, and the metadata
    // must round-trip through the repository mapper.
    final conv = Conversation(title: 'Conv', assistantId: 'a1');
    await repo.putConversation(conv);
    await repo.putMessage(
      ChatMessage(
        role: 'user',
        content: 'draw a cat',
        conversationId: conv.id,
        requestAllowImagesApiRouting: false,
        requestExtraBodyJson: '{"quality":"high","n":2}',
      ),
    );

    final rows = await repo.db.select(repo.db.messageRows).get();
    expect(rows, hasLength(1));
    final loaded = await repo.getMessage(rows.first.id);
    expect(loaded?.requestAllowImagesApiRouting, isFalse);
    expect(loaded?.requestExtraBody, {'quality': 'high', 'n': 2});

    await repo.close();
  });

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

  test('heal adds quote_json to a workspace-complete v20 database', () async {
    _createLegacyDb(
      dbFile,
      userVersion: 20,
      missingIsPreset: false,
      missingHandoffColumns: false,
      missingV15RequestMetadata: false,
      missingQuoteJson: true,
      includeWorkspaceBindingColumns: true,
      includeWorkspaceV20Columns: true,
    );

    final repo = ChatDatabaseRepository.open(file: dbFile);
    await repo.ensureReady();

    // Must succeed: heal adds quote_json before Drift INSERT, and the
    // citation round-trips through the repository.
    final conv = Conversation(title: 'Conv', assistantId: 'a1');
    await repo.putConversation(conv);
    await repo.putMessage(
      ChatMessage(
        role: 'user',
        content: 'reply',
        conversationId: conv.id,
        quoteJson: '{"id":"msg-1","start":3,"end":9}',
      ),
    );

    final rows = await repo.db.select(repo.db.messageRows).get();
    expect(rows, hasLength(1));
    expect(rows.first.quoteJson, '{"id":"msg-1","start":3,"end":9}');

    await repo.close();
  });

  test('heal creates preference_rows (v21 table shape)', () async {
    _createLegacyDb(
      dbFile,
      userVersion: 21,
      missingIsPreset: false,
      missingHandoffColumns: false,
      missingV15RequestMetadata: false,
      missingQuoteJson: false,
      missingPreferenceRows: true,
    );

    final repo = ChatDatabaseRepository.open(file: dbFile);
    await repo.ensureReady();

    // Must succeed: heal creates the KV table before BusinessPreferences
    // writes run, and a key round-trips through it.
    final table = await repo.db
        .customSelect(
          "SELECT COUNT(*) AS c FROM sqlite_master "
          "WHERE type = 'table' AND name = ?",
          variables: [Variable.withString('preference_rows')],
        )
        .get();
    expect(
      table.single.read<int>('c'),
      1,
      reason: 'heal should create preference_rows',
    );

    await repo.db.customStatement(
      "INSERT INTO preference_rows (key, value, updated_at) "
      "VALUES ('test_key_v1', 'true', 1)",
    );
    final stored = await repo.db
        .customSelect(
          "SELECT value FROM preference_rows WHERE key = ?",
          variables: [Variable.withString('test_key_v1')],
        )
        .get();
    expect(stored.single.read<String>('value'), 'true');

    await repo.close();
  });

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

  test('heal adds workspace directory maps and AGENTS.md loading before '
      'assistant and conversation inserts (v20 column shape)', () async {
    _createLegacyDb(
      dbFile,
      userVersion: 20,
      missingIsPreset: false,
      missingHandoffColumns: false,
      missingContextTokens: false,
      missingQuoteJson: false,
      includeWorkspaceBindingColumns: true,
    );

    final repo = ChatDatabaseRepository.open(file: dbFile);
    await repo.ensureReady();

    await repo.putAssistant(
      Assistant(
        id: 'a1',
        name: 'Alpha',
        workspaceDefaultDirectories: const {'w1': '/workspace/project'},
        autoLoadAgentsMd: false,
      ),
      sortOrder: 0,
    );
    await repo.putConversation(
      Conversation(
        title: 'Conv',
        assistantId: 'a1',
        workspaceDirectoryOverrides: const {'w1': '/workspace/project/session'},
      ),
    );

    final assistants = await repo.getAllAssistants();
    final conversations = await repo.getAllConversations();
    expect(assistants.single.workspaceDefaultDirectories, {
      'w1': '/workspace/project',
    });
    expect(assistants.single.autoLoadAgentsMd, isFalse);
    expect(conversations.single.workspaceDirectoryOverrides, {
      'w1': '/workspace/project/session',
    });

    await repo.close();
  });

  test('upgrades v19 workspace bindings to the complete v20 shape', () async {
    _createLegacyDb(
      dbFile,
      userVersion: 19,
      missingIsPreset: false,
      missingHandoffColumns: false,
      missingContextTokens: false,
      includeWorkspaceBindingColumns: true,
    );

    final repo = ChatDatabaseRepository.open(file: dbFile);
    await repo.ensureReady();

    final assistantColumns = await repo.db
        .customSelect('PRAGMA table_info(assistant_rows)')
        .get();
    final assistantColumnNames = assistantColumns
        .map((row) => row.read<String>('name'))
        .toSet();
    expect(
      assistantColumnNames,
      containsAll(<String>[
        'workspace_default_directories_json',
        'auto_load_agents_md',
      ]),
    );
    final conversationColumns = await repo.db
        .customSelect('PRAGMA table_info(conversation_rows)')
        .get();
    expect(
      conversationColumns.map((row) => row.read<String>('name')),
      contains('workspace_directory_overrides_json'),
    );
    final messageColumns = await repo.db
        .customSelect('PRAGMA table_info(message_rows)')
        .get();
    expect(
      messageColumns.map((row) => row.read<String>('name')),
      contains('quote_json'),
    );

    await repo.putAssistant(
      Assistant(
        id: 'a1',
        name: 'Alpha',
        workspaceEnabled: true,
        workspaceId: 'w1',
        workspaceDefaultDirectories: const {'w1': '/workspace/project'},
        autoLoadAgentsMd: false,
      ),
      sortOrder: 0,
    );
    final assistant = (await repo.getAllAssistants()).single;
    expect(assistant.workspaceDefaultDirectories, {'w1': '/workspace/project'});
    expect(assistant.autoLoadAgentsMd, isFalse);

    final conversation = Conversation(
      title: 'Conv',
      assistantId: assistant.id,
      workspaceDirectoryOverrides: const {'w1': '/workspace/project/session'},
    );
    await repo.putConversation(conversation);
    await repo.putMessage(
      ChatMessage(
        role: 'user',
        content: 'reply',
        conversationId: conversation.id,
        quoteJson: '{"id":"msg-1","start":3,"end":9}',
      ),
    );
    expect(
      (await repo.getAllConversations()).single.workspaceDirectoryOverrides,
      {'w1': '/workspace/project/session'},
    );
    expect(
      (await repo.db.select(repo.db.messageRows).get()).single.quoteJson,
      '{"id":"msg-1","start":3,"end":9}',
    );

    await repo.close();
  });

  test('v22 migration adds conversation proactive-care columns and transfers the '
      'future legacy schedule to the newest normal conversation', () async {
    _createLegacyDb(
      dbFile,
      userVersion: 21,
      missingIsPreset: false,
      missingHandoffColumns: false,
      missingContextTokens: false,
      missingV15RequestMetadata: false,
      missingQuoteJson: false,
      includeWorkspaceBindingColumns: true,
      includeWorkspaceV20Columns: true,
      missingPreferenceRows: false,
    );
    final future = DateTime.utc(2099, 1, 2, 3, 4, 5);
    final raw = sqlite.sqlite3.open(dbFile.path);
    raw.execute(
      'INSERT INTO assistant_rows '
      '(id, name, proactive_care_next_message_at, sort_order, created_at, updated_at) '
      'VALUES (?, ?, ?, ?, ?, ?)',
      ['a1', 'Alpha', _secondsSinceEpoch(future), 0, 1, 1],
    );
    raw.execute(
      'INSERT INTO conversation_rows '
      '(id, title, created_at, updated_at, assistant_id) '
      'VALUES (?, ?, ?, ?, ?)',
      ['older', 'Older', 1, 10, 'a1'],
    );
    raw.execute(
      'INSERT INTO conversation_rows '
      '(id, title, created_at, updated_at, assistant_id) '
      'VALUES (?, ?, ?, ?, ?)',
      ['newer', 'Newer', 1, 20, 'a1'],
    );
    raw.close();

    final repo = ChatDatabaseRepository.open(file: dbFile);
    await repo.ensureReady();

    final columns = await repo.db
        .customSelect('PRAGMA table_info(conversation_rows)')
        .get();
    expect(
      columns.map((row) => row.read<String>('name')),
      containsAll(<String>[
        'proactive_care_enabled_override',
        'proactive_care_next_message_at',
      ]),
    );
    expect(
      (await repo.getConversation('older'))?.proactiveCareNextMessageAt,
      isNull,
    );
    final migrated = await repo.getConversation('newer');
    expect(migrated?.proactiveCareEnabledOverride, isNull);
    expect(
      migrated?.proactiveCareNextMessageAt?.isAtSameMomentAs(future),
      isTrue,
    );
    expect((await repo.getAssistant('a1'))?.proactiveCareNextMessageAt, isNull);

    await repo.close();
  });

  test('heal restores missing v22 conversation proactive-care columns when '
      'user_version already advanced', () async {
    _createLegacyDb(
      dbFile,
      userVersion: 22,
      missingIsPreset: false,
      missingHandoffColumns: false,
      missingContextTokens: false,
      missingV15RequestMetadata: false,
      missingQuoteJson: false,
      includeWorkspaceBindingColumns: true,
      includeWorkspaceV20Columns: true,
      missingPreferenceRows: false,
    );

    final repo = ChatDatabaseRepository.open(file: dbFile);
    await repo.ensureReady();
    final nextMessageAt = DateTime.utc(2028, 3, 4, 5, 6, 7);
    await repo.putConversation(
      Conversation(
        id: 'healed-v22',
        title: 'Healed',
        proactiveCareEnabledOverride: false,
        proactiveCareNextMessageAt: nextMessageAt,
      ),
    );

    final loaded = await repo.getConversation('healed-v22');
    expect(loaded?.proactiveCareEnabledOverride, isFalse);
    expect(
      loaded?.proactiveCareNextMessageAt?.isAtSameMomentAs(nextMessageAt),
      isTrue,
    );

    await repo.close();
  });

  test('legacy transfer preserves conversation schedules and clears future '
      'assistant schedules without eligible targets', () async {
    _createLegacyDb(
      dbFile,
      userVersion: 22,
      missingIsPreset: false,
      missingHandoffColumns: false,
      missingContextTokens: false,
      missingV15RequestMetadata: false,
      missingQuoteJson: false,
      includeWorkspaceBindingColumns: true,
      includeWorkspaceV20Columns: true,
      includeConversationKindColumn: true,
      includeConversationV22Columns: true,
      missingPreferenceRows: false,
    );
    final future = DateTime.utc(2099, 2, 3, 4, 5, 6);
    final existing = DateTime.utc(2098, 2, 3, 4, 5, 6);
    final past = DateTime.utc(2020, 1, 1);
    final raw = sqlite.sqlite3.open(dbFile.path);
    for (final entry in <(String, DateTime)>[
      ('existing', future),
      ('no-target', future),
      ('group-only', future),
      ('past', past),
    ]) {
      raw.execute(
        'INSERT INTO assistant_rows '
        '(id, name, proactive_care_next_message_at, sort_order, created_at, updated_at) '
        'VALUES (?, ?, ?, ?, ?, ?)',
        [entry.$1, entry.$1, _secondsSinceEpoch(entry.$2), 0, 1, 1],
      );
    }
    raw.execute(
      'INSERT INTO conversation_rows '
      '(id, title, created_at, updated_at, assistant_id, conversation_kind, '
      'proactive_care_next_message_at) VALUES (?, ?, ?, ?, ?, ?, ?)',
      [
        'target',
        'Target',
        1,
        10,
        'existing',
        'normal',
        _secondsSinceEpoch(existing),
      ],
    );
    raw.execute(
      'INSERT INTO conversation_rows '
      '(id, title, created_at, updated_at, assistant_id, conversation_kind) '
      'VALUES (?, ?, ?, ?, ?, ?)',
      ['group', 'Group', 1, 10, 'group-only', 'group'],
    );
    raw.execute(
      'INSERT INTO conversation_rows '
      '(id, title, created_at, updated_at, assistant_id, conversation_kind) '
      'VALUES (?, ?, ?, ?, ?, ?)',
      ['past-target', 'Past', 1, 10, 'past', 'normal'],
    );
    raw.close();

    final repo = ChatDatabaseRepository.open(file: dbFile);
    await repo.ensureReady();

    expect(
      (await repo.getConversation(
        'target',
      ))?.proactiveCareNextMessageAt?.isAtSameMomentAs(existing),
      isTrue,
    );
    expect(
      (await repo.getConversation('group'))?.proactiveCareNextMessageAt,
      isNull,
    );
    expect(
      (await repo.getConversation('past-target'))?.proactiveCareNextMessageAt,
      isNull,
    );
    expect(
      (await repo.getAssistant('existing'))?.proactiveCareNextMessageAt,
      isNull,
    );
    expect(
      (await repo.getAssistant('no-target'))?.proactiveCareNextMessageAt,
      isNull,
    );
    expect(
      (await repo.getAssistant('group-only'))?.proactiveCareNextMessageAt,
      isNull,
    );
    expect(
      (await repo.getAssistant(
        'past',
      ))?.proactiveCareNextMessageAt?.isAtSameMomentAs(past),
      isTrue,
    );

    await repo.close();
  });
}

int _secondsSinceEpoch(DateTime value) =>
    value.millisecondsSinceEpoch ~/ Duration.millisecondsPerSecond;

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
  bool missingV15RequestMetadata = false,
  bool missingQuoteJson = true,
  bool includeWorkspaceBindingColumns = false,
  bool includeWorkspaceV20Columns = false,
  bool includeConversationKindColumn = false,
  bool includeConversationV22Columns = false,
  bool missingPreferenceRows = true,
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
  final workspaceBindingColumns = includeWorkspaceBindingColumns
      ? '''
  workspace_enabled INTEGER NOT NULL DEFAULT 0,
  workspace_id TEXT NULL,
'''
      : '';
  final workspaceV20AssistantColumns = includeWorkspaceV20Columns
      ? '''
  workspace_default_directories_json TEXT NOT NULL DEFAULT '{}',
  auto_load_agents_md INTEGER NOT NULL DEFAULT 1,
'''
      : '';
  final workspaceV20ConversationColumn = includeWorkspaceV20Columns
      ? ",\n  workspace_directory_overrides_json TEXT NOT NULL DEFAULT '{}'"
      : '';
  final conversationKindColumn = includeConversationKindColumn
      ? ",\n  conversation_kind TEXT NOT NULL DEFAULT 'normal'"
      : '';
  final conversationV22Columns = includeConversationV22Columns
      ? ',\n  proactive_care_enabled_override INTEGER NULL'
            ',\n  proactive_care_next_message_at INTEGER NULL'
      : '';
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
  $workspaceBindingColumns
  $workspaceV20AssistantColumns
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
  parent_conversation_id TEXT NULL$workspaceV20ConversationColumn$conversationKindColumn$conversationV22Columns
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
  final v15Columns = missingV15RequestMetadata
      ? ''
      : '''
  request_allow_images_api_routing INTEGER NULL,
  request_extra_body_json TEXT NULL,
''';
  final quoteJsonColumn = missingQuoteJson
      ? ''
      : '''
  quote_json TEXT NULL,
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
  $v15Columns
  $quoteJsonColumn
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
  if (!missingPreferenceRows) {
    raw.execute('''
CREATE TABLE preference_rows (
  key TEXT NOT NULL PRIMARY KEY,
  value TEXT NOT NULL,
  updated_at INTEGER NOT NULL
);
''');
  }
  raw.close();
}
