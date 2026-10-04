import 'package:Cuplivo/core/models/assistant.dart';
import 'package:Cuplivo/core/models/conversation.dart';
import 'package:Cuplivo/core/services/desktop_power_state.dart';
import 'package:Cuplivo/core/services/desktop_proactive_care_scheduler.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('DesktopProactiveCareScheduler', () {
    var currentTime = DateTime(2026, 8, 14, 12, 0, 0);
    var powerState = const DesktopPowerState();

    DesktopProactiveCareScheduler createScheduler() {
      return DesktopProactiveCareScheduler(
        now: () => currentTime,
        readPowerState: () async => powerState,
      );
    }

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

    test(
      'sync adds future eligible schedule and removes past or ineligible',
      () async {
        final scheduler = createScheduler();
        final targetTime = currentTime.add(const Duration(minutes: 10));

        await scheduler.sync(
          conversation: conversation(id: 'c1', nextAt: targetTime),
          assistant: assistant(id: 'a1'),
        );
        expect(scheduler.schedules['c1'], targetTime);

        // Ineligible removes
        await scheduler.sync(
          conversation: conversation(id: 'c1', nextAt: targetTime),
          assistant: assistant(id: 'a1', enabled: false),
        );
        expect(scheduler.schedules.containsKey('c1'), isFalse);

        scheduler.dispose();
      },
    );

    test('tick fires due schedule when not sleeping', () async {
      final scheduler = createScheduler();
      final targetTime = currentTime.add(const Duration(seconds: 5));
      final fired = <String>[];

      await scheduler.attach((convId, dueAt) async {
        fired.add(convId);
      });

      await scheduler.sync(
        conversation: conversation(id: 'c1', nextAt: targetTime),
        assistant: assistant(id: 'a1'),
      );

      // Before due time
      await scheduler.tickForTesting();
      expect(fired, isEmpty);
      expect(scheduler.schedules.containsKey('c1'), isTrue);

      // Advance time to due
      currentTime = targetTime;
      await scheduler.tickForTesting();
      expect(fired, ['c1']);
      expect(scheduler.schedules.containsKey('c1'), isFalse);

      scheduler.dispose();
    });

    test('sleeping power state suppresses firing', () async {
      final scheduler = createScheduler();
      final targetTime = currentTime.add(const Duration(seconds: 5));
      final fired = <String>[];

      await scheduler.attach((convId, dueAt) async {
        fired.add(convId);
      });

      await scheduler.sync(
        conversation: conversation(id: 'c1', nextAt: targetTime),
        assistant: assistant(id: 'a1'),
      );

      // Advance time but computer is sleeping
      currentTime = targetTime.add(const Duration(seconds: 10));
      powerState = const DesktopPowerState(sleeping: true);

      await scheduler.tickForTesting();
      expect(fired, isEmpty);
      expect(scheduler.schedules.containsKey('c1'), isTrue);

      // Wake up after due time: if lastWakeAt is after targetTime, it is skipped as a missed occurrence
      powerState = DesktopPowerState(sleeping: false, lastWakeAt: currentTime);
      await scheduler.tickForTesting();
      // Missed occurrence during sleep is skipped on wake
      expect(fired, isEmpty);
      expect(scheduler.schedules.containsKey('c1'), isFalse);

      scheduler.dispose();
    });

    test('cancelFor removes specific schedule', () async {
      final scheduler = createScheduler();
      final targetTime = currentTime.add(const Duration(minutes: 5));

      await scheduler.sync(
        conversation: conversation(id: 'c1', nextAt: targetTime),
        assistant: assistant(id: 'a1'),
      );
      expect(scheduler.schedules.containsKey('c1'), isTrue);

      await scheduler.cancelFor('c1');
      expect(scheduler.schedules.containsKey('c1'), isFalse);

      scheduler.dispose();
    });

    test(
      'rescheduleAll replaces schedules with pending eligible ones',
      () async {
        final scheduler = createScheduler();
        final targetTime = currentTime.add(const Duration(minutes: 5));

        await scheduler.rescheduleAll(
          conversations: [
            conversation(id: 'c1', nextAt: targetTime),
            conversation(
              id: 'c2',
              nextAt: currentTime.subtract(const Duration(minutes: 5)),
            ),
          ],
          assistants: [assistant(id: 'a1')],
        );

        expect(scheduler.schedules.keys, ['c1']);
        expect(scheduler.schedules['c1'], targetTime);

        scheduler.dispose();
      },
    );
  });
}
