import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

import '../services/mcp/kelivo_filesystem/kelivo_filesystem_server.dart';
import '../../utils/app_directories.dart';
import '../../utils/platform_utils.dart';

/// Owns the global filesystem mount configuration for `@kelivo/filesystem`.
///
/// The built-in `@workspaces` mount (rw sandbox, host location user-configurable
/// on desktop via [AppDirectories.workspacesDirPrefsKey]) is always present and
/// is the only mount on mobile. External mounts are desktop-only, never sync,
/// and live in SharedPreferences (`filesystem_mounts_v1`), which means they
/// ride `settings.json` in backups automatically — but they are loaded ONLY on
/// desktop, so a backup restored on a phone can never surface a foreign host
/// path (see CONTEXT.md "Filesystem MCP").
class FilesystemMountsProvider extends ChangeNotifier {
  static const String prefsKey = 'filesystem_mounts_v1';
  static const String workspacesAlias = 'workspaces';

  static const String errorAliasInvalid = 'alias_invalid';
  static const String errorAliasReserved = 'alias_reserved';
  static const String errorAliasDuplicate = 'alias_duplicate';
  static const String errorPathInvalid = 'path_invalid';
  static const String errorPathNotFound = 'path_not_found';
  static const String errorSyncOverlap = 'sync_overlap';
  static const String errorInsideWorkspaces = 'inside_workspaces';
  static const String errorDestinationNotEmpty = 'destination_not_empty';

  final List<FilesystemMount> _external = <FilesystemMount>[];
  String? _workspacesPath;
  bool _loaded = false;

  bool get loaded => _loaded;

  FilesystemMount? get workspaces {
    final path = _workspacesPath;
    if (path == null) return null;
    return FilesystemMount(alias: workspacesAlias, path: path, readOnly: false);
  }

  List<FilesystemMount> get externalMounts => List.unmodifiable(_external);

  /// [workspaces] first, then external mounts.
  List<FilesystemMount> get allMounts => [
    if (workspaces != null) workspaces!,
    ..._external,
  ];

  FilesystemMountsProvider() {
    unawaited(init());
  }

  Future<void> init() async {
    if (_loaded) return;
    final prefs = await SharedPreferences.getInstance();
    if (PlatformUtils.isDesktopTarget) {
      final raw = prefs.getString(prefsKey);
      if (raw != null && raw.isNotEmpty) {
        try {
          final list = (jsonDecode(raw) as List)
              .whereType<Map>()
              .map((e) => FilesystemMount.fromJson(e.cast<String, dynamic>()))
              .toList();
          // Re-validate persisted mounts against the sync scope: a legacy
          // mount created before the overlap check existed must not stay
          // mounted — its host content would silently be swept into backup
          // packs. The config stays in prefs (no data loss); the user can
          // re-add an intentional mount elsewhere.
          final syncRoots = await AppDirectories.getSyncRootPaths();
          _external.clear();
          for (final m in list) {
            if (syncRoots.any((r) => AppDirectories.pathsOverlap(m.path, r))) {
              debugPrint(
                'FilesystemMountsProvider: skipping mount @${m.alias} '
                'overlapping the sync scope: ${m.path}',
              );
              continue;
            }
            _external.add(m);
          }
        } catch (e) {
          debugPrint('FilesystemMountsProvider: failed to load mounts: $e');
        }
      }
    } else {
      // External mounts are desktop-only. The config may still ride a backup's
      // settings.json onto a phone — keep it persisted but never mounted.
      _external.clear();
    }
    final wsDir = await AppDirectories.getWorkspacesDirectory();
    try {
      await wsDir.create(recursive: true);
    } catch (e) {
      debugPrint(
        'FilesystemMountsProvider: failed to create '
        'workspaces dir: $e',
      );
    }
    _workspacesPath = wsDir.path;
    _loaded = true;
    notifyListeners();
  }

  /// Adds an external mount. Returns `null` on success or an error code
  /// (one of the `error*` constants) for the UI to localize.
  Future<String?> addExternalMount({
    required String alias,
    required String path,
    bool readOnly = true,
  }) async {
    await init(); // serialize with the constructor-triggered load
    final syncRoots = await AppDirectories.getSyncRootPaths();
    final err = validateMountConfig(
      alias: alias,
      path: path,
      existing: _external,
      syncRoots: syncRoots,
    );
    if (err != null) return err;
    _external.add(
      FilesystemMount(alias: alias, path: path, readOnly: readOnly),
    );
    await _persist();
    notifyListeners();
    return null;
  }

  Future<String?> updateExternalMount({
    required String alias,
    String? path,
    bool? readOnly,
  }) async {
    await init();
    final idx = _external.indexWhere((m) => m.alias == alias);
    if (idx < 0) return errorAliasInvalid;
    final current = _external[idx];
    final newPath = path ?? current.path;
    final newReadOnly = readOnly ?? current.readOnly;
    final syncRoots = await AppDirectories.getSyncRootPaths();
    final err = validateMountConfig(
      alias: current.alias,
      path: newPath,
      existing: _external.where((m) => m.alias != alias).toList(),
      syncRoots: syncRoots,
    );
    if (err != null) return err;
    _external[idx] = current.copyWith(path: newPath, readOnly: newReadOnly);
    await _persist();
    notifyListeners();
    return null;
  }

  Future<void> removeExternalMount(String alias) async {
    await init();
    _external.removeWhere((m) => m.alias == alias);
    await _persist();
    notifyListeners();
  }

  /// Relocates the built-in `@workspaces` host directory (desktop only).
  /// Returns `null` on success or an error code for the UI to localize.
  /// When [moveFiles] is true, existing sandbox content is moved to the new
  /// location (same-volume rename, or copy+delete when the target exists or
  /// the move crosses volumes); otherwise the old directory is left in place
  /// and the new one starts empty. A non-empty destination is rejected when
  /// [moveFiles] is true — its content would silently become part of the
  /// synced sandbox.
  Future<String?> setWorkspacesLocation(
    String path, {
    required bool moveFiles,
  }) async {
    await init();
    final trimmed = path.trim();
    final err = await _validateWorkspacesLocation(trimmed);
    if (err != null) return err;
    final current = _workspacesPath;
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
      // Persist BEFORE moving: if the pref write fails, nothing has moved yet.
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(AppDirectories.workspacesDirPrefsKey, trimmed);
      if (moveFiles && current != null) {
        try {
          await _moveDirectoryContents(current, trimmed);
        } catch (e) {
          // Move failed after the pref was persisted: roll the setting back
          // and attempt to move the data back (best-effort).
          debugPrint('setWorkspacesLocation: move failed: $e');
          try {
            await prefs.setString(
              AppDirectories.workspacesDirPrefsKey,
              current,
            );
          } catch (e2) {
            debugPrint('setWorkspacesLocation: pref rollback failed: $e2');
          }
          try {
            if (await Directory(trimmed).exists()) {
              await _moveDirectoryContents(trimmed, current);
            }
          } catch (e3) {
            debugPrint('setWorkspacesLocation: move-back failed: $e3');
          }
          rethrow;
        }
      }
      _workspacesPath = trimmed;
      notifyListeners();
    }
    return null;
  }

  Future<String?> _validateWorkspacesLocation(String path) async {
    if (path.isEmpty) return errorPathInvalid;
    final trimmed = path.trim();
    final isUnc = trimmed.startsWith('\\\\');
    if (!(trimmed.startsWith('/') || isUnc || _hasDrivePrefix(trimmed))) {
      return errorPathInvalid;
    }
    final current = _workspacesPath;
    if (current != null &&
        AppDirectories.canonPath(trimmed) !=
            AppDirectories.canonPath(current)) {
      // Never nest the sandbox inside itself (recursive-copy hazard).
      if (AppDirectories.isPathInside(trimmed, current)) {
        return errorInsideWorkspaces;
      }
      // Never widen the sandbox to contain the current sandbox or any other
      // sync tree — both would sweep synced content into the pack walk.
      final roots = await AppDirectories.getSyncRootPaths();
      for (final r in roots) {
        if (AppDirectories.pathsOverlap(trimmed, r)) {
          return errorSyncOverlap;
        }
      }
      // Never overlap an existing external mount, either direction: a
      // sandbox containing a mount would sweep the mount's host content into
      // backups, and a sandbox inside a mount would resolve the same host
      // file under two aliases — a delete via the mount alias writes no
      // marker and would resurrect on the next sync merge.
      for (final m in _external) {
        if (AppDirectories.pathsOverlap(trimmed, m.path)) {
          return errorSyncOverlap;
        }
      }
    }
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
      // Target exists or cross-volume: copy recursively, then remove the
      // source.
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
        // Preserve mtimes: relocation is a physical move, not new content —
        // stamping mtime=now would re-sync the whole sandbox to LAN peers in
        // one burst and re-pack it into every incremental backup.
        await File(targetPath).setLastModified(modified);
      } else if (ent is Link) {
        // Best-effort link recreation: reliable on POSIX, needs privileges
        // on Windows — a failure is logged, not fatal.
        try {
          final target = await ent.target();
          await Link(targetPath).create(target);
        } catch (e) {
          debugPrint(
            'setWorkspacesLocation: failed to recreate link '
            '${ent.path}: $e',
          );
        }
      }
    }
  }

  Future<void> _persist() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      prefsKey,
      jsonEncode(_external.map((e) => e.toJson()).toList()),
    );
  }
}

/// Validates an external mount config. Returns `null` on success or an error
/// code (one of the `FilesystemMountsProvider.error*` constants).
///
/// [syncRoots] are the backup/LAN-sync packed directories; a mount inside or
/// containing one would silently enter the sync scope despite "external
/// mounts never sync" (see CONTEXT.md "Filesystem MCP").
String? validateMountConfig({
  required String alias,
  required String path,
  required List<FilesystemMount> existing,
  List<String> syncRoots = const [],
}) {
  if (alias == FilesystemMountsProvider.workspacesAlias) {
    return FilesystemMountsProvider.errorAliasReserved;
  }
  if (!isValidMountAlias(alias)) {
    return FilesystemMountsProvider.errorAliasInvalid;
  }
  if (existing.any((m) => m.alias == alias)) {
    return FilesystemMountsProvider.errorAliasDuplicate;
  }
  final trimmed = path.trim();
  final isUnc = trimmed.startsWith('\\\\');
  if (trimmed.isEmpty ||
      !(trimmed.startsWith('/') || isUnc || _hasDrivePrefix(trimmed))) {
    return FilesystemMountsProvider.errorPathInvalid;
  }
  for (final r in syncRoots) {
    if (AppDirectories.pathsOverlap(trimmed, r)) {
      return FilesystemMountsProvider.errorSyncOverlap;
    }
  }
  bool exists = false;
  try {
    // Unreachable UNC shares and permission errors make existsSync THROW
    // rather than return false — treat any failure as "not found".
    exists = Directory(trimmed).existsSync();
  } catch (_) {}
  if (!exists) {
    return FilesystemMountsProvider.errorPathNotFound;
  }
  return null;
}

bool _hasDrivePrefix(String s) {
  if (s.length < 3) return false;
  final c0 = s.codeUnitAt(0);
  final isLetter = (c0 >= 0x41 && c0 <= 0x5a) || (c0 >= 0x61 && c0 <= 0x7a);
  return isLetter && s[1] == ':' && (s[2] == '/' || s[2] == '\\');
}
