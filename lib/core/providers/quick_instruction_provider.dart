import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:uuid/uuid.dart';

import '../database/business_preferences.dart';
import '../models/quick_instruction.dart';
import '../services/chat/chat_service.dart';
import '../services/deleted_records_store.dart';
import '../services/quick_instruction_store.dart';
import 'assistant_provider.dart';

class QuickInstructionProvider with ChangeNotifier {
  QuickInstructionProvider({
    required BusinessPreferences preferences,
    this.chatService,
    this.assistantProvider,
  }) : _store = QuickInstructionStore.shared(preferences);

  final QuickInstructionStore _store;
  final ChatService? chatService;
  final AssistantProvider? assistantProvider;

  List<QuickInstruction> _items = const <QuickInstruction>[];
  Map<String, List<String>> _activeIdsByAssistant =
      const <String, List<String>>{};
  bool _initialized = false;

  List<QuickInstruction> get items =>
      List<QuickInstruction>.unmodifiable(_items);
  List<QuickInstruction> get systemItems =>
      _items.where((item) => item.isSystem).toList(growable: false);
  List<QuickInstruction> get inputBoxItems =>
      _items.where((item) => item.isInputBox).toList(growable: false);
  bool get initialized => _initialized;

  String _normGroup(String value) => value.trim();

  Future<void> initialize() async {
    if (_initialized) return;
    await loadAll();
    _initialized = true;
  }

  Future<void> loadAll() async {
    try {
      _store.invalidateCache();
      final names = <String, String>{};
      final assistants = assistantProvider;
      if (assistants != null) {
        try {
          await assistants.ensureLoaded();
          for (final assistant in assistants.assistants) {
            names[assistant.id] = assistant.name;
          }
        } catch (error, stackTrace) {
          debugPrint(
            'QuickInstructionProvider: assistant names unavailable; '
            'legacy IDs will be used: $error\n$stackTrace',
          );
        }
      }
      await _store.getAll();
      await _store.migrateLegacyQuickPhrases(assistantNames: names);
      _items = await _store.getAll();
      _activeIdsByAssistant = await _store.getActiveIdsByAssistant();
      notifyListeners();
    } catch (error, stackTrace) {
      debugPrint(
        'QuickInstructionProvider.loadAll failed: $error\n$stackTrace',
      );
      rethrow;
    }
  }

  Future<void> add(QuickInstruction item) async {
    await _store.add(item);
    await loadAll();
  }

  Future<void> addMany(List<QuickInstruction> items) async {
    if (items.isEmpty) return;
    await _store.addMany(items);
    await loadAll();
  }

  Future<void> update(QuickInstruction item) async {
    final previous = _items
        .where((candidate) => candidate.id == item.id)
        .firstOrNull;
    await _store.update(item);
    if (previous?.isPersistent == true && !item.isPersistent) {
      await chatService?.removeQuickInstructionFromAllConversations(item.id);
    }
    await loadAll();
  }

  Future<void> delete(String id) async {
    final item = _items.where((candidate) => candidate.id == id).firstOrNull;
    final deletedStore = chatService?.deletedRecordsStore;
    if (item != null && deletedStore != null) {
      try {
        await deletedStore.recordDeletion(
          id: id,
          type: DeletionEntityType.quickPhrase,
          recoveryJson: jsonEncode(item.toJson()),
          batchId: const Uuid().v4(),
          deletedAt: DateTime.now(),
        );
      } catch (error, stackTrace) {
        debugPrint(
          'QuickInstructionProvider.delete: failed to write trash: '
          '$error\n$stackTrace',
        );
      }
    }
    await _store.delete(id);
    await chatService?.removeQuickInstructionFromAllConversations(id);
    await loadAll();
  }

  Future<void> clear() async {
    await _store.clear();
    await chatService?.clearPersistentQuickInstructions();
    _items = const <QuickInstruction>[];
    _activeIdsByAssistant = const <String, List<String>>{};
    notifyListeners();
  }

  Future<void> reorder({required int oldIndex, required int newIndex}) async {
    if (oldIndex < 0 || oldIndex >= _items.length) return;
    if (newIndex < 0 || newIndex >= _items.length) return;
    final next = List<QuickInstruction>.from(_items);
    final item = next.removeAt(oldIndex);
    next.insert(newIndex, item);
    _items = next;
    notifyListeners();
    await _store.save(next);
  }

  Future<void> reorderWithinGroup({
    required String group,
    required int oldIndex,
    required int newIndex,
  }) async {
    final target = _normGroup(group);
    final indices = <int>[
      for (var index = 0; index < _items.length; index++)
        if (_normGroup(_items[index].group) == target) index,
    ];
    if (oldIndex < 0 || oldIndex >= indices.length) return;
    if (newIndex < 0 || newIndex > indices.length) return;

    final next = List<QuickInstruction>.from(_items);
    final item = next.removeAt(indices[oldIndex]);
    final after = <int>[
      for (var index = 0; index < next.length; index++)
        if (_normGroup(next[index].group) == target) index,
    ];
    final insertAt = newIndex >= after.length
        ? (after.isEmpty ? next.length : after.last + 1)
        : after[newIndex];
    next.insert(insertAt, item);
    _items = next;
    notifyListeners();
    await _store.save(next);
  }

  List<String> get activeIds => activeIdsFor(null);

  List<String> activeIdsFor(String? assistantId) {
    final key = QuickInstructionStore.assistantKey(assistantId);
    final ids =
        _activeIdsByAssistant[key] ??
        _activeIdsByAssistant[QuickInstructionStore.defaultAssistantKey] ??
        const <String>[];
    final systemIds = systemItems.map((item) => item.id).toSet();
    return ids.where(systemIds.contains).toList(growable: false);
  }

  bool isActive(String id, {String? assistantId}) =>
      activeIdsFor(assistantId).contains(id);

  List<QuickInstruction> get actives => activesFor(null);

  List<QuickInstruction> activesFor(String? assistantId) {
    final ids = activeIdsFor(assistantId).toSet();
    return _items
        .where((item) => item.isSystem && ids.contains(item.id))
        .toList(growable: false);
  }

  String? get activeId => activeIdFor(null);

  String? activeIdFor(String? assistantId) {
    final ids = activeIdsFor(assistantId);
    return ids.isEmpty ? null : ids.first;
  }

  QuickInstruction? get active => activeFor(null);

  QuickInstruction? activeFor(String? assistantId) {
    final values = activesFor(assistantId);
    return values.isEmpty ? null : values.first;
  }

  Future<void> setActiveId(String? id, {String? assistantId}) async {
    await setActiveIds(
      id == null || id.isEmpty ? const <String>[] : <String>[id],
      assistantId: assistantId,
    );
  }

  Future<void> setActiveIds(List<String> ids, {String? assistantId}) async {
    final systemIds = systemItems.map((item) => item.id).toSet();
    final clean = ids.where(systemIds.contains).toSet().toList(growable: false);
    final key = QuickInstructionStore.assistantKey(assistantId);
    _activeIdsByAssistant = <String, List<String>>{
      ..._activeIdsByAssistant,
      key: clean,
    };
    notifyListeners();
    await _store.setActiveIds(clean, assistantId: assistantId);
  }

  Future<void> toggleActiveId(String id, {String? assistantId}) async {
    final ids = activeIdsFor(assistantId).toSet();
    ids.contains(id) ? ids.remove(id) : ids.add(id);
    await setActiveIds(ids.toList(growable: false), assistantId: assistantId);
  }

  Future<void> setActive(QuickInstruction? item, {String? assistantId}) {
    return setActiveId(item?.id, assistantId: assistantId);
  }

  List<String> persistentIdsFor(String? conversationId) {
    if (conversationId == null) return const <String>[];
    final conversation = chatService?.getCompleteConversation(conversationId);
    if (conversation == null) return const <String>[];
    final valid = _items
        .where((item) => item.isPersistent)
        .map((item) => item.id)
        .toSet();
    return conversation.persistentQuickInstructionIds
        .where(valid.contains)
        .toList(growable: false);
  }

  bool isPersistentActive(String id, {required String? conversationId}) {
    return persistentIdsFor(conversationId).contains(id);
  }

  Future<void> togglePersistent(
    String id, {
    required String conversationId,
  }) async {
    final ids = persistentIdsFor(conversationId).toSet();
    ids.contains(id) ? ids.remove(id) : ids.add(id);
    await chatService?.setPersistentQuickInstructionIds(
      conversationId,
      ids.toList(growable: false),
    );
    notifyListeners();
  }

  Future<int> activeAssistantReferenceCount(String id) {
    final assistants = assistantProvider?.assistants;
    if (assistants != null) {
      return Future<int>.value(
        assistants
            .where((assistant) => activeIdsFor(assistant.id).contains(id))
            .length,
      );
    }
    return _store.activeAssistantReferenceCount(id);
  }

  Future<int> activeConversationReferenceCount(String id) async {
    return await chatService?.countConversationsUsingQuickInstruction(id) ?? 0;
  }
}
