import 'dart:io';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

/// Whether one path segment may be joined onto the app data root.
///
/// Written against both filesystems at once, because a workspace id travels
/// between platforms: a separator of either flavour, a NUL, an empty or dot
/// segment, a drive/alternate-stream colon, a trailing dot or space (Windows
/// silently strips both, so `evil. ` and `evil` are the same file there) and a
/// DOS device name are all rejected.
bool isSafePathSegment(String segment) {
  if (segment.isEmpty || segment == '.' || segment == '..') return false;
  if (segment.contains('/') || segment.contains('\\')) return false;
  if (segment.contains('\u0000')) return false;
  if (segment.contains(':')) return false;
  if (segment.endsWith('.') || segment.endsWith(' ')) return false;
  return !_isReservedWindowsName(segment);
}

/// Whether [id] may name a directory under `<appData>/workspaces`.
///
/// This device creates workspace ids as UUIDs, but an id also arrives from the
/// wire (LAN sync) and from a backup. It is a single path segment or it is not
/// a workspace id at all: `..` would name a directory *outside* the managed
/// tree, which the file plane would then index, advertise to the peer and — on
/// a delete — remove recursively.
bool isSafeWorkspaceId(String id) => isSafePathSegment(id);

/// The DOS device names Windows refuses (or resolves to a device) even with an
/// extension attached. A peer that names one is asking this device to write
/// somewhere that is not a file in the workspace.
bool _isReservedWindowsName(String segment) {
  final stem = segment.split('.').first.toLowerCase();
  if (stem == 'con' || stem == 'prn' || stem == 'aux' || stem == 'nul') {
    return true;
  }
  if (stem.length == 4 &&
      (stem.startsWith('com') || stem.startsWith('lpt')) &&
      stem[3].codeUnitAt(0) >= 0x31 &&
      stem[3].codeUnitAt(0) <= 0x39) {
    return true;
  }
  return false;
}

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

  /// Gets the directory for cache files.
  static Future<Directory> getCacheDirectory() async {
    final root = await getAppDataDirectory();
    return Directory('${root.path}/cache');
  }

  /// Managed workspace roots: `<appData>/workspaces`.
  static Future<Directory> getWorkspacesDirectory() =>
      _ensureSubdir('workspaces');

  /// Per-conversation session roots: `<appData>/sessions`.
  static Future<Directory> getSessionsDirectory() => _ensureSubdir('sessions');

  /// Installed skill bodies: `<appData>/skills`.
  static Future<Directory> getSkillsDirectory() => _ensureSubdir('skills');

  /// Sandbox environment install root: `<appData>/environment`.
  static Future<Directory> getEnvironmentDirectory() =>
      _ensureSubdir('environment');

  /// LAN sync device state: `<appData>/sync` (identity, peers, checkpoints).
  /// Deliberately outside the backup face — the device private key and the
  /// per-peer checkpoints are device-local by definition (ADR-0003).
  static Future<Directory> getSyncDirectory() => _ensureSubdir(syncDirName);

  /// The sync directory's name under the app data root. Exported because the
  /// restore cutover resets sync state before any provider exists and so
  /// builds the path itself (see `SyncStore.resetForBulkReplacement`).
  static const syncDirName = 'sync';

  /// The recycle bin: `<appData>/recycle`.
  ///
  /// Holds what a deletion removed and what a losing last-write-wins comparison
  /// replaced, so either can be undone. Deliberately outside the backup face
  /// and outside every sync manifest — the same standing as [getSyncDirectory]:
  /// this is one device's own safety net, not shared state.
  static Future<Directory> getRecycleDirectory() =>
      _ensureSubdir(recycleDirName);

  /// The recycle directory's name under the app data root. Exported because the
  /// storage-space report measures it by name while walking that root.
  static const recycleDirName = 'recycle';

  /// Files root for a managed workspace: `<appData>/workspaces/<id>/files`.
  ///
  /// Throws for an id that is not a single safe path segment. The id arrives
  /// from the wire and from a backup, and this is the last place before it
  /// becomes a filesystem path — see [isSafeWorkspaceId].
  static Future<Directory> workspaceFilesDir(String workspaceId) async {
    if (!isSafeWorkspaceId(workspaceId)) {
      throw ArgumentError.value(
        workspaceId,
        'workspaceId',
        'not a single safe path segment',
      );
    }
    return _ensurePath('workspaces/$workspaceId/files');
  }

  /// Session root for a conversation, with `attachments/` and `outputs/`.
  static Future<Directory> sessionDir(String conversationId) async {
    final dir = await _ensurePath('sessions/$conversationId');
    await Directory('${dir.path}/attachments').create(recursive: true);
    await Directory('${dir.path}/outputs').create(recursive: true);
    return dir;
  }

  /// Skill body directory: `<appData>/skills/<id>`.
  static Future<Directory> skillDir(String skillId) {
    return _ensurePath('skills/$skillId');
  }

  static Future<Directory> _ensureSubdir(String name) => _ensurePath(name);

  static Future<Directory> _ensurePath(String relativePath) async {
    final root = await getAppDataDirectory();
    final dir = Directory('${root.path}/$relativePath');
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    return dir;
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
