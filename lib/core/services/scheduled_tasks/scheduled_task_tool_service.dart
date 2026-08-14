import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../../models/scheduled_task.dart';
import '../../providers/scheduled_task_provider.dart';

class ScheduledTaskToolNames {
  const ScheduledTaskToolNames._();

  static const String list = 'list_scheduled_tasks';
  static const String create = 'create_scheduled_task';
  static const String update = 'update_scheduled_task';
  static const String delete = 'delete_scheduled_task';
  static const String setEnabled = 'set_scheduled_task_enabled';

  static const Set<String> all = <String>{
    list,
    create,
    update,
    delete,
    setEnabled,
  };

  static const Set<String> writes = <String>{
    create,
    update,
    delete,
    setEnabled,
  };
}

class ScheduledTaskToolService {
  const ScheduledTaskToolService._();

  static bool get isSupportedPlatform =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.iOS;

  static bool isToolName(String name) => ScheduledTaskToolNames.all.contains(name);

  static bool requiresApproval(String name) =>
      ScheduledTaskToolNames.writes.contains(name);

  static List<Map<String, dynamic>> buildToolDefinitions() {
    if (!isSupportedPlatform) return const <Map<String, dynamic>>[];
    return <Map<String, dynamic>>[
      {
        'type': 'function',
        'function': {
          'name': ScheduledTaskToolNames.list,
          'description':
              'List scheduled tasks owned by this assistant. Use this before '
              'editing, deleting, enabling, or disabling an existing task. '
              'The assistant can only see its own scheduled tasks.',
          'parameters': {'type': 'object', 'properties': <String, dynamic>{}},
        },
      },
      {
        'type': 'function',
        'function': {
          'name': ScheduledTaskToolNames.create,
          'description':
              'Create an iOS scheduled task owned by this assistant. The task '
              'runs in a brand-new conversation when triggered. Hourly schedules '
              'are not supported. Schedules follow the device current local '
              'timezone. Use interval > 1 for every N days/weeks/months/years. '
              'Weekly schedules may choose multiple ISO weekdays (Monday=1). '
              'Monthly schedules may choose multiple calendar month days. '
              'After creation the user still needs to connect the task to an '
              'iOS Shortcuts personal automation from Cuplivo Settings.',
          'parameters': {
            'type': 'object',
            'properties': {
              'name': {
                'type': 'string',
                'description': 'Short human-readable task name.',
              },
              'prompt': {
                'type': 'string',
                'description':
                    'The complete user message sent in the new conversation when the task runs.',
              },
              'schedule': _scheduleSchema,
            },
            'required': ['name', 'prompt', 'schedule'],
          },
        },
      },
      {
        'type': 'function',
        'function': {
          'name': ScheduledTaskToolNames.update,
          'description':
              'Edit one scheduled task owned by this assistant. Call '
              'list_scheduled_tasks first to obtain task_id. Changing any '
              'schedule field invalidates the old iOS Shortcut Trigger ID and '
              'the user must reconnect the task. Changing only name or prompt '
              'does not require reconnection.',
          'parameters': {
            'type': 'object',
            'properties': {
              'task_id': {'type': 'string'},
              'name': {'type': 'string'},
              'prompt': {'type': 'string'},
              'schedule': _scheduleSchema,
            },
            'required': ['task_id'],
          },
        },
      },
      {
        'type': 'function',
        'function': {
          'name': ScheduledTaskToolNames.delete,
          'description':
              'Delete one scheduled task owned by this assistant. Old iOS '
              'Shortcut triggers become harmless: Cuplivo will no longer find '
              'their Trigger ID and will silently ignore them.',
          'parameters': {
            'type': 'object',
            'properties': {
              'task_id': {'type': 'string'},
            },
            'required': ['task_id'],
          },
        },
      },
      {
        'type': 'function',
        'function': {
          'name': ScheduledTaskToolNames.setEnabled,
          'description':
              'Enable or disable one scheduled task owned by this assistant. '
              'A disabled task silently ignores Shortcut triggers.',
          'parameters': {
            'type': 'object',
            'properties': {
              'task_id': {'type': 'string'},
              'enabled': {'type': 'boolean'},
            },
            'required': ['task_id', 'enabled'],
          },
        },
      },
    ];
  }

  static const Map<String, dynamic> _scheduleSchema = <String, dynamic>{
    'type': 'object',
    'description':
        'Schedule in the device current local timezone. frequency is once, daily, weekly, monthly, or yearly. Hourly is unsupported.',
    'properties': <String, dynamic>{
      'frequency': <String, dynamic>{
        'type': 'string',
        'enum': <String>['once', 'daily', 'weekly', 'monthly', 'yearly'],
      },
      'interval': <String, dynamic>{
        'type': 'integer',
        'description': 'Every N units. Minimum 1. Ignored for once.',
      },
      'hour': <String, dynamic>{
        'type': 'integer',
        'description': 'Local hour, 0-23. Required except when once_at is supplied.',
      },
      'minute': <String, dynamic>{
        'type': 'integer',
        'description': 'Local minute, 0-59. Required except when once_at is supplied.',
      },
      'anchor_date': <String, dynamic>{
        'type': 'string',
        'description':
            'Local YYYY-MM-DD recurrence anchor. Defaults to today. Useful for every N units.',
      },
      'weekdays': <String, dynamic>{
        'type': 'array',
        'description': 'For weekly recurrence. ISO weekdays Monday=1 ... Sunday=7.',
        'items': <String, dynamic>{'type': 'integer'},
      },
      'month_days': <String, dynamic>{
        'type': 'array',
        'description': 'For monthly recurrence. Calendar days 1...31.',
        'items': <String, dynamic>{'type': 'integer'},
      },
      'month': <String, dynamic>{
        'type': 'integer',
        'description': 'For yearly recurrence, month 1...12.',
      },
      'day': <String, dynamic>{
        'type': 'integer',
        'description': 'For yearly recurrence, day 1...31.',
      },
      'once_at': <String, dynamic>{
        'type': 'string',
        'description':
            'For once recurrence, local ISO date-time such as 2026-08-20T18:30:00.',
      },
    },
    'required': <String>['frequency'],
  };

  static Future<String> execute({
    required String name,
    required Map<String, dynamic> arguments,
    required String assistantId,
    required ScheduledTaskProvider provider,
  }) async {
    await provider.ensureLoaded();
    if (!provider.allowAiOperations) {
      return _error('scheduled_tasks_disabled', 'AI scheduled-task access is disabled.');
    }

    switch (name) {
      case ScheduledTaskToolNames.list:
        final tasks = provider.forAssistant(assistantId);
        return jsonEncode(<String, dynamic>{
          'tasks': tasks.map(_taskForTool).toList(growable: false),
        });
      case ScheduledTaskToolNames.create:
        final taskName = (arguments['name'] ?? '').toString().trim();
        final prompt = (arguments['prompt'] ?? '').toString().trim();
        if (taskName.isEmpty || prompt.isEmpty) {
          return _error('invalid_arguments', 'name and prompt are required.');
        }
        final schedule = _parseSchedule(arguments['schedule']);
        if (schedule == null) {
          return _error('invalid_schedule', 'The schedule is invalid or incomplete.');
        }
        final task = await provider.createTask(
          assistantId: assistantId,
          name: taskName,
          prompt: prompt,
          schedule: schedule,
        );
        return jsonEncode(<String, dynamic>{
          'success': true,
          'task': _taskForTool(task),
          'needs_shortcuts_connection': true,
        });
      case ScheduledTaskToolNames.update:
        final task = _ownedTask(arguments, assistantId, provider);
        if (task == null) return _notFound();
        ScheduledTaskSchedule? schedule;
        if (arguments.containsKey('schedule')) {
          schedule = _parseSchedule(arguments['schedule']);
          if (schedule == null) {
            return _error('invalid_schedule', 'The schedule is invalid or incomplete.');
          }
        }
        final nextName = arguments.containsKey('name')
            ? arguments['name']?.toString().trim()
            : null;
        final nextPrompt = arguments.containsKey('prompt')
            ? arguments['prompt']?.toString().trim()
            : null;
        if ((nextName != null && nextName.isEmpty) ||
            (nextPrompt != null && nextPrompt.isEmpty)) {
          return _error(
            'invalid_arguments',
            'name and prompt cannot be empty when supplied.',
          );
        }
        final updated = await provider.updateTask(
          id: task.id,
          name: nextName,
          prompt: nextPrompt,
          schedule: schedule,
        );
        if (updated == null) return _notFound();
        return jsonEncode(<String, dynamic>{
          'success': true,
          'task': _taskForTool(updated),
          'needs_shortcuts_connection': !updated.connected,
        });
      case ScheduledTaskToolNames.delete:
        final task = _ownedTask(arguments, assistantId, provider);
        if (task == null) return _notFound();
        await provider.deleteTask(task.id);
        return jsonEncode(<String, dynamic>{'success': true, 'task_id': task.id});
      case ScheduledTaskToolNames.setEnabled:
        final task = _ownedTask(arguments, assistantId, provider);
        if (task == null) return _notFound();
        final enabled = arguments['enabled'];
        if (enabled is! bool) {
          return _error('invalid_arguments', 'enabled must be a boolean.');
        }
        final updated = await provider.setEnabled(task.id, enabled);
        return jsonEncode(<String, dynamic>{
          'success': updated != null,
          if (updated != null) 'task': _taskForTool(updated),
        });
      default:
        return _error('unknown_tool', 'Unknown scheduled-task tool: $name');
    }
  }

  static ScheduledTask? _ownedTask(
    Map<String, dynamic> arguments,
    String assistantId,
    ScheduledTaskProvider provider,
  ) {
    final id = (arguments['task_id'] ?? '').toString();
    final task = provider.getById(id);
    if (task == null || task.assistantId != assistantId) return null;
    return task;
  }

  static Map<String, dynamic> _taskForTool(ScheduledTask task) => <String, dynamic>{
    'task_id': task.id,
    'name': task.name,
    'prompt': task.prompt,
    'enabled': task.enabled,
    'connected': task.connected,
    'completed': task.isCompleted,
    'schedule': task.schedule.toJson(),
  };

  static ScheduledTaskSchedule? _parseSchedule(dynamic raw) {
    if (raw is! Map) return null;
    final map = raw.cast<String, dynamic>();
    final frequencyName = (map['frequency'] ?? '').toString();
    ScheduledTaskFrequency? frequency;
    for (final candidate in ScheduledTaskFrequency.values) {
      if (candidate.name == frequencyName) {
        frequency = candidate;
        break;
      }
    }
    if (frequency == null) return null;

    final now = DateTime.now();
    final onceAtRaw = (map['once_at'] ?? '').toString().trim();
    final parsedOnceAt = DateTime.tryParse(onceAtRaw);
    final onceAt = parsedOnceAt?.toLocal();
    if (frequency == ScheduledTaskFrequency.once && onceAt == null) return null;

    final interval = _asInt(map['interval']) ?? 1;
    if (interval < 1) return null;

    final hour = onceAt?.hour ?? _asInt(map['hour']) ?? -1;
    final minute = onceAt?.minute ?? _asInt(map['minute']) ?? -1;
    if (hour < 0 || hour > 23 || minute < 0 || minute > 59) return null;

    DateTime? anchor;
    final anchorRaw = (map['anchor_date'] ?? '').toString();
    if (anchorRaw.isNotEmpty) {
      anchor = DateTime.tryParse(anchorRaw)?.toLocal();
      if (anchor == null) return null;
    }
    anchor ??= onceAt ?? now;

    List<int> intList(String key) {
      final values = map[key];
      if (values is! List) return const <int>[];
      return values.map(_asInt).whereType<int>().toList(growable: false);
    }

    final weekdays = intList('weekdays');
    if (weekdays.any((day) => day < DateTime.monday || day > DateTime.sunday)) {
      return null;
    }
    final monthDays = intList('month_days');
    if (monthDays.any((day) => day < 1 || day > 31)) return null;

    final yearMonth = _asInt(map['month']);
    final yearDay = _asInt(map['day']);
    if (yearMonth != null && (yearMonth < 1 || yearMonth > 12)) return null;
    if (yearDay != null && (yearDay < 1 || yearDay > 31)) return null;
    if (frequency == ScheduledTaskFrequency.yearly &&
        yearMonth != null &&
        yearDay != null &&
        !_isValidMonthDay(yearMonth, yearDay)) {
      return null;
    }

    return ScheduledTaskSchedule(
      frequency: frequency,
      interval: interval,
      hour: hour,
      minute: minute,
      anchorDate: anchor,
      weekdays: weekdays,
      monthDays: monthDays,
      yearMonth: yearMonth,
      yearDay: yearDay,
      onceAt: onceAt,
    ).normalized();
  }

  static bool _isValidMonthDay(int month, int day) {
    final lastDay = DateTime(2024, month + 1, 0).day;
    return day <= lastDay;
  }

  static int? _asInt(dynamic value) {
    if (value is int) return value;
    if (value is num) return value.toInt();
    return int.tryParse(value?.toString() ?? '');
  }

  static String _notFound() =>
      _error('task_not_found', 'The task does not exist or belongs to another assistant.');

  static String _error(String code, String message) => jsonEncode(<String, dynamic>{
    'success': false,
    'error': code,
    'message': message,
  });
}
