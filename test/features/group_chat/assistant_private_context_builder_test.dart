import 'package:Cuplivo/core/models/assistant.dart';
import 'package:Cuplivo/core/models/chat_message.dart';
import 'package:Cuplivo/core/models/conversation.dart';
import 'package:Cuplivo/core/models/group_chat.dart';
import 'package:Cuplivo/core/services/chat/chat_service.dart';
import 'package:Cuplivo/features/group_chat/services/assistant_private_context_builder.dart';
import 'package:flutter_test/flutter_test.dart';

class _FakeChatService extends ChatService {
  @override
  List<Map<String, dynamic>> getToolEvents(String messageId) => const [];
}

void main() {
  test('private context rewrites other speakers as prefixed user lines', () {
    final service = _FakeChatService();
    final builder = AssistantPrivateContextBuilder(chatService: service);
    final conv = Conversation(
      id: 'c1',
      title: 'g',
      conversationKind: Conversation.kindGroup,
    );
    final alice = Assistant(id: 'a1', name: 'Alice', systemPrompt: 'A');
    final bob = Assistant(id: 'a2', name: 'Bob', systemPrompt: 'B');

    final public = [
      ChatMessage(role: 'user', content: 'Hello all', conversationId: 'c1'),
      ChatMessage(
        role: 'assistant',
        content: 'Hi from Alice',
        conversationId: 'c1',
        speakerAssistantId: 'a1',
      ),
      ChatMessage(
        role: 'assistant',
        content: 'Hi from Bob',
        conversationId: 'c1',
        speakerAssistantId: 'a2',
      ),
      ChatMessage(role: 'user', content: 'Continue', conversationId: 'c1'),
    ];

    final private = builder.build(
      conversation: conv,
      publicMessages: public,
      speaker: alice,
      userName: 'User',
      assistantsById: {'a1': alice, 'a2': bob},
    );

    // Alice sees her own message as assistant; others as user-prefixed.
    expect(private.any((m) => m.role == 'assistant'), isTrue);
    final userJoined = private
        .where((m) => m.role == 'user')
        .map((m) => m.content)
        .join('\n');
    expect(userJoined, contains('[User]: Hello all'));
    expect(userJoined, contains('[Bob]: Hi from Bob'));
    expect(userJoined, contains('[User]: Continue'));
  });

  test('private context collapse defaults to last version by index', () {
    final service = _FakeChatService();
    final builder = AssistantPrivateContextBuilder(chatService: service);
    final conv = Conversation(
      id: 'c1',
      title: 'g',
      conversationKind: Conversation.kindGroup,
    );
    final alice = Assistant(id: 'a1', name: 'Alice', systemPrompt: 'A');
    const gid = 'ag';
    final public = [
      ChatMessage(role: 'user', content: 'Q', conversationId: 'c1'),
      ChatMessage(
        id: 'v0',
        role: 'assistant',
        content: 'old',
        conversationId: 'c1',
        speakerAssistantId: 'a1',
        groupId: gid,
        version: 0,
      ),
      ChatMessage(
        id: 'v1',
        role: 'assistant',
        content: 'new',
        conversationId: 'c1',
        speakerAssistantId: 'a1',
        groupId: gid,
        version: 1,
      ),
    ];

    final private = builder.build(
      conversation: conv,
      publicMessages: public,
      speaker: alice,
      userName: 'User',
      assistantsById: {'a1': alice},
    );
    final assistant = private.where((m) => m.role == 'assistant').single;
    expect(assistant.content, 'new');
  });

  test(
    'private context truncation follows raw-space boundary across versions',
    () {
      final service = _FakeChatService();
      final builder = AssistantPrivateContextBuilder(chatService: service);
      final alice = Assistant(id: 'a1', name: 'Alice', systemPrompt: 'A');
      final conv = Conversation(
        id: 'c1',
        title: 'g',
        conversationKind: Conversation.kindGroup,
        truncateIndex: 2,
      );
      const gid = 'ag';
      final public = [
        ChatMessage(
          id: 'u0',
          role: 'user',
          content: 'Old start',
          conversationId: 'c1',
        ),
        ChatMessage(
          id: 'v0',
          role: 'assistant',
          content: 'old version',
          conversationId: 'c1',
          speakerAssistantId: 'a1',
          groupId: gid,
          version: 0,
        ),
        ChatMessage(
          id: 'v1',
          role: 'assistant',
          content: 'new version',
          conversationId: 'c1',
          speakerAssistantId: 'a1',
          groupId: gid,
          version: 1,
        ),
        ChatMessage(
          id: 'u1',
          role: 'user',
          content: 'Continue',
          conversationId: 'c1',
        ),
      ];

      // Raw boundary 2: u0 (anchor 0) and the versioned group (anchor 1) are
      // both before it; only u1 survives. Collapsed-space indexing would have
      // kept the versioned group instead.
      final private = builder.build(
        conversation: conv,
        publicMessages: public,
        speaker: alice,
        userName: 'User',
        assistantsById: {'a1': alice},
      );

      expect(private, hasLength(1));
      expect(private.single.role, 'user');
      expect(private.single.content, contains('[User]: Continue'));
    },
  );

  test('group member injection is null when disabled', () {
    final group = GroupChat(
      name: 'G',
      conversationId: 'c1',
      injectGroupMembersIntoAssistantSystemPrompt: false,
    );
    final injection = AssistantPrivateContextBuilder.buildGroupMemberInjection(
      group: group,
      userName: 'User',
      memberNames: const ['Alpha', 'Beta'],
    );
    expect(injection, isNull);
  });

  test('group member injection lists user then member names when enabled', () {
    final group = GroupChat(
      name: 'G',
      conversationId: 'c1',
      injectGroupMembersIntoAssistantSystemPrompt: true,
    );
    final injection = AssistantPrivateContextBuilder.buildGroupMemberInjection(
      group: group,
      userName: 'User',
      memberNames: const ['Alpha', 'Beta'],
    );
    expect(injection, isNotNull);
    expect(injection, contains('你现在处于一个群聊中'));
    expect(injection, contains('User'));
    expect(injection, contains('Alpha'));
    expect(injection, contains('Beta'));
  });

  test('group member injection is enabled by default for new groups', () {
    final group = GroupChat(name: 'G', conversationId: 'c1');
    final injection = AssistantPrivateContextBuilder.buildGroupMemberInjection(
      group: group,
      userName: 'User',
      memberNames: const ['Alpha'],
    );
    expect(injection, isNotNull);
    expect(injection, contains('Alpha'));
  });
}
