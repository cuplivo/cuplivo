import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:Cuplivo/core/database/chat_database_repository.dart';
import 'package:Cuplivo/core/models/chat_message.dart';
import 'package:Cuplivo/core/models/conversation.dart';
import 'package:Cuplivo/core/models/message_part.dart';

void main() {
  late Directory root;
  late ChatDatabaseRepository repository;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('chat_mini_map_search_');
    repository = ChatDatabaseRepository.open(
      file: File('${root.path}/search.sqlite'),
    );
    await repository.ensureReady();
  });

  tearDown(() async {
    await repository.close();
    await root.delete(recursive: true);
  });

  Future<void> seed({
    required Conversation conversation,
    required List<ChatMessage> messages,
  }) {
    return repository.putMigrationBatch(
      conversations: [conversation],
      messages: [
        for (final (index, message) in messages.indexed)
          (message: message, messageOrder: index),
      ],
      toolEventsByMessageId: const {},
      geminiSignaturesByMessageId: const {},
    );
  }

  test('keyword after the 200-character projection still matches', () async {
    const conversationId = 'conversation-1';
    final conversation = Conversation(
      id: conversationId,
      title: 'Long',
      createdAt: DateTime.utc(2026, 8, 18),
      updatedAt: DateTime.utc(2026, 8, 18),
    );
    final message = ChatMessage(
      id: 'msg-1',
      role: 'user',
      content: '${'a' * 200}hidden-tail-token',
      conversationId: conversationId,
    );
    await seed(conversation: conversation, messages: [message]);

    final projections = await repository.getSelectedMessageProjections(
      conversationId,
    );
    expect(projections.single.content.length, 200);
    expect(projections.single.content.contains('hidden-tail-token'), isFalse);

    final hits = await repository.searchMiniMapMatches(
      conversationId,
      'hidden-tail-token',
    );
    expect(hits, hasLength(1));
    expect(hits.single.messageId, 'msg-1');
    expect(hits.single.snippet, contains('hidden-tail-token'));
  });

  test(
    'second text part is searchable and projections concat by ordinal',
    () async {
      const conversationId = 'conversation-2';
      final conversation = Conversation(
        id: conversationId,
        title: 'Parts',
        createdAt: DateTime.utc(2026, 8, 18),
        updatedAt: DateTime.utc(2026, 8, 18),
      );
      final message = ChatMessage(
        id: 'msg-parts',
        role: 'assistant',
        conversationId: conversationId,
        parts: [TextPart('b' * 210), const TextPart('needle-in-second-part')],
      );
      await seed(conversation: conversation, messages: [message]);

      final projections = await repository.getSelectedMessageProjections(
        conversationId,
        summaryCharacters: 80,
      );
      expect(projections.single.content, 'b' * 80);
      expect(
        projections.single.content.contains('needle-in-second-part'),
        isFalse,
      );

      final hits = await repository.searchMiniMapMatches(
        conversationId,
        'needle-in-second-part',
      );
      expect(hits.single.messageId, 'msg-parts');
      expect(hits.single.snippet, contains('needle-in-second-part'));
    },
  );

  test(
    'selected projections concatenate text parts before truncating',
    () async {
      const conversationId = 'conversation-concat';
      await seed(
        conversation: Conversation(
          id: conversationId,
          title: 'Concat',
          createdAt: DateTime.utc(2026, 8, 18),
          updatedAt: DateTime.utc(2026, 8, 18),
        ),
        messages: [
          ChatMessage(
            id: 'msg-concat',
            role: 'user',
            conversationId: conversationId,
            parts: const [TextPart('hello '), TextPart('world-suffix')],
          ),
        ],
      );

      final projections = await repository.getSelectedMessageProjections(
        conversationId,
        summaryCharacters: 20,
      );
      expect(projections.single.content, 'hello world-suffix');
    },
  );

  test('matchCount counts every non-overlapping occurrence', () async {
    const conversationId = 'conversation-3';
    await seed(
      conversation: Conversation(
        id: conversationId,
        title: 'Counts',
        createdAt: DateTime.utc(2026, 8, 18),
        updatedAt: DateTime.utc(2026, 8, 18),
      ),
      messages: [
        ChatMessage(
          id: 'msg-count',
          role: 'user',
          content: 'foo bar foo baz foo',
          conversationId: conversationId,
        ),
      ],
    );

    final hits = await repository.searchMiniMapMatches(conversationId, 'foo');
    expect(hits.single.matchCount, 3);
  });

  test('only the selected version is searchable', () async {
    final now = DateTime.utc(2026, 7, 12);
    final conversation = Conversation(
      id: 'conversation-1',
      title: 'Versions',
      createdAt: now,
      updatedAt: now,
      versionSelections: const {'slot-1': 2},
    );
    ChatMessage version(String id, int number, String content) => ChatMessage(
      id: id,
      role: 'assistant',
      content: content,
      timestamp: now,
      conversationId: conversation.id,
      groupId: 'slot-1',
      version: number,
    );
    await seed(
      conversation: conversation,
      messages: [
        version('v1', 1, 'hidden-only-token'),
        version('v2', 2, 'visible-only-token'),
      ],
    );

    expect(
      await repository.searchMiniMapMatches(
        conversation.id,
        'hidden-only-token',
      ),
      isEmpty,
    );
    expect(
      (await repository.searchMiniMapMatches(
        conversation.id,
        'visible-only-token',
      )).single.messageId,
      'v2',
    );
  });

  test('ASCII search is case-insensitive', () async {
    const conversationId = 'conversation-case';
    await seed(
      conversation: Conversation(
        id: conversationId,
        title: 'Case',
        createdAt: DateTime.utc(2026, 8, 18),
        updatedAt: DateTime.utc(2026, 8, 18),
      ),
      messages: [
        ChatMessage(
          id: 'msg-case',
          role: 'assistant',
          content: 'Hello World',
          conversationId: conversationId,
        ),
      ],
    );

    final hits = await repository.searchMiniMapMatches(conversationId, 'HELLO');
    expect(hits.single.messageId, 'msg-case');
    expect(hits.single.snippet, contains('Hello'));
  });

  test('snippet window contains the keyword', () async {
    const conversationId = 'conversation-snippet';
    const prefix = 'prefix-text-that-is-long-enough-to-shift-the-window-';
    await seed(
      conversation: Conversation(
        id: conversationId,
        title: 'Snippet',
        createdAt: DateTime.utc(2026, 8, 18),
        updatedAt: DateTime.utc(2026, 8, 18),
      ),
      messages: [
        ChatMessage(
          id: 'msg-snippet',
          role: 'user',
          content: '${prefix}keyword-token and a tail',
          conversationId: conversationId,
        ),
      ],
    );

    final hits = await repository.searchMiniMapMatches(
      conversationId,
      'keyword-token',
      snippetRadius: 8,
      snippetLength: 24,
    );
    expect(hits.single.snippet, contains('keyword-token'));
    expect(hits.single.snippetStart, greaterThan(0));
  });

  test('snippet window grows so a long keyword is not truncated', () async {
    const conversationId = 'conversation-long-keyword';
    const prefix =
        'prefix-text-that-is-long-enough-to-fill-the-default-radius-xx';
    final keyword = '${'k' * 90}-unique-tail';
    expect(prefix.length, greaterThanOrEqualTo(40));
    expect(keyword.length, greaterThan(80));
    await seed(
      conversation: Conversation(
        id: conversationId,
        title: 'Long keyword',
        createdAt: DateTime.utc(2026, 8, 18),
        updatedAt: DateTime.utc(2026, 8, 18),
      ),
      messages: [
        ChatMessage(
          id: 'msg-long-keyword',
          role: 'user',
          content: '$prefix$keyword and a tail',
          conversationId: conversationId,
        ),
      ],
    );

    final hits = await repository.searchMiniMapMatches(conversationId, keyword);
    expect(hits.single.snippet, contains(keyword));
    expect(
      miniMapSnippetLength(needleLength: keyword.length),
      greaterThan(120),
    );
  });
}
