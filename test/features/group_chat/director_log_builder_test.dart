import 'package:flutter_test/flutter_test.dart';

import 'package:Cuplivo/core/models/assistant.dart';
import 'package:Cuplivo/core/models/chat_message.dart';
import 'package:Cuplivo/core/models/conversation.dart';
import 'package:Cuplivo/core/models/group_chat.dart';
import 'package:Cuplivo/core/models/group_chat_director_log.dart';
import 'package:Cuplivo/core/services/chat/chat_service.dart';
import 'package:Cuplivo/features/group_chat/services/director_log_builder.dart';

class _FakeChatService extends ChatService {
  @override
  List<Map<String, dynamic>> getToolEvents(String assistantMessageId) =>
      const [];
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Assistant alpha;
  late Assistant beta;
  late GroupChat group;
  late DirectorLogBuilder builder;

  setUp(() {
    alpha = const Assistant(id: 'a1', name: 'Alpha', systemPrompt: 'A');
    beta = const Assistant(id: 'a2', name: 'Beta', systemPrompt: 'B');
    group = GroupChat(
      id: 'g1',
      name: 'Room',
      conversationId: 'c1',
      directorSystemPrompt: 'You are the director.',
    );
    builder = DirectorLogBuilder(chatService: _FakeChatService());
  });

  ChatMessage user(String id, String content) =>
      ChatMessage(id: id, role: 'user', content: content, conversationId: 'c1');

  ChatMessage assistant(
    String id,
    String content, {
    String? senderId = 'a1',
    String? groupId,
    int version = 0,
  }) => ChatMessage(
    id: id,
    role: 'assistant',
    content: content,
    conversationId: 'c1',
    senderId: senderId,
    groupId: groupId,
    version: version,
  );

  List<DirectorLogEntry> buildLogs(
    List<ChatMessage> messages, {
    Conversation? conversation,
    int? maxAssistantMessagesPerRound,
    List<GroupChatDirectorRuntimeLog> runtimeLogs = const [],
    List<Assistant>? roster,
  }) {
    final configuredGroup = maxAssistantMessagesPerRound == null
        ? group
        : GroupChat(
            id: group.id,
            name: group.name,
            conversationId: group.conversationId,
            directorSystemPrompt: group.directorSystemPrompt,
            maxAssistantMessagesPerRound: maxAssistantMessagesPerRound,
          );
    final assistants = roster ?? [alpha, beta];
    return builder.build(
      group: configuredGroup,
      publicMessages: messages,
      conversation: conversation,
      rosterAssistants: assistants,
      userName: 'User',
      assistantsById: {
        for (final item in [alpha, beta]) item.id: item,
      },
      fallbackAssistantName: 'Assistant',
      runtimeLogs: runtimeLogs,
    );
  }

  test('empty public conversation produces no entries', () {
    expect(buildLogs(const []), isEmpty);
  });

  test('no roster assistants yields no derived director entries', () {
    expect(buildLogs([user('u1', 'Hello')], roster: const []), isEmpty);
  });

  test('user and assistant messages expose the observed next speaker', () {
    final entries = buildLogs([user('u1', 'Hello'), assistant('m1', 'Hi')]);

    expect(entries, hasLength(2));
    expect(entries[0].trigger, GroupChatDirectorLogTrigger.user);
    expect(entries[0].outcome, DirectorLogOutcome.observedSpeaker);
    expect(entries[0].observedAssistantId, 'a1');
    expect(entries[1].trigger, GroupChatDirectorLogTrigger.assistant);
    expect(entries[1].outcome, DirectorLogOutcome.noObservedFollowUp);
    expect(entries[1].observedAssistantId, isNull);
    expect(entries[1].contextMessages, isNotEmpty);
    expect(entries[1].contextMessages.last.content, contains('[Alpha]: Hi'));
  });

  test('multiple consecutive assistants are separate director calls', () {
    final entries = buildLogs([
      user('u1', 'Discuss this'),
      assistant('m1', 'Alpha reply', senderId: 'a1'),
      assistant('m2', 'Beta follow-up', senderId: 'a2'),
    ]);

    expect(entries, hasLength(3));
    expect(entries[0].observedAssistantId, 'a1');
    expect(entries[1].observedAssistantId, 'a2');
    expect(entries[2].outcome, DirectorLogOutcome.noObservedFollowUp);
  });

  test('cap marker is separate and the next user uses an E3 cap merge', () {
    final entries = buildLogs([
      user('u1', 'First'),
      assistant('m1', 'At the cap'),
      user('u2', 'Second'),
    ], maxAssistantMessagesPerRound: 1);

    expect(entries, hasLength(3));
    expect(entries[1].outcome, DirectorLogOutcome.roundCapReached);
    expect(entries[1].contextMessages, isEmpty);
    expect(entries[1].runtime, isNull);
    expect(entries[2].trigger, GroupChatDirectorLogTrigger.capMerge);
    expect(
      entries[2].contextMessages.last.content,
      contains('[Alpha]: At the cap'),
    );
    expect(entries[2].contextMessages.last.content, contains('[User]: Second'));
  });

  test('version selection is applied to the reconstructed context', () {
    final entries = buildLogs(
      [
        user('u1', 'Question'),
        assistant('old', 'old answer', groupId: 'answer', version: 0),
        assistant('new', 'new answer', groupId: 'answer', version: 1),
        user('u2', 'Follow up'),
      ],
      conversation: Conversation(
        id: 'c1',
        title: 'Room',
        versionSelections: const {'answer': 0},
      ),
    );

    final context = entries.last.contextMessages
        .map((m) => m.content)
        .join('\n');
    expect(context, contains('old answer'));
    expect(context, isNot(contains('new answer')));
  });

  test('a selected version appended after a later turn is still included', () {
    final entries = buildLogs(
      [
        user('u1', 'Question'),
        assistant('old', 'old answer', groupId: 'answer', version: 0),
        user('u2', 'Follow up'),
        assistant('new', 'new answer', groupId: 'answer', version: 1),
      ],
      conversation: Conversation(
        id: 'c1',
        title: 'Room',
        versionSelections: const {'answer': 1},
      ),
    );

    final context = entries.last.contextMessages
        .map((m) => m.content)
        .join('\n');
    expect(context, contains('new answer'));
    expect(context, isNot(contains('old answer')));
  });

  test(
    'clear-context boundary is applied relative to the prefix being shown',
    () {
      final entries = buildLogs([
        user('u0', 'Old question'),
        assistant('a0', 'Old answer'),
        user('u1', 'New question'),
      ], conversation: Conversation(id: 'c1', title: 'Room', truncateIndex: 2));

      final context = entries.last.contextMessages
          .map((m) => m.content)
          .join('\n');
      expect(context, contains('[User]: New question'));
      expect(context, isNot(contains('Old question')));
      expect(context, isNot(contains('Old answer')));
    },
  );

  test('missing speaker and missing follow-up remain explicit', () {
    final entries = buildLogs([
      user('u1', 'Who is there?'),
      assistant('missing', 'From a removed assistant', senderId: 'gone'),
      ChatMessage(
        id: 'tool-message',
        role: 'tool',
        content: 'tool output',
        conversationId: 'c1',
      ),
    ]);

    expect(entries.first.observedAssistantId, 'gone');
    expect(entries.first.outcome, DirectorLogOutcome.observedSpeaker);
    expect(entries[1].outcome, DirectorLogOutcome.noObservedFollowUp);
    expect(entries[1].contextMessages.last.content, contains('[gone]'));
  });

  test('only the newest runtime record for a source message is attached', () {
    final firstUser = user('u1', 'Hello');
    final oldFinishedAt = DateTime(2026, 1, 1, 10);
    final newFinishedAt = DateTime(2026, 1, 1, 11);
    final entries = buildLogs(
      [firstUser],
      runtimeLogs: [
        GroupChatDirectorRuntimeLog(
          sourceMessageId: firstUser.id,
          trigger: GroupChatDirectorLogTrigger.user,
          startedAt: oldFinishedAt,
          finishedAt: oldFinishedAt,
          providerKey: 'old-provider',
          modelId: 'old-model',
          requestMessageCount: 1,
          attemptCount: 1,
          attemptErrors: const [],
        ),
        GroupChatDirectorRuntimeLog(
          sourceMessageId: firstUser.id,
          trigger: GroupChatDirectorLogTrigger.user,
          startedAt: newFinishedAt,
          finishedAt: newFinishedAt,
          providerKey: 'new-provider',
          modelId: 'new-model',
          requestMessageCount: 2,
          attemptCount: 2,
          attemptErrors: const ['retry'],
        ),
      ],
    );

    expect(entries.single.runtime?.modelId, 'new-model');
    expect(entries.single.runtime?.attemptErrors, ['retry']);
  });

  test('entries are ordered and carry their source message identity', () {
    final firstUser = user('u1', 'Hello');
    final entries = buildLogs([
      firstUser,
      assistant('m1', 'Hi'),
      user('u2', 'x'),
    ]);

    expect(entries.map((e) => e.order), [0, 1, 2]);
    expect(entries.first.sourceMessageId, firstUser.id);
    expect(entries.first.triggerContent, 'Hello');
    // Every reconstructed context starts with the substituted system prompt.
    expect(entries.first.contextMessages.first.role, 'system');
    expect(
      entries.first.contextMessages.first.content,
      'You are the director.',
    );
  });

  test('trigger content strips legacy media markers from human turns', () {
    final entries = buildLogs([
      user('u1', '看图 [image:/tmp/photo.png] 附件 [file:/tmp/r.pdf|r.pdf|x]'),
    ]);

    expect(entries.single.triggerContent, '看图 [image] 附件 [file]');
  });
}
