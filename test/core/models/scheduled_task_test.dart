import 'package:flutter_test/flutter_test.dart';
import 'package:Cuplivo/core/models/scheduled_task.dart';

void main() {
  group('ScheduledTaskSchedule.matchesTrigger', () {
    test('once runs only on its local calendar date and time window', () {
      final schedule = ScheduledTaskSchedule(
        frequency: ScheduledTaskFrequency.once,
        hour: 8,
        minute: 30,
        onceAt: DateTime(2026, 8, 20, 8, 30),
      );

      expect(schedule.matchesTrigger(DateTime(2026, 8, 20, 8, 30)), isTrue);
      expect(schedule.matchesTrigger(DateTime(2026, 8, 20, 9, 15)), isTrue);
      expect(schedule.matchesTrigger(DateTime(2026, 8, 20, 8, 20)), isFalse);
      expect(schedule.matchesTrigger(DateTime(2026, 8, 21, 8, 30)), isFalse);
    });

    test('daily interval is anchored to the selected start date', () {
      final schedule = ScheduledTaskSchedule(
        frequency: ScheduledTaskFrequency.daily,
        interval: 3,
        hour: 8,
        minute: 0,
        anchorDate: DateTime(2026, 8, 1),
      );

      expect(schedule.matchesTrigger(DateTime(2026, 8, 1, 8)), isTrue);
      expect(schedule.matchesTrigger(DateTime(2026, 8, 2, 8)), isFalse);
      expect(schedule.matchesTrigger(DateTime(2026, 8, 4, 8)), isTrue);
    });

    test('weekly interval supports multiple weekdays', () {
      final schedule = ScheduledTaskSchedule(
        frequency: ScheduledTaskFrequency.weekly,
        interval: 2,
        hour: 7,
        minute: 45,
        anchorDate: DateTime(2026, 8, 3), // Monday
        weekdays: const <int>[DateTime.monday, DateTime.friday],
      );

      expect(schedule.matchesTrigger(DateTime(2026, 8, 3, 7, 45)), isTrue);
      expect(schedule.matchesTrigger(DateTime(2026, 8, 7, 7, 45)), isTrue);
      expect(schedule.matchesTrigger(DateTime(2026, 8, 10, 7, 45)), isFalse);
      expect(schedule.matchesTrigger(DateTime(2026, 8, 17, 7, 45)), isTrue);
    });

    test('monthly interval supports multiple month days', () {
      final schedule = ScheduledTaskSchedule(
        frequency: ScheduledTaskFrequency.monthly,
        interval: 2,
        hour: 12,
        minute: 0,
        anchorDate: DateTime(2026, 1, 1),
        monthDays: const <int>[1, 15],
      );

      expect(schedule.matchesTrigger(DateTime(2026, 1, 15, 12)), isTrue);
      expect(schedule.matchesTrigger(DateTime(2026, 2, 15, 12)), isFalse);
      expect(schedule.matchesTrigger(DateTime(2026, 3, 1, 12)), isTrue);
    });

    test('yearly interval follows month and day', () {
      final schedule = ScheduledTaskSchedule(
        frequency: ScheduledTaskFrequency.yearly,
        interval: 2,
        hour: 9,
        minute: 0,
        anchorDate: DateTime(2026, 8, 14),
        yearMonth: 8,
        yearDay: 14,
      );

      expect(schedule.matchesTrigger(DateTime(2026, 8, 14, 9)), isTrue);
      expect(schedule.matchesTrigger(DateTime(2027, 8, 14, 9)), isFalse);
      expect(schedule.matchesTrigger(DateTime(2028, 8, 14, 9)), isTrue);
    });
  });
}
