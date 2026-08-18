import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
// ignore: depend_on_referenced_packages
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';

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

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;
  final services = <ChatService>[];

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp(
      'kelivo_chat_service_test_',
    );
    PathProviderPlatform.instance = _FakePathProviderPlatform(tempDir.path);
  });

  tearDown(() async {
    for (final service in services) {
      await service.close();
    }
    services.clear();
    if (await tempDir.exists()) {
      await tempDir.delete(recursive: true);
    }
  });

  ChatService createService() {
    final service = ChatService();
    services.add(service);
    return service;
  }

  group('ChatService temporary conversations', () {
    test(
      'workspace directory override updates and clears on a draft',
      () async {
        final service = createService();
        await service.init();
        final conversation = await service.createDraftConversation(
          title: 'Chat',
        );

        await service.setConversationWorkspaceDirectoryOverride(
          conversation.id,
          'workspace-a',
          '/workspace/session-a',
        );
        expect(
          service
              .getConversation(conversation.id)
              ?.workspaceDirectoryOverrides['workspace-a'],
          '/workspace/session-a',
        );

        await service.clearConversationWorkspaceDirectoryOverride(
          conversation.id,
          'workspace-a',
        );
        expect(
          service
              .getConversation(conversation.id)
              ?.workspaceDirectoryOverrides
              .containsKey('workspace-a'),
          isFalse,
        );
      },
    );

    test('ordinary draft persists when its first message is added', () async {
      final service = createService();
      await service.init();

      final conversation = await service.createDraftConversation(title: 'Chat');
      await service.addMessage(
        conversationId: conversation.id,
        role: 'user',
        content: 'hello',
      );

      expect(service.getAllConversations().map((c) => c.id), [conversation.id]);
      expect(service.getMessages(conversation.id), hasLength(1));
    });

    test(
      'temporary draft keeps messages in memory without entering history',
      () async {
        final service = createService();
        await service.init();

        final conversation = await service.createDraftConversation(
          title: 'Temporary Chat',
          temporary: true,
        );
        await service.addMessage(
          conversationId: conversation.id,
          role: 'user',
          content: 'secret',
        );

        expect(service.getAllConversations(), isEmpty);
        expect(service.getConversation(conversation.id), isNotNull);
        expect(service.getMessages(conversation.id), hasLength(1));
        expect(service.isTemporaryConversation(conversation.id), isTrue);
      },
    );

    test(
      'temporary conversation supports range and recent message reads',
      () async {
        final service = createService();
        await service.init();

        final conversation = await service.createDraftConversation(
          title: 'Temporary Chat',
          temporary: true,
        );
        for (var i = 0; i < 5; i++) {
          await service.addMessage(
            conversationId: conversation.id,
            role: i.isEven ? 'user' : 'assistant',
            content: 'temporary message $i',
          );
        }

        final range = service.getMessagesRange(
          conversation.id,
          start: 1,
          limit: 3,
        );
        final recent = service.getRecentMessages(
          conversation.id,
          minMessages: 2,
          maxMessages: 2,
        );

        expect(range.map((message) => message.content), [
          'temporary message 1',
          'temporary message 2',
          'temporary message 3',
        ]);
        expect(recent.map((message) => message.content), [
          'temporary message 3',
          'temporary message 4',
        ]);
      },
    );

    test(
      'temporary conversation is discarded when current conversation changes',
      () async {
        final service = createService();
        await service.init();

        final temporary = await service.createDraftConversation(
          title: 'Temporary Chat',
          temporary: true,
        );
        await service.addMessage(
          conversationId: temporary.id,
          role: 'user',
          content: 'secret',
        );

        final ordinary = await service.createDraftConversation(title: 'Chat');

        expect(service.getConversation(temporary.id), isNull);
        expect(service.getMessages(temporary.id), isEmpty);
        expect(service.currentConversationId, ordinary.id);
        expect(service.getAllConversations(), isEmpty);
      },
    );

    test('temporary message deletion only affects memory', () async {
      final service = createService();
      await service.init();

      final conversation = await service.createDraftConversation(
        title: 'Temporary Chat',
        temporary: true,
      );
      final message = await service.addMessage(
        conversationId: conversation.id,
        role: 'user',
        content: 'secret',
      );

      await service.deleteMessage(message.id);

      expect(service.getAllConversations(), isEmpty);
      expect(service.getMessages(conversation.id), isEmpty);
      expect(service.getConversation(conversation.id)?.messageIds, isEmpty);
    });

    test('temporary user message edit appends an in-memory version', () async {
      final service = createService();
      await service.init();

      final conversation = await service.createDraftConversation(
        title: 'Temporary Chat',
        temporary: true,
      );
      final original = await service.addMessage(
        conversationId: conversation.id,
        role: 'user',
        content: 'hello',
      );

      final edited = await service.appendMessageVersion(
        messageId: original.id,
        content: 'hello, edited',
      );

      expect(edited, isNotNull);
      expect(edited!.role, 'user');
      expect(edited.content, 'hello, edited');
      expect(edited.conversationId, conversation.id);
      expect(edited.groupId ?? edited.id, original.id);
      expect(edited.version, 1);

      expect(service.getMessages(conversation.id), hasLength(2));
      final convo = service.getConversation(conversation.id);
      expect(convo?.messageIds, contains(edited.id));
      expect(service.getVersionSelections(conversation.id), {original.id: 1});
    });

    test(
      'successive temporary edits increment the version within the group',
      () async {
        final service = createService();
        await service.init();

        final conversation = await service.createDraftConversation(
          title: 'Temporary Chat',
          temporary: true,
        );
        final original = await service.addMessage(
          conversationId: conversation.id,
          role: 'user',
          content: 'hello',
        );

        final first = await service.appendMessageVersion(
          messageId: original.id,
          content: 'first edit',
        );
        final second = await service.appendMessageVersion(
          messageId: original.id,
          content: 'second edit',
        );

        expect(first?.version, 1);
        expect(second?.version, 2);
        expect(second?.groupId ?? second?.id, original.id);
        expect(service.getVersionSelections(conversation.id), {original.id: 2});
      },
    );

    test(
      'appendMessageVersion returns null for an unknown message id',
      () async {
        final service = createService();
        await service.init();

        await service.createDraftConversation(
          title: 'Temporary Chat',
          temporary: true,
        );

        final edited = await service.appendMessageVersion(
          messageId: 'no-such-message',
          content: 'edited',
        );

        expect(edited, isNull);
      },
    );

    test('appendMessageVersion keeps the provided timestamp', () async {
      final service = createService();
      await service.init();

      final conversation = await service.createDraftConversation(
        title: 'Temporary Chat',
        temporary: true,
      );
      final original = await service.addMessage(
        conversationId: conversation.id,
        role: 'assistant',
        content: 'original answer',
      );
      final originalTime = DateTime(2024, 1, 1, 10, 30);

      final edited = await service.appendMessageVersion(
        messageId: original.id,
        content: 'edited answer',
        timestamp: originalTime,
      );

      expect(edited, isNotNull);
      expect(edited!.timestamp, originalTime);
    });

    test(
      'appendMessageVersion defaults to now when no timestamp is given',
      () async {
        final service = createService();
        await service.init();

        final conversation = await service.createDraftConversation(
          title: 'Temporary Chat',
          temporary: true,
        );
        final original = await service.addMessage(
          conversationId: conversation.id,
          role: 'user',
          content: 'hello',
        );
        final before = DateTime.now();

        final edited = await service.appendMessageVersion(
          messageId: original.id,
          content: 'hello, edited',
        );

        expect(edited, isNotNull);
        expect(edited!.timestamp.isBefore(before), isFalse);
      },
    );
  });

  group('ChatService fork conversations', () {
    test(
      'fork copies selected path as plain single-version messages',
      () async {
        final service = createService();
        await service.init();

        final source = await service.createConversation(title: 'Source');
        final original = await service.addMessage(
          conversationId: source.id,
          role: 'assistant',
          content: 'original answer',
        );
        final edited = await service.appendMessageVersion(
          messageId: original.id,
          content: 'edited answer',
        );
        expect(edited, isNotNull);

        final fork = await service.forkConversation(
          title: 'Fork',
          assistantId: null,
          sourceMessages: [edited!],
        );

        final forkMessages = service.getMessages(fork.id);
        expect(forkMessages, hasLength(1));
        expect(forkMessages.single.conversationId, fork.id);
        expect(forkMessages.single.content, 'edited answer');
        expect(
          forkMessages.single.groupId ?? forkMessages.single.id,
          forkMessages.single.id,
        );
        expect(forkMessages.single.version, 0);
        expect(service.getVersionSelections(fork.id), isEmpty);
      },
    );
  });
}
