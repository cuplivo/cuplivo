/// In-place Kelivo v2 → legacy compat converter tests.
///
/// All fixtures here are SYNTHETIC (fabricated rows/JSON) — no real user
/// data is ever committed to this repository.
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';

import 'package:Cuplivo/core/services/backup/kelivo_v2_compat_converter.dart';
import 'package:Cuplivo/core/services/backup/kelivo_v2_exception.dart';

const int microsBase = 1700000000000000; // synthetic epoch µs

Directory _makeExtractDir() {
  final dir = Directory.systemTemp.createTempSync('kelivo_v2_compat_test_');
  addTearDown(() => dir.deleteSync(recursive: true));
  return dir;
}

/// Builds a minimal-but-realistic upstream kelivo.db snapshot (synthetic).
void _writeKelivoDb(String dbPath) {
  final db = sqlite3.open(dbPath);
  db.execute('PRAGMA journal_mode = DELETE;');
  db.execute('''
    CREATE TABLE conversation_rows (
      id TEXT PRIMARY KEY, title TEXT, created_at INTEGER, updated_at INTEGER,
      is_pinned INTEGER, assistant_id TEXT, truncate_index INTEGER,
      version_selections_json TEXT, summary TEXT,
      last_summarized_message_count INTEGER, chat_suggestions_json TEXT,
      injected_memory_hash TEXT, last_memory_extracted_order INTEGER
    );
  ''');
  db.execute('''
    CREATE TABLE conversation_mcp_server_rows (
      conversation_id TEXT, server_id TEXT, ordinal INTEGER
    );
  ''');
  db.execute('''
    CREATE TABLE message_rows (
      id TEXT PRIMARY KEY, conversation_id TEXT, role TEXT, timestamp INTEGER,
      model_id TEXT, provider_id TEXT, total_tokens INTEGER,
      is_streaming INTEGER, reasoning_start_at INTEGER,
      reasoning_finished_at INTEGER, translation TEXT,
      reasoning_segments_json TEXT, group_id TEXT, version INTEGER,
      prompt_tokens INTEGER, completion_tokens INTEGER, cached_tokens INTEGER,
      duration_ms INTEGER, message_order INTEGER
    );
  ''');
  db.execute('''
    CREATE TABLE message_part_rows (
      part_id INTEGER PRIMARY KEY, conversation_id TEXT, revision_id TEXT,
      ordinal INTEGER, kind TEXT, payload TEXT
    );
  ''');
  db.execute('''
    CREATE TABLE provider_artifact_rows (
      revision_id TEXT, kind TEXT, payload TEXT
    );
  ''');
  db.execute('''
    CREATE TABLE asset_rows (
      id TEXT PRIMARY KEY, content_hash TEXT, path TEXT, byte_size INTEGER
    );
  ''');
  db.execute('''
    CREATE TABLE message_asset_rows (
      revision_id TEXT, asset_id TEXT
    );
  ''');

  db.execute(
    "INSERT INTO conversation_rows VALUES ('c1', 'Conv 1', "
    "$microsBase, ${microsBase + 2000000}, 1, 'a1', 3, "
    "'{\"m0\": 2}', NULL, 0, '[\"s1\"]', 'hash-1', 7);",
  );
  db.execute("INSERT INTO conversation_mcp_server_rows VALUES ('c1', 'srv1', 0);");

  db.execute(
    "INSERT INTO message_rows VALUES ('m0', 'c1', 'user', "
    "$microsBase + 1000000, NULL, NULL, NULL, 0, NULL, NULL, NULL, NULL, "
    "NULL, 0, NULL, NULL, NULL, NULL, 0);",
  );
  db.execute(
    "INSERT INTO message_rows VALUES ('m1', 'c1', 'assistant', "
    "$microsBase + 1500000, 'gpt', 'prov', 42, 0, ${microsBase + 1100000}, "
    "${microsBase + 1400000}, '译文', NULL, NULL, 2, 10, 32, 5, 900, 1);",
  );

  db.execute("INSERT INTO message_part_rows VALUES (1, 'c1', 'm0', 0, 'text', '你好');");
  db.execute(
    "INSERT INTO message_part_rows VALUES (2, 'c1', 'm1', 0, 'reasoning', '想一想');",
  );
  db.execute(
    "INSERT INTO message_part_rows VALUES (3, 'c1', 'm1', 1, 'text', '回答内容');",
  );
  db.execute(
    "INSERT INTO message_part_rows VALUES (4, 'c1', 'm1', 2, 'image', "
    "'{\"uri\": \"kelivo-file:///upload/test.png\"}');",
  );
  db.execute(
    "INSERT INTO message_part_rows VALUES (5, 'c1', 'm1', 3, 'tool_call', "
    "'{\"id\": \"t1\", \"name\": \"search\", \"arguments\": {\"q\": \"x\"}}');",
  );

  db.execute(
    "INSERT INTO provider_artifact_rows VALUES ('m1', "
    "'gemini_thought_signature', 'sig-blob');",
  );
  db.execute("INSERT INTO asset_rows VALUES ('as1', 'h', 'upload/test.png', 3);");
  db.execute("INSERT INTO message_asset_rows VALUES ('m1', 'as1');");
  db.close();
}

Map<String, dynamic> _assistantsBlob() => {
  'assistants_v1': jsonEncode([
    {
      'id': 'a1',
      'name': 'A',
      'presetMessages': jsonEncode([
        {'role': 'system', 'content': 'be nice'},
      ]),
      'allowPastConversationRecall': true,
    },
  ]),
};

void _writeSettings(String dirPath, Map<String, dynamic> settings) {
  File('$dirPath/settings.json').writeAsStringSync(jsonEncode(settings));
}

void _writeManifest(String dirPath, {int formatVersion = 2, String payloadKind = 'sqlite'}) {
  File('$dirPath/manifest.json').writeAsStringSync(jsonEncode({
    'format': 'kelivo-backup',
    'formatVersion': formatVersion,
    'payloadKind': payloadKind,
    'entries': <String, dynamic>{},
  }));
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('converts a full sqlite backup in place to the legacy layout', () async {
    final dir = _makeExtractDir();
    Directory('${dir.path}/database').createSync();
    _writeKelivoDb('${dir.path}/database/kelivo.db');
    _writeManifest(dir.path);
    _writeSettings(dir.path, {
      ..._assistantsBlob(),
      'memory_entries_v1': jsonEncode([
        {
          'id': 1,
          'scope': 'assistant',
          'status': 'active',
          'assistantId': 'a1',
          'content': '喜欢简洁回答',
          'createdAt': microsBase ~/ 1000,
          'migrationIds': <int>[],
        },
        {
          'id': 2,
          'scope': 'global',
          'status': 'active',
          'content': '使用中文',
          'createdAt': microsBase ~/ 1000 + 1,
          'migrationIds': <int>[],
        },
        {
          'id': 3,
          'scope': 'assistant',
          'status': 'archived',
          'assistantId': 'a1',
          'content': '过时记忆',
          'createdAt': microsBase ~/ 1000 + 2,
          'migrationIds': <int>[],
        },
        {
          'id': 4,
          'scope': 'assistant',
          'status': 'active',
          'assistantId': 'a1',
          'content': '取代旧记录',
          'createdAt': microsBase ~/ 1000 + 3,
          'migrationIds': [11],
        },
      ]),
      'assistant_memories_v1': jsonEncode([
        {'id': 11, 'assistantId': 'a1', 'content': '取代旧记录'},
        {'id': 12, 'assistantId': 'a1', 'content': '使用中文'},
        {'id': 13, 'assistantId': 'a1', 'content': '独特旧记忆'},
      ]),
      'search_services_v1': jsonEncode([
        {
          'id': 'searxng',
          'apiKey': 'primary-key',
          'apiKeys': <String>['pool-key-1', 'primary-key'],
        },
      ]),
      'double_key_v1': 1.0,
    });
    Directory('${dir.path}/upload').createSync();
    File('${dir.path}/upload/test.png').writeAsBytesSync([1, 2, 3]);

    final result = await convertKelivoV2BackupInPlace(dir.path);

    expect(result.settingsOnly, isFalse);
    expect(result.conversations, 1);
    expect(result.messages, 2);
    expect(result.toolEvents, 1);
    expect(result.geminiSignatures, 1);
    expect(result.drops['记忆：archived（旧版格式无此状态）'], 1);

    // manifest consumed, tombstones written
    expect(File('${dir.path}/manifest.json').existsSync(), isFalse);
    expect(File('${dir.path}/deleted.json').readAsStringSync(), '{}');

    // chats.json: legacy v1 layout with flattened parts
    final chats =
        jsonDecode(File('${dir.path}/chats.json').readAsStringSync())
            as Map<String, dynamic>;
    expect(chats['version'], 1);
    final convs = chats['conversations'] as List;
    expect(convs, hasLength(1));
    final conv = convs.first as Map<String, dynamic>;
    expect(conv['id'], 'c1');
    expect(conv['isPinned'], isTrue);
    expect(conv['mcpServerIds'], ['srv1']);
    expect(conv['messageIds'], ['m0', 'm1']);
    expect(conv['createdAt'], endsWith('Z'));
    expect(DateTime.parse(conv['createdAt'] as String).microsecondsSinceEpoch,
        microsBase);
    expect(conv['versionSelections'], {'m0': 2});

    final msgs = chats['messages'] as List;
    final m1 = msgs.firstWhere((m) => m['id'] == 'm1') as Map<String, dynamic>;
    expect(m1['content'], '回答内容\n[image:/upload/test.png]');
    expect(m1['reasoningText'], '想一想');
    expect(m1['translation'], '译文');
    expect(m1['totalTokens'], 42);
    expect(DateTime.parse(m1['reasoningStartAt'] as String)
            .microsecondsSinceEpoch,
        microsBase + 1100000);
    final m0 = msgs.first as Map<String, dynamic>;
    expect(m0['content'], '你好');

    final toolEvents = chats['toolEvents'] as Map<String, dynamic>;
    expect(toolEvents['m1'], hasLength(1));
    expect((toolEvents['m1'] as List).first['name'], 'search');
    expect(chats['geminiThoughtSigs'], {'m1': 'sig-blob'});

    // settings.json: surgery applied, pass-through keys intact
    final settings =
        jsonDecode(File('${dir.path}/settings.json').readAsStringSync())
            as Map<String, dynamic>;
    final assistants = jsonDecode(settings['assistants_v1'] as String) as List;
    final assistant = assistants.first as Map<String, dynamic>;
    expect(assistant['presetMessages'], isA<List>());
    expect(assistant['enableRecentChatsReference'], isTrue);

    // memory downgrade: new → legacy, dedupe + supersede rules
    expect(settings.containsKey('memory_entries_v1'), isFalse);
    final memories =
        jsonDecode(settings['assistant_memories_v1'] as String) as List;
    final contents = memories
        .map((m) => '${m['assistantId']}:${m['content']}')
        .toSet();
    expect(contents, contains('a1:喜欢简洁回答'));
    expect(contents, contains('a1:使用中文')); // global copied to assistant
    expect(contents, contains('a1:独特旧记忆')); // legacy kept
    expect(contents, contains('a1:取代旧记录')); // new-format record survives…
    // …while the superseded legacy twin (id 13, same content) is gone:
    expect(memories, hasLength(4));
    expect(contents, isNot(contains('a1:过时记忆'))); // archived dropped
    final converted = memories.firstWhere((m) => m['content'] == '喜欢简洁回答')
        as Map<String, dynamic>;
    expect(converted['id'], 14); // max legacy id (13) + 1

    // search services: string pool → ApiKeyConfig objects
    final services =
        jsonDecode(settings['search_services_v1'] as String) as List;
    final service = services.first as Map<String, dynamic>;
    final apiKeys = service['apiKeys'] as List;
    expect(apiKeys, hasLength(2));
    expect((apiKeys.first as Map)['key'], 'primary-key');
    expect((apiKeys.last as Map)['key'], 'pool-key-1');

    // double round-trip: Dart-native doubles survive re-encode
    expect(settings['double_key_v1'], 1.0);
  });

  test('settings-only backup writes no chats.json (no wipe risk)', () async {
    final dir = _makeExtractDir();
    _writeManifest(dir.path, payloadKind: 'settings-only');
    _writeSettings(dir.path, _assistantsBlob());

    final result = await convertKelivoV2BackupInPlace(dir.path);

    expect(result.settingsOnly, isTrue);
    expect(File('${dir.path}/chats.json').existsSync(), isFalse);
    expect(File('${dir.path}/manifest.json').existsSync(), isFalse);
  });

  test('unreadable database skips chats instead of writing an empty blob',
      () async {
    final dir = _makeExtractDir();
    _writeManifest(dir.path);
    _writeSettings(dir.path, _assistantsBlob());
    Directory('${dir.path}/database').createSync();
    File('${dir.path}/database/kelivo.db').writeAsBytesSync([0, 1, 2, 3]);

    final result = await convertKelivoV2BackupInPlace(dir.path);

    expect(result.settingsOnly, isTrue);
    expect(File('${dir.path}/chats.json').existsSync(), isFalse);
    expect(result.warnings, isNotEmpty);
  });

  test('unknown manifest / version throws the fallback exception', () async {
    final dir = _makeExtractDir();
    _writeManifest(dir.path, formatVersion: 99);
    expect(
      () => convertKelivoV2BackupInPlace(dir.path),
      throwsA(isA<KelivoV2BackupException>()),
    );

    final dir2 = _makeExtractDir();
    File('${dir2.path}/manifest.json').writeAsStringSync('not json');
    expect(
      () => convertKelivoV2BackupInPlace(dir2.path),
      throwsA(isA<KelivoV2BackupException>()),
    );
  });
}
