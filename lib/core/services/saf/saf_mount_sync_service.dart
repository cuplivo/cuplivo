import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:path/path.dart' as p;
import 'package:Cuplivo/core/database/business_preferences.dart';
import 'package:uuid/uuid.dart';

import '../../models/workspace.dart';
import '../../providers/workspace_provider.dart';
import '../mcp/kelivo_filesystem/kelivo_filesystem_server.dart';
import '../workspace/workspace_terminal_native_bridge.dart';
import '../../../utils/app_directories.dart';

enum SafMountStatus {
  /// No round running; last round succeeded (or none ran yet).
  idle,

  /// A sync round is in flight.
  syncing,

  /// The SAF grant is gone (permission revoked / storage unmounted / the URI
  /// was restored from a backup onto another device). The mirror and all
  /// local changes are preserved; nothing is deleted or pushed.
  unavailable,

  /// The last round failed with a transient error; the next trigger retries.
  error,
}

class SafMountState {
  final SafMountStatus status;
  final String? lastError;
  final DateTime? lastSyncAt;

  const SafMountState({
    this.status = SafMountStatus.idle,
    this.lastError,
    this.lastSyncAt,
  });

  SafMountState copyWith({
    SafMountStatus? status,
    String? lastError,
    bool clearError = false,
    DateTime? lastSyncAt,
  }) => SafMountState(
    status: status ?? this.status,
    lastError: clearError ? null : (lastError ?? this.lastError),
    lastSyncAt: lastSyncAt ?? this.lastSyncAt,
  );
}

/// A directory entry as reported by the native SAF bridge.
class SafEntry {
  final String name;
  final bool isDirectory;
  final int? lastModifiedMs;
  final int? size;
  final String uri;

  const SafEntry({
    required this.name,
    required this.isDirectory,
    required this.uri,
    this.lastModifiedMs,
    this.size,
  });
}

/// Native SAF bridge (`cuplivo/saf_mount`). Methods are virtual so tests can
/// substitute a fake implementation.
class SafChannel {
  SafChannel() : _channel = const MethodChannel('cuplivo/saf_mount');

  static const Duration callTimeout = Duration(seconds: 30);

  final MethodChannel _channel;

  /// Launches ACTION_OPEN_DOCUMENT_TREE and persists the read/write grant.
  /// Returns `{uri, displayName}` or null when the user cancelled.
  Future<Map<String, dynamic>?> pickTree() async {
    final map = await _channel.invokeMethod<Map>('pickTree');
    return map?.cast<String, dynamic>();
  }

  Future<List<Map<String, dynamic>>> list(String uri) async {
    final raw = await _channel.invokeMethod<List>('list', {'uri': uri});
    return (raw ?? const <dynamic>[])
        .whereType<Map>()
        .map((e) => e.cast<String, dynamic>())
        .toList();
  }

  Future<void> copyToPath(String uri, String targetPath) async {
    await _channel.invokeMethod<void>('copyToPath', {
      'uri': uri,
      'targetPath': targetPath,
    });
  }

  Future<void> copyFromPath(String uri, String sourcePath) async {
    await _channel.invokeMethod<void>('copyFromPath', {
      'uri': uri,
      'sourcePath': sourcePath,
    });
  }

  Future<String> createFile(String parentUri, String name) async {
    final uri = await _channel.invokeMethod<String>('createFile', {
      'parentUri': parentUri,
      'name': name,
    });
    if (uri == null) throw StateError('createFile returned null');
    return uri;
  }

  Future<String> mkdir(String parentUri, String name) async {
    final uri = await _channel.invokeMethod<String>('mkdir', {
      'parentUri': parentUri,
      'name': name,
    });
    if (uri == null) throw StateError('mkdir returned null');
    return uri;
  }

  Future<bool> delete(String uri) async {
    final ok = await _channel.invokeMethod<bool>('delete', {'uri': uri});
    return ok == true;
  }

  Future<bool> checkAccess(String uri) async {
    final ok = await _channel.invokeMethod<bool>('checkAccess', {'uri': uri});
    return ok == true;
  }

  /// Wraps [action] with a bounded timeout so a hung DocumentsProvider can
  /// never wedge a sync round forever.
  Future<T> withTimeout<T>(Future<T> Function() action) =>
      action().timeout(callTimeout);
}

/// Owns Android SAF mounts: config persistence, mirror locations, the
/// bidirectional mirror-sync engine, lifecycle triggers and the guest bind
/// list for the Linux sandbox.
///
/// Sync semantics (ADR-0037):
/// - Three-state merge by mtime+size; last-writer-wins, mtime ties resolved
///   to the mirror side (deterministic, documented).
/// - Deletions propagate BOTH ways, gated by a `.state/<alias>.json` snapshot
///   (a path must have existed at the last completed round before either side
///   deleting it counts as a deletion).
/// - Whole-tree-gone guard: an empty SAF side while the snapshot and the
///   mirror both disagree never propagates deletions (unmounted SD card /
///   revoked grant) — the round is aborted instead.
/// - A failed SAF access marks the mount `unavailable`; nothing is deleted
///   or pushed while unavailable, and the mirror keeps all local changes.
class SafMountSyncService extends ChangeNotifier with WidgetsBindingObserver {
  static const String legacyPrefsKey = 'saf_mounts_v1';
  static const String errorAliasInvalid = 'alias_invalid';
  static const String errorAliasReserved = 'alias_reserved';
  static const String errorAliasDuplicate = 'alias_duplicate';
  static const String errorUriDuplicate = 'uri_duplicate';
  static const String errorUnsupported = 'unsupported';
  static const String errorTerminalStopFailed = 'terminal_stop_failed';

  static const Duration mutationDebounce = Duration(milliseconds: 500);
  static const Duration foregroundPollInterval = Duration(seconds: 60);
  static const Duration resumeDebounce = Duration(seconds: 1);

  /// Overridable platform gate so tests can exercise the Android code path
  /// on any host.
  static bool Function() androidProbe = () => Platform.isAndroid;

  /// mtime tolerance for the "same entry" comparison: SAF providers report
  /// second-resolution mtimes in practice, so a few hundred ms of jitter
  /// must not count as a change.
  static const Duration mtimeTolerance = Duration(milliseconds: 1500);

  final WorkspaceProvider workspaces;
  final Future<void> Function(String workspaceId) _stopWorkspaceTerminal;
  final Map<String, SafMountState> _states = <String, SafMountState>{};
  final Set<String> _running = <String>{};
  final Map<String, Timer> _debounceTimers = <String, Timer>{};
  Set<String> _knownMountIds = <String>{};
  Timer? _pollTimer;
  bool _loaded = false;
  Future<void>? _initFuture;
  late String _mirrorsRoot;
  late String _stateRoot;

  SafChannel channel;

  SafMountSyncService({
    required this.workspaces,
    required this.preferences,
    SafChannel? channel,
    Future<void> Function(String workspaceId)? stopWorkspaceTerminal,
  }) : channel = channel ?? SafChannel(),
       _stopWorkspaceTerminal =
           stopWorkspaceTerminal ??
           WorkspaceTerminalNativeBridge.instance.stopSession {
    unawaited(init());
  }

  final BusinessPreferences preferences;

  bool get loaded => _loaded;

  List<WorkspaceSafMount> get _allEntries => [
    for (final workspace in workspaces.workspaces) ...workspace.safMounts,
  ];

  List<WorkspaceSafMount> entriesFor(String workspaceId) {
    if (!_loaded || !androidProbe()) return const <WorkspaceSafMount>[];
    return List<WorkspaceSafMount>.unmodifiable(
      workspaces.getById(workspaceId)?.safMounts ?? const <WorkspaceSafMount>[],
    );
  }

  WorkspaceSafMount? entryById(String mountId) =>
      _allEntries.where((e) => e.id == mountId).firstOrNull;

  WorkspaceSafMount? entryByAlias(String workspaceId, String alias) =>
      entriesFor(workspaceId).where((e) => e.alias == alias).firstOrNull;

  List<FilesystemMount> mountsFor(String workspaceId) {
    return [
      for (final e in entriesFor(workspaceId))
        FilesystemMount(
          alias: e.alias,
          path: mirrorPathFor(e.id),
          readOnly: false,
          uri: e.uri,
        ),
    ];
  }

  SafMountState stateOf(String mountId) =>
      _states[mountId] ?? const SafMountState();

  /// proot bind payloads (`{host, guest, readOnly}`) for the Linux sandbox
  /// shell and the Workspace Terminal. Guests land under the reserved
  /// `/workspace/.mounts/<alias>` directory (ADR-0037). SAF binds are always
  /// writable; the owning workspace's enabled tools are the permission layer.
  List<Map<String, Object?>> guestBindsFor(String workspaceId) {
    return [
      for (final e in entriesFor(workspaceId))
        {
          'host': mirrorPathFor(e.id),
          'guest': '/workspace/.mounts/${e.alias}',
          'readOnly': false,
        },
    ];
  }

  String mirrorPathFor(String mountId) => p.join(_mirrorsRoot, mountId);

  String statePathFor(String mountId) => p.join(_stateRoot, '$mountId.json');

  Future<void> init() {
    if (_loaded) return Future.value();
    return _initFuture ??= _doInit();
  }

  Future<void> _doInit() async {
    await workspaces.init();
    if (androidProbe()) {
      try {
        WidgetsBinding.instance.addObserver(this);
      } catch (_) {
        // Headless tests without a binding: lifecycle triggers stay inert.
      }
    }
    final mirrors = await AppDirectories.getSafMountsDirectory();
    final stateDir = await AppDirectories.getSafMountStateDirectory();
    _mirrorsRoot = mirrors.path;
    _stateRoot = stateDir.path;
    await _clearLegacyGlobalMountsIfNeeded();
    if (androidProbe()) {
      try {
        await stateDir.create(recursive: true);
      } catch (e) {
        debugPrint('SafMountSyncService: state dir create failed: $e');
      }
    }
    _knownMountIds = androidProbe()
        ? _allEntries.map((e) => e.id).toSet()
        : <String>{};
    workspaces.addListener(_onWorkspacesChanged);
    await _ensureMirrorDirs();
    _loaded = true;
    notifyListeners();
  }

  Future<void> _clearLegacyGlobalMountsIfNeeded() async {
    if (!preferences.containsKey(legacyPrefsKey)) return;
    try {
      final root = Directory(_mirrorsRoot);
      if (await root.exists()) await root.delete(recursive: true);
    } catch (e) {
      debugPrint('SafMountSyncService: legacy mirror cleanup failed: $e');
    }
    await preferences.remove(legacyPrefsKey);
  }

  Future<void> reloadAfterRestore() async {
    await init();
    await _clearLegacyGlobalMountsIfNeeded();
    _onWorkspacesChanged();
    await _ensureMirrorDirs();
    await syncAll();
  }

  void _onWorkspacesChanged() {
    if (!_loaded || !androidProbe()) return;
    final current = _allEntries.map((e) => e.id).toSet();
    final removed = _knownMountIds.difference(current);
    final added = current.difference(_knownMountIds);
    _knownMountIds = current;
    for (final id in removed) {
      unawaited(_cleanupMount(id));
    }
    for (final id in added) {
      unawaited(Directory(mirrorPathFor(id)).create(recursive: true));
    }
    notifyListeners();
  }

  Future<void> _ensureMirrorDirs() async {
    if (!androidProbe()) return;
    for (final e in _allEntries) {
      try {
        await Directory(mirrorPathFor(e.id)).create(recursive: true);
      } catch (err) {
        debugPrint(
          'SafMountSyncService: failed to create mirror for '
          '${e.alias}: $err',
        );
      }
    }
  }

  /// Launches the SAF directory picker (user grants read/write). Returns
  /// `{uri, displayName}` or null when cancelled.
  ///
  /// Deliberately NOT wrapped in [SafChannel.withTimeout]: the picker is an
  /// interactive full-screen browser that can legitimately stay open for
  /// minutes; a timeout would drop the result while the native side still
  /// holds the pending reply (the grant is persisted but the UI never hears
  /// about it).
  Future<Map<String, dynamic>?> pickTree() async {
    await init();
    if (!androidProbe()) return null;
    return channel.pickTree();
  }

  /// Returns null on success or an error code for the UI to localize.
  Future<String?> addMount({
    required String workspaceId,
    required String alias,
    required String uri,
    required String displayName,
  }) async {
    await init();
    if (!androidProbe()) return errorUnsupported;
    final workspace = workspaces.getById(workspaceId);
    if (workspace == null) return errorAliasReserved;
    final trimmed = alias.trim();
    if (!isValidMountAlias(trimmed)) return errorAliasInvalid;
    if (trimmed == workspace.alias) return errorAliasReserved;
    if (workspace.safMounts.any((e) => e.alias == trimmed)) {
      return errorAliasDuplicate;
    }
    final trimmedUri = uri.trim();
    if (_allEntries.any((e) => e.uri == trimmedUri)) {
      return errorUriDuplicate;
    }
    try {
      await _stopWorkspaceTerminal(workspaceId);
    } catch (error, stackTrace) {
      debugPrint(
        'SafMountSyncService: failed to stop terminal before addMount: '
        '$error\n$stackTrace',
      );
      return errorTerminalStopFailed;
    }
    final entry = WorkspaceSafMount(
      id: const Uuid().v4(),
      alias: trimmed,
      uri: trimmedUri,
      displayName: displayName.trim(),
    );
    try {
      await Directory(mirrorPathFor(entry.id)).create(recursive: true);
    } catch (e) {
      debugPrint('SafMountSyncService: mirror create failed: $e');
      return errorAliasInvalid;
    }
    try {
      await workspaces.addSafMount(workspaceId, entry);
    } catch (e) {
      await _cleanupMount(entry.id);
      debugPrint('SafMountSyncService: persist failed after add: $e');
      rethrow;
    }
    // Initial full pull completes before addMount returns: the caller's UI
    // sees a converged mirror, and tests get deterministic sequencing.
    await syncNow(entry.id);
    return null;
  }

  Future<void> removeMount(String workspaceId, String mountId) async {
    await init();
    final ownsMount = workspaces
        .getById(workspaceId)
        ?.safMounts
        .any((entry) => entry.id == mountId);
    if (ownsMount != true) return;
    await _stopWorkspaceTerminal(workspaceId);
    _knownMountIds.remove(mountId);
    await workspaces.removeSafMount(workspaceId, mountId);
    await _cleanupMount(mountId);
    notifyListeners();
  }

  Future<void> _cleanupMount(String mountId) async {
    _states.remove(mountId);
    _debounceTimers.remove(mountId)?.cancel();
    try {
      final mirror = Directory(mirrorPathFor(mountId));
      if (await mirror.exists()) await mirror.delete(recursive: true);
    } catch (e) {
      debugPrint('SafMountSyncService: mirror cleanup failed for $mountId: $e');
    }
    try {
      final state = File(statePathFor(mountId));
      if (await state.exists()) await state.delete();
    } catch (e) {
      debugPrint('SafMountSyncService: state cleanup failed for $mountId: $e');
    }
  }

  /// Called by the filesystem engine after an AI tool mutated a mount —
  /// schedules a debounced push round for SAF mounts.
  void notifyMutated(String workspaceId, String alias) {
    final entry = entryByAlias(workspaceId, alias);
    if (entry == null) return;
    _debounceTimers.remove(entry.id)?.cancel();
    _debounceTimers[entry.id] = Timer(mutationDebounce, () {
      _debounceTimers.remove(entry.id);
      unawaited(syncNow(entry.id));
    });
  }

  Future<void> syncAll() async {
    await init();
    if (!androidProbe()) return;
    final mountIds = _allEntries.map((e) => e.id).toList();
    for (final mountId in mountIds) {
      await syncNow(mountId);
    }
  }

  Future<void> syncNow(String mountId) async {
    await init();
    if (!androidProbe()) return;
    final entry = entryById(mountId);
    if (entry == null || !_running.add(mountId)) return;
    try {
      final state = stateOf(mountId);
      _states[mountId] = state.copyWith(
        status: SafMountStatus.syncing,
        clearError: true,
      );
      notifyListeners();
      try {
        final deleteFailed = await _syncRound(entry);
        if (deleteFailed) {
          // The provider persistently refused a delete (no exception): the
          // snapshot entry is retained and the next round retries — but the
          // UI must not claim "Synced" while a deletion never lands.
          _states[mountId] = _states[mountId]!.copyWith(
            status: SafMountStatus.error,
            lastError: 'SAF delete failed; will retry',
          );
        } else {
          _states[mountId] = _states[mountId]!.copyWith(
            status: SafMountStatus.idle,
            lastSyncAt: DateTime.now(),
          );
        }
      } on SafAccessException catch (e) {
        debugPrint('SafMountSyncService: ${entry.alias} unavailable: $e');
        _states[mountId] = _states[mountId]!.copyWith(
          status: SafMountStatus.unavailable,
          lastError: e.message,
        );
      } catch (e) {
        debugPrint('SafMountSyncService: sync failed for ${entry.alias}: $e');
        _states[mountId] = _states[mountId]!.copyWith(
          status: SafMountStatus.error,
          lastError: e.toString(),
        );
      } finally {
        notifyListeners();
      }
    } finally {
      _running.remove(mountId);
    }
  }

  // =====================================================================
  // Sync engine
  // =====================================================================

  static bool _isAccessError(Object e) {
    if (e is PlatformException) {
      return e.code == 'access_denied' ||
          e.code == 'access_failed' ||
          e.code == 'uri_not_found';
    }
    return false;
  }

  /// Runs one full two-way merge round. Returns true when a SAF-side delete
  /// was persistently refused (the round completed, but a deletion never
  /// landed and the snapshot entry was retained for retry).
  Future<bool> _syncRound(WorkspaceSafMount entry) async {
    final uri = entry.uri;
    final mirrorRoot = Directory(mirrorPathFor(entry.id));
    // The mount may have been removed while this round was queued behind the
    // execution lock (removeMount does not cancel in-flight rounds). If it is
    // gone, abort BEFORE touching the mirror or the SAF side — the mirror
    // directory may already be deleted, and pass 3 would otherwise misread
    // the missing mirror content as "deleted in the mirror" and delete the
    // user's real files.
    if (entryById(entry.id) == null) return false;
    await mirrorRoot.create(recursive: true);

    final snapshot = await _readSnapshot(entry.id);

    bool accessOk;
    try {
      accessOk = await channel.withTimeout(() => channel.checkAccess(uri));
    } catch (e) {
      throw SafAccessException('SAF grant unavailable: $e');
    }
    if (!accessOk) {
      throw SafAccessException('SAF grant revoked or storage unmounted');
    }

    Map<String, SafEntry> safTree;
    try {
      safTree = await channel.withTimeout(() => _listSafTree(uri));
    } on PlatformException catch (e) {
      if (_isAccessError(e)) throw SafAccessException(e.message ?? e.code);
      rethrow;
    }

    // Whole-tree-gone guard: the SAF side lists empty while the previous
    // snapshot knew content. An unmounted volume (SD card) typically reports
    // an empty tree — treating it as deletions would wipe snapshot-known
    // mirror files, INCLUDING AI edits never pushed. Abort instead; nothing
    // real is lost (files re-pull after remount), and a genuinely emptied
    // folder can be re-mounted to start fresh.
    if (snapshot.isNotEmpty && safTree.isEmpty) {
      throw SafAccessException(
        'SAF tree listed empty while the previous snapshot knew content — '
        'storage likely unmounted; aborting round',
      );
    }

    final mirrorTree = await _listMirrorTree(mirrorRoot);
    final next = <String, _StatSnapshot>{};
    var deleteFailed = false;
    // URIs of directories created on the SAF side during THIS round, so
    // child pushes find their parents without re-walking the whole tree.
    final createdSafDirs = <String, String>{};

    // Pass 1: entries present on the SAF side.
    for (final rel in safTree.keys.toList()) {
      final saf = safTree[rel];
      if (saf == null) continue;
      final mir = mirrorTree[rel];
      if (saf.isDirectory) {
        final target = Directory(p.join(mirrorRoot.path, rel));
        final mirrorHasFile = await File(target.path).exists();
        if (mirrorHasFile) {
          // Type conflict: mirror has a FILE where SAF has a directory. The
          // newer side wins (LWW): if the mirror file is newer, push it
          // (deletes the SAF dir, creates the file); otherwise the SAF dir
          // wins and the conflicting file is removed so the dir can exist.
          final mir = mirrorTree[rel];
          final safM = saf.lastModifiedMs ?? 0;
          final mirM = mir?.lastModifiedMs ?? 0;
          if (mirM > safM) {
            final updated = await _pushMirrorAndAlign(
              entry,
              saf,
              mirrorRoot,
              rel,
              safTree,
              createdSafDirs,
            );
            next[rel] = updated;
            continue;
          }
          try {
            await File(target.path).delete();
          } catch (e) {
            debugPrint('SafMountSyncService: conflict file delete failed: $e');
          }
        }
        if (!await target.exists()) {
          if (snapshot.containsKey(rel)) {
            // Pending mirror-side deletion (ADR-0037): pass 3 removes the
            // SAF side; never resurrect the directory here.
            continue;
          }
          await target.create(recursive: true);
        }
        next[rel] = _StatSnapshot(
          mtimeMs: saf.lastModifiedMs,
          size: 0,
          isDir: true,
        );
        continue;
      }
      if (mir == null) {
        if (snapshot.containsKey(rel)) {
          // Pending mirror-side deletion: the file was deleted in the mirror
          // after the last completed round — pass 3 propagates the deletion
          // to the SAF side. Copying it back here would resurrect it (and a
          // delete-then-recreate by the AI within the poll window would then
          // be misread as a deletion on the next round and destroyed).
          continue;
        }
        await _copySafToMirror(entry, saf, mirrorRoot, rel);
        next[rel] = _snapshotOf(saf);
        continue;
      }
      if (_sameEntry(saf, mir)) {
        next[rel] = _snapshotOf(saf);
        continue;
      }
      final safM = saf.lastModifiedMs ?? 0;
      final mirM = mir.lastModifiedMs ?? 0;
      if (safM > mirM) {
        await _copySafToMirror(entry, saf, mirrorRoot, rel);
        next[rel] = _snapshotOf(saf);
      } else {
        // Mirror side is newer or it's an mtime tie — the mirror wins (tie
        // rule, ADR-0037). The push below then re-stats the SAF side so the
        // two converge without a ping-pong pull round.
        next[rel] = await _pushMirrorAndAlign(
          entry,
          saf,
          mirrorRoot,
          rel,
          safTree,
          createdSafDirs,
        );
      }
    }

    // Pass 2: entries present only on the mirror side.
    for (final rel in mirrorTree.keys) {
      if (safTree.containsKey(rel)) continue;
      final mir = mirrorTree[rel]!;
      final existed = snapshot.containsKey(rel);
      if (existed) {
        // Propagate the deletion: the path existed at the last completed
        // round and is now gone from the SAF side while the mirror still
        // has it — the user (or AI) deleted it.
        if (await _deleteSafEntry(entry, rel, safTree)) {
          await _removeRecursive(p.join(mirrorRoot.path, rel));
        } else {
          // SAF-side delete failed (transient provider error): keep the
          // snapshot entry so the next round retries instead of treating the
          // mirror file as brand-new content and pushing it back.
          next[rel] = _snapshotOfMirror(mir);
          deleteFailed = true;
        }
        continue;
      }
      // Brand-new mirror content (AI wrote it): push to SAF.
      await _pushMirrorToSaf(
        entry,
        safTree[rel],
        mirrorRoot,
        rel,
        safTree,
        createdSafDirs,
      );
      final updated = await _statSafAfterPush(
        entry,
        null,
        rel,
        safTree,
        createdSafDirs,
      );
      next[rel] = updated;
    }

    // Pass 3: mirror-side deletions propagate to SAF. A path that existed at
    // the last completed round, still exists on the SAF side, and is gone
    // from the mirror was deleted in the mirror (AI / user) — delete it on
    // the SAF side too. (The reverse direction — SAF gone, mirror kept — is
    // pass 2.)
    if (entryById(entry.id) == null) {
      // Removed mid-round (e.g. by clearAllData or the remove dialog): skip
      // deletion propagation entirely — the mirror was already deleted and
      // pass 3 would treat its absence as deletions in the user's real dir.
      return deleteFailed;
    }
    final deletionCandidates = snapshot.keys.toList()
      ..sort((a, b) {
        final depthOrder = b.split('/').length.compareTo(a.split('/').length);
        return depthOrder != 0 ? depthOrder : b.compareTo(a);
      });
    for (final rel in deletionCandidates) {
      final safHas = safTree.containsKey(rel);
      final mirHas = mirrorTree.containsKey(rel);
      if (safHas && !mirHas) {
        if (!await _deleteSafEntry(entry, rel, safTree)) {
          deleteFailed = true;
          // Keep the snapshot entry so the next round RETRIES the deletion.
          // Pass 1 skips snapshot-known mirror-missing paths as pending
          // deletions and would otherwise drop them from `next` — the
          // failed delete would then be forgotten forever.
          final saf = safTree[rel];
          if (saf != null) {
            next[rel] = _snapshotOf(saf);
          }
        }
      }
    }

    await _writeSnapshot(entry.id, next);
    return deleteFailed;
  }

  bool _sameEntry(SafEntry saf, _MirrorEntry mir) {
    // A file↔directory conflict at the same path is NEVER "same" — the
    // merge must resolve it (newer side wins) instead of silently diverging.
    if (saf.isDirectory != mir.isDirectory) return false;
    if (saf.size != mir.size) return false;
    final safM = saf.lastModifiedMs;
    final mirM = mir.lastModifiedMs;
    if (safM == null || mirM == null) return saf.size == mir.size;
    return (safM - mirM).abs() <= mtimeTolerance.inMilliseconds;
  }

  static _StatSnapshot _snapshotOf(SafEntry saf) => _StatSnapshot(
    mtimeMs: saf.lastModifiedMs,
    size: saf.size ?? 0,
    isDir: saf.isDirectory,
  );

  static _StatSnapshot _snapshotOfMirror(_MirrorEntry m) => _StatSnapshot(
    mtimeMs: m.lastModifiedMs,
    size: m.size,
    isDir: m.isDirectory,
  );

  Future<void> _copySafToMirror(
    WorkspaceSafMount entry,
    SafEntry saf,
    Directory mirrorRoot,
    String rel,
  ) async {
    final target = File(p.join(mirrorRoot.path, rel));
    if (await Directory(target.path).exists()) {
      // Type conflict: a directory sits where the SAF file must land —
      // remove it so the file can be written (newer side wins).
      await _removeRecursive(target.path);
    }
    await target.parent.create(recursive: true);
    // Temp file lives OUTSIDE the mirror walk root (.state/): an interrupted
    // round (process death) must never leave a .saf_tmp entry inside the
    // mirror, which the next round would misread as brand-new mirror content
    // and push into the user's real directory. Same-volume rename stays
    // atomic; per-alias single-flight guarantees a fixed temp name is safe.
    final tmp = File(p.join(_stateRoot, '${entry.id}_copy_tmp'));
    await channel.withTimeout(() => channel.copyToPath(saf.uri, tmp.path));
    await tmp.rename(target.path);
    final mtime = saf.lastModifiedMs;
    if (mtime != null) {
      try {
        await target.setLastModified(
          DateTime.fromMillisecondsSinceEpoch(mtime),
        );
      } catch (_) {}
    }
  }

  /// Pushes the mirror's content for [rel] to the SAF side and aligns the
  /// mirror mtime to the post-push SAF stat so the two converge without a
  /// ping-pong pull round. Returns the post-push snapshot stat.
  Future<_StatSnapshot> _pushMirrorAndAlign(
    WorkspaceSafMount entry,
    SafEntry saf,
    Directory mirrorRoot,
    String rel,
    Map<String, SafEntry> safTree,
    Map<String, String> createdSafDirs,
  ) async {
    await _pushMirrorToSaf(
      entry,
      saf,
      mirrorRoot,
      rel,
      safTree,
      createdSafDirs,
    );
    final updated = await _statSafAfterPush(
      entry,
      saf,
      rel,
      safTree,
      createdSafDirs,
    );
    final safM = saf.lastModifiedMs ?? 0;
    if (updated.mtimeMs != null && updated.mtimeMs != safM) {
      try {
        final f = File(p.join(mirrorRoot.path, rel));
        await f.setLastModified(
          DateTime.fromMillisecondsSinceEpoch(updated.mtimeMs!),
        );
      } catch (e) {
        debugPrint('SafMountSyncService: mirror mtime align failed: $e');
      }
    }
    return updated;
  }

  /// Pushes one mirror file into the SAF side. [safEntry] may be null when
  /// the path has no SAF counterpart yet (brand-new mirror file). Parent
  /// lookups reuse the round's [safTree] plus [createdSafDirs] so pushes
  /// never re-walk the whole SAF tree.
  Future<void> _pushMirrorToSaf(
    WorkspaceSafMount entry,
    SafEntry? safEntry,
    Directory mirrorRoot,
    String rel,
    Map<String, SafEntry> safTree,
    Map<String, String> createdSafDirs,
  ) async {
    final file = File(p.join(mirrorRoot.path, rel));
    if (await Directory(file.path).exists()) {
      if (safEntry != null && !safEntry.isDirectory) {
        // Type conflict: SAF has a file where the mirror has a directory —
        // delete the SAF file so the directory can be created (newer side
        // wins).
        final deleted = await channel.withTimeout(
          () => channel.delete(safEntry.uri),
        );
        if (!deleted) {
          throw StateError('Provider refused to delete conflicting SAF file');
        }
        _replaceSafSubtree(safTree, rel);
      }
      if (safEntry == null || !safEntry.isDirectory) {
        final parentUri = await _ensureParentSafDir(
          entry,
          rel,
          safTree,
          createdSafDirs,
        );
        final created = await channel.withTimeout(
          () => channel.mkdir(parentUri, p.basename(rel)),
        );
        createdSafDirs[rel] = created;
        _replaceSafSubtree(
          safTree,
          rel,
          SafEntry(name: p.basename(rel), isDirectory: true, uri: created),
        );
      }
      return;
    }
    if (safEntry != null) {
      if (!safEntry.isDirectory) {
        await channel.withTimeout(
          () => channel.copyFromPath(safEntry.uri, file.path),
        );
        return;
      }
      // Type conflict: SAF has a directory where the mirror has a file —
      // delete it, then fall through to create the file.
      final deleted = await channel.withTimeout(
        () => channel.delete(safEntry.uri),
      );
      if (!deleted) {
        throw StateError(
          'Provider refused to delete conflicting SAF directory',
        );
      }
      _replaceSafSubtree(safTree, rel);
    }
    // New file (or post-conflict): create in the SAF parent directory, then
    // write.
    final parentUri = await _ensureParentSafDir(
      entry,
      rel,
      safTree,
      createdSafDirs,
    );
    final created = await channel.withTimeout(
      () => channel.createFile(parentUri, p.basename(rel)),
    );
    await channel.withTimeout(() => channel.copyFromPath(created, file.path));
    _replaceSafSubtree(
      safTree,
      rel,
      SafEntry(name: p.basename(rel), isDirectory: false, uri: created),
    );
  }

  static void _replaceSafSubtree(
    Map<String, SafEntry> safTree,
    String rel, [
    SafEntry? replacement,
  ]) {
    safTree.removeWhere((path, _) => path == rel || path.startsWith('$rel/'));
    if (replacement != null) safTree[rel] = replacement;
  }

  /// Resolves the SAF URI of the parent directory of [rel], creating any
  /// missing ancestor directories top-down on the SAF side. Created
  /// directories are memoized in [createdSafDirs] so siblings reuse them
  /// without extra channel round-trips.
  Future<String> _ensureParentSafDir(
    WorkspaceSafMount entry,
    String rel,
    Map<String, SafEntry> safTree,
    Map<String, String> createdSafDirs,
  ) async {
    final parentRel = p.dirname(rel);
    if (parentRel == '.') return entry.uri;
    final cached = createdSafDirs[parentRel];
    if (cached != null) return cached;
    var currentUri = entry.uri;
    final prefix = <String>[];
    for (final part in parentRel.split('/')) {
      prefix.add(part);
      final key = prefix.join('/');
      final cachedChild = createdSafDirs[key];
      if (cachedChild != null) {
        currentUri = cachedChild;
        continue;
      }
      final existing = safTree[key];
      if (existing != null) {
        currentUri = existing.uri;
        continue;
      }
      final created = await channel.withTimeout(
        () => channel.mkdir(currentUri, part),
      );
      createdSafDirs[key] = created;
      currentUri = created;
    }
    return currentUri;
  }

  /// Re-stats the just-written SAF entry so the mirror mtime can be aligned
  /// and the snapshot records the post-push truth (prevents a pull-back
  /// round on the next sync). Only the PARENT directory is re-listed — one
  /// channel round-trip instead of a full-tree walk. Falls back to the
  /// pre-push [safEntry] stat when the re-stat fails (the mtime tolerance
  /// absorbs the provider-side rewrite and the next round converges).
  Future<_StatSnapshot> _statSafAfterPush(
    WorkspaceSafMount entry,
    SafEntry? safEntry,
    String rel,
    Map<String, SafEntry> safTree,
    Map<String, String> createdSafDirs,
  ) async {
    try {
      final parentRel = p.dirname(rel);
      final parentUri = parentRel == '.'
          ? entry.uri
          // createdSafDirs first: a type-conflict may have REPLACED the SAF
          // entry during this round, leaving a stale URI in safTree.
          : (createdSafDirs[parentRel] ?? safTree[parentRel]?.uri);
      if (parentUri != null) {
        final raw = await channel.withTimeout(() => channel.list(parentUri));
        final name = p.basename(rel);
        for (final m in raw) {
          if ((m['name'] ?? '').toString() == name) {
            return _StatSnapshot(
              mtimeMs: (m['lastModified'] as num?)?.toInt(),
              size: (m['size'] as num?)?.toInt() ?? 0,
              isDir: m['isDirectory'] == true,
            );
          }
        }
      }
    } catch (e) {
      debugPrint('SafMountSyncService: post-push stat failed: $e');
    }
    if (safEntry != null) return _snapshotOf(safEntry);
    return const _StatSnapshot(mtimeMs: null, size: 0, isDir: false);
  }

  Future<bool> _deleteSafEntry(
    WorkspaceSafMount entry,
    String rel,
    Map<String, SafEntry> safTree,
  ) async {
    final saf = safTree[rel];
    if (saf == null) return true;
    try {
      return await channel.withTimeout(() => channel.delete(saf.uri));
    } catch (e) {
      debugPrint('SafMountSyncService: SAF delete failed for $rel: $e');
      return false;
    }
  }

  Future<void> _removeRecursive(String path) async {
    final f = File(path);
    try {
      if (await f.exists()) {
        await f.delete();
        return;
      }
    } catch (_) {}
    try {
      final d = Directory(path);
      if (await d.exists()) await d.delete(recursive: true);
    } catch (e) {
      debugPrint('SafMountSyncService: mirror delete failed for $path: $e');
    }
  }

  Future<Map<String, SafEntry>> _listSafTree(String rootUri) async {
    final out = <String, SafEntry>{};
    await _walkSaf(rootUri, '.', out);
    return out;
  }

  Future<void> _walkSaf(
    String uri,
    String relPrefix,
    Map<String, SafEntry> out,
  ) async {
    final raw = await channel.list(uri);
    final entries = <SafEntry>[];
    for (final m in raw) {
      final name = (m['name'] ?? '').toString();
      if (!_isSafeSafDocumentName(name)) {
        debugPrint(
          'SafMountSyncService: provider returned unsafe document name; '
          'aborting round',
        );
        throw StateError('SAF provider returned an unsafe document name');
      }
      final childUri = (m['uri'] ?? '').toString();
      if (Uri.tryParse(childUri)?.scheme != 'content') {
        debugPrint(
          'SafMountSyncService: provider returned an invalid document URI; '
          'aborting round',
        );
        throw StateError('SAF provider returned an invalid document URI');
      }
      final entry = SafEntry(
        name: name,
        isDirectory: m['isDirectory'] == true,
        uri: childUri,
        lastModifiedMs: (m['lastModified'] as num?)?.toInt(),
        size: (m['size'] as num?)?.toInt(),
      );
      entries.add(entry);
    }
    entries.sort((a, b) => a.name.compareTo(b.name));
    for (final e in entries) {
      final rel = relPrefix == '.' ? e.name : '$relPrefix/${e.name}';
      if (out.containsKey(rel)) {
        debugPrint(
          'SafMountSyncService: provider returned a duplicate document name; '
          'aborting round',
        );
        throw StateError('SAF provider returned a duplicate document name');
      }
      out[rel] = e;
      if (e.isDirectory) {
        await _walkSaf(e.uri, rel, out);
      }
    }
  }

  static bool _isSafeSafDocumentName(String name) {
    return isSafeWireSegment(name) &&
        !name.contains('/') &&
        !name.contains('\\') &&
        !name.contains(':') &&
        !name.contains('\u0000');
  }

  Future<Map<String, _MirrorEntry>> _listMirrorTree(Directory root) async {
    final out = <String, _MirrorEntry>{};
    await _walkMirror(root, root.path, '.', out);
    return out;
  }

  Future<void> _walkMirror(
    Directory root,
    String dirPath,
    String relPrefix,
    Map<String, _MirrorEntry> out,
  ) async {
    List<FileSystemEntity> children;
    try {
      children = await Directory(dirPath).list(followLinks: false).toList();
    } catch (e) {
      // A failed mirror walk must ABORT the round instead of silently
      // dropping the subtree: pass 3 would misread the missing paths as
      // mirror-side deletions and delete the corresponding files in the
      // user's real directory (ADR-0037 removal race).
      debugPrint('SafMountSyncService: mirror walk failed at $dirPath: $e');
      rethrow;
    }
    children.sort((a, b) => p.basename(a.path).compareTo(p.basename(b.path)));
    for (final child in children) {
      final name = p.basename(child.path);
      if (!_isSafeSafDocumentName(name)) {
        debugPrint(
          'SafMountSyncService: mirror contains an unsafe document name at '
          '${child.path}; aborting round',
        );
        throw StateError('Mirror contains an unsafe document name');
      }
      final rel = relPrefix == '.' ? name : '$relPrefix/$name';
      if (name.endsWith('.saf_tmp')) {
        // Stale copy temp from a pre-ADR-0037-build interruption (older
        // versions wrote temps inside the mirror). Prune instead of
        // treating it as brand-new mirror content (which would push it into
        // the user's real directory).
        try {
          if (child is Directory) {
            await child.delete(recursive: true);
          } else {
            await child.delete();
          }
        } catch (e) {
          debugPrint('SafMountSyncService: stale tmp prune failed: $e');
        }
        continue;
      }
      if (child is Directory) {
        out[rel] = _MirrorEntry(
          isDirectory: true,
          size: 0,
          lastModifiedMs: _safeMtime(child),
        );
        await _walkMirror(root, child.path, rel, out);
      } else if (child is File) {
        int size;
        int? mtime;
        try {
          size = await child.length();
        } catch (_) {
          size = 0;
        }
        mtime = _safeMtime(child);
        out[rel] = _MirrorEntry(
          isDirectory: false,
          size: size,
          lastModifiedMs: mtime,
        );
      } else if (child is Link) {
        // A symlink in the mirror (e.g. created inside the proot guest at
        // /workspace/.mounts/<alias>) cannot be mirrored to SAF and must
        // never be misread as a deletion — abort the round loudly instead;
        // the mount resumes once the link is removed.
        debugPrint(
          'SafMountSyncService: mirror contains a symbolic link at '
          '${child.path}; aborting round — remove the link to resume sync',
        );
        throw StateError('Mirror contains a symbolic link: ${child.path}');
      }
    }
  }

  static int? _safeMtime(FileSystemEntity entity) {
    try {
      return entity.statSync().modified.millisecondsSinceEpoch;
    } catch (_) {
      return null;
    }
  }

  // =====================================================================
  // Snapshot persistence
  // =====================================================================

  Future<Map<String, _StatSnapshot>> _readSnapshot(String mountId) async {
    final f = File(statePathFor(mountId));
    try {
      if (!await f.exists()) return <String, _StatSnapshot>{};
      final raw = await f.readAsString();
      final map = (jsonDecode(raw) as Map).cast<String, dynamic>();
      return {
        for (final e in map.entries)
          e.key: _StatSnapshot.fromJson(
            (e.value as Map).cast<String, dynamic>(),
          ),
      };
    } catch (e) {
      debugPrint('SafMountSyncService: snapshot read failed for $mountId: $e');
      return <String, _StatSnapshot>{};
    }
  }

  Future<void> _writeSnapshot(
    String mountId,
    Map<String, _StatSnapshot> snapshot,
  ) async {
    try {
      await Directory(_stateRoot).create(recursive: true);
      final f = File(statePathFor(mountId));
      final tmp = File('${f.path}.tmp');
      await tmp.writeAsString(
        jsonEncode({for (final e in snapshot.entries) e.key: e.value.toJson()}),
        flush: true,
      );
      await tmp.rename(f.path);
    } catch (e) {
      debugPrint('SafMountSyncService: snapshot write failed for $mountId: $e');
      rethrow;
    }
  }

  // =====================================================================
  // Lifecycle: resume sync + foreground polling
  // =====================================================================

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (!androidProbe()) return;
    if (state == AppLifecycleState.resumed) {
      _setForeground(true);
      Timer(resumeDebounce, () => unawaited(syncAll()));
    } else if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.detached) {
      _setForeground(false);
    }
  }

  void _setForeground(bool foreground) {
    if (foreground) {
      _pollTimer ??= Timer.periodic(
        foregroundPollInterval,
        (_) => unawaited(syncAll()),
      );
    } else {
      _pollTimer?.cancel();
      _pollTimer = null;
    }
  }

  @override
  void dispose() {
    workspaces.removeListener(_onWorkspacesChanged);
    _pollTimer?.cancel();
    for (final timer in _debounceTimers.values) {
      timer.cancel();
    }
    try {
      WidgetsBinding.instance.removeObserver(this);
    } catch (_) {
      // Headless tests may not have a binding.
    }
    super.dispose();
  }
}

/// Raised when the SAF grant is missing or the provider rejects access.
/// The round aborts without deleting or pushing anything.
class SafAccessException implements Exception {
  final String message;
  SafAccessException(this.message);
  @override
  String toString() => message;
}

/// Mirrored-entry stat for the three-state comparison.
class _MirrorEntry {
  final bool isDirectory;
  final int size;
  final int? lastModifiedMs;

  const _MirrorEntry({
    required this.isDirectory,
    required this.size,
    this.lastModifiedMs,
  });
}

/// Snapshot stat for deletion gating. `mtimeMs: null` means "unknown" (the
/// entry then matches any mtime — never triggers a change by itself).
class _StatSnapshot {
  final int? mtimeMs;
  final int size;
  final bool isDir;

  const _StatSnapshot({
    required this.mtimeMs,
    required this.size,
    required this.isDir,
  });

  Map<String, dynamic> toJson() => {'m': mtimeMs, 's': size, 'd': isDir};

  factory _StatSnapshot.fromJson(Map<String, dynamic> json) => _StatSnapshot(
    mtimeMs: (json['m'] as num?)?.toInt(),
    size: (json['s'] as num?)?.toInt() ?? 0,
    isDir: json['d'] as bool? ?? false,
  );
}
