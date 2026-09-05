import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
// ignore: depend_on_referenced_packages
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';

import 'package:Cuplivo/core/models/chat_message.dart';
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

        final source = await service.createConversation(
          title: 'Source',
          persistentQuickInstructionIds: const <String>['persistent-1'],
        );
        final original = await service.addMessage(
          conversationId: source.id,
          role: 'assistant',
          content: 'original answer',
          quickInstructionInvocationsJson: '[{"instructionId":"snapshot-1"}]',
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
        expect(fork.persistentQuickInstructionIds, const <String>[
          'persistent-1',
        ]);
        expect(
          forkMessages.single.quickInstructionInvocationsJson,
          '[{"instructionId":"snapshot-1"}]',
        );
        expect(
          forkMessages.single.groupId ?? forkMessages.single.id,
          forkMessages.single.id,
        );
        expect(forkMessages.single.version, 0);
        expect(service.getVersionSelections(fork.id), isEmpty);
      },
    );

    test(
      'empty-prefix fork inherits current conversation activations',
      () async {
        final service = createService();
        await service.init();

        await service.createConversation(
          title: 'Source',
          persistentQuickInstructionIds: const <String>['persistent-1'],
        );

        final fork = await service.forkConversation(
          title: 'Fork',
          assistantId: null,
          sourceMessages: const <ChatMessage>[],
        );

        expect(fork.persistentQuickInstructionIds, const <String>[
          'persistent-1',
        ]);
      },
    );

    test('preserve-mode fork carries every version, remaps groups and '
        'forces the forked revision selection', () async {
      final service = createService();
      await service.init();

      final source = await service.createConversation(title: 'Source');
      final user = await service.addMessage(
        conversationId: source.id,
        role: 'user',
        content: 'question',
      );
      final original = await service.addMessage(
        conversationId: source.id,
        role: 'assistant',
        content: 'answer v0',
      );
      final edited = await service.appendMessageVersion(
        messageId: original.id,
        content: 'answer v1',
      );
      expect(user.id, isNot(original.id));
      expect(edited, isNotNull);

      final target = await service.addMessage(
        conversationId: source.id,
        role: 'user',
        content: 'second question',
      );

      await service.setToolEvents(edited!.id, [
        {'id': 'tool-call', 'name': 'search', 'result': 'done'},
      ]);
      await service.setGeminiThoughtSignature(edited.id, 'sig-v1');

      final fork = await service.forkConversation(
        title: 'Fork',
        assistantId: null,
        sourceMessages: [user, original, edited, target],
        preserveVersions: true,
        sourceVersionSelections: {original.id: 0},
        forkTargetMessageId: edited.id,
      );

      final forkMessages = service.getMessages(fork.id);
      expect(forkMessages, hasLength(4));

      final byContent = {for (final m in forkMessages) m.content: m};
      // All rows of the kept context are present with version counters.
      expect(byContent['answer v0']!.version, 0);
      expect(byContent['answer v1']!.version, 1);
      // The anchor clone emulates the source anchor (groupId == own id is
      // the factory normalization of null); the v1 clone references it.
      expect(byContent['answer v0']!.groupId, byContent['answer v0']!.id);
      expect(byContent['answer v1']!.groupId, byContent['answer v0']!.id);
      // Origin ids are never carried into the fork (fresh identities).
      expect(byContent['answer v0']!.id, isNot(original.id));
      expect(byContent['answer v1']!.id, isNot(edited.id));
      // subgroupId must be stripped even if the source rows carried it.
      expect(byContent['answer v0']!.subgroupId, isNull);
      // Every clone lives in the fork conversation.
      expect(forkMessages.map((m) => m.conversationId).toSet(), {fork.id});

      // The new conversation's selection map uses the remapped group key
      // (the anchor clone's new id) and points at the forked-off revision's
      // index (the v1 clone sits at index 1 in the sorted group). Only the
      // forked target group is written; the plain user groups carry no
      // selection entries.
      final newSelections = service.getVersionSelections(fork.id);
      expect(newSelections, {byContent['answer v0']!.id: 1});
      // Verify tool events + signature rode along to the v1 clone.
      final v1Clone = byContent['answer v1']!;
      expect(service.getToolEvents(v1Clone.id), [
        {'id': 'tool-call', 'name': 'search', 'result': 'done'},
      ]);
      expect(service.getGeminiThoughtSignature(v1Clone.id), 'sig-v1');

      // The user group keeps no selection entry (map uses group keys only).
      expect(newSelections.containsKey(byContent['question']!.id), isFalse);
    });

    test('preserve-mode fork keeps source selections of earlier groups, drops '
        'unknowns, and forces the forked revision index', () async {
      final service = createService();
      await service.init();

      final source = await service.createConversation(title: 'Source');
      final user1 = await service.addMessage(
        conversationId: source.id,
        role: 'user',
        content: 'q1',
      );
      final a1v0 = await service.addMessage(
        conversationId: source.id,
        role: 'assistant',
        content: 'a1 v0',
      );
      final a1v1 = (await service.appendMessageVersion(
        messageId: a1v0.id,
        content: 'a1 v1',
      ))!;
      expect(a1v1.id, isNot(a1v0.id));

      // Fork at a1v0. The caller supplies the cut itself (user1 + both a1
      // versions); the source map carries an entry for a group that ia not
      // in the cut (dropped), plus a stale target selection (overridden).
      final fork = await service.forkConversation(
        title: 'Fork',
        assistantId: null,
        sourceMessages: [user1, a1v0, a1v1],
        preserveVersions: true,
        sourceVersionSelections: {a1v0.id: 1, 'unknown-group': 0},
        forkTargetMessageId: a1v0.id,
      );

      final forkMessages = service.getMessages(fork.id);
      expect(forkMessages.map((m) => m.content).toList(), [
        'q1',
        'a1 v0',
        'a1 v1',
      ]);
      // The anchor clone's group key is its own new id (factory
      // normalization of the anchor's null groupId); the v1 clone must
      // reference it, and the selection must be forced onto that key.
      final aGroup = forkMessages[1].id;
      expect(forkMessages[1].groupId, aGroup);
      expect(forkMessages[2].groupId, aGroup);
      // The a1 group's position selection is the forked-off revision (0),
      // the stale target index (1) and the unknown group are gone.
      expect(service.getVersionSelections(fork.id), {aGroup: 0});
    });

    test('preserve-mode fork carries tool events and signatures from a '
        'temporary source conversation', () async {
      final service = createService();
      await service.init();

      final temporary = await service.createDraftConversation(
        title: 'Temporary Chat',
        temporary: true,
      );
      final answer = await service.addMessage(
        conversationId: temporary.id,
        role: 'assistant',
        content: 'temp answer',
      );
      await service.setToolEvents(answer.id, [
        {'id': 'tool-temp', 'name': 'temp-search', 'result': 'ok'},
      ]);
      await service.setGeminiThoughtSignature(answer.id, 'temp-sig');

      final fork = await service.forkConversation(
        title: 'Fork',
        assistantId: null,
        sourceMessages: [answer],
        preserveVersions: true,
        sourceVersionSelections: const {},
        forkTargetMessageId: answer.id,
      );

      // The temporary source conversation is discarded by the fork.
      expect(service.getConversation(temporary.id), isNull);

      final forkMessages = service.getMessages(fork.id);
      expect(forkMessages, hasLength(1));
      expect(forkMessages.single.content, 'temp answer');
      expect(forkMessages.single.id, isNot(answer.id));
      expect(service.getToolEvents(forkMessages.single.id), [
        {'id': 'tool-temp', 'name': 'temp-search', 'result': 'ok'},
      ]);
      expect(
        service.getGeminiThoughtSignature(forkMessages.single.id),
        'temp-sig',
      );
    });
  });
}
