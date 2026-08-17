import 'dart:async';
import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/assistant_memory.dart';

class MemoryStore {
  static const String _memoriesKey = 'assistant_memories_v1';

  /// Mutex that serializes every read-modify-write mutation
  /// (add/update/delete) so concurrent tool calls cannot observe a stale
  /// snapshot and assign duplicate IDs or drop each other's changes.
  ///
  /// The lock is reset to null after each release so waiters never chain onto
  /// a future that outlives the call site's event loop zone.
  ///
  /// NOT reentrant: a locked action must never invoke another locked method,
  /// or it will wait forever on its own uncompleted completer.
  static Completer<void>? _lock;

  static List<AssistantMemory>? _cache;

  static Future<T> _withLock<T>(Future<T> Function() action) async {
    while (_lock != null) {
      await _lock!.future;
    }
    final completer = Completer<void>();
    _lock = completer;
    try {
      return await action();
    } finally {
      _lock = null;
      completer.complete();
    }
  }

  static Future<List<AssistantMemory>> _loadAllInternal() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_memoriesKey);
    if (raw == null || raw.isEmpty) return <AssistantMemory>[];
    try {
      final arr = jsonDecode(raw) as List<dynamic>;
      return [
        for (final e in arr)
          if (e is Map<String, dynamic>)
            AssistantMemory.fromJson(e)
          else
            AssistantMemory.fromJson((e as Map).cast<String, dynamic>()),
      ];
    } catch (_) {
      return <AssistantMemory>[];
    }
  }

  static Future<List<AssistantMemory>> getAll() async {
    _cache ??= await _loadAllInternal();
    return List<AssistantMemory>.of(_cache!);
  }

  /// Replaces the whole memory list. Does NOT take the mutation lock.
  ///
  /// Callers outside the locked mutations (e.g. trash restore) must not run
  /// concurrently with add/update/delete or they can clobber newer changes.
  static Future<void> saveAll(List<AssistantMemory> list) async {
    _cache = List<AssistantMemory>.of(list);
    final prefs = await SharedPreferences.getInstance();
    final json = jsonEncode(list.map((e) => e.toJson()).toList());
    await prefs.setString(_memoriesKey, json);
  }

  static Future<void> _saveAll(List<AssistantMemory> list) async =>
      saveAll(list);

  static Future<List<AssistantMemory>> getForAssistant(
    String assistantId,
  ) async {
    final all = await getAll();
    return all.where((m) => m.assistantId == assistantId).toList();
  }

  static int _nextId(List<AssistantMemory> list) {
    int maxId = 0;
    for (final m in list) {
      if (m.id > maxId) maxId = m.id;
    }
    return maxId + 1;
  }

  static Future<AssistantMemory> add({
    required String assistantId,
    required String content,
  }) {
    return _withLock(() async {
      final all = await getAll();
      final id = _nextId(all);
      final mem = AssistantMemory(
        id: id,
        assistantId: assistantId,
        content: content,
      );
      all.add(mem);
      await _saveAll(all);
      return mem;
    });
  }

  static Future<AssistantMemory?> update({
    required int id,
    required String content,
  }) {
    return _withLock(() async {
      final all = await getAll();
      final idx = all.indexWhere((m) => m.id == id);
      if (idx == -1) return null;
      final updated = all[idx].copyWith(content: content);
      all[idx] = updated;
      await _saveAll(all);
      return updated;
    });
  }

  static Future<bool> delete({required int id}) {
    return _withLock(() async {
      final all = await getAll();
      final before = all.length;
      all.removeWhere((m) => m.id == id);
      final changed = all.length != before;
      if (changed) await _saveAll(all);
      return changed;
    });
  }

  static Future<void> deleteForAssistant(String assistantId) {
    return _withLock(() async {
      final all = await getAll();
      all.removeWhere((m) => m.assistantId == assistantId);
      await _saveAll(all);
    });
  }
}
