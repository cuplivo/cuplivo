import '../../database/business_preferences.dart';
import '../../database/business_repository.dart';
import '../../database/chat_database_repository.dart';
import '../chat/chat_service.dart';
import 'business_state_reloader.dart';
import 'sync_merge.dart';
import 'sync_models.dart';

/// Everything sync needs from the stores, in one place: manifest building,
/// subtree and business-row reading, transactional apply, and the reload tail
/// that makes applied rows visible without restarting the app (ADR-0002).
///
/// Both roles (initiator and responder) go through this class, which is what
/// guarantees the two sides plan against the same kind of inputs.
class SyncDataPlane {
  SyncDataPlane({
    required this.repository,
    required this.chatService,
    required this.businessRepository,
    this.businessPreferences,
    this.reloader,
  });

  final ChatDatabaseRepository repository;
  final ChatService chatService;
  final BusinessRepository businessRepository;

  /// Null only in tests that exercise conversations alone; sync writes to the
  /// business store without it, but the in-memory view cannot be refreshed and
  /// the restore fence cannot be observed.
  final BusinessPreferences? businessPreferences;

  /// Refreshes the in-memory business view and the providers that read it after
  /// a successful apply. Null in conversation-only tests.
  final BusinessStateReloader? reloader;

  int get schemaVersion => repository.syncSchemaVersion;

  /// Conversation, entity and preference state of this device, as a manifest.
  Future<SyncManifest> buildManifest() async {
    final refs = await repository.syncConversationRefs();
    final digestInputs = await repository.syncMessageDigestInputs();
    final byConversation = {
      for (final row in digestInputs) row.conversationId: row,
    };
    final entityRefs = await businessRepository.syncEntityRefs();
    final preferenceRefs = await businessRepository.syncPreferenceRefs();
    final entities = <String, Map<String, SyncManifestEntry>>{};
    for (final ref in entityRefs) {
      (entities[ref.kindWire] ??=
          <String, SyncManifestEntry>{})[ref.id] = SyncManifestEntry(
        updatedAtUs: ref.updatedAtUs,
        // Unused for business rows: they have no sub-rows to count.
        messageCount: 0,
        digest: ref.digest,
      );
    }
    return SyncManifest(
      {
        for (final ref in refs)
          ref.conversationId: SyncManifestEntry(
            updatedAtUs: ref.updatedAtUs,
            messageCount: byConversation[ref.conversationId]?.messageCount ?? 0,
            digest: switch (byConversation[ref.conversationId]) {
              null => emptyConversationDigest,
              final row => digestFromDigestInput(row.digestInput),
            },
          ),
      },
      entities: entities,
      preferences: {
        for (final ref in preferenceRefs)
          ref.key: SyncManifestEntry(
            updatedAtUs: ref.updatedAtUs,
            messageCount: 0,
            digest: ref.digest,
          ),
      },
    );
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

  // ---- business rows (entities + preferences, slice 2) ----

  /// Whether a restore currently holds the business write fence. Applying
  /// business rows then defers: the session keeps its previous checkpoint
  /// entries and retries next time, rather than writing over a restore.
  bool get businessWritesBlocked =>
      businessPreferences?.writesBlockedForRestore ?? false;

  /// The named rows, ready to travel, together with the identity of every row
  /// actually included: a row deleted between planning and reading is in
  /// neither, so the caller can tell what was truly sent.
  Future<({SyncBusinessPayload payload, Set<String> keys})> readBusinessRows({
    required Map<String, Set<String>> entityIds,
    required Set<String> preferenceKeys,
  }) async {
    final entities = <String, List<Map<String, dynamic>>>{};
    final keys = <String>{};
    for (final entry in entityIds.entries) {
      if (entry.value.isEmpty) continue;
      final idColumn = _entityIdColumn(entry.key);
      if (idColumn == null) continue;
      final rows = await businessRepository.syncReadEntityRows(
        entry.key,
        entry.value,
      );
      if (rows.isEmpty) continue;
      entities[entry.key] = rows;
      for (final row in rows) {
        final id = row[idColumn];
        if (id is String) keys.add(syncBusinessKey(entry.key, id));
      }
    }
    final preferences = await businessRepository.syncReadPreferenceRows(
      preferenceKeys,
    );
    for (final row in preferences) {
      final key = row['key'];
      if (key is String) keys.add(syncBusinessKey(kSyncPreferenceWire, key));
    }
    return (
      payload: SyncBusinessPayload(
        entities: entities,
        preferences: preferences,
      ),
      keys: keys,
    );
  }

  /// The identities carried by an incoming payload.
  Set<String> businessKeysOf(SyncBusinessPayload payload) {
    final keys = <String>{};
    for (final entry in payload.entities.entries) {
      final idColumn = _entityIdColumn(entry.key);
      if (idColumn == null) continue;
      for (final row in entry.value) {
        final id = row[idColumn];
        if (id is String) keys.add(syncBusinessKey(entry.key, id));
      }
    }
    for (final row in payload.preferences) {
      final key = row['key'];
      if (key is String) keys.add(syncBusinessKey(kSyncPreferenceWire, key));
    }
    return keys;
  }

  /// The primary-key column of a wire kind, or null when this build does not
  /// sync that kind.
  static String? _entityIdColumn(String kindWire) =>
      BusinessRepository.syncKindForWire(kindWire)?.idColumn;

  /// Applies an incoming business payload, then refreshes the in-memory view
  /// and the providers that read it — once, and only when something changed.
  Future<SyncBusinessApplyOutcome> applyBusiness(
    SyncBusinessPayload payload, {
    required String myDeviceId,
    required String peerDeviceId,
  }) async {
    if (businessWritesBlocked) {
      return SyncBusinessApplyOutcome.deferredOutcome;
    }
    Future<SyncBusinessApplyOutcome> write() =>
        businessRepository.syncApplyBusinessRows(
          entities: payload.entities,
          preferences: payload.preferences,
          myDeviceId: myDeviceId,
          peerDeviceId: peerDeviceId,
        );
    // Writes ride the same queue as local entity edits, so a provider's
    // whole-list rewrite cannot interleave with an apply in the middle.
    final preferences = businessPreferences;
    final outcome = preferences == null
        ? await write()
        : await preferences.serializeExternalWrite(write);
    if (outcome.deferred) return outcome;
    if (outcome.changed) await reloadBusiness();
    return outcome;
  }

  /// Deletes one business row the peer no longer has.
  Future<bool> deleteBusinessRow(String kindWire, String id) =>
      kindWire == kSyncPreferenceWire
      ? businessRepository.syncDeletePreference(id)
      : businessRepository.syncDeleteEntity(kindWire, id);

  /// The checkpoint entry for a business row whose local state is the state
  /// both sides now agree on, or null when the row does not exist here.
  Future<SyncCheckpointEntry?> checkpointBusinessFromLocal(
    String kindWire,
    String id,
  ) async {
    if (kindWire == kSyncPreferenceWire) {
      final rows = await businessRepository.syncReadPreferenceRows({id});
      if (rows.isEmpty) return null;
      return SyncCheckpointEntry(
        updatedAtUs: (rows.first['updated_at'] as num).toInt(),
        digest: businessContentDigest(rows.first['value'] as String),
      );
    }
    final rows = await businessRepository.syncReadEntityRows(kindWire, {id});
    if (rows.isEmpty) return null;
    final kind = BusinessRepository.syncKindForWire(kindWire);
    if (kind == null) return null;
    return SyncCheckpointEntry(
      updatedAtUs: (rows.first['updated_at'] as num).toInt(),
      digest: businessContentDigest(rows.first['payload'] as String),
    );
  }

  /// Refreshes the in-memory business view and every provider that reads it.
  /// One call per session that changed business state.
  Future<void> reloadBusiness() async {
    final active = reloader;
    if (active != null) {
      await active.reloadAll();
      return;
    }
    await businessPreferences?.reload();
  }
}
