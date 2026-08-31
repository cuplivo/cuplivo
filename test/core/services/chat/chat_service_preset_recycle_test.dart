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

    test(
      'first message persists proactive-care settings from a draft',
      () async {
        final nextAt = DateTime.utc(2099, 1, 2, 3, 4, 5);
        final convo = await service.createDraftConversation(
          title: 'Draft',
          assistantId: 'assistant-1',
        );

        await service.setConversationProactiveCareEnabledOverride(
          convo.id,
          false,
        );
        await service.setConversationProactiveCareNextMessageAt(
          convo.id,
          nextAt,
        );

        expect(service.isDraftConversation(convo.id), isTrue);
        expect(
          service.getConversation(convo.id)?.proactiveCareEnabledOverride,
          isFalse,
        );

        await service.addMessage(
          conversationId: convo.id,
          role: 'user',
          content: 'persist this draft',
        );

        final persisted = await service.repo.getConversation(convo.id);
        expect(service.isDraftConversation(convo.id), isFalse);
        expect(persisted?.proactiveCareEnabledOverride, isFalse);
        expect(
          persisted?.proactiveCareNextMessageAt?.isAtSameMomentAs(nextAt),
          isTrue,
        );
      },
    );

    test('temporary conversations reject proactive-care settings', () async {
      final convo = await service.createDraftConversation(
        title: 'Temporary',
        assistantId: 'assistant-1',
        temporary: true,
      );

      await expectLater(
        service.setConversationProactiveCareEnabledOverride(convo.id, true),
        throwsStateError,
      );
      await expectLater(
        service.setConversationProactiveCareNextMessageAt(
          convo.id,
          DateTime.utc(2099),
        ),
        throwsStateError,
      );
    });

    test('ownerless and group conversations reject proactive care', () async {
      final ownerless = await service.createDraftConversation(
        title: 'No owner',
      );
      await expectLater(
        service.setConversationProactiveCareEnabledOverride(ownerless.id, true),
        throwsStateError,
      );

      final group = await service.createConversation(
        title: 'Group',
        assistantId: 'assistant-1',
      );
      group.conversationKind = Conversation.kindGroup;
      await expectLater(
        service.setConversationProactiveCareEnabledOverride(group.id, true),
        throwsStateError,
      );
    });

    test(
      'foreground claim clears the cache and returns exact history',
      () async {
        final expectedAt = DateTime.utc(2099, 2, 3, 4, 5, 6);
        await service.putAssistant(
          Assistant(
            id: 'assistant-1',
            name: 'Owner',
            enableProactiveCare: true,
          ),
        );
        final convo = await service.createDraftConversation(
          title: 'Target',
          assistantId: 'assistant-1',
        );
        await service.setConversationProactiveCareNextMessageAt(
          convo.id,
          expectedAt,
        );
        await service.addMessage(
          conversationId: convo.id,
          role: 'user',
          content: 'exact history',
        );

        final claim = await service.claimConversationProactiveCareSchedule(
          conversationId: convo.id,
          expectedAt: expectedAt,
        );

        expect(claim?.conversation.id, convo.id);
        expect(claim?.messages.single.content, 'exact history');
        expect(
          service.getConversation(convo.id)?.proactiveCareNextMessageAt,
          isNull,
        );
        expect(
          await service.claimConversationProactiveCareSchedule(
            conversationId: convo.id,
            expectedAt: expectedAt,
          ),
          isNull,
        );
      },
    );

    test(
      'concurrent proactive-care setting writes retain both fields',
      () async {
        final nextAt = DateTime.utc(2099, 3, 4, 5, 6, 7);
        final convo = await service.createDraftConversation(
          title: 'Target',
          assistantId: 'assistant-1',
        );
        await service.addMessage(
          conversationId: convo.id,
          role: 'user',
          content: 'persist conversation',
        );

        await Future.wait([
          service.setConversationProactiveCareEnabledOverride(convo.id, false),
          service.setConversationProactiveCareNextMessageAt(convo.id, nextAt),
        ]);

        final saved = await service.repo.getConversation(convo.id);
        expect(saved?.proactiveCareEnabledOverride, isFalse);
        expect(
          saved?.proactiveCareNextMessageAt?.isAtSameMomentAs(nextAt),
          isTrue,
        );
      },
    );

    test(
      'close queued before proactive-care append prevents delivery',
      () async {
        await service.putAssistant(
          Assistant(
            id: 'assistant-1',
            name: 'Owner',
            enableProactiveCare: true,
          ),
        );
        final convo = await service.createDraftConversation(
          title: 'Target',
          assistantId: 'assistant-1',
        );
        await service.addMessage(
          conversationId: convo.id,
          role: 'user',
          content: 'existing history',
        );

        final disable = service.setConversationProactiveCareEnabledOverride(
          convo.id,
          false,
        );
        final appended = service.appendProactiveCareReplyIfEligible(
          conversationId: convo.id,
          assistantId: 'assistant-1',
          content: 'Must not be delivered',
        );
        await disable;

        expect(await appended, isNull);
        expect(
          (await service.repo.getMessagesRange(
            convo.id,
            start: 0,
            limit: 10,
          )).map((message) => message.content),
          ['existing history'],
        );
        expect(
          (await service.repo.getConversation(
            convo.id,
          ))?.proactiveCareEnabledOverride,
          isFalse,
        );
      },
    );
  });
}
