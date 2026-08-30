import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
// ignore: depend_on_referenced_packages
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:drift/native.dart';
import 'package:Cuplivo/core/database/app_database.dart';
import 'package:Cuplivo/core/database/chat_database_repository.dart';
import 'package:Cuplivo/core/models/assistant.dart';
import 'package:Cuplivo/core/models/chat_message.dart';
import 'package:Cuplivo/core/models/conversation.dart';
import 'package:Cuplivo/core/services/chat/chat_service.dart';

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

/// An initialized [ChatService] backed by an in-memory database.
class _InMemoryChatService extends ChatService {
  late final AppDatabase db;
  late final ChatDatabaseRepository _testRepo;

  _InMemoryChatService() {
    db = AppDatabase(NativeDatabase.memory());
    _testRepo = ChatDatabaseRepository(db);
  }

  @override
  bool get initialized => true;

  @override
  ChatDatabaseRepository get repo => _testRepo;

  @override
  Future<List<Assistant>> getAllAssistants() => _testRepo.getAllAssistants();

  @override
  Future<void> putAssistants(List<Assistant> list) =>
      _testRepo.putAssistants(list);

  @override
  Future<void> reloadCachesFromDb() async {}

  void closeDb() {
    _testRepo.close();
  }
}

ChatMessage _message({
  required String id,
  required String role,
  required String content,
  required String conversationId,
  bool isPreset = false,
}) {
  return ChatMessage(
    id: id,
    role: role,
    content: content,
    conversationId: conversationId,
    version: 0,
    isPreset: isPreset,
  );
}

void main() {
  group('ChatService.isRecyclablePresetOnlyConversation', () {
    late _InMemoryChatService service;

    setUp(() {
      service = _InMemoryChatService();
    });

    tearDown(() {
      service.closeDb();
    });

    test('0-message conversation is NOT recyclable', () async {
      final result = await service.isRecyclablePresetOnlyConversation('empty');
      expect(result, isFalse);
    });

    test('preset-only conversation IS recyclable', () async {
      await service.repo.putConversation(
        Conversation(id: 'preset-only', title: 'New Chat'),
      );
      await service.repo.putMessage(
        _message(
          id: 'p1',
          role: 'user',
          content: 'preset greeting',
          conversationId: 'preset-only',
          isPreset: true,
        ),
      );
      await service.repo.putMessage(
        _message(
          id: 'p2',
          role: 'assistant',
          content: 'preset reply',
          conversationId: 'preset-only',
          isPreset: true,
        ),
      );

      final result = await service.isRecyclablePresetOnlyConversation(
        'preset-only',
      );
      expect(result, isTrue);
    });

    test('preset + real message is NOT recyclable', () async {
      await service.repo.putConversation(
        Conversation(id: 'mixed', title: 'New Chat'),
      );
      await service.repo.putMessage(
        _message(
          id: 'p1',
          role: 'user',
          content: 'preset greeting',
          conversationId: 'mixed',
          isPreset: true,
        ),
      );
      await service.repo.putMessage(
        _message(
          id: 'r1',
          role: 'user',
          content: 'real question',
          conversationId: 'mixed',
          isPreset: false,
        ),
      );

      final result = await service.isRecyclablePresetOnlyConversation('mixed');
      expect(result, isFalse);
    });

    test('real-only conversation is NOT recyclable', () async {
      await service.repo.putConversation(
        Conversation(id: 'real-only', title: 'New Chat'),
      );
      await service.repo.putMessage(
        _message(
          id: 'r1',
          role: 'user',
          content: 'hello',
          conversationId: 'real-only',
          isPreset: false,
        ),
      );

      final result = await service.isRecyclablePresetOnlyConversation(
        'real-only',
      );
      expect(result, isFalse);
    });

    test('draft conversation (no repo rows) is NOT recyclable', () async {
      // createDraftConversation keeps the conversation in the in-memory draft
      // map with zero persisted rows — the predicate must not return true.
      final result = await service.isRecyclablePresetOnlyConversation(
        'some-draft',
      );
      expect(result, isFalse);
    });

    test('uninitialized service returns false', () async {
      final uninitialized = ChatService();
      final result = await uninitialized.isRecyclablePresetOnlyConversation(
        'x',
      );
      expect(result, isFalse);
    });
  });

  group('ChatService recycle lifecycle (#578 loop)', () {
    late Directory tempDir;
    late ChatService service;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('kelivo_preset_recycle_');
      PathProviderPlatform.instance = _FakePathProviderPlatform(tempDir.path);
      service = ChatService();
      await service.init();
    });

    tearDown(() async {
      await service.close();
      if (await tempDir.exists()) {
        await tempDir.delete(recursive: true);
      }
    });

    Future<Conversation> newPresetOnlyConversation() async {
      final convo = await service.createDraftConversation(title: 'New Chat');
      // Mirror HomeViewModel.createNewConversation's preset injection.
      await service.addMessage(
        conversationId: convo.id,
        role: 'user',
        content: 'preset user message',
        isPreset: true,
      );
      await service.addMessage(
        conversationId: convo.id,
        role: 'assistant',
        content: 'preset assistant message',
        isPreset: true,
      );
      return convo;
    }

    test('preset injection makes the new conversation recyclable', () async {
      final convo = await newPresetOnlyConversation();
      expect(
        await service.isRecyclablePresetOnlyConversation(convo.id),
        isTrue,
      );
      expect(service.getAllConversations().map((c) => c.id), [convo.id]);
    });

    test('complete recycle loop: delete removes all traces', () async {
      final convo = await newPresetOnlyConversation();
      expect(
        await service.isRecyclablePresetOnlyConversation(convo.id),
        isTrue,
      );
      await service.deleteConversation(convo.id);
      expect(service.getConversation(convo.id), isNull);
      expect(service.getAllConversations(), isEmpty);
      expect(
        await service.isRecyclablePresetOnlyConversation(convo.id),
        isFalse,
        reason: 'a deleted conversation must not be recyclable again',
      );
    });

    test('first real message after preset injection blocks recycle', () async {
      final convo = await newPresetOnlyConversation();
      // The user actually chats in the conversation — it is now user data.
      await service.addMessage(
        conversationId: convo.id,
        role: 'user',
        content: 'real question',
        isPreset: false,
      );
      expect(
        await service.isRecyclablePresetOnlyConversation(convo.id),
        isFalse,
      );
    });
  });
}
