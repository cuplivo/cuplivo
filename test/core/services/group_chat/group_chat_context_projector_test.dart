import 'package:Cuplivo/core/models/group_chat_message.dart';
import 'package:Cuplivo/core/services/group_chat/group_chat_context_projector.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('GroupChatContextProjector', () {
    test('keeps current speaker artifacts and strips other speakers', () {
      final messages = <GroupChatMessage>[
        GroupChatMessage(
          id: 'user-message',
          groupId: 'group-1',
          role: 'user',
          content: 'question',
        ),
        GroupChatMessage(
          id: 'speaker-message',
          groupId: 'group-1',
          role: 'assistant',
          speakerAssistantId: 'assistant-a',
          content: 'own answer',
          reasoningText: 'own reasoning',
          reasoningSegmentsJson: '{"reasoningDetails":[{"type":"text"}]}',
        ),
        GroupChatMessage(
          id: 'other-message',
          groupId: 'group-1',
          role: 'assistant',
          speakerAssistantId: 'assistant-b',
          content: 'other answer<!-- gemini_thought_signatures:private -->',
          reasoningText: 'private reasoning',
          reasoningSegmentsJson: '{"reasoningDetails":[{"private":true}]}',
        ),
      ];

      final projected = GroupChatContextProjector.project(
        messages: messages,
        speakerAssistantId: 'assistant-a',
        assistantNames: const <String, String>{'assistant-b': 'Bob'},
      );

      expect(projected, hasLength(3));
      expect(projected[0].includeArtifacts, isTrue);
      expect(projected[1].includeArtifacts, isTrue);
      expect(projected[1].applyAssistantSendTransform, isTrue);
      expect(projected[1].message.reasoningText, 'own reasoning');
      expect(projected[2].includeArtifacts, isFalse);
      expect(projected[2].applyAssistantSendTransform, isFalse);
      expect(projected[2].message.content, '[Bob]: other answer');
      expect(projected[2].message.conversationId, 'group-1');
      expect(projected[2].message.groupId, 'other-message');
    });

    test('does not invent a prefix when the member name is unavailable', () {
      final message = GroupChatMessage(
        id: 'message-1',
        groupId: 'group-1',
        role: 'assistant',
        speakerAssistantId: 'assistant-b',
        content: 'answer',
      );

      final projected = GroupChatContextProjector.project(
        messages: <GroupChatMessage>[message],
        speakerAssistantId: 'assistant-a',
      );

      expect(projected.single.message.content, 'answer');
      expect(projected.single.includeArtifacts, isFalse);
    });
  });
}
