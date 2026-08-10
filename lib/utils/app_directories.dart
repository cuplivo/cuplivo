import 'dart:io';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'platform_utils.dart';

/// Platform-specific application data directory utilities.
///
/// - Windows/macOS/Linux: use the Application Support (app data) directory
///   provided by `path_provider`.
/// - Android/iOS: keep using the Application Documents directory.
class AppDirectories {
  AppDirectories._();

  /// Gets the root directory for application data storage.
  ///
  /// - Windows/macOS/Linux: Application Support directory
  /// - Android/iOS: Application Documents directory
  static Future<Directory> getAppDataDirectory() async {
    switch (defaultTargetPlatform) {
      case TargetPlatform.windows:
      case TargetPlatform.macOS:
      case TargetPlatform.linux:
        return await getApplicationSupportDirectory();
      case TargetPlatform.android:
      case TargetPlatform.iOS:
      case TargetPlatform.fuchsia:
        return await getApplicationDocumentsDirectory();
    }
  }

  /// Gets the directory for uploaded files.
  static Future<Directory> getUploadDirectory() async {
    final root = await getAppDataDirectory();
    return Directory('${root.path}/upload');
  }

  /// Gets the directory for image files.
  static Future<Directory> getImagesDirectory() async {
    final root = await getAppDataDirectory();
    return Directory('${root.path}/images');
  }

  /// Gets the directory for avatar files.
  static Future<Directory> getAvatarsDirectory() async {
    final root = await getAppDataDirectory();
    return Directory('${root.path}/avatars');
  }

  /// Gets the directory for user-imported font files.
  static Future<Directory> getFontsDirectory() async {
    final root = await getAppDataDirectory();
    return Directory('${root.path}/fonts');
  }

  /// Gets the directory for skill files.
  static Future<Directory> getSkillsDirectory() async {
    final root = await getAppDataDirectory();
    return Directory('${root.path}/skills');
  }

  /// Gets the directory for the built-in `@workspaces` filesystem sandbox.
  ///
  /// Desktop users may relocate the sandbox via the storage mounts settings
  /// (`workspaces_dir_v1`); the preference is honored on desktop only, so a
  /// backup restored on mobile can never point the sandbox at a foreign
  /// host path (mount configs are device-local, see CONTEXT.md). The value
  /// is re-validated at load (`_isSafeWorkspacesLocation`): a restored or
  /// hand-edited pref that is relative, a filesystem root, or overlapping a
  /// fixed sync tree falls back to the default location with a log — the
  /// write-time guards cannot cover the settings.json restore door.
  static Future<Directory> getWorkspacesDirectory() async {
    if (PlatformUtils.isDesktopTarget) {
      try {
        final prefs = await SharedPreferences.getInstance();
        final custom = prefs.getString(workspacesDirPrefsKey);
        if (custom != null &&
            custom.isNotEmpty &&
            await _isSafeWorkspacesLocation(custom)) {
          return Directory(custom);
        }
        if (custom != null && custom.isNotEmpty) {
          debugPrint(
            'AppDirectories: ignoring unsafe workspaces location: $custom',
          );
        }
      } catch (e) {
        debugPrint('AppDirectories: failed to read workspaces location: $e');
      }
    }
    final root = await getAppDataDirectory();
    return Directory('${root.path}/workspaces');
  }

  /// Load-time safety check for [workspacesDirPrefsKey]: the path must be
  /// absolute, must not be a filesystem root (a sandbox at `C:/` or `/`
  /// would sweep the whole volume into every backup pack), and must not
  /// overlap the fixed sync trees (upload/images/avatars/fonts/skills).
  /// The workspaces tree itself is excluded — the pref IS the workspaces
  /// location being validated.
  static Future<bool> _isSafeWorkspacesLocation(String path) async {
    final trimmed = path.trim();
    if (trimmed.isEmpty || !_looksAbsolute(trimmed)) return false;
    if (isFilesystemRootPath(trimmed)) return false;
    final roots = await getSyncRootPaths(includeWorkspaces: false);
    for (final r in roots) {
      if (pathsOverlap(trimmed, r)) return false;
    }
    return true;
  }

  /// True when [path] canonicalizes to a filesystem root. Platform trap: a
  /// drive root normalizes differently per platform — Windows keeps the
  /// trailing slash (`C:/`), POSIX strips it to a bare drive letter (`C:`)
  /// — so both forms must be recognized (and a bare letter drive is exactly
  /// what a Windows restore value becomes on a POSIX host).
  static bool isFilesystemRootPath(String path) {
    final canon = canonPath(path);
    return canon == '/' ||
        (canon.length <= 3 && canon.endsWith('/')) ||
        RegExp(r'^[a-zA-Z]:$').hasMatch(canon);
  }

  static bool _looksAbsolute(String path) {
    if (path.startsWith('/') || path.startsWith('\\\\')) return true;
    if (path.length < 3) return false;
    final c0 = path.codeUnitAt(0);
    final isLetter = (c0 >= 0x41 && c0 <= 0x5a) || (c0 >= 0x61 && c0 <= 0x7a);
    return isLetter && path[1] == ':' && (path[2] == '/' || path[2] == '\\');
  }

  /// SharedPreferences key holding the user-relocatable `@workspaces` host
  /// directory (desktop only; see [getWorkspacesDirectory]).
  static const String workspacesDirPrefsKey = 'workspaces_dir_v1';

  /// The directories packed into backups and LAN sync zips (mtime-filtered,
  /// `includeFiles`-gated). Used to reject mounts/relocations that would
  /// silently overlap the sync scope.
  static Future<List<String>> getSyncRootPaths({
    bool includeWorkspaces = true,
  }) async {
    final root = await getAppDataDirectory();
    return [
      '${root.path}/upload',
      '${root.path}/images',
      '${root.path}/avatars',
      '${root.path}/fonts',
      '${root.path}/skills',
      if (includeWorkspaces) (await getWorkspacesDirectory()).path,
    ];
  }

  /// Canonicalized path for sync-tree overlap comparisons: normalized,
  /// forward slashes, Windows case-folded, trailing slashes stripped
  /// (roots like `C:/` are preserved).
  static String canonPath(String path) {
    var normalized = p.normalize(path).replaceAll('\\', '/');
    if (Platform.isWindows) normalized = normalized.toLowerCase();
    while (normalized.length > 3 && normalized.endsWith('/')) {
      normalized = normalized.substring(0, normalized.length - 1);
    }
    return normalized;
  }

  /// True when [child] is [parent] or lives inside it (both canonicalized).
  /// Root parents (`C:/`, `/`) keep their trailing slash in [canonPath], so
  /// the prefix must not double it (`'c://'` would never match).
  static bool isPathInside(String child, String parent) {
    final c = canonPath(child);
    final pa = canonPath(parent);
    final prefix = pa.endsWith('/') ? pa : '$pa/';
    return c == pa || c.startsWith(prefix);
  }

  /// True when two paths overlap (one contains the other).
  static bool pathsOverlap(String a, String b) =>
      isPathInside(a, b) || isPathInside(b, a);

  /// Gets the directory for cache files.
  static Future<Directory> getCacheDirectory() async {
    final root = await getAppDataDirectory();
    return Directory('${root.path}/cache');
  }

  /// Gets the platform-provided application cache directory.
  ///
  /// - Android: /data/user/0/`<package>`/cache
  /// - iOS/macOS: Caches directory
  /// - Windows/Linux: platform cache directory (app-specific on Linux via XDG)
  static Future<Directory> getSystemCacheDirectory() async {
    return await getApplicationCacheDirectory();
  }

  /// Gets the directory for avatar cache files.
  static Future<Directory> getAvatarCacheDirectory() async {
    final root = await getAppDataDirectory();
    return Directory('${root.path}/cache/avatars');
  }

  /// Get file extension from MIME type
  static String extFromMime(String mime) {
    switch (mime.toLowerCase()) {
      case 'image/jpeg':
      case 'image/jpg':
        return 'jpg';
      case 'image/gif':
        return 'gif';
      case 'image/webp':
        return 'webp';
      default:
        return 'png';
    }
  }

  /// Save base64 image data to images directory.
  /// [prefix] is used for filename (e.g. 'img', 'mcp_img').
  /// Returns the saved file path, or null if failed.
  static Future<String?> saveBase64Image(
    String mime,
    String base64Data, {
    String prefix = 'img',
  }) async {
    try {
      final dir = await getImagesDirectory();
      if (!await dir.exists()) {
        await dir.create(recursive: true);
      }
      final cleaned = base64Data.replaceAll(RegExp(r'\s'), '');
      List<int> bytes;
      // Support both standard base64 and URL-safe base64
      if (cleaned.contains('-') || cleaned.contains('_')) {
        bytes = base64Url.decode(cleaned);
      } else {
        bytes = base64Decode(cleaned);
      }
      final ext = extFromMime(mime);
      final path =
          '${dir.path}/${prefix}_${DateTime.now().microsecondsSinceEpoch}.$ext';
      final file = File(path);
      await file.writeAsBytes(bytes, flush: true);
      return path;
    } catch (e) {
      debugPrint('Failed to save image: $e');
      return null;
    }
  }
}
