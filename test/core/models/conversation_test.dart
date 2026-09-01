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

  group('Conversation proactive care', () {
    final nextMessageAt = DateTime.utc(2026, 2, 3, 4, 5, 6);

    test('JSON round-trips nullable per-conversation settings', () {
      final conversation = Conversation(
        id: 'conversation-proactive',
        title: 'Chat',
        proactiveCareEnabledOverride: false,
        proactiveCareNextMessageAt: nextMessageAt,
      );

      final json = conversation.toJson();
      expect(json['proactiveCareEnabledOverride'], isFalse);
      expect(
        json['proactiveCareNextMessageAt'],
        nextMessageAt.toIso8601String(),
      );

      final loaded = Conversation.fromJson(json);
      expect(loaded.proactiveCareEnabledOverride, isFalse);
      expect(loaded.proactiveCareNextMessageAt, nextMessageAt);
    });

    test('missing JSON fields preserve inherited defaults', () {
      final conversation = Conversation.fromJson({
        'id': 'conversation-legacy',
        'title': 'Legacy',
        'createdAt': DateTime.utc(2026, 1, 1).toIso8601String(),
        'updatedAt': DateTime.utc(2026, 1, 2).toIso8601String(),
      });

      expect(conversation.proactiveCareEnabledOverride, isNull);
      expect(conversation.proactiveCareNextMessageAt, isNull);
    });

    test(
      'copyWith retains, replaces, and explicitly clears nullable fields',
      () {
        final conversation = Conversation(
          title: 'Chat',
          proactiveCareEnabledOverride: true,
          proactiveCareNextMessageAt: nextMessageAt,
        );

        final unchanged = conversation.copyWith(title: 'Renamed');
        expect(unchanged.proactiveCareEnabledOverride, isTrue);
        expect(unchanged.proactiveCareNextMessageAt, nextMessageAt);

        final replacementTime = nextMessageAt.add(const Duration(hours: 1));
        final replaced = conversation.copyWith(
          proactiveCareEnabledOverride: false,
          proactiveCareNextMessageAt: replacementTime,
        );
        expect(replaced.proactiveCareEnabledOverride, isFalse);
        expect(replaced.proactiveCareNextMessageAt, replacementTime);

        final cleared = conversation.copyWith(
          clearProactiveCareEnabledOverride: true,
          clearProactiveCareNextMessageAt: true,
        );
        expect(cleared.proactiveCareEnabledOverride, isNull);
        expect(cleared.proactiveCareNextMessageAt, isNull);
      },
    );
  });
}
