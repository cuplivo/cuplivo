import '../../database/chat_database_repository.dart';
import '../chat/chat_service.dart';
import 'sync_merge.dart';
import 'sync_models.dart';

/// Everything sync needs from the chat store, in one place: manifest building,
/// subtree reading, transactional apply, and the reload tail that makes applied
/// rows visible without restarting the app (ADR-0002).
///
/// Both roles (initiator and responder) go through this class, which is what
/// guarantees the two sides plan against the same kind of inputs.
class SyncDataPlane {
  SyncDataPlane({required this.repository, required this.chatService});

  final ChatDatabaseRepository repository;
  final ChatService chatService;

  int get schemaVersion => repository.syncSchemaVersion;

  /// Conversation state of this device, as a manifest.
  Future<SyncManifest> buildManifest() async {
    final refs = await repository.syncConversationRefs();
    final digestInputs = await repository.syncMessageDigestInputs();
    final byConversation = {
      for (final row in digestInputs) row.conversationId: row,
    };
    return SyncManifest({
      for (final ref in refs)
        ref.conversationId: SyncManifestEntry(
          updatedAtUs: ref.updatedAtUs,
          messageCount: byConversation[ref.conversationId]?.messageCount ?? 0,
          digest: switch (byConversation[ref.conversationId]) {
            null => emptyConversationDigest,
            final row => digestFromDigestInput(row.digestInput),
          },
        ),
    });
  }

  /// One conversation as a wire subtree, or null when it no longer exists.
  Future<SyncSubtreePayload?> readSubtree(String conversationId) async {
    final conversation = await repository.syncReadConversationRow(
      conversationId,
    );
    if (conversation == null) return null;
    return SyncSubtreePayload(
      conversation: conversation,
      messages: await repository.syncReadMessageRows(conversationId),
      parts: await repository.syncReadMessagePartRows(conversationId),
      mcpServers: await repository.syncReadMcpServerRows(conversationId),
    );
  }

  /// Whether a generation is writing to this conversation right now. Such a
  /// conversation is neither sent nor applied in this round; its checkpoint
  /// entry is left untouched so the next session retries it.
  Future<bool> isStreaming(String conversationId) =>
      repository.syncConversationIsStreaming(conversationId);

  /// The checkpoint entry for a conversation whose local state already equals
  /// the peer's post-session state (nothing to send, or we are the sender).
  Future<SyncCheckpointConversation?> checkpointFromLocal(
    String conversationId,
  ) async {
    final conversation = await repository.syncReadConversationRow(
      conversationId,
    );
    if (conversation == null) return null;
    return buildCheckpointConversation(
      conversationRow: conversation,
      messageRows: await repository.syncReadMessageRows(conversationId),
    );
  }

  /// Applies incoming subtrees one conversation at a time, then reloads the
  /// chat caches once. Returns per-conversation outcomes keyed by id so the
  /// caller can advance checkpoints precisely (deferred conversations keep
  /// their previous entry).
  Future<Map<String, SyncSubtreeApplyOutcome>> applySubtrees(
    List<SyncSubtreePayload> subtrees, {
    required String myDeviceId,
    required String peerDeviceId,
    required Map<String, Map<String, int>> checkpointRowsByConversation,
  }) async {
    final outcomes = <String, SyncSubtreeApplyOutcome>{};
    var changed = false;
    for (final subtree in subtrees) {
      final conversationId = subtree.conversation['id'] as String;
      final outcome = await repository.syncApplySubtree(
        payload: subtree,
        myDeviceId: myDeviceId,
        peerDeviceId: peerDeviceId,
        checkpointRows:
            checkpointRowsByConversation[conversationId] ?? const {},
      );
      outcomes[conversationId] = outcome;
      if (!outcome.deferred &&
          (outcome.upsertedMessages > 0 ||
              outcome.deletedMessages > 0 ||
              outcome.conversationRowChanged)) {
        changed = true;
      }
    }
    if (changed) await chatService.reloadAfterExternalChange();
    return outcomes;
  }

  /// Deletes a conversation the peer deleted. Returns false when the deletion
  /// yielded to a running generation and must be retried next session.
  Future<bool> deleteConversation(String conversationId) =>
      repository.syncApplyPeerDeletion(conversationId);

  /// Re-reads chat caches after this device deleted conversations (or applied
  /// subtrees) outside the normal UI write path.
  Future<void> reload() => chatService.reloadAfterExternalChange();
}
