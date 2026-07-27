import 'package:flutter/foundation.dart';

import '../../database/chat_database_repository.dart';
import '../../models/director_session.dart';
import '../../models/group_chat.dart';
import '../../models/group_chat_member.dart';
import '../../models/group_chat_message.dart';
import '../../models/group_chat_settings.dart';
import '../group_chat/group_chat_orchestrator.dart';
import 'chat_service.dart';

/// Multi-assistant group chat facade (mirrors [ChatService] caching style, simplified).
///
/// Depends on [ChatService] for the shared [ChatDatabaseRepository] / SQLite file.
/// Optional [orchestrator] handles director tool loop + member speaking (Phase 2).
class GroupChatService extends ChangeNotifier {
  GroupChatService({this.chatService, this._orchestrator});

  final ChatService? chatService;
  GroupChatOrchestrator? _orchestrator;

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

  Future<void> ensureLoaded() async {
    if (_loaded) return;
    final cs = chatService;
    if (cs != null && !cs.initialized) {
      await cs.init();
    }
    await reload();
  }

  Future<void> reload() async {
    final repo = _repo;
    if (repo == null) {
      _loaded = false;
      notifyListeners();
      return;
    }
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
    if (uniqueAssistants.length < 2) {
      throw ArgumentError(
        'Group chat requires at least 2 distinct assistant members',
      );
    }

    final now = DateTime.now();
    final group = GroupChat(
      title: title.trim().isEmpty ? 'Group Chat' : title.trim(),
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
    _membersCache[group.id] = members;
    notifyListeners();
    return withIds;
  }

  Future<void> updateGroup(GroupChat group) async {
    await ensureLoaded();
    final repo = _repo;
    if (repo == null) return;
    final updated = group.copyWith(updatedAt: DateTime.now());
    await repo.putGroupChat(updated);
    _groupsCache[updated.id] = updated;
    notifyListeners();
  }

  Future<void> deleteGroup(String id) async {
    await ensureLoaded();
    final repo = _repo;
    if (repo == null) return;
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
    final repo = _repo;
    if (repo == null) return const [];
    final members = await repo.getGroupMembers(groupId);
    _membersCache[groupId] = members;
    return List.unmodifiable(members);
  }

  Future<void> setMembers(String groupId, List<GroupChatMember> members) async {
    await ensureLoaded();
    final repo = _repo;
    if (repo == null) return;

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
    final repo = _repo;
    if (repo == null) return const [];
    final messages = await repo.getGroupMessages(groupId);
    _messagesCache[groupId] = messages;
    return List.unmodifiable(messages);
  }

  /// Force-reload messages from DB into cache.
  Future<List<GroupChatMessage>> reloadMessages(String groupId) async {
    await ensureLoaded();
    final repo = _repo;
    if (repo == null) return const [];
    final messages = await repo.getGroupMessages(groupId);
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

    final list = _messagesCache.putIfAbsent(message.groupId, () => []);
    final idx = list.indexWhere((m) => m.id == toWrite.id);
    if (idx >= 0) {
      list[idx] = toWrite;
    } else {
      list.add(toWrite);
      list.sort((a, b) => a.messageOrder.compareTo(b.messageOrder));
    }

    final g = _groupsCache[message.groupId];
    if (g != null) {
      final updated = g.copyWith(updatedAt: DateTime.now());
      await repo.putGroupChat(updated);
      _groupsCache[message.groupId] = updated;
    }
    notifyListeners();
    return toWrite;
  }

  Future<void> updateMessage(GroupChatMessage message) async {
    await ensureLoaded();
    final repo = _repo;
    if (repo == null) return;
    await repo.putGroupMessage(message);
    final list = _messagesCache[message.groupId];
    if (list != null) {
      final idx = list.indexWhere((m) => m.id == message.id);
      if (idx >= 0) list[idx] = message;
    }
    notifyListeners();
  }

  Future<void> deleteMessage(String groupId, String messageId) async {
    await ensureLoaded();
    final repo = _repo;
    if (repo == null) return;
    await repo.deleteGroupMessage(messageId);
    _messagesCache[groupId]?.removeWhere((m) => m.id == messageId);
    // Reload order after compact.
    final messages = await repo.getGroupMessages(groupId);
    _messagesCache[groupId] = messages;
    notifyListeners();
  }

  Future<DirectorSession?> getDirectorSession(String groupId) async {
    await ensureLoaded();
    final cached = _directorByGroup[groupId];
    if (cached != null) return cached;
    final repo = _repo;
    if (repo == null) return null;
    final session = await repo.getDirectorSession(groupId);
    if (session != null) _directorByGroup[groupId] = session;
    return session;
  }

  Future<DirectorSession> putDirectorSession(DirectorSession session) async {
    await ensureLoaded();
    final repo = _repo;
    if (repo == null) {
      throw StateError('GroupChatService: database not ready');
    }
    final updated = session.copyWith(updatedAt: DateTime.now());
    await repo.putDirectorSession(updated);
    _directorByGroup[updated.groupId] = updated;
    notifyListeners();
    return updated;
  }

  Future<DirectorSession> ensureDirectorSession(String groupId) async {
    final existing = await getDirectorSession(groupId);
    if (existing != null) return existing;
    final session = DirectorSession(groupId: groupId);
    return putDirectorSession(session);
  }

  /// Attach / replace the Phase-2 orchestrator (typically from app bootstrap).
  void attachOrchestrator(GroupChatOrchestrator orchestrator) {
    _orchestrator = orchestrator;
  }

  GroupChatOrchestrator? get orchestrator => _orchestrator;

  bool isGroupGenerating(String groupId) =>
      _orchestrator?.isRunning(groupId) ?? false;

  /// Cancel in-flight director / member streams for [groupId].
  Future<void> cancelGeneration(String groupId) async {
    await _orchestrator?.cancel(groupId);
  }

  /// Send a user message and run the director → member loop.
  ///
  /// Requires [attachOrchestrator] first. Throws [StateError] if missing.
  Future<GroupChatTurnResult> sendUserMessage({
    required String groupId,
    required String content,
  }) async {
    final orch = _orchestrator;
    if (orch == null) {
      throw StateError(
        'GroupChatService: orchestrator not attached (Phase 2 wiring)',
      );
    }
    return orch.sendUserMessage(groupId: groupId, content: content);
  }
}
