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
  });

  group('Conversation persistent quick instructions', () {
    test('missing legacy field defaults to an empty activation list', () {
      final conversation = Conversation.fromJson({
        'id': 'conversation-legacy',
        'title': 'Chat',
        'createdAt': DateTime(2026, 1, 1).toIso8601String(),
        'updatedAt': DateTime(2026, 1, 2).toIso8601String(),
        'messageIds': <String>[],
      });

      expect(conversation.persistentQuickInstructionIds, isEmpty);
    });

    test('activation IDs survive JSON and copy round-trips', () {
      final conversation = Conversation(
        id: 'conversation-new',
        title: 'Chat',
        persistentQuickInstructionIds: const ['persistent-1', 'persistent-2'],
      );

      final decoded = Conversation.fromJson(conversation.toJson());
      final copied = decoded.copyWith();

      expect(copied.persistentQuickInstructionIds, [
        'persistent-1',
        'persistent-2',
      ]);
      decoded.persistentQuickInstructionIds.add('persistent-3');
      expect(
        copied.persistentQuickInstructionIds,
        isNot(contains('persistent-3')),
      );
    });
  });
}
