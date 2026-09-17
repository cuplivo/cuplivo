import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart' as sqlite;

import 'package:Cuplivo/core/services/migration/cuplivo_v3/cuplivo_v3_reader.dart';

/// Builds a `kelivo.sqlite`-shaped fixture: raw DDL mirroring the fork's
/// Drift schema v23 tables (only the columns the reader touches), with
/// `PRAGMA user_version = 23`.
class V3FixtureBuilder {
  V3FixtureBuilder(this.path);

  final String path;

  static const String ddl = '''
CREATE TABLE conversation_rows (
  id TEXT NOT NULL PRIMARY KEY,
  title TEXT NOT NULL,
  created_at INTEGER NOT NULL,
  updated_at INTEGER NOT NULL,
  is_pinned INTEGER NOT NULL DEFAULT 0 CHECK (is_pinned IN (0, 1)),
  assistant_id TEXT NULL,
  truncate_index INTEGER NOT NULL DEFAULT -1,
  version_selections_json TEXT NOT NULL DEFAULT '{}',
  summary TEXT NULL,
  last_summarized_message_count INTEGER NOT NULL DEFAULT 0,
  chat_suggestions_json TEXT NOT NULL DEFAULT '[]',
  parent_conversation_id TEXT NULL,
  conversation_kind TEXT NOT NULL DEFAULT 'normal',
  workspace_directory_overrides_json TEXT NOT NULL DEFAULT '{}',
  chat_model_provider TEXT NULL,
  chat_model_id TEXT NULL,
  persistent_quick_instruction_ids_json TEXT NOT NULL DEFAULT '[]',
  proactive_care_enabled_override INTEGER NULL,
  proactive_care_next_message_at INTEGER NULL
);
CREATE TABLE message_rows (
  id TEXT NOT NULL PRIMARY KEY,
  conversation_id TEXT NOT NULL REFERENCES conversation_rows (id) ON DELETE CASCADE,
  role TEXT NOT NULL,
  content TEXT NOT NULL,
  timestamp INTEGER NOT NULL,
  model_id TEXT NULL,
  provider_id TEXT NULL,
  total_tokens INTEGER NULL,
  context_tokens INTEGER NULL,
  is_streaming INTEGER NOT NULL DEFAULT 0 CHECK (is_streaming IN (0, 1)),
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
  is_preset INTEGER NOT NULL DEFAULT 0 CHECK (is_preset IN (0, 1)),
  speaker_assistant_id TEXT NULL,
  request_allow_images_api_routing INTEGER NULL,
  request_extra_body_json TEXT NULL,
  quote_json TEXT NULL,
  quick_instruction_invocations_json TEXT NULL
);
CREATE TABLE conversation_mcp_server_rows (
  conversation_id TEXT NOT NULL REFERENCES conversation_rows (id) ON DELETE CASCADE,
  server_id TEXT NOT NULL,
  ordinal INTEGER NOT NULL,
  PRIMARY KEY (conversation_id, server_id)
);
CREATE TABLE tool_event_rows (
  message_id TEXT NOT NULL REFERENCES message_rows (id) ON DELETE CASCADE,
  events_json TEXT NOT NULL,
  PRIMARY KEY (message_id)
);
CREATE TABLE gemini_thought_signature_rows (
  message_id TEXT NOT NULL REFERENCES message_rows (id) ON DELETE CASCADE,
  signature TEXT NOT NULL,
  PRIMARY KEY (message_id)
);
CREATE TABLE group_chat_rows (
  id TEXT NOT NULL PRIMARY KEY,
  name TEXT NOT NULL,
  avatar TEXT NULL,
  conversation_id TEXT NOT NULL UNIQUE REFERENCES conversation_rows (id) ON DELETE CASCADE,
  director_model_provider TEXT NULL,
  director_model_id TEXT NULL,
  director_system_prompt TEXT NOT NULL DEFAULT '',
  max_assistant_messages_per_round INTEGER NOT NULL DEFAULT 3,
  assistant_detail_injection_mode TEXT NOT NULL DEFAULT 'endOfEveryUserMessage',
  assistant_detail_injection_n INTEGER NOT NULL DEFAULT 5,
  inject_group_members_into_assistant_system_prompt INTEGER NOT NULL DEFAULT 1,
  pending_cap_assistant_message_id TEXT NULL,
  assistant_messages_this_round INTEGER NOT NULL DEFAULT 0,
  created_at INTEGER NOT NULL,
  updated_at INTEGER NOT NULL
);
CREATE TABLE group_chat_member_rows (
  group_chat_id TEXT NOT NULL REFERENCES group_chat_rows (id) ON DELETE CASCADE,
  member_key TEXT NOT NULL,
  assistant_id TEXT NULL,
  sort_order INTEGER NOT NULL,
  PRIMARY KEY (group_chat_id, member_key)
);
CREATE TABLE preference_rows (
  key TEXT NOT NULL PRIMARY KEY,
  value TEXT NOT NULL,
  updated_at INTEGER NOT NULL
);
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
  workspace_enabled INTEGER NOT NULL DEFAULT 0,
  workspace_id TEXT NULL,
  workspace_default_directories_json TEXT NOT NULL DEFAULT '{}',
  auto_load_agents_md INTEGER NOT NULL DEFAULT 1,
  regex_rules_json TEXT NOT NULL DEFAULT '[]',
  enable_proactive_care INTEGER NOT NULL DEFAULT 0,
  proactive_care_next_message_at INTEGER NULL,
  proactive_care_prompt TEXT NOT NULL DEFAULT '',
  proactive_care_decision_prompt TEXT NOT NULL DEFAULT '',
  proactive_care_decision_history_message_limit INTEGER NULL,
  enable_memory INTEGER NOT NULL DEFAULT 0,
  memory_mode TEXT NOT NULL DEFAULT 'injection',
  enable_recent_chats_reference INTEGER NOT NULL DEFAULT 0,
  recent_chats_summary_message_count INTEGER NOT NULL DEFAULT 5,
  memory_record_prompt TEXT NOT NULL DEFAULT '',
  docx_mode TEXT NOT NULL DEFAULT 'extract',
  pdf_mode TEXT NOT NULL DEFAULT 'extract',
  other_office_mode TEXT NOT NULL DEFAULT 'direct',
  ocr_mode TEXT NOT NULL DEFAULT 'auto',
  enable_time_injection INTEGER NOT NULL DEFAULT 0,
  discoverable INTEGER NOT NULL DEFAULT 0,
  handoff_id TEXT NULL,
  handoff_description TEXT NULL,
  sort_order INTEGER NOT NULL,
  created_at INTEGER NOT NULL,
  updated_at INTEGER NOT NULL
);
''';

  /// Drift stores DateTime as unix SECONDS by default (the fork declares no
  /// DateStorageMode override); these constants are second-precision.
  static const int convCreatedSecs = 1700000000;
  static const int convUpdatedSecs = 1700000600;
  static const int msgOneSecs = 1700000100;
  static const int msgTwoSecs = 1700000200;
  static const int reasoningStartSecs = 1700000210;
  static const int reasoningFinishSecs = 1700000215;
  static const int nextMessageAtSecs = 1700003600;
  static const int groupCreatedSecs = 1700000300;
  static const int assistantCreatedSecs = 1699000000;

  void create({int userVersion = 23}) {
    final database = sqlite.sqlite3.open(path);
    try {
      database.execute('PRAGMA foreign_keys = ON;');
      database.execute(ddl);
      database.execute('PRAGMA user_version = $userVersion;');
    } finally {
      database.close();
    }
  }

  void transaction(void Function(sqlite.Database db) body) {
    final database = sqlite.sqlite3.open(path);
    try {
      database.execute('PRAGMA foreign_keys = ON;');
      database.execute('BEGIN;');
      body(database);
      database.execute('COMMIT;');
    } catch (_) {
      database.execute('ROLLBACK;');
      rethrow;
    } finally {
      database.close();
    }
  }

  /// The canonical happy-path dataset described by the field spec.
  void seedStandardRows() => transaction((db) {
    // Conversation 1: normal chat, json extras populated, two MCP servers.
    db.execute(
      'INSERT INTO conversation_rows (id, title, created_at, updated_at, '
      'is_pinned, assistant_id, truncate_index, version_selections_json, '
      'summary, last_summarized_message_count, chat_suggestions_json, '
      'parent_conversation_id, conversation_kind, '
      'workspace_directory_overrides_json, chat_model_provider, '
      'chat_model_id, persistent_quick_instruction_ids_json, '
      'proactive_care_enabled_override, proactive_care_next_message_at) '
      'VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);',
      [
        'conv-1',
        'First chat',
        convCreatedSecs,
        convUpdatedSecs,
        1,
        'asst-1',
        2,
        '{"g-1": 1}',
        'A summary',
        7,
        '["Suggest A"]',
        null,
        'normal',
        '{"dir-a": "/tmp/a"}',
        'openai',
        'gpt-4o-mini',
        '["qi-1"]',
        null,
        null,
      ],
    );
    // Conversation 2: group kind + proactive-care override + schedule.
    db.execute(
      'INSERT INTO conversation_rows (id, title, created_at, updated_at, '
      'is_pinned, assistant_id, conversation_kind, '
      'proactive_care_enabled_override, proactive_care_next_message_at) '
      'VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?);',
      [
        'conv-2',
        'Group room',
        groupCreatedSecs,
        groupCreatedSecs + 30,
        0,
        null,
        'group',
        0,
        nextMessageAtSecs,
      ],
    );
    db.execute(
      'INSERT INTO conversation_mcp_server_rows (conversation_id, server_id, '
      'ordinal) VALUES (?, ?, ?), (?, ?, ?);',
      ['conv-1', 'mcp-b', 1, 'conv-1', 'mcp-a', 0],
    );
    // Four messages: a user/assistant pair in conv-1 (the user one carries
    // quote/request metadata, the assistant one reasoning timestamps and tool
    // events), plus two in conv-2 where one has a speaker assistant id. Orders
    // are deliberately not insertion order so message_order drives sequence.
    db.execute(
      'INSERT INTO message_rows (id, conversation_id, role, content, '
      'timestamp, model_id, provider_id, total_tokens, context_tokens, '
      'is_streaming, reasoning_text, reasoning_start_at, '
      'reasoning_finished_at, translation, reasoning_segments_json, group_id, '
      'subgroup_id, version, prompt_tokens, completion_tokens, cached_tokens, '
      'duration_ms, message_order, is_preset, speaker_assistant_id, '
      'request_allow_images_api_routing, request_extra_body_json, quote_json, '
      'quick_instruction_invocations_json) '
      'VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, '
      '?, ?, ?, ?, ?, ?, ?, ?);',
      [
        'msg-u1',
        'conv-1',
        'user',
        'Hello there',
        msgOneSecs,
        null,
        null,
        null,
        null,
        0,
        null,
        null,
        null,
        null,
        null,
        'grp-1',
        null,
        0,
        null,
        null,
        null,
        null,
        0,
        0,
        null,
        1,
        '{"image":true}',
        null,
        '[{"id":"qi-1"}]',
      ],
    );
    db.execute(
      'INSERT INTO message_rows (id, conversation_id, role, content, '
      'timestamp, model_id, provider_id, total_tokens, context_tokens, '
      'is_streaming, reasoning_text, reasoning_start_at, '
      'reasoning_finished_at, translation, reasoning_segments_json, group_id, '
      'subgroup_id, version, prompt_tokens, completion_tokens, cached_tokens, '
      'duration_ms, message_order, is_preset, speaker_assistant_id, '
      'request_allow_images_api_routing, request_extra_body_json, quote_json, '
      'quick_instruction_invocations_json) '
      'VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, '
      '?, ?, ?, ?, ?, ?, ?, ?);',
      [
        'msg-a1',
        'conv-1',
        'assistant',
        'Hi! How can I help?',
        msgTwoSecs,
        'gemini-2.5-flash',
        'gemini',
        120,
        8000,
        0,
        'thinking hard',
        reasoningStartSecs,
        reasoningFinishSecs,
        'translated',
        '[{"text":"seg"}]',
        'grp-1',
        'sub-1',
        1,
        100,
        20,
        5,
        1234,
        1,
        0,
        null,
        null,
        null,
        '{"messageId":"msg-u1","text":"Hello there"}',
        null,
      ],
    );
    db.execute(
      'INSERT INTO message_rows (id, conversation_id, role, content, '
      'timestamp, message_order, speaker_assistant_id) VALUES (?, ?, ?, ?, '
      '?, ?, ?);',
      [
        'msg-g1',
        'conv-2',
        'assistant',
        'As a group member',
        groupCreatedSecs + 10,
        0,
        'asst-1',
      ],
    );
    db.execute(
      'INSERT INTO message_rows (id, conversation_id, role, content, '
      'timestamp, message_order) VALUES (?, ?, ?, ?, ?, ?);',
      [
        'msg-g2',
        'conv-2',
        'user',
        'Talk amongst yourselves',
        groupCreatedSecs + 20,
        1,
      ],
    );
    db.execute(
      'INSERT INTO tool_event_rows (message_id, events_json) VALUES (?, ?);',
      ['msg-a1', '[{"toolName":"web_search","status":"done"}]'],
    );
    // The second signature is whitespace-only and must be skipped on read.
    db.execute(
      'INSERT INTO gemini_thought_signature_rows (message_id, signature) '
      'VALUES (?, ?), (?, ?);',
      ['msg-a1', '  sig-abc  ', 'msg-g1', '   '],
    );
    db.execute(
      'INSERT INTO group_chat_rows (id, name, avatar, conversation_id, '
      'director_model_provider, director_model_id, director_system_prompt, '
      'max_assistant_messages_per_round, assistant_detail_injection_mode, '
      'assistant_detail_injection_n, '
      'inject_group_members_into_assistant_system_prompt, '
      'pending_cap_assistant_message_id, assistant_messages_this_round, '
      'created_at, updated_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, '
      '?, ?);',
      [
        'grp-1',
        'Round table',
        null,
        'conv-2',
        'google',
        'gemini-2.5-pro',
        'You are the Director',
        4,
        'everyNUserMessages',
        3,
        0,
        null,
        2,
        groupCreatedSecs,
        groupCreatedSecs + 30,
      ],
    );
    db.execute(
      'INSERT INTO group_chat_member_rows (group_chat_id, member_key, '
      'assistant_id, sort_order) VALUES (?, ?, ?, ?), (?, ?, ?, ?);',
      ['grp-1', 'user', null, 0, 'grp-1', 'asst-1', 'asst-1', 1],
    );
    // Preferences: each value is JSON-encoded by the fork's store.
    db.execute(
      'INSERT INTO preference_rows (key, value, updated_at) VALUES '
      '(?, ?, ?), (?, ?, ?), (?, ?, ?), (?, ?, ?);',
      [
        'app_locale_v1',
        jsonEncode('zh_CN'),
        1,
        'thinking_budget_v1',
        jsonEncode(1024),
        2,
        'per_chat_model_enabled_v1',
        jsonEncode(true),
        3,
        'pinned_models_v1',
        jsonEncode(['a', 'b']),
        4,
      ],
    );
    db.execute(
      'INSERT INTO assistant_rows (id, name, avatar, use_assistant_avatar, '
      'use_assistant_name, background, chat_model_provider, chat_model_id, '
      'temperature, top_p, context_message_size, limit_context_messages, '
      'stream_output, thinking_budget, max_tokens, custom_headers_json, '
      'custom_body_json, system_prompt, message_template, '
      'preset_messages_json, search_enabled, mcp_server_ids_json, '
      'local_tool_ids_json, skill_ids_json, workspace_enabled, workspace_id, '
      'workspace_default_directories_json, auto_load_agents_md, '
      'regex_rules_json, enable_proactive_care, '
      'proactive_care_next_message_at, proactive_care_prompt, '
      'proactive_care_decision_prompt, '
      'proactive_care_decision_history_message_limit, enable_memory, '
      'memory_mode, enable_recent_chats_reference, '
      'recent_chats_summary_message_count, memory_record_prompt, docx_mode, '
      'pdf_mode, other_office_mode, ocr_mode, enable_time_injection, '
      'discoverable, handoff_id, handoff_description, sort_order, '
      'created_at, updated_at) '
      'VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, '
      '?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, '
      '?, ?, ?, ?, ?, ?);',
      [
        'asst-1',
        'Pal',
        'avatar.png',
        1,
        0,
        null,
        'google',
        'gemini-2.5-flash',
        0.7,
        0.95,
        32,
        1,
        1,
        2048,
        4096,
        '[{"X-Test":"1"}]',
        '[]',
        'You are Pal',
        '{{ message }}',
        '[{"id":"p1","role":"user","content":"hi"}]',
        0,
        '["mcp-a"]',
        '["calculator"]',
        '["skill-1"]',
        1,
        'ws-1',
        '{"dir-a":"/tmp/a"}',
        1,
        '[{"id":"r1","name":"trim","pattern":"a+","replacement":"b",'
            '"visualOnly":false,"replaceOnly":false,"enabled":true}]',
        1,
        nextMessageAtSecs,
        'care?',
        'decide?',
        12,
        1,
        'injection',
        1,
        9,
        'record me',
        'convert',
        'ocr',
        'direct',
        'always',
        1,
        0,
        'h-id',
        'h-desc',
        0,
        assistantCreatedSecs,
        assistantCreatedSecs + 5,
      ],
    );
  });

  /// Fork-style image compression prefs (`one_click_compress_*`).
  void seedImagePrefs({required bool enabled, required int quality}) {
    transaction((db) {
      db.execute(
        'INSERT INTO preference_rows (key, value, updated_at) VALUES '
        "('one_click_compress_enabled_v1', ?, 10), "
        "('one_click_compress_quality_v1', ?, 11), "
        "('one_click_compress_always_jpg_v1', 'true', 12), "
        "('one_click_compress_max_long_edge_v1', '1536', 13);",
        [jsonEncode(enabled), jsonEncode(quality)],
      );
    });
  }
}

void main() {
  late Directory workspace;
  late String dbPath;
  late V3FixtureBuilder fixture;

  setUp(() async {
    workspace = await Directory.systemTemp.createTemp('cuplivo-v3-reader');
    dbPath = '${workspace.path}/kelivo.sqlite';
    fixture = V3FixtureBuilder(dbPath);
  });

  tearDown(() async {
    if (await workspace.exists()) await workspace.delete(recursive: true);
  });

  String iso(int secondsUtc) => DateTime.fromMillisecondsSinceEpoch(
    secondsUtc * Duration.millisecondsPerSecond,
  ).toIso8601String();

  Map<String, dynamic> conversationById(
    CuplivoV3MigrationData data,
    String id,
  ) => (data.chatsJson['conversations'] as List)
      .cast<Map<String, dynamic>>()
      .firstWhere((entry) => entry['id'] == id);

  Map<String, dynamic> messageById(CuplivoV3MigrationData data, String id) =>
      (data.chatsJson['messages'] as List)
          .cast<Map<String, dynamic>>()
          .firstWhere((entry) => entry['id'] == id);

  test('happy path emits legacy chats.json v1 and settings shapes', () {
    fixture
      ..create()
      ..seedStandardRows();

    final data = CuplivoV3Reader.readDatabase(dbPath);

    expect(data.chatsJson['version'], 1);
    expect(data.chatsJson.keys, [
      'version',
      'conversations',
      'messages',
      'toolEvents',
      'geminiThoughtSigs',
      'groupChats',
      'groupMembers',
    ]);

    final conversations = (data.chatsJson['conversations'] as List)
        .cast<Map<String, dynamic>>();
    expect(conversations, hasLength(2));
    // Ordered by updated_at DESC: conv-1 (1700000600) is newer than conv-2.
    expect(conversations.map((c) => c['id']), ['conv-1', 'conv-2']);
    expect(conversations.first.keys.toList(), [
      'id',
      'title',
      'createdAt',
      'updatedAt',
      'messageIds',
      'isPinned',
      'mcpServerIds',
      'assistantId',
      'parentConversationId',
      'truncateIndex',
      'versionSelections',
      'summary',
      'lastSummarizedMessageCount',
      'chatSuggestions',
      'conversationKind',
      'workspaceDirectoryOverrides',
      'chatModelProvider',
      'chatModelId',
      'persistentQuickInstructionIds',
      'proactiveCareEnabledOverride',
      'proactiveCareNextMessageAt',
    ]);

    final first = conversationById(data, 'conv-1');
    expect(first['title'], 'First chat');
    expect(first['createdAt'], iso(V3FixtureBuilder.convCreatedSecs));
    expect(first['updatedAt'], iso(V3FixtureBuilder.convUpdatedSecs));
    // messageIds follow message_order ASC, not insertion or id order.
    expect(first['messageIds'], ['msg-u1', 'msg-a1']);
    expect(first['isPinned'], isTrue);
    expect(first['mcpServerIds'], ['mcp-a', 'mcp-b']); // ordinal ASC
    expect(first['assistantId'], 'asst-1');
    expect(first['parentConversationId'], isNull);
    expect(first['truncateIndex'], 2);
    expect(first['versionSelections'], {'g-1': 1});
    expect(first['summary'], 'A summary');
    expect(first['lastSummarizedMessageCount'], 7);
    expect(first['chatSuggestions'], ['Suggest A']);
    expect(first['conversationKind'], 'normal');
    expect(first['workspaceDirectoryOverrides'], {'dir-a': '/tmp/a'});
    expect(first['chatModelProvider'], 'openai');
    expect(first['chatModelId'], 'gpt-4o-mini');
    expect(first['persistentQuickInstructionIds'], ['qi-1']);
    expect(first['proactiveCareEnabledOverride'], isNull);
    expect(first['proactiveCareNextMessageAt'], isNull);

    final group = conversationById(data, 'conv-2');
    expect(group['conversationKind'], 'group');
    expect(group['proactiveCareEnabledOverride'], isFalse);
    expect(
      group['proactiveCareNextMessageAt'],
      iso(V3FixtureBuilder.nextMessageAtSecs),
    );
    expect(group['truncateIndex'], -1);
    expect(group['versionSelections'], <String, int>{});
    expect(group['messageIds'], ['msg-g1', 'msg-g2']);

    final messages = (data.chatsJson['messages'] as List)
        .cast<Map<String, dynamic>>();
    expect(messages, hasLength(4));
    expect(messages.first.keys.toList(), [
      'id',
      'role',
      'content',
      'timestamp',
      'modelId',
      'providerId',
      'totalTokens',
      'contextTokens',
      'conversationId',
      'isStreaming',
      'reasoningText',
      'reasoningStartAt',
      'reasoningFinishedAt',
      'translation',
      'reasoningSegmentsJson',
      'groupId',
      'subgroupId',
      'version',
      'promptTokens',
      'completionTokens',
      'cachedTokens',
      'durationMs',
      'isPreset',
      'speakerAssistantId',
      'requestAllowImagesApiRouting',
      'requestExtraBodyJson',
      'quoteJson',
      'quickInstructionInvocationsJson',
    ]);

    final assistantMessage = messageById(data, 'msg-a1');
    expect(assistantMessage['role'], 'assistant');
    expect(assistantMessage['timestamp'], iso(V3FixtureBuilder.msgTwoSecs));
    expect(assistantMessage['modelId'], 'gemini-2.5-flash');
    expect(assistantMessage['providerId'], 'gemini');
    expect(assistantMessage['totalTokens'], 120);
    expect(assistantMessage['contextTokens'], 8000);
    expect(assistantMessage['conversationId'], 'conv-1');
    expect(assistantMessage['isStreaming'], isFalse);
    expect(assistantMessage['reasoningText'], 'thinking hard');
    expect(
      assistantMessage['reasoningStartAt'],
      iso(V3FixtureBuilder.reasoningStartSecs),
    );
    expect(
      assistantMessage['reasoningFinishedAt'],
      iso(V3FixtureBuilder.reasoningFinishSecs),
    );
    expect(assistantMessage['translation'], 'translated');
    expect(assistantMessage['reasoningSegmentsJson'], '[{"text":"seg"}]');
    expect(assistantMessage['groupId'], 'grp-1');
    expect(assistantMessage['subgroupId'], 'sub-1');
    expect(assistantMessage['version'], 1);
    expect(assistantMessage['promptTokens'], 100);
    expect(assistantMessage['completionTokens'], 20);
    expect(assistantMessage['cachedTokens'], 5);
    expect(assistantMessage['durationMs'], 1234);
    expect(assistantMessage['isPreset'], isFalse);
    expect(assistantMessage['speakerAssistantId'], isNull);
    expect(
      assistantMessage['quoteJson'],
      '{"messageId":"msg-u1","text":"Hello there"}',
    );

    final quotedUser = messageById(data, 'msg-u1');
    expect(quotedUser['requestAllowImagesApiRouting'], isTrue);
    expect(quotedUser['requestExtraBodyJson'], '{"image":true}');
    expect(quotedUser['quickInstructionInvocationsJson'], '[{"id":"qi-1"}]');
    expect(messageById(data, 'msg-g1')['speakerAssistantId'], 'asst-1');

    expect(data.chatsJson['toolEvents'], {
      'msg-a1': [
        {'toolName': 'web_search', 'status': 'done'},
      ],
    });
    // The whitespace-only signature must be skipped.
    expect(data.chatsJson['geminiThoughtSigs'], {'msg-a1': 'sig-abc'});

    final groups = (data.chatsJson['groupChats'] as List)
        .cast<Map<String, dynamic>>();
    expect(groups, hasLength(1));
    expect(groups.single, {
      'id': 'grp-1',
      'name': 'Round table',
      'avatar': null,
      'conversationId': 'conv-2',
      'directorModelProvider': 'google',
      'directorModelId': 'gemini-2.5-pro',
      'directorSystemPrompt': 'You are the Director',
      'maxAssistantMessagesPerRound': 4,
      'assistantDetailInjectionMode': 'everyNUserMessages',
      'assistantDetailInjectionN': 3,
      'injectGroupMembersIntoAssistantSystemPrompt': false,
      'pendingCapAssistantMessageId': null,
      'assistantMessagesThisRound': 2,
      'createdAt': iso(V3FixtureBuilder.groupCreatedSecs),
      'updatedAt': iso(V3FixtureBuilder.groupCreatedSecs + 30),
    });
    final members = (data.chatsJson['groupMembers'] as List)
        .cast<Map<String, dynamic>>();
    expect(members, [
      {
        'groupChatId': 'grp-1',
        'memberKey': 'user',
        'assistantId': null,
        'sortOrder': 0,
      },
      {
        'groupChatId': 'grp-1',
        'memberKey': 'asst-1',
        'assistantId': 'asst-1',
        'sortOrder': 1,
      },
    ]);
  });

  test('settings decode JSON-encoded preferences and assistants', () {
    fixture
      ..create()
      ..seedStandardRows();

    final data = CuplivoV3Reader.readDatabase(dbPath);

    expect(data.settings['app_locale_v1'], 'zh_CN');
    expect(data.settings['thinking_budget_v1'], 1024);
    expect(data.settings['per_chat_model_enabled_v1'], isTrue);
    expect(data.settings['pinned_models_v1'], ['a', 'b']);

    final assistantsRaw = data.settings['assistants_v1'];
    expect(
      assistantsRaw,
      isA<String>(),
      reason: 'entity keys ride JSON strings',
    );
    final assistants = (jsonDecode(assistantsRaw! as String) as List)
        .cast<Map<String, dynamic>>();
    expect(assistants, hasLength(1));
    final assistant = assistants.single;
    expect(assistant['id'], 'asst-1');
    expect(assistant['name'], 'Pal');
    expect(assistant['avatar'], 'avatar.png');
    expect(assistant['useAssistantAvatar'], isTrue);
    expect(assistant['useAssistantName'], isFalse);
    expect(assistant['chatModelProvider'], 'google');
    expect(assistant['chatModelId'], 'gemini-2.5-flash');
    expect(assistant['temperature'], 0.7);
    expect(assistant['topP'], 0.95);
    expect(assistant['contextMessageSize'], 32);
    expect(assistant['limitContextMessages'], isTrue);
    expect(assistant['streamOutput'], isTrue);
    expect(assistant['thinkingBudget'], 2048);
    expect(assistant['maxTokens'], 4096);
    expect(assistant['systemPrompt'], 'You are Pal');
    expect(assistant['messageTemplate'], '{{ message }}');
    expect(assistant['searchEnabled'], isFalse);
    expect(assistant['mcpServerIds'], ['mcp-a']);
    expect(assistant['localToolIds'], ['calculator']);
    expect(assistant['skillIds'], ['skill-1']);
    expect(assistant['workspaceEnabled'], isTrue);
    expect(assistant['workspaceId'], 'ws-1');
    expect(assistant['workspaceDefaultDirectories'], {'dir-a': '/tmp/a'});
    expect(assistant['autoLoadAgentsMd'], isTrue);
    expect(assistant['customHeaders'], [
      {'X-Test': '1'},
    ]);
    expect(assistant['customBody'], isEmpty);
    expect(assistant['enableMemory'], isTrue);
    expect(assistant['memoryMode'], 'injection');
    expect(assistant['enableRecentChatsReference'], isTrue);
    expect(assistant['recentChatsSummaryMessageCount'], 9);
    expect(assistant['memoryRecordPrompt'], 'record me');
    expect(assistant['presetMessages'], [
      {'id': 'p1', 'role': 'user', 'content': 'hi'},
    ]);
    expect(assistant['regexRules'], [
      {
        'id': 'r1',
        'name': 'trim',
        'pattern': 'a+',
        'replacement': 'b',
        'visualOnly': false,
        'replaceOnly': false,
        'enabled': true,
      },
    ]);
    expect(assistant['enableProactiveCare'], isTrue);
    expect(
      assistant['proactiveCareNextMessageAt'],
      iso(V3FixtureBuilder.nextMessageAtSecs),
    );
    expect(assistant['proactiveCarePrompt'], 'care?');
    expect(assistant['proactiveCareDecisionPrompt'], 'decide?');
    expect(assistant['proactiveCareDecisionHistoryMessageLimit'], 12);
    // Schema v23 has both file-processing mode columns on assistant_rows.
    expect(assistant['docxMode'], 'convert');
    expect(assistant['pdfMode'], 'ocr');
    expect(assistant['otherOfficeMode'], 'direct');
    expect(assistant['ocrMode'], 'always');
    expect(assistant['enableTimeInjection'], isTrue);
    expect(assistant['appendCurrentTimeToUserMessage'], isTrue);
    expect(assistant['discoverable'], isFalse);
    expect(assistant['handoffId'], 'h-id');
    expect(assistant['handoffDescription'], 'h-desc');
    expect(assistant['createdAt'], iso(V3FixtureBuilder.assistantCreatedSecs));
    expect(
      assistant['updatedAt'],
      iso(V3FixtureBuilder.assistantCreatedSecs + 5),
    );
  });

  test('image settings translate to upstream keys', () {
    fixture
      ..create()
      ..seedStandardRows()
      ..seedImagePrefs(enabled: true, quality: 75);

    final data = CuplivoV3Reader.readDatabase(dbPath);

    expect(data.settings['image_upload_quality_v1'], 'custom');
    expect(data.settings['image_compress_custom_quality_v1'], 75);
    expect(data.settings['image_compress_transparent_enabled_v1'], isTrue);
    // Source keys survive untouched — the importer decides what to keep.
    expect(data.settings['one_click_compress_enabled_v1'], isTrue);
  });

  test('absent image prefs produce no upstream keys', () {
    fixture
      ..create()
      ..seedStandardRows();

    final data = CuplivoV3Reader.readDatabase(dbPath);
    expect(data.settings.containsKey('image_upload_quality_v1'), isFalse);
  });

  test('empty assistant table does not emit assistants_v1', () {
    fixture
      ..create()
      ..seedStandardRows()
      ..transaction((db) => db.execute('DELETE FROM assistant_rows;'));

    final data = CuplivoV3Reader.readDatabase(dbPath);
    expect(data.settings.containsKey('assistants_v1'), isFalse);
  });

  group('looksLikeV3Database', () {
    test('true for a v23 fixture', () {
      fixture
        ..create()
        ..seedStandardRows();
      expect(CuplivoV3Reader.looksLikeV3Database(dbPath), isTrue);
    });

    test('false for another user_version', () {
      fixture.create(userVersion: 3);
      expect(CuplivoV3Reader.looksLikeV3Database(dbPath), isFalse);
    });

    test('false for a non-sqlite file', () {
      File(dbPath).writeAsStringSync('not a database at all, honestly');
      expect(CuplivoV3Reader.looksLikeV3Database(dbPath), isFalse);
    });

    test('false for a missing path', () {
      expect(
        CuplivoV3Reader.looksLikeV3Database('${workspace.path}/nope.sqlite'),
        isFalse,
      );
    });
  });

  test('readDatabase names the missing table and wraps the cause', () {
    fixture
      ..create()
      ..seedStandardRows()
      ..transaction((db) {
        db.execute('PRAGMA foreign_keys = OFF;');
        db.execute('DROP TABLE message_rows;');
      });

    try {
      CuplivoV3Reader.readDatabase(dbPath);
      fail('expected CuplivoV3ReadException');
    } on CuplivoV3ReadException catch (error) {
      expect(error.table, 'message_rows');
      expect(error.message, contains('message_rows'));
      expect(error.toString(), contains('message_rows'));
    }
  });

  test('missing database file throws', () {
    expect(
      () => CuplivoV3Reader.readDatabase('${workspace.path}/gone.sqlite'),
      throwsA(isA<CuplivoV3ReadException>()),
    );
  });

  test('wrong user_version throws instead of guessing', () {
    fixture
      ..create(userVersion: 3)
      ..seedStandardRows();
    expect(
      () => CuplivoV3Reader.readDatabase(dbPath),
      throwsA(
        isA<CuplivoV3ReadException>().having(
          (e) => e.message,
          'message',
          contains('unexpected_user_version:3'),
        ),
      ),
    );
  });

  test('malformed JSON column fails fast', () {
    fixture
      ..create()
      ..seedStandardRows()
      ..transaction(
        (db) => db.execute(
          "UPDATE conversation_rows SET version_selections_json = '{oops' "
          "WHERE id = 'conv-1';",
        ),
      );

    expect(
      () => CuplivoV3Reader.readDatabase(dbPath),
      throwsA(
        isA<CuplivoV3ReadException>().having(
          (e) => e.message,
          'message',
          allOf(
            contains('malformed_json'),
            contains('version_selections_json'),
          ),
        ),
      ),
    );
  });

  test('source database is never modified', () {
    fixture
      ..create()
      ..seedStandardRows();
    final before = File(dbPath).readAsBytesSync();

    CuplivoV3Reader.readDatabase(dbPath);
    CuplivoV3Reader.looksLikeV3Database(dbPath);

    expect(File(dbPath).readAsBytesSync(), equals(before));
  });

  /// The migration service calls the reader through `Isolate.run`, so it must
  /// not touch Flutter bindings or leak its handle across the boundary.
  test('reader runs inside a spawned isolate', () async {
    fixture
      ..create()
      ..seedStandardRows();

    final data = await Isolate.run(() => CuplivoV3Reader.readDatabase(dbPath));
    expect(data.chatsJson['version'], 1);
    expect(data.chatsJson['conversations'], hasLength(2));
    expect(data.chatsJson['messages'], hasLength(4));
    expect(data.settings['thinking_budget_v1'], 1024);

    expect(
      await Isolate.run(() => CuplivoV3Reader.looksLikeV3Database(dbPath)),
      isTrue,
    );
  });
}
