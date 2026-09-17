/// Reader for the old fork's database (`kelivo.sqlite`, Drift schema v23).
///
/// Produces in-memory payloads shaped exactly like the legacy backup files the
/// app's import APIs already consume: a `chats.json` v1 map and a flat
/// `settings.json` map. Pure Dart + `package:sqlite3` only — no Flutter
/// bindings — so [CuplivoV3Reader.readDatabase] is safe inside `Isolate.run`.
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:sqlite3/sqlite3.dart' as sqlite;

/// The `PRAGMA user_version` of every database this reader understands.
const int cuplivoV3SchemaVersion = 23;

/// Payloads read out of an old fork database, ready for the legacy import APIs.
class CuplivoV3MigrationData {
  final Map<String, dynamic> chatsJson;
  final Map<String, Object?> settings;

  const CuplivoV3MigrationData({
    required this.chatsJson,
    required this.settings,
  });
}

/// A structural problem while reading the source database.
///
/// [table] names the table whose read failed; it is empty when the failure is
/// not tied to one table (a malformed preference value, say). [cause] carries
/// the underlying error when there is one.
class CuplivoV3ReadException implements Exception {
  const CuplivoV3ReadException(this.message, {this.table = '', this.cause});

  final String message;
  final String table;
  final Object? cause;

  @override
  String toString() {
    final buffer = StringBuffer('CuplivoV3ReadException: $message');
    if (table.isNotEmpty) buffer.write(' (table: $table)');
    final error = cause;
    if (error != null) buffer.write(' cause: $error');
    return buffer.toString();
  }
}

/// Reads a Cuplivo v3 (fork lineage, Drift schema v23) database.
abstract final class CuplivoV3Reader {
  CuplivoV3Reader._();

  static const List<int> _magicHeader = [
    // "SQLite format 3\0"
    0x53, 0x51, 0x4c, 0x69, 0x74, 0x65, 0x20, 0x66, 0x6f, 0x72, 0x6d, 0x61,
    0x74, 0x20, 0x33, 0x00,
  ];

  /// Tables a full read needs. `conversation_mcp_server_rows` is deliberately
  /// absent: the fork heals its eight core tables only, so a partially healed
  /// v23 file can lack it, and an empty `mcpServerIds` is a faithful read.
  static const List<String> _requiredTables = [
    'conversation_rows',
    'message_rows',
    'tool_event_rows',
    'gemini_thought_signature_rows',
    'group_chat_rows',
    'group_chat_member_rows',
    'preference_rows',
    'assistant_rows',
  ];

  /// Quick probe: true when [dbPath] is a readable SQLite file whose
  /// `PRAGMA user_version` is exactly 23.
  static bool looksLikeV3Database(String dbPath) {
    try {
      if (!FileSystemEntity.isFileSync(dbPath)) return false;
      if (!_hasSqliteMagic(File(dbPath))) return false;
      final database = _openReadOnly(dbPath);
      try {
        return database.userVersion == cuplivoV3SchemaVersion;
      } finally {
        database.close();
      }
    } catch (_) {
      return false;
    }
  }

  /// Full read. Throws [CuplivoV3ReadException] on any structural problem
  /// (missing tables, undecodable JSON columns). Never writes to the source.
  static CuplivoV3MigrationData readDatabase(String dbPath) {
    if (!FileSystemEntity.isFileSync(dbPath)) {
      throw const CuplivoV3ReadException('database_file_missing');
    }
    final sqlite.Database database;
    try {
      database = _openReadOnly(dbPath);
    } catch (error) {
      throw CuplivoV3ReadException('cannot_open_database', cause: error);
    }
    try {
      final version = database.userVersion;
      if (version != cuplivoV3SchemaVersion) {
        throw CuplivoV3ReadException(
          'unexpected_user_version:$version',
          cause: 'expected $cuplivoV3SchemaVersion',
        );
      }
      final present = _tableNames(database);
      for (final table in _requiredTables) {
        if (!present.contains(table)) {
          throw CuplivoV3ReadException('missing_table:$table', table: table);
        }
      }
      return CuplivoV3MigrationData(
        chatsJson: _readChatsJson(database),
        settings: _readSettings(database),
      );
    } on CuplivoV3ReadException {
      rethrow;
    } catch (error) {
      throw CuplivoV3ReadException('read_failed', cause: error);
    } finally {
      database.close();
    }
  }

  // ===== chats.json =====

  static Map<String, dynamic> _readChatsJson(sqlite.Database database) {
    return <String, dynamic>{
      'version': 1,
      'conversations': _readConversations(database),
      'messages': _readMessages(database),
      'toolEvents': _readToolEvents(database),
      'geminiThoughtSigs': _readGeminiThoughtSignatures(database),
      // Reserved for a later feature phase: today's importer ignores both.
      'groupChats': _readGroupChats(database),
      'groupMembers': _readGroupMembers(database),
    };
  }

  static List<Map<String, dynamic>> _readConversations(
    sqlite.Database database,
  ) {
    final rows = _select(
      database,
      'SELECT id, title, created_at, updated_at, is_pinned, assistant_id, '
      'truncate_index, version_selections_json, summary, '
      'last_summarized_message_count, chat_suggestions_json, '
      'parent_conversation_id, conversation_kind, '
      'workspace_directory_overrides_json, chat_model_provider, chat_model_id, '
      'persistent_quick_instruction_ids_json, proactive_care_enabled_override, '
      'proactive_care_next_message_at '
      'FROM conversation_rows ORDER BY updated_at DESC, id;',
      table: 'conversation_rows',
    );
    return [
      for (final row in rows)
        <String, dynamic>{
          'id': _requiredString(row['id'], 'conversation_rows.id'),
          'title': _requiredString(row['title'], 'conversation_rows.title'),
          'createdAt': _isoFromSeconds(row['created_at']),
          'updatedAt': _isoFromSeconds(row['updated_at']),
          'messageIds': _messageIdsFor(database, '${row['id']}'),
          'isPinned': row['is_pinned'] == 1,
          'mcpServerIds': _mcpServerIds(database, '${row['id']}'),
          'assistantId': _asStringOrNull(row['assistant_id']),
          'parentConversationId': _asStringOrNull(
            row['parent_conversation_id'],
          ),
          'truncateIndex': _asInt(row['truncate_index']) ?? -1,
          'versionSelections': _versionSelections(
            _asStringOrNull(row['version_selections_json']) ?? '{}',
          ),
          'summary': _asStringOrNull(row['summary']),
          'lastSummarizedMessageCount':
              _asInt(row['last_summarized_message_count']) ?? 0,
          'chatSuggestions': _decodedStringList(
            _asStringOrNull(row['chat_suggestions_json']) ?? '[]',
            column: 'conversation_rows.chat_suggestions_json',
          ),
          'conversationKind':
              _asStringOrNull(row['conversation_kind']) ?? 'normal',
          'workspaceDirectoryOverrides': _decodedStringMap(
            _asStringOrNull(row['workspace_directory_overrides_json']) ?? '{}',
            column: 'conversation_rows.workspace_directory_overrides_json',
          ),
          'chatModelProvider': _asStringOrNull(row['chat_model_provider']),
          'chatModelId': _asStringOrNull(row['chat_model_id']),
          'persistentQuickInstructionIds': _decodedStringList(
            _asStringOrNull(row['persistent_quick_instruction_ids_json']) ??
                '[]',
            column: 'conversation_rows.persistent_quick_instruction_ids_json',
          ),
          'proactiveCareEnabledOverride': _asBoolOrNull(
            row['proactive_care_enabled_override'],
          ),
          'proactiveCareNextMessageAt': _isoFromSecondsOrNull(
            row['proactive_care_next_message_at'],
          ),
        },
    ];
  }

  static List<String> _mcpServerIds(sqlite.Database database, String id) {
    if (!_hasTable(database, 'conversation_mcp_server_rows')) {
      return const <String>[];
    }
    final rows = _select(
      database,
      'SELECT server_id FROM conversation_mcp_server_rows '
      'WHERE conversation_id = ? ORDER BY ordinal ASC;',
      arguments: [id],
      table: 'conversation_mcp_server_rows',
    );
    return [
      for (final row in rows)
        _requiredString(row['server_id'], 'conversation_mcp_server_rows.id'),
    ];
  }

  /// Message ids in display order: the fork's `ORDER BY message_order ASC`,
  /// plus the id tie-break the current build applies, so the emitted order
  /// survives the importer's reference validation.
  static List<String> _messageIdsFor(sqlite.Database database, String id) {
    final rows = _select(
      database,
      'SELECT id FROM message_rows WHERE conversation_id = ? '
      'ORDER BY message_order ASC, id ASC;',
      arguments: [id],
      table: 'message_rows',
    );
    return [for (final row in rows) '${row['id']}'];
  }

  static List<Map<String, dynamic>> _readMessages(sqlite.Database database) {
    final rows = _select(
      database,
      'SELECT id, role, content, timestamp, model_id, provider_id, '
      'total_tokens, context_tokens, conversation_id, is_streaming, '
      'reasoning_text, reasoning_start_at, reasoning_finished_at, '
      'translation, reasoning_segments_json, group_id, subgroup_id, version, '
      'prompt_tokens, completion_tokens, cached_tokens, duration_ms, '
      'is_preset, speaker_assistant_id, request_allow_images_api_routing, '
      'request_extra_body_json, quote_json, '
      'quick_instruction_invocations_json '
      'FROM message_rows ORDER BY conversation_id ASC, message_order ASC, '
      'id ASC;',
      table: 'message_rows',
    );
    return [
      for (final row in rows)
        <String, dynamic>{
          'id': _requiredString(row['id'], 'message_rows.id'),
          'role': _requiredString(row['role'], 'message_rows.role'),
          'content': _requiredString(row['content'], 'message_rows.content'),
          'timestamp': _isoFromSeconds(row['timestamp']),
          'modelId': _asStringOrNull(row['model_id']),
          'providerId': _asStringOrNull(row['provider_id']),
          'totalTokens': _asInt(row['total_tokens']),
          'contextTokens': _asInt(row['context_tokens']),
          'conversationId': _requiredString(
            row['conversation_id'],
            'message_rows.conversation_id',
          ),
          'isStreaming': row['is_streaming'] == 1,
          'reasoningText': _asStringOrNull(row['reasoning_text']),
          'reasoningStartAt': _isoFromSecondsOrNull(row['reasoning_start_at']),
          'reasoningFinishedAt': _isoFromSecondsOrNull(
            row['reasoning_finished_at'],
          ),
          'translation': _asStringOrNull(row['translation']),
          'reasoningSegmentsJson': _asStringOrNull(
            row['reasoning_segments_json'],
          ),
          'groupId': _asStringOrNull(row['group_id']),
          'subgroupId': _asStringOrNull(row['subgroup_id']),
          'version': _asInt(row['version']) ?? 0,
          'promptTokens': _asInt(row['prompt_tokens']),
          'completionTokens': _asInt(row['completion_tokens']),
          'cachedTokens': _asInt(row['cached_tokens']),
          'durationMs': _asInt(row['duration_ms']),
          'isPreset': row['is_preset'] == 1,
          'speakerAssistantId': _asStringOrNull(row['speaker_assistant_id']),
          'requestAllowImagesApiRouting': _asBoolOrNull(
            row['request_allow_images_api_routing'],
          ),
          'requestExtraBodyJson': _asStringOrNull(
            row['request_extra_body_json'],
          ),
          'quoteJson': _asStringOrNull(row['quote_json']),
          'quickInstructionInvocationsJson': _asStringOrNull(
            row['quick_instruction_invocations_json'],
          ),
        },
    ];
  }

  static Map<String, List<Map<String, dynamic>>> _readToolEvents(
    sqlite.Database database,
  ) {
    final rows = _select(
      database,
      'SELECT message_id, events_json FROM tool_event_rows '
      'ORDER BY message_id;',
      table: 'tool_event_rows',
    );
    final result = <String, List<Map<String, dynamic>>>{};
    for (final row in rows) {
      final messageId = _requiredString(
        row['message_id'],
        'tool_event_rows.message_id',
      );
      final decoded = _jsonDecode(
        _requiredString(row['events_json'], 'tool_event_rows.events_json'),
        'tool_event_rows.events_json',
      );
      if (decoded is! List) {
        throw const CuplivoV3ReadException(
          'expected_json_list:tool_event_rows.events_json',
          table: 'tool_event_rows',
        );
      }
      result[messageId] = _objectList(decoded, 'tool_event_rows.events_json');
    }
    return result;
  }

  static Map<String, String> _readGeminiThoughtSignatures(
    sqlite.Database database,
  ) {
    final rows = _select(
      database,
      'SELECT message_id, signature FROM gemini_thought_signature_rows '
      'ORDER BY message_id;',
      table: 'gemini_thought_signature_rows',
    );
    final result = <String, String>{};
    for (final row in rows) {
      final signature = (row['signature'] as String?)?.trim();
      if (signature == null || signature.isEmpty) continue;
      final messageId = _requiredString(
        row['message_id'],
        'gemini_thought_signature_rows.message_id',
      );
      result[messageId] = signature;
    }
    return result;
  }

  static List<Map<String, dynamic>> _readGroupChats(sqlite.Database database) {
    final rows = _select(
      database,
      'SELECT id, name, avatar, conversation_id, director_model_provider, '
      'director_model_id, director_system_prompt, '
      'max_assistant_messages_per_round, assistant_detail_injection_mode, '
      'assistant_detail_injection_n, '
      'inject_group_members_into_assistant_system_prompt, '
      'pending_cap_assistant_message_id, assistant_messages_this_round, '
      'created_at, updated_at FROM group_chat_rows ORDER BY updated_at DESC, '
      'id;',
      table: 'group_chat_rows',
    );
    return [
      for (final row in rows)
        <String, dynamic>{
          'id': _requiredString(row['id'], 'group_chat_rows.id'),
          'name': _requiredString(row['name'], 'group_chat_rows.name'),
          'avatar': _asStringOrNull(row['avatar']),
          'conversationId': _requiredString(
            row['conversation_id'],
            'group_chat_rows.conversation_id',
          ),
          'directorModelProvider': _asStringOrNull(
            row['director_model_provider'],
          ),
          'directorModelId': _asStringOrNull(row['director_model_id']),
          'directorSystemPrompt': _requiredString(
            row['director_system_prompt'],
            'group_chat_rows.director_system_prompt',
          ),
          'maxAssistantMessagesPerRound':
              _asInt(row['max_assistant_messages_per_round']) ?? 3,
          'assistantDetailInjectionMode': _injectionMode(
            _asStringOrNull(row['assistant_detail_injection_mode']),
          ),
          'assistantDetailInjectionN':
              _asInt(row['assistant_detail_injection_n']) ?? 5,
          'injectGroupMembersIntoAssistantSystemPrompt':
              row['inject_group_members_into_assistant_system_prompt'] != 0,
          'pendingCapAssistantMessageId': _asStringOrNull(
            row['pending_cap_assistant_message_id'],
          ),
          'assistantMessagesThisRound':
              _asInt(row['assistant_messages_this_round']) ?? 0,
          'createdAt': _isoFromSeconds(row['created_at']),
          'updatedAt': _isoFromSeconds(row['updated_at']),
        },
    ];
  }

  static List<Map<String, dynamic>> _readGroupMembers(
    sqlite.Database database,
  ) {
    final rows = _select(
      database,
      'SELECT group_chat_id, member_key, assistant_id, sort_order '
      'FROM group_chat_member_rows ORDER BY group_chat_id ASC, '
      'sort_order ASC, member_key ASC;',
      table: 'group_chat_member_rows',
    );
    return [
      for (final row in rows)
        <String, dynamic>{
          'groupChatId': _requiredString(
            row['group_chat_id'],
            'group_chat_member_rows.group_chat_id',
          ),
          'memberKey': _requiredString(
            row['member_key'],
            'group_chat_member_rows.member_key',
          ),
          'assistantId': _asStringOrNull(row['assistant_id']),
          'sortOrder': _asInt(row['sort_order']) ?? 0,
        },
    ];
  }

  static const Set<String> _injectionModes = {
    'beforeSystemPrompt',
    'appendIntoSystemPrompt',
    'endOfFirstUserMessage',
    'endOfEveryUserMessage',
    'endOfEveryUserAndAssistantMessage',
    'everyNUserMessages',
    'everyNUserAndAssistantMessages',
  };

  /// Unknown or empty values normalize to the fork's default mode, matching
  /// `AssistantDetailInjectionModeX.fromStorage`.
  static String _injectionMode(String? raw) =>
      raw != null && _injectionModes.contains(raw)
      ? raw
      : 'endOfEveryUserMessage';

  // ===== settings.json =====

  static Map<String, Object?> _readSettings(sqlite.Database database) {
    final rows = _select(
      database,
      'SELECT key, value FROM preference_rows ORDER BY key;',
      table: 'preference_rows',
    );
    final settings = <String, Object?>{};
    for (final row in rows) {
      final key = _requiredString(row['key'], 'preference_rows.key');
      final encoded = _requiredString(row['value'], 'preference_rows.value');
      // preference_rows holds each value JSON-encoded: the fork's
      // BusinessRepository.write does `jsonEncode(normalized)` over a
      // bool / int / double / String / List<String>.
      final decoded = _jsonDecode(encoded, 'preference_rows.value:$key');
      if (decoded == null) {
        throw CuplivoV3ReadException(
          'business_preference_value:$key',
          table: 'preference_rows',
        );
      }
      settings[key] = decoded;
    }
    final assistants = _readAssistants(database);
    if (assistants.isNotEmpty) {
      // Entity keys ride the payload as a JSON string — the shape legacy
      // settings.json used and what the importer's validator requires.
      settings['assistants_v1'] = jsonEncode(assistants);
    }
    return settings..addAll(_translateImageSettingsToUpstream(settings));
  }

  static List<Map<String, dynamic>> _readAssistants(sqlite.Database database) {
    final rows = _select(
      database,
      'SELECT id, name, avatar, use_assistant_avatar, use_assistant_name, '
      'background, chat_model_provider, chat_model_id, temperature, top_p, '
      'context_message_size, limit_context_messages, stream_output, '
      'thinking_budget, max_tokens, custom_headers_json, custom_body_json, '
      'system_prompt, message_template, preset_messages_json, search_enabled, '
      'mcp_server_ids_json, local_tool_ids_json, skill_ids_json, '
      'workspace_enabled, workspace_id, workspace_default_directories_json, '
      'auto_load_agents_md, regex_rules_json, enable_proactive_care, '
      'proactive_care_next_message_at, proactive_care_prompt, '
      'proactive_care_decision_prompt, '
      'proactive_care_decision_history_message_limit, enable_memory, '
      'memory_mode, enable_recent_chats_reference, '
      'recent_chats_summary_message_count, memory_record_prompt, docx_mode, '
      'pdf_mode, other_office_mode, ocr_mode, enable_time_injection, '
      'discoverable, handoff_id, handoff_description, sort_order, created_at, '
      'updated_at FROM assistant_rows ORDER BY sort_order ASC, id ASC;',
      table: 'assistant_rows',
    );
    return [
      for (final row in rows)
        <String, dynamic>{
          'id': _requiredString(row['id'], 'assistant_rows.id'),
          'name': _requiredString(row['name'], 'assistant_rows.name'),
          'avatar': _asStringOrNull(row['avatar']),
          'useAssistantAvatar': row['use_assistant_avatar'] == 1,
          'useAssistantName': row['use_assistant_name'] == 1,
          'chatModelProvider': _asStringOrNull(row['chat_model_provider']),
          'chatModelId': _asStringOrNull(row['chat_model_id']),
          'temperature': _asDouble(row['temperature']),
          'topP': _asDouble(row['top_p']),
          'contextMessageSize': _asInt(row['context_message_size']) ?? 64,
          'limitContextMessages': row['limit_context_messages'] == 1,
          'streamOutput': row['stream_output'] == 1,
          'thinkingBudget': _asInt(row['thinking_budget']),
          'maxTokens': _asInt(row['max_tokens']),
          'systemPrompt': _requiredString(
            row['system_prompt'],
            'assistant_rows.system_prompt',
          ),
          'messageTemplate': _requiredString(
            row['message_template'],
            'assistant_rows.message_template',
          ),
          'searchEnabled': row['search_enabled'] == 1,
          'mcpServerIds': _decodedStringList(
            _asStringOrNull(row['mcp_server_ids_json']) ?? '[]',
            column: 'assistant_rows.mcp_server_ids_json',
          ),
          'localToolIds': _decodedStringList(
            _asStringOrNull(row['local_tool_ids_json']) ?? '[]',
            column: 'assistant_rows.local_tool_ids_json',
          ),
          'skillIds': _decodedStringList(
            _asStringOrNull(row['skill_ids_json']) ?? '[]',
            column: 'assistant_rows.skill_ids_json',
          ),
          'workspaceEnabled': row['workspace_enabled'] == 1,
          'workspaceId': _asStringOrNull(row['workspace_id']),
          'workspaceDefaultDirectories': _decodedStringMap(
            _asStringOrNull(row['workspace_default_directories_json']) ?? '{}',
            column: 'assistant_rows.workspace_default_directories_json',
          ),
          'autoLoadAgentsMd': row['auto_load_agents_md'] == 1,
          'background': _asStringOrNull(row['background']),
          'customHeaders': _decodedObjectList(
            _asStringOrNull(row['custom_headers_json']) ?? '[]',
            column: 'assistant_rows.custom_headers_json',
          ),
          'customBody': _decodedObjectList(
            _asStringOrNull(row['custom_body_json']) ?? '[]',
            column: 'assistant_rows.custom_body_json',
          ),
          'enableMemory': row['enable_memory'] == 1,
          'memoryMode': _requiredString(
            row['memory_mode'],
            'assistant_rows.memory_mode',
          ),
          'enableRecentChatsReference':
              row['enable_recent_chats_reference'] == 1,
          'recentChatsSummaryMessageCount':
              _asInt(row['recent_chats_summary_message_count']) ?? 5,
          'memoryRecordPrompt': _requiredString(
            row['memory_record_prompt'],
            'assistant_rows.memory_record_prompt',
          ),
          'presetMessages': _decodedObjectList(
            _asStringOrNull(row['preset_messages_json']) ?? '[]',
            column: 'assistant_rows.preset_messages_json',
          ),
          'regexRules': _decodedObjectList(
            _asStringOrNull(row['regex_rules_json']) ?? '[]',
            column: 'assistant_rows.regex_rules_json',
          ),
          'enableProactiveCare': row['enable_proactive_care'] == 1,
          'proactiveCareNextMessageAt': _isoFromSecondsOrNull(
            row['proactive_care_next_message_at'],
          ),
          'proactiveCarePrompt': _requiredString(
            row['proactive_care_prompt'],
            'assistant_rows.proactive_care_prompt',
          ),
          'proactiveCareDecisionPrompt': _requiredString(
            row['proactive_care_decision_prompt'],
            'assistant_rows.proactive_care_decision_prompt',
          ),
          'proactiveCareDecisionHistoryMessageLimit': _asInt(
            row['proactive_care_decision_history_message_limit'],
          ),
          'docxMode': _requiredString(
            row['docx_mode'],
            'assistant_rows.docx_mode',
          ),
          'pdfMode': _requiredString(
            row['pdf_mode'],
            'assistant_rows.pdf_mode',
          ),
          'otherOfficeMode': _requiredString(
            row['other_office_mode'],
            'assistant_rows.other_office_mode',
          ),
          'ocrMode': _requiredString(
            row['ocr_mode'],
            'assistant_rows.ocr_mode',
          ),
          'enableTimeInjection': row['enable_time_injection'] == 1,
          // The fork's toJson aliases the two: same source column.
          'appendCurrentTimeToUserMessage': row['enable_time_injection'] == 1,
          'discoverable': row['discoverable'] == 1,
          'handoffId': _asStringOrNull(row['handoff_id']),
          'handoffDescription': _asStringOrNull(row['handoff_description']),
          'createdAt': _isoFromSeconds(row['created_at']),
          'updatedAt': _isoFromSeconds(row['updated_at']),
        },
    ];
  }

  // ===== image settings translation =====

  // Ported from the fork's KelivoImageSettingsMapper.translateToUpstream
  // (lib/core/services/backup/kelivo_image_settings_mapper.dart). The fork
  // persisted four orthogonal `one_click_compress_*` params; the current build
  // reads `image_upload_quality_v1` (+ custom quality / transparent toggle),
  // so translating keeps the user's compression intent under known keys.
  static const String _upstreamQualityKey = 'image_upload_quality_v1';
  static const String _upstreamCustomQualityKey =
      'image_compress_custom_quality_v1';
  static const String _upstreamTransparentKey =
      'image_compress_transparent_enabled_v1';
  static const String _enabledKey = 'one_click_compress_enabled_v1';
  static const String _qualityKey = 'one_click_compress_quality_v1';
  static const String _alwaysJpgKey = 'one_click_compress_always_jpg_v1';

  // Fork quality bounds and upstream defaults, mirrored from the mapper.
  static const int _minQuality = 50;
  static const int _maxQuality = 95;
  static const int _defaultCustomQuality = 85;

  static Map<String, Object?> _translateImageSettingsToUpstream(
    Map<String, Object?> prefs,
  ) {
    final enabled = prefs[_enabledKey];
    if (enabled is! bool) return const {};
    final quality = prefs[_qualityKey];
    final alwaysJpgRaw = prefs[_alwaysJpgKey];
    return <String, Object?>{
      _upstreamQualityKey: enabled ? 'custom' : 'original',
      _upstreamCustomQualityKey: quality is int
          ? _clampQuality(quality)
          : _defaultCustomQuality,
      _upstreamTransparentKey: alwaysJpgRaw is bool && alwaysJpgRaw,
    };
  }

  /// Upstream clamps custom quality to 10..100 on load, and its `custom`
  /// preset fixes the long edge at 1568 px. The fork's own bounds are tighter,
  /// so an out-of-range stored value is pulled back into them here rather than
  /// being reshaped differently by the target app.
  static int _clampQuality(int quality) {
    if (quality < _minQuality) return _minQuality;
    if (quality > _maxQuality) return _maxQuality;
    return quality;
  }

  // ===== SQLite access =====

  static sqlite.Database _openReadOnly(String dbPath) => sqlite.sqlite3.open(
    File(dbPath).absolute.path,
    mode: sqlite.OpenMode.readOnly,
  );

  static bool _hasSqliteMagic(File file) {
    if (file.lengthSync() < _magicHeader.length) return false;
    final handle = file.openSync(mode: FileMode.read);
    try {
      final header = Uint8List(_magicHeader.length);
      if (handle.readIntoSync(header) < _magicHeader.length) return false;
      for (var i = 0; i < _magicHeader.length; i++) {
        if (header[i] != _magicHeader[i]) return false;
      }
      return true;
    } finally {
      handle.closeSync();
    }
  }

  static Set<String> _tableNames(sqlite.Database database) {
    final result = <String>{};
    for (final row in database.select(
      "SELECT name FROM sqlite_master WHERE type = 'table';",
    )) {
      result.add('${row['name']}');
    }
    return result;
  }

  static bool _hasTable(sqlite.Database database, String table) =>
      _tableNames(database).contains(table);

  static List<sqlite.Row> _select(
    sqlite.Database database,
    String sql, {
    List<Object?> arguments = const [],
    required String table,
  }) {
    try {
      return database.select(sql, arguments);
    } catch (error) {
      throw CuplivoV3ReadException(
        'query_failed:$table',
        table: table,
        cause: error,
      );
    }
  }

  // ===== Value coercion =====

  static String _requiredString(Object? value, String column) {
    if (value is String) return value;
    if (value == null) {
      throw CuplivoV3ReadException('null_required_column:$column');
    }
    return '$value';
  }

  static String? _asStringOrNull(Object? value) {
    if (value == null) return null;
    if (value is String) return value;
    return '$value';
  }

  static int? _asInt(Object? value) {
    if (value == null) return null;
    if (value is int) return value;
    if (value is num) return value.toInt();
    throw CuplivoV3ReadException('not_an_integer:$value');
  }

  static double? _asDouble(Object? value) {
    if (value == null) return null;
    if (value is double) return value;
    if (value is num) return value.toDouble();
    throw CuplivoV3ReadException('not_a_double:$value');
  }

  static bool? _asBoolOrNull(Object? value) {
    if (value == null) return null;
    if (value is int) return value == 1;
    if (value is bool) return value;
    throw CuplivoV3ReadException('not_a_boolean:$value');
  }

  /// Drift stores DateTime as INTEGER unix seconds by default (the fork
  /// declares no DateStorageMode override), and its own row mapper reads that
  /// back as a *local* DateTime. Emitting the ISO string of the same local
  /// instant keeps timestamps identical to what the fork exported.
  static String _isoFromSeconds(Object? value) {
    final seconds = _asInt(value);
    if (seconds == null) {
      throw const CuplivoV3ReadException('null_datetime_column');
    }
    return _isoFromSecondsValue(seconds);
  }

  static String? _isoFromSecondsOrNull(Object? value) {
    final seconds = _asInt(value);
    return seconds == null ? null : _isoFromSecondsValue(seconds);
  }

  static String _isoFromSecondsValue(int seconds) {
    return DateTime.fromMillisecondsSinceEpoch(
      seconds * Duration.millisecondsPerSecond,
    ).toIso8601String();
  }

  static Object? _jsonDecode(String encoded, String column) {
    try {
      return jsonDecode(encoded);
    } on FormatException catch (error) {
      throw CuplivoV3ReadException('malformed_json:$column', cause: error);
    }
  }

  /// Mirrors the fork's lenient `_decodeStringIntMap`: a non-map decodes to
  /// `{}`, but malformed JSON fails fast. Values may be numbers or numeric
  /// strings, as the fork tolerated both.
  static Map<String, int> _versionSelections(String raw) {
    final decoded = _jsonDecode(
      raw,
      'conversation_rows.version_selections_json',
    );
    if (decoded is! Map) return <String, int>{};
    final result = <String, int>{};
    for (final entry in decoded.entries) {
      final value = entry.value;
      result['${entry.key}'] = value is num
          ? value.toInt()
          : int.parse('${entry.value}');
    }
    return result;
  }

  /// Mirrors the fork's `_decodeStringList`: a wrong shape yields an empty
  /// list rather than an error — only unparseable JSON fails.
  static List<String> _decodedStringList(String raw, {required String column}) {
    final decoded = _jsonDecode(raw, column);
    if (decoded is! List) return const <String>[];
    return [for (final value in decoded) '$value'];
  }

  /// Strict, like the fork's `_decodeStringStringMap`: every key and value must
  /// be a string, otherwise the read fails instead of silently dropping data.
  static Map<String, String> _decodedStringMap(
    String raw, {
    required String column,
  }) {
    final decoded = _jsonDecode(raw, column);
    if (decoded is! Map) {
      throw CuplivoV3ReadException('expected_json_object:$column');
    }
    final result = <String, String>{};
    for (final entry in decoded.entries) {
      final key = entry.key;
      final value = entry.value;
      if (key is! String || value is! String) {
        throw CuplivoV3ReadException(
          'expected_string_entries:$column',
          cause: '$key: $value',
        );
      }
      result[key] = value;
    }
    return result;
  }

  /// Assistant JSON columns hold lists of objects. The fork's decoders accept
  /// whatever is there, but a half-parsed assistant would be silent data loss,
  /// so a wrong shape fails the read.
  static List<Map<String, dynamic>> _decodedObjectList(
    String raw, {
    required String column,
  }) {
    final decoded = _jsonDecode(raw, column);
    if (decoded is! List) {
      throw CuplivoV3ReadException('expected_json_list:$column');
    }
    return _objectList(decoded, column);
  }

  static List<Map<String, dynamic>> _objectList(
    List<Object?> decoded,
    String column,
  ) {
    final result = <Map<String, dynamic>>[];
    for (final entry in decoded) {
      if (entry is! Map) {
        throw CuplivoV3ReadException(
          'expected_json_object:$column',
          cause: '${entry.runtimeType}',
        );
      }
      result.add(_stringKeyedMap(entry));
    }
    return result;
  }

  static Map<String, dynamic> _stringKeyedMap(Map<dynamic, dynamic> raw) {
    return raw.map((key, value) => MapEntry<String, dynamic>('$key', value));
  }
}
