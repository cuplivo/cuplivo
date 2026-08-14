import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:uuid/uuid.dart';

import '../models/conversation.dart';
import '../models/group_chat.dart';
import '../models/group_chat_member.dart';
import '../models/group_chat_director_log.dart';
import '../models/assistant_detail_injection.dart';
import '../services/chat/chat_service.dart';
import '../services/deleted_records_store.dart';

/// Soft / hard caps for assistant members (excluding the user).
const int groupChatMemberSoftCap = 12;
const int groupChatMemberHardCap = 20;

class GroupChatProvider extends ChangeNotifier {
  /// Runtime metadata is diagnostic only; keep enough recent entries for a
  /// long-running process without allowing repeated retries to grow forever.
  static const int maxRuntimeDirectorLogsPerGroup = 200;

  GroupChatProvider({required this.chatService});

  final ChatService chatService;
  ChatService get _chatService => chatService;
  final List<GroupChat> _groups = [];
  final Map<String, List<GroupChatMember>> _membersByGroup = {};
  final Map<String, List<GroupChatDirectorRuntimeLog>> _runtimeDirectorLogs =
      {};
  bool _loaded = false;

  bool get loaded => _loaded;
  List<GroupChat> get groups => List.unmodifiable(_groups);

  Future<void> load() async {
    if (!_chatService.initialized) {
      await _chatService.init();
    }
    final list = await _chatService.repo.getAllGroupChats();
    _groups
      ..clear()
      ..addAll(list);
    _membersByGroup.clear();
    _runtimeDirectorLogs.clear();
    for (final g in list) {
      _membersByGroup[g.id] = await _chatService.repo.getGroupMembers(g.id);
    }
    _loaded = true;
    notifyListeners();
  }

  GroupChat? getById(String id) {
    for (final g in _groups) {
      if (g.id == id) return g;
    }
    return null;
  }

  List<GroupChatMember> membersOf(String groupChatId) {
    return List.unmodifiable(_membersByGroup[groupChatId] ?? const []);
  }

  List<String> assistantIdsOf(String groupChatId) {
    return membersOf(groupChatId)
        .where((m) => !m.isUser && m.assistantId != null)
        .map((m) => m.assistantId!)
        .toList(growable: false);
  }

  List<GroupChatDirectorRuntimeLog> directorRuntimeLogs(String groupChatId) {
    return List.unmodifiable(_runtimeDirectorLogs[groupChatId] ?? const []);
  }

  void recordDirectorRuntimeLog(
    String groupChatId,
    GroupChatDirectorRuntimeLog log,
  ) {
    _runtimeDirectorLogs
        .putIfAbsent(groupChatId, () => <GroupChatDirectorRuntimeLog>[])
        .add(log);
    final logs = _runtimeDirectorLogs[groupChatId]!;
    if (logs.length > maxRuntimeDirectorLogsPerGroup) {
      logs.removeRange(0, logs.length - maxRuntimeDirectorLogsPerGroup);
    }
    notifyListeners();
  }

  /// Latest public message preview for list subtitle.
  String? latestMessagePreview(String groupChatId) {
    final g = getById(groupChatId);
    if (g == null) return null;
    final msgs = _chatService.getMessages(g.conversationId);
    if (msgs.isEmpty) return null;
    final last = msgs.last;
    final t = last.content.trim();
    if (t.isEmpty) return null;
    return t.length > 80 ? '${t.substring(0, 80)}…' : t;
  }

  Future<GroupChat> createGroup({required String name}) async {
    // Callers must pass a non-empty, localized name.
    final trimmed = name.trim();
    final conversation = await _chatService.createConversation(
      title: trimmed,
      assistantId: null,
      conversationKind: Conversation.kindGroup,
      setAsCurrent: false,
    );

    final group = GroupChat(
      name: trimmed,
      conversationId: conversation.id,
      directorSystemPrompt: GroupChat.defaultDirectorSystemPrompt,
      maxAssistantMessagesPerRound: 3,
      assistantDetailInjectionMode:
          AssistantDetailInjectionMode.endOfEveryUserMessage,
      assistantDetailInjectionN: 5,
    );

    await _chatService.repo.putGroupChat(group);
    final members = [GroupChatMember.user(groupChatId: group.id, sortOrder: 0)];
    await _chatService.repo.putGroupMembers(group.id, members);

    _groups.insert(0, group);
    _membersByGroup[group.id] = members;
    notifyListeners();
    return group;
  }

  /// Duplicate a group chat (config only): a new group + a fresh empty
  /// conversation with the same members, director model and prompt settings.
  /// Per-round runtime state (pending cap message, assistant count) resets.
  Future<GroupChat> duplicateGroup(GroupChat source) async {
    final conversation = await _chatService.createConversation(
      title: source.name,
      assistantId: null,
      conversationKind: Conversation.kindGroup,
      setAsCurrent: false,
    );

    final copy = GroupChat(
      name: source.name,
      conversationId: conversation.id,
      directorModelProvider: source.directorModelProvider,
      directorModelId: source.directorModelId,
      directorSystemPrompt: source.directorSystemPrompt,
      maxAssistantMessagesPerRound: source.maxAssistantMessagesPerRound,
      assistantDetailInjectionMode: source.assistantDetailInjectionMode,
      assistantDetailInjectionN: source.assistantDetailInjectionN,
      injectGroupMembersIntoAssistantSystemPrompt:
          source.injectGroupMembersIntoAssistantSystemPrompt,
    );

    await _chatService.repo.putGroupChat(copy);
    final members = membersOf(source.id)
        .map(
          (m) => GroupChatMember(
            groupChatId: copy.id,
            memberKey: m.memberKey,
            assistantId: m.assistantId,
            sortOrder: m.sortOrder,
          ),
        )
        .toList();
    await _chatService.repo.putGroupMembers(copy.id, members);

    _groups.insert(0, copy);
    _membersByGroup[copy.id] = members;
    notifyListeners();
    return copy;
  }

  Future<void> updateGroup(GroupChat group) async {
    final updated = group.copyWith(updatedAt: DateTime.now());
    await _chatService.repo.putGroupChat(updated);
    final idx = _groups.indexWhere((g) => g.id == updated.id);
    if (idx >= 0) {
      _groups[idx] = updated;
    } else {
      _groups.add(updated);
    }
    // Keep conversation title in sync with group name. This is the ONLY
    // path that renames a group's conversation — always via
    // ChatService.setConversationTitle (repo + in-memory cache + updatedAt),
    // never a bare repo.putConversation.
    final conv = _chatService.getConversation(updated.conversationId);
    if (conv != null && conv.title != updated.name) {
      await _chatService.setConversationTitle(
        updated.conversationId,
        updated.name,
      );
    }
    notifyListeners();
  }

  Future<void> touchUpdatedAt(String groupChatId) async {
    final g = getById(groupChatId);
    if (g == null) return;
    await updateGroup(g.copyWith(updatedAt: DateTime.now()));
    // Group activity must also move the conversation's updatedAt so backup
    // inventory ordering reflects it.
    await _chatService.bumpConversationUpdatedAt(g.conversationId);
  }

  Future<void> setMembers(String groupChatId, List<String> assistantIds) async {
    final unique = assistantIds.toSet().toList();
    if (unique.length > groupChatMemberHardCap) {
      throw StateError('member_hard_cap');
    }
    final members = <GroupChatMember>[
      GroupChatMember.user(groupChatId: groupChatId, sortOrder: 0),
    ];
    for (var i = 0; i < unique.length; i++) {
      members.add(
        GroupChatMember.assistant(
          groupChatId: groupChatId,
          assistantId: unique[i],
          sortOrder: i + 1,
        ),
      );
    }
    await _chatService.repo.putGroupMembers(groupChatId, members);
    _membersByGroup[groupChatId] = members;
    notifyListeners();
  }

  Future<void> addAssistants(
    String groupChatId,
    List<String> assistantIds,
  ) async {
    final current = assistantIdsOf(groupChatId).toSet();
    for (final id in assistantIds) {
      current.add(id);
    }
    if (current.length > groupChatMemberHardCap) {
      throw StateError('member_hard_cap');
    }
    await setMembers(groupChatId, current.toList());
  }

  Future<void> removeAssistant(String groupChatId, String assistantId) async {
    final ids = assistantIdsOf(groupChatId)
      ..removeWhere((id) => id == assistantId);
    await setMembers(groupChatId, ids);
  }

  Future<void> removeAssistantFromAllGroups(String assistantId) async {
    await _chatService.repo.removeAssistantFromAllGroups(assistantId);
    for (final entry in _membersByGroup.entries.toList()) {
      final next = entry.value
          .where((m) => m.assistantId != assistantId)
          .toList();
      if (next.length != entry.value.length) {
        _membersByGroup[entry.key] = next;
      }
    }
    notifyListeners();
  }

  Future<void> persistGroupState(GroupChat group) async {
    await _chatService.repo.putGroupChat(group);
    final idx = _groups.indexWhere((g) => g.id == group.id);
    if (idx >= 0) _groups[idx] = group;
    notifyListeners();
  }

  /// Full delete with trash packaging.
  ///
  /// Trash records: the group bundle (group + members) and the conversation
  /// are TWO independent trash entries. Restore order matters
  /// — the group row has a FK to the conversation, so the conversation must be
  /// restored first; restoring either side alone leaves an orphan.
  Future<void> deleteGroup(String groupChatId) async {
    final group = getById(groupChatId);
    if (group == null) return;

    final members = membersOf(groupChatId);
    final store = _chatService.deletedRecordsStore;
    final batchId = const Uuid().v4();
    final deletedAt = DateTime.now();

    if (store != null) {
      final recovery = jsonEncode({
        'groupChat': group.toJson(),
        'members': members.map((m) => m.toJson()).toList(),
        'conversationId': group.conversationId,
      });
      await store.recordDeletion(
        id: groupChatId,
        type: DeletionEntityType.groupChat,
        recoveryJson: recovery,
        batchId: batchId,
        deletedAt: deletedAt,
      );
    }

    // Delete group row first (cascades members); then conversation
    // with allowGroup so trash for conversation may also run.
    await _chatService.repo.deleteGroupChat(groupChatId);
    try {
      await _chatService.deleteConversation(
        group.conversationId,
        allowGroup: true,
      );
    } catch (e) {
      debugPrint('[GroupChatProvider] delete conversation: $e');
      // Conversation may already be cascade-deleted if FK fired; ensure cache.
      await _chatService.repo.deleteConversation(group.conversationId);
    }

    _groups.removeWhere((g) => g.id == groupChatId);
    _membersByGroup.remove(groupChatId);
    _runtimeDirectorLogs.remove(groupChatId);
    notifyListeners();
  }
}
