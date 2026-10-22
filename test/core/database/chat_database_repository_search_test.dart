import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart' as sqlite;

import 'package:Cuplivo/core/database/chat_database_repository.dart';
import 'package:Cuplivo/core/models/chat_message.dart';
import 'package:Cuplivo/core/models/conversation.dart';

/// Ensures FTS setup ran, then runs FTS5 integrity-check on [dbFile].
Future<void> expectFtsIntegrity(
  ChatDatabaseRepository repository,
  File dbFile,
) async {
  await repository.searchConversationMatches(
    tokens: const ['__fts_integrity__'],
  );
  await repository.close();
  final database = sqlite.sqlite3.open(dbFile.path);
  try {
    database.execute(
      "INSERT INTO message_search_fts(message_search_fts) "
      "VALUES('integrity-check');",
    );
  } finally {
    database.close();
  }
}

void main() {
  test(
    'search defaults to selected versions and can include every version',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'chat_search_versions_',
      );
      final repository = ChatDatabaseRepository.open(
        file: File('${root.path}/search.sqlite'),
      );
      addTearDown(() async {
        await repository.close();
        await root.delete(recursive: true);
      });
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
      await repository.putMigrationBatch(
        conversations: [conversation],
        messages: [
          (message: version('v1', 1, 'hidden-only-token'), messageOrder: 0),
          (message: version('v2', 2, 'visible-only-token'), messageOrder: 1),
        ],
        toolEventsByMessageId: const {},
        geminiSignaturesByMessageId: const {},
      );

      expect(
        await repository.searchConversationMatches(
          tokens: const ['hidden-only-token'],
        ),
        isEmpty,
      );
      expect(
        (await repository.searchConversationMatches(
          tokens: const ['visible-only-token'],
        )).single.messageId,
        'v2',
      );
      expect(
        (await repository.searchConversationMatches(
          tokens: const ['hidden-only-token'],
          includeAllRevisions: true,
        )).single.messageId,
        'v1',
      );
    },
  );

  test('search uses FTS for words and substring fallback for CJK', () async {
    final root = await Directory.systemTemp.createTemp('chat_search_test_');
    final repository = ChatDatabaseRepository.open(
      file: File('${root.path}/search.sqlite'),
    );
    addTearDown(() async {
      await repository.close();
      await root.delete(recursive: true);
    });
    final conversation = Conversation(
      id: 'conversation-1',
      title: 'Search',
      createdAt: DateTime.utc(2026, 7, 12),
      updatedAt: DateTime.utc(2026, 7, 12),
      messageIds: const ['revision-1'],
    );
    final message = ChatMessage(
      id: 'revision-1',
      role: 'assistant',
      content: 'A searchable needle appears here，测试中文短词。',
      timestamp: DateTime.utc(2026, 7, 12),
      conversationId: conversation.id,
      groupId: 'slot-1',
      version: 1,
    );
    await repository.putMigrationBatch(
      conversations: [conversation],
      messages: [(message: message, messageOrder: 0)],
      toolEventsByMessageId: const {},
      geminiSignaturesByMessageId: const {},
    );

    final word = await repository.searchConversationMatches(
      tokens: const ['needle'],
    );
    final cjk = await repository.searchConversationMatches(
      tokens: const ['中文'],
    );

    expect(word.single.messageId, 'revision-1');
    expect(word.single.groupId, 'slot-1');
    expect(word.single.messageContent, contains('needle'));
    expect(cjk.single.messageId, 'revision-1');

    await repository.updateMessage(
      message.copyWith(content: 'replacement token'),
    );
    expect(
      await repository.searchConversationMatches(tokens: const ['needle']),
      isEmpty,
    );
    expect(
      (await repository.searchConversationMatches(
        tokens: const ['replacement'],
      )).single.messageId,
      'revision-1',
    );
  });

  test(
    'FTS uses message part rows as external content instead of copying bodies',
    () async {
      final root = await Directory.systemTemp.createTemp('chat_search_fts_');
      final file = File('${root.path}/search.sqlite');
      final repository = ChatDatabaseRepository.open(file: file);
      final conversation = Conversation(
        id: 'conversation-1',
        title: 'Search',
        createdAt: DateTime.utc(2026, 7, 12),
        updatedAt: DateTime.utc(2026, 7, 12),
        messageIds: const ['revision-1'],
      );
      final message = ChatMessage(
        id: 'revision-1',
        role: 'user',
        content: 'body stored only in message part rows',
        timestamp: DateTime.utc(2026, 7, 12),
        conversationId: conversation.id,
      );
      await repository.putMigrationBatch(
        conversations: [conversation],
        messages: [(message: message, messageOrder: 0)],
        toolEventsByMessageId: const {},
        geminiSignaturesByMessageId: const {},
      );
      expect(
        await repository.searchConversationMatches(tokens: const ['stored']),
        isNotEmpty,
      );
      await repository.close();

      final database = sqlite.sqlite3.open(file.path);
      try {
        final sql = database
            .select(
              "SELECT sql FROM sqlite_master WHERE type = 'table' AND name = 'message_search_fts';",
            )
            .single['sql']
            .toString();
        expect(sql, contains("content='message_part_rows'"));
        expect(sql, contains("content_rowid='part_id'"));
        expect(sql, isNot(contains("content='message_rows'")));
      } finally {
        database.close();
        await root.delete(recursive: true);
      }
    },
  );

  test('streaming messages stay out of FTS until finalized', () async {
    final root = await Directory.systemTemp.createTemp('chat_search_stream_');
    final repository = ChatDatabaseRepository.open(
      file: File('${root.path}/search.sqlite'),
    );
    addTearDown(() async {
      await repository.close();
      await root.delete(recursive: true);
    });
    final conversation = Conversation(
      id: 'conversation-1',
      title: 'Stream',
      createdAt: DateTime.utc(2026, 7, 12),
      updatedAt: DateTime.utc(2026, 7, 12),
      messageIds: const ['revision-1'],
    );
    final streaming = ChatMessage(
      id: 'revision-1',
      role: 'assistant',
      content: '',
      timestamp: DateTime.utc(2026, 7, 12),
      conversationId: conversation.id,
      isStreaming: true,
    );
    await repository.putMigrationBatch(
      conversations: [conversation],
      messages: [(message: streaming, messageOrder: 0)],
      toolEventsByMessageId: const {},
      geminiSignaturesByMessageId: const {},
    );

    await repository.updateStreamingCheckpoint(
      streaming.copyWith(content: 'partial unique-stream-token draft'),
      const [],
    );
    expect(
      await repository.searchConversationMatches(
        tokens: const ['unique-stream-token'],
      ),
      isEmpty,
    );

    await repository.updateStreamingCheckpoint(
      streaming.copyWith(
        content: 'final unique-stream-token answer',
        isStreaming: false,
      ),
      const [],
    );
    expect(
      (await repository.searchConversationMatches(
        tokens: const ['unique-stream-token'],
      )).single.messageId,
      'revision-1',
    );
    expect(
      await repository.searchConversationMatches(tokens: const ['draft']),
      isEmpty,
    );
  });

  test('deleting a message removes its body from search', () async {
    final root = await Directory.systemTemp.createTemp('chat_search_del_msg_');
    final file = File('${root.path}/search.sqlite');
    final repository = ChatDatabaseRepository.open(file: file);
    addTearDown(() async {
      if (await root.exists()) {
        await root.delete(recursive: true);
      }
    });
    final conversation = Conversation(
      id: 'conversation-1',
      title: 'Delete message',
      createdAt: DateTime.utc(2026, 7, 12),
      updatedAt: DateTime.utc(2026, 7, 12),
      messageIds: const ['keep', 'drop'],
    );
    await repository.putMigrationBatch(
      conversations: [conversation],
      messages: [
        (
          message: ChatMessage(
            id: 'keep',
            role: 'user',
            content: 'keep-token stays',
            timestamp: DateTime.utc(2026, 7, 12),
            conversationId: conversation.id,
          ),
          messageOrder: 0,
        ),
        (
          message: ChatMessage(
            id: 'drop',
            role: 'assistant',
            content: 'drop-token vanishes',
            timestamp: DateTime.utc(2026, 7, 12),
            conversationId: conversation.id,
          ),
          messageOrder: 1,
        ),
      ],
      toolEventsByMessageId: const {},
      geminiSignaturesByMessageId: const {},
    );

    expect(
      (await repository.searchConversationMatches(
        tokens: const ['drop-token'],
      )).single.messageId,
      'drop',
    );
    await repository.deleteMessage('drop');
    expect(
      await repository.searchConversationMatches(tokens: const ['drop-token']),
      isEmpty,
    );
    expect(
      (await repository.searchConversationMatches(
        tokens: const ['keep-token'],
      )).single.messageId,
      'keep',
    );
    await expectFtsIntegrity(repository, file);
  });

  test(
    'deleting a conversation removes all message bodies from search',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'chat_search_del_conv_',
      );
      final file = File('${root.path}/search.sqlite');
      final repository = ChatDatabaseRepository.open(file: file);
      addTearDown(() async {
        if (await root.exists()) {
          await root.delete(recursive: true);
        }
      });
      await repository.putMigrationBatch(
        conversations: [
          Conversation(
            id: 'doomed',
            title: 'Doomed',
            createdAt: DateTime.utc(2026, 7, 12),
            updatedAt: DateTime.utc(2026, 7, 12),
            messageIds: const ['m1'],
          ),
          Conversation(
            id: 'survivor',
            title: 'Survivor',
            createdAt: DateTime.utc(2026, 7, 12),
            updatedAt: DateTime.utc(2026, 7, 12),
            messageIds: const ['m2'],
          ),
        ],
        messages: [
          (
            message: ChatMessage(
              id: 'm1',
              role: 'user',
              content: 'doomed-conversation-token',
              timestamp: DateTime.utc(2026, 7, 12),
              conversationId: 'doomed',
            ),
            messageOrder: 0,
          ),
          (
            message: ChatMessage(
              id: 'm2',
              role: 'user',
              content: 'survivor-conversation-token',
              timestamp: DateTime.utc(2026, 7, 12),
              conversationId: 'survivor',
            ),
            messageOrder: 0,
          ),
        ],
        toolEventsByMessageId: const {},
        geminiSignaturesByMessageId: const {},
      );

      expect(
        await repository.searchConversationMatches(
          tokens: const ['doomed-conversation-token'],
        ),
        isNotEmpty,
      );
      await repository.deleteConversation('doomed');
      expect(
        await repository.searchConversationMatches(
          tokens: const ['doomed-conversation-token'],
        ),
        isEmpty,
      );
      expect(
        (await repository.searchConversationMatches(
          tokens: const ['survivor-conversation-token'],
        )).single.messageId,
        'm2',
      );
      await expectFtsIntegrity(repository, file);
    },
  );

  test(
    'reopening a finalized message for streaming unindexes before rewrite',
    () async {
      final root = await Directory.systemTemp.createTemp('chat_search_reopen_');
      final file = File('${root.path}/search.sqlite');
      final repository = ChatDatabaseRepository.open(file: file);
      addTearDown(() async {
        if (await root.exists()) {
          await root.delete(recursive: true);
        }
      });
      final conversation = Conversation(
        id: 'conversation-1',
        title: 'Reopen',
        createdAt: DateTime.utc(2026, 7, 12),
        updatedAt: DateTime.utc(2026, 7, 12),
        messageIds: const ['revision-1'],
      );
      final finished = ChatMessage(
        id: 'revision-1',
        role: 'assistant',
        content: 'reopen-old-body-token',
        timestamp: DateTime.utc(2026, 7, 12),
        conversationId: conversation.id,
      );
      await repository.putMigrationBatch(
        conversations: [conversation],
        messages: [(message: finished, messageOrder: 0)],
        toolEventsByMessageId: const {},
        geminiSignaturesByMessageId: const {},
      );
      expect(
        (await repository.searchConversationMatches(
          tokens: const ['reopen-old-body-token'],
        )).single.messageId,
        'revision-1',
      );

      // Real path: continueAssistantMessageAfterToolAnswer → updateMessageFields
      await repository.updateMessageFields('revision-1', isStreaming: true);
      final reopened = finished.copyWith(isStreaming: true);
      await repository.updateStreamingCheckpoint(
        reopened.copyWith(content: 'reopen-draft-one'),
        const [],
      );
      await repository.updateStreamingCheckpoint(
        reopened.copyWith(content: 'reopen-draft-two'),
        const [],
      );
      await repository.updateStreamingCheckpoint(
        reopened.copyWith(content: 'reopen-new-body-token', isStreaming: false),
        const [],
      );

      expect(
        await repository.searchConversationMatches(
          tokens: const ['reopen-old-body-token'],
        ),
        isEmpty,
      );
      expect(
        (await repository.searchConversationMatches(
          tokens: const ['reopen-new-body-token'],
        )).single.messageId,
        'revision-1',
      );
      await expectFtsIntegrity(repository, file);
    },
  );

  test('conversationId scope is applied before the candidate LIMIT', () async {
    // candidateLimit = (limit * candidateMultiplier).clamp(limit, 2000).
    // With limit=2 and multiplier=1 the ceiling is 2 rows. Newer matching
    // noise fills that window; SQL scoping must still find the older target.
    // Filtering in Dart after an unscoped LIMIT would miss it.
    final root = await Directory.systemTemp.createTemp(
      'chat_search_scope_limit_',
    );
    final repository = ChatDatabaseRepository.open(
      file: File('${root.path}/search.sqlite'),
    );
    addTearDown(() async {
      await repository.close();
      await root.delete(recursive: true);
    });

    final base = DateTime.utc(2026, 7, 1);
    Future<void> seedConversation({
      required String id,
      required DateTime updatedAt,
      required String messageId,
    }) {
      return repository.putMigrationBatch(
        conversations: [
          Conversation(
            id: id,
            title: id,
            createdAt: updatedAt,
            updatedAt: updatedAt,
            messageIds: [messageId],
          ),
        ],
        messages: [
          (
            message: ChatMessage(
              id: messageId,
              role: 'user',
              content: 'needle in conversation',
              timestamp: updatedAt,
              conversationId: id,
            ),
            messageOrder: 0,
          ),
        ],
        toolEventsByMessageId: const {},
        geminiSignaturesByMessageId: const {},
      );
    }

    await seedConversation(
      id: 'wanted',
      updatedAt: base,
      messageId: 'wanted-msg',
    );
    for (var i = 0; i < 5; i++) {
      await seedConversation(
        id: 'noise-$i',
        updatedAt: base.add(Duration(days: i + 1)),
        messageId: 'noise-msg-$i',
      );
    }

    final matches = await repository.searchConversationMatches(
      tokens: const ['needle'],
      limit: 2,
      candidateMultiplier: 1,
      conversationId: 'wanted',
    );
    expect(matches, isNotEmpty);
    expect(matches.every((m) => m.conversationId == 'wanted'), isTrue);
  });

  test('tool_call payloads are not indexed for search', () async {
    final root = await Directory.systemTemp.createTemp('chat_search_tool_');
    final repository = ChatDatabaseRepository.open(
      file: File('${root.path}/search.sqlite'),
    );
    addTearDown(() async {
      await repository.close();
      await root.delete(recursive: true);
    });
    final conversation = Conversation(
      id: 'conversation-1',
      title: 'Tools',
      createdAt: DateTime.utc(2026, 7, 12),
      updatedAt: DateTime.utc(2026, 7, 12),
      messageIds: const ['revision-1'],
    );
    final message = ChatMessage(
      id: 'revision-1',
      role: 'assistant',
      content: 'visible-text-body',
      timestamp: DateTime.utc(2026, 7, 12),
      conversationId: conversation.id,
    );
    await repository.putMigrationBatch(
      conversations: [conversation],
      messages: [(message: message, messageOrder: 0)],
      toolEventsByMessageId: const {
        'revision-1': [
          {
            'id': 'tool-1',
            'name': 'search',
            'arguments': {'q': 'secret-tool-json-token'},
            'content': 'secret-tool-result-token',
          },
        ],
      },
      geminiSignaturesByMessageId: const {},
    );

    expect(
      (await repository.searchConversationMatches(
        tokens: const ['visible-text-body'],
      )).single.messageId,
      'revision-1',
    );
    expect(
      await repository.searchConversationMatches(
        tokens: const ['secret-tool-json-token'],
      ),
      isEmpty,
    );
    expect(
      await repository.searchConversationMatches(
        tokens: const ['secret-tool-result-token'],
      ),
      isEmpty,
    );
  });

  test(
    'FTS integrity holds across stream, finalize, edit, and delete',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'chat_search_integrity_',
      );
      final file = File('${root.path}/search.sqlite');
      final repository = ChatDatabaseRepository.open(file: file);
      addTearDown(() async {
        await repository.close();
        if (await root.exists()) {
          await root.delete(recursive: true);
        }
      });
      final conversation = Conversation(
        id: 'conversation-1',
        title: 'Integrity',
        createdAt: DateTime.utc(2026, 7, 12),
        updatedAt: DateTime.utc(2026, 7, 12),
        messageIds: const ['revision-1'],
      );
      final streaming = ChatMessage(
        id: 'revision-1',
        role: 'assistant',
        content: '',
        timestamp: DateTime.utc(2026, 7, 12),
        conversationId: conversation.id,
        isStreaming: true,
      );
      await repository.putMigrationBatch(
        conversations: [conversation],
        messages: [(message: streaming, messageOrder: 0)],
        toolEventsByMessageId: const {},
        geminiSignaturesByMessageId: const {},
      );

      await repository.updateStreamingCheckpoint(
        streaming.copyWith(content: 'integrity-draft-one'),
        const [],
      );
      await repository.updateStreamingCheckpoint(
        streaming.copyWith(content: 'integrity-draft-two'),
        const [],
      );
      await repository.updateStreamingCheckpoint(
        streaming.copyWith(
          content: 'integrity-final-token',
          isStreaming: false,
        ),
        const [
          {
            'id': 'tool-1',
            'name': 'lookup',
            'arguments': {'q': 'integrity-tool-only'},
            'content': 'integrity-tool-result',
          },
        ],
      );
      expect(
        (await repository.searchConversationMatches(
          tokens: const ['integrity-final-token'],
        )).single.messageId,
        'revision-1',
      );

      await repository.updateMessage(
        streaming.copyWith(
          content: 'integrity-edited-token',
          isStreaming: false,
        ),
      );
      expect(
        await repository.searchConversationMatches(
          tokens: const ['integrity-final-token'],
        ),
        isEmpty,
      );
      expect(
        (await repository.searchConversationMatches(
          tokens: const ['integrity-edited-token'],
        )).single.messageId,
        'revision-1',
      );

      await repository.deleteMessage('revision-1');
      expect(
        await repository.searchConversationMatches(
          tokens: const ['integrity-edited-token'],
        ),
        isEmpty,
      );

      await expectFtsIntegrity(repository, file);
    },
  );
}
