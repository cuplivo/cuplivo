import 'dart:io';

import 'package:Cuplivo/core/database/app_database.dart';
import 'package:Cuplivo/core/database/chat_database_repository.dart';
import 'package:Cuplivo/core/models/assistant.dart';
import 'package:Cuplivo/core/models/chat_message.dart';
import 'package:Cuplivo/core/models/conversation.dart';
import 'package:Cuplivo/core/services/proactive_care_message_flow.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart' as sqlite;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;
  late Future<String> Function() originalDataDirPathProvider;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('cuplivo_headless_db_');
    originalDataDirPathProvider =
        ProactiveCareHeadlessChatStore.dataDirPathProvider;
    await ProactiveCareHeadlessChatStore.close();
    ProactiveCareHeadlessChatStore.dataDirPathProvider = () async =>
        tempDir.path;
  });

  tearDown(() async {
    await ProactiveCareHeadlessChatStore.close();
    ProactiveCareHeadlessChatStore.dataDirPathProvider =
        originalDataDirPathProvider;
    if (await tempDir.exists()) await tempDir.delete(recursive: true);
  });

  test(
    'loads an assistant from a pre-v20 table without the cwd column',
    () async {
      final dbFile = File(p.join(tempDir.path, AppDatabase.databaseFileName));
      final repository = ChatDatabaseRepository.open(file: dbFile);
      await repository.ensureReady();
      await repository.putAssistant(
        Assistant(
          id: 'assistant-1',
          name: 'Legacy Assistant',
          proactiveCareDecisionHistoryMessageLimit: 23,
        ),
      );
      await repository.close();

      final rawDb = sqlite.sqlite3.open(dbFile.path);
      rawDb.execute(
        'ALTER TABLE assistant_rows '
        'DROP COLUMN workspace_default_directories_json',
      );
      rawDb.execute(
        'ALTER TABLE assistant_rows '
        'DROP COLUMN proactive_care_decision_history_message_limit',
      );
      rawDb.close();

      final assistant = await ProactiveCareHeadlessChatStore.loadAssistantFor(
        'assistant-1',
      );

      expect(assistant, isNotNull);
      expect(assistant!.workspaceDefaultDirectories, isEmpty);
      expect(assistant.proactiveCareDecisionHistoryMessageLimit, isNull);
    },
  );

  test('claims and clears only the exact conversation schedule once', () async {
    final dbFile = File(p.join(tempDir.path, AppDatabase.databaseFileName));
    final repository = ChatDatabaseRepository.open(file: dbFile);
    await repository.ensureReady();
    await repository.putAssistant(
      Assistant(id: 'assistant-1', name: 'Owner', enableProactiveCare: true),
    );
    final expectedAt = DateTime(2026, 8, 14, 12, 30, 45);
    await repository.putConversation(
      Conversation(
        id: 'target',
        title: 'Target',
        assistantId: 'assistant-1',
        proactiveCareNextMessageAt: expectedAt,
      ),
    );
    await repository.putConversation(
      Conversation(
        id: 'newest',
        title: 'Newest',
        assistantId: 'assistant-1',
        updatedAt: DateTime(2026, 8, 15),
      ),
    );
    await repository.putMessage(
      ChatMessage(
        id: 'target-message',
        role: 'user',
        content: 'Exact history',
        conversationId: 'target',
      ),
    );
    await repository.putMessage(
      ChatMessage(
        id: 'newest-message',
        role: 'user',
        content: 'Wrong history',
        conversationId: 'newest',
      ),
    );
    await repository.close();

    final claim =
        await ProactiveCareHeadlessChatStore.claimConversationSchedule(
          conversationId: 'target',
          expectedAt: expectedAt,
        );

    expect(claim?.conversation.id, 'target');
    expect(claim?.assistant.id, 'assistant-1');
    expect(claim?.messages.single.content, 'Exact history');
    expect(claim?.conversation.proactiveCareNextMessageAt, isNull);
    expect(
      await ProactiveCareHeadlessChatStore.claimConversationSchedule(
        conversationId: 'target',
        expectedAt: expectedAt,
      ),
      isNull,
    );
    expect(
      (await ProactiveCareHeadlessChatStore.loadConversation(
        'target',
      ))?.conversation.proactiveCareNextMessageAt,
      isNull,
    );
    expect(
      (await ProactiveCareHeadlessChatStore.loadConversation(
        'newest',
      ))?.messages.single.content,
      'Wrong history',
    );
  });

  test('mismatched expected timestamp does not consume schedule', () async {
    final dbFile = File(p.join(tempDir.path, AppDatabase.databaseFileName));
    final repository = ChatDatabaseRepository.open(file: dbFile);
    await repository.ensureReady();
    await repository.putAssistant(
      Assistant(id: 'assistant-1', name: 'Owner', enableProactiveCare: true),
    );
    final expectedAt = DateTime(2026, 8, 14, 12, 30);
    await repository.putConversation(
      Conversation(
        id: 'target',
        title: 'Target',
        assistantId: 'assistant-1',
        proactiveCareNextMessageAt: expectedAt,
      ),
    );
    await repository.close();

    expect(
      await ProactiveCareHeadlessChatStore.claimConversationSchedule(
        conversationId: 'target',
        expectedAt: expectedAt.add(const Duration(seconds: 1)),
      ),
      isNull,
    );
    expect(
      (await ProactiveCareHeadlessChatStore.loadConversation(
        'target',
      ))?.conversation.proactiveCareNextMessageAt,
      expectedAt,
    );
  });

  test('append rechecks exact owner and effective enabled state', () async {
    final dbFile = File(p.join(tempDir.path, AppDatabase.databaseFileName));
    final repository = ChatDatabaseRepository.open(file: dbFile);
    await repository.ensureReady();
    await repository.putAssistant(
      Assistant(id: 'assistant-1', name: 'Owner', enableProactiveCare: true),
    );
    final expectedAt = DateTime(2026, 8, 14, 12, 30);
    await repository.putConversation(
      Conversation(
        id: 'target',
        title: 'Target',
        assistantId: 'assistant-1',
        proactiveCareNextMessageAt: expectedAt,
      ),
    );
    await repository.close();
    expect(
      await ProactiveCareHeadlessChatStore.claimConversationSchedule(
        conversationId: 'target',
        expectedAt: expectedAt,
      ),
      isNotNull,
    );

    await ProactiveCareHeadlessChatStore.close();
    final rawDb = sqlite.sqlite3.open(dbFile.path);
    rawDb.execute(
      'UPDATE conversation_rows '
      'SET proactive_care_enabled_override = 0 WHERE id = ?',
      ['target'],
    );
    rawDb.close();

    expect(
      await ProactiveCareHeadlessChatStore.appendAssistantReply(
        conversationId: 'target',
        assistantId: 'assistant-1',
        content: 'Must not append',
      ),
      isNull,
    );
    await ProactiveCareHeadlessChatStore.close();
    final ownerChangedDb = sqlite.sqlite3.open(dbFile.path);
    ownerChangedDb.execute(
      'UPDATE conversation_rows '
      'SET proactive_care_enabled_override = NULL, assistant_id = ? '
      'WHERE id = ?',
      ['assistant-2', 'target'],
    );
    ownerChangedDb.close();
    expect(
      await ProactiveCareHeadlessChatStore.appendAssistantReply(
        conversationId: 'target',
        assistantId: 'assistant-1',
        content: 'Must not append after owner change',
      ),
      isNull,
    );
    expect(
      (await ProactiveCareHeadlessChatStore.loadConversation(
        'target',
      ))?.messages,
      isEmpty,
    );
  });

  test('appends and writes the next time to the exact conversation', () async {
    const previousSignature =
        '<!-- gemini_thought_signatures:{"text":{"k":"thoughtSignature","v":"previous"}} -->';
    const deliveredSignature =
        '<!-- gemini_thought_signatures:{"text":{"k":"thoughtSignature","v":"delivered"}} -->';
    final dbFile = File(p.join(tempDir.path, AppDatabase.databaseFileName));
    final repository = ChatDatabaseRepository.open(file: dbFile);
    await repository.ensureReady();
    await repository.putAssistant(
      Assistant(id: 'assistant-1', name: 'Owner', enableProactiveCare: true),
    );
    final expectedAt = DateTime(2026, 8, 14, 12, 30);
    await repository.putConversation(
      Conversation(
        id: 'target',
        title: 'Target',
        assistantId: 'assistant-1',
        proactiveCareNextMessageAt: expectedAt,
      ),
    );
    await repository.putConversation(
      Conversation(id: 'other', title: 'Other', assistantId: 'assistant-1'),
    );
    await repository.putMessage(
      ChatMessage(
        id: 'previous-message',
        role: 'assistant',
        content: 'Previous',
        conversationId: 'target',
      ),
    );
    await repository.setGeminiThoughtSignature(
      'previous-message',
      previousSignature,
    );
    await repository.close();
    final claim =
        await ProactiveCareHeadlessChatStore.claimConversationSchedule(
          conversationId: 'target',
          expectedAt: expectedAt,
        );
    expect(claim?.geminiThoughtSignaturesByMessageId, {
      'previous-message': previousSignature,
    });

    final appended = await ProactiveCareHeadlessChatStore.appendAssistantReply(
      conversationId: 'target',
      assistantId: 'assistant-1',
      content: 'Delivered',
      geminiThoughtSignature: deliveredSignature,
    );
    final nextAt = DateTime(2026, 8, 15, 9);
    final target =
        await ProactiveCareHeadlessChatStore.updateConversationNextTime(
          conversationId: 'target',
          assistantId: 'assistant-1',
          nextCareTime: nextAt,
        );

    expect(appended?.conversationId, 'target');
    expect(target?.conversation.id, 'target');
    expect(target?.conversation.proactiveCareNextMessageAt, nextAt);
    expect(
      (await ProactiveCareHeadlessChatStore.loadConversation(
        'target',
      ))?.messages.last.content,
      'Delivered',
    );
    expect(
      (await ProactiveCareHeadlessChatStore.loadConversation(
        'other',
      ))?.messages,
      isEmpty,
    );
    final laterCompletion = nextAt.add(const Duration(days: 1));
    final overwritten =
        await ProactiveCareHeadlessChatStore.updateConversationNextTime(
          conversationId: 'target',
          assistantId: 'assistant-1',
          nextCareTime: laterCompletion,
        );
    expect(
      overwritten?.conversation.proactiveCareNextMessageAt,
      laterCompletion,
      reason: 'the last completed write wins even when a schedule exists',
    );
    await ProactiveCareHeadlessChatStore.close();
    final verificationRepository = ChatDatabaseRepository.open(file: dbFile);
    await verificationRepository.ensureReady();
    expect(
      await verificationRepository.getGeminiThoughtSignature(appended!.id),
      deliveredSignature,
    );
    await verificationRepository.close();
  });

  test('pre-v22 database safely skips a conversation trigger', () async {
    final dbFile = File(p.join(tempDir.path, AppDatabase.databaseFileName));
    final rawDb = sqlite.sqlite3.open(dbFile.path);
    rawDb.execute('''
CREATE TABLE conversation_rows (
  id TEXT NOT NULL PRIMARY KEY,
  title TEXT NOT NULL,
  created_at INTEGER NOT NULL,
  updated_at INTEGER NOT NULL
);
''');
    rawDb.close();

    expect(
      await ProactiveCareHeadlessChatStore.claimConversationSchedule(
        conversationId: 'legacy',
        expectedAt: DateTime(2026, 8, 14),
      ),
      isNull,
    );
  });
}
