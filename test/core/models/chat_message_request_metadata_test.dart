import 'package:Cuplivo/core/models/chat_message.dart';
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

    test('toJson/fromJson preserves directed-tree parent', () {
      final message = ChatMessage(
        id: 'answer-5',
        role: 'assistant',
        content: '5',
        conversationId: 'conversation-1',
        parentMessageId: 'question-4',
      );

      expect(
        ChatMessage.fromJson(message.toJson()).parentMessageId,
        'question-4',
      );
    });
  });
}
