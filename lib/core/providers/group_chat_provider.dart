import 'package:flutter/foundation.dart';

import '../database/chat_database_repository.dart';
import '../models/chat_input_data.dart';
import '../models/conversation.dart';
import '../models/assistant_detail_injection.dart';
import '../models/group_chat.dart';
import '../models/group_chat_conversations.dart';
import '../models/group_chat_director_log.dart';
import '../models/group_chat_member.dart';
import '../services/chat/chat_service.dart';

/// Soft / hard caps for assistant members (excluding the user).
const int groupChatMemberSoftCap = 12;
const int groupChatMemberHardCap = 20;

/// In-memory state of every group chat.
///
/// The group row and its roster live in [ChatDatabaseRepository]; the public
/// transcript is an ordinary conversation marked with
/// `group.kind` in its extras, owned by [ChatService]. This provider keeps the
/// lists hot in memory and is the only writer of the group rows.
class GroupChatProvider extends ChangeNotifier {
  /// Runtime metadata is diagnostic only; keep enough recent entries for a
  /// long-running process without allowing repeated retries to grow forever.
  static const int maxRuntimeDirectorLogsPerGroup = 200;

  GroupChatProvider({required this.chatService});

  final ChatService chatService;
  final List<GroupChat> _groups = [];
  final Map<String, List<GroupChatMember>> _membersByGroup = {};
  final Map<String, List<GroupChatDirectorRuntimeLog>> _runtimeDirectorLogs =
      {};

  /// Session-level stash for a queued send that outlives its page:
  /// GroupChatView stashes its one-slot pending send on dispose (mobile
  /// route pop) so the queued text is not silently lost; a freshly mounted
  /// view for the same group takes it back and auto-drains (mirrors the
  /// single-chat per-conversation queue drain). In-memory only — process
  /// death loses it, same as the single-chat queue. Cleared with the group.
  final Map<String, ChatInputData> _pendingQueuedInput = {};
  bool _loaded = false;

  bool get loaded => _loaded;
  List<GroupChat> get groups => List.unmodifiable(_groups);

  /// The repository behind [chatService]. Throws when the service has no
  /// database yet: every method here is a database operation.
  ChatDatabaseRepository get _repo {
    final repo = chatService.chatRepositoryOrNull;
    if (repo == null) throw StateError('group_chat_repository_unavailable');
    return repo;
  }

  Future<void> load() async {
    if (!chatService.initialized) {
      await chatService.init();
    }
    final list = await _repo.getAllGroupChats();
    _groups
      ..clear()
      ..addAll(list);
    _membersByGroup.clear();
    _runtimeDirectorLogs.clear();
    _pendingQueuedInput.clear();
    for (final g in list) {
      _membersByGroup[g.id] = await _repo.getGroupMembers(g.id);
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

  /// The group bound to [conversationId], or null when the conversation is
  /// not a group transcript. Resolved straight from the database: unlike
  /// [getById] this works before [load] and after an external write.
  Future<GroupChat?> getByConversationId(String conversationId) async {
    if (!chatService.initialized) await chatService.init();
    return _repo.getGroupChatByConversationId(conversationId);
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

  /// Stashes a queued send for [groupChatId] so it survives the page being
  /// disposed (mobile route pop). Callers must not stash for a group that no
  /// longer exists. Notifies listeners: a view of the same group that mounted
  /// before this stash landed (the disposing route can outlive the new one's
  /// first frame during the pop animation) picks it up from the notification.
  void stashQueuedInput(String groupChatId, ChatInputData input) {
    _pendingQueuedInput[groupChatId] = input;
    notifyListeners();
  }

  /// Takes (and removes) the stashed queued send for [groupChatId], if any.
  ChatInputData? takeQueuedInput(String groupChatId) {
    return _pendingQueuedInput.remove(groupChatId);
  }

  /// Whether a stash exists for [groupChatId], without consuming it. Lets a
  /// mounted view cheaply decide whether a provider notification is a stash
  /// handoff worth a post-frame drain check.
  bool hasQueuedInput(String groupChatId) {
    return _pendingQueuedInput.containsKey(groupChatId);
  }

  /// Latest public message preview for list subtitle.
  String? latestMessagePreview(String groupChatId) {
    final g = getById(groupChatId);
    if (g == null) return null;
    final msgs = chatService.getMessages(g.conversationId);
    if (msgs.isEmpty) return null;
    final last = msgs.last;
    final t = last.content.trim();
    if (t.isEmpty) return null;
    return t.length > 80 ? '${t.substring(0, 80)}…' : t;
  }

  Future<GroupChat> createGroup({required String name}) async {
    // Callers must pass a non-empty, localized name.
    final trimmed = name.trim();
    final conversation = await _createGroupConversation(trimmed);
    final group = GroupChat(
      name: trimmed,
      conversationId: conversation.id,
      directorSystemPrompt: GroupChat.defaultDirectorSystemPrompt,
      maxAssistantMessagesPerRound: 3,
      assistantDetailInjectionMode:
          AssistantDetailInjectionMode.endOfEveryUserMessage,
      assistantDetailInjectionN: 5,
    );

    await _repo.putGroupChat(group);
    final members = [GroupChatMember.user(groupChatId: group.id, sortOrder: 0)];
    await _repo.putGroupMembers(group.id, members);

    _groups.insert(0, group);
    _membersByGroup[group.id] = members;
    notifyListeners();
    return group;
  }

  /// Duplicate a group chat (config only): a new group + a fresh empty
  /// conversation with the same members, director model and prompt settings.
  /// Per-round runtime state (pending cap message, assistant count) resets.
  Future<GroupChat> duplicateGroup(GroupChat source) async {
    final conversation = await _createGroupConversation(source.name);
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

    await _repo.putGroupChat(copy);
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
    await _repo.putGroupMembers(copy.id, members);

    _groups.insert(0, copy);
    _membersByGroup[copy.id] = members;
    notifyListeners();
    return copy;
  }

  /// Creates the transcript conversation for a new group and marks it.
  ///
  /// [ChatService.createConversation] activates the new conversation and has
  /// no extras pass-through, so the mark is applied immediately afterwards
  /// and the previously active conversation is restored.
  Future<Conversation> _createGroupConversation(String title) =>
      createGroupConversation(chatService, title);

  /// Standalone form of [_createGroupConversation] so callers outside this
  /// provider (importers, tests) never hand-build a group transcript.
  static Future<Conversation> createGroupConversation(
    ChatService chatService,
    String title,
  ) async {
    final previousId = chatService.currentConversationId;
    final conversation = await chatService.createConversation(title: title);
    await chatService.updateConversationExtras(conversation.id, (current) {
      return {
        ...current,
        GroupChatConversations.extrasKindKey: GroupChatConversations.kindGroup,
      };
    });
    if (previousId != null && previousId != conversation.id) {
      chatService.setCurrentConversation(previousId);
    }
    final marked = chatService.getConversation(conversation.id);
    return marked ?? conversation;
  }

  Future<void> updateGroup(GroupChat group) async {
    final updated = group.copyWith(updatedAt: DateTime.now());
    await _repo.putGroupChat(updated);
    final idx = _groups.indexWhere((g) => g.id == updated.id);
    if (idx >= 0) {
      _groups[idx] = updated;
    } else {
      _groups.add(updated);
    }
    // Keep conversation title in sync with group name. This is the ONLY path
    // that renames a group's conversation — never a bare repo.putConversation.
    final conv = chatService.getConversation(updated.conversationId);
    if (conv != null && conv.title != updated.name) {
      await chatService.renameConversation(
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
    await _repo.putGroupMembers(groupChatId, members);
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
    final ids = assistantIdsOf(groupChatId).where((id) => id != assistantId);
    await setMembers(groupChatId, ids.toList());
  }

  Future<void> removeAssistantFromAllGroups(String assistantId) async {
    await _repo.removeAssistantFromAllGroups(assistantId);
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
    await _repo.putGroupChat(group);
    final idx = _groups.indexWhere((g) => g.id == group.id);
    if (idx >= 0) _groups[idx] = group;
    notifyListeners();
  }

  /// Deletes the group row plus its transcript conversation.
  ///
  /// There is no trash coordinator in this worktree, so nothing is packaged
  /// for restore: the deletion is final. The conversation goes through
  /// [ChatService.deleteConversation] (which records the repo tombstone and
  /// clears the caches); the group row is deleted directly because the
  /// conversation must stay alive until the group row is gone.
  Future<void> deleteGroup(String groupChatId) async {
    final group = getById(groupChatId);
    if (group == null) return;

    await _repo.deleteGroupChat(groupChatId);
    try {
      await chatService.deleteConversation(group.conversationId);
    } catch (e) {
      debugPrint('[GroupChatProvider] delete conversation: $e');
      await _repo.deleteConversation(group.conversationId);
    }

    _groups.removeWhere((g) => g.id == groupChatId);
    _membersByGroup.remove(groupChatId);
    _runtimeDirectorLogs.remove(groupChatId);
    // A queued send of a deleted group must never resurrect as a send into
    // a fresh view (or leak in memory).
    _pendingQueuedInput.remove(groupChatId);
    notifyListeners();
  }

  /// Drops every group from memory (backup restore / clear-all). Callers must
  /// re-[load] once the underlying database was replaced.
  void resetForNewData() {
    _groups.clear();
    _membersByGroup.clear();
    _runtimeDirectorLogs.clear();
    _pendingQueuedInput.clear();
    _loaded = false;
    notifyListeners();
  }

  /// Replaces the in-memory copy of [group] after an out-of-band write
  /// (for example a backup merge that rewrote the row).
  void adoptGroup(GroupChat group, {List<GroupChatMember>? members}) {
    final idx = _groups.indexWhere((g) => g.id == group.id);
    if (idx >= 0) {
      _groups[idx] = group;
    } else {
      _groups.insert(0, group);
    }
    if (members != null) _membersByGroup[group.id] = members;
    notifyListeners();
  }

  /// Test seam: replaces the roster map with [entries] without touching the
  /// database. Production callers go through [setMembers] / [load].
  @visibleForTesting
  void debugSetMembersByGroup(Map<String, List<GroupChatMember>> entries) {
    _membersByGroup
      ..clear()
      ..addAll(entries);
    notifyListeners();
  }
}
