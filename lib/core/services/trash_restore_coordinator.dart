import 'dart:convert';

import '../database/business_preferences.dart';
import '../database/chat_database_repository.dart';
import '../providers/assistant_provider.dart';
import '../providers/mcp_provider.dart';
import '../providers/memory_provider.dart';
import '../providers/quick_instruction_provider.dart';
import '../providers/world_book_provider.dart';
import '../services/chat/chat_service.dart';
import '../services/deleted_records_store.dart';
import '../services/memory_store.dart';
import '../services/quick_instruction_store.dart';
import '../services/world_book_store.dart';
import '../models/assistant.dart';
import '../models/assistant_memory.dart';
import '../models/group_chat.dart';
import '../models/group_chat_member.dart';
import '../models/quick_instruction.dart';
import '../models/world_book.dart';

/// Central coordinator for restore / local-delete / local-id-resolution
/// across all 7 recoverable entity types.
///
/// Injected into the Provider tree AFTER all concrete providers so it can
/// depend on them. Used by [TrashDetailPage] and [DataSync].
class TrashRestoreCoordinator {
  TrashRestoreCoordinator({
    required this.chatService,
    required BusinessPreferences preferences,
    this.assistantProvider,
    this.worldBookProvider,
    this.quickInstructionProvider,
    this.mcpProvider,
    this.memoryProvider,
  }) : _worldBookStore = WorldBookStore.shared(preferences),
       _quickInstructionStore = QuickInstructionStore.shared(preferences),
       _memoryStore = MemoryStore.shared(preferences);

  final WorldBookStore _worldBookStore;
  final QuickInstructionStore _quickInstructionStore;
  final MemoryStore _memoryStore;
  final ChatService chatService;
  final AssistantProvider? assistantProvider;
  final WorldBookProvider? worldBookProvider;
  final QuickInstructionProvider? quickInstructionProvider;
  final McpProvider? mcpProvider;
  final MemoryProvider? memoryProvider;

  DeletedRecordsStore? get _store => chatService.deletedRecordsStore;
  ChatDatabaseRepository get _repo => chatService.repo;

  // ===== Restore =====

  /// Returns `null` on success, or an error message string.
  /// Also removes the matching deletion marker so it won't appear as a false
  /// "conflict" (you-deleted marker) in the Pending tab after restore.
  Future<String?> restoreEntity(String id, String type) async {
    final store = _store;
    String? error;
    switch (type) {
      case DeletionEntityType.conversation:
        error = await chatService.restoreConversationFromTrash(id);
      case DeletionEntityType.message:
        error = await chatService.restoreMessage(id);
      case DeletionEntityType.assistant:
        error = await _restoreAssistant(id);
      case DeletionEntityType.worldBook:
        error = await _restoreWorldBook(id);
      case DeletionEntityType.quickPhrase:
        error = await _restoreQuickPhrase(id);
      case DeletionEntityType.mcpServer:
        error = await _restoreMcpServer(id);
      case DeletionEntityType.memory:
        error = await _restoreMemory(id);
      case DeletionEntityType.groupChat:
        error = await _restoreGroupChat(id);
      default:
        return 'Unknown type: $type';
    }
    if (error == null && store != null) {
      // Clear marker to prevent false conflict detection after restore.
      await store.purgeLocalMarker(id, type);
    }
    return error;
  }

  Future<String?> _restoreAssistant(String id) async {
    final store = _store;
    if (store == null) return 'DeletedRecordsStore not initialized';
    final record = await store.getDeletedRecord(
      id,
      DeletionEntityType.assistant,
    );
    if (record == null) return 'Record not found in trash';
    try {
      final assistant = Assistant.fromJson(
        (jsonDecode(record.recoveryJson) as Map).cast<String, dynamic>(),
      );
      await _repo.putAssistant(assistant);
      await assistantProvider?.reloadFromRepo();
      await store.purgeDeletedRecord(id, DeletionEntityType.assistant);
      return null;
    } catch (e) {
      return 'Restore assistant failed: $e';
    }
  }

  Future<String?> _restoreWorldBook(String id) async {
    final store = _store;
    if (store == null) return 'DeletedRecordsStore not initialized';
    final record = await store.getDeletedRecord(
      id,
      DeletionEntityType.worldBook,
    );
    if (record == null) return 'Record not found in trash';
    try {
      final book = WorldBook.fromJson(
        (jsonDecode(record.recoveryJson) as Map).cast<String, dynamic>(),
      );
      await _worldBookStore.add(book);
      await worldBookProvider?.loadAll();
      await store.purgeDeletedRecord(id, DeletionEntityType.worldBook);
      return null;
    } catch (e) {
      return 'Restore worldBook failed: $e';
    }
  }

  Future<String?> _restoreQuickPhrase(String id) async {
    final store = _store;
    if (store == null) return 'DeletedRecordsStore not initialized';
    final record = await store.getDeletedRecord(
      id,
      DeletionEntityType.quickPhrase,
    );
    if (record == null) return 'Record not found in trash';
    try {
      final json = (jsonDecode(record.recoveryJson) as Map)
          .cast<String, dynamic>();
      final legacyTitle = (json['title'] ?? json['name'] ?? '')
          .toString()
          .trim();
      final item = json.containsKey('placement')
          ? QuickInstruction.fromJson(json)
          : QuickInstruction(
              id: json['id']?.toString() ?? id,
              title: legacyTitle.isEmpty ? 'Untitled' : legacyTitle,
              prompt: (json['content'] ?? json['prompt'] ?? '').toString(),
              group: QuickInstructionStore.migratedQuickPhraseGroup,
              placement: QuickInstructionPlacement.inputBox,
            );
      await _quickInstructionStore.add(item);
      await quickInstructionProvider?.loadAll();
      await store.purgeDeletedRecord(id, DeletionEntityType.quickPhrase);
      return null;
    } catch (e) {
      return 'Restore quickPhrase failed: $e';
    }
  }

  Future<String?> _restoreMcpServer(String id) async {
    final store = _store;
    if (store == null) return 'DeletedRecordsStore not initialized';
    final record = await store.getDeletedRecord(
      id,
      DeletionEntityType.mcpServer,
    );
    if (record == null) return 'Record not found in trash';
    try {
      final config = McpServerConfig.fromJson(
        (jsonDecode(record.recoveryJson) as Map).cast<String, dynamic>(),
      );
      mcpProvider?.restoreServer(config);
      await store.purgeDeletedRecord(id, DeletionEntityType.mcpServer);
      return null;
    } catch (e) {
      return 'Restore mcpServer failed: $e';
    }
  }

  Future<String?> _restoreMemory(String id) async {
    final store = _store;
    if (store == null) return 'DeletedRecordsStore not initialized';
    final record = await store.getDeletedRecord(id, DeletionEntityType.memory);
    if (record == null) return 'Record not found in trash';
    try {
      final mem = AssistantMemory.fromJson(
        (jsonDecode(record.recoveryJson) as Map).cast<String, dynamic>(),
      );
      // Re-insert with original id by writing all memories + this one.
      final all = await _memoryStore.getAll();
      all.add(mem);
      await _memoryStore.saveAll(all);
      await memoryProvider?.loadAll();
      await store.purgeDeletedRecord(id, DeletionEntityType.memory);
      return null;
    } catch (e) {
      return 'Restore memory failed: $e';
    }
  }

  // ===== Delete locally (for remote markers) =====

  /// Deletes an entity locally that was marked as "remote-deleted".
  /// Only covers types that can be deleted through available providers.
  /// Returns true on success.
  Future<bool> deleteLocally(String id, String type) async {
    switch (type) {
      case DeletionEntityType.conversation:
        await chatService.deleteConversation(id);
        return true;
      case DeletionEntityType.message:
        await chatService.deleteMessage(id);
        return true;
      case DeletionEntityType.assistant:
        final ok = await assistantProvider?.deleteAssistant(id);
        return ok ?? false;
      case DeletionEntityType.worldBook:
        await worldBookProvider?.deleteBook(id);
        return true;
      case DeletionEntityType.quickPhrase:
        await quickInstructionProvider?.delete(id);
        return true;
      case DeletionEntityType.mcpServer:
        await mcpProvider?.removeServer(id);
        return true;
      case DeletionEntityType.memory:
        final idInt = int.tryParse(id);
        if (idInt != null) {
          await memoryProvider?.delete(id: idInt);
        }
        return true;
      case DeletionEntityType.groupChat:
        await chatService.repo.deleteGroupChat(id);
        return true;
      default:
        return false;
    }
  }

  // ===== Local ID resolution (for deleted.json import) =====

  /// Returns the set of locally-existing ids for a given entity type.
  /// Used by [DataSync] to filter remote markers.
  Future<Set<String>> getLocalIds(String type) async {
    switch (type) {
      case DeletionEntityType.conversation:
        return chatService
            .getAllCompleteConversations()
            .map((c) => c.id)
            .toSet();
      case DeletionEntityType.message:
        final ids = <String>{};
        for (final conv in chatService.getAllCompleteConversations()) {
          for (final m in chatService.getMessages(conv.id)) {
            ids.add(m.id);
          }
        }
        return ids;
      case DeletionEntityType.assistant:
        return (await chatService.getAllAssistants()).map((a) => a.id).toSet();
      case DeletionEntityType.worldBook:
        return worldBookProvider?.books.map((b) => b.id).toSet() ?? {};
      case DeletionEntityType.quickPhrase:
        return quickInstructionProvider?.items.map((item) => item.id).toSet() ??
            {};
      case DeletionEntityType.mcpServer:
        return mcpProvider?.servers.map((s) => s.id).toSet() ?? {};
      case DeletionEntityType.memory:
        return (memoryProvider?.memories ?? [])
            .map((m) => m.id.toString())
            .toSet();
      case DeletionEntityType.groupChat:
        final groups = await chatService.repo.getAllGroupChats();
        return groups.map((g) => g.id).toSet();
      default:
        return {};
    }
  }

  // ===== Conflict detection (entities alive + deletion marker exists) =====

  /// Returns the count of markers whose entity still exists locally.
  /// Designed for the lightweight startup check.
  Future<int> countConflicts() async {
    final store = _store;
    if (store == null) return 0;
    final conflicts = await store.listConflicts(getLocalIds);
    return conflicts.length;
  }

  /// Returns a human-readable display name for a live entity (not from trash).
  /// Used by the pending-conflicts tab.
  Future<String?> getLiveDisplayName(String id, String type) async {
    switch (type) {
      case DeletionEntityType.conversation:
        final conv = chatService.getConversation(id);
        return conv?.title;
      case DeletionEntityType.message:
        for (final conv in chatService.getAllCompleteConversations()) {
          for (final m in chatService.getMessages(conv.id)) {
            if (m.id == id) {
              return _contentPreview(m.content);
            }
          }
        }
        return null;
      case DeletionEntityType.assistant:
        final assistants = await chatService.getAllAssistants();
        return assistants.where((a) => a.id == id).firstOrNull?.name;
      case DeletionEntityType.worldBook:
        return worldBookProvider?.books
            .where((b) => b.id == id)
            .firstOrNull
            ?.name;
      case DeletionEntityType.quickPhrase:
        return quickInstructionProvider?.items
            .where((item) => item.id == id)
            .firstOrNull
            ?.title;
      case DeletionEntityType.mcpServer:
        return mcpProvider?.servers.where((s) => s.id == id).firstOrNull?.name;
      case DeletionEntityType.memory:
        final idInt = int.tryParse(id);
        if (idInt == null) return null;
        final mem = memoryProvider?.memories
            .where((m) => m.id == idInt)
            .firstOrNull;
        return mem != null ? _contentPreview(mem.content) : null;
      case DeletionEntityType.groupChat:
        final g = await chatService.repo.getGroupChat(id);
        return g?.name;
      default:
        return null;
    }
  }

  Future<String?> _restoreGroupChat(String id) async {
    final store = _store;
    if (store == null) return 'DeletedRecordsStore not initialized';
    final record = await store.getDeletedRecord(
      id,
      DeletionEntityType.groupChat,
    );
    if (record == null) return 'Record not found in trash';
    try {
      final map = (jsonDecode(record.recoveryJson) as Map)
          .cast<String, dynamic>();
      final group = GroupChat.fromJson(
        (map['groupChat'] as Map).cast<String, dynamic>(),
      );
      final membersRaw = map['members'] as List? ?? const [];
      final members = membersRaw
          .map(
            (e) => GroupChatMember.fromJson((e as Map).cast<String, dynamic>()),
          )
          .toList();

      // Conversation/messages may already be restored via conversation trash.
      await chatService.repo.putGroupChat(group);
      await chatService.repo.putGroupMembers(group.id, members);
      await store.purgeDeletedRecord(id, DeletionEntityType.groupChat);
      return null;
    } catch (e) {
      return 'Restore groupChat failed: $e';
    }
  }

  static String? _contentPreview(String? content) {
    if (content == null || content.isEmpty) return null;
    final clean = content
        .replaceAll(RegExp(r'^[#*>\-\d\.]+\s*'), '')
        .replaceAll(RegExp(r'\*\*|__|~~'), '')
        .trim();
    return clean.length > 50 ? '${clean.substring(0, 50)}\u2026' : clean;
  }
}
