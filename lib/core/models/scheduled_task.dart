import 'dart:math' as math;

/// Recurrence modes supported by iOS scheduled tasks.
///
/// Hourly recurrence is intentionally excluded from the first iOS version:
/// Shortcuts' time-of-day automation is used as the daily wake-up gate, and
/// Cuplivo decides whether the current local date belongs to the recurrence.
enum ScheduledTaskFrequency { once, daily, weekly, monthly, yearly }

enum ScheduledTaskExecutionStatus { success, failure }

class ScheduledTaskLog {
  const ScheduledTaskLog({
    required this.id,
    required this.triggeredAt,
    required this.finishedAt,
    required this.status,
    this.conversationId,
    this.error,
  });

  final String id;
  final DateTime triggeredAt;
  final DateTime finishedAt;
  final ScheduledTaskExecutionStatus status;
  final String? conversationId;
  final String? error;

  Map<String, dynamic> toJson() => <String, dynamic>{
    'id': id,
    'triggeredAt': triggeredAt.toIso8601String(),
    'finishedAt': finishedAt.toIso8601String(),
    'status': status.name,
    if (conversationId != null) 'conversationId': conversationId,
    if (error != null) 'error': error,
  };

  factory ScheduledTaskLog.fromJson(Map<String, dynamic> json) {
    return ScheduledTaskLog(
      id: (json['id'] ?? '').toString(),
      triggeredAt:
          DateTime.tryParse((json['triggeredAt'] ?? '').toString()) ??
          DateTime.now(),
      finishedAt:
          DateTime.tryParse((json['finishedAt'] ?? '').toString()) ??
          DateTime.now(),
      status: ScheduledTaskExecutionStatus.values.firstWhere(
        (value) => value.name == json['status'],
        orElse: () => ScheduledTaskExecutionStatus.failure,
      ),
      conversationId: json['conversationId']?.toString(),
      error: json['error']?.toString(),
    );
  }
}

class ScheduledTaskSchedule {
  const ScheduledTaskSchedule({
    required this.frequency,
    required this.hour,
    required this.minute,
    this.interval = 1,
    this.anchorDate,
    this.weekdays = const <int>[],
    this.monthDays = const <int>[],
    this.yearMonth,
    this.yearDay,
    this.onceAt,
  });

  final ScheduledTaskFrequency frequency;
  final int interval;
  final int hour;
  final int minute;

  /// Local calendar anchor for every-N recurrence. Timezone is deliberately
  /// not persisted: schedules follow the device's current local timezone.
  final DateTime? anchorDate;

  /// ISO weekdays: Monday=1 ... Sunday=7.
  final List<int> weekdays;

  /// Calendar days of month (1...31). Invalid dates in a particular month are
  /// simply skipped for that month.
  final List<int> monthDays;

  final int? yearMonth;
  final int? yearDay;
  final DateTime? onceAt;

  ScheduledTaskSchedule normalized() {
    final normalizedInterval = math.max(1, interval);
    final normalizedHour = hour.clamp(0, 23).toInt();
    final normalizedMinute = minute.clamp(0, 59).toInt();
    final now = DateTime.now();
    final anchor = _dateOnly(anchorDate ?? onceAt ?? now);
    final normalizedWeekdays = weekdays
        .where((value) => value >= DateTime.monday && value <= DateTime.sunday)
        .toSet()
        .toList()
      ..sort();
    final normalizedMonthDays = monthDays
        .where((value) => value >= 1 && value <= 31)
        .toSet()
        .toList()
      ..sort();
    final oneTime = onceAt;
    return ScheduledTaskSchedule(
      frequency: frequency,
      interval: normalizedInterval,
      hour: oneTime?.hour ?? normalizedHour,
      minute: oneTime?.minute ?? normalizedMinute,
      anchorDate: anchor,
      weekdays: normalizedWeekdays,
      monthDays: normalizedMonthDays,
      yearMonth: (yearMonth ?? anchor.month).clamp(1, 12).toInt(),
      yearDay: (yearDay ?? anchor.day).clamp(1, 31).toInt(),
      onceAt: oneTime,
    );
  }

  /// Whether a trigger received at [now] should execute this schedule.
  ///
  /// Shortcuts should invoke Cuplivo at the configured local clock time every
  /// day. iOS may deliver an automation a little late, so a one-hour window is
  /// accepted. The Trigger ID still identifies the exact task, so this window
  /// never performs "nearest task" guessing.
  bool matchesTrigger(DateTime now, {Duration tolerance = const Duration(hours: 1)}) {
    final schedule = normalized();
    final targetToday = DateTime(
      now.year,
      now.month,
      now.day,
      schedule.hour,
      schedule.minute,
    );
    final lateness = now.difference(targetToday);
    if (lateness < const Duration(minutes: -1) || lateness > tolerance) {
      return false;
    }

    final today = _dateOnly(now);
    final anchor = _dateOnly(schedule.anchorDate ?? today);
    if (today.isBefore(anchor) && schedule.frequency != ScheduledTaskFrequency.once) {
      return false;
    }

    switch (schedule.frequency) {
      case ScheduledTaskFrequency.once:
        final once = schedule.onceAt;
        if (once == null) return false;
        return _sameDate(today, _dateOnly(once));
      case ScheduledTaskFrequency.daily:
        final days = _calendarDaysBetween(today, anchor);
        return days >= 0 && days % schedule.interval == 0;
      case ScheduledTaskFrequency.weekly:
        final anchorWeek = anchor.subtract(Duration(days: anchor.weekday - 1));
        final todayWeek = today.subtract(Duration(days: today.weekday - 1));
        final weeks = _calendarDaysBetween(todayWeek, anchorWeek) ~/ 7;
        final days = schedule.weekdays.isEmpty
            ? <int>[anchor.weekday]
            : schedule.weekdays;
        return weeks >= 0 &&
            weeks % schedule.interval == 0 &&
            days.contains(today.weekday);
      case ScheduledTaskFrequency.monthly:
        final months = (today.year - anchor.year) * 12 + today.month - anchor.month;
        final days = schedule.monthDays.isEmpty
            ? <int>[anchor.day]
            : schedule.monthDays;
        return months >= 0 &&
            months % schedule.interval == 0 &&
            days.contains(today.day);
      case ScheduledTaskFrequency.yearly:
        final years = today.year - anchor.year;
        return years >= 0 &&
            years % schedule.interval == 0 &&
            today.month == (schedule.yearMonth ?? anchor.month) &&
            today.day == (schedule.yearDay ?? anchor.day);
    }
  }

  /// Stable key for one due occurrence. Multiple Shortcuts may accidentally
  /// point at the same Trigger ID, so execution claims this key before making
  /// a model request and never retries that occurrence.
  String? occurrenceKey(
    DateTime now, {
    Duration tolerance = const Duration(hours: 1),
  }) {
    if (!matchesTrigger(now, tolerance: tolerance)) return null;
    final s = normalized();
    final y = now.year.toString().padLeft(4, '0');
    final m = now.month.toString().padLeft(2, '0');
    final d = now.day.toString().padLeft(2, '0');
    final h = s.hour.toString().padLeft(2, '0');
    final min = s.minute.toString().padLeft(2, '0');
    return '$y-$m-$d@$h:$min';
  }

  /// String used only for detecting whether editing a task invalidates the
  /// existing Shortcut trigger binding.
  String get triggerSignature {
    final s = normalized();
    return <Object?>[
      s.frequency.name,
      s.interval,
      s.hour,
      s.minute,
      _dateKey(s.anchorDate),
      s.weekdays.join(','),
      s.monthDays.join(','),
      s.yearMonth,
      s.yearDay,
      s.onceAt?.toIso8601String(),
    ].join('|');
  }

  Map<String, dynamic> toJson() {
    final s = normalized();
    return <String, dynamic>{
      'frequency': s.frequency.name,
      'interval': s.interval,
      'hour': s.hour,
      'minute': s.minute,
      if (s.anchorDate != null) 'anchorDate': _dateKey(s.anchorDate),
      'weekdays': s.weekdays,
      'monthDays': s.monthDays,
      if (s.yearMonth != null) 'yearMonth': s.yearMonth,
      if (s.yearDay != null) 'yearDay': s.yearDay,
      if (s.onceAt != null) 'onceAt': s.onceAt!.toIso8601String(),
    };
  }

  factory ScheduledTaskSchedule.fromJson(Map<String, dynamic> json) {
    final frequency = ScheduledTaskFrequency.values.firstWhere(
      (value) => value.name == json['frequency'],
      orElse: () => ScheduledTaskFrequency.daily,
    );
    return ScheduledTaskSchedule(
      frequency: frequency,
      interval: (json['interval'] as num?)?.toInt() ?? 1,
      hour: (json['hour'] as num?)?.toInt() ?? 8,
      minute: (json['minute'] as num?)?.toInt() ?? 0,
      anchorDate: _parseLocalDate(json['anchorDate']?.toString()),
      weekdays: (json['weekdays'] as List? ?? const <dynamic>[])
          .map((value) => (value as num).toInt())
          .toList(growable: false),
      monthDays: (json['monthDays'] as List? ?? const <dynamic>[])
          .map((value) => (value as num).toInt())
          .toList(growable: false),
      yearMonth: (json['yearMonth'] as num?)?.toInt(),
      yearDay: (json['yearDay'] as num?)?.toInt(),
      onceAt: DateTime.tryParse((json['onceAt'] ?? '').toString()),
    ).normalized();
  }

  static DateTime _dateOnly(DateTime value) =>
      DateTime(value.year, value.month, value.day);

  static bool _sameDate(DateTime a, DateTime b) =>
      a.year == b.year && a.month == b.month && a.day == b.day;

  /// Calendar-day arithmetic deliberately uses UTC date shells so daylight
  /// saving transitions cannot turn a local one-day step into 23 or 25 hours.
  static int _calendarDaysBetween(DateTime a, DateTime b) {
    final aUtc = DateTime.utc(a.year, a.month, a.day);
    final bUtc = DateTime.utc(b.year, b.month, b.day);
    return aUtc.difference(bUtc).inDays;
  }

  static String? _dateKey(DateTime? value) {
    if (value == null) return null;
    final y = value.year.toString().padLeft(4, '0');
    final m = value.month.toString().padLeft(2, '0');
    final d = value.day.toString().padLeft(2, '0');
    return '$y-$m-$d';
  }

  static DateTime? _parseLocalDate(String? value) {
    if (value == null || value.isEmpty) return null;
    final parts = value.split('-');
    if (parts.length != 3) return DateTime.tryParse(value);
    final y = int.tryParse(parts[0]);
    final m = int.tryParse(parts[1]);
    final d = int.tryParse(parts[2]);
    if (y == null || m == null || d == null) return null;
    return DateTime(y, m, d);
  }
}

class ScheduledTask {
  const ScheduledTask({
    required this.id,
    required this.assistantId,
    required this.name,
    required this.prompt,
    required this.schedule,
    required this.triggerId,
    required this.createdAt,
    required this.updatedAt,
    this.enabled = true,
    this.connected = false,
    this.completedAt,
    this.lastAttemptOccurrenceKey,
    this.logs = const <ScheduledTaskLog>[],
  });

  final String id;
  final String assistantId;
  final String name;
  final String prompt;
  final ScheduledTaskSchedule schedule;
  final String triggerId;
  final bool enabled;
  final bool connected;
  final DateTime? completedAt;
  final String? lastAttemptOccurrenceKey;
  final DateTime createdAt;
  final DateTime updatedAt;
  final List<ScheduledTaskLog> logs;

  bool get isCompleted =>
      completedAt != null ||
      (schedule.frequency == ScheduledTaskFrequency.once &&
          lastAttemptOccurrenceKey != null);

  ScheduledTask copyWith({
    String? assistantId,
    String? name,
    String? prompt,
    ScheduledTaskSchedule? schedule,
    String? triggerId,
    bool? enabled,
    bool? connected,
    DateTime? completedAt,
    bool clearCompletedAt = false,
    String? lastAttemptOccurrenceKey,
    bool clearLastAttemptOccurrenceKey = false,
    DateTime? updatedAt,
    List<ScheduledTaskLog>? logs,
  }) {
    return ScheduledTask(
      id: id,
      assistantId: assistantId ?? this.assistantId,
      name: name ?? this.name,
      prompt: prompt ?? this.prompt,
      schedule: schedule ?? this.schedule,
      triggerId: triggerId ?? this.triggerId,
      enabled: enabled ?? this.enabled,
      connected: connected ?? this.connected,
      completedAt: clearCompletedAt ? null : (completedAt ?? this.completedAt),
      lastAttemptOccurrenceKey: clearLastAttemptOccurrenceKey
          ? null
          : (lastAttemptOccurrenceKey ?? this.lastAttemptOccurrenceKey),
      createdAt: createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
      logs: logs ?? this.logs,
    );
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
    'id': id,
    'assistantId': assistantId,
    'name': name,
    'prompt': prompt,
    'schedule': schedule.toJson(),
    'triggerId': triggerId,
    'enabled': enabled,
    'connected': connected,
    if (completedAt != null) 'completedAt': completedAt!.toIso8601String(),
    if (lastAttemptOccurrenceKey != null)
      'lastAttemptOccurrenceKey': lastAttemptOccurrenceKey,
    'createdAt': createdAt.toIso8601String(),
    'updatedAt': updatedAt.toIso8601String(),
    'logs': logs.map((log) => log.toJson()).toList(growable: false),
  };

  factory ScheduledTask.fromJson(Map<String, dynamic> json) {
    final now = DateTime.now();
    return ScheduledTask(
      id: (json['id'] ?? '').toString(),
      assistantId: (json['assistantId'] ?? '').toString(),
      name: (json['name'] ?? '').toString(),
      prompt: (json['prompt'] ?? '').toString(),
      schedule: ScheduledTaskSchedule.fromJson(
        (json['schedule'] as Map? ?? const <String, dynamic>{})
            .cast<String, dynamic>(),
      ),
      triggerId: (json['triggerId'] ?? '').toString(),
      enabled: json['enabled'] != false,
      connected: json['connected'] == true,
      completedAt: DateTime.tryParse((json['completedAt'] ?? '').toString()),
      lastAttemptOccurrenceKey: json['lastAttemptOccurrenceKey']?.toString(),
      createdAt: DateTime.tryParse((json['createdAt'] ?? '').toString()) ?? now,
      updatedAt: DateTime.tryParse((json['updatedAt'] ?? '').toString()) ?? now,
      logs: (json['logs'] as List? ?? const <dynamic>[])
          .whereType<Map>()
          .map((raw) => ScheduledTaskLog.fromJson(raw.cast<String, dynamic>()))
          .toList(growable: false),
    );
  }
}
