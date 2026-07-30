import 'package:flutter/foundation.dart';

import '../../database/chat_database_repository.dart';
import '../../models/director_session.dart';
import '../../models/group_chat.dart';
import '../../models/group_chat_member.dart';
import '../../models/group_chat_message.dart';
import '../../models/group_chat_settings.dart';
import 'chat_service.dart';

/// Multi-assistant group chat facade (mirrors [ChatService] caching style, simplified).
///
/// Depends on [ChatService] for the shared [ChatDatabaseRepository] / SQLite file.
class GroupChatService extends ChangeNotifier {
  GroupChatService({this.chatService});

  final ChatService? chatService;

  final Map<String, GroupChat> _groupsCache = {};
  final Map<String, List<GroupChatMember>> _membersCache = {};
  final Map<String, List<GroupChatMessage>> _messagesCache = {};
  final Map<String, DirectorSession> _directorByGroup = {};

  String? _currentGroupId;
  bool _loaded = false;

  bool get isLoaded => _loaded;
  String? get currentGroupId => _currentGroupId;

  ChatDatabaseRepository? get _repo {
    final cs = chatService;
    if (cs == null || !cs.initialized) return null;
    return cs.repo;
  }

  ChatDatabaseRepository get _readyRepo {
    final repo = _repo;
    if (repo == null) {
      throw StateError('GroupChatService: database not ready');
    }
    return repo;
  }

  Future<void> ensureLoaded() async {
    if (_loaded) return;
    final cs = chatService;
    if (cs == null) {
      throw StateError('GroupChatService: ChatService is required');
    }
    if (!cs.initialized) {
      await cs.init();
    }
    await _readyRepo.clearActiveGroupStreamingIds();
    await reload();
  }

  Future<void> reload() async {
    final repo = _readyRepo;
    final groups = await repo.getAllGroupChats(includeMemberIds: true);
    _groupsCache
      ..clear()
      ..addEntries(groups.map((g) => MapEntry(g.id, g)));
    _membersCache.clear();
    _messagesCache.clear();
    _directorByGroup.clear();
    _loaded = true;
    notifyListeners();
  }

  List<GroupChat> getAllGroups() {
    final list = _groupsCache.values.toList();
    list.sort((a, b) {
      if (a.isPinned != b.isPinned) return a.isPinned ? -1 : 1;
      return b.updatedAt.compareTo(a.updatedAt);
    });
    return list;
  }

  GroupChat? getGroup(String id) => _groupsCache[id];

  void setCurrentGroup(String? id) {
    if (_currentGroupId == id) return;
    _currentGroupId = id;
    notifyListeners();
  }

  /// Create a group with a fixed user member + at least two assistant members.
  Future<GroupChat> createGroup({
    required String title,
    required List<String> assistantIds,
    String? avatar,
    GroupChatSettings? settings,
  }) async {
    await ensureLoaded();
    final repo = _repo;
    if (repo == null) {
      throw StateError('GroupChatService: database not ready');
    }
    final uniqueAssistants = assistantIds.toSet().toList();
    final normalizedTitle = title.trim();
    if (normalizedTitle.isEmpty) {
      throw ArgumentError('Group chat title must not be empty');
    }
    if (uniqueAssistants.length < 2) {
      throw ArgumentError(
        'Group chat requires at least 2 distinct assistant members',
      );
    }

    final now = DateTime.now();
    final group = GroupChat(
      title: normalizedTitle,
      avatar: avatar,
      createdAt: now,
      updatedAt: now,
      settings: settings ?? GroupChatSettings.defaults,
    );

    final members = <GroupChatMember>[
      GroupChatMember(
        groupId: group.id,
        kind: GroupChatMember.kindUser,
        sortOrder: 0,
        createdAt: now,
      ),
      for (var i = 0; i < uniqueAssistants.length; i++)
        GroupChatMember(
          groupId: group.id,
          kind: GroupChatMember.kindAssistant,
          assistantId: uniqueAssistants[i],
          sortOrder: i + 1,
          createdAt: now,
        ),
    ];

    await repo.putGroupChat(group);
    await repo.putGroupMembers(group.id, members);

    final withIds = group.copyWith(
      memberIds: members.map((m) => m.id).toList(),
    );
    _groupsCache[group.id] = withIds;
    _membersCache[group.id] = List<GroupChatMember>.of(members);
    notifyListeners();
    return withIds;
  }

  Future<void> updateGroup(GroupChat group) async {
    await ensureLoaded();
    final repo = _readyRepo;
    final updated = group.copyWith(updatedAt: DateTime.now());
    await repo.putGroupChat(updated);
    _groupsCache[updated.id] = updated;
    notifyListeners();
  }

  Future<void> deleteGroup(String id) async {
    await ensureLoaded();
    final repo = _readyRepo;
    await repo.deleteGroupChat(id);
    _groupsCache.remove(id);
    _membersCache.remove(id);
    _messagesCache.remove(id);
    _directorByGroup.remove(id);
    if (_currentGroupId == id) _currentGroupId = null;
    notifyListeners();
  }

  Future<List<GroupChatMember>> getMembers(String groupId) async {
    await ensureLoaded();
    final cached = _membersCache[groupId];
    if (cached != null) return List.unmodifiable(cached);
    final repo = _readyRepo;
    // Repo returns growable:false; cache must stay growable for later mutate.
    final members = List<GroupChatMember>.of(
      await repo.getGroupMembers(groupId),
    );
    _membersCache[groupId] = members;
    return List.unmodifiable(members);
  }

  Future<void> setMembers(String groupId, List<GroupChatMember> members) async {
    await ensureLoaded();
    final repo = _readyRepo;

    final hasUser = members.any((m) => m.kind == GroupChatMember.kindUser);
    final assistantCount = members
        .where((m) => m.kind == GroupChatMember.kindAssistant && m.isEnabled)
        .length;
    if (!hasUser) {
      throw ArgumentError('Group must include a user member');
    }
    if (assistantCount < 2) {
      throw ArgumentError('Group must keep at least 2 enabled assistants');
    }

    await repo.putGroupMembers(groupId, members);
    _membersCache[groupId] = List<GroupChatMember>.of(members);
    final g = _groupsCache[groupId];
    if (g != null) {
      final updated = g.copyWith(
        memberIds: members.map((m) => m.id).toList(),
        updatedAt: DateTime.now(),
      );
      await repo.putGroupChat(updated);
      _groupsCache[groupId] = updated;
    }
    notifyListeners();
  }

  Future<List<GroupChatMessage>> getMessages(String groupId) async {
    await ensureLoaded();
    final cached = _messagesCache[groupId];
    if (cached != null) return List.unmodifiable(cached);
    final repo = _readyRepo;
    // Repo returns growable:false; always store a growable copy so
    // [addMessage]/[deleteMessage] can mutate without
    // "Cannot add to a fixed-length list".
    final messages = List<GroupChatMessage>.of(
      await repo.getGroupMessages(groupId),
    );
    _messagesCache[groupId] = messages;
    return List.unmodifiable(messages);
  }

  /// Force-reload messages from DB into cache.
  Future<List<GroupChatMessage>> reloadMessages(String groupId) async {
    await ensureLoaded();
    final repo = _readyRepo;
    final messages = List<GroupChatMessage>.of(
      await repo.getGroupMessages(groupId),
    );
    _messagesCache[groupId] = messages;
    notifyListeners();
    return List.unmodifiable(messages);
  }

  Future<GroupChatMessage> addMessage(GroupChatMessage message) async {
    await ensureLoaded();
    final repo = _repo;
    if (repo == null) {
      throw StateError('GroupChatService: database not ready');
    }
    var order = message.messageOrder;
    if (order == 0) {
      final count = await repo.getGroupMessageCount(message.groupId);
      // If first message and order is 0, keep 0; otherwise append.
      final existing = _messagesCache[message.groupId];
      if (existing != null && existing.isNotEmpty) {
        order = existing.last.messageOrder + 1;
      } else if (count > 0) {
        final loaded = await repo.getGroupMessages(message.groupId);
        order = loaded.isEmpty ? 0 : loaded.last.messageOrder + 1;
      }
    }
    final toWrite = message.copyWith(messageOrder: order);
    await repo.putGroupMessage(toWrite);

    // Always mutate a growable list (defensive vs fixed-length repo results).
    final list = List<GroupChatMessage>.of(
      _messagesCache[message.groupId] ?? const <GroupChatMessage>[],
    );
    final idx = list.indexWhere((m) => m.id == toWrite.id);
    if (idx >= 0) {
      list[idx] = toWrite;
    } else {
      list.add(toWrite);
      list.sort((a, b) => a.messageOrder.compareTo(b.messageOrder));
    }
    _messagesCache[message.groupId] = list;

    final g = _groupsCache[message.groupId];
    if (g != null) {
      final updated = g.copyWith(updatedAt: DateTime.now());
      await repo.putGroupChat(updated);
      _groupsCache[message.groupId] = updated;
    }
    notifyListeners();
    return toWrite;
  }

  Future<void> updateMessage(
    GroupChatMessage message, {
    bool notify = true,
  }) async {
    await ensureLoaded();
    final repo = _readyRepo;
    await repo.putGroupMessage(message);
    final cached = _messagesCache[message.groupId];
    if (cached != null) {
      final list = List<GroupChatMessage>.of(cached);
      final idx = list.indexWhere((m) => m.id == message.id);
      if (idx >= 0) {
        list[idx] = message;
        _messagesCache[message.groupId] = list;
      }
    }
    if (notify) notifyListeners();
  }

  List<Map<String, dynamic>> getToolEvents(String messageId) =>
      _readyRepo.getGroupToolEventsSync(messageId);

  Future<void> setToolEvents(
    String messageId,
    List<Map<String, dynamic>> events,
  ) async {
    await ensureLoaded();
    final repo = _repo;
    if (repo == null) {
      throw StateError('GroupChatService: database not ready');
    }
    await repo.setGroupToolEvents(messageId, events);
  }

  Future<void> upsertToolEvent(
    String messageId, {
    required String id,
    required String name,
    required Map<String, dynamic> arguments,
    String? content,
    Map<String, dynamic>? metadata,
  }) async {
    final events = List<Map<String, dynamic>>.of(getToolEvents(messageId));
    final index = events.indexWhere(
      (event) =>
          (id.isNotEmpty && event['id'] == id) ||
          (id.isEmpty && event['name'] == name),
    );
    final value = <String, dynamic>{
      'id': id,
      'name': name,
      'arguments': arguments,
      'content': content,
      if (metadata != null && metadata.isNotEmpty) 'metadata': metadata,
    };
    if (index < 0) {
      events.add(value);
    } else {
      events[index] = value;
    }
    await setToolEvents(messageId, events);
  }

  String? getGeminiThoughtSignature(String messageId) =>
      _readyRepo.getGroupGeminiThoughtSignatureSync(messageId);

  Future<void> setGeminiThoughtSignature(
    String messageId,
    String signature,
  ) async {
    await ensureLoaded();
    final repo = _repo;
    if (repo == null) {
      throw StateError('GroupChatService: database not ready');
    }
    await repo.setGroupGeminiThoughtSignature(messageId, signature);
  }

  Future<void> deleteMessage(String groupId, String messageId) async {
    await ensureLoaded();
    final repo = _readyRepo;
    await repo.deleteGroupMessage(messageId);
    final cached = _messagesCache[groupId];
    if (cached != null) {
      _messagesCache[groupId] = List<GroupChatMessage>.of(cached)
        ..removeWhere((m) => m.id == messageId);
    }
    // Reload order after compact.
    final messages = List<GroupChatMessage>.of(
      await repo.getGroupMessages(groupId),
    );
    _messagesCache[groupId] = messages;
    notifyListeners();
  }

  Future<DirectorSession?> getDirectorSession(String groupId) async {
    await ensureLoaded();
    final cached = _directorByGroup[groupId];
    if (cached != null) return cached;
    final repo = _readyRepo;
    final session = await repo.getDirectorSession(groupId);
    if (session != null) {
      // Defensive growable copies — UI/debug pages must not mutate repo shapes.
      _directorByGroup[groupId] = session.copyWith(
        messages: List<Map<String, dynamic>>.from(
          session.messages.map(Map<String, dynamic>.from),
        ),
        state: Map<String, dynamic>.from(session.state),
      );
    }
    return _directorByGroup[groupId];
  }

  /// Force-reload director session from SQLite (bypasses memory cache).
  Future<DirectorSession?> reloadDirectorSession(String groupId) async {
    await ensureLoaded();
    final repo = _readyRepo;
    final session = await repo.getDirectorSession(groupId);
    if (session == null) {
      _directorByGroup.remove(groupId);
      notifyListeners();
      return null;
    }
    final copied = session.copyWith(
      messages: List<Map<String, dynamic>>.from(
        session.messages.map(Map<String, dynamic>.from),
      ),
      state: Map<String, dynamic>.from(session.state),
    );
    _directorByGroup[groupId] = copied;
    debugPrint(
      '[GroupChat] reloadDirectorSession group=$groupId '
      'status=${copied.status} msgs=${copied.messages.length}',
    );
    notifyListeners();
    return copied;
  }

  Future<DirectorSession> putDirectorSession(DirectorSession session) async {
    await ensureLoaded();
    final repo = _repo;
    if (repo == null) {
      throw StateError('GroupChatService: database not ready');
    }
    final updated = session.copyWith(
      updatedAt: DateTime.now(),
      messages: List<Map<String, dynamic>>.from(
        session.messages.map(Map<String, dynamic>.from),
      ),
      state: Map<String, dynamic>.from(session.state),
    );
    await repo.putDirectorSession(updated);
    _directorByGroup[updated.groupId] = updated;
    final group = _groupsCache[updated.groupId];
    if (group != null) {
      final touched = group.copyWith(updatedAt: updated.updatedAt);
      await repo.putGroupChat(touched);
      _groupsCache[updated.groupId] = touched;
    }
    notifyListeners();
    return updated;
  }

  Future<DirectorSession> ensureDirectorSession(String groupId) async {
    final existing = await getDirectorSession(groupId);
    if (existing != null) return existing;
    final session = DirectorSession(groupId: groupId);
    return putDirectorSession(session);
  }
}
