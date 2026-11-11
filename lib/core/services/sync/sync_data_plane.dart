import 'dart:io';

import '../../database/business_data.dart';
import '../../database/business_preferences.dart';
import '../../database/business_repository.dart';
import '../../database/chat_database_repository.dart';
import '../chat/chat_service.dart';
import '../recycle/recycle_service.dart';
import '../skills/skill_directory_sync.dart';
import 'blob_sync.dart';
import 'business_state_reloader.dart';
import 'sync_merge.dart';
import 'sync_models.dart';
import 'workspace_content_sync.dart';

/// Everything sync needs from the stores, in one place: manifest building,
/// subtree and business-row reading, transactional apply, and the reload tail
/// that makes applied rows visible without restarting the app (ADR-0003).
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
    this.skillDirectories,
    this.workspaceContent,
    this.recycle,
    BlobFileHasher? fileHasher,
    this.blobPathResolver = defaultBlobPathResolver,
  }) : fileHasher = fileHasher ?? BlobFileHasher();

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

  /// Skill directory hashing, zip serving and atomic apply (slice 3). Null in
  /// conversation-only tests; skill bodies then hash as "missing", so a skill
  /// record still converges on its own but no body is transferred.
  final SkillDirectorySync? skillDirectories;

  /// Managed workspace *content* (slice 18): the folder behind a workspace row.
  /// Null in conversation-only tests, where the records still travel and no
  /// file ever moves.
  final WorkspaceContentSync? workspaceContent;

  /// The device-local recycle bin, when the app attached one. A skill's body
  /// travels into it together with the record a peer's deletion removes, so that
  /// deletion is undoable (ADR-0016); null in a harness with no bin, where the
  /// body is deleted and the row is staged on its own.
  final RecycleService? recycle;

  /// Content hashing for file blobs, memoised per (path, length, mtime).
  final BlobFileHasher fileHasher;

  /// URI → local file mapping for file blobs. Production is the sandbox
  /// resolver; a two-device test process injects one root per side.
  final BlobPathResolver blobPathResolver;

  /// Wire name of the skill entity kind — the single authority for it lives on
  /// `BusinessEntityKind`.
  static String get skillWire => BusinessEntityKind.skill.wireName;

  /// Sentinel directory hash for a skill whose body this device does not have.
  /// It is a legal digest value, so it rides the ordinary combined digest and
  /// makes "record without body" compare unequal to any real directory hash.
  static const String missingSkillBody = 'missing';

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
    // A skill's manifest digest combines its record payload with its directory
    // hash: the record clock does not track content edits, so the directory
    // hash is the only thing that can make a body edit visible to the plan.
    final skillIds = {
      for (final ref in entityRefs)
        if (ref.kindWire == skillWire) ref.id,
    };
    final dirHashes = await _directoryHashes(skillIds);
    final entities = <String, Map<String, SyncManifestEntry>>{};
    for (final ref in entityRefs) {
      final digest = ref.kindWire == skillWire
          ? combineSkillDigest(
              ref.digest,
              dirHashes[ref.id] ?? missingSkillBody,
            )
          : ref.digest;
      (entities[ref.kindWire] ??=
          <String, SyncManifestEntry>{})[ref.id] = SyncManifestEntry(
        updatedAtUs: ref.updatedAtUs,
        // Unused for business rows: they have no sub-rows to count.
        messageCount: 0,
        digest: digest,
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
  ///
  /// The conversations the peer sent ride along with the reload: they are what
  /// tells an open window to rebuild, instead of leaving the user reading
  /// pre-sync content until they switch conversations and back. "The peer sent
  /// it" is the trigger rather than "a counter moved", because the counters
  /// cannot express every change the user sees — a subtree that only carries
  /// parts or asset references for a revision already here, and a repaired
  /// message order (which has its own flag for exactly this reason), both
  /// change what is rendered while every counter stays at zero. A deferred
  /// conversation stays out: its apply wrote nothing locally.
  Future<Map<String, SyncSubtreeApplyOutcome>> applySubtrees(
    List<SyncSubtreePayload> subtrees, {
    required String myDeviceId,
    required String peerDeviceId,
    required Map<String, Map<String, int>> checkpointRowsByConversation,
  }) async {
    final outcomes = <String, SyncSubtreeApplyOutcome>{};
    final touched = <String>{};
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
      if (!outcome.deferred) touched.add(conversationId);
    }
    if (touched.isNotEmpty) {
      await chatService.reloadAfterExternalChange(
        touchedConversations: touched,
      );
    }
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

  /// Deletes one business row the peer no longer has. A skill's body goes with
  /// its record — a row-less directory would be resurrected as a fresh record by
  /// the skills rescan, and a directory-less row installs a broken skill — and
  /// the pair goes into the recycle bin as **one** entry, so that deletion is
  /// undoable on this device (ADR-0016). A
  /// *managed workspace's* folder goes with its record for the same two
  /// reasons — a directory-less workspace looks empty in the app, and a
  /// row-less folder is invisible there while sitting on the disk.
  ///
  /// **Except when the user has switched content sync off for that workspace.**
  /// The switch promises that this device's files are its own, and a peer-driven
  /// deletion is exactly the case that promise has to cover: the row goes (it is
  /// gone on the peer, and a row that stayed would be re-advertised and come
  /// back), the folder stays, and the outcome says so ([folderKept]) so the
  /// session report can name it. Deleting it would make "off" mean "protected
  /// only from transfers, and removed when the peer tidies up", which is not
  /// what the switch says anywhere it is explained.
  ///
  /// The delete rides the same serialized write queue as applies and local
  /// entity edits (ADR-0003): a provider's whole-list read-modify-write must
  /// not interleave with a sync deletion either, or it re-inserts the row the
  /// checkpoint entry already dropped.
  Future<BusinessRowDeleteOutcome> deleteBusinessRow(
    String kindWire,
    String id, {

    /// What this pairing last agreed for the workspace's files, when the row is
    /// a workspace. Carried from the checkpoint the session read at its start.
    Map<String, SyncAgreedFile> agreedFiles = const {},
  }) async {
    Future<BusinessRowDeleteOutcome> delete() async {
      if (kindWire == kSyncPreferenceWire) {
        return BusinessRowDeleteOutcome(
          removed: await businessRepository.syncDeletePreference(id),
        );
      }
      // Read before the delete: the row is what says whether the folder is
      // Cuplivo's to remove (a linked workspace's is the user's own).
      final managesFolder =
          kindWire == WorkspaceContentSync.workspaceWire &&
          await _isManagedWorkspace(id);
      // A skill's body leaves this device with its record, in **one** entry: a
      // row staged on its own restores into a skill with no directory, which is
      // what a peer's deletion used to produce. The body moves first, because
      // the entry that preserves it carries the row — so the row must not also
      // be staged on its own that way.
      final preservedBody = kindWire != skillWire
          ? null
          : await recycle?.stageSkillBody(
              skillId: id,
              origin: RecycleOrigin.remote,
              reason: RecycleReason.deleted,
            );
      final removed = await businessRepository.syncDeleteEntity(
        kindWire,
        id,
        stageRow: preservedBody == null,
      );
      if (!removed) return const BusinessRowDeleteOutcome(removed: false);
      if (kindWire == skillWire) {
        // The bin did not take the body (no bin wired, an unwritable directory):
        // the row is gone, so the directory has to go too, or the rescan
        // resurrects what was just deleted as a fresh import.
        if (preservedBody == null) {
          await skillDirectories?.deleteDirectory(id);
        }
      } else if (managesFolder) {
        final content = workspaceContent;
        final off =
            content != null &&
            (await content.disabledWorkspaceIds()).contains(id);
        if (off) {
          return const BusinessRowDeleteOutcome(
            removed: true,
            folderKept: true,
          );
        }
        // The folder is about to go with `delete(recursive: true)`, which destroys
        // local files in bulk and leaves none of them in the bin. A file the two
        // sides never agreed on is an edit, and an edit beats a delete: the folder
        // stays, the row still goes (that is the peer's intent and, unlike a
        // refused row, it cannot make the session retry forever), and the report
        // names it. Same rule the file face applies per file — there is no
        // per-file pass here, because the peer shares no table for this workspace
        // to plan against.
        if (content != null &&
            await content.holdsUnagreedContent(id, agreedFiles)) {
          return const BusinessRowDeleteOutcome(
            removed: true,
            folderKept: true,
          );
        }
        await content?.deleteContent(id);
      }
      return const BusinessRowDeleteOutcome(removed: true);
    }

    final preferences = businessPreferences;
    return preferences == null
        ? await delete()
        : await preferences.serializeExternalWrite(delete);
  }

  /// Whether the local row [id] is a workspace Cuplivo owns the directory of.
  Future<bool> _isManagedWorkspace(String id) async {
    final rows = await businessRepository.syncReadEntityRows(
      WorkspaceContentSync.workspaceWire,
      {id},
    );
    if (rows.isEmpty) return false;
    final payload = rows.first['payload'];
    return payload is String && !isLinkedWorkspace(payload);
  }

  /// The checkpoint entry for a business row whose local state is the state
  /// both sides now agree on, or null when the row does not exist here.
  ///
  /// This is the **action** face: it asks what is here *now*, which is the right
  /// question for a row nobody just sent — a `none` (nothing differs) or a row
  /// the peer sent and this device applied. A row this device *sent* is answered
  /// by [checkpointBusinessFromSent] instead, and the two are not
  /// interchangeable.
  Future<SyncCheckpointEntry?> checkpointBusinessFromLocal(
    String kindWire,
    String id,
  ) async {
    if (kindWire == kSyncPreferenceWire) {
      final rows = await businessRepository.syncReadPreferenceRows({id});
      if (rows.isEmpty) return null;
      return _businessEntryFromRow(kindWire: kindWire, row: rows.first);
    }
    final rows = await businessRepository.syncReadEntityRows(kindWire, {id});
    if (rows.isEmpty) return null;
    if (BusinessRepository.syncKindForWire(kindWire) == null) return null;
    return _businessEntryFromRow(
      kindWire: kindWire,
      row: rows.first,
      directoryHash: kindWire == skillWire
          ? (await _directoryHashes({id}))[id] ?? missingSkillBody
          : null,
    );
  }

  /// The checkpoint entry for a business row **as it was sent**, or null when
  /// [sent] does not carry it.
  ///
  /// The **evidence** face, and the reason it is a separate name is the whole of
  /// this slice. A checkpoint entry is a claim about what the *peer* holds, so
  /// it has to be read from the payload that crossed the wire. Re-reading the
  /// row instead records a write the user made while the session ran — between
  /// the read and the advance, which is the push beat's whole duration — as
  /// content the peer has seen. The peer never received it, and the damage is
  /// not merely a missed send: the next session plans `mine == checkpoint` and
  /// concludes the *peer* has newer content, so this device pulls the peer's
  /// stale row over the edit it never sent.
  ///
  /// The conversation face has read its checkpoint from the sent subtree since
  /// slice 1 for exactly this reason ([SyncEngine] passes `sentSubtrees`); the
  /// business face was the only violator.
  ///
  /// [directoryHash] is the skill body hash that travelled with the row. A
  /// skill sent with no hash advertised carried no body the peer agreed to,
  /// which is what [missingSkillBody] records.
  SyncCheckpointEntry? checkpointBusinessFromSent({
    required SyncBusinessPayload sent,
    required String kindWire,
    required String id,
    String? directoryHash,
  }) {
    final row = _sentRow(sent, kindWire, id);
    if (row == null) return null;
    return _businessEntryFromRow(
      kindWire: kindWire,
      row: row,
      // A skill's advertised hash is the one that travelled; a nil hash here
      // means nothing was advertised, not that the body is missing.
      directoryHash: directoryHash ?? missingSkillBody,
    );
  }

  /// The row [sent] carries for `(kindWire, id)`, or null when the payload does
  /// not include it — a row deleted between the manifest and the read.
  static Map<String, dynamic>? _sentRow(
    SyncBusinessPayload sent,
    String kindWire,
    String id,
  ) {
    if (kindWire == kSyncPreferenceWire) {
      for (final row in sent.preferences) {
        if (row['key'] == id) return row;
      }
      return null;
    }
    final idColumn = _entityIdColumn(kindWire);
    if (idColumn == null) return null;
    for (final row in sent.entities[kindWire] ?? const []) {
      if (row[idColumn] == id) return row;
    }
    return null;
  }

  /// One checkpoint entry from one wire row.
  ///
  /// The single place an entry is built for a business row, so both faces agree
  /// on what an entry *is* and differ only in which row they were handed. A
  /// shape this build cannot digest answers null, which leaves the caller's
  /// previous entry in place rather than inventing one.
  SyncCheckpointEntry? _businessEntryFromRow({
    required String kindWire,
    required Map<String, dynamic> row,
    String? directoryHash,
  }) {
    final clock = row['updated_at'];
    if (clock is! num) return null;
    final updatedAtUs = clock.toInt();
    if (kindWire == kSyncPreferenceWire) {
      final value = row['value'];
      if (value is! String) return null;
      return SyncCheckpointEntry(
        updatedAtUs: updatedAtUs,
        digest: businessContentDigest(value),
      );
    }
    final payload = row['payload'];
    final sortOrder = row['sort_order'];
    if (payload is! String || sortOrder is! num) return null;
    final payloadDigest = entityRowDigest(payload, sortOrder.toInt());
    if (kindWire != skillWire) {
      return SyncCheckpointEntry(
        updatedAtUs: updatedAtUs,
        digest: payloadDigest,
      );
    }
    return SyncCheckpointEntry(
      updatedAtUs: updatedAtUs,
      digest: combineSkillDigest(
        payloadDigest,
        directoryHash ?? missingSkillBody,
      ),
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

  // ---- workspace content (slice 18) ----

  /// This device's managed workspaces, with their content indexed (stat-only,
  /// off the UI isolate). Empty when this build has no workspace content
  /// support, which is what a conversation-only test constructs.
  Future<List<WorkspaceContentSnapshot>> workspaceSnapshots() async =>
      await workspaceContent?.snapshots() ?? const [];

  /// The file tables to advertise for [snapshots] — one entry per workspace this
  /// device shares, none for the rest — and how many shared workspaces the
  /// session's table cap dropped. The count is what the report needs: a dropped
  /// workspace is advertised as "not shared", so the peer silently plans nothing
  /// for it.
  ({SyncWorkspaceFileTables tables, int droppedWorkspaces}) workspaceTables(
    List<WorkspaceContentSnapshot> snapshots,
  ) =>
      workspaceContent?.tablesOf(snapshots) ??
      (tables: const {}, droppedWorkspaces: 0);

  /// Publishes [snapshots] as the files this device will serve [peerDeviceId]
  /// until the next publish — called before the beat in which that peer may
  /// fetch, so a file it decides it needs is one this device just advertised.
  void publishWorkspaceContent(
    String peerDeviceId,
    List<WorkspaceContentSnapshot> snapshots,
  ) => workspaceContent?.publish(peerDeviceId, snapshots);

  /// Drops the table this device advertised to [peerDeviceId]: the session that
  /// published it is over, so nothing it promised may still be served.
  void clearWorkspacePublication(String peerDeviceId) =>
      workspaceContent?.clearServed(peerDeviceId);

  /// Plans and applies this device's half of one session's workspace file
  /// exchange: what to fetch from the peer, what to delete here because the
  /// peer deleted it, and the ledger that records what both sides now hold.
  ///
  /// [allowDeletes] is false when the peer's database was bulk-replaced since
  /// the last session (a restore): its absences then prove nothing, so a file
  /// it lacks is re-offered rather than deleted here — the file face of the
  /// same rule the row plan applies.
  Future<WorkspaceContentOutcome> applyWorkspaceContent({
    required String myDeviceId,
    required String peerDeviceId,
    required List<WorkspaceContentSnapshot> mine,
    required SyncWorkspaceFileTables peerTables,
    required Map<String, Map<String, SyncAgreedFile>> ledger,
    required bool allowDeletes,
    WorkspaceFileFetcher? fetch,
  }) async {
    final content = workspaceContent;
    // No content support (conversation-only tests): the ledger is carried
    // through untouched rather than emptied, so a build without the feature
    // cannot make a build with it forget what it knew.
    if (content == null) return WorkspaceContentOutcome(ledger: ledger);
    return content.applyIncoming(
      myDeviceId: myDeviceId,
      peerDeviceId: peerDeviceId,
      mine: mine,
      peerTables: peerTables,
      ledger: ledger,
      allowDeletes: allowDeletes,
      fetch: fetch,
    );
  }

  // ---- blobs (slice 3) ----

  /// Directory hashes of every skill this device has a record for — the
  /// current baseline for skill-content planning.
  Future<Map<String, String>> skillDirHashes() async {
    final ids = await businessRepository.syncEntityIds(skillWire);
    return _directoryHashes(ids);
  }

  /// The blob manifest for exactly the rows about to travel: every
  /// `kelivo-file` URI they reference that this device can serve, plus one
  /// directory entry per skill record being sent.
  Future<List<SyncBlobEntry>> buildBlobManifest({
    required List<SyncSubtreePayload> subtrees,
    required SyncBusinessPayload business,
  }) async {
    final rows = <Map<String, dynamic>>[
      for (final subtree in subtrees) ...[
        subtree.conversation,
        ...subtree.messages,
        ...subtree.parts,
        ...subtree.mcpServers,
      ],
      for (final entityRows in business.entities.values) ...entityRows,
      ...business.preferences,
    ];
    final entries = await buildFileBlobEntries(
      kelivoFileUrisInRows(rows),
      fileHasher,
      resolve: blobPathResolver,
    );
    // One directory entry per skill record being sent: the receiver verifies
    // its re-hash against this value before swapping the directory in.
    final sentSkillIds = {
      for (final row in business.entities[skillWire] ?? const [])
        if (row['id'] is String) row['id'] as String,
    };
    if (sentSkillIds.isNotEmpty && skillDirectories != null) {
      final hashes = await _directoryHashes(sentSkillIds);
      for (final entry in hashes.entries) {
        entries.add(
          SyncBlobEntry(
            kind: SyncBlobEntry.kindSkillDir,
            key: entry.key,
            contentHash: entry.value,
          ),
        );
      }
    }
    return entries;
  }

  /// Which of the peer's file entries this device must still fetch.
  Future<List<SyncBlobEntry>> neededFileBlobs(List<SyncBlobEntry> entries) =>
      neededFileBlobEntries(entries, fileHasher, resolve: blobPathResolver);

  /// Removes rows of [skillIds] from an incoming business payload, so a skill
  /// whose body has not converged is deferred rather than installed broken.
  SyncBusinessPayload withoutSkillRows(
    SyncBusinessPayload payload,
    Set<String> skillIds,
  ) {
    if (skillIds.isEmpty) return payload;
    final entities = <String, List<Map<String, dynamic>>>{};
    for (final entry in payload.entities.entries) {
      if (entry.key != skillWire) {
        entities[entry.key] = entry.value;
        continue;
      }
      final kept = [
        for (final row in entry.value)
          if (!skillIds.contains(row['id'])) row,
      ];
      if (kept.isNotEmpty) entities[entry.key] = kept;
    }
    return SyncBusinessPayload(
      entities: entities,
      preferences: payload.preferences,
    );
  }

  /// Registers the file blobs a peer advertised for the revisions its push
  /// actually applied, so the asset registry owns them (GC protection and
  /// future dedupe). The registry is what makes the fetched file a first-class
  /// local asset rather than an orphan next to a message.
  ///
  /// Registration is scoped to [SyncSubtreeApplyOutcome.appliedRevisionIds]:
  /// the wire parts of a row the local copy beat describe references this
  /// device does not hold (replacing the set with them would unlink the
  /// winner's own attachments), and a revision that never landed here (a
  /// deferred conversation, a resolved version-group loser) would dangle
  /// against the revision foreign key and abort the session.
  ///
  /// Keyed off the advertised manifest rather than what landed: a blob whose
  /// pull failed still gets its reference now, so the retry that lands it in a
  /// later session — one that carries no subtree for this conversation — is
  /// already protected.
  ///
  /// Writing a reference is itself a change the chat window renders (a file
  /// that had none now resolves), and the message row it hangs off does not
  /// move, so the touched conversations are published the same way
  /// [applySubtrees] publishes its own.
  Future<void> registerLandedAssets({
    required List<SyncSubtreePayload> subtrees,
    required Map<String, SyncSubtreeApplyOutcome> outcomes,
    required Map<String, SyncBlobEntry> advertisedByUri,
  }) async {
    final allowed = {
      for (final entry in advertisedByUri.entries)
        if (entry.value.kind == SyncBlobEntry.kindFile &&
            isAllowedFileBlobUri(entry.key))
          entry.key: entry.value,
    };
    if (allowed.isEmpty) return;
    final touched = <String>{};
    for (final subtree in subtrees) {
      final conversationId = subtree.conversation['id'];
      if (conversationId is! String) continue;
      final revisions = outcomes[conversationId]?.appliedRevisionIds;
      if (revisions == null || revisions.isEmpty) continue;
      final byRevision = <String, List<({String uri, String kind})>>{};
      for (final part in subtree.parts) {
        final revisionId = part['revision_id'];
        final payload = part['payload'];
        if (revisionId is! String || payload is! String) continue;
        if (!revisions.contains(revisionId)) continue;
        final kind = (part['kind'] as String?) ?? 'file';
        for (final uri in kelivoFileUrisInRows([
          <String, dynamic>{'payload': payload},
        ])) {
          if (!allowed.containsKey(uri)) continue;
          byRevision.putIfAbsent(revisionId, () => []).add((
            uri: uri,
            kind: kind,
          ));
        }
      }
      for (final entry in byRevision.entries) {
        await repository.replaceMessageAssetReferences(
          conversationId: conversationId,
          revisionId: entry.key,
          assets: [
            for (final item in entry.value)
              MessageAssetRegistration(
                assetId: 'asset_${allowed[item.uri]!.contentHash}',
                contentHash: allowed[item.uri]!.contentHash,
                path: item.uri,
                byteSize: allowed[item.uri]!.byteSize,
                kind: item.kind,
              ),
          ],
        );
        touched.add(conversationId);
      }
    }
    if (touched.isNotEmpty) {
      await chatService.reloadAfterExternalChange(
        touchedConversations: touched,
      );
    }
  }

  /// Directory hashes for [ids], or an empty map when this device has no skill
  /// body support (conversation-only tests).
  Future<Map<String, String>> _directoryHashes(Set<String> ids) async {
    final dirs = skillDirectories;
    if (dirs == null || ids.isEmpty) return const {};
    await dirs.ensureRoot();
    return dirs.hashesOf(ids);
  }

  /// Extracts a received skill zip into a staging directory, verifies the
  /// re-hash and swaps it in. False means nothing was installed.
  Future<bool> applySkillBlob({
    required String skillId,
    required String dirHash,
    required File zip,
  }) async {
    final dirs = skillDirectories;
    if (dirs == null) return false;
    return dirs.applyZip(skillId: skillId, dirHash: dirHash, zip: zip);
  }

  /// The zip for one named skill, when its current directory hash still equals
  /// [dirHash]; null otherwise (it changed since the manifest was published).
  Future<File?> skillBlobForHash({
    required String skillId,
    required String dirHash,
  }) async {
    final dirs = skillDirectories;
    if (dirs == null) return null;
    final current = await dirs.hashOf(skillId);
    if (current == null || current != dirHash) return null;
    return dirs.zipToCache(skillId: skillId, dirHash: dirHash);
  }

  /// The zip for whichever local skill currently hashes to [contentHash] —
  /// what serves a blob pending from an earlier session, after a restart
  /// cleared the in-memory published set.
  Future<File?> skillBlobForContentHash(String contentHash) async {
    final dirs = skillDirectories;
    if (dirs == null) return null;
    final hashes = await skillDirHashes();
    for (final entry in hashes.entries) {
      if (entry.value == contentHash) {
        return dirs.zipToCache(skillId: entry.key, dirHash: contentHash);
      }
    }
    return null;
  }

  /// The file behind a content hash in the asset registry, or null when this
  /// device never registered that content.
  Future<File?> assetFileForContentHash(String contentHash) async {
    final path = await repository.assetPathForContentHash(contentHash);
    if (path == null) return null;
    final resolved = blobPathResolver(path);
    if (resolved == null) return null;
    final file = File(resolved);
    return await file.exists() ? file : null;
  }

  /// Drops the served-zip cache (reproducible from the live skill bodies).
  Future<void> clearSkillBlobCache() =>
      skillDirectories?.clearBlobCache() ?? Future<void>.value();
}

/// What one peer-driven business-row deletion did.
///
/// Three facts, not a bool, because two of them are independent: the *row* is
/// what the checkpoint advance and the manifest care about, and the *folder* is
/// what the user's switch cares about. A deletion that removed the row and left
/// the folder is a success on one face and a deliberate no-op on the other, and
/// the session report is the only place that can say so.
class BusinessRowDeleteOutcome {
  const BusinessRowDeleteOutcome({
    required this.removed,
    this.folderKept = false,
  });

  /// The row is gone locally (so the checkpoint may advance past it).
  final bool removed;

  /// The row was a managed workspace's, the user had content sync switched off
  /// for it, and its folder was therefore left on disk.
  final bool folderKept;
}
