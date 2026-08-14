import 'package:Cuplivo/core/models/assistant.dart';
import 'package:Cuplivo/core/services/proactive_care_alarm_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('ProactiveCareAlarmService.pendingForReschedule', () {
    final now = DateTime(2026, 8, 14, 12, 0, 0);

    Assistant assistant({
      String id = 'a1',
      bool enabled = true,
      DateTime? nextAt,
    }) => Assistant(
      id: id,
      name: 'Test',
      enableProactiveCare: enabled,
      proactiveCareNextMessageAt: nextAt,
    );

    test('empty list yields nothing to re-arm', () {
      expect(
        ProactiveCareAlarmService.pendingForReschedule(
          const <Assistant>[],
          now: now,
        ),
        isEmpty,
      );
    });

    test('assistant with proactive care disabled is skipped', () {
      final a = assistant(
        enabled: false,
        nextAt: now.add(const Duration(minutes: 5)),
      );
      expect(
        ProactiveCareAlarmService.pendingForReschedule([a], now: now),
        isEmpty,
      );
    });

    test('assistant without a next time is skipped', () {
      expect(
        ProactiveCareAlarmService.pendingForReschedule([
          assistant(nextAt: null),
        ], now: now),
        isEmpty,
      );
    });

    test('assistant with a past next time is skipped', () {
      final a = assistant(nextAt: now.subtract(const Duration(minutes: 1)));
      expect(
        ProactiveCareAlarmService.pendingForReschedule([a], now: now),
        isEmpty,
      );
    });

    test('next time exactly at now is skipped (must be strictly after)', () {
      expect(
        ProactiveCareAlarmService.pendingForReschedule([
          assistant(nextAt: now),
        ], now: now),
        isEmpty,
      );
    });

    test('assistant with a future next time is re-armed', () {
      final a = assistant(nextAt: now.add(const Duration(minutes: 5)));
      expect(ProactiveCareAlarmService.pendingForReschedule([a], now: now), [
        a,
      ]);
    });

    test('mixed list filters to only the pending assistants', () {
      final pending = assistant(nextAt: now.add(const Duration(minutes: 5)));
      final disabled = assistant(
        id: 'a2',
        enabled: false,
        nextAt: now.add(const Duration(minutes: 5)),
      );
      final noTime = assistant(id: 'a3', nextAt: null);
      final past = assistant(
        id: 'a4',
        nextAt: now.subtract(const Duration(minutes: 1)),
      );
      expect(
        ProactiveCareAlarmService.pendingForReschedule([
          pending,
          disabled,
          noTime,
          past,
        ], now: now),
        [pending],
      );
    });

    test('multiple pending assistants keep their original order', () {
      final pending1 = assistant(
        id: 'a1',
        nextAt: now.add(const Duration(minutes: 3)),
      );
      final disabled = assistant(
        id: 'a2',
        enabled: false,
        nextAt: now.add(const Duration(minutes: 5)),
      );
      final pending2 = assistant(
        id: 'a3',
        nextAt: now.add(const Duration(minutes: 9)),
      );
      final past = assistant(
        id: 'a4',
        nextAt: now.subtract(const Duration(minutes: 1)),
      );
      expect(
        ProactiveCareAlarmService.pendingForReschedule([
          pending1,
          disabled,
          pending2,
          past,
        ], now: now),
        [pending1, pending2],
      );
    });

    test('uses the wall clock when now is not provided', () {
      final a = assistant(
        nextAt: DateTime.now().add(const Duration(minutes: 5)),
      );
      expect(ProactiveCareAlarmService.pendingForReschedule([a]), [a]);
    });
  });
}
