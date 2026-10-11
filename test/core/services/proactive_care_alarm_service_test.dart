import 'dart:async';

import 'package:Cuplivo/core/models/assistant.dart';
import 'package:Cuplivo/core/models/conversation.dart';
import 'package:Cuplivo/core/services/in_process_proactive_care_scheduler.dart';
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

    test('attach installs the in-process foreground safety net', () async {
      await ProactiveCareAlarmService.attach((_, _) async {});

      expect(ProactiveCareAlarmService.inProcessScheduler, isNotNull);
      expect(calls.map((c) => c.method), contains('ready'));
    });

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
      'sync arms the native alarm and mirrors into the safety net',
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
        expect(scheduler.schedules['c1'], dueAt);

        scheduler.dispose();
      },
    );

    test('a past or ineligible schedule cancels both owners', () async {
      final scheduler = InProcessProactiveCareScheduler();
      ProactiveCareAlarmService.setInProcessSchedulerForTesting(scheduler);

      await ProactiveCareAlarmService.sync(
        conversation: conversation(nextAt: now.add(const Duration(minutes: 5))),
        assistant: assistant(),
      );
      expect(scheduler.schedules, isNotEmpty);

      await ProactiveCareAlarmService.sync(
        conversation: conversation(
          nextAt: now.subtract(const Duration(minutes: 5)),
        ),
        assistant: assistant(),
      );

      expect(calls.map((c) => c.method), contains('cancel'));
      expect(scheduler.schedules.containsKey('c1'), isFalse);

      scheduler.dispose();
    });

    test('rescheduleAll sends only future eligible letters', () async {
      final scheduler = InProcessProactiveCareScheduler();
      ProactiveCareAlarmService.setInProcessSchedulerForTesting(scheduler);
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
      expect(scheduler.schedules.keys, ['c1']);

      scheduler.dispose();
    });

    test('detach stops the safety net from firing held schedules', () async {
      // The facade's eligibility check reads the real clock, so the injected
      // scheduler clock has to start from now.
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

      await ProactiveCareAlarmService.detach();
      fired.clear();
      await ProactiveCareAlarmService.sync(
        conversation: conversation(
          nextAt: currentTime.add(const Duration(minutes: 1)),
        ),
        assistant: assistant(),
      );
      currentTime = currentTime.add(const Duration(minutes: 2));
      await scheduler.tickForTesting();
      expect(fired, isEmpty);

      scheduler.dispose();
    });
  });
}
