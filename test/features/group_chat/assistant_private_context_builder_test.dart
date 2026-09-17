import 'package:flutter_test/flutter_test.dart';

import 'package:Cuplivo/core/models/assistant.dart';
import 'package:Cuplivo/core/models/chat_message.dart';
import 'package:Cuplivo/core/models/conversation.dart';
import 'package:Cuplivo/core/models/group_chat.dart';
import 'package:Cuplivo/core/models/message_part.dart';
import 'package:Cuplivo/core/services/chat/chat_service.dart';
import 'package:Cuplivo/features/group_chat/services/assistant_private_context_builder.dart';

class _FakeChatService extends ChatService {
  @override
  List<Map<String, dynamic>> getToolEvents(String assistantMessageId) =>
      const [];
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final service = _FakeChatService();
  final builder = AssistantPrivateContextBuilder(chatService: service);

  Conversation conversation({int truncateIndex = -1}) => Conversation(
    id: 'c1',
    title: 'g',
    extras: const {'group.kind': 'group'},
    truncateIndex: truncateIndex,
  );

  const alice = Assistant(id: 'a1', name: 'Alice', systemPrompt: 'A');
  const bob = Assistant(id: 'a2', name: 'Bob', systemPrompt: 'B');
  final assistantsById = {'a1': alice, 'a2': bob};

  ChatMessage user(String content, {List<MessagePart>? parts}) => ChatMessage(
    role: 'user',
    content: content,
    parts: parts,
    conversationId: 'c1',
  );

  ChatMessage member(String content, String senderId) => ChatMessage(
    role: 'assistant',
    content: content,
    conversationId: 'c1',
    senderId: senderId,
  );

  test(
    'rewrites other speakers as prefixed user lines, keeps own as assistant',
    () {
      final public = [
        user('Hello all'),
        member('Hi from Alice', 'a1'),
        member('Hi from Bob', 'a2'),
        user('Continue'),
      ];

      final private = builder.build(
        conversation: conversation(),
        publicMessages: public,
        speaker: alice,
        userName: 'User',
        assistantsById: assistantsById,
      );

      expect(
        private.where((m) => m.role == 'assistant').single.content,
        'Hi from Alice',
      );
      final userJoined = private
          .where((m) => m.role == 'user')
          .map((m) => m.content)
          .join('\n');
      expect(userJoined, contains('[User]: Hello all'));
      expect(userJoined, contains('[Bob]: Hi from Bob'));
      expect(userJoined, contains('[User]: Continue'));
      // The director never appears in a member's context.
      expect(userJoined, isNot(contains(DirectorReminderProbe.reminder)));
    },
  );

  test('version collapse defaults to the last version of a group', () {
    const gid = 'ag';
    final public = [
      user('Q'),
      member('old', 'a1').copyWith(groupId: gid, version: 0),
      member('new', 'a1').copyWith(groupId: gid, version: 1),
    ];

    final private = builder.build(
      conversation: conversation(),
      publicMessages: public,
      speaker: alice,
      userName: 'User',
      assistantsById: assistantsById,
    );

    expect(private.where((m) => m.role == 'assistant').single.content, 'new');
  });

  test('clear-context boundary slices collapsed slots', () {
    const gid = 'ag';
    final public = [
      user('Old start'),
      member('old version', 'a1').copyWith(groupId: gid, version: 0),
      member('new version', 'a1').copyWith(groupId: gid, version: 1),
      user('Continue'),
    ];

    // Logical slots before the boundary: [user-0, group ag] — both dropped.
    final private = builder.build(
      conversation: conversation(truncateIndex: 2),
      publicMessages: public,
      speaker: alice,
      userName: 'User',
      assistantsById: assistantsById,
    );

    expect(private, hasLength(1));
    expect(private.single.role, 'user');
    expect(private.single.content, '[User]: Continue');
  });

  test('trailing member-only bubble keeps the human turn attachments', () {
    final public = [
      user(
        '',
        parts: [
          TextPart('看图 '),
          ImagePart(uri: '/tmp/photo.png', mime: 'image/png'),
        ],
      ),
      member('好的', 'a1'),
      member('补充一点', 'a2'),
    ];

    final private = builder.build(
      conversation: conversation(),
      publicMessages: public,
      speaker: alice,
      userName: 'User',
      assistantsById: assistantsById,
    );

    final bubbles = private.where((m) => m.role == 'user').toList();
    expect(bubbles, hasLength(2));
    expect(bubbles.last.content, contains('[Bob]: 补充一点'));
    expect(bubbles.last.parts.whereType<ImagePart>().map((p) => p.uri), [
      '/tmp/photo.png',
    ]);
  });

  test(
    'a new media-less human turn does not inherit the previous turn media',
    () {
      final public = [
        user(
          '',
          parts: [
            TextPart('看图 '),
            ImagePart(uri: '/tmp/photo.png', mime: 'image/png'),
          ],
        ),
        member('好的', 'a1'),
        member('补充一点', 'a2'),
        user('继续'),
      ];

      final private = builder.build(
        conversation: conversation(),
        publicMessages: public,
        speaker: alice,
        userName: 'User',
        assistantsById: assistantsById,
      );

      final lastUser = private.where((m) => m.role == 'user').last;
      expect(lastUser.content, endsWith('[User]: 继续'));
      expect(lastUser.parts.whereType<ImagePart>(), isEmpty);
    },
  );

  test('own message keeps its reasoning and tool cards for the speaker', () {
    final own = ChatMessage(
      role: 'assistant',
      conversationId: 'c1',
      senderId: 'a1',
      parts: [
        ReasoningPart('private thought'),
        TextPart('visible answer'),
        ToolCallPart('{"id":"c1","name":"read_file"}'),
      ],
    );

    final private = builder.build(
      conversation: conversation(),
      publicMessages: [user('Q'), own],
      speaker: alice,
      userName: 'User',
      assistantsById: assistantsById,
    );

    final assistant = private.where((m) => m.role == 'assistant').single;
    expect(assistant.parts.map((p) => p.kind), [
      'reasoning',
      'text',
      'tool_call',
    ]);
    expect(assistant.senderId, 'a1');
  });

  test('member limit trims the rewritten timeline from the front', () {
    const limited = Assistant(
      id: 'a1',
      name: 'Alice',
      systemPrompt: 'A',
      limitContextMessages: true,
      contextMessageSize: 2,
    );
    final public = [
      user('one'),
      member('two', 'a2'),
      user('three'),
      member('four', 'a1'),
    ];

    final private = builder.build(
      conversation: conversation(),
      publicMessages: public,
      speaker: limited,
      userName: 'User',
      assistantsById: assistantsById,
    );

    expect(private, hasLength(2));
    expect(private.first.content, contains('[User]: three'));
    expect(private.last.role, 'assistant');
  });

  group('buildGroupMemberInjection', () {
    test('is null when disabled', () {
      final injection =
          AssistantPrivateContextBuilder.buildGroupMemberInjection(
            group: GroupChat(
              name: 'G',
              conversationId: 'c1',
              injectGroupMembersIntoAssistantSystemPrompt: false,
            ),
            userName: 'User',
            memberNames: const ['Alpha', 'Beta'],
          );
      expect(injection, isNull);
    });

    test('lists the user before the member names when enabled', () {
      final injection =
          AssistantPrivateContextBuilder.buildGroupMemberInjection(
            group: GroupChat(name: 'G', conversationId: 'c1'),
            userName: 'User',
            memberNames: const ['Alpha', 'Beta'],
          );
      expect(injection, contains('你现在处于一个群聊中'));
      expect(injection, contains('User、Alpha、Beta'));
    });
  });
}

/// Guards against the director's protocol reminder leaking into a member's
/// private transcript (it belongs to the director request only).
class DirectorReminderProbe {
  static const reminder = 'Respond only by calling select_speaker or end_turn.';
}
