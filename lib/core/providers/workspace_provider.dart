import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:Cuplivo/core/database/business_preferences.dart';
import 'package:uuid/uuid.dart';

import '../models/workspace.dart';
import '../services/mcp/kelivo_filesystem/kelivo_filesystem_server.dart';
import '../services/workspace/workspace_terminal_native_bridge.dart';
import '../../utils/app_directories.dart';
import '../../utils/platform_utils.dart';

/// Owns multi-workspace metadata, host paths, and one-shot migrations from the
/// legacy single `@workspaces` sandbox + desktop external mounts.
class WorkspaceProvider extends ChangeNotifier {
  final BusinessPreferences _preferences;
  static const String metaPrefsKey = 'workspaces_meta_v1';
  static const String migratedPrefsKey = 'workspaces_multi_migrated_v1';
  static const String legacyMountsPrefsKey = 'filesystem_mounts_v1';

  static const String errorAliasInvalid = 'alias_invalid';
  static const String errorAliasReserved = 'alias_reserved';
  static const String errorAliasDuplicate = 'alias_duplicate';
  static const String errorPathInvalid = 'path_invalid';
  static const String errorPathNotFound = 'path_not_found';
  static const String errorSyncOverlap = 'sync_overlap';
  static const String errorInsideWorkspaces = 'inside_workspaces';
  static const String errorDestinationNotEmpty = 'destination_not_empty';
  static const String errorCannotDeleteDefault = 'cannot_delete_default';
  static const String errorNameEmpty = 'name_empty';
  static const String errorTerminalStopFailed = 'terminal_stop_failed';

  final WorkspaceTerminalPort _terminal;

  final List<Workspace> _workspaces = <Workspace>[];
  String? _rootPath;
  bool _loaded = false;
  Future<void>? _initFuture;

  bool get loaded => _loaded;

  List<Workspace> get workspaces => List.unmodifiable(_workspaces);

  String? get rootPath => _rootPath;

  Workspace? get defaultWorkspace =>
      _workspaces.where((w) => w.alias == Workspace.defaultAlias).firstOrNull;

  Workspace? getById(String id) =>
      _workspaces.where((w) => w.id == id).firstOrNull;

  Workspace? getByAlias(String alias) =>
      _workspaces.where((w) => w.alias == alias).firstOrNull;

  /// Mounts exposed to tools for a single bound workspace.
  List<FilesystemMount> mountsFor(Workspace? ws) {
    if (ws == null) return const <FilesystemMount>[];
    final path = hostPathFor(ws);
    if (path == null) return const <FilesystemMount>[];
    return [
      FilesystemMount(alias: ws.alias, path: path, readOnly: ws.readOnly),
    ];
  }

  /// All managed mounts (file browser / storage UI).
  List<FilesystemMount> get allMounts => [
    for (final w in _workspaces)
      if (hostPathFor(w) != null)
        FilesystemMount(
          alias: w.alias,
          path: hostPathFor(w)!,
          readOnly: w.readOnly,
        ),
  ];

  String? hostPathFor(Workspace ws) {
    final custom = ws.customHostPath?.trim();
    if (custom != null && custom.isNotEmpty) return custom;
    final root = _rootPath;
    if (root == null) return null;
    return p.join(root, ws.alias);
  }

  String? sandboxPathFor(Workspace ws) {
    final host = hostPathFor(ws);
    if (host == null) return null;
    return p.join(host, '.sandbox');
  }

  WorkspaceProvider({
    required this._preferences,
    WorkspaceTerminalPort? terminal,
  }) : _terminal = terminal ?? WorkspaceTerminalNativeBridge.instance {
    unawaited(init());
  }

  Future<void> init() {
    if (_loaded) return Future.value();
    return _initFuture ??= _doInit();
  }

  Future<void> _doInit() async {
    try {
      final prefs = _preferences;
      final root = await AppDirectories.getWorkspacesRootDirectory();
      try {
        await root.create(recursive: true);
      } catch (e) {
        debugPrint('WorkspaceProvider: failed to create root: $e');
      }
      _rootPath = root.path;

      final migrated = prefs.getBool(migratedPrefsKey) == true;
      if (!migrated) {
        await _runOneShotMigration(prefs);
        await prefs.setBool(migratedPrefsKey, true);
      } else {
        await _loadMeta(prefs);
      }

      if (_workspaces.isEmpty) {
        _workspaces.add(Workspace.createDefault());
        await _persistMeta();
      } else if (defaultWorkspace == null) {
        _workspaces.insert(0, Workspace.createDefault());
        await _persistMeta();
      }

      for (final w in _workspaces) {
        if (w.customHostPath == null) {
          try {
            await Directory(hostPathFor(w)!).create(recursive: true);
          } catch (e) {
            debugPrint('WorkspaceProvider: mkdir ${w.alias}: $e');
          }
        }
      }

      _loaded = true;
      notifyListeners();
    } finally {
      _initFuture = null;
    }
  }

  Future<void> reloadFromPrefs() async {
    // Wait for any in-flight init before resetting.
    final inflight = _initFuture;
    if (inflight != null) {
      try {
        await inflight;
      } catch (_) {}
    }
    _loaded = false;
    _workspaces.clear();
    _rootPath = null;
    await init();
  }

  Future<void> _loadMeta(BusinessPreferences prefs) async {
    final raw = prefs.getString(metaPrefsKey);
    if (raw == null || raw.isEmpty) return;
    try {
      final list = Workspace.decodeList(raw);
      _workspaces
        ..clear()
        ..addAll(_sanitizeSafMounts(list));
      _workspaces.sort((a, b) => a.sortOrder.compareTo(b.sortOrder));
    } catch (e) {
      debugPrint('WorkspaceProvider: failed to load meta: $e');
    }
  }

  List<Workspace> _sanitizeSafMounts(List<Workspace> workspaces) {
    final usedIds = <String>{};
    final usedUris = <String>{};
    return [
      for (final workspace in workspaces)
        workspace.copyWith(
          safMounts: () {
            final aliases = <String>{};
            final mounts = <WorkspaceSafMount>[];
            for (final mount in workspace.safMounts) {
              final valid =
                  isValidSafMountId(mount.id) &&
                  !usedIds.contains(mount.id) &&
                  mount.uri.isNotEmpty &&
                  !usedUris.contains(mount.uri) &&
                  isValidMountAlias(mount.alias) &&
                  mount.alias != workspace.alias &&
                  !aliases.contains(mount.alias);
              if (!valid) {
                debugPrint(
                  'WorkspaceProvider: skipping invalid SAF mount '
                  '${mount.alias} for ${workspace.id}',
                );
                continue;
              }
              usedIds.add(mount.id);
              usedUris.add(mount.uri);
              aliases.add(mount.alias);
              mounts.add(mount);
            }
            return mounts;
          }(),
        ),
    ];
  }

  Future<void> _runOneShotMigration(BusinessPreferences prefs) async {
    await _loadMeta(prefs);
    if (_workspaces.isEmpty) {
      _workspaces.add(Workspace.createDefault());
    }

    final root = Directory(_rootPath!);
    final defaultDir = Directory(p.join(root.path, Workspace.defaultAlias));
    final alreadyNested = await defaultDir.exists();

    if (!alreadyNested && await root.exists()) {
      final toMove = <FileSystemEntity>[];
      await for (final ent in root.list(followLinks: false)) {
        final name = p.basename(ent.path);
        if (name == Workspace.defaultAlias) continue;
        if (name.startsWith('workspace_')) continue;
        if (name.startsWith('.')) {
          // Keep root-level dot dirs under default after move of .fetch_cache.
        }
        toMove.add(ent);
      }
      if (toMove.isNotEmpty) {
        await defaultDir.create(recursive: true);
        for (final ent in toMove) {
          final name = p.basename(ent.path);
          final dest = p.join(defaultDir.path, name);
          try {
            if (ent is Directory) {
              await ent.rename(dest);
            } else if (ent is File) {
              await ent.rename(dest);
            } else if (ent is Link) {
              await ent.rename(dest);
            }
          } catch (e) {
            debugPrint('WorkspaceProvider: migrate move $name failed: $e');
            try {
              if (ent is Directory) {
                await _copyDirectoryRecursive(ent, Directory(dest));
                await ent.delete(recursive: true);
              } else if (ent is File) {
                await ent.copy(dest);
                await ent.delete();
              }
            } catch (e2) {
              debugPrint('WorkspaceProvider: migrate copy $name failed: $e2');
            }
          }
        }
      }
    } else if (!alreadyNested) {
      await defaultDir.create(recursive: true);
    }

    // Desktop external mounts → workspaces.
    if (PlatformUtils.isDesktopTarget) {
      final mountsRaw = prefs.getString(legacyMountsPrefsKey);
      if (mountsRaw != null && mountsRaw.isNotEmpty) {
        try {
          final list = (jsonDecode(mountsRaw) as List)
              .whereType<Map>()
              .map((e) => e.cast<String, dynamic>())
              .toList();
          var n = _nextWorkspaceNumber();
          for (final m in list) {
            final aliasRaw = (m['alias'] as String?)?.trim() ?? '';
            final path = (m['path'] as String?)?.trim() ?? '';
            if (path.isEmpty) continue;
            var alias = aliasRaw;
            if (!isValidWorkspaceAlias(alias) ||
                _workspaces.any((w) => w.alias == alias) ||
                alias == Workspace.defaultAlias ||
                alias == Workspace.legacyAlias) {
              alias = 'workspace_$n';
              n++;
            }
            final id = const Uuid().v4();
            _workspaces.add(
              Workspace(
                id: id,
                displayName: aliasRaw.isNotEmpty ? aliasRaw : alias,
                alias: alias,
                sortOrder: _workspaces.length,
                customHostPath: path,
                readOnly: m['readOnly'] as bool? ?? true,
              ),
            );
          }
          await prefs.remove(legacyMountsPrefsKey);
        } catch (e) {
          debugPrint('WorkspaceProvider: external mount migrate failed: $e');
        }
      }
    }

    await _persistMeta();
  }

  int _nextWorkspaceNumber() {
    var max = 0;
    final re = RegExp(r'^workspace_(\d+)$');
    for (final w in _workspaces) {
      final m = re.firstMatch(w.alias);
      if (m != null) {
        max = max < int.parse(m.group(1)!) ? int.parse(m.group(1)!) : max;
      }
    }
    return max + 1;
  }

  String allocateAlias() => 'workspace_${_nextWorkspaceNumber()}';

  Future<Workspace> createWorkspace({
    required String displayName,
    String? customHostPath,
    bool readOnly = false,
  }) async {
    await init();
    final name = displayName.trim();
    if (name.isEmpty) {
      throw StateError(errorNameEmpty);
    }
    final alias = allocateAlias();
    final ws = Workspace(
      id: const Uuid().v4(),
      displayName: name,
      alias: alias,
      sortOrder: _workspaces.isEmpty
          ? 0
          : _workspaces.map((w) => w.sortOrder).reduce(max) + 1,
      customHostPath: customHostPath?.trim().isNotEmpty == true
          ? customHostPath!.trim()
          : null,
      readOnly: readOnly,
    );
    if (ws.customHostPath == null) {
      await Directory(hostPathFor(ws)!).create(recursive: true);
    } else {
      final err = await _validateCustomPath(ws.customHostPath!);
      if (err != null) throw StateError(err);
    }
    _workspaces.add(ws);
    await _persistMeta();
    notifyListeners();
    return ws;
  }

  Future<void> updateWorkspace(Workspace ws) async {
    await init();
    final idx = _workspaces.indexWhere((w) => w.id == ws.id);
    if (idx < 0) return;
    _workspaces[idx] = ws.copyWith(updatedAt: DateTime.now());
    await _persistMeta();
    notifyListeners();
  }

  Future<void> renameWorkspace(String id, String displayName) async {
    final name = displayName.trim();
    if (name.isEmpty) throw StateError(errorNameEmpty);
    final ws = getById(id);
    if (ws == null) return;
    await updateWorkspace(ws.copyWith(displayName: name));
  }

  Future<void> setToolEnabled(String id, String tool, bool enabled) async {
    final ws = getById(id);
    if (ws == null) return;
    if (!WorkspaceToolNames.isWorkspaceTool(tool)) return;
    final tools = Map<String, bool>.from(ws.tools);
    tools[tool] = enabled;
    // Keep shellEnabled in lockstep with tools['shell'].
    final shellEnabled = tool == WorkspaceToolNames.shell
        ? enabled
        : (tools[WorkspaceToolNames.shell] == true);
    await updateWorkspace(
      ws.copyWith(tools: tools, shellEnabled: shellEnabled),
    );
  }

  Future<void> setToolNeedsApproval(
    String id,
    String tool,
    bool needsApproval,
  ) async {
    final ws = getById(id);
    if (ws == null) return;
    if (!WorkspaceToolNames.isWorkspaceTool(tool)) return;
    final approvals = Map<String, bool>.from(ws.toolApprovals);
    approvals[tool] = needsApproval;
    await updateWorkspace(ws.copyWith(toolApprovals: approvals));
  }

  /// Enable the full filesystem tool surface (used when migrating assistants
  /// that previously had the MCP filesystem server bound).
  Future<void> enableFullFilesystemTools(String id) async {
    final ws = getById(id);
    if (ws == null) return;
    final tools = {
      for (final t in WorkspaceToolNames.filesystemTools) t: true,
      WorkspaceToolNames.shell: ws.isToolEnabled(WorkspaceToolNames.shell),
    };
    await updateWorkspace(ws.copyWith(tools: tools));
  }

  Future<void> setDependencyPref(
    String id,
    String depId,
    DependencyInstallPref pref,
  ) async {
    final ws = getById(id);
    if (ws == null) return;
    final prefs = Map<String, DependencyInstallPref>.from(ws.dependencyPrefs);
    prefs[depId] = pref;
    await updateWorkspace(ws.copyWith(dependencyPrefs: prefs));
  }

  /// Atomically persists the three terminal-lifecycle settings.
  ///
  /// [Workspace] normalizes child flags to false when the parent flag is off,
  /// so legacy or restored invalid combinations cannot escape this boundary.
  Future<void> setTerminalPersistenceSettings(
    String id, {
    required bool keepTerminalAfterExit,
    required bool terminalPersistentKeepAlive,
    required bool autoStartLinuxSandbox,
  }) async {
    final ws = getById(id);
    if (ws == null) return;
    await updateWorkspace(
      ws.copyWith(
        keepTerminalAfterExit: keepTerminalAfterExit,
        terminalPersistentKeepAlive: terminalPersistentKeepAlive,
        autoStartLinuxSandbox: autoStartLinuxSandbox,
      ),
    );
  }

  Future<void> addSafMount(String workspaceId, WorkspaceSafMount mount) async {
    final ws = getById(workspaceId);
    if (ws == null) return;
    await updateWorkspace(ws.copyWith(safMounts: [...ws.safMounts, mount]));
  }

  Future<void> removeSafMount(String workspaceId, String mountId) async {
    final ws = getById(workspaceId);
    if (ws == null) return;
    await updateWorkspace(
      ws.copyWith(
        safMounts: [
          for (final m in ws.safMounts)
            if (m.id != mountId) m,
        ],
      ),
    );
  }

  Future<void> reorder(List<String> orderedIds) async {
    await init();
    final byId = {for (final w in _workspaces) w.id: w};
    final next = <Workspace>[];
    var order = 0;
    for (final id in orderedIds) {
      final w = byId.remove(id);
      if (w != null) {
        next.add(w.copyWith(sortOrder: order++));
      }
    }
    for (final w in byId.values) {
      next.add(w.copyWith(sortOrder: order++));
    }
    _workspaces
      ..clear()
      ..addAll(next);
    await _persistMeta();
    notifyListeners();
  }

  /// Deletes workspace meta. Does not delete custom host paths; deletes
  /// managed directory under root when not custom.
  Future<String?> deleteWorkspace(String id) async {
    await init();
    final ws = getById(id);
    if (ws == null) return null;
    if (ws.alias == Workspace.defaultAlias || ws.id == Workspace.defaultId) {
      return errorCannotDeleteDefault;
    }
    if (!await _stopTerminalForMutation(ws.id)) {
      return errorTerminalStopFailed;
    }
    _workspaces.removeWhere((w) => w.id == id);
    if (ws.customHostPath == null) {
      final path = hostPathFor(ws);
      if (path != null) {
        try {
          final dir = Directory(path);
          if (await dir.exists()) await dir.delete(recursive: true);
        } catch (e) {
          debugPrint('WorkspaceProvider: delete files failed: $e');
        }
      }
    }
    await _persistMeta();
    notifyListeners();
    return null;
  }

  /// Relocate managed root (desktop) — moves entire multi-workspace tree.
  Future<String?> setWorkspacesRootLocation(
    String path, {
    required bool moveFiles,
  }) async {
    await init();
    final trimmed = path.trim();
    final err = await _validateRootLocation(trimmed);
    if (err != null) return err;
    final current = _rootPath;
    final same =
        current != null &&
        AppDirectories.canonPath(trimmed) == AppDirectories.canonPath(current);
    if (!same) {
      if (moveFiles && current != null) {
        final dst = Directory(trimmed);
        if (await dst.exists() && await _dirHasEntries(dst)) {
          return errorDestinationNotEmpty;
        }
      }
      // workspaces_dir_v1 is device-local (desktop-only host path, localOnly
      // in the business registry): physical SharedPreferences is its sole
      // owner, NOT the business facade.
      final localPrefs = await SharedPreferences.getInstance();
      await localPrefs.setString(AppDirectories.workspacesDirPrefsKey, trimmed);
      if (moveFiles && current != null) {
        try {
          await _moveDirectoryContents(current, trimmed);
        } catch (e) {
          debugPrint('setWorkspacesRootLocation: move failed: $e');
          try {
            await localPrefs.setString(
              AppDirectories.workspacesDirPrefsKey,
              current,
            );
          } catch (e2) {
            debugPrint('setWorkspacesRootLocation: pref rollback failed: $e2');
          }
          try {
            if (await Directory(trimmed).exists()) {
              await _moveDirectoryContents(trimmed, current);
            }
          } catch (e3) {
            debugPrint('setWorkspacesRootLocation: move-back failed: $e3');
          }
          rethrow;
        }
      }
      try {
        await Directory(trimmed).create(recursive: true);
      } catch (e) {
        debugPrint('setWorkspacesRootLocation: mkdir failed: $e');
      }
      _rootPath = trimmed;
      notifyListeners();
    }
    return null;
  }

  Future<String?> setCustomHostPath(
    String workspaceId,
    String? path, {
    required bool moveFiles,
  }) async {
    await init();
    final ws = getById(workspaceId);
    if (ws == null) return errorPathInvalid;
    if (path == null || path.trim().isEmpty) {
      if (!await _stopTerminalForMutation(workspaceId)) {
        return errorTerminalStopFailed;
      }
      // Revert to managed path under root.
      final managed = p.join(_rootPath!, ws.alias);
      if (moveFiles && ws.customHostPath != null) {
        try {
          await _moveDirectoryContents(ws.customHostPath!, managed);
        } catch (e) {
          debugPrint('setCustomHostPath clear move failed: $e');
          rethrow;
        }
      }
      await updateWorkspace(ws.copyWith(clearCustomHostPath: true));
      return null;
    }
    final trimmed = path.trim();
    final err = await _validateCustomPath(trimmed, excludeId: workspaceId);
    if (err != null) return err;
    if (!await _stopTerminalForMutation(workspaceId)) {
      return errorTerminalStopFailed;
    }
    if (moveFiles) {
      final from = hostPathFor(ws);
      if (from != null &&
          AppDirectories.canonPath(from) != AppDirectories.canonPath(trimmed)) {
        final dst = Directory(trimmed);
        if (await dst.exists() && await _dirHasEntries(dst)) {
          return errorDestinationNotEmpty;
        }
        try {
          await _moveDirectoryContents(from, trimmed);
        } catch (e) {
          debugPrint('setCustomHostPath move failed: $e');
          rethrow;
        }
      }
    }
    await updateWorkspace(ws.copyWith(customHostPath: trimmed));
    return null;
  }

  Future<bool> _stopTerminalForMutation(String workspaceId) async {
    try {
      await _terminal.stopSession(workspaceId);
      return true;
    } catch (error, stackTrace) {
      debugPrint(
        'WorkspaceProvider: failed to stop terminal for $workspaceId: '
        '$error\n$stackTrace',
      );
      return false;
    }
  }

  Future<String?> _validateRootLocation(String path) async {
    if (path.isEmpty) return errorPathInvalid;
    final trimmed = path.trim();
    if (!_looksAbsolute(trimmed)) return errorPathInvalid;
    if (AppDirectories.isFilesystemRootPath(trimmed)) return errorPathInvalid;
    final current = _rootPath;
    if (current != null &&
        AppDirectories.canonPath(trimmed) !=
            AppDirectories.canonPath(current)) {
      if (AppDirectories.isPathInside(trimmed, current)) {
        return errorInsideWorkspaces;
      }
      final roots = await AppDirectories.getSyncRootPaths(
        includeWorkspaces: false,
      );
      for (final r in roots) {
        if (AppDirectories.pathsOverlap(trimmed, r)) return errorSyncOverlap;
      }
    }
    return null;
  }

  Future<String?> _validateCustomPath(String path, {String? excludeId}) async {
    final trimmed = path.trim();
    if (!_looksAbsolute(trimmed)) return errorPathInvalid;
    final roots = await AppDirectories.getSyncRootPaths();
    for (final r in roots) {
      if (AppDirectories.pathsOverlap(trimmed, r)) return errorSyncOverlap;
    }
    for (final w in _workspaces) {
      if (excludeId != null && w.id == excludeId) continue;
      final hp = hostPathFor(w);
      if (hp != null && AppDirectories.pathsOverlap(trimmed, hp)) {
        return errorSyncOverlap;
      }
    }
    bool isDir = false;
    try {
      final type = FileSystemEntity.typeSync(trimmed, followLinks: true);
      isDir = type == FileSystemEntityType.directory;
    } catch (_) {}
    if (!isDir) return errorPathNotFound;
    return null;
  }

  Future<bool> _dirHasEntries(Directory dir) async {
    await for (final _ in dir.list(followLinks: false)) {
      return true;
    }
    return false;
  }

  Future<void> _moveDirectoryContents(String from, String to) async {
    final src = Directory(from);
    final dst = Directory(to);
    if (!await src.exists()) return;
    try {
      await src.rename(to);
      return;
    } on FileSystemException {
      await dst.create(recursive: true);
      await _copyDirectoryRecursive(src, dst);
      await src.delete(recursive: true);
    }
  }

  Future<void> _copyDirectoryRecursive(Directory src, Directory dst) async {
    await dst.create(recursive: true);
    await for (final ent in src.list(followLinks: false)) {
      final targetPath = p.join(dst.path, p.basename(ent.path));
      if (ent is Directory) {
        await _copyDirectoryRecursive(ent, Directory(targetPath));
      } else if (ent is File) {
        final modified = await ent.lastModified();
        await ent.copy(targetPath);
        await File(targetPath).setLastModified(modified);
      } else if (ent is Link) {
        try {
          final target = await ent.target();
          await Link(targetPath).create(target);
        } catch (e) {
          debugPrint('WorkspaceProvider: link recreate failed: $e');
        }
      }
    }
  }

  Future<void> _persistMeta() async {
    final prefs = _preferences;
    await prefs.setString(metaPrefsKey, Workspace.encodeList(_workspaces));
  }

  static bool _looksAbsolute(String path) {
    if (path.startsWith('/') || path.startsWith('\\\\')) return true;
    if (path.length < 3) return false;
    final c0 = path.codeUnitAt(0);
    final isLetter = (c0 >= 0x41 && c0 <= 0x5a) || (c0 >= 0x61 && c0 <= 0x7a);
    return isLetter && path[1] == ':' && (path[2] == '/' || path[2] == '\\');
  }
}

/// Alias rules for multi-workspace wire paths.
/// Reserved: `workspaces` (legacy), empty, invalid charset.
bool isValidWorkspaceAlias(String alias) {
  if (alias.isEmpty || alias.length > 32) return false;
  if (alias == Workspace.legacyAlias) return false;
  final first = alias.codeUnitAt(0);
  final lower = first >= 0x61 && first <= 0x7a;
  final digit = first >= 0x30 && first <= 0x39;
  if (!lower && !digit) return false;
  for (var i = 1; i < alias.length; i++) {
    final c = alias.codeUnitAt(i);
    final a = c >= 0x61 && c <= 0x7a;
    final d = c >= 0x30 && c <= 0x39;
    final us = c == 0x5f;
    final hy = c == 0x2d;
    if (!a && !d && !us && !hy) return false;
  }
  return true;
}
