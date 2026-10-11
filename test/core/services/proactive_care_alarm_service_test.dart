import 'dart:async';

import 'package:Cuplivo/core/models/assistant.dart';
import 'package:Cuplivo/core/models/conversation.dart';
import 'package:Cuplivo/core/services/in_process_proactive_care_scheduler.dart';
import 'package:Cuplivo/core/services/ios_proactive_care_scheduler.dart';
import 'package:Cuplivo/core/services/proactive_care_alarm_service.dart';
import 'package:Cuplivo/core/services/notification_service.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const alarmChannel = MethodChannel('app.proactive_care_alarms');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  final calls = <MethodCall>[];

  setUp(() {
    calls.clear();
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    messenger.setMockMethodCallHandler(alarmChannel, (call) async {
      calls.add(call);
      return null;
    });
  });

  tearDown(() {
    ProactiveCareAlarmService.setInProcessSchedulerForTesting(null);
    ProactiveCareAlarmService.setDesktopSchedulerForTesting(null);
    ProactiveCareAlarmService.resetExactAlarmStatusForTesting();
    debugDefaultTargetPlatformOverride = null;
    messenger.setMockMethodCallHandler(alarmChannel, null);
  });

  Future<void> native(String method, Object? args) async {
    final reply = Completer<void>();
    await messenger.handlePlatformMessage(
      alarmChannel.name,
      const StandardMethodCodec().encodeMethodCall(MethodCall(method, args)),
      (_) => reply.complete(),
    );
    await reply.future;
  }

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

  group('ProactiveCareAlarmService Android trigger chain', () {
    final now = DateTime.now();

    Assistant assistant({String id = 'a1', bool enabled = true}) =>
        Assistant(id: id, name: 'Test', enableProactiveCare: enabled);

    Conversation conversation({
      String id = 'c1',
      String? assistantId = 'a1',
      DateTime? nextAt,
    }) {
      var conv = Conversation(id: id, title: 'Chat', assistantId: assistantId);
      if (nextAt != null) {
        conv = conv.setProactiveCareNextMessageAt(nextAt);
      }
      return conv;
    }

    test(
      'attach readies the native owner and installs no in-app executor',
      () async {
        await ProactiveCareAlarmService.attach((_, _) async {});

        // Kelivo has no in-app executor on Android (ScheduledTasksService
        // .configureDevice returns early there), so care must not add one: the
        // native exact alarm is the only trigger.
        expect(ProactiveCareAlarmService.inProcessScheduler, isNull);
        expect(calls.map((c) => c.method), contains('ready'));
      },
    );

    test('a native fire reaches the handler and completes the run', () async {
      final fired = <String>[];
      await ProactiveCareAlarmService.attach((
        conversationId,
        expectedAt,
      ) async {
        fired.add(conversationId);
      });

      await native('fire', {
        'conversationId': 'c1',
        'dueAt': now.millisecondsSinceEpoch,
      });
      await pumpEventQueue();

      expect(fired, ['c1']);
      expect(calls.map((c) => c.method), contains('done'));
    });

    test(
      'sync arms the native alarm and leaves the mirror untouched',
      () async {
        final scheduler = InProcessProactiveCareScheduler();
        ProactiveCareAlarmService.setInProcessSchedulerForTesting(scheduler);
        final dueAt = now.add(const Duration(minutes: 10));

        await ProactiveCareAlarmService.sync(
          conversation: conversation(nextAt: dueAt),
          assistant: assistant(),
        );

        final sync = calls.singleWhere((c) => c.method == 'sync');
        expect(sync.arguments, {
          'conversationId': 'c1',
          'dueAt': dueAt.millisecondsSinceEpoch,
        });
        // Android has no in-process owner, so nothing may be mirrored into one.
        expect(scheduler.schedules, isEmpty);

        scheduler.dispose();
      },
    );

    test('a past or ineligible schedule cancels the native alarm', () async {
      await ProactiveCareAlarmService.sync(
        conversation: conversation(nextAt: now.add(const Duration(minutes: 5))),
        assistant: assistant(),
      );
      expect(calls.map((c) => c.method), contains('sync'));

      await ProactiveCareAlarmService.sync(
        conversation: conversation(
          nextAt: now.subtract(const Duration(minutes: 5)),
        ),
        assistant: assistant(),
      );

      expect(calls.map((c) => c.method), contains('cancel'));
    });

    test('rescheduleAll sends only future eligible letters', () async {
      final dueAt = now.add(const Duration(minutes: 10));

      await ProactiveCareAlarmService.rescheduleAll(
        conversations: [
          conversation(nextAt: dueAt),
          conversation(
            id: 'past',
            nextAt: now.subtract(const Duration(minutes: 5)),
          ),
        ],
        assistants: [assistant()],
      );

      final payload =
          (calls.singleWhere((c) => c.method == 'rescheduleAll').arguments
                  as Map)['alarms']
              as List;
      expect(payload, [
        {'conversationId': 'c1', 'dueAt': dueAt.millisecondsSinceEpoch},
      ]);
    });

    test('rescheduleAll refuses a snapshot with no owner assistant', () async {
      final dueAt = now.add(const Duration(minutes: 10));

      await ProactiveCareAlarmService.rescheduleAll(
        conversations: [conversation(nextAt: dueAt)],
        assistants: const [],
      );

      // A replace-all on a snapshot whose assistant store is unloaded would
      // cancel the alarms it cannot see, so the whole call must be refused.
      expect(calls.map((c) => c.method), isNot(contains('rescheduleAll')));
    });

    test(
      'rescheduleAll refuses a snapshot missing a scheduled owner',
      () async {
        await ProactiveCareAlarmService.rescheduleAll(
          conversations: [
            conversation(
              assistantId: 'a1',
              nextAt: now.add(const Duration(minutes: 10)),
            ),
          ],
          // The scheduled conversation is owned by a1; a partially loaded store
          // would look exactly like this, and a replace-all would cancel it.
          assistants: [assistant(id: 'a2')],
        );

        expect(calls.map((c) => c.method), isNot(contains('rescheduleAll')));
      },
    );

    test('a stale schedule no longer vetoes the whole re-arm', () async {
      final dueAt = now.add(const Duration(minutes: 10));

      // Only the past-due row has a dangling owner. It can never be armed
      // again, so it must not block the healthy pending letter (the same
      // applies to a schedule whose owner id is gone entirely).
      await ProactiveCareAlarmService.rescheduleAll(
        conversations: [
          conversation(nextAt: dueAt),
          conversation(
            id: 'stale',
            assistantId: 'deleted',
            nextAt: now.subtract(const Duration(minutes: 5)),
          ),
          conversation(id: 'ownerless', assistantId: null, nextAt: dueAt),
        ],
        assistants: [assistant()],
      );

      final payload =
          (calls.singleWhere((c) => c.method == 'rescheduleAll').arguments
                  as Map)['alarms']
              as List;
      expect(payload, [
        {'conversationId': 'c1', 'dueAt': dueAt.millisecondsSinceEpoch},
      ]);
    });

    test('the exact-alarm grant the native owner reports is kept', () async {
      messenger.setMockMethodCallHandler(alarmChannel, (call) async {
        calls.add(call);
        return {'exactAlarms': false};
      });

      await ProactiveCareAlarmService.sync(
        conversation: conversation(
          nextAt: now.add(const Duration(minutes: 10)),
        ),
        assistant: assistant(),
      );

      // Dart may not claim a background schedule the system refused.
      expect(ProactiveCareAlarmService.exactAlarmsPermitted, isFalse);
    });

    test('rescheduleAll also refreshes the grant state', () async {
      messenger.setMockMethodCallHandler(alarmChannel, (call) async {
        calls.add(call);
        return {'exactAlarms': true};
      });

      await ProactiveCareAlarmService.rescheduleAll(
        conversations: [
          conversation(nextAt: now.add(const Duration(minutes: 10))),
        ],
        assistants: [assistant()],
      );

      expect(ProactiveCareAlarmService.exactAlarmsPermitted, isTrue);
    });
  });

  // Kelivo's own iOS scheduler runs due scheduled tasks in-app while the app is
  // alive (PreparedScheduledTasks); proactive care reused only its arrival
  // notification, which is why a care time reached in the foreground produced
  // nothing at all. These tests pin the parity.
  group('ProactiveCareAlarmService iOS trigger chain', () {
    const scheduledChannel = MethodChannel('app.scheduled_notifications');
    final scheduledCalls = <MethodCall>[];

    setUp(() {
      scheduledCalls.clear();
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      messenger.setMockMethodCallHandler(scheduledChannel, (call) async {
        scheduledCalls.add(call);
        return null;
      });
      ProactiveCareAlarmService.setIosSchedulerForTesting(
        IosProactiveCareScheduler(
          channel: scheduledChannel,
          isIos: () => true,
          arrivalBodyResolver: () => 'A letter has arrived.',
        ),
      );
    });

    tearDown(() {
      ProactiveCareAlarmService.setIosSchedulerForTesting(null);
      messenger.setMockMethodCallHandler(scheduledChannel, null);
    });

    final now = DateTime.now();

    Assistant assistant({String id = 'a1', bool enabled = true}) =>
        Assistant(id: id, name: 'Test', enableProactiveCare: enabled);

    Conversation conversation({
      String id = 'c1',
      String? assistantId = 'a1',
      DateTime? nextAt,
    }) {
      var conv = Conversation(id: id, title: 'Chat', assistantId: assistantId);
      if (nextAt != null) {
        conv = conv.setProactiveCareNextMessageAt(nextAt);
      }
      return conv;
    }

    test('attach installs the in-app executor without touching the alarm '
        'channel', () async {
      await ProactiveCareAlarmService.attach((_, _) async {});

      expect(ProactiveCareAlarmService.inProcessScheduler, isNotNull);
      expect(calls, isEmpty);
    });

    test(
      'sync mirrors into the executor and arms the arrival notification',
      () async {
        final scheduler = InProcessProactiveCareScheduler();
        ProactiveCareAlarmService.setInProcessSchedulerForTesting(scheduler);
        final dueAt = now.add(const Duration(minutes: 10));

        await ProactiveCareAlarmService.sync(
          conversation: conversation(nextAt: dueAt),
          assistant: assistant(),
        );

        expect(scheduler.schedules['c1'], dueAt);
        final schedule = scheduledCalls.singleWhere(
          (c) => c.method == 'schedule',
        );
        final args = schedule.arguments as Map;
        expect(args['runId'], 'c1');
        expect(args['at'], dueAt.millisecondsSinceEpoch);
        expect(args['title'], 'Test');
        expect(args['prepared'], isFalse);
        expect(args['payload'], 'proactive-care:c1');

        scheduler.dispose();
      },
    );

    test('a due letter fires in-app while the app is alive', () async {
      var currentTime = DateTime.now();
      final scheduler = InProcessProactiveCareScheduler(now: () => currentTime);
      ProactiveCareAlarmService.setInProcessSchedulerForTesting(scheduler);
      final fired = <String>[];
      await ProactiveCareAlarmService.attach((conversationId, _) async {
        fired.add(conversationId);
      });

      await ProactiveCareAlarmService.sync(
        conversation: conversation(
          nextAt: currentTime.add(const Duration(minutes: 1)),
        ),
        assistant: assistant(),
      );
      currentTime = currentTime.add(const Duration(minutes: 2));
      await scheduler.tickForTesting();

      expect(fired, ['c1']);

      scheduler.dispose();
    });

    test('cancelFor clears both owners', () async {
      final scheduler = InProcessProactiveCareScheduler();
      ProactiveCareAlarmService.setInProcessSchedulerForTesting(scheduler);

      await ProactiveCareAlarmService.sync(
        conversation: conversation(nextAt: now.add(const Duration(minutes: 5))),
        assistant: assistant(),
      );
      expect(scheduler.schedules, isNotEmpty);
      scheduledCalls.clear();

      await ProactiveCareAlarmService.cancelFor('c1');

      expect(scheduler.schedules.containsKey('c1'), isFalse);
      expect(scheduledCalls.map((c) => c.method), contains('cancel'));

      scheduler.dispose();
    });
  });
}
