import 'dart:convert';
import 'dart:io';

import 'package:Cuplivo/core/database/app_database.dart';
import 'package:Cuplivo/core/database/business_preferences.dart';
import 'package:Cuplivo/core/database/business_repository.dart';
import 'package:Cuplivo/core/database/chat_database_repository.dart';
import 'package:Cuplivo/core/models/assistant.dart';
import 'package:Cuplivo/core/models/chat_message.dart';
import 'package:Cuplivo/core/models/conversation.dart';
import 'package:Cuplivo/core/services/chat/chat_service.dart';
import 'package:Cuplivo/core/services/memory/memory_repository.dart';
import 'package:Cuplivo/core/services/memory/memory_tools.dart';
import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
// ignore: depend_on_referenced_packages
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';

class _FakePathProviderPlatform extends PathProviderPlatform {
  _FakePathProviderPlatform(this.path);

  final String path;

  @override
  Future<String?> getApplicationDocumentsPath() async => path;

  @override
  Future<String?> getApplicationSupportPath() async => path;

  @override
  Future<String?> getApplicationCachePath() async => '$path/cache';

  @override
  Future<String?> getTemporaryPath() async => '$path/tmp';
}

void main() {
  Future<void> seedConversation(
    ChatDatabaseRepository repository, {
    required String id,
    required String? assistantId,
    required String content,
    DateTime? updatedAt,
  }) {
    final stamp = updatedAt ?? DateTime.utc(2026, 7, 12);
    return repository.putMigrationBatch(
      conversations: [
        Conversation(
          id: id,
          title: id,
          createdAt: stamp,
          updatedAt: stamp,
          assistantId: assistantId,
          messageIds: ['$id-msg'],
        ),
      ],
      messages: [
        (
          message: ChatMessage(
            id: '$id-msg',
            role: 'user',
            content: content,
            timestamp: stamp,
            conversationId: id,
          ),
          messageOrder: 0,
        ),
      ],
      toolEventsByMessageId: const {},
      geminiSignaturesByMessageId: const {},
    );
  }

  test(
    'searchConversationMatches isolates assistants and keeps unowned chats',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'memory_assistant_isolation_',
      );
      final repository = ChatDatabaseRepository.open(
        file: File('${root.path}/search.sqlite'),
      );
      addTearDown(() async {
        await repository.close();
        await root.delete(recursive: true);
      });

      await seedConversation(
        repository,
        id: 'conv-a',
        assistantId: 'assistant-a',
        content: 'shared-needle assistant-a-secret',
      );
      await seedConversation(
        repository,
        id: 'conv-b',
        assistantId: 'assistant-b',
        content: 'shared-needle assistant-b-secret',
      );
      await seedConversation(
        repository,
        id: 'conv-unowned',
        assistantId: null,
        content: 'shared-needle unowned-secret',
      );

      final unscoped = await repository.searchConversationMatches(
        tokens: const ['shared-needle'],
      );
      expect(unscoped.map((m) => m.conversationId).toSet(), {
        'conv-a',
        'conv-b',
        'conv-unowned',
      });

      final forB = await repository.searchConversationMatches(
        tokens: const ['shared-needle'],
        assistantId: 'assistant-b',
      );
      expect(forB.map((m) => m.conversationId).toSet(), {
        'conv-b',
        'conv-unowned',
      });

      final forA = await repository.searchConversationMatches(
        tokens: const ['shared-needle'],
        assistantId: 'assistant-a',
      );
      expect(forA.map((m) => m.conversationId).toSet(), {
        'conv-a',
        'conv-unowned',
      });

      expect(
        await repository.searchConversationMatches(
          tokens: const ['assistant-a-secret'],
          assistantId: 'assistant-b',
        ),
        isEmpty,
      );
    },
  );

  test(
    'chat_search tool does not return another assistant\'s conversations',
    () async {
      driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
      final root = await Directory.systemTemp.createTemp(
        'memory_chat_search_isolation_',
      );
      final previousPathProvider = PathProviderPlatform.instance;
      PathProviderPlatform.instance = _FakePathProviderPlatform(root.path);
      final repository = ChatDatabaseRepository.open(
        file: File('${root.path}/search.sqlite'),
      );
      final memoryDatabase = AppDatabase(
        NativeDatabase.memory(
          setup: (raw) => raw.execute('PRAGMA foreign_keys = ON;'),
        ),
      );
      final memoryRepository = MemoryRepository(
        BusinessPreferences(BusinessRepository(memoryDatabase)),
      );
      addTearDown(() async {
        PathProviderPlatform.instance = previousPathProvider;
        await repository.close();
        await memoryDatabase.close();
        if (await root.exists()) {
          await root.delete(recursive: true);
        }
      });

      await seedConversation(
        repository,
        id: 'conv-a',
        assistantId: 'assistant-a',
        content: 'shared-needle assistant-a-secret',
      );
      await seedConversation(
        repository,
        id: 'conv-b',
        assistantId: 'assistant-b',
        content: 'shared-needle assistant-b-secret',
      );
      await seedConversation(
        repository,
        id: 'conv-unowned',
        assistantId: null,
        content: 'shared-needle unowned-secret',
      );

      final chatService = ChatService(existingRepository: repository);
      addTearDown(chatService.close);
      await chatService.init();

      Future<Set<String>> searchAs(String assistantId) async {
        final raw = await MemoryTools.handle(
          name: MemoryTools.chatSearch,
          args: {'query': 'shared-needle'},
          assistant: Assistant(
            id: assistantId,
            name: assistantId,
            enableMemory: false,
            allowPastConversationRecall: true,
          ),
          repository: memoryRepository,
          chatRepository: repository,
          chatService: chatService,
        );
        expect(raw, isNotNull);
        final results = (jsonDecode(raw!) as Map)['results'] as List;
        return {
          for (final row in results) (row as Map)['conversationId'] as String,
        };
      }

      expect(await searchAs('assistant-b'), {'conv-b', 'conv-unowned'});
      expect(await searchAs('assistant-a'), {'conv-a', 'conv-unowned'});
    },
  );
}
