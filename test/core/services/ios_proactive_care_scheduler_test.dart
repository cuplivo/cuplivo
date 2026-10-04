import 'package:Cuplivo/core/models/assistant.dart';
import 'package:Cuplivo/core/models/conversation.dart';
import 'package:Cuplivo/core/services/ios_proactive_care_scheduler.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('test.proactive_care_notifications');
  final calls = <MethodCall>[];

  setUp(() {
    calls.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          calls.add(call);
          return true;
        });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  group('IosProactiveCareScheduler', () {
    var currentTime = DateTime(2026, 8, 14, 12, 0, 0);

    IosProactiveCareScheduler createScheduler({String? arrivalBody}) =>
        IosProactiveCareScheduler(
          channel: channel,
          now: () => currentTime,
          isIos: () => true,
          arrivalBodyResolver: arrivalBody == null ? null : () => arrivalBody,
        );

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
      'sync registers the arrival notification with the letter payload',
      () async {
        final scheduler = createScheduler(arrivalBody: 'A letter has arrived.');
        final targetTime = currentTime.add(const Duration(minutes: 10));

        await scheduler.sync(
          conversation: conversation(id: 'c1', nextAt: targetTime),
          assistant: assistant(),
        );

        expect(scheduler.schedules['c1'], targetTime);
        expect(calls, hasLength(1));
        final call = calls.single;
        expect(call.method, 'schedule');
        final args = Map<String, Object?>.from(call.arguments as Map);
        // The native adapter prefixes `scheduled-task:` in both `schedule` and
        // `cancel`, so callers pass the bare conversation id via
        // `notificationIdFor` without double-prefixing.
        expect(args['runId'], 'c1');
        expect(args['at'], targetTime.millisecondsSinceEpoch);
        expect(args['title'], 'Test');
        expect(args['body'], 'A letter has arrived.');
        expect(args['prepared'], isFalse);
        expect(args['payload'], 'proactive-care:c1');

        scheduler.dispose();
      },
    );

    test('the arrival body falls back when no resolver is wired', () async {
      final scheduler = createScheduler();
      final targetTime = currentTime.add(const Duration(minutes: 10));

      await scheduler.sync(
        conversation: conversation(id: 'c1', nextAt: targetTime),
        assistant: assistant(),
      );

      final args = Map<String, Object?>.from(calls.single.arguments as Map);
      expect(args['body'], IosProactiveCareScheduler.defaultArrivalBody);

      scheduler.dispose();
    });

    test('a blank resolved body falls back too', () async {
      final scheduler = createScheduler(arrivalBody: '   ');
      final targetTime = currentTime.add(const Duration(minutes: 10));

      await scheduler.sync(
        conversation: conversation(id: 'c1', nextAt: targetTime),
        assistant: assistant(),
      );

      final args = Map<String, Object?>.from(calls.single.arguments as Map);
      expect(args['body'], IosProactiveCareScheduler.defaultArrivalBody);

      scheduler.dispose();
    });

    test('past or ineligible schedules cancel instead of scheduling', () async {
      final scheduler = createScheduler(arrivalBody: 'A letter has arrived.');
      final targetTime = currentTime.add(const Duration(minutes: 10));

      await scheduler.sync(
        conversation: conversation(
          id: 'c1',
          nextAt: currentTime.subtract(const Duration(minutes: 5)),
        ),
        assistant: assistant(),
      );
      expect(scheduler.schedules.containsKey('c1'), isFalse);
      expect(calls.last.method, 'cancel');
      expect(calls.last.arguments, 'c1');

      await scheduler.sync(
        conversation: conversation(id: 'c2', nextAt: targetTime),
        assistant: assistant(enabled: false),
      );
      expect(scheduler.schedules.containsKey('c2'), isFalse);
      expect(calls.last.method, 'cancel');
      expect(calls.last.arguments, 'c2');

      scheduler.dispose();
    });

    test(
      'rescheduleAll replaces the schedules with the pending ones and cancels dropped ones',
      () async {
        final scheduler = createScheduler(arrivalBody: 'A letter has arrived.');
        final targetTime = currentTime.add(const Duration(minutes: 5));

        // Pre-populate a previously scheduled conversation ('c3') that is not
        // in the new snapshot at all, plus an ineligible/past-due conversation
        // ('c2') in the snapshot. Both must be cancelled when `rescheduleAll`
        // replaces the schedule set.
        await scheduler.sync(
          conversation: conversation(id: 'c3', nextAt: targetTime),
          assistant: assistant(),
        );
        calls.clear();

        await scheduler.rescheduleAll(
          conversations: [
            conversation(id: 'c1', nextAt: targetTime),
            conversation(
              id: 'c2',
              nextAt: currentTime.subtract(const Duration(minutes: 5)),
            ),
          ],
          assistants: [assistant()],
        );

        expect(scheduler.schedules.keys, ['c1']);
        final cancels = calls
            .where((c) => c.method == 'cancel')
            .map((c) => c.arguments)
            .toSet();
        expect(cancels, {'c2', 'c3'});
        final schedules = calls.where((c) => c.method == 'schedule').toList();
        expect(schedules, hasLength(1));
        expect((schedules.single.arguments as Map)['runId'], 'c1');

        scheduler.dispose();
      },
    );

    test('schedule and cancel address the same native identifier', () async {
      final scheduler = createScheduler(arrivalBody: 'A letter has arrived.');
      final targetTime = currentTime.add(const Duration(minutes: 10));

      await scheduler.sync(
        conversation: conversation(id: 'c1', nextAt: targetTime),
        assistant: assistant(),
      );
      await scheduler.cancelFor('c1');

      final registered = calls.singleWhere((c) => c.method == 'schedule');
      final removed = calls.singleWhere((c) => c.method == 'cancel');
      final runId = (registered.arguments as Map)['runId'];
      expect(removed.arguments, runId);
      expect(runId, IosProactiveCareScheduler.notificationIdFor('c1'));
      expect(runId, 'c1');

      scheduler.dispose();
    });
  });
}
