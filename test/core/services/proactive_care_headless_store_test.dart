import 'dart:io';

import 'package:Cuplivo/core/models/conversation.dart';
import 'package:Cuplivo/core/services/proactive_care_message_flow.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart' as sqlite;

void main() {
  late Directory tempDirectory;
  late Future<String> Function() originalPathProvider;

  setUp(() async {
    await ProactiveCareHeadlessChatStore.close();
    originalPathProvider = ProactiveCareHeadlessChatStore.dataDirPathProvider;
    tempDirectory = await Directory.systemTemp.createTemp(
      'cuplivo-proactive-headless-',
    );
    ProactiveCareHeadlessChatStore.dataDirPathProvider = () async =>
        tempDirectory.path;
  });

  tearDown(() async {
    await ProactiveCareHeadlessChatStore.close();
    ProactiveCareHeadlessChatStore.dataDirPathProvider = originalPathProvider;
    if (await tempDirectory.exists()) {
      await tempDirectory.delete(recursive: true);
    }
  });

  test('recent references and exact load map persisted messages', () async {
    final database = sqlite.sqlite3.open(
      p.join(tempDirectory.path, 'kelivo.sqlite'),
    );
    database.execute('''
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
  parent_conversation_id TEXT NULL,
  conversation_kind TEXT NOT NULL DEFAULT 'normal',
  proactive_care_enabled_override INTEGER NULL,
  proactive_care_next_message_at INTEGER NULL
);
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
  group_id TEXT NULL,
  subgroup_id TEXT NULL,
  version INTEGER NOT NULL DEFAULT 0,
  message_order INTEGER NOT NULL,
  is_preset INTEGER NOT NULL DEFAULT 0
);
''');

    const baseTimestamp = 1787011200;

    void insertConversation({
      required String id,
      required String title,
      required int updatedAt,
      String assistantId = 'assistant-1',
      String kind = Conversation.kindNormal,
      String? summary,
    }) {
      database.execute(
        'INSERT INTO conversation_rows '
        '(id, title, created_at, updated_at, assistant_id, summary, '
        'conversation_kind) VALUES (?, ?, ?, ?, ?, ?, ?)',
        [id, title, baseTimestamp, updatedAt, assistantId, summary, kind],
      );
    }

    for (var index = 0; index < 12; index++) {
      insertConversation(
        id: 'chat-$index',
        title: 'Chat $index',
        updatedAt: baseTimestamp + index,
        summary: 'Summary $index',
      );
    }
    insertConversation(
      id: 'current',
      title: 'Current',
      updatedAt: baseTimestamp + 30,
    );
    insertConversation(
      id: 'group',
      title: 'Group',
      updatedAt: baseTimestamp + 40,
      kind: Conversation.kindGroup,
    );
    insertConversation(
      id: 'other-assistant',
      title: 'Other',
      updatedAt: baseTimestamp + 50,
      assistantId: 'assistant-2',
    );
    insertConversation(
      id: 'empty-title',
      title: '   ',
      updatedAt: baseTimestamp + 25,
    );
    database.execute(
      'INSERT INTO message_rows '
      '(id, conversation_id, role, content, timestamp, message_order, '
      'is_preset) VALUES (?, ?, ?, ?, ?, ?, ?)',
      [
        'preset-message',
        'current',
        'user',
        'preset content',
        baseTimestamp,
        0,
        1,
      ],
    );
    database.close();

    final references =
        await ProactiveCareHeadlessChatStore.loadRecentChatReferencesFor(
          'assistant-1',
          currentConversationId: 'current',
        );

    expect(references.map((conversation) => conversation.id), [
      'chat-11',
      'chat-10',
      'chat-9',
      'chat-8',
      'chat-7',
      'chat-6',
      'chat-5',
      'chat-4',
      'chat-3',
      'chat-2',
    ]);
    expect(references.first.summary, 'Summary 11');

    final exact = await ProactiveCareHeadlessChatStore.loadConversation(
      'current',
    );
    expect(exact?.conversation.id, 'current');
    expect(exact?.messages.single.isPreset, isTrue);
  });
}
