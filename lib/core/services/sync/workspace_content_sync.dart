import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import '../../database/business_data.dart';
import '../../database/business_repository.dart';
import '../../models/workspace.dart';
import '../recycle/recycle_service.dart';
import 'sync_limits.dart';
import 'sync_merge.dart';
import 'sync_models.dart';
import 'sync_store.dart';
import 'workspace_content_index.dart';

/// Where one managed workspace's files live on *this* device.
///
/// Injected rather than read from `AppDirectories` so a two-device test can
/// host both peers in one process — the same seam `BlobPathResolver` and
/// `SkillDirectorySync`'s root already provide — and so this class never has to
/// know how the app lays its data directory out.
typedef WorkspaceRootResolver = Future<Directory> Function(String workspaceId);

/// Fetches one file from the peer into [destination]. Returns the bytes
/// written. Null (or a throw) means "nothing landed"; the caller keeps the
/// ledger entry and retries next session.
typedef WorkspaceFileFetcher =
    Future<int> Function(String workspaceId, String relPath, File destination);

/// One managed workspace as this device holds it, with its content index.
///
/// Built by [WorkspaceContentSync.snapshots] and reused for everything one
/// session does with workspace content — advertising, planning, serving — so a
/// session walks each workspace once (per side) instead of once per question.
class WorkspaceContentSnapshot {
  const WorkspaceContentSnapshot({
    required this.id,
    required this.name,
    required this.root,
    required this.enabled,
    required this.index,
  });

  final String id;
  final String name;

  /// Where this workspace's files live on this device, or null when even that
  /// could not be resolved (an unwritable app data directory, a full disk).
  /// Null is not "empty": the folder cannot be enumerated at all, which is why
  /// [shared] is false — and the row is still reported, because the panel has
  /// to be able to say "this one is not syncing".
  final Directory? root;

  /// Whether this device is willing to sync files for it (the panel's switch).
  final bool enabled;

  final WorkspaceContentIndex index;

  /// Whether this workspace's files may be advertised at all. Every condition
  /// is device-local and every one is a refusal to share: the folder could not
  /// be resolved or the walk could not read all of it (a table missing a file
  /// would tell the peer to delete that file), the user turned it off, or it is
  /// over the caps.
  bool get shared =>
      root != null && enabled && !index.truncated && !index.incomplete;
}

/// What one session's workspace content work did, from this device's own point
/// of view: what it fetched, what it deleted, what it lost and what it could
/// not apply.
class WorkspaceContentOutcome {
  const WorkspaceContentOutcome({
    this.ledger = const {},
    this.filesLanded = 0,
    this.bytesLanded = 0,
    this.filesRemoved = 0,
    this.filesReplaced = 0,
    this.filesMissing = 0,
    this.unlanded = const {},
    this.replacedUnlanded = const {},
    this.workspacesOmitted = 0,
  });

  /// The per-peer ledger for the next checkpoint (see
  /// [SyncCheckpoint.workspaceFiles]).
  final Map<String, Map<String, SyncAgreedFile>> ledger;

  final int filesLanded;
  final int bytesLanded;

  /// Local files deleted because the peer deleted them.
  final int filesRemoved;

  /// Local files whose own edit the peer's newer version replaced.
  final int filesReplaced;

  /// Files this device wanted but could not apply — a fetch that failed, or a
  /// deletion the filesystem refused. Both stay owed and are retried.
  final int filesMissing;

  /// The fetch-planned files behind [filesMissing], by workspace and path, with
  /// the version the peer advertised for each.
  ///
  /// This is what the push acknowledgement asks the initiator to push instead
  /// (slice 23). It is the *only* set of pairs this device will accept a write
  /// for: a request can name nothing that was not advertised in the push that
  /// produced it, and the bytes that arrive must match the stamp named here.
  final Map<String, Map<String, WorkspaceFileStamp>> unlanded;

  /// The serve keys inside [unlanded] whose plan action was
  /// [WorkspaceFileAction.peerWins] — a local edit this session means to
  /// replace, and could not.
  ///
  /// It has to travel with the request rather than be re-derived when the bytes
  /// arrive: the push landing is where the replacement actually happens, and
  /// `peerWins` promises the user it is "counted, never silent". Without this,
  /// the one case the fallback exists for — the conflict that had to travel the
  /// other way — would be the one the card did not mention.
  final Set<String> replacedUnlanded;

  /// Workspaces this device shared no content for, and why it could not: turned
  /// off, over the caps, or dropped by the advertised-table cap at the moment
  /// the tables were built (that last one is counted by the caller, which is
  /// where the drop happens).
  final int workspacesOmitted;
}

/// The workspace *content* plane for LAN sync (ADR-0003 slice 18).
///
/// The row side of a workspace is an ordinary business row; this is the folder
/// behind it, moved file by file. Three properties shape everything here:
///
/// * **Planning is stat-only.** A workspace's content is described by
///   path → (size, mtime) and nothing else; no byte is read to decide what
///   changed, and no hash is computed. The walk aborts the moment the caps are
///   passed, so a workspace that will not be transferred is never walked far.
/// * **Only *both* sides' sharing is enough.** A workspace one side did not
///   advertise is not planned at all — not pulled, not deleted. That is what
///   keeps "turned off here" and "over the caps there" from reading as "the
///   other device deleted these files".
/// * **A ledger entry only ever advances on demonstrated agreement.** An entry
///   that is missing is conservative in both directions, which is why the
///   send side never advances one: it cannot know whether the peer's fetch
///   landed, and claiming it did would turn the peer's next silence into a
///   deletion.
class WorkspaceContentSync {
  WorkspaceContentSync({
    required this.businessRepository,
    required this.store,
    required this.resolveRoot,
    this.recycle,
    this.maxFiles = kMaxWorkspaceFiles,
    this.maxBytes = kMaxWorkspaceBytes,
    this.maxLedgerEntries = kMaxWorkspaceLedgerEntries,
  });

  final BusinessRepository businessRepository;
  final SyncStore store;
  final WorkspaceRootResolver resolveRoot;

  /// The device-local recycle bin, when the app attached one.
  ///
  /// A file this round replaces or removes is staged here first: the version at
  /// that path is the only copy this device has of it, and a losing
  /// last-write-wins comparison is exactly the loss the bin exists for
  /// (ADR-0016). Null in every harness that has no bin, which is why both call
  /// sites fall back to the plain delete.
  final RecycleService? recycle;

  /// The per-workspace caps, as parameters only so a test can prove the abort
  /// without creating two thousand files. Production never passes them.
  final int maxFiles;
  final int maxBytes;

  /// The advertised-table and ledger cap, a parameter for the same reason: the
  /// drop only happens past twenty thousand file entries, and what a test has to
  /// prove is that a dropped workspace is *named* rather than silently unsynced.
  final int maxLedgerEntries;

  /// The wire name of the workspace entity kind — the single authority lives on
  /// `BusinessEntityKind`.
  static String get workspaceWire => BusinessEntityKind.workspace.wireName;

  /// What this device served, per peer and per file, for the table it last
  /// published to that peer. The route resolves a request through this map and
  /// nowhere else: a request never supplies a path that has not been walked and
  /// advertised first.
  final Map<String, Map<String, _ServedWorkspaceFile>> _served = {};

  // ---- this device's own content ----

  /// Every managed workspace this device holds, indexed.
  ///
  /// Linked workspaces are excluded by the same predicate the backup and the
  /// row face use ([isLinkedWorkspace]) — their folder is a fact about *this*
  /// machine, so it can neither travel nor be advertised.
  ///
  /// The index is built off the calling isolate (see
  /// [indexWorkspaceContent]), and a workspace whose directory cannot be read
  /// is still reported: the panel has to be able to say "this one is not
  /// syncing" rather than silently omit a row.
  Future<List<WorkspaceContentSnapshot>> snapshots() async {
    final disabled = await store.readWorkspaceContentDisabled();
    final ids = await businessRepository.syncEntityIds(workspaceWire);
    if (ids.isEmpty) return const [];
    final rows = await businessRepository.syncReadEntityRows(
      workspaceWire,
      ids,
    );
    final snapshots = <WorkspaceContentSnapshot>[];
    for (final row in rows) {
      final payload = row['payload'];
      if (payload is! String) continue;
      if (isLinkedWorkspace(payload)) continue;
      final id = row['id'];
      if (id is! String || id.isEmpty) continue;
      // A root that cannot be resolved is reported, not dropped: the walk
      // cannot enumerate it, so the index says it is incomplete — which is the
      // same refusal to share a partial tree that an unreadable directory gets,
      // and it is what lets the panel say "this one is not syncing" instead of
      // omitting the row entirely.
      final root = await _resolveRootOrNull(id);
      final index = root == null
          ? const WorkspaceContentIndex(
              <String, WorkspaceFileStamp>{},
              totalBytes: 0,
              incomplete: true,
            )
          : await indexWorkspaceContent(
              root.path,
              maxFiles: maxFiles,
              maxBytes: maxBytes,
            );
      snapshots.add(
        WorkspaceContentSnapshot(
          id: id,
          name: _nameOf(payload, fallback: id),
          root: root,
          enabled: !disabled.contains(id),
          index: index,
        ),
      );
    }
    return snapshots;
  }

  /// The file tables this device advertises to a peer, and how many shared
  /// workspaces the session cap dropped.
  ///
  /// The total is bounded ([kMaxWorkspaceLedgerEntries]) by dropping whole
  /// workspaces, deterministically by id. A dropped workspace is advertised as
  /// "not shared", which the peer reads as "no opinion" — the same treatment an
  /// over-cap workspace gets, and for the same reason. The count comes back with
  /// the tables because that is the only place the drop is known: a shared
  /// workspace this session advertises nothing for is a workspace the user
  /// believes is syncing and that no card would otherwise mention (see
  /// `SyncPeerReport.workspacesOmitted`).
  ({SyncWorkspaceFileTables tables, int droppedWorkspaces}) tablesOf(
    List<WorkspaceContentSnapshot> snapshots,
  ) {
    final shareable = [
      for (final snapshot in snapshots)
        if (snapshot.shared) snapshot,
    ]..sort((a, b) => a.id.compareTo(b.id));
    final tables = <String, SyncWorkspaceFileTable>{};
    var entries = 0;
    var dropped = 0;
    for (final snapshot in shareable) {
      if (entries + snapshot.index.files.length > maxLedgerEntries) {
        dropped++;
        continue;
      }
      entries += snapshot.index.files.length;
      tables[snapshot.id] = snapshot.index.files;
    }
    return (tables: tables, droppedWorkspaces: dropped);
  }

  /// Forgets what this device advertised to [peerDeviceId].
  ///
  /// Called when the session that published the table ends, and when the peer is
  /// unpaired. The table is a *session's* promise — "inside this session, these
  /// files are what I said I hold" — and a promise outliving the session that
  /// made it is what let a file be served to a later request on the strength of
  /// a walk taken before the user switched the workspace off.
  void clearServed(String peerDeviceId) {
    _served.remove(peerDeviceId);
  }

  /// Publishes [snapshots] as the set this device will serve to
  /// [peerDeviceId] until the next publish. Called before the beat in which
  /// that peer may fetch, so a file the peer decides it needs is always one
  /// this device just advertised.
  void publish(String peerDeviceId, List<WorkspaceContentSnapshot> snapshots) {
    final served = <String, _ServedWorkspaceFile>{};
    for (final snapshot in snapshots) {
      final root = snapshot.root;
      if (root == null || !snapshot.shared) continue;
      for (final entry in snapshot.index.files.entries) {
        served[serveKey(snapshot.id, entry.key)] = _ServedWorkspaceFile(
          file: File(p.joinAll([root.path, ...p.posix.split(entry.key)])),
          stamp: entry.value,
        );
      }
    }
    _served[peerDeviceId] = served;
  }

  /// The file behind one advertised `(workspace, path)`, or null when this
  /// device never advertised it — or advertised a version the file no longer
  /// is.
  ///
  /// The stamp check is the whole integrity story of this route: the bytes a
  /// peer receives are the bytes whose size and mtime it was told, or they are
  /// nothing. A file edited between the walk and the fetch is therefore a miss
  /// rather than a mislabelled transfer (the peer retries next session, when
  /// the new stamp has been advertised).
  Future<File?> serve({
    required String peerDeviceId,
    required String workspaceId,
    required String relPath,
  }) async {
    final served = _served[peerDeviceId]?[serveKey(workspaceId, relPath)];
    if (served == null) return null;
    try {
      final stat = await served.file.stat();
      if (stat.type != FileSystemEntityType.file) return null;
      if (stat.size != served.stamp.size) return null;
      if (stat.modified.millisecondsSinceEpoch != served.stamp.mtimeMs) {
        return null;
      }
      return served.file;
    } catch (error) {
      debugPrint(
        'sync workspace: serving $workspaceId/$relPath failed: $error',
      );
      return null;
    }
  }

  // ---- one session's transfers ----

  /// Plans and applies this device's half of the workspace content exchange.
  ///
  /// [mine] must be this device's snapshots as they stand for the session, and
  /// [peerTables] the tables the peer advertised. A workspace either side did
  /// not share produces no work at all.
  ///
  /// [allowDeletes] is false when the peer's database was bulk-replaced since
  /// the last session (a restore): its absences then prove nothing, so a file
  /// that is missing there is re-offered rather than deleted here — the file
  /// face of the same rule the row plan already applies.
  Future<WorkspaceContentOutcome> applyIncoming({
    required String myDeviceId,
    required String peerDeviceId,
    required List<WorkspaceContentSnapshot> mine,
    required SyncWorkspaceFileTables peerTables,
    required Map<String, Map<String, SyncAgreedFile>> ledger,
    required bool allowDeletes,
    WorkspaceFileFetcher? fetch,
  }) async {
    final processed = <String, Map<String, SyncAgreedFile>>{};
    var filesLanded = 0;
    var bytesLanded = 0;
    var filesRemoved = 0;
    var filesReplaced = 0;
    var filesMissing = 0;
    final unlanded = <String, Map<String, WorkspaceFileStamp>>{};
    final replacedUnlanded = <String>{};

    for (final snapshot in mine) {
      final peerTable = peerTables[snapshot.id];
      // Not both sides sharing it: nothing here is this device's business.
      // There is deliberately no "the peer shares it, so I must too" branch —
      // a workspace this device is not sharing is one whose files must not
      // move in either direction.
      if (peerTable == null || !snapshot.shared) continue;
      final baseline = ledger[snapshot.id] ?? const <String, SyncAgreedFile>{};
      final plan = planWorkspaceContent(
        mine: snapshot.index.files,
        peers: peerTable,
        baseline: baseline,
        myDeviceId: myDeviceId,
        peerDeviceId: peerDeviceId,
      );
      final landed = <String, WorkspaceFileStamp>{};
      final deleted = <String>{};
      for (final item in plan) {
        switch (item.action) {
          case WorkspaceFileAction.peerSends:
          case WorkspaceFileAction.peerWins:
            final advertised = peerTable[item.path];
            if (advertised == null) continue;
            final stamp = await _fetchOne(
              snapshot: snapshot,
              relPath: item.path,
              advertised: advertised,
              fetch: fetch,
            );
            if (stamp == null) {
              filesMissing++;
              // A fetch that did not happen is the one kind of miss a push can
              // repair, so it is recorded with the version to ask for. A delete
              // the filesystem refused is not: nothing the peer holds would fix
              // it, so it stays a plain miss and is retried here next session.
              (unlanded[snapshot.id] ??= {})[item.path] = advertised;
              // The replacement `peerWins` promises to count has not happened
              // yet — it happens if and when the push lands, and this is the
              // only place that knows the action was `peerWins`.
              if (item.action == WorkspaceFileAction.peerWins) {
                replacedUnlanded.add(serveKey(snapshot.id, item.path));
              }
              continue;
            }
            landed[item.path] = stamp;
            filesLanded++;
            bytesLanded += stamp.size;
            if (item.action == WorkspaceFileAction.peerWins) filesReplaced++;
          case WorkspaceFileAction.iDelete:
            if (!allowDeletes) continue;
            if (await _deleteOne(snapshot, item.path)) {
              deleted.add(item.path);
              filesRemoved++;
            } else {
              filesMissing++;
            }
          case WorkspaceFileAction.none:
          case WorkspaceFileAction.iSend:
          case WorkspaceFileAction.iWin:
          case WorkspaceFileAction.peerDeletes:
          case WorkspaceFileAction.bothDeleted:
            break;
        }
      }
      processed[snapshot.id] = advanceWorkspaceBaseline(
        mine: snapshot.index.files,
        peers: peerTable,
        baseline: baseline,
        plan: plan,
        landed: landed,
        deleted: deleted,
      );
    }

    // Entries are kept only for workspaces that still exist on one of the two
    // sides this session. Neither side sharing a workspace and this device no
    // longer holding its row means it is gone: keeping its file entries would
    // grow the checkpoint for the life of the pairing with nothing to describe.
    final live = <String>{
      for (final snapshot in mine) snapshot.id,
      ...peerTables.keys,
    };
    final next = <String, Map<String, SyncAgreedFile>>{};
    for (final id in live) {
      final current = processed[id] ?? ledger[id];
      if (current != null && current.isNotEmpty) next[id] = current;
    }

    var omitted = 0;
    for (final snapshot in mine) {
      if (!snapshot.shared) omitted++;
    }
    return WorkspaceContentOutcome(
      ledger: capWorkspaceLedger(next, maxEntries: maxLedgerEntries),
      filesLanded: filesLanded,
      bytesLanded: bytesLanded,
      filesRemoved: filesRemoved,
      filesReplaced: filesReplaced,
      filesMissing: filesMissing,
      unlanded: unlanded,
      replacedUnlanded: replacedUnlanded,
      workspacesOmitted: omitted,
    );
  }

  /// Lands one file the initiator pushed because this device could not fetch it
  /// (slice 23), and returns the stamp it now holds — or null when the write may
  /// not happen.
  ///
  /// The caller has already checked that this pair is one this session asked
  /// for and that the size matches the request; what is left here is the switch
  /// and the four landing gates, which are deliberately the *same* ones a pull
  /// goes through ([land]): a file arriving by push is not a different kind of
  /// file, and two landing paths would be two places for a containment rule to
  /// drift.
  ///
  /// The switch is re-read here rather than trusted from the push beat: a
  /// workspace the user turns off mid-session must stop being written to, the
  /// same way it stops being served.
  Future<WorkspaceFileStamp?> acceptPushed({
    required String workspaceId,
    required String relPath,
    required File staged,
    required WorkspaceFileStamp advertised,
  }) async {
    try {
      if ((await disabledWorkspaceIds()).contains(workspaceId)) {
        debugPrint(
          'sync workspace: refusing a push for $workspaceId/$relPath: the '
          'switch is off',
        );
        return null;
      }
      final root = await _resolveRootOrNull(workspaceId);
      if (root == null) return null;
      return await land(
        workspaceId: workspaceId,
        root: root,
        relPath: relPath,
        staged: staged,
        advertised: advertised,
      );
    } catch (error) {
      debugPrint(
        'sync workspace: landing the pushed $workspaceId/$relPath failed: '
        '$error',
      );
      return null;
    }
  }

  /// The ledger after files the initiator *pushed* landed here (slice 23).
  ///
  /// The lander advances an entry; the sender never does, because it cannot
  /// know whether its bytes arrived — that is the rule
  /// [advanceWorkspaceBaseline] states for a fetch, and a push is the same
  /// event seen from the other side. Both stamps are exact: `mine` is the file
  /// that just landed on this disk, `peer` is the version the initiator
  /// advertised when it was asked for it.
  ///
  /// Called once, at the fetch beat, where this side finalises the checkpoint
  /// the push beat started: a pushed file arrives *after* the push beat ran, so
  /// merging here rather than there is what keeps one writer per ledger.
  Map<String, Map<String, SyncAgreedFile>> ledgerWithPushed(
    Map<String, Map<String, SyncAgreedFile>> ledger,
    Map<String, Map<String, SyncAgreedFile>> pushed,
  ) {
    if (pushed.isEmpty) return ledger;
    final next = <String, Map<String, SyncAgreedFile>>{
      for (final entry in ledger.entries) entry.key: Map.of(entry.value),
    };
    for (final entry in pushed.entries) {
      next
          .putIfAbsent(entry.key, () => <String, SyncAgreedFile>{})
          .addAll(entry.value);
    }
    return capWorkspaceLedger(next, maxEntries: maxLedgerEntries);
  }

  /// Deletes a managed workspace's files — what a workspace row deleted *by
  /// sync* owes the disk. The row is what the UI shows, so leaving the folder
  /// behind would make a deletion invisible in the app and very visible in a
  /// file manager.
  Future<void> deleteContent(String workspaceId) async {
    try {
      final root = await resolveRoot(workspaceId);
      if (await root.exists()) await root.delete(recursive: true);
      // The workspace's own directory holds nothing but that files root.
      final parent = root.parent;
      if (await parent.exists() && await parent.list().isEmpty) {
        await parent.delete();
      }
    } catch (error) {
      debugPrint(
        'sync workspace $workspaceId: deleting its files failed: $error',
      );
    }
  }

  // ---- the panel's switch ----

  Future<Set<String>> disabledWorkspaceIds() =>
      store.readWorkspaceContentDisabled();

  /// Turns content sync for one workspace on or off. Returns whether the stored
  /// choice changed. The workspace *row* is untouched by this either way: the
  /// record always travels, because a row this device stops publishing would be
  /// read by the peer as a deletion (see `planRowSync`'s `peerDeletes`).
  ///
  /// The change goes through the store's serialized mutation rather than a read
  /// and a write here: the set is one file holding every workspace's choice, so
  /// two toggles landing at once — the panel's switch and a session's own read
  /// of the same file — must not be able to lose one of them. Turning one
  /// workspace off also drops the table this device advertised for the peer that
  /// just synced it: a switch flipped mid-session must not leave the old
  /// advertisement servable.
  Future<bool> setEnabled(String workspaceId, bool enabled) async {
    if (workspaceId.isEmpty) return false;
    final changed = await store.mutateWorkspaceContentDisabled((disabled) {
      if (enabled) return disabled.remove(workspaceId);
      return disabled.add(workspaceId);
    });
    if (changed && !enabled) {
      // The advertisement is per session, and this is the one caller that can
      // invalidate it while a session is still open.
      _served.clear();
    }
    return changed;
  }

  // ---- internals ----

  /// This workspace's files root, or null when the resolver refused (an
  /// unwritable app data directory, a full disk, an id the sink rejects).
  Future<Directory?> _resolveRootOrNull(String id) async {
    try {
      return await resolveRoot(id);
    } catch (error) {
      debugPrint('sync workspace $id: could not resolve its root: $error');
      return null;
    }
  }

  Future<WorkspaceFileStamp?> _fetchOne({
    required WorkspaceContentSnapshot snapshot,
    required String relPath,
    required WorkspaceFileStamp advertised,
    required WorkspaceFileFetcher? fetch,
  }) async {
    final fetcher = fetch;
    final root = snapshot.root;
    if (fetcher == null) {
      // No connection to the peer at all. Worth a line: without it, a session
      // whose whole file direction was unreachable reads exactly like a peer
      // that refused every file.
      debugPrint(
        'sync workspace ${snapshot.id}/$relPath: the peer could not be '
        'dialled back, so nothing can be fetched from it',
      );
      return null;
    }
    if (root == null) return null;
    File? temp;
    try {
      temp = await store.newBlobTempFile();
      await fetcher(snapshot.id, relPath, temp);
      return await land(
        workspaceId: snapshot.id,
        root: root,
        relPath: relPath,
        staged: temp,
        advertised: advertised,
      );
    } catch (error) {
      debugPrint('sync workspace file ${snapshot.id}/$relPath failed: $error');
      return null;
    } finally {
      try {
        if (temp != null && await temp.exists()) await temp.delete();
      } catch (_) {}
    }
  }

  /// Moves a staged file into the workspace, or returns null when it may not go
  /// there. The one landing path: a fetched file and a pushed one differ only
  /// in which side asked for the transfer.
  ///
  /// Four gates, in order: the path must be a legal workspace-relative one, it
  /// must join to a target inside the root, the directory it lands in must
  /// *really* be inside the root (a symlinked directory in the tree would
  /// otherwise redirect the write out of it), and the landed size must be the
  /// advertised one. The mtime is then set from the peer's, best effort: it is
  /// what the user sees in a file manager, and a filesystem that rounds it does
  /// not break convergence because the ledger remembers both sides' stamps.
  Future<WorkspaceFileStamp?> land({
    required String workspaceId,
    required Directory root,
    required String relPath,
    required File staged,
    required WorkspaceFileStamp advertised,
  }) async {
    final target = workspacePathWithin(root.path, relPath);
    if (target == null) {
      debugPrint('sync workspace: refusing an unsafe path "$relPath"');
      return null;
    }
    final file = File(target);
    try {
      // Containment is verified *before* anything is created: `create` follows
      // a symlinked ancestor, so creating first and checking afterwards would
      // already have made the directory on the far side of the link.
      final existing = await nearestExistingAncestor(file.parent);
      if (!await isReallyInsideWorkspace(root, existing)) {
        debugPrint('sync workspace: refusing "$relPath": it leaves the root');
        return null;
      }
      await file.parent.create(recursive: true);
      // Verified *before* the destination is touched. The version already at this
      // path is, at this moment, the only copy this device has of the file — a
      // refusal that had already deleted it left the path empty, and the next
      // session re-fetches a file this device never lost. What the rename would
      // publish is the staged file, so that is what is checked.
      final stagedLength = await staged.length();
      if (stagedLength != advertised.size) {
        // The bytes are not the version that was advertised: a file edited while
        // it streamed. Nothing here can tell which byte is which, so the transfer
        // is refused and the next session re-fetches it.
        debugPrint(
          'sync workspace: refusing to land "$relPath": $stagedLength bytes '
          'staged, ${advertised.size} advertised',
        );
        return null;
      }
      if (await file.exists()) {
        // Staging *moves* the version at this path into the bin, which both
        // keeps it and frees the path — so the rename below needs no delete at
        // all. It runs only here, after every gate and the size check: a landing
        // that is refused must not leave a copy of a file nothing replaced.
        //
        // The fallback below is for the staging that did not move anything (an
        // unwritable bin, a file another process holds): the file is still at
        // the path, and the rename needs it gone. When the move *did* happen but
        // neither the entry nor the put-back did, there is nothing left to
        // delete — the path is already free — so the `exists()` check is what
        // keeps the two cases apart rather than a second guess about the failure.
        final preserved = await recycle?.stageWorkspaceFile(
          workspaceId: workspaceId,
          relPath: relPath,
          source: file,
          origin: RecycleOrigin.remote,
          reason: RecycleReason.overwritten,
        );
        if (preserved == null && await file.exists()) await file.delete();
      }
      final landed = await staged.rename(target);
      try {
        await landed.setLastModified(
          DateTime.fromMillisecondsSinceEpoch(advertised.mtimeMs),
        );
      } catch (error) {
        debugPrint('sync workspace: could not stamp "$relPath": $error');
      }
      final stat = await landed.stat();
      if (stat.size != advertised.size) {
        // Belt to the check above: something wrote this path between the rename
        // and the stat. The bytes that landed are not the version asked for, so
        // they are removed rather than left as a half-advertised file.
        await _deleteQuietly(landed);
        return null;
      }
      return WorkspaceFileStamp(
        size: stat.size,
        mtimeMs: stat.modified.millisecondsSinceEpoch,
      );
    } catch (error) {
      debugPrint('sync workspace: landing "$relPath" failed: $error');
      return null;
    }
  }

  Future<bool> _deleteOne(
    WorkspaceContentSnapshot snapshot,
    String relPath,
  ) async {
    final root = snapshot.root;
    if (root == null) return false;
    final target = workspacePathWithin(root.path, relPath);
    if (target == null) return false;
    try {
      final type = await FileSystemEntity.type(target, followLinks: false);
      if (type == FileSystemEntityType.notFound) return true;
      // A directory where the peer had a file is not this device's to remove:
      // it may be a real folder the user made since, and deleting it would
      // take its contents with it.
      if (type != FileSystemEntityType.file) return false;
      // The peer removed this file and its bytes are about to leave the disk:
      // staged first for the same reason a replacement is, and awaited rather
      // than detached, because the move has to finish before this session
      // records the path as deleted. A staging that moved nothing still deletes —
      // the removal is what the peer asked for, and refusing it would only
      // re-offer the same file next session — and a staging that moved the file
      // but could not publish an entry hands it back, so the `exists()` check is
      // what says whether there is anything left to remove.
      final preserved = await recycle?.stageWorkspaceFile(
        workspaceId: snapshot.id,
        relPath: relPath,
        source: File(target),
        origin: RecycleOrigin.remote,
        reason: RecycleReason.deleted,
      );
      if (preserved == null && await File(target).exists()) {
        await File(target).delete();
      }
      await _pruneEmptyParents(root, File(target).parent);
      return true;
    } catch (error) {
      debugPrint('sync workspace: deleting "$relPath" failed: $error');
      return false;
    }
  }

  /// Removes the directories a deletion emptied, up to (but never including)
  /// the workspace root. Best effort: an empty directory left behind is
  /// cosmetic, and failing the delete over it would be worse.
  Future<void> _pruneEmptyParents(Directory root, Directory from) async {
    final rootPath = p.canonicalize(root.path);
    var current = from;
    while (p.canonicalize(current.path) != rootPath) {
      try {
        if (!p.isWithin(rootPath, p.canonicalize(current.path))) return;
        if (!await current.exists()) break;
        final children = await current.list(followLinks: false).toList();
        if (children.isNotEmpty) return;
        await current.delete();
      } catch (_) {
        return;
      }
      final parent = current.parent;
      if (p.equals(parent.path, current.path)) return;
      current = parent;
    }
  }

  static Future<void> _deleteQuietly(File file) async {
    try {
      if (await file.exists()) await file.delete();
    } catch (_) {}
  }

  /// The identity of one `(workspace, path)` pair inside this class's served
  /// table and inside the engine's per-session upload requests. One authority
  /// because the two must agree exactly: a key that differed by a byte would
  /// make a requested file unwritable.
  static String serveKey(String workspaceId, String relPath) =>
      '$workspaceId\u0000$relPath';

  /// The workspace's display name from its row payload, falling back to the id
  /// when the payload cannot be read: a half-written row must not blank the
  /// panel's row for it.
  static String _nameOf(String payload, {required String fallback}) {
    try {
      final workspace = Workspace.fromJson(
        jsonDecode(payload) as Map<String, dynamic>,
      );
      return workspace.name.isEmpty ? fallback : workspace.name;
    } catch (_) {
      return fallback;
    }
  }
}

/// One file this device advertised to one peer, with the stamp it advertised.
class _ServedWorkspaceFile {
  const _ServedWorkspaceFile({required this.file, required this.stamp});

  final File file;
  final WorkspaceFileStamp stamp;
}
