import 'package:Cuplivo/core/models/chat_message.dart';
import 'package:Cuplivo/core/models/quick_instruction.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('ChatMessage request metadata', () {
    test('requestExtraBody decodes persisted JSON map', () {
      final message = ChatMessage(
        role: 'user',
        content: 'draw a cat',
        conversationId: 'conversation-1',
        requestExtraBodyJson:
            '{"quality":"high","size":"3840x2160","output_format":"png"}',
      );

      expect(message.requestExtraBody, {
        'quality': 'high',
        'size': '3840x2160',
        'output_format': 'png',
      });
    });

    test('requestExtraBody treats malformed JSON as absent', () {
      final message = ChatMessage(
        role: 'user',
        content: 'draw a cat',
        conversationId: 'conversation-1',
        requestExtraBodyJson: '{not json',
      );

      expect(message.requestExtraBody, isEmpty);
    });

    test('toJson/fromJson preserves request routing metadata', () {
      final message = ChatMessage(
        id: 'message-1',
        role: 'user',
        content: 'draw a cat',
        conversationId: 'conversation-1',
        requestAllowImagesApiRouting: false,
        requestExtraBodyJson:
            '{"quality":"medium","output_format":"webp","n":2}',
      );

      final roundTrip = ChatMessage.fromJson(message.toJson());

      expect(roundTrip.requestAllowImagesApiRouting, isFalse);
      expect(roundTrip.requestExtraBody, {
        'quality': 'medium',
        'output_format': 'webp',
        'n': 2,
      });
    });

    test('quick instruction snapshots survive JSON and version copies', () {
      final frozen = QuickInstructionInvocationSnapshot.encodeList([
        QuickInstructionInvocationSnapshot.fromInstruction(
          QuickInstruction(
            id: 'once-1',
            title: 'Once',
            prompt: 'Be concise.',
            placement: QuickInstructionPlacement.beforeUserMessage,
          ),
          order: 2,
        ),
      ]);
      final message = ChatMessage(
        id: 'message-quick-instruction',
        role: 'user',
        content: 'Question',
        conversationId: 'conversation-1',
        quickInstructionInvocationsJson: frozen,
      );

      final roundTrip = ChatMessage.fromJson(
        message.toJson(),
      ).copyWith(version: 1);

      expect(roundTrip.quickInstructionInvocations, hasLength(1));
      expect(roundTrip.quickInstructionInvocations.single.title, 'Once');
      expect(
        roundTrip.quickInstructionInvocations.single.prompt,
        'Be concise.',
      );
      expect(roundTrip.quickInstructionInvocations.single.order, 2);
    });
  });
}
