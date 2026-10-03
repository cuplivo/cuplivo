import 'package:Cuplivo/core/models/assistant.dart';
import 'package:Cuplivo/core/models/conversation.dart';
import 'package:Cuplivo/core/services/proactive_care_alarm_service.dart';
import 'package:Cuplivo/core/services/notification_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('ProactiveCareAlarmService.pendingForReschedule', () {
    final now = DateTime(2026, 8, 14, 12);

    Assistant assistant({String id = 'a1', bool enabled = true}) =>
        Assistant(id: id, name: 'Test', enableProactiveCare: enabled);

    Conversation conversation({
      String id = 'c1',
      String? assistantId = 'a1',
      bool? enabledOverride,
      DateTime? nextAt,
    }) {
      var conv = Conversation(id: id, title: 'Chat', assistantId: assistantId);
      if (enabledOverride != null) {
        conv = conv.setProactiveCareEnabledOverride(enabledOverride);
      }
      if (nextAt != null) {
        conv = conv.setProactiveCareNextMessageAt(nextAt);
      }
      return conv;
    }

    List<String> pendingIds({
      required List<Conversation> conversations,
      required List<Assistant> assistants,
    }) => ProactiveCareAlarmService.pendingForReschedule(
      conversations: conversations,
      assistants: assistants,
      now: now,
    ).map((target) => target.conversation.id).toList();

    test('inherits enabled state from the fixed owner assistant', () {
      expect(
        pendingIds(
          conversations: [
            conversation(nextAt: now.add(const Duration(minutes: 5))),
          ],
          assistants: [assistant()],
        ),
        ['c1'],
      );
      expect(
        pendingIds(
          conversations: [
            conversation(nextAt: now.add(const Duration(minutes: 5))),
          ],
          assistants: [assistant(enabled: false)],
        ),
        isEmpty,
      );
    });

    test('conversation override wins over assistant state', () {
      final nextAt = now.add(const Duration(minutes: 5));
      expect(
        pendingIds(
          conversations: [conversation(enabledOverride: true, nextAt: nextAt)],
          assistants: [assistant(enabled: false)],
        ),
        ['c1'],
      );
      expect(
        pendingIds(
          conversations: [conversation(enabledOverride: false, nextAt: nextAt)],
          assistants: [assistant(enabled: true)],
        ),
        isEmpty,
      );
    });

    test('only future schedules of owned conversations are armed', () {
      expect(
        pendingIds(
          conversations: [
            conversation(
              id: 'past',
              nextAt: now.subtract(const Duration(minutes: 5)),
            ),
            conversation(id: 'none'),
            conversation(id: 'other', assistantId: 'a2', nextAt: now),
          ],
          assistants: [assistant()],
        ),
        isEmpty,
      );
    });

    test('isSupported is true on non-web platforms', () {
      expect(ProactiveCareAlarmService.isSupported, isTrue);
    });

    test('letter ids share the conversation hash with distinct ids', () {
      final letter = NotificationService.proactiveCareIdFor('conv-1');
      final chat = NotificationService.notificationIdForConversation('conv-1');
      expect(letter, NotificationService.proactiveCareIdFor('conv-1'));
      expect(letter, isNot(chat));
      // Distinct conversations map to distinct ids.
      expect(
        NotificationService.proactiveCareIdFor('conv-1'),
        isNot(NotificationService.proactiveCareIdFor('conv-2')),
      );
    });
  });
}
