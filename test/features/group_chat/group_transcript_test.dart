import 'package:Cuplivo/core/models/assistant.dart';
import 'package:Cuplivo/core/models/chat_message.dart';
import 'package:Cuplivo/core/models/group_chat.dart';
import 'package:Cuplivo/core/models/message_part.dart';
import 'package:Cuplivo/features/group_chat/services/group_transcript.dart';
import 'package:flutter_test/flutter_test.dart';

/// How a group conversation becomes model input: only the speaker's own turns
/// stay `assistant`, everyone else travels as `user` inside a `<group_message>`
/// envelope, and another member's reasoning, tool calls and images never cross
/// into the next speaker's request.
void main() {
  Assistant assistant(String id, String name) =>
      Assistant(id: id, name: name, chatModelProvider: 'p', chatModelId: 'm');

  final alice = assistant('a1', 'Alice');
  final bob = assistant('a2', 'Bob');

  Assistant? resolve(String? senderId) => switch (senderId) {
    'a1' => alice,
    'a2' => bob,
    _ => null,
  };

  test('my own reply stays assistant, with no name line', () {
    final message = ChatMessage(
      id: 'm1',
      role: 'assistant',
      content: 'answer',
      conversationId: 'c1',
      senderId: 'a1',
      reasoningText: 'private thinking',
    );
    final flattened = GroupTranscript.forSpeaker(
      [message],
      speakerId: 'a1',
      resolve: resolve,
    );
    expect(flattened.single.role, 'assistant');
    expect(flattened.single.content, 'answer');
    expect(flattened.single.parts.whereType<ReasoningPart>(), isEmpty);
  });

  test('another member speaks as user, wrapped with its name', () {
    final message = ChatMessage(
      id: 'm1',
      role: 'assistant',
      content: 'answer',
      conversationId: 'c1',
      senderId: 'a2',
    );
    final flattened = GroupTranscript.forSpeaker(
      [message],
      speakerId: 'a1',
      resolve: resolve,
    );
    expect(flattened.single.role, 'user');
    expect(
      flattened.single.content,
      '<group_message from="Bob">\nanswer\n</group_message>',
    );
    // The identity stays attached for panels, edits and versions.
    expect(flattened.single.senderId, 'a2');
    expect(flattened.single.id, 'm1');
  });

  test('tool cards and images from another model are dropped', () {
    final message = ChatMessage(
      id: 'm1',
      role: 'assistant',
      conversationId: 'c1',
      senderId: 'a2',
      parts: const [
        TextPart('look'),
        ToolCallPart('{"id":"call-1","name":"read_file"}'),
        ImagePart(uri: 'file:///tmp/a.png'),
      ],
    );
    final flattened = GroupTranscript.forSpeaker(
      [message],
      speakerId: 'a1',
      resolve: resolve,
    );
    expect(
      flattened.single.content,
      '<group_message from="Bob">\nlook\n</group_message>',
    );
    expect(flattened.single.parts.whereType<ToolCallPart>(), isEmpty);
    expect(flattened.single.parts.whereType<ImagePart>(), isEmpty);
  });

  test('a user turn travels unchanged, attachments included', () {
    final message = ChatMessage(
      id: 'u1',
      role: 'user',
      conversationId: 'c1',
      parts: const [
        TextPart('see this'),
        ImagePart(uri: 'file:///u.png'),
      ],
    );
    final flattened = GroupTranscript.forSpeaker(
      [message],
      speakerId: 'a1',
      resolve: resolve,
    );
    expect(identical(flattened.single, message), isTrue);
  });

  test('every reply is authored: a missing one is never assumed', () {
    final message = ChatMessage(
      id: 'm1',
      role: 'assistant',
      content: 'answer',
      conversationId: 'c1',
    );
    final flattened = GroupTranscript.forSpeaker(
      [message],
      speakerId: 'a1',
      resolve: resolve,
    );
    expect(flattened.single.role, 'user');
    expect(
      flattened.single.content,
      '<group_message from="Assistant">\nanswer\n</group_message>',
    );
  });

  test('a deleted author gets a neutral name, not the current assistant', () {
    expect(GroupTranscript.speakerName('gone', resolve), 'Unknown assistant');
    expect(GroupTranscript.speakerName('a1', resolve), 'Alice');
  });

  test('the title source names the author and drops private thinking', () {
    final message = ChatMessage(
      id: 'm1',
      role: 'assistant',
      content: 'answer',
      conversationId: 'c1',
      senderId: 'a2',
      reasoningText: 'private thinking',
    );
    final line = GroupTranscript.titleLine(resolve)(message);
    expect(line, '[Bob]: answer');
    expect(line, isNot(contains('private thinking')));
  });

  test('the title source keeps a user turn labelled as the user', () {
    final message = ChatMessage(
      id: 'u1',
      role: 'user',
      content: 'what now',
      conversationId: 'c1',
    );
    expect(GroupTranscript.titleLine(resolve)(message), 'User: what now');
  });

  test('the roster directive names the speaker and the members', () {
    final group = GroupChat(
      id: 'g1',
      name: 'Panel',
      memberIds: const ['a1', 'a2'],
      createdAt: DateTime.utc(2026),
      updatedAt: DateTime.utc(2026),
    );
    final directive = GroupTranscript.rosterDirective(
      group: group,
      members: [alice, bob],
      speakerName: 'Alice',
      spokeThisRound: const {'a2'},
    );
    expect(directive, contains('Panel'));
    expect(directive, contains('Alice'));
    expect(directive, contains('Bob'));
    expect(directive, contains('Already replied in this round: Bob'));
    expect(directive, contains('<group_message from="Name">'));
    expect(directive, contains('no wrapper, no name prefix'));
  });

  test('the director transcript collapses one member speaking twice', () {
    final messages = [
      ChatMessage(
        id: 'u1',
        role: 'user',
        content: 'hello',
        conversationId: 'c1',
      ),
      ChatMessage(
        id: 'm1',
        role: 'assistant',
        content: 'first',
        conversationId: 'c1',
        senderId: 'a1',
      ),
      ChatMessage(
        id: 'm2',
        role: 'assistant',
        content: 'second',
        conversationId: 'c1',
        senderId: 'a1',
      ),
    ];
    final transcript = GroupTranscript.forDirector(messages, resolve: resolve);
    expect(transcript, hasLength(2));
    expect(transcript.last['name'], 'Alice');
    expect(transcript.last['text'], contains('second'));
  });
}
