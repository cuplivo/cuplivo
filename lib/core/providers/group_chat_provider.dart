import 'package:flutter/foundation.dart';
import 'package:uuid/uuid.dart';

import '../database/business_data.dart';
import '../database/business_repository.dart';
import '../database/extension_entity_store.dart';
import '../models/conversation.dart';
import '../models/group_chat.dart';
import '../services/chat/chat_service.dart';
import '../services/recycle/recycle_store.dart';

/// The group chats this device holds.
///
/// Rows live in `extension_entity_rows(kind: 'groupChat')`, which is why this
/// needs no storage of its own — and no schema change. A group is also a
/// business entity, so backup, LAN sync and the recycle bin already know how to
/// carry and undo one.
class GroupChatProvider extends ChangeNotifier {
  GroupChatProvider({
    required this.store,
    this.chatService,
    this.businessRepository,
  }) {
    loaded = _load();
  }

  static const String kind = 'groupChat';

  final ExtensionEntityStore store;
  final ChatService? chatService;
  final BusinessRepository? businessRepository;
  final List<GroupChat> _groups = <GroupChat>[];

  late final Future<void> loaded;

  List<GroupChat> get groups => List.unmodifiable(_groups);

  GroupChat? byId(String? id) {
    if (id == null || id.isEmpty) return null;
    for (final group in _groups) {
      if (group.id == id) return group;
    }
    return null;
  }

  /// The group a conversation belongs to, or null for a 1:1 conversation.
  GroupChat? forConversation(Conversation? conversation) =>
      conversation == null ? null : byId(conversation.groupChatId);

  Future<void> _load() async {
    try {
      final entities = await store.listByKind(kind);
      final groups = <GroupChat>[];
      for (final entity in entities) {
        // One unreadable row costs its own group, never the list: the payload is
        // peer input, and the row stays in SQLite for the peer's next push to
        // repair.
        if (entity.payload['id'] != entity.id) continue;
        try {
          groups.add(GroupChat.fromJson(entity.payload));
        } catch (error) {
          debugPrint('groupChats: skipping an unreadable row: $error');
        }
      }
      _groups
        ..clear()
        ..addAll(groups);
    } catch (error) {
      debugPrint('Failed to load group chats: $error');
      _groups.clear();
    }
    notifyListeners();
  }

  /// Re-reads after LAN sync wrote rows outside this provider (ADR-0003).
  Future<void> reloadAfterExternalChange() => _load();

  Future<GroupChat> create({
    required String name,
    required List<String> memberIds,
    String? avatar,
    int? maxSpeakerTurns,
  }) async {
    await loaded;
    final now = DateTime.now().toUtc();
    final group = GroupChat(
      id: const Uuid().v4(),
      name: name.trim(),
      avatar: avatar,
      memberIds: List<String>.unmodifiable(memberIds.toSet()),
      maxSpeakerTurns: (maxSpeakerTurns ?? GroupChat.defaultMaxSpeakerTurns)
          .clamp(GroupChat.minSpeakerTurns, GroupChat.maxSpeakerTurnsLimit),
      createdAt: now,
      updatedAt: now,
    );
    await store.upsert(
      kind,
      group.id,
      group.toJson(),
      sortOrder: _groups.length,
    );
    _groups.add(group);
    notifyListeners();
    return group;
  }

  /// Applies [mutate] to the group **as it is now**, not to a snapshot the
  /// caller captured earlier.
  ///
  /// Every edit in the settings view starts with a row it read at build or tap
  /// time, and several of them finish after an await — a rename debounce, an
  /// avatar dialog, a member picker. Writing the whole snapshot back let the
  /// slower edit undo the faster one; a mutator makes the write read-modify-write
  /// instead, so the two edits compose.
  ///
  /// A group that is no longer here is **not** re-added: the row can be gone
  /// because a peer deleted it (LAN sync), and a stale write must not resurrect
  /// it. A mutation that changes nothing is skipped, so an unchanged write does
  /// not bump `updatedAt` and hand the row to the next sync as if it had moved.
  Future<void> update(
    String id,
    GroupChat Function(GroupChat current) mutate,
  ) async {
    await loaded;
    final index = _groups.indexWhere((item) => item.id == id);
    if (index < 0) return;
    final current = _groups[index];
    final mutated = mutate(current);
    if (mutated == current) return;
    final next = mutated.copyWith(updatedAt: DateTime.now().toUtc());
    await store.upsert(kind, id, next.toJson(), sortOrder: index);
    _groups[index] = next;
    notifyListeners();
  }

  /// Removes the group and every conversation that belongs to it, as one act:
  /// the bin shows the group row and its topics under a single
  /// [RecycleGroup] rather than as N unrelated deletions.
  Future<void> delete(String id) async {
    await loaded;
    final group = byId(id);
    if (group == null) return;
    final recycleGroup = RecycleGroup(
      id: const Uuid().v4().substring(0, 8),
      label: group.name.isEmpty ? group.id : group.name,
    );
    await chatService?.deleteConversationsForGroup(id, group: recycleGroup);
    final repository = businessRepository;
    if (repository != null) {
      await repository.deleteEntity(
        BusinessEntityKind.groupChat,
        id,
        group: recycleGroup,
      );
    } else {
      await store.delete(kind, id);
    }
    _groups.removeWhere((item) => item.id == id);
    notifyListeners();
  }
}
