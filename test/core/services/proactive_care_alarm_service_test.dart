import 'package:Cuplivo/core/models/assistant.dart';
import 'package:Cuplivo/core/models/conversation.dart';
import 'package:Cuplivo/core/services/proactive_care_alarm_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('ProactiveCareAlarmService.pendingForReschedule', () {
    final now = DateTime(2026, 8, 14, 12);

    Assistant assistant({String id = 'a1', bool enabled = true}) =>
        Assistant(id: id, name: 'Test', enableProactiveCare: enabled);

    Conversation conversation({
      String id = 'c1',
      String? assistantId = 'a1',
      String kind = Conversation.kindNormal,
      bool? enabledOverride,
      DateTime? nextAt,
    }) => Conversation(
      id: id,
      title: 'Chat',
      assistantId: assistantId,
      conversationKind: kind,
      proactiveCareEnabledOverride: enabledOverride,
      proactiveCareNextMessageAt: nextAt,
    );

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

    test('requires a normal conversation with an existing fixed owner', () {
      final nextAt = now.add(const Duration(minutes: 5));
      expect(
        pendingIds(
          conversations: [
            conversation(
              id: 'group',
              kind: Conversation.kindGroup,
              nextAt: nextAt,
            ),
            conversation(id: 'unowned', assistantId: null, nextAt: nextAt),
            conversation(id: 'missing', assistantId: 'missing', nextAt: nextAt),
          ],
          assistants: [assistant()],
        ),
        isEmpty,
      );
    });

    test('requires a strictly future conversation schedule', () {
      expect(
        pendingIds(
          conversations: [
            conversation(id: 'null'),
            conversation(
              id: 'past',
              nextAt: now.subtract(const Duration(seconds: 1)),
            ),
            conversation(id: 'now', nextAt: now),
            conversation(
              id: 'future',
              nextAt: now.add(const Duration(seconds: 1)),
            ),
          ],
          assistants: [assistant()],
        ),
        ['future'],
      );
    });

    test('preserves persisted conversation order', () {
      final nextAt = now.add(const Duration(minutes: 5));
      expect(
        pendingIds(
          conversations: [
            conversation(id: 'c2', nextAt: nextAt),
            conversation(id: 'c1', nextAt: nextAt),
          ],
          assistants: [assistant()],
        ),
        ['c2', 'c1'],
      );
    });
  });

  group('ProactiveCareAlarmTrigger', () {
    test(
      'round-trips conversation and drift-compatible expected timestamp',
      () {
        final at = DateTime(2026, 8, 14, 12, 30, 45, 987);
        final trigger = ProactiveCareAlarmTrigger.fromSchedule(
          conversationId: 'conversation-1',
          expectedAt: at,
        );

        final decoded = ProactiveCareAlarmTrigger.fromMap(trigger.toMap());

        expect(decoded.conversationId, 'conversation-1');
        expect(
          decoded.expectedAtSeconds,
          at.millisecondsSinceEpoch ~/ Duration.millisecondsPerSecond,
        );
        expect(decoded.expectedAt.millisecond, 0);
      },
    );

    test('rejects missing or non-primitive fields', () {
      expect(
        () => ProactiveCareAlarmTrigger.fromMap(<Object?, Object?>{}),
        throwsFormatException,
      );
      expect(
        () => ProactiveCareAlarmTrigger.fromMap(<Object?, Object?>{
          'conversationId': 'c1',
          'expectedAtSeconds': 'not-an-int',
        }),
        throwsFormatException,
      );
    });
  });

  test('alarm id is stable and conversation-owned', () {
    expect(
      ProactiveCareAlarmService.alarmIdFor('conversation-1'),
      ProactiveCareAlarmService.alarmIdFor('conversation-1'),
    );
    expect(
      ProactiveCareAlarmService.alarmIdFor('conversation-1'),
      isNot(ProactiveCareAlarmService.alarmIdFor('conversation-2')),
    );
  });
}
