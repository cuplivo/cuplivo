import 'dart:async';

import 'package:flutter/foundation.dart';

import '../database/business_preferences.dart';
import '../models/chat_owner.dart';
import 'assistant_provider.dart';
import 'group_chat_provider.dart';

/// The sidebar's single ordered list of chat owners: assistants and group chats
/// together, in one drag order.
///
/// The order is stored as a plain string list (`assistant:<id>` /
/// `group:<id>`), so it rides the ordinary preference channel — backup, restore
/// and LAN sync — without a new table. Membership is not stored: the sources are
/// the authority for *what exists*, and this provider only remembers *where*.
/// A key whose assistant or group is gone is dropped, and a newly created one is
/// appended, so the two can never drift into disagreeing.
class ChatOwnersProvider extends ChangeNotifier {
  ChatOwnersProvider({
    required this.assistants,
    required this.groups,
    required this.preferences,
  }) {
    assistants.addListener(_onSourcesChanged);
    groups.addListener(_onSourcesChanged);
    loaded = _load();
  }

  static const String preferenceKey = 'chat_owner_order_v1';

  final AssistantProvider assistants;
  final GroupChatProvider groups;
  final BusinessPreferences preferences;

  final List<String> _order = <String>[];
  List<ChatOwner> _owners = const <ChatOwner>[];

  late final Future<void> loaded;

  /// Every existing owner, in the user's order.
  List<ChatOwner> get owners => _owners;

  List<ChatOwner> get groupOwners =>
      _owners.where((owner) => owner.isGroup).toList(growable: false);

  /// The part of the list that sits under no tag header: untagged assistants
  /// plus every group, in order. Tag headers stay assistant-only, which is why
  /// groups land here rather than inventing a tag of their own.
  List<ChatOwner> ungroupedOwners(Set<String> taggedAssistantIds) => [
    for (final owner in _owners)
      if (owner.isGroup || !taggedAssistantIds.contains(owner.id)) owner,
  ];

  /// [items] in the user's drag order, with anything the order does not know
  /// yet left at its tail.
  ///
  /// A picker that lists one kind of owner reads this instead of its source
  /// list, so a drag in the sidebar or in settings is the same order in every
  /// surface that lists owners.
  List<T> inOwnerOrder<T>(Iterable<T> items, String Function(T item) keyOf) {
    final rank = <String, int>{
      for (var i = 0; i < _owners.length; i++) _owners[i].key: i,
    };
    final indexed = <({int rank, int index, T item})>[
      for (final (index, item) in items.indexed)
        (rank: rank[keyOf(item)] ?? 1 << 20, index: index, item: item),
    ];
    indexed.sort((a, b) {
      final byRank = a.rank.compareTo(b.rank);
      return byRank != 0 ? byRank : a.index.compareTo(b.index);
    });
    return [for (final entry in indexed) entry.item];
  }

  Future<void> _load() async {
    final stored = preferences.getStringList(preferenceKey);
    if (stored != null) {
      _order
        ..clear()
        ..addAll(stored);
    }
    await _reconcile(persist: stored == null);
  }

  void _onSourcesChanged() {
    unawaited(_reconcile());
  }

  /// Rebuilds [owners] from the stored order plus the live sources. Persists
  /// only when the resolved order actually changed.
  Future<void> _reconcile({bool persist = false}) async {
    final available = <String, ChatOwner>{
      for (final assistant in assistants.assistants)
        ChatOwner.assistant(assistant.id).key: ChatOwner.assistant(
          assistant.id,
        ),
      for (final group in groups.groups)
        ChatOwner.group(group.id).key: ChatOwner.group(group.id),
    };
    final next = <ChatOwner>[];
    final seen = <String>{};
    for (final key in _order) {
      final owner = available.remove(key);
      if (owner != null && seen.add(key)) next.add(owner);
    }
    for (final owner in available.values) {
      if (seen.add(owner.key)) next.add(owner);
    }
    final nextKeys = [for (final owner in next) owner.key];
    final changed = !listEquals(_order, nextKeys);
    _order
      ..clear()
      ..addAll(nextKeys);
    _owners = List<ChatOwner>.unmodifiable(next);
    if (persist || changed) {
      await preferences.setStringList(preferenceKey, List<String>.of(_order));
    }
    if (changed) notifyListeners();
  }

  Future<void> reorder(int oldIndex, int newIndex) async {
    if (oldIndex == newIndex) return;
    if (oldIndex < 0 || oldIndex >= _owners.length) return;
    final list = List<ChatOwner>.of(_owners);
    final moved = list.removeAt(oldIndex);
    list.insert(newIndex.clamp(0, list.length), moved);
    _owners = List<ChatOwner>.unmodifiable(list);
    _order
      ..clear()
      ..addAll([for (final owner in _owners) owner.key]);
    notifyListeners();
    await preferences.setStringList(preferenceKey, List<String>.of(_order));
  }

  /// Moves one owner inside a slice of the order — a tag section, which only
  /// ever holds assistants.
  ///
  /// The slice is filtered, not reordered as a block: every owner outside the
  /// keys keeps its absolute position, so a tag drag never reshuffles the list
  /// it cannot see.
  Future<void> reorderWithin({
    required Set<String> keys,
    required int oldIndex,
    required int newIndex,
  }) async {
    if (oldIndex == newIndex) return;
    final subset = [
      for (final owner in _owners)
        if (keys.contains(owner.key)) owner,
    ];
    if (oldIndex < 0 || oldIndex >= subset.length) return;
    if (newIndex < 0 || newIndex >= subset.length) return;
    final moved = subset.removeAt(oldIndex);
    subset.insert(newIndex, moved);
    var take = 0;
    final next = [
      for (final owner in _owners)
        if (keys.contains(owner.key)) subset[take++] else owner,
    ];
    _owners = List<ChatOwner>.unmodifiable(next);
    _order
      ..clear()
      ..addAll([for (final owner in _owners) owner.key]);
    notifyListeners();
    await preferences.setStringList(preferenceKey, List<String>.of(_order));
  }
}
