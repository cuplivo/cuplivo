import 'dart:convert';
import 'dart:io';

import 'package:Cuplivo/core/database/app_database.dart';
import 'package:Cuplivo/core/database/backup_content_filter.dart';
import 'package:Cuplivo/core/database/business_data.dart';
import 'package:Cuplivo/core/database/business_settings_router.dart';
import 'package:Cuplivo/core/database/chat_database_repository.dart';
import 'package:Cuplivo/core/models/backup_scope.dart';
import 'package:Cuplivo/core/models/chat_message.dart';
import 'package:Cuplivo/core/models/conversation.dart';
import 'package:Cuplivo/core/models/group_chat.dart';
import 'package:flutter_test/flutter_test.dart';

/// A group chat is three schema-5 extension points, no new tables and no new
/// schema version: entity rows for the group, conversation extras for the link,
/// and `message_rows.sender_id` for who wrote a reply.
void main() {
  group('schema', () {
    test('stays at version 5', () {
      expect(AppDatabase.currentSchemaVersion, 5);
    });

    test('a group is an extension entity row, not a table', () {
      const kind = BusinessEntityKind.groupChat;
      expect(kind.sourceKey, 'group_chats_v1');
      expect(kind.tableName, 'extension_entity_rows');
      expect(kind.extensionKind, 'groupChat');
      expect(kind.wireName, 'groupChat');
    });

    test('a group travels with the chats it belongs to', () {
      expect(
        BackupContentFilter.categoryForKey(
          BusinessEntityKind.groupChat.sourceKey,
        ),
        BackupCategory.chats,
      );
    });

    test('one group payload routes as one entity row', () {
      final payload = GroupChat(
        id: 'group-1',
        name: 'Panel',
        memberIds: const ['a1', 'a2'],
        createdAt: DateTime.utc(2026, 1, 1),
        updatedAt: DateTime.utc(2026, 1, 2),
      ).toJson();
      final snapshot = BusinessSettingsRouter.normalizeAndRoute({
        'group_chats_v1': jsonEncode([payload]),
      });
      final rows = snapshot.entities[BusinessEntityKind.groupChat]!;
      expect(rows, hasLength(1));
      expect(rows.single.id, 'group-1');
    });

    test('a group payload without a name is refused at the boundary', () {
      expect(
        () => BusinessSettingsRouter.normalizeAndRoute({
          'group_chats_v1': jsonEncode([
            {'id': 'group-1'},
          ]),
        }),
        throwsA(isA<FormatException>()),
      );
    });
  });

  group('GroupChat payload', () {
    test('round-trips', () {
      final group = GroupChat(
        id: 'group-1',
        name: 'Panel',
        avatar: '🎛️',
        memberIds: const ['a1', 'a2'],
        maxSpeakerTurns: 2,
        createdAt: DateTime.utc(2026, 1, 1),
        updatedAt: DateTime.utc(2026, 1, 2),
      );
      expect(GroupChat.fromJson(group.toJson()), group);
    });

    test('clamps the speaker budget into the supported range', () {
      final group = GroupChat(
        id: 'group-1',
        name: 'Panel',
        memberIds: const [],
        maxSpeakerTurns: 99,
        createdAt: DateTime.utc(2026),
        updatedAt: DateTime.utc(2026),
      );
      expect(group.speakerTurnLimit, GroupChat.maxSpeakerTurnsLimit);
      expect(GroupChat.fromJson(group.toJson()).maxSpeakerTurns, 6);
    });

    test('a payload from a newer build is skipped, not guessed at', () {
      final json = GroupChat(
        id: 'group-1',
        name: 'Panel',
        memberIds: const ['a1'],
        createdAt: DateTime.utc(2026),
        updatedAt: DateTime.utc(2026),
      ).toJson()..['v'] = 2;
      expect(() => GroupChat.fromJson(json), throwsA(isA<FormatException>()));
    });
  });

  group('conversation link', () {
    test('a group conversation has no owning assistant', () {
      final conversation = Conversation(
        id: 'c1',
        title: 'Topic',
      ).withGroupChatId('group-1');
      expect(conversation.groupChatId, 'group-1');
      expect(conversation.isGroupConversation, isTrue);
      expect(conversation.assistantId, isNull);
    });

    test('clearing the link restores an ordinary conversation', () {
      final conversation = Conversation(
        id: 'c1',
        title: 'Topic',
      ).withGroupChatId('group-1').withGroupChatId(null);
      expect(conversation.isGroupConversation, isFalse);
      expect(
        conversation.extras.containsKey(Conversation.groupChatIdKey),
        isFalse,
      );
    });

    test('the link survives a JSON round-trip', () {
      final conversation = Conversation(
        id: 'c1',
        title: 'Topic',
      ).withGroupChatId('group-1');
      final decoded = Conversation.fromJson(conversation.toJson());
      expect(decoded.groupChatId, 'group-1');
    });
  });

  group('sender_id', () {
    late Directory directory;
    late ChatDatabaseRepository repository;

    setUp(() async {
      directory = await Directory.systemTemp.createTemp('cuplivo_group_test_');
      repository = ChatDatabaseRepository.open(
        file: File('${directory.path}/chat.sqlite'),
      );
      await repository.ensureReady();
    });

    tearDown(() async {
      await repository.close();
      await directory.delete(recursive: true);
    });

    Conversation conversation({String id = 'conversation-1'}) =>
        Conversation(id: id, title: 'Topic').withGroupChatId('group-1');

    ChatMessage reply({
      required String id,
      required String senderId,
      String content = 'hello',
    }) => ChatMessage(
      id: id,
      role: 'assistant',
      content: content,
      conversationId: 'conversation-1',
      senderId: senderId,
      isStreaming: true,
    );

    test('an author lands in the row and reads back', () async {
      await repository.appendLinearMessageToConversation(
        conversation: conversation(),
        message: reply(id: 'm1', senderId: 'a1'),
      );
      expect((await repository.getMessage('m1'))?.senderId, 'a1');

      await repository.appendLinearMessageToConversation(
        conversation: conversation(),
        message: reply(id: 'm2', senderId: 'a2'),
      );
      expect((await repository.getMessage('m2'))?.senderId, 'a2');
    });

    test('a rewrite keeps the author', () async {
      await repository.appendLinearMessageToConversation(
        conversation: conversation(),
        message: reply(id: 'm1', senderId: 'a1'),
      );
      final stored = (await repository.getMessage('m1'))!;
      await repository.updateMessage(
        stored.copyWith(content: 'rewritten', isStreaming: false),
      );
      expect((await repository.getMessage('m1'))?.senderId, 'a1');
    });

    test('an edit version keeps the author', () async {
      await repository.appendLinearMessageToConversation(
        conversation: conversation(),
        message: reply(id: 'm1', senderId: 'a1'),
      );
      // Editing a reply is a new revision of the same words from the same
      // member: an authorless revision would be re-attributed to whichever
      // assistant is selected when it is shown.
      final appended = await repository.appendMessageVersion(
        messageId: 'm1',
        content: 'hello, edited',
      );
      expect(appended, isNotNull);
      expect(appended!.message.senderId, 'a1');
      expect(
        (await repository.getMessage(appended.message.id))?.senderId,
        'a1',
      );
    });

    test('a copied conversation keeps every author', () async {
      await repository.appendLinearMessageToConversation(
        conversation: conversation(),
        message: reply(id: 'm1', senderId: 'a1'),
      );
      await repository.appendLinearMessageToConversation(
        conversation: conversation(),
        message: reply(id: 'm2', senderId: 'a2'),
      );
      final copy = await repository.duplicateConversation('conversation-1');
      expect(copy, isNotNull);
      final rows = await repository.syncReadMessageRows(copy!.id);
      expect(rows.map((row) => row['sender_id']).toList(), ['a1', 'a2']);
    });

    test('a 1:1 reply carries no author', () async {
      await repository.appendLinearMessageToConversation(
        conversation: Conversation(id: 'conversation-1', title: 'Chat'),
        message: ChatMessage(
          id: 'm1',
          role: 'assistant',
          content: 'hi',
          conversationId: 'conversation-1',
        ),
      );
      expect((await repository.getMessage('m1'))?.senderId, isNull);
    });
  });
}
