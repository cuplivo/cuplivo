import 'package:flutter_test/flutter_test.dart';

import 'package:Cuplivo/core/models/conversation.dart';

void main() {
  group('Conversation chat suggestions compatibility', () {
    test('fromJson defaults missing suggestions to empty list', () {
      final conversation = Conversation.fromJson({
        'id': 'conversation-1',
        'title': 'Chat',
        'createdAt': DateTime(2026, 1, 1).toIso8601String(),
        'updatedAt': DateTime(2026, 1, 2).toIso8601String(),
        'messageIds': <String>[],
      });

      expect(conversation.chatSuggestions, isEmpty);
    });

    test('toJson includes chat suggestions', () {
      final conversation = Conversation(
        id: 'conversation-2',
        title: 'Chat',
        chatSuggestions: const ['继续', '举例'],
      );

      expect(conversation.toJson()['chatSuggestions'], ['继续', '举例']);
    });

    test('toJson/fromJson preserves directed-tree active leaf', () {
      final conversation = Conversation(
        id: 'conversation-tree',
        title: 'Chat',
        activeMessageId: 'answer-5',
      );

      expect(
        Conversation.fromJson(conversation.toJson()).activeMessageId,
        'answer-5',
      );
    });

    test('copyWith can explicitly clear the directed-tree active leaf', () {
      final conversation = Conversation(
        id: 'conversation-tree-clear',
        title: 'Chat',
        activeMessageId: 'answer-5',
      );

      expect(
        conversation.copyWith(clearActiveMessageId: true).activeMessageId,
        isNull,
      );
    });
  });
}
