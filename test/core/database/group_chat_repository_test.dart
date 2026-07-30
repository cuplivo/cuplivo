import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:drift/native.dart';
import 'package:sqlite3/sqlite3.dart' as sqlite;
import 'package:Cuplivo/core/database/app_database.dart';
import 'package:Cuplivo/core/database/chat_database_repository.dart';
import 'package:Cuplivo/core/models/director_session.dart';
import 'package:Cuplivo/core/models/group_chat.dart';
import 'package:Cuplivo/core/models/group_chat_member.dart';
import 'package:Cuplivo/core/models/group_chat_message.dart';
import 'package:Cuplivo/core/models/group_chat_settings.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('schemaVersion', () {
    test('AppDatabase schemaVersion is 12', () {
      final db = AppDatabase(NativeDatabase.memory());
      expect(db.schemaVersion, 12);
      db.close();
    });

    test(
      'migrates v11 to v12 without changing ordinary artifact FKs',
      () async {
        final temp = await Directory.systemTemp.createTemp(
          'cuplivo_group_migration_',
        );
        final file = File('${temp.path}/v11.sqlite');
        final raw = sqlite.sqlite3.open(file.path);
        raw.execute('PRAGMA foreign_keys = ON');
        raw.execute(
          'CREATE TABLE message_rows ('
          'id TEXT NOT NULL PRIMARY KEY'
          ')',
        );
        raw.execute(
          'CREATE TABLE tool_event_rows ('
          'message_id TEXT NOT NULL PRIMARY KEY '
          'REFERENCES message_rows(id) ON DELETE CASCADE, '
          'events_json TEXT NOT NULL DEFAULT "[]"'
          ')',
        );
        raw.execute(
          'CREATE TABLE gemini_thought_signature_rows ('
          'message_id TEXT NOT NULL PRIMARY KEY '
          'REFERENCES message_rows(id) ON DELETE CASCADE, '
          'signature TEXT NOT NULL'
          ')',
        );
        raw.execute('PRAGMA user_version = 11');
        raw.close();

        final db = AppDatabase(NativeDatabase(file));
        try {
          final version = await db
              .customSelect('PRAGMA user_version')
              .map((row) => row.read<int>('user_version'))
              .getSingle();
          expect(version, 12);

          final tables = await db
              .customSelect(
                "SELECT name FROM sqlite_master WHERE type = 'table'",
              )
              .map((row) => row.read<String>('name'))
              .get();
          expect(tables, contains('chat_group_rows'));
          expect(tables, contains('chat_group_tool_event_rows'));
          expect(tables, contains('chat_group_gemini_thought_signature_rows'));

          final ordinaryFk = await db
              .customSelect('PRAGMA foreign_key_list(tool_event_rows)')
              .map((row) => row.read<String>('table'))
              .get();
          final groupFk = await db
              .customSelect(
                'PRAGMA foreign_key_list(chat_group_tool_event_rows)',
              )
              .map((row) => row.read<String>('table'))
              .get();
          expect(ordinaryFk, contains('message_rows'));
          expect(groupFk, contains('chat_group_message_rows'));
        } finally {
          await db.close();
          await temp.delete(recursive: true);
        }
      },
    );
  });

  group('ChatDatabaseRepository — Group chat', () {
    late AppDatabase db;
    late ChatDatabaseRepository repo;

    setUp(() {
      db = AppDatabase(NativeDatabase.memory());
      repo = ChatDatabaseRepository(db);
    });

    tearDown(() async {
      await repo.close();
    });

    test('putGroupChat / getGroupChat / getAllGroupChats round-trip', () async {
      final group = GroupChat(
        id: 'g1',
        title: 'Debate Club',
        avatar: '🎭',
        settings: const GroupChatSettings(
          maxAssistantMessagesPerUserTurn: 4,
          directorModelId: 'gpt-test',
          directorModelProvider: 'openai',
        ),
      );
      await repo.putGroupChat(group);

      final loaded = await repo.getGroupChat('g1');
      expect(loaded, isNotNull);
      expect(loaded!.title, 'Debate Club');
      expect(loaded.avatar, '🎭');
      expect(loaded.settings.maxAssistantMessagesPerUserTurn, 4);
      expect(loaded.settings.directorModelId, 'gpt-test');
      expect(loaded.settings.directorModelProvider, 'openai');
      expect(loaded.settings.persistDirectorTranscript, isTrue);

      final all = await repo.getAllGroupChats();
      expect(all.length, 1);
      expect(all.first.id, 'g1');
    });

    test('members CRUD and cascade delete with group', () async {
      final group = GroupChat(id: 'g1', title: 'G');
      await repo.putGroupChat(group);

      final members = [
        GroupChatMember(
          id: 'm-user',
          groupId: 'g1',
          kind: GroupChatMember.kindUser,
          sortOrder: 0,
        ),
        GroupChatMember(
          id: 'm-a1',
          groupId: 'g1',
          kind: GroupChatMember.kindAssistant,
          assistantId: 'a1',
          sortOrder: 1,
        ),
        GroupChatMember(
          id: 'm-a2',
          groupId: 'g1',
          kind: GroupChatMember.kindAssistant,
          assistantId: 'a2',
          sortOrder: 2,
        ),
      ];
      await repo.putGroupMembers('g1', members);

      final loaded = await repo.getGroupMembers('g1');
      expect(loaded.length, 3);
      expect(loaded[0].kind, GroupChatMember.kindUser);
      expect(loaded[1].assistantId, 'a1');
      expect(loaded[2].assistantId, 'a2');

      await repo.deleteGroupMember('m-a2');
      expect((await repo.getGroupMembers('g1')).length, 2);

      await repo.deleteGroupChat('g1');
      expect(await repo.getGroupChat('g1'), isNull);
      expect(await repo.getGroupMembers('g1'), isEmpty);
    });

    test('messages ordered by messageOrder', () async {
      await repo.putGroupChat(GroupChat(id: 'g1', title: 'G'));

      await repo.putGroupMessage(
        GroupChatMessage(
          id: 'msg1',
          groupId: 'g1',
          role: 'user',
          content: 'hello',
          messageOrder: 0,
        ),
      );
      await repo.putGroupMessage(
        GroupChatMessage(
          id: 'msg2',
          groupId: 'g1',
          role: 'assistant',
          content: 'hi from a1',
          speakerAssistantId: 'a1',
          messageOrder: 1,
          modelId: 'm1',
          providerId: 'p1',
        ),
      );
      await repo.putGroupMessage(
        GroupChatMessage(
          id: 'msg3',
          groupId: 'g1',
          role: 'assistant',
          content: 'hi from a2',
          speakerAssistantId: 'a2',
          messageOrder: 2,
        ),
      );

      final messages = await repo.getGroupMessages('g1');
      expect(messages.map((m) => m.id).toList(), ['msg1', 'msg2', 'msg3']);
      expect(messages[0].speakerAssistantId, isNull);
      expect(messages[1].speakerAssistantId, 'a1');
      expect(messages[1].modelId, 'm1');
      expect(await repo.getGroupMessageCount('g1'), 3);

      await repo.deleteGroupMessage('msg2');
      final after = await repo.getGroupMessages('g1');
      expect(after.map((m) => m.id).toList(), ['msg1', 'msg3']);
      // compact rewrites order to 0,1
      expect(after.map((m) => m.messageOrder).toList(), [0, 1]);
    });

    test('clears stale group streaming flags after interruption', () async {
      await repo.putGroupChat(GroupChat(id: 'g1', title: 'G'));
      await repo.putGroupMessage(
        GroupChatMessage(
          id: 'interrupted',
          groupId: 'g1',
          role: 'assistant',
          speakerAssistantId: 'a1',
          content: 'partial',
          isStreaming: true,
        ),
      );

      await repo.clearActiveGroupStreamingIds();

      expect((await repo.getGroupMessage('interrupted'))?.isStreaming, isFalse);
    });

    test('director session get/put', () async {
      await repo.putGroupChat(GroupChat(id: 'g1', title: 'G'));
      final session = DirectorSession(
        id: 'd1',
        groupId: 'g1',
        status: DirectorSession.statusDirecting,
        messages: [
          {'role': 'system', 'content': 'you are director'},
          {'role': 'user', 'content': 'who speaks next?'},
        ],
        state: {'round': 1},
        triggerUserMessageId: 'msg1',
      );
      await repo.putDirectorSession(session);

      final loaded = await repo.getDirectorSession('g1');
      expect(loaded, isNotNull);
      expect(loaded!.id, 'd1');
      expect(loaded.status, DirectorSession.statusDirecting);
      expect(loaded.messages.length, 2);
      expect(loaded.state['round'], 1);
      expect(loaded.triggerUserMessageId, 'msg1');

      await repo.deleteDirectorSessionForGroup('g1');
      expect(await repo.getDirectorSession('g1'), isNull);
    });

    test('group message artifacts use cascading group sidecars', () async {
      await repo.putGroupChat(GroupChat(id: 'g1', title: 'G'));
      await repo.putGroupMessage(
        GroupChatMessage(
          id: 'gmsg-tool',
          groupId: 'g1',
          role: 'assistant',
          content: 'calling tool',
          speakerAssistantId: 'a1',
          messageOrder: 0,
        ),
      );

      await repo.setGroupToolEvents('gmsg-tool', [
        {
          'id': 't1',
          'name': 'search',
          'arguments': {'q': 'x'},
          'content': 'result',
        },
      ]);

      await repo.setGroupGeminiThoughtSignature(
        'gmsg-tool',
        '<!-- gemini_thought_signatures:test -->',
      );

      final events = await repo.getGroupToolEvents('gmsg-tool');
      expect(events.length, 1);
      expect(events.first['name'], 'search');
      expect(await repo.getGroupGeminiThoughtSignature('gmsg-tool'), isNotNull);

      await repo.deleteGroupMessage('gmsg-tool');
      expect(await repo.getGroupToolEvents('gmsg-tool'), isEmpty);
      expect(await repo.getGroupGeminiThoughtSignature('gmsg-tool'), isNull);
    });

    test('clearAllData removes group tables', () async {
      await repo.putGroupChat(GroupChat(id: 'g1', title: 'G'));
      await repo.putGroupMembers('g1', [
        GroupChatMember(
          groupId: 'g1',
          kind: GroupChatMember.kindUser,
          sortOrder: 0,
        ),
      ]);
      await repo.putGroupMessage(
        GroupChatMessage(
          groupId: 'g1',
          role: 'user',
          content: 'x',
          messageOrder: 0,
        ),
      );
      await repo.putDirectorSession(DirectorSession(groupId: 'g1'));

      await repo.clearAllData();

      expect(await repo.getAllGroupChats(), isEmpty);
      expect(await repo.getGroupMembers('g1'), isEmpty);
      expect(await repo.getGroupMessages('g1'), isEmpty);
      expect(await repo.getDirectorSession('g1'), isNull);
    });

    test('putGroupChatRestoreBatch restores hierarchy', () async {
      final group = GroupChat(id: 'g1', title: 'Restored');
      final members = [
        GroupChatMember(
          id: 'm1',
          groupId: 'g1',
          kind: GroupChatMember.kindUser,
          sortOrder: 0,
        ),
        GroupChatMember(
          id: 'm2',
          groupId: 'g1',
          kind: GroupChatMember.kindAssistant,
          assistantId: 'a1',
          sortOrder: 1,
        ),
      ];
      final messages = [
        GroupChatMessage(
          id: 'msg1',
          groupId: 'g1',
          role: 'user',
          content: 'hi',
          messageOrder: 0,
        ),
      ];
      final sessions = [DirectorSession(id: 'd1', groupId: 'g1')];

      await repo.putGroupChatRestoreBatch(
        groups: [group],
        membersByGroup: {'g1': members},
        messagesByGroup: {'g1': messages},
        directorSessions: sessions,
      );

      expect((await repo.getGroupChat('g1'))?.title, 'Restored');
      expect((await repo.getGroupMembers('g1')).length, 2);
      expect((await repo.getGroupMessages('g1')).single.content, 'hi');
      expect((await repo.getDirectorSession('g1'))?.id, 'd1');
    });

    test('GroupChatSettings JSON defaults and nullable sentinel copyWith', () {
      final s = GroupChatSettings.fromJson({});
      expect(s.maxAssistantMessagesPerUserTurn, 6);
      expect(s.allowSameAssistantConsecutive, isTrue);

      final cleared = const GroupChatSettings(
        directorModelId: 'x',
        directorModelProvider: 'p',
      ).copyWith(directorModelId: null, directorModelProvider: null);
      expect(cleared.directorModelId, isNull);
      expect(cleared.directorModelProvider, isNull);
    });
  });
}
