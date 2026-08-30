import 'package:flutter/foundation.dart';
import 'dart:convert';
import 'package:uuid/uuid.dart';

import '../database/business_preferences.dart';
import '../models/world_book.dart';
import '../services/world_book_store.dart';
import '../services/chat/chat_service.dart';
import '../services/deleted_records_store.dart';

class WorldBookProvider with ChangeNotifier {
  WorldBookProvider({
    required BusinessPreferences preferences,
    this.chatService,
  }) : _store = WorldBookStore.shared(preferences);

  final WorldBookStore _store;
  final ChatService? chatService;

  List<WorldBook> _books = const <WorldBook>[];
  bool _initialized = false;
  Map<String, List<String>> _activeIdsByAssistant =
      const <String, List<String>>{};
  Map<String, bool> _collapsedBooks = const <String, bool>{};
  Map<String, bool> _collapsedGroups = const <String, bool>{};

  List<WorldBook> get books => List<WorldBook>.unmodifiable(_books);

  WorldBook? getById(String id) {
    try {
      return _books.firstWhere((e) => e.id == id);
    } catch (_) {
      return null;
    }
  }

  List<String> activeBookIdsFor(String? assistantId) {
    final key = WorldBookStore.assistantKey(assistantId);
    if (_activeIdsByAssistant.containsKey(key)) {
      return List<String>.unmodifiable(_activeIdsByAssistant[key]!);
    }
    final fallback =
        _activeIdsByAssistant[WorldBookStore.assistantKey(null)] ??
        const <String>[];
    return List<String>.unmodifiable(fallback);
  }

  bool isBookActive(String id, {String? assistantId}) =>
      activeBookIdsFor(assistantId).contains(id);

  bool isBookCollapsed(String id) => _collapsedBooks[id] ?? false;

  bool isGroupCollapsed(String groupName) =>
      _collapsedGroups[WorldBookStore.groupCollapseKey(groupName)] ?? false;

  Future<void> initialize() async {
    if (_initialized) return;
    await loadAll();
    _initialized = true;
  }

  Future<void> loadAll() async {
    try {
      _books = await _store.getAll();
      _activeIdsByAssistant = await _store.getActiveIdsByAssistant();
      final collapsed = await _store.getCollapsedBooksMap();
      final knownIds = _books.map((e) => e.id).toSet();
      final cleanedCollapsed = <String, bool>{
        for (final entry in collapsed.entries)
          if (knownIds.contains(entry.key)) entry.key: entry.value,
      };
      _collapsedBooks = cleanedCollapsed;

      if (cleanedCollapsed.length != collapsed.length) {
        await _store.setCollapsedMap(cleanedCollapsed);
      }

      final collapsedGroups = await _store.getCollapsedGroupsMap();
      final knownGroupKeys = _books
          .map((e) => WorldBookStore.groupCollapseKey(e.group))
          .toSet();
      final cleanedGroups = <String, bool>{
        for (final entry in collapsedGroups.entries)
          if (knownGroupKeys.contains(entry.key)) entry.key: entry.value,
      };
      _collapsedGroups = cleanedGroups;

      if (cleanedGroups.length != collapsedGroups.length) {
        await _store.setCollapsedGroupsMap(cleanedGroups);
      }

      notifyListeners();
    } catch (e) {
      debugPrint('Failed to load world books: $e');
      _books = const <WorldBook>[];
      _activeIdsByAssistant = const <String, List<String>>{};
      _collapsedBooks = const <String, bool>{};
      _collapsedGroups = const <String, bool>{};
      notifyListeners();
    }
  }

  Future<void> addBook(WorldBook book) async {
    await _store.add(book);
    await loadAll();
  }

  Future<void> updateBook(WorldBook book) async {
    if (!book.enabled) {
      try {
        final map = await _store.getActiveIdsByAssistant();
        final next = <String, List<String>>{};
        bool changed = false;
        for (final entry in map.entries) {
          final filtered = entry.value
              .where((e) => e != book.id)
              .toList(growable: false);
          if (filtered.length != entry.value.length) changed = true;
          next[entry.key] = filtered;
        }
        if (changed) {
          await _store.setActiveIdsMap(next);
        }
      } catch (_) {}
    }
    await _store.update(book);
    await loadAll();
  }

  Future<void> deleteBook(String id) async {
    // Write trash bundle before deleting.
    final store = chatService?.deletedRecordsStore;
    if (store != null) {
      final book = _books.where((b) => b.id == id).firstOrNull;
      if (book != null) {
        try {
          await store.recordDeletion(
            id: id,
            type: DeletionEntityType.worldBook,
            recoveryJson: jsonEncode(book.toJson()),
            batchId: const Uuid().v4(),
            deletedAt: DateTime.now(),
          );
        } catch (e) {
          debugPrint('WorldBookProvider.deleteBook: failed to write trash: $e');
        }
      }
    }
    await _store.delete(id);
    await loadAll();
  }

  Future<void> clear() async {
    await _store.clear();
    _books = const <WorldBook>[];
    _activeIdsByAssistant = const <String, List<String>>{};
    _collapsedBooks = const <String, bool>{};
    _collapsedGroups = const <String, bool>{};
    notifyListeners();
  }

  Future<void> reorderBooks({
    required int oldIndex,
    required int newIndex,
  }) async {
    if (_books.isEmpty) return;
    if (oldIndex < 0 || oldIndex >= _books.length) return;
    if (newIndex < 0 || newIndex >= _books.length) return;
    final list = List<WorldBook>.from(_books);
    final item = list.removeAt(oldIndex);
    list.insert(newIndex, item);
    _books = list;
    notifyListeners();
    await _store.save(_books);
  }

  Future<void> reorderEntries({
    required String bookId,
    required int oldIndex,
    required int newIndex,
  }) async {
    final bookIndex = _books.indexWhere((e) => e.id == bookId);
    if (bookIndex == -1) return;
    final book = _books[bookIndex];
    final entries = List<WorldBookEntry>.from(book.entries);
    if (entries.isEmpty) return;
    if (oldIndex < 0 || oldIndex >= entries.length) return;
    if (newIndex < 0 || newIndex >= entries.length) return;
    final item = entries.removeAt(oldIndex);
    entries.insert(newIndex, item);
    final nextBook = book.copyWith(entries: entries);
    final nextBooks = List<WorldBook>.from(_books);
    nextBooks[bookIndex] = nextBook;
    _books = nextBooks;
    notifyListeners();
    await _store.save(_books);
  }

  Future<void> setBookCollapsed(String id, bool collapsed) async {
    final key = id.trim();
    if (key.isEmpty) return;

    final next = Map<String, bool>.from(_collapsedBooks);
    next[key] = collapsed;
    _collapsedBooks = next;
    notifyListeners();
    await _store.setCollapsed(key, collapsed);
  }

  Future<void> toggleBookCollapsed(String id) async {
    await setBookCollapsed(id, !isBookCollapsed(id));
  }

  Future<void> setGroupCollapsed(String groupName, bool collapsed) async {
    final key = WorldBookStore.groupCollapseKey(groupName);

    final next = Map<String, bool>.from(_collapsedGroups);
    next[key] = collapsed;
    _collapsedGroups = next;
    notifyListeners();
    await _store.setCollapsedGroup(key, collapsed);
  }

  Future<void> toggleGroupCollapsed(String groupName) async {
    await setGroupCollapsed(groupName, !isGroupCollapsed(groupName));
  }

  Future<void> setActiveBookIds(List<String> ids, {String? assistantId}) async {
    final key = WorldBookStore.assistantKey(assistantId);
    final nextMap = Map<String, List<String>>.from(_activeIdsByAssistant);
    nextMap[key] = ids.toSet().toList(growable: false);
    _activeIdsByAssistant = nextMap;
    notifyListeners();
    await _store.setActiveIds(ids, assistantId: assistantId);
  }

  Future<void> toggleActiveBookId(String id, {String? assistantId}) async {
    final set = activeBookIdsFor(assistantId).toSet();
    if (set.contains(id)) {
      set.remove(id);
    } else {
      final book = getById(id);
      if (book == null) return;
      if (!book.enabled) return;
      set.add(id);
    }
    await setActiveBookIds(
      set.toList(growable: false),
      assistantId: assistantId,
    );
  }
}
