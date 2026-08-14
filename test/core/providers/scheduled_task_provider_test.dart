import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:Cuplivo/core/models/scheduled_task.dart';
import 'package:Cuplivo/core/providers/scheduled_task_provider.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  test('schedule edits invalidate the Trigger ID but content edits do not', () async {
    final provider = ScheduledTaskProvider();
    await provider.init();

    final task = await provider.createTask(
      assistantId: 'assistant-a',
      name: 'Morning task',
      prompt: 'Do the thing',
      schedule: ScheduledTaskSchedule(
        frequency: ScheduledTaskFrequency.daily,
        hour: 8,
        minute: 0,
        anchorDate: DateTime(2026, 8, 14),
      ),
    );
    await provider.markConnected(task.id);
    final connected = provider.getById(task.id)!;

    final contentEdit = await provider.updateTask(
      id: task.id,
      name: 'Renamed task',
      prompt: 'Do the improved thing',
    );
    expect(contentEdit!.triggerId, connected.triggerId);
    expect(contentEdit.connected, isTrue);

    final oldTrigger = contentEdit.triggerId;
    final scheduleEdit = await provider.updateTask(
      id: task.id,
      schedule: ScheduledTaskSchedule(
        frequency: ScheduledTaskFrequency.daily,
        hour: 9,
        minute: 0,
        anchorDate: DateTime(2026, 8, 14),
      ),
    );
    expect(scheduleEdit!.triggerId, isNot(oldTrigger));
    expect(scheduleEdit.connected, isFalse);
    expect(provider.getByTriggerId(oldTrigger), isNull);
  });

  test('deleting a task makes an old Trigger ID harmless', () async {
    final provider = ScheduledTaskProvider();
    await provider.init();
    final task = await provider.createTask(
      assistantId: 'assistant-a',
      name: 'One shot',
      prompt: 'Run once',
      schedule: ScheduledTaskSchedule(
        frequency: ScheduledTaskFrequency.once,
        hour: 10,
        minute: 0,
        onceAt: DateTime(2026, 8, 20, 10),
      ),
    );

    expect(await provider.deleteTask(task.id), isTrue);
    expect(provider.getByTriggerId(task.triggerId), isNull);
  });

  test('rescheduling a completed once task makes it runnable again', () async {
    final provider = ScheduledTaskProvider();
    await provider.init();
    final task = await provider.createTask(
      assistantId: 'assistant-a',
      name: 'One shot',
      prompt: 'Run once',
      schedule: ScheduledTaskSchedule(
        frequency: ScheduledTaskFrequency.once,
        hour: 10,
        minute: 0,
        onceAt: DateTime(2026, 8, 20, 10),
      ),
    );

    await provider.markOnceCompleted(task.id, DateTime(2026, 8, 20, 10, 1));
    expect(provider.getById(task.id)!.isCompleted, isTrue);

    final updated = await provider.updateTask(
      id: task.id,
      schedule: ScheduledTaskSchedule(
        frequency: ScheduledTaskFrequency.once,
        hour: 11,
        minute: 0,
        onceAt: DateTime(2026, 8, 21, 11),
      ),
    );
    expect(updated!.isCompleted, isFalse);
  });
  test('the same recurrence occurrence can only be claimed once', () async {
    final provider = ScheduledTaskProvider();
    await provider.init();
    final task = await provider.createTask(
      assistantId: 'assistant-a',
      name: 'Daily task',
      prompt: 'Run daily',
      schedule: ScheduledTaskSchedule(
        frequency: ScheduledTaskFrequency.daily,
        hour: 8,
        minute: 0,
        anchorDate: DateTime(2026, 8, 14),
      ),
    );

    expect(
      await provider.claimOccurrence(
        taskId: task.id,
        triggerId: task.triggerId,
        occurrenceKey: '2026-08-14@08:00',
      ),
      isTrue,
    );
    expect(
      await provider.claimOccurrence(
        taskId: task.id,
        triggerId: task.triggerId,
        occurrenceKey: '2026-08-14@08:00',
      ),
      isFalse,
    );
    expect(
      await provider.claimOccurrence(
        taskId: task.id,
        triggerId: task.triggerId,
        occurrenceKey: '2026-08-15@08:00',
      ),
      isTrue,
    );
  });

}
