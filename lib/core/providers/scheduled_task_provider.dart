import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

import '../models/scheduled_task.dart';

class ScheduledTaskProvider extends ChangeNotifier {
  static const String _tasksKey = 'ios_scheduled_tasks_v1';
  static const String _allowAiKey = 'ios_scheduled_tasks_allow_ai_v1';
  static const String _approvalKey = 'ios_scheduled_tasks_ai_approval_v1';
  static const int _maxLogsPerTask = 100;
  static const Uuid _uuid = Uuid();

  final List<ScheduledTask> _tasks = <ScheduledTask>[];
  bool _loaded = false;
  Future<void>? _loadFuture;
  bool _allowAiOperations = false;
  bool _aiRequiresApproval = true;

  bool get isLoaded => _loaded;
  bool get allowAiOperations => _allowAiOperations;
  bool get aiRequiresApproval => _aiRequiresApproval;

  List<ScheduledTask> get tasks {
    final copy = List<ScheduledTask>.of(_tasks);
    copy.sort((a, b) => b.createdAt.compareTo(a.createdAt));
    return List.unmodifiable(copy);
  }

  Future<void> init() => ensureLoaded();

  Future<void> ensureLoaded() {
    if (_loaded) return Future<void>.value();
    return _loadFuture ??= _load();
  }

  Future<void> _load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      _allowAiOperations = prefs.getBool(_allowAiKey) ?? false;
      _aiRequiresApproval = prefs.getBool(_approvalKey) ?? true;
      final raw = prefs.getString(_tasksKey);
      if (raw != null && raw.isNotEmpty) {
        final decoded = jsonDecode(raw);
        if (decoded is List) {
          _tasks
            ..clear()
            ..addAll(
              decoded
                  .whereType<Map>()
                  .map(
                    (entry) => ScheduledTask.fromJson(
                      entry.cast<String, dynamic>(),
                    ),
                  )
                  .where(
                    (task) =>
                        task.id.isNotEmpty &&
                        task.assistantId.isNotEmpty &&
                        task.triggerId.isNotEmpty,
                  ),
            );
        }
      }
    } catch (error) {
      debugPrint('[ScheduledTaskProvider] load failed: $error');
    } finally {
      _loaded = true;
      _loadFuture = null;
      notifyListeners();
    }
  }

  Future<void> setAllowAiOperations(bool value) async {
    await ensureLoaded();
    if (_allowAiOperations == value) return;
    _allowAiOperations = value;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_allowAiKey, value);
    notifyListeners();
  }

  Future<void> setAiRequiresApproval(bool value) async {
    await ensureLoaded();
    if (_aiRequiresApproval == value) return;
    _aiRequiresApproval = value;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_approvalKey, value);
    notifyListeners();
  }

  Future<ScheduledTask> createTask({
    required String assistantId,
    required String name,
    required String prompt,
    required ScheduledTaskSchedule schedule,
    bool enabled = true,
  }) async {
    await ensureLoaded();
    final now = DateTime.now();
    final task = ScheduledTask(
      id: _uuid.v4(),
      assistantId: assistantId,
      name: name.trim(),
      prompt: prompt.trim(),
      schedule: schedule.normalized(),
      triggerId: _newTriggerId(),
      enabled: enabled,
      connected: false,
      createdAt: now,
      updatedAt: now,
    );
    _tasks.add(task);
    await _persist();
    notifyListeners();
    return task;
  }

  ScheduledTask? getById(String id) {
    for (final task in _tasks) {
      if (task.id == id) return task;
    }
    return null;
  }

  ScheduledTask? getByTriggerId(String triggerId) {
    for (final task in _tasks) {
      if (task.triggerId == triggerId) return task;
    }
    return null;
  }

  List<ScheduledTask> forAssistant(String assistantId) {
    return tasks
        .where((task) => task.assistantId == assistantId)
        .toList(growable: false);
  }

  Future<ScheduledTask?> updateTask({
    required String id,
    String? assistantId,
    String? name,
    String? prompt,
    ScheduledTaskSchedule? schedule,
    bool? enabled,
  }) async {
    await ensureLoaded();
    final index = _tasks.indexWhere((task) => task.id == id);
    if (index < 0) return null;
    final old = _tasks[index];
    final nextSchedule = (schedule ?? old.schedule).normalized();
    final scheduleChanged =
        nextSchedule.triggerSignature != old.schedule.triggerSignature;
    final next = old.copyWith(
      assistantId: assistantId,
      name: name?.trim(),
      prompt: prompt?.trim(),
      schedule: nextSchedule,
      enabled: enabled,
      triggerId: scheduleChanged ? _newTriggerId() : old.triggerId,
      connected: scheduleChanged ? false : old.connected,
      clearCompletedAt: scheduleChanged,
      clearLastAttemptOccurrenceKey: scheduleChanged,
      updatedAt: DateTime.now(),
    );
    _tasks[index] = next;
    await _persist();
    notifyListeners();
    return next;
  }

  Future<ScheduledTask?> markConnected(String id) async {
    await ensureLoaded();
    final index = _tasks.indexWhere((task) => task.id == id);
    if (index < 0) return null;
    final next = _tasks[index].copyWith(
      connected: true,
      updatedAt: DateTime.now(),
    );
    _tasks[index] = next;
    await _persist();
    notifyListeners();
    return next;
  }

  Future<ScheduledTask?> setEnabled(String id, bool value) async {
    return updateTask(id: id, enabled: value);
  }

  Future<bool> deleteTask(String id) async {
    await ensureLoaded();
    final before = _tasks.length;
    _tasks.removeWhere((task) => task.id == id);
    if (_tasks.length == before) return false;
    await _persist();
    notifyListeners();
    return true;
  }

  Future<bool> claimOccurrence({
    required String taskId,
    required String triggerId,
    required String occurrenceKey,
  }) async {
    await ensureLoaded();
    final index = _tasks.indexWhere((task) => task.id == taskId);
    if (index < 0) return false;
    final task = _tasks[index];
    if (task.triggerId != triggerId ||
        !task.enabled ||
        task.isCompleted ||
        task.lastAttemptOccurrenceKey == occurrenceKey) {
      return false;
    }
    _tasks[index] = task.copyWith(
      lastAttemptOccurrenceKey: occurrenceKey,
      updatedAt: DateTime.now(),
    );
    await _persist();
    notifyListeners();
    return true;
  }

  Future<void> recordLog(String taskId, ScheduledTaskLog log) async {
    await ensureLoaded();
    final index = _tasks.indexWhere((task) => task.id == taskId);
    if (index < 0) return;
    final logs = <ScheduledTaskLog>[log, ..._tasks[index].logs];
    if (logs.length > _maxLogsPerTask) {
      logs.removeRange(_maxLogsPerTask, logs.length);
    }
    _tasks[index] = _tasks[index].copyWith(
      logs: logs,
      updatedAt: DateTime.now(),
    );
    await _persist();
    notifyListeners();
  }

  Future<void> markOnceCompleted(String taskId, DateTime completedAt) async {
    await ensureLoaded();
    final index = _tasks.indexWhere((task) => task.id == taskId);
    if (index < 0) return;
    _tasks[index] = _tasks[index].copyWith(
      completedAt: completedAt,
      updatedAt: DateTime.now(),
    );
    await _persist();
    notifyListeners();
  }

  Future<void> _persist() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      _tasksKey,
      jsonEncode(_tasks.map((task) => task.toJson()).toList(growable: false)),
    );
  }

  static String _newTriggerId() => _uuid.v4().replaceAll('-', '');
}
