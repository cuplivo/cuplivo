import 'dart:io';

import '../../database/business_data.dart';
import '../../database/business_preferences.dart';
import '../../database/business_repository.dart';
import '../../database/chat_database_repository.dart';
import '../chat/chat_service.dart';
import '../skills/skill_directory_sync.dart';
import 'blob_sync.dart';
import 'business_state_reloader.dart';
import 'sync_merge.dart';
import 'sync_models.dart';

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
  /// The conversations that actually changed ride along with the reload: they
  /// are what tells an open window to rebuild, instead of leaving the user
  /// reading pre-sync content until they switch conversations and back.
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
      if (!outcome.deferred &&
          (outcome.upsertedMessages > 0 ||
              outcome.deletedMessages > 0 ||
              outcome.conversationRowChanged)) {
        touched.add(conversationId);
      }
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
  /// its record: a row-less directory would be resurrected as a fresh record by
  /// the skills rescan, and a directory-less row installs a broken skill.
  ///
  /// The delete rides the same serialized write queue as applies and local
  /// entity edits (ADR-0003): a provider's whole-list read-modify-write must
  /// not interleave with a sync deletion either, or it re-inserts the row the
  /// checkpoint entry already dropped.
  Future<bool> deleteBusinessRow(String kindWire, String id) async {
    Future<bool> delete() async {
      if (kindWire == kSyncPreferenceWire) {
        return businessRepository.syncDeletePreference(id);
      }
      final removed = await businessRepository.syncDeleteEntity(kindWire, id);
      if (removed && kindWire == skillWire) {
        await skillDirectories?.deleteDirectory(id);
      }
      return removed;
    }

    final preferences = businessPreferences;
    return preferences == null
        ? await delete()
        : await preferences.serializeExternalWrite(delete);
  }

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
    final payloadDigest = entityRowDigest(
      rows.first['payload'] as String,
      (rows.first['sort_order'] as num).toInt(),
    );
    if (kindWire != skillWire) {
      return SyncCheckpointEntry(
        updatedAtUs: (rows.first['updated_at'] as num).toInt(),
        digest: payloadDigest,
      );
    }
    final dirHash = (await _directoryHashes({id}))[id] ?? missingSkillBody;
    return SyncCheckpointEntry(
      updatedAtUs: (rows.first['updated_at'] as num).toInt(),
      digest: combineSkillDigest(payloadDigest, dirHash),
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
      }
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
