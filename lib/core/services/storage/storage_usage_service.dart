import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import '../../database/app_database.dart';
import '../../../utils/app_directories.dart';
import '../../../utils/avatar_cache.dart';
import '../logging/flutter_logger.dart';
import '../network/request_logger.dart';
import '../workspace/linux_sandbox_service.dart';
import '../workspace/workspace_terminal_native_bridge.dart';
import 'ios_tmp_directory.dart';

enum StorageUsageCategoryKey {
  images,
  files,
  chatData,
  assistantData,
  workspaces,
  skills,
  fonts,
  sandbox,
  cache,
  logs,
  other,
  deletedRecords,
}

class StorageUsageStats {
  final int fileCount;
  final int bytes;
  const StorageUsageStats({required this.fileCount, required this.bytes});

  StorageUsageStats operator +(StorageUsageStats other) {
    return StorageUsageStats(
      fileCount: fileCount + other.fileCount,
      bytes: bytes + other.bytes,
    );
  }
}

class StorageUsageSubcategory {
  final String id;
  final StorageUsageStats stats;
  final String? path;
  const StorageUsageSubcategory({
    required this.id,
    required this.stats,
    this.path,
  });
}

class StorageUsageCategory {
  final StorageUsageCategoryKey key;
  final StorageUsageStats stats;
  final List<StorageUsageSubcategory> subcategories;
  const StorageUsageCategory({
    required this.key,
    required this.stats,
    this.subcategories = const <StorageUsageSubcategory>[],
  });
}

class StorageUsageReport {
  final int totalBytes;
  final int totalFiles;
  final StorageUsageStats clearable;
  final List<StorageUsageCategory> categories;
  const StorageUsageReport({
    required this.totalBytes,
    required this.totalFiles,
    required this.clearable,
    required this.categories,
  });
}

class StorageFileEntry {
  final String path;
  final String name;
  final int bytes;
  final DateTime modifiedAt;
  const StorageFileEntry({
    required this.path,
    required this.name,
    required this.bytes,
    required this.modifiedAt,
  });
}

abstract final class StorageUsageService {
  StorageUsageService._();

  static bool _isImageExt(String name) {
    final lower = name.toLowerCase();
    return lower.endsWith('.png') ||
        lower.endsWith('.jpg') ||
        lower.endsWith('.jpeg') ||
        lower.endsWith('.gif') ||
        lower.endsWith('.webp') ||
        lower.endsWith('.heic') ||
        lower.endsWith('.heif') ||
        lower.endsWith('.bmp') ||
        lower.endsWith('.ico');
  }

  static String? _chatDatabaseSubcategoryId(String name) {
    switch (name.toLowerCase()) {
      case AppDatabase.databaseFileName:
        return 'sqlite_database';
      case '${AppDatabase.databaseFileName}-wal':
        return 'sqlite_wal';
      case '${AppDatabase.databaseFileName}-shm':
        return 'sqlite_shm';
      default:
        return null;
    }
  }

  static String _chatDatabaseFileName(String subcategoryId) {
    switch (subcategoryId) {
      case 'sqlite_wal':
        return '${AppDatabase.databaseFileName}-wal';
      case 'sqlite_shm':
        return '${AppDatabase.databaseFileName}-shm';
      case 'sqlite_database':
      default:
        return AppDatabase.databaseFileName;
    }
  }

  static Future<StorageUsageReport> computeReport({
    List<String> workspaceHostPaths = const [],
    void Function(int files, int bytes)? onProgress,
  }) async {
    final root = await AppDirectories.getAppDataDirectory();
    final progress = _ScanProgress(onProgress ?? (_, _) {});

    final byCat = <StorageUsageCategoryKey, _MutableStats>{
      for (final k in StorageUsageCategoryKey.values) k: _MutableStats(),
    };

    final chatSubs = <String, _MutableStats>{
      'sqlite_database': _MutableStats(),
      'sqlite_wal': _MutableStats(),
      'sqlite_shm': _MutableStats(),
    };

    final assistantSubs = <String, _MutableStats>{'avatars': _MutableStats()};

    final sandboxSubs = <String, _MutableStats>{
      'sandbox_per_ws': _MutableStats(),
      'sandbox_shared_runtime': _MutableStats(),
    };

    final cacheSubs = <String, _MutableStats>{
      'avatar_cache': _MutableStats(),
      'other_cache': _MutableStats(),
      'system_cache': _MutableStats(),
      'tmp_cache': _MutableStats(),
    };

    final logsSubs = <String, _MutableStats>{
      'flutter_logs': _MutableStats(),
      'request_logs': _MutableStats(),
      'other_logs': _MutableStats(),
    };

    final workspacesRoot = await AppDirectories.getWorkspacesRootDirectory();

    if (!await root.exists()) {
      return StorageUsageReport(
        totalBytes: 0,
        totalFiles: 0,
        clearable: const StorageUsageStats(fileCount: 0, bytes: 0),
        categories: [
          for (final k in _categoryOrder)
            StorageUsageCategory(
              key: k,
              stats: const StorageUsageStats(fileCount: 0, bytes: 0),
            ),
        ],
      );
    }

    try {
      await _scanFilesConcurrently(
        root,
        progress: progress,
        onFile: (ent, bytes) {
          final rel = p.relative(ent.path, from: root.path);
          final parts = p.split(rel);
          if (parts.isEmpty) {
            byCat[StorageUsageCategoryKey.other]!.add(bytes);
            return;
          }

          // Root-level chat data is stored by Drift in the SQLite database file
          // family. Legacy Hive boxes are migration inputs only and should not
          // affect the steady-state chat records size.
          if (parts.length == 1) {
            final name = parts.first;
            final chatSubId = _chatDatabaseSubcategoryId(name);
            if (chatSubId != null) {
              byCat[StorageUsageCategoryKey.chatData]!.add(bytes);
              chatSubs[chatSubId]!.add(bytes);
              return;
            }
            byCat[StorageUsageCategoryKey.other]!.add(bytes);
            return;
          }

          // A relocated workspaces root (workspaces_dir_v1) may live inside
          // the app data root under a non-"workspaces" name. The main scan
          // must categorize it by its effective path, not by the literal
          // top-level name, so the .sandbox split and clear affordance keep
          // working (mirrors the separate scan below for relocated roots
          // outside the app data root).
          final topLevel = p.join(root.path, parts.first);
          if (p.equals(topLevel, workspacesRoot.path)) {
            _addWorkspaceEntry(parts, bytes, byCat, sandboxSubs);
            return;
          }

          final top = parts.first.toLowerCase();
          switch (top) {
            case 'upload':
              final name = parts.last;
              if (_isImageExt(name)) {
                byCat[StorageUsageCategoryKey.images]!.add(bytes);
              } else {
                byCat[StorageUsageCategoryKey.files]!.add(bytes);
              }
              break;
            case 'avatars':
              byCat[StorageUsageCategoryKey.assistantData]!.add(bytes);
              assistantSubs['avatars']!.add(bytes);
              break;
            case 'workspaces':
              // Only reached for a stale root/workspaces leftover when the
              // root has been relocated elsewhere; the effective root is
              // handled by the path equality check above.
              _addWorkspaceEntry(parts, bytes, byCat, sandboxSubs);
              break;
            case 'skills':
              byCat[StorageUsageCategoryKey.skills]!.add(bytes);
              break;
            case 'fonts':
              byCat[StorageUsageCategoryKey.fonts]!.add(bytes);
              break;
            case 'linux-sandbox':
              // Shared Linux sandbox runtime (Android; iOS lives outside the
              // app data root and is scanned separately below).
              byCat[StorageUsageCategoryKey.sandbox]!.add(bytes);
              sandboxSubs['sandbox_shared_runtime']!.add(bytes);
              break;
            case 'images':
              // Inline/generated images are stored under appData/images.
              // Treat them as "Images" so users can manage them together.
              byCat[StorageUsageCategoryKey.images]!.add(bytes);
              break;
            case 'cache':
              byCat[StorageUsageCategoryKey.cache]!.add(bytes);
              if (parts.length >= 2 && parts[1].toLowerCase() == 'avatars') {
                cacheSubs['avatar_cache']!.add(bytes);
              } else {
                cacheSubs['other_cache']!.add(bytes);
              }
              break;
            case 'logs':
              byCat[StorageUsageCategoryKey.logs]!.add(bytes);
              final name = parts.last.toLowerCase();
              if (name.startsWith('flutter_logs')) {
                logsSubs['flutter_logs']!.add(bytes);
              } else if (name.startsWith('logs')) {
                logsSubs['request_logs']!.add(bytes);
              } else {
                logsSubs['other_logs']!.add(bytes);
              }
              break;
            default:
              byCat[StorageUsageCategoryKey.other]!.add(bytes);
              break;
          }
        },
      );
    } catch (e) {
      // Last-resort guard. Nested failures are logged and skipped inside
      // _scanFilesConcurrently, so reaching this only means the app data
      // root itself (or one of its immediate entries) cannot be listed.
      // Never swallow silently: a silent catch once left the storage page
      // reporting 0 bytes for every category except the separately-scanned
      // sandbox (real incident).
      debugPrint(
        'StorageUsageService: failed to scan app data root ${root.path}: $e',
      );
    }

    // Desktop workspaces root can be relocated (workspaces_dir_v1) to a
    // location outside the app data root — the main scan above misses it
    // entirely. Scan it separately, keeping the same .sandbox split.
    if (!AppDirectories.isPathInside(workspacesRoot.path, root.path)) {
      try {
        if (await workspacesRoot.exists()) {
          await _scanFilesConcurrently(
            workspacesRoot,
            progress: progress,
            onFile: (ent, bytes) {
              final rel = p.relative(ent.path, from: workspacesRoot.path);
              if (p
                  .split(rel)
                  .any((part) => part.toLowerCase() == '.sandbox')) {
                byCat[StorageUsageCategoryKey.sandbox]!.add(bytes);
                sandboxSubs['sandbox_per_ws']!.add(bytes);
              } else {
                byCat[StorageUsageCategoryKey.workspaces]!.add(bytes);
              }
            },
          );
        }
      } catch (e) {
        debugPrint(
          'StorageUsageService: failed to scan relocated workspaces root '
          '${workspacesRoot.path}: $e',
        );
      }
    }

    // iOS shared Linux sandbox runtime (iSH rootfs) lives in Application
    // Support, outside the app data root (ADR-0029) — scan it separately.
    final sandboxRuntime =
        await AppDirectories.getLinuxSandboxRuntimeDirectory();
    if (!AppDirectories.isPathInside(sandboxRuntime.path, root.path)) {
      try {
        if (await sandboxRuntime.exists()) {
          await _scanFilesConcurrently(
            sandboxRuntime,
            progress: progress,
            onFile: (ent, bytes) {
              byCat[StorageUsageCategoryKey.sandbox]!.add(bytes);
              sandboxSubs['sandbox_shared_runtime']!.add(bytes);
            },
          );
        }
      } catch (e) {
        debugPrint(
          'StorageUsageService: failed to scan sandbox runtime '
          '${sandboxRuntime.path}: $e',
        );
      }
    }

    // Workspaces with a customHostPath live outside the managed roots. Their
    // `.sandbox` dirs are still cleared by [clearSandbox], so scan them too,
    // deduped against every root already covered above.
    final coveredRoots = <String>{
      p.normalize(p.absolute(root.path)),
      p.normalize(p.absolute(workspacesRoot.path)),
      p.normalize(p.absolute(sandboxRuntime.path)),
    };
    final seenHosts = <String>{};
    for (final host in workspaceHostPaths) {
      final normHost = p.normalize(p.absolute(host));
      if (normHost.isEmpty || !seenHosts.add(normHost)) continue;
      if (coveredRoots.any((r) => AppDirectories.isPathInside(normHost, r))) {
        continue;
      }
      try {
        if (await Directory(host).exists()) {
          await _scanFilesConcurrently(
            Directory(host),
            progress: progress,
            onFile: (ent, bytes) {
              final rel = p.relative(ent.path, from: host);
              if (p
                  .split(rel)
                  .any((part) => part.toLowerCase() == '.sandbox')) {
                byCat[StorageUsageCategoryKey.sandbox]!.add(bytes);
                sandboxSubs['sandbox_per_ws']!.add(bytes);
              } else {
                byCat[StorageUsageCategoryKey.workspaces]!.add(bytes);
              }
            },
          );
        }
      } catch (e) {
        debugPrint(
          'StorageUsageService: failed to scan custom host workspace '
          '$normHost: $e',
        );
      }
    }

    final avatarsDir = await AppDirectories.getAvatarsDirectory();
    final cacheDir = await AppDirectories.getCacheDirectory();
    final systemCacheDir = await AppDirectories.getSystemCacheDirectory();
    final avatarCacheDir = await AppDirectories.getAvatarCacheDirectory();
    final logsDir = Directory(p.join(root.path, 'logs'));

    // Real iOS app tmp directory (<container>/tmp, via platform channel).
    // path_provider's getTemporaryDirectory() returns Caches on iOS, so the
    // true tmp dir — where file_picker / image_picker / image_cropper / the
    // paste-image channel copy files that are never cleaned up — is only
    // reachable through the channel. Null on every other platform: Android's
    // tmp IS the system cache dir (already counted above); macOS/Windows/Linux
    // system temp is outside the app container and never counted.
    final iosTmpPath = await IosTmpDirectory.getPath();

    // Platform cache directory (e.g. Android /data/user/0/<package>/cache).
    try {
      if (await systemCacheDir.exists()) {
        await _scanFilesConcurrently(
          systemCacheDir,
          progress: progress,
          onFile: (ent, bytes) {
            byCat[StorageUsageCategoryKey.cache]!.add(bytes);
            cacheSubs['system_cache']!.add(bytes);
          },
        );
      }
    } catch (e) {
      debugPrint(
        'StorageUsageService: failed to scan system cache '
        '${systemCacheDir.path}: $e',
      );
    }

    if (iosTmpPath != null) {
      final tmpDir = Directory(iosTmpPath);
      try {
        if (await tmpDir.exists()) {
          await _scanFilesConcurrently(
            tmpDir,
            progress: progress,
            onFile: (ent, bytes) {
              byCat[StorageUsageCategoryKey.cache]!.add(bytes);
              cacheSubs['tmp_cache']!.add(bytes);
            },
          );
        }
      } catch (e) {
        debugPrint('StorageUsageService: failed to scan iOS tmp dir: $e');
      }
    }

    final clearable = StorageUsageStats(
      fileCount:
          byCat[StorageUsageCategoryKey.cache]!.fileCount +
          byCat[StorageUsageCategoryKey.logs]!.fileCount +
          byCat[StorageUsageCategoryKey.sandbox]!.fileCount,
      bytes:
          byCat[StorageUsageCategoryKey.cache]!.bytes +
          byCat[StorageUsageCategoryKey.logs]!.bytes +
          byCat[StorageUsageCategoryKey.sandbox]!.bytes,
    );

    final categories = <StorageUsageCategory>[
      StorageUsageCategory(
        key: StorageUsageCategoryKey.images,
        stats: byCat[StorageUsageCategoryKey.images]!.toStats(),
      ),
      StorageUsageCategory(
        key: StorageUsageCategoryKey.files,
        stats: byCat[StorageUsageCategoryKey.files]!.toStats(),
      ),
      StorageUsageCategory(
        key: StorageUsageCategoryKey.chatData,
        stats: byCat[StorageUsageCategoryKey.chatData]!.toStats(),
        subcategories: [
          for (final e in chatSubs.entries)
            if (e.value.bytes > 0 || e.value.fileCount > 0)
              StorageUsageSubcategory(
                id: e.key,
                stats: e.value.toStats(),
                path: p.join(root.path, _chatDatabaseFileName(e.key)),
              ),
        ],
      ),
      StorageUsageCategory(
        key: StorageUsageCategoryKey.assistantData,
        stats: byCat[StorageUsageCategoryKey.assistantData]!.toStats(),
        subcategories: [
          StorageUsageSubcategory(
            id: 'avatars',
            stats: assistantSubs['avatars']!.toStats(),
            path: avatarsDir.path,
          ),
        ],
      ),
      StorageUsageCategory(
        key: StorageUsageCategoryKey.workspaces,
        stats: byCat[StorageUsageCategoryKey.workspaces]!.toStats(),
      ),
      StorageUsageCategory(
        key: StorageUsageCategoryKey.skills,
        stats: byCat[StorageUsageCategoryKey.skills]!.toStats(),
      ),
      StorageUsageCategory(
        key: StorageUsageCategoryKey.fonts,
        stats: byCat[StorageUsageCategoryKey.fonts]!.toStats(),
      ),
      StorageUsageCategory(
        key: StorageUsageCategoryKey.sandbox,
        stats: byCat[StorageUsageCategoryKey.sandbox]!.toStats(),
        subcategories: [
          StorageUsageSubcategory(
            id: 'sandbox_per_ws',
            stats: sandboxSubs['sandbox_per_ws']!.toStats(),
            path: workspacesRoot.path,
          ),
          if (sandboxSubs['sandbox_shared_runtime']!.bytes > 0 ||
              sandboxSubs['sandbox_shared_runtime']!.fileCount > 0)
            StorageUsageSubcategory(
              id: 'sandbox_shared_runtime',
              stats: sandboxSubs['sandbox_shared_runtime']!.toStats(),
              path: sandboxRuntime.path,
            ),
        ],
      ),
      StorageUsageCategory(
        key: StorageUsageCategoryKey.cache,
        stats: byCat[StorageUsageCategoryKey.cache]!.toStats(),
        subcategories: [
          StorageUsageSubcategory(
            id: 'avatar_cache',
            stats: cacheSubs['avatar_cache']!.toStats(),
            path: avatarCacheDir.path,
          ),
          StorageUsageSubcategory(
            id: 'other_cache',
            stats: cacheSubs['other_cache']!.toStats(),
            path: cacheDir.path,
          ),
          if (cacheSubs['system_cache']!.bytes > 0 ||
              cacheSubs['system_cache']!.fileCount > 0)
            StorageUsageSubcategory(
              id: 'system_cache',
              stats: cacheSubs['system_cache']!.toStats(),
              path: systemCacheDir.path,
            ),
          if (iosTmpPath != null &&
              (cacheSubs['tmp_cache']!.bytes > 0 ||
                  cacheSubs['tmp_cache']!.fileCount > 0))
            StorageUsageSubcategory(
              id: 'tmp_cache',
              stats: cacheSubs['tmp_cache']!.toStats(),
              path: iosTmpPath,
            ),
        ],
      ),
      StorageUsageCategory(
        key: StorageUsageCategoryKey.logs,
        stats: byCat[StorageUsageCategoryKey.logs]!.toStats(),
        subcategories: [
          StorageUsageSubcategory(
            id: 'flutter_logs',
            stats: logsSubs['flutter_logs']!.toStats(),
            path: logsDir.path,
          ),
          StorageUsageSubcategory(
            id: 'request_logs',
            stats: logsSubs['request_logs']!.toStats(),
            path: logsDir.path,
          ),
          if (logsSubs['other_logs']!.bytes > 0 ||
              logsSubs['other_logs']!.fileCount > 0)
            StorageUsageSubcategory(
              id: 'other_logs',
              stats: logsSubs['other_logs']!.toStats(),
              path: logsDir.path,
            ),
        ],
      ),
      // Deleted records — informational entry (actual bytes loaded by the
      // trash detail page via DeletedRecordsStore, not via filesystem scan).
      StorageUsageCategory(
        key: StorageUsageCategoryKey.deletedRecords,
        stats: const StorageUsageStats(fileCount: 0, bytes: 0),
      ),
    ];

    // Ensure consistent ordering.
    categories.sort(
      (a, b) => _categoryOrder
          .indexOf(a.key)
          .compareTo(_categoryOrder.indexOf(b.key)),
    );

    return StorageUsageReport(
      totalBytes: progress.bytes,
      totalFiles: progress.files,
      clearable: clearable,
      categories: categories,
    );
  }

  /// Streams every file under [dir] recursively, resolving sizes in bounded
  /// batches of [_scanBatchSize] so huge trees (e.g. sandbox rootfs with tens
  /// of thousands of files) do not flood the event loop with concurrent IO
  /// requests. [onFile] is called once per file with its byte size (0 when
  /// stat fails); running totals are emitted after every batch through
  /// [progress].
  ///
  /// A single unreadable subdirectory used to fail the whole scan: the old
  /// `list(recursive: true)` stream threw and the caller swallowed it, so the
  /// storage page reported 0 bytes for every category except the separately
  /// scanned sandbox (real incident). Each subdirectory is now recursed
  /// individually, so a failing entry is logged and skipped instead of
  /// zeroing the entire app data scan.
  static Future<void> _scanFilesConcurrently(
    Directory dir, {
    required void Function(File file, int bytes) onFile,
    required _ScanProgress progress,
  }) async {
    var batch = <File>[];
    await for (final ent in dir.list(followLinks: false)) {
      if (ent is Directory) {
        try {
          await _scanFilesConcurrently(ent, onFile: onFile, progress: progress);
        } catch (e) {
          debugPrint(
            'StorageUsageService: skipping unreadable directory '
            '${ent.path}: $e',
          );
        }
      } else if (ent is File) {
        batch.add(ent);
        if (batch.length >= _scanBatchSize) {
          await _resolveScanBatch(batch, onFile, progress);
          batch = <File>[];
        }
      }
    }
    if (batch.isNotEmpty) {
      await _resolveScanBatch(batch, onFile, progress);
    }
  }

  static const _scanBatchSize = 32;

  static Future<void> _resolveScanBatch(
    List<File> batch,
    void Function(File file, int bytes) onFile,
    _ScanProgress progress,
  ) async {
    final sizes = await Future.wait([
      for (final f in batch) f.length().catchError((_) => 0),
    ]);
    for (var i = 0; i < batch.length; i++) {
      progress.files += 1;
      progress.bytes += sizes[i];
      onFile(batch[i], sizes[i]);
    }
    progress.onEmit(progress.files, progress.bytes);
  }

  /// Walks [dir] recursively, invoking [onFile] once per file.
  ///
  /// A single `list(recursive: true)` stream would abort at the first
  /// unreadable subdirectory and silently drop every file traversed after
  /// it — the same failure mode [listCacheEntries] used to have and the one
  /// that produced the zero-usage incident documented on
  /// [_scanFilesConcurrently]. Each subdirectory is therefore recursed
  /// individually: a failing directory is logged and skipped while its
  /// siblings keep being traversed. A failure to list the walked root itself
  /// is not caught here — the caller logs it and returns partial results.
  static Future<void> _listFilesTolerantly(
    Directory dir, {
    required Future<void> Function(File file) onFile,
  }) async {
    await for (final ent in dir.list(followLinks: false)) {
      if (ent is Directory) {
        try {
          await _listFilesTolerantly(ent, onFile: onFile);
        } catch (e) {
          debugPrint(
            'StorageUsageService: skipping unreadable directory '
            '${ent.path}: $e',
          );
        }
      } else if (ent is File) {
        await onFile(ent);
      }
    }
  }

  /// Categorizes a workspace tree entry: per-workspace Linux sandboxes
  /// (.sandbox: rootfs, tmp, staged dependency archives) are counted
  /// separately so they can be cleared; everything else under a workspace
  /// is user files.
  static void _addWorkspaceEntry(
    List<String> parts,
    int bytes,
    Map<StorageUsageCategoryKey, _MutableStats> byCat,
    Map<String, _MutableStats> sandboxSubs,
  ) {
    if (parts.any((part) => part.toLowerCase() == '.sandbox')) {
      byCat[StorageUsageCategoryKey.sandbox]!.add(bytes);
      sandboxSubs['sandbox_per_ws']!.add(bytes);
    } else {
      byCat[StorageUsageCategoryKey.workspaces]!.add(bytes);
    }
  }

  static Future<void> clearCache({required bool avatarsOnly}) async {
    if (avatarsOnly) {
      final dir = await AppDirectories.getAvatarCacheDirectory();
      await _deleteDirectoryContents(dir);
      AvatarCache.clearMemory();
      return;
    }
    final dir = await AppDirectories.getCacheDirectory();
    await _deleteDirectoryContents(dir);
    try {
      final sys = await AppDirectories.getSystemCacheDirectory();
      await _deleteDirectoryContents(sys);
    } catch (_) {}
    AvatarCache.clearMemory();
  }

  static Future<void> clearOtherCache() async {
    final cacheDir = await AppDirectories.getCacheDirectory();
    final avatarCacheDir = await AppDirectories.getAvatarCacheDirectory();
    if (!await cacheDir.exists()) return;

    final String avatarAbs = p.normalize(
      Directory(avatarCacheDir.path).absolute.path,
    );
    try {
      await for (final ent in cacheDir.list(
        recursive: false,
        followLinks: false,
      )) {
        try {
          final entAbs = p.normalize(p.absolute(ent.path));
          if (p.equals(entAbs, avatarAbs)) continue;
          await ent.delete(recursive: true);
        } catch (_) {}
      }
    } catch (_) {}
  }

  static Future<void> clearSystemCache() async {
    try {
      final dir = await AppDirectories.getSystemCacheDirectory();
      await _deleteDirectoryContents(dir);
    } catch (_) {}
  }

  /// Clears the real iOS app tmp directory contents (directory itself is
  /// kept). No-op when the platform channel is unavailable (non-iOS).
  ///
  /// Per-file failures are tolerated by [_deleteDirectoryContents] (a locked
  /// file is truncated instead of removed), matching the other `clearX`
  /// methods; directory-level failures (e.g. the dir cannot be listed) throw
  /// and are surfaced by the caller's error snackbar.
  static Future<void> clearTmpCache() async {
    final iosTmpPath = await IosTmpDirectory.getPath();
    if (iosTmpPath == null) return;
    await _deleteDirectoryContents(Directory(iosTmpPath));
  }

  static Future<void> clearLogs() async {
    final flutterOn = FlutterLogger.enabled;
    final requestOn = RequestLogger.enabled;

    try {
      if (flutterOn) await FlutterLogger.setEnabled(false);
    } catch (_) {}
    try {
      if (requestOn) await RequestLogger.setAllEnabled(false);
    } catch (_) {}

    try {
      final root = await AppDirectories.getAppDataDirectory();
      final logsDir = Directory(p.join(root.path, 'logs'));
      await _deleteDirectoryContents(logsDir);
    } finally {
      try {
        if (flutterOn) await FlutterLogger.setEnabled(true);
      } catch (_) {}
      try {
        if (requestOn) await RequestLogger.setAllEnabled(true);
      } catch (_) {}
    }
  }

  /// Clears the Linux sandbox: every managed workspace's `.sandbox` directory
  /// (rootfs, tmp, staged dependency archives — all regenerable by
  /// re-installing dependencies) plus the shared runtime. Workspace user
  /// files are never touched.
  ///
  /// Returns true when the shared runtime was kept because the iOS iSH kernel
  /// is booted (deleting a live fakefs mount would corrupt the guest; it is
  /// removed on a later clear after relaunch, mirroring
  /// ChatService.clearAllData).
  static Future<bool> clearSandbox({
    required List<String> workspaceHostPaths,
    Future<void> Function()? stopTerminals,
  }) async {
    try {
      await (stopTerminals ??
          WorkspaceTerminalNativeBridge.instance.stopAllSessions)();
    } catch (error) {
      if (error is WorkspaceTerminalStopException) rethrow;
      throw WorkspaceTerminalStopException(error);
    }
    for (final host in workspaceHostPaths) {
      final sandboxDir = Directory(p.join(host, '.sandbox'));
      if (!await sandboxDir.exists()) continue;
      try {
        await sandboxDir.delete(recursive: true);
      } catch (e) {
        debugPrint(
          'StorageUsageService.clearSandbox: failed to delete '
          '$host/.sandbox: $e',
        );
      }
    }

    final runtime = await AppDirectories.getLinuxSandboxRuntimeDirectory();
    if (!await runtime.exists()) return false;
    if (Platform.isIOS &&
        await LinuxSandboxService.instance.isIosKernelBooted()) {
      debugPrint(
        'StorageUsageService.clearSandbox: iOS sandbox kernel booted; '
        'keeping shared runtime until relaunch',
      );
      return true;
    }
    try {
      await runtime.delete(recursive: true);
    } catch (e) {
      debugPrint(
        'StorageUsageService.clearSandbox: failed to delete shared '
        'runtime ${runtime.path}: $e',
      );
    }
    return false;
  }

  static Future<List<StorageFileEntry>> listUploadEntries({
    required bool images,
  }) async {
    final dir = await AppDirectories.getUploadDirectory();
    final imagesDir = await AppDirectories.getImagesDirectory();
    final out = <StorageFileEntry>[];
    Future<void> addFromDir(
      Directory d, {
      required bool includeImages,
      required bool includeNonImages,
    }) async {
      if (!await d.exists()) return;
      try {
        await _listFilesTolerantly(
          d,
          onFile: (file) async {
            final name = p.basename(file.path);
            final isImg = _isImageExt(name);
            if (isImg && !includeImages) return;
            if (!isImg && !includeNonImages) return;
            int bytes = 0;
            DateTime modifiedAt = DateTime.fromMillisecondsSinceEpoch(0);
            try {
              final stat = await file.stat();
              bytes = stat.size;
              modifiedAt = stat.modified;
            } catch (_) {
              try {
                bytes = await file.length();
              } catch (_) {}
            }
            out.add(
              StorageFileEntry(
                path: file.path,
                name: name,
                bytes: bytes,
                modifiedAt: modifiedAt,
              ),
            );
          },
        );
      } catch (e) {
        debugPrint(
          'StorageUsageService: failed to list upload dir ${d.path}: $e',
        );
      }
    }

    // Chat attachments live under upload/. Inline/generated images live under images/.
    await addFromDir(dir, includeImages: images, includeNonImages: !images);
    if (images) {
      await addFromDir(imagesDir, includeImages: true, includeNonImages: false);
    }
    out.sort((a, b) => b.modifiedAt.compareTo(a.modifiedAt));
    return out;
  }

  static Future<int> deleteUploadFiles(
    Iterable<String> paths, {
    required bool images,
  }) async {
    final dir = await AppDirectories.getUploadDirectory();
    final imagesDir = await AppDirectories.getImagesDirectory();
    final roots = <String>[
      p.normalize(Directory(dir.path).absolute.path),
      if (images) p.normalize(Directory(imagesDir.path).absolute.path),
    ];
    int deleted = 0;
    for (final raw in paths) {
      try {
        final abs = p.normalize(File(raw).absolute.path);
        final allowed = roots.any(
          (root) => p.isWithin(root, abs) || abs == root,
        );
        if (!allowed) continue;
        final f = File(abs);
        if (await f.exists()) {
          await f.delete();
          deleted += 1;
        }
      } catch (e) {
        debugPrint(
          'StorageUsageService.deleteUploadFiles: failed to delete $raw: $e',
        );
      }
    }
    return deleted;
  }

  /// Lists every file [clearCache]/[clearOtherCache]/[clearSystemCache]/
  /// [clearTmpCache] would delete for the given cache [subcategoryId], so the
  /// storage page can show exactly which files are judged as cache before
  /// clearing. Mirrors the clear methods' boundaries:
  /// - 'avatar_cache': everything under `appData/cache/avatars`
  /// - 'other_cache':  everything under `appData/cache` except avatars
  /// - 'system_cache': platform application cache directory
  /// - 'tmp_cache':    real iOS tmp dir (empty on other platforms)
  ///
  /// Sorted by size descending (largest first). Unknown ids return an empty
  /// list. Unreadable subdirectories are logged and skipped while their
  /// siblings keep being traversed (see [_listFilesTolerantly]); a failure
  /// to list the root itself is logged and the partial results are returned,
  /// never thrown.
  static Future<List<StorageFileEntry>> listCacheEntries({
    required String subcategoryId,
  }) async {
    final out = <StorageFileEntry>[];

    final cacheDir = await AppDirectories.getCacheDirectory();
    final avatarCacheDir = await AppDirectories.getAvatarCacheDirectory();
    final systemCacheDir = await AppDirectories.getSystemCacheDirectory();

    Directory root;
    String? excludedRoot;
    switch (subcategoryId) {
      case 'avatar_cache':
        root = Directory(avatarCacheDir.path);
        break;
      case 'other_cache':
        root = Directory(cacheDir.path);
        excludedRoot = p.normalize(
          Directory(avatarCacheDir.path).absolute.path,
        );
        break;
      case 'system_cache':
        root = Directory(systemCacheDir.path);
        break;
      case 'tmp_cache':
        final iosTmpPath = await IosTmpDirectory.getPath();
        if (iosTmpPath == null) return out;
        root = Directory(iosTmpPath);
        break;
      default:
        return out;
    }

    if (!await root.exists()) return out;

    try {
      await _listFilesTolerantly(
        root,
        onFile: (file) async {
          final abs = p.normalize(file.absolute.path);
          if (excludedRoot != null && p.isWithin(excludedRoot, abs)) return;
          int bytes = 0;
          DateTime modifiedAt = DateTime.fromMillisecondsSinceEpoch(0);
          try {
            final stat = await file.stat();
            bytes = stat.size;
            modifiedAt = stat.modified;
          } catch (_) {
            try {
              bytes = await file.length();
            } catch (_) {}
          }
          out.add(
            StorageFileEntry(
              path: file.path,
              name: p.basename(file.path),
              bytes: bytes,
              modifiedAt: modifiedAt,
            ),
          );
        },
      );
    } catch (e) {
      debugPrint(
        'StorageUsageService: failed to list cache dir ${root.path}: $e',
      );
    }

    out.sort((a, b) {
      final r = a.bytes.compareTo(b.bytes);
      if (r != 0) return -r;
      return a.modifiedAt.compareTo(b.modifiedAt);
    });
    return out;
  }

  /// Deletes the given files from one cache subcategory, validating every
  /// path against the same roots [listCacheEntries] reports. Paths outside
  /// the allowed root, or inside the excluded 'avatars' root for
  /// 'other_cache', are skipped. Returns the number of files actually
  /// deleted.
  static Future<int> deleteCacheFiles(
    Iterable<String> paths, {
    required String subcategoryId,
  }) async {
    final cacheDir = await AppDirectories.getCacheDirectory();
    final avatarCacheDir = await AppDirectories.getAvatarCacheDirectory();
    final systemCacheDir = await AppDirectories.getSystemCacheDirectory();

    final roots = <String>[];
    String? excludedRoot;
    switch (subcategoryId) {
      case 'avatar_cache':
        roots.add(p.normalize(Directory(avatarCacheDir.path).absolute.path));
        break;
      case 'other_cache':
        roots.add(p.normalize(Directory(cacheDir.path).absolute.path));
        excludedRoot = p.normalize(
          Directory(avatarCacheDir.path).absolute.path,
        );
        break;
      case 'system_cache':
        roots.add(p.normalize(Directory(systemCacheDir.path).absolute.path));
        break;
      case 'tmp_cache':
        final iosTmpPath = await IosTmpDirectory.getPath();
        if (iosTmpPath == null) return 0;
        roots.add(p.normalize(Directory(iosTmpPath).absolute.path));
        break;
      default:
        return 0;
    }

    int deleted = 0;
    for (final raw in paths) {
      try {
        final abs = p.normalize(File(raw).absolute.path);
        final allowed = roots.any(
          (root) => p.isWithin(root, abs) || abs == root,
        );
        if (!allowed) continue;
        if (excludedRoot != null && p.isWithin(excludedRoot, abs)) continue;
        final f = File(abs);
        if (await f.exists()) {
          await f.delete();
          deleted += 1;
        }
      } catch (e) {
        debugPrint(
          'StorageUsageService.deleteCacheFiles: failed to delete $raw: $e',
        );
      }
    }
    return deleted;
  }

  static Future<void> _deleteDirectoryContents(Directory dir) async {
    if (!await dir.exists()) return;
    try {
      await for (final ent in dir.list(recursive: true, followLinks: false)) {
        try {
          if (ent is File) {
            try {
              await ent.delete();
            } catch (_) {
              // Some platforms lock active log files; try truncating.
              try {
                await ent.writeAsBytes(const <int>[], flush: true);
              } catch (_) {}
            }
          } else if (ent is Directory) {
            // We'll delete empty dirs in a second pass.
          } else {
            try {
              await ent.delete();
            } catch (_) {}
          }
        } catch (_) {}
      }

      // Delete empty directories bottom-up.
      final dirs = <Directory>[];
      await for (final ent in dir.list(recursive: true, followLinks: false)) {
        if (ent is Directory) dirs.add(ent);
      }
      dirs.sort((a, b) => b.path.length.compareTo(a.path.length));
      for (final d in dirs) {
        try {
          if (await d.exists()) {
            await d.delete();
          }
        } catch (_) {}
      }
    } catch (_) {}
  }
}

class _ScanProgress {
  _ScanProgress(this.onEmit);

  final void Function(int files, int bytes) onEmit;
  int files = 0;
  int bytes = 0;
}

class _MutableStats {
  int fileCount = 0;
  int bytes = 0;
  void add(int b) {
    fileCount += 1;
    bytes += b;
  }

  StorageUsageStats toStats() =>
      StorageUsageStats(fileCount: fileCount, bytes: bytes);
}

const List<StorageUsageCategoryKey> _categoryOrder = <StorageUsageCategoryKey>[
  StorageUsageCategoryKey.images,
  StorageUsageCategoryKey.files,
  StorageUsageCategoryKey.chatData,
  StorageUsageCategoryKey.assistantData,
  StorageUsageCategoryKey.workspaces,
  StorageUsageCategoryKey.skills,
  StorageUsageCategoryKey.fonts,
  StorageUsageCategoryKey.sandbox,
  StorageUsageCategoryKey.cache,
  StorageUsageCategoryKey.logs,
  StorageUsageCategoryKey.deletedRecords,
  StorageUsageCategoryKey.other,
];
