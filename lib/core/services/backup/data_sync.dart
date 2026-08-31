import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:archive/archive_io.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:xml/xml.dart';

import '../../models/assistant.dart';
import '../../models/backup.dart';
import '../../models/chat_message.dart';
import '../../models/conversation.dart';
import '../../models/group_chat.dart';
import '../../models/group_chat_member.dart';
import '../../models/incremental_backup.dart';
import '../chat/chat_service.dart';
import '../deleted_records_store.dart';
import '../mcp/kelivo_filesystem/kelivo_filesystem_server.dart'
    show isSafeWireSegment;
import '../sync/lan_sync_models.dart' show FileManifestEntry;
import '../../database/business_preferences.dart';
import '../../database/business_key_registry.dart';
import 'kelivo_image_settings_mapper.dart';
import 'kelivo_v2_exception.dart';
import 'double_pref_keys.dart';
import '../../../utils/app_directories.dart';

/// Stage of a restore-in-progress, for UI progress display.
enum RestoreStage {
  /// ZIP extraction (runs in an isolate — indeterminate).
  extracting,

  /// Chat / message merge into SQLite.
  mergingChats,

  /// File tree copying (upload/images/avatars/fonts/workspaces).
  copyingFiles,

  /// Skill file restore.
  restoringSkills,
}

/// Snapshot of restore progress.
///
/// [fraction] is null while the stage is indeterminate. [filesCopied] /
/// [filesTotal] and [bytesCopied] / [bytesTotal] are only meaningful during
/// [RestoreStage.copyingFiles]; [conversationsMerged] / [conversationsTotal]
/// during [RestoreStage.mergingChats].
class RestoreProgress {
  final RestoreStage stage;
  final double? fraction;
  final int filesCopied;
  final int filesTotal;
  final int bytesCopied;
  final int bytesTotal;
  final int conversationsMerged;
  final int conversationsTotal;

  const RestoreProgress({
    required this.stage,
    this.fraction,
    this.filesCopied = 0,
    this.filesTotal = 0,
    this.bytesCopied = 0,
    this.bytesTotal = 0,
    this.conversationsMerged = 0,
    this.conversationsTotal = 0,
  });
}

/// Optional progress callback threaded through a restore. Null for callers
/// that do not surface progress (backup page/pane, S3, BackupProvider).
typedef RestoreProgressCallback = void Function(RestoreProgress progress);

/// Stage of a backup build/upload in progress, for UI progress display.
enum BackupStage {
  /// Building the intermediate files (settings.json / chats.json /
  /// deleted.json) on the main isolate.
  generating,

  /// ZIP packing inside the isolate (`_packZipSync` — indeterminate).
  packing,

  /// Uploading the finished staging ZIP (WebDAV PUT / S3 PUT). Local
  /// `exportToFile` never enters this stage — delivery is the user's own
  /// save dialog.
  uploading,
}

/// Optional stage callback threaded through a backup. Null for callers that
/// do not surface progress (LAN sync, tests).
typedef BackupStageCallback = void Function(BackupStage stage);

/// Export wire format for a backup ZIP.
enum BackupFormat {
  /// Cuplivo v2: JSONL chat streams + chats_meta.json sentinel (default).
  jsonl,

  /// Kelivo-legacy v1: a single chats.json blob (version 1) + settings.json +
  /// deleted.json. Kelivo's legacy importer only accepts that shape; the
  /// JSONL v2 zips Cuplivo produces are NOT importable by Kelivo. Full
  /// backups only (incremental/LAN-sync always use [jsonl]).
  kelivoLegacy,
}

class DataSync {
  final ChatService chatService;
  final Future<Set<String>> Function(String type)? _localIdResolver;
  final BusinessPreferences _preferences;
  DataSync({
    required this.chatService,
    required this._preferences,
    this._localIdResolver,
  });

  // Kelivo's legacy chats.json importer only accepts version 1 (or a missing
  // field); anything else is rejected with FormatException. The legacy
  // export writer must keep this at 1.
  static const int _kelivoChatsJsonVersion = 1;

  // Proxy fields inside a provider config. Proxy is device-local: during a
  // merge restore these fields are never adopted from the backup for
  // providers that already exist locally (issue #512).
  static const List<String> _providerProxyFields = [
    'proxyEnabled',
    'proxyType',
    'proxyHost',
    'proxyPort',
    'proxyUsername',
    'proxyPassword',
  ];

  // The no-proxy state the app writes for fresh configs (mirrors
  // SettingsProvider's defaults). Used when a legacy local provider config
  // carries no proxy block at all, so the backup's proxy never survives even
  // in disabled form.
  static const Map<String, dynamic> _noProxyProviderDefaults = {
    'proxyEnabled': false,
    'proxyType': 'http',
    'proxyHost': '',
    'proxyPort': '8080',
    'proxyUsername': '',
    'proxyPassword': '',
  };

  // ===== WebDAV helpers =====
  Uri _collectionUri(WebDavConfig cfg) {
    String base = cfg.url.trim();
    if (base.endsWith('/')) base = base.substring(0, base.length - 1);
    String pathPart = cfg.path.trim();
    if (pathPart.isNotEmpty) {
      pathPart = '/${pathPart.replaceAll(RegExp(r'^/+'), '')}';
    }
    // Ensure trailing slash for collection
    final full = '$base$pathPart/';
    return Uri.parse(full);
  }

  Uri _fileUri(WebDavConfig cfg, String childName) {
    final base = _collectionUri(cfg).toString();
    final child = childName.replaceAll(RegExp(r'^/+'), '');
    return Uri.parse('$base$child');
  }

  Map<String, String> _authHeaders(WebDavConfig cfg) {
    if (cfg.username.trim().isEmpty) return {};
    final token = base64Encode(utf8.encode('${cfg.username}:${cfg.password}'));
    return {'Authorization': 'Basic $token'};
  }

  Map<String, String> _extraHeaders(WebDavConfig cfg) {
    final h = <String, String>{};
    final ua = cfg.userAgent.trim();
    if (ua.isNotEmpty) h['User-Agent'] = ua;
    return h;
  }

  Future<void> _ensureCollection(WebDavConfig cfg) async {
    final client = http.Client();
    try {
      // Ensure each segment exists
      final url = cfg.url.trim().replaceAll(RegExp(r'/+$'), '');
      final segments = cfg.path
          .split('/')
          .where((s) => s.trim().isNotEmpty)
          .toList();
      String acc = url;
      for (final seg in segments) {
        acc = '$acc/$seg';
        // PROPFIND depth 0 on this collection (with trailing slash)
        final u = Uri.parse('$acc/');
        final req = http.Request('PROPFIND', u);
        req.headers.addAll({
          'Depth': '0',
          'Content-Type': 'application/xml; charset=utf-8',
          ..._authHeaders(cfg),
          ..._extraHeaders(cfg),
        });
        req.body =
            '<?xml version="1.0" encoding="utf-8" ?><d:propfind xmlns:d="DAV:"><d:prop><d:displayname/></d:prop></d:propfind>';
        final res = await client.send(req).then(http.Response.fromStream);
        if (res.statusCode == 404) {
          // create this level
          final mk = await client
              .send(
                http.Request('MKCOL', u)
                  ..headers.addAll({
                    ..._authHeaders(cfg),
                    ..._extraHeaders(cfg),
                  }),
              )
              .then(http.Response.fromStream);
          if (mk.statusCode != 201 &&
              mk.statusCode != 200 &&
              mk.statusCode != 405) {
            throw Exception('MKCOL failed at $u: ${mk.statusCode}');
          }
        } else if (res.statusCode == 401) {
          throw Exception('Unauthorized');
        } else if (!(res.statusCode >= 200 && res.statusCode < 400)) {
          // Some servers return 207 Multi-Status; accept 2xx/3xx/207
          if (res.statusCode != 207) {
            throw Exception('PROPFIND error at $u: ${res.statusCode}');
          }
        }
      }
    } finally {
      client.close();
    }
  }

  // ===== Public APIs =====
  Future<void> testWebdav(WebDavConfig cfg) async {
    final uri = _collectionUri(cfg);
    final req = http.Request('PROPFIND', uri);
    req.headers.addAll({
      'Depth': '1',
      'Content-Type': 'application/xml; charset=utf-8',
      ..._authHeaders(cfg),
      ..._extraHeaders(cfg),
    });
    req.body =
        '<?xml version="1.0" encoding="utf-8" ?>\n'
        '<d:propfind xmlns:d="DAV:">\n'
        '  <d:prop>\n'
        '    <d:displayname/>\n'
        '  </d:prop>\n'
        '</d:propfind>';
    final res = await http.Client().send(req).then(http.Response.fromStream);
    if (res.statusCode != 207 &&
        (res.statusCode < 200 || res.statusCode >= 300)) {
      throw Exception('WebDAV test failed: ${res.statusCode}');
    }
  }

  Future<File> prepareBackupFile(
    WebDavConfig cfg, {
    IncrementalBackupConfig? incremental,
    BackupStageCallback? onStage,
    BackupFormat format = BackupFormat.jsonl,
  }) async {
    onStage?.call(BackupStage.generating);
    final tmp = await _ensureTempDir();
    await _cleanupPreviousBackupTempFiles(tmp);
    final now = DateTime.now();
    final isIncremental = incremental != null;
    final baseName = isIncremental
        ? _incrementalBaseName(now, incremental.since)
        : 'kelivo_backup_${_isoCompact(now)}';
    final workDir = Directory(p.join(tmp.path, baseName));
    await workDir.create(recursive: true);

    final outPath = p.join(workDir.path, '$baseName.zip');
    final outFile = File(outPath);
    if (await outFile.exists()) await outFile.delete();

    File? settingsTmp;
    File? settingsMetaTmp;
    File? chatsMetaTmp;
    File? conversationsTmp;
    File? messagesTmp;
    File? legacyChatsTmp;
    File? deletedJsonTmp;
    // Effective content scope. Kelivo-legacy exports are always whole-pack
    // (their importer needs the full settings/chats shape).
    final scope = format == BackupFormat.kelivoLegacy
        ? const BackupContentScope()
        : incremental?.effectiveScope ?? cfg.content;
    // Scope-mode splits settings.json into section-wise payloads (assistant
    // keys ride the chats bit). Legacy incremental runs (contentScope == null)
    // keep the old contract: settings.json appears iff includeSettings.
    final explicitScope =
        format == BackupFormat.kelivoLegacy ||
        incremental == null ||
        incremental.contentScope != null;
    try {
      // --- Step 1: Prepare temp files that need ChatService (main isolate) ---
      // settings.json — section-aware: assistant keys ride the chats bit,
      // everything else rides the settings bit.
      if (explicitScope ? scope.anySettings : scope.settings) {
        final payloads = await _exportSettingsPayloads();
        var settingsMap = payloads.settings;
        var settingsMeta = payloads.updatedAt;
        if (!scope.chatsAndAssistants || !scope.settings) {
          final split = _splitSettingsSections(
            settingsMap,
            settingsMeta,
            scope,
          );
          settingsMap = split.settings;
          settingsMeta = split.updatedAt;
        }
        settingsTmp = await _writeTempText(
          workDir,
          '_bk_settings.json',
          jsonEncode(settingsMap),
        );
        if (settingsMeta.isNotEmpty && format == BackupFormat.jsonl) {
          settingsMetaTmp = await _writeTempText(
            workDir,
            '_bk_settings_meta.json',
            jsonEncode(settingsMeta),
          );
        }
      }

      // chats payload — JSONL streams by default; single v1 blob for the
      // Kelivo-legacy format (whose importer cannot read JSONL).
      if (scope.chatsAndAssistants) {
        if (format == BackupFormat.kelivoLegacy) {
          legacyChatsTmp = await _exportChatsToLegacyFile(
            workDir,
            incremental: incremental,
          );
        } else {
          final metaFile = await _exportChatsToFile(
            workDir,
            incremental: incremental,
          );
          chatsMetaTmp = metaFile;
          final conversationsFile = File(
            p.join(workDir.path, '_bk_conversations.jsonl'),
          );
          final messagesFile = File(p.join(workDir.path, '_bk_messages.jsonl'));
          if (await conversationsFile.exists()) {
            conversationsTmp = conversationsFile;
          }
          if (await messagesFile.exists()) {
            messagesTmp = messagesFile;
          }
        }
      }

      // deleted.json — id-only tombstones for sync/backup (origin='local' only)
      if (scope.chatsAndAssistants) {
        try {
          final deletedJson = await buildDeletedJson(chatService.repo.db);
          deletedJsonTmp = await _writeTempText(
            workDir,
            '_bk_deleted.json',
            deletedJson,
          );
        } catch (e) {
          // Non-fatal: backup proceeds without deleted.json.
          debugPrint('prepareBackupFile: failed to write deleted.json: $e');
        }
      }

      // Resolve directory paths (need AppDirectories on main isolate)
      final uploadDirPath = (await _getUploadDir()).path;
      final avatarsDirPath = (await _getAvatarsDir()).path;
      final imagesDirPath = (await _getImagesDir()).path;
      final fontsDirPath = (await _getFontsDir()).path;
      final skillsDirPath = (await _getSkillsDir()).path;
      final workspacesDirPath = (await _getWorkspacesDir()).path;
      final settingsPath = settingsTmp?.path;
      final settingsMetaPath = settingsMetaTmp?.path;
      final chatsMetaPath = chatsMetaTmp?.path;
      final conversationsPath = conversationsTmp?.path;
      final messagesPath = messagesTmp?.path;
      final legacyChatsPath = legacyChatsTmp?.path;
      final deletedJsonPath = deletedJsonTmp?.path;

      // --- Step 2: Run CPU-heavy ZIP packing in a separate isolate ---
      onStage?.call(BackupStage.packing);
      final packSince = incremental?.since;
      final packIncludeFilePaths = incremental?.includeFilePaths;
      await Isolate.run(() {
        _packZipSync(
          outPath: outPath,
          settingsPath: settingsPath,
          settingsMetaPath: settingsMetaPath,
          chatsMetaPath: chatsMetaPath,
          conversationsPath: conversationsPath,
          messagesPath: messagesPath,
          legacyChatsPath: legacyChatsPath,
          deletedJsonPath: deletedJsonPath,
          scope: scope,
          since: packSince,
          includeFilePaths: packIncludeFilePaths,
          uploadDirPath: uploadDirPath,
          avatarsDirPath: avatarsDirPath,
          imagesDirPath: imagesDirPath,
          fontsDirPath: fontsDirPath,
          skillsDirPath: skillsDirPath,
          workspacesDirPath: workspacesDirPath,
        );
      });

      return outFile;
    } catch (_) {
      await _deleteDirectoryQuietly(workDir);
      rethrow;
    } finally {
      // Cleanup temp intermediate files. The final zip is returned to callers
      // and must be deleted by the upload/export caller after it is consumed.
      await _deleteFileQuietly(settingsTmp);
      await _deleteFileQuietly(settingsMetaTmp);
      await _deleteFileQuietly(chatsMetaTmp);
      await _deleteFileQuietly(conversationsTmp);
      await _deleteFileQuietly(messagesTmp);
      await _deleteFileQuietly(legacyChatsTmp);
      await _deleteFileQuietly(deletedJsonTmp);
    }
  }

  /// Generate base name (without extension) for incremental backup files.
  /// Format: cuplivo_incr_`export_ts`_`since_ts`
  ///   export_ts = YYYYMMDD-HHmmss-ffffff (date-microseconds)
  ///   since_ts  = YYYYMMDD-HHmmss          (date-seconds)
  static String _incrementalBaseName(DateTime now, DateTime since) {
    final e =
        '${_fmtDigits(now.year, 4)}'
        '${_fmtDigits(now.month, 2)}'
        '${_fmtDigits(now.day, 2)}'
        '-'
        '${_fmtDigits(now.hour, 2)}'
        '${_fmtDigits(now.minute, 2)}'
        '${_fmtDigits(now.second, 2)}'
        '-'
        '${_fmtDigits(now.microsecond, 6)}';
    final s =
        '${_fmtDigits(since.year, 4)}'
        '${_fmtDigits(since.month, 2)}'
        '${_fmtDigits(since.day, 2)}'
        '-'
        '${_fmtDigits(since.hour, 2)}'
        '${_fmtDigits(since.minute, 2)}'
        '${_fmtDigits(since.second, 2)}';
    return 'cuplivo_incr_${e}_$s';
  }

  /// Compact ISO-like timestamp without separators (for full backup).
  /// Result: 20260703T123456.123456
  static String _isoCompact(DateTime dt) {
    return '${_fmtDigits(dt.year, 4)}'
        '${_fmtDigits(dt.month, 2)}'
        '${_fmtDigits(dt.day, 2)}'
        'T'
        '${_fmtDigits(dt.hour, 2)}'
        '${_fmtDigits(dt.minute, 2)}'
        '${_fmtDigits(dt.second, 2)}'
        '.'
        '${_fmtDigits(dt.microsecond, 6)}';
  }

  static String _fmtDigits(int n, int width) =>
      n.toString().padLeft(width, '0');

  static Future<void> cleanupTemporaryBackupFile(File? file) async {
    if (file == null) return;
    final parent = file.parent;
    await _deleteFileQuietly(file);
    try {
      if (await parent.exists() && await parent.list().isEmpty) {
        await parent.delete();
      }
    } catch (_) {}
  }

  static Future<void> _deleteFileQuietly(File? file) async {
    if (file == null) return;
    try {
      if (await file.exists()) {
        await file.delete();
      }
    } catch (_) {}
  }

  static Future<void> _deleteDirectoryQuietly(Directory? directory) async {
    if (directory == null) return;
    try {
      if (await directory.exists()) {
        await directory.delete(recursive: true);
      }
    } catch (_) {}
  }

  static Future<void> _cleanupPreviousBackupTempFiles(Directory tmp) async {
    try {
      if (!await tmp.exists()) return;
      await for (final ent in tmp.list(followLinks: false)) {
        final name = p.basename(ent.path);
        if (ent is Directory &&
            (name.startsWith('kelivo_backup_') ||
                name.startsWith('cuplivo_incr_'))) {
          await _deleteDirectoryQuietly(ent);
        } else if (ent is File &&
            ((name.startsWith('kelivo_backup_') && name.endsWith('.zip')) ||
                (name.startsWith('cuplivo_incr_') && name.endsWith('.zip')) ||
                name == '_bk_settings.json' ||
                name == '_bk_settings_meta.json' ||
                name == '_bk_chats.json' ||
                name == '_bk_chats_meta.json' ||
                name == '_bk_conversations.jsonl' ||
                name == '_bk_messages.jsonl')) {
          await _deleteFileQuietly(ent);
        }
      }
    } catch (_) {}
  }

  /// Synchronous ZIP packing — runs inside an Isolate.
  static void _packZipSync({
    required String outPath,
    String? settingsPath,
    String? settingsMetaPath,
    String? chatsMetaPath,
    String? conversationsPath,
    String? messagesPath,
    String? legacyChatsPath,
    String? deletedJsonPath,
    required BackupContentScope scope,
    required String uploadDirPath,
    required String avatarsDirPath,
    required String imagesDirPath,
    required String fontsDirPath,
    required String skillsDirPath,
    required String workspacesDirPath,
    DateTime? since,
    Set<String>? includeFilePaths,
  }) {
    final writer = _StreamingZipWriter(outPath);
    // LAN-sync delta flow only: collect the exact (size, ms mtime) of every
    // packed file so the receiving side restores matching mtimes (kills
    // cross-run re-send churn). Null → legacy mtime-filter path, no manifest.
    final manifest = includeFilePaths != null
        ? <String, ({int size, int mtimeMs})>{}
        : null;
    try {
      // settings.json
      if (settingsPath != null) {
        _addFileToZip(writer, settingsPath, 'settings.json');
      }

      // settings_meta.json — LWW timestamps companion (optional; legacy
      // zips and old builds ignore/fall back)
      if (settingsMetaPath != null) {
        _addFileToZip(writer, settingsMetaPath, 'settings_meta.json');
      }

      // Kelivo-legacy chats.json (v1 blob) — used ONLY for the
      // BackupFormat.kelivoLegacy export. JSONL v2 zips never ship it.
      if (legacyChatsPath != null) {
        _addFileToZip(writer, legacyChatsPath, 'chats.json');
      }

      // chats.jsonl stream set — conversations.jsonl/messages.jsonl + the
      // chats_meta.json sentinel (v2 format, issue #123)
      if (conversationsPath != null) {
        _addFileToZip(writer, conversationsPath, 'conversations.jsonl');
      }
      if (messagesPath != null) {
        _addFileToZip(writer, messagesPath, 'messages.jsonl');
      }
      if (chatsMetaPath != null) {
        _addFileToZip(writer, chatsMetaPath, 'chats_meta.json');
      }

      // deleted.json — id-only tombstones (optional, backward compatible)
      if (deletedJsonPath != null) {
        _addFileToZip(writer, deletedJsonPath, 'deleted.json');
      }

      // skills/ — scope-gated (the "always included" rule was dropped when
      // the backup content scope split into 6 sections).
      if (scope.skills) {
        _addDirectoryToZip(
          writer,
          skillsDirPath,
          'skills',
          since: since,
          includeFilePaths: includeFilePaths,
          manifestOut: manifest,
        );
      }

      // files under upload/, images/ (附件)
      if (scope.attachments) {
        _addDirectoryToZip(
          writer,
          uploadDirPath,
          'upload',
          since: since,
          includeFilePaths: includeFilePaths,
          manifestOut: manifest,
        );
        _addDirectoryToZip(
          writer,
          imagesDirPath,
          'images',
          since: since,
          includeFilePaths: includeFilePaths,
          manifestOut: manifest,
        );
      }

      // fonts/ + avatars/ (字体与头像)
      if (scope.fontsAndAvatars) {
        _addDirectoryToZip(
          writer,
          avatarsDirPath,
          'avatars',
          since: since,
          includeFilePaths: includeFilePaths,
          manifestOut: manifest,
        );
        _addDirectoryToZip(
          writer,
          fontsDirPath,
          'fonts',
          since: since,
          includeFilePaths: includeFilePaths,
          manifestOut: manifest,
        );
      }

      // workspaces/ — user content; dot-prefixed entries (e.g.
      // .fetch_cache/) are excluded from backup/sync (one dotfile rule,
      // same as the server's glob/grep convention).
      if (scope.workspaces) {
        _addDirectoryToZip(
          writer,
          workspacesDirPath,
          'workspaces',
          since: since,
          skipDotEntries: true,
          includeFilePaths: includeFilePaths,
          manifestOut: manifest,
        );
      }

      // sync_manifest.json — exact ms mtimes of the packed files, consumed by
      // the restore side. Deliberately NOT named manifest.json: that name is
      // the Kelivo-v2 backup detector and would mis-reject this zip.
      if (manifest != null) {
        final manifestJson = jsonEncode({
          for (final entry in manifest.entries)
            entry.key: {'size': entry.value.size, 'mtime': entry.value.mtimeMs},
        });
        writer.addBytes(utf8.encode(manifestJson), 'sync_manifest.json');
      }

      writer.closeSync();
    } finally {
      writer.closeIfNeededSync();
    }
  }

  static void _addFileToZip(
    _StreamingZipWriter writer,
    String filePath,
    String entryName,
  ) {
    final file = File(filePath);
    if (!file.existsSync()) return;
    writer.addFile(file, _zipEntryName(entryName));
  }

  /// Add all files from [srcDirPath] into the zip under [zipPrefix].
  ///
  /// When [includeFilePaths] is set (LAN-sync delta flow), a file is packed
  /// iff its zip-entry name (`<zipPrefix>/<relPosix>`) is in the set — this
  /// replaces the mtime `>= since` filter. Otherwise [since] behaves as before.
  /// [manifestOut], when non-null, is filled with the packed files' exact
  /// (size, ms mtime) keyed by zip-entry name.
  static void _addDirectoryToZip(
    _StreamingZipWriter writer,
    String srcDirPath,
    String zipPrefix, {
    DateTime? since,
    bool skipDotEntries = false,
    Set<String>? includeFilePaths,
    Map<String, ({int size, int mtimeMs})>? manifestOut,
  }) {
    final dir = Directory(srcDirPath);
    if (!dir.existsSync()) return;
    // Pruned depth-first walk (dot dirs are never descended into; ZIP entry
    // names use forward slashes because _listFiles returns POSIX paths).
    // Output set is identical to the old full-recursive walk + per-file dot
    // filter — only traversal work differs.
    for (final ent in _listFiles(dir, skipDot: skipDotEntries)) {
      final relPosix = ent.rel;
      final entryName = '$zipPrefix/$relPosix';
      if (includeFilePaths != null) {
        if (!includeFilePaths.contains(entryName)) continue;
      } else if (since != null) {
        try {
          if (ent.file.lastModifiedSync().isBefore(since)) continue;
        } catch (_) {
          // Cannot read modification time — include conservatively
        }
      }
      if (manifestOut != null) {
        try {
          final stat = ent.file.statSync();
          manifestOut[entryName] = (
            size: stat.size,
            mtimeMs: stat.modified.millisecondsSinceEpoch,
          );
        } catch (_) {
          // Cannot stat — the pack call below surfaces a real error later.
        }
      }
      _addFileToZip(writer, ent.file.path, entryName);
    }
  }

  static String _zipEntryName(String name) {
    return name.replaceAll('\\', '/').replaceAll(RegExp(r'^/+'), '');
  }

  /// Lists the files of [dir] depth-first in name-sorted order, with their
  /// root-relative POSIX paths.
  ///
  /// Mirrors the dot-entry rule of [_addDirectoryToZip]: when [skipDot] is
  /// set, any entry whose name starts with `.` is pruned at walk time — dot
  /// DIRECTORIES are never descended into, so `.sandbox`-style trees are not
  /// traversed at all. The output set is identical to a full-recursive walk
  /// with a per-file dot filter; only the traversal work differs. Symlinks
  /// are never followed. Returns empty when the directory does not exist.
  static List<({File file, String rel})> _listFiles(
    Directory dir, {
    bool skipDot = false,
  }) {
    if (!dir.existsSync()) return const [];
    final out = <({File file, String rel})>[];
    _listFilesInto(dir, '', skipDot, out);
    return out;
  }

  static void _listFilesInto(
    Directory dir,
    String prefix,
    bool skipDot,
    List<({File file, String rel})> out,
  ) {
    final children = dir.listSync(recursive: false, followLinks: false)
      ..sort((a, b) => a.path.compareTo(b.path));
    for (final ent in children) {
      final name = p.basename(ent.path);
      if (skipDot && name.startsWith('.')) continue;
      final rel = prefix.isEmpty ? name : '$prefix/$name';
      if (ent is Directory) {
        _listFilesInto(ent, rel, skipDot, out);
      } else if (ent is File) {
        out.add((file: ent, rel: rel));
      }
    }
  }

  /// Sets [target]'s mtime, preferring the LAN-sync manifest's ms precision
  /// when present; otherwise falls back to [source]'s own mtime (the ZIP's
  /// second-granularity UT field). Best-effort — never throws.
  static Future<void> _setTargetMtime(
    File target,
    File source,
    String extractDirPath,
    Map<String, ({int size, int mtimeMs})>? manifest,
  ) async {
    final mtime = await _backupFileMtime(source, extractDirPath, manifest);
    try {
      await target.setLastModified(mtime);
    } catch (_) {}
  }

  /// The effective mtime of an extracted backup file. When the LAN-sync
  /// `sync_manifest.json` carries an entry for the file, its exact ms mtime is
  /// used — this makes the merge's newer-wins comparison agree precisely with
  /// the delta (`computeFileDelta` compares ms mtimes), so a same-second tie
  /// can never keep the receiver's older copy and re-send forever. Otherwise
  /// falls back to the ZIP's own (second-granularity) mtime.
  static Future<DateTime> _backupFileMtime(
    File source,
    String extractDirPath,
    Map<String, ({int size, int mtimeMs})>? manifest,
  ) async {
    final key = p
        .relative(source.path, from: extractDirPath)
        .replaceAll('\\', '/');
    final entry = manifest?[key];
    if (entry != null) {
      return DateTime.fromMillisecondsSinceEpoch(entry.mtimeMs);
    }
    return source.lastModified();
  }

  /// Decode a DOS date/time packed value (from ZIP entry's lastModTime) into
  /// a [DateTime]. Returns null when the date portion is zero (unset).
  static DateTime? _decodeDosDateTime(int packed) {
    final dosDate = packed >> 16;
    final dosTime = packed & 0xFFFF;
    if (dosDate == 0) return null;
    final year = ((dosDate >> 9) & 0x7f) + 1980;
    final month = (dosDate >> 5) & 0x0f;
    final day = dosDate & 0x1f;
    final hour = (dosTime >> 11) & 0x1f;
    final minute = (dosTime >> 5) & 0x3f;
    final second = (dosTime & 0x1f) * 2;
    try {
      return DateTime(year, month, day, hour, minute, second);
    } catch (_) {
      return null;
    }
  }

  /// Synchronous ZIP extraction — runs inside an Isolate.
  /// Uses InputFileStream so the ZIP bytes are read from disk on demand rather
  /// than loading the entire archive into a single byte array.
  static void _extractZipSync(String zipPath, String extractDirPath) {
    final inputStream = InputFileStream(zipPath);
    // Full-second mtimes from UT (0x5455) extra fields, keyed by raw entry
    // name. Empty when absent — DOS timestamps (even-second) are the fallback.
    final utMtimes = _readUtMtimes(zipPath);
    try {
      final archive = ZipDecoder().decodeStream(inputStream);
      try {
        for (final entry in archive) {
          // Normalize entry name to use forward slashes and remove traversal
          final normalized = entry.name.replaceAll('\\', '/');
          final parts = normalized
              .split('/')
              .where((seg) => seg.isNotEmpty && seg != '.' && seg != '..')
              .toList();
          if (parts.isEmpty) continue;
          final outPath = p.joinAll([extractDirPath, ...parts]);
          if (entry.isFile) {
            File(outPath).parent.createSync(recursive: true);
            final output = OutputFileStream(outPath);
            try {
              entry.writeContent(output);
            } finally {
              output.closeSync();
            }
            final dt =
                utMtimes[entry.name] ?? _decodeDosDateTime(entry.lastModTime);
            if (dt != null) {
              try {
                File(outPath).setLastModifiedSync(dt);
              } catch (_) {}
            }
          } else {
            Directory(outPath).createSync(recursive: true);
          }
        }
      } finally {
        archive.clearSync();
      }
    } finally {
      inputStream.closeSync();
    }
  }

  /// Runs the synchronous ZIP extraction in an isolate.
  ///
  /// The closure passed to `Isolate.run` is created inside a STATIC method
  /// taking only plain strings. A closure created in an instance method can
  /// over-capture the enclosing frame (including `this` and callback params
  /// like the restore `onProgress` tear-off, whose owner graph reaches the
  /// LAN sync `HttpServer` on the server side) — sending such a closure fails
  /// with "object is unsendable" (dart-lang/sdk#52661).
  static Future<void> _runExtractInIsolate(
    String zipPath,
    String extractDirPath,
  ) => Isolate.run(() => _extractZipSync(zipPath, extractDirPath));

  /// Reads full-second mtimes from a zip's central-directory UT (0x5455)
  /// extra fields, keyed by raw entry name.
  ///
  /// ZIP DOS timestamps round down to even seconds; the UT field carries the
  /// true Unix-second mtime so the newer-wins merge comparison is not biased
  /// against odd-second mtimes. Returns an empty map when no entry carries
  /// the field or the layout cannot be parsed (callers fall back to DOS).
  static Map<String, DateTime> _readUtMtimes(String zipPath) {
    final raf = File(zipPath).openSync();
    try {
      final length = raf.lengthSync();
      if (length < 22) return const {};
      // EOCD (22 bytes) + max comment (65535): read the whole tail.
      final tailLen = length - 22 > 0xffff ? 22 + 0xffff : length;
      raf.setPositionSync(length - tailLen);
      final tail = raf.readSync(tailLen);
      // Scan backwards for the last EOCD signature (0x06054b50).
      var eocdPos = -1;
      for (var i = tail.length - 22; i >= 0; i--) {
        if (tail[i] == 0x50 &&
            tail[i + 1] == 0x4b &&
            tail[i + 2] == 0x05 &&
            tail[i + 3] == 0x06) {
          eocdPos = i;
          break;
        }
      }
      if (eocdPos < 0) return const {};
      final cdSize = ByteData.sublistView(
        tail,
      ).getUint32(eocdPos + 12, Endian.little);
      final cdOffset = ByteData.sublistView(
        tail,
      ).getUint32(eocdPos + 16, Endian.little);
      if (cdOffset + cdSize > length) return const {};

      raf.setPositionSync(cdOffset);
      final cd = raf.readSync(cdSize);
      final view = ByteData.sublistView(cd);
      final result = <String, DateTime>{};
      var pos = 0;
      while (pos + 46 <= cd.length) {
        // Central directory header signature (0x02014b50).
        if (view.getUint32(pos, Endian.little) != 0x02014b50) break;
        final nameLen = view.getUint16(pos + 28, Endian.little);
        final extraLen = view.getUint16(pos + 30, Endian.little);
        final commentLen = view.getUint16(pos + 32, Endian.little);
        final nameStart = pos + 46;
        final extraStart = nameStart + nameLen;
        final next = extraStart + extraLen + commentLen;
        if (next > cd.length) break;
        if (extraLen >= 9) {
          final name = _decodeZipName(
            cd.sublist(nameStart, nameStart + nameLen),
          );
          final ut = _parseUtMtime(view, extraStart, extraLen);
          if (name != null && ut != null) result[name] = ut;
        }
        pos = next;
      }
      return result;
    } finally {
      raf.closeSync();
    }
  }

  /// Decodes a central-directory entry name the same way archive_io does:
  /// UTF-8 first, latin-1 on parse error. Null when the entry has no name.
  static String? _decodeZipName(List<int> bytes) {
    if (bytes.isEmpty) return null;
    try {
      return utf8.decode(bytes);
    } catch (_) {
      return String.fromCharCodes(bytes);
    }
  }

  /// Extracts the mtime from a UT (0x5455) extra field inside [view] starting
  /// at [start] with [length] bytes. Returns null when absent or malformed.
  static DateTime? _parseUtMtime(ByteData view, int start, int length) {
    var pos = start;
    final end = start + length;
    while (pos + 4 <= end) {
      final id = view.getUint16(pos, Endian.little);
      final size = view.getUint16(pos + 2, Endian.little);
      final dataStart = pos + 4;
      if (dataStart + size > end) return null;
      if (id == 0x5455 && size >= 5 && (view.getUint8(dataStart) & 1) != 0) {
        final secs = view.getUint32(dataStart + 1, Endian.little);
        if (secs == 0) return null;
        return DateTime.fromMillisecondsSinceEpoch(secs * 1000, isUtc: true);
      }
      pos = dataStart + size;
    }
    return null;
  }

  Future<void> backupToWebDav(
    WebDavConfig cfg, {
    IncrementalBackupConfig? incremental,
    BackupStageCallback? onStage,
  }) async {
    final file = await prepareBackupFile(
      cfg,
      incremental: incremental,
      onStage: onStage,
    );
    try {
      onStage?.call(BackupStage.uploading);
      await _ensureCollection(cfg);
      final target = _fileUri(cfg, p.basename(file.path));
      final fileLen = await file.length();
      // Use a streamed request so we don't load the entire file into RAM.
      final req = http.StreamedRequest('PUT', target);
      req.headers.addAll({
        'content-type': 'application/zip',
        'content-length': fileLen.toString(),
        ..._authHeaders(cfg),
        ..._extraHeaders(cfg),
      });
      // Pipe the file stream into the request body.
      file.openRead().listen(
        req.sink.add,
        onDone: req.sink.close,
        onError: req.sink.addError,
      );
      final client = http.Client();
      try {
        final res = await client.send(req).then(http.Response.fromStream);
        if (res.statusCode < 200 || res.statusCode >= 300) {
          throw Exception('Upload failed: ${res.statusCode}');
        }
      } finally {
        client.close();
      }
    } finally {
      await cleanupTemporaryBackupFile(file);
    }
  }

  Future<List<BackupFileItem>> listBackupFiles(WebDavConfig cfg) async {
    await _ensureCollection(cfg);
    final uri = _collectionUri(cfg);
    final req = http.Request('PROPFIND', uri);
    req.headers.addAll({
      'Depth': '1',
      'Content-Type': 'application/xml; charset=utf-8',
      ..._authHeaders(cfg),
      ..._extraHeaders(cfg),
    });
    req.body =
        '<?xml version="1.0" encoding="utf-8" ?>\n'
        '<d:propfind xmlns:d="DAV:">\n'
        '  <d:prop>\n'
        '    <d:displayname/>\n'
        '    <d:getcontentlength/>\n'
        '    <d:getlastmodified/>\n'
        '  </d:prop>\n'
        '</d:propfind>';
    final res = await http.Client().send(req).then(http.Response.fromStream);
    if (res.statusCode < 200 || res.statusCode >= 300) {
      throw Exception('PROPFIND failed: ${res.statusCode}');
    }
    final doc = XmlDocument.parse(res.body);
    final items = <BackupFileItem>[];
    final baseStr = uri.toString();
    for (final resp in doc.findAllElements('response', namespace: '*')) {
      final href = resp.getElement('href', namespace: '*')?.innerText ?? '';
      if (href.isEmpty) continue;
      // Skip the collection itself
      final abs = Uri.parse(href).isAbsolute
          ? Uri.parse(href).toString()
          : uri.resolve(href).toString();
      if (abs == baseStr) continue;
      final disp = resp
          .findAllElements('displayname', namespace: '*')
          .map((e) => e.innerText)
          .toList();
      final sizeStr = resp
          .findAllElements('getcontentlength', namespace: '*')
          .map((e) => e.innerText)
          .cast<String>()
          .toList();
      final mtimeStr = resp
          .findAllElements('getlastmodified', namespace: '*')
          .map((e) => e.innerText)
          .cast<String>()
          .toList();
      final size = (sizeStr.isNotEmpty) ? int.tryParse(sizeStr.first) ?? 0 : 0;
      DateTime? mtime;
      if (mtimeStr.isNotEmpty) {
        try {
          mtime = DateTime.parse(mtimeStr.first);
        } catch (_) {}
      }
      final name = (disp.isNotEmpty && disp.first.trim().isNotEmpty)
          ? disp.first.trim()
          : Uri.parse(href).pathSegments.last;

      // If mtime is null, try to extract from filename
      if (mtime == null) {
        // Try old full backup format: kelivo_backup_2026-07-03T12-34-56.123456.zip
        var fullMatch = RegExp(
          r'kelivo_backup_(\d{4}-\d{2}-\d{2}T\d{2}-\d{2}-\d{2}\.\d+)\.zip',
        ).firstMatch(name);
        if (fullMatch != null) {
          try {
            final timestamp = fullMatch
                .group(1)!
                .replaceAll(
                  RegExp(r'T(\d{2})-(\d{2})-(\d{2})'),
                  'T\$1:\$2:\$3',
                );
            mtime = DateTime.parse(timestamp);
          } catch (_) {}
        } else {
          // Try new full backup format: kelivo_backup_20260703T123456.123456.zip
          fullMatch = RegExp(
            r'kelivo_backup_(\d{8}T\d{6}\.\d+)\.zip',
          ).firstMatch(name);
          if (fullMatch != null) {
            try {
              mtime = DateTime.parse(fullMatch.group(1)!);
            } catch (_) {}
          } else {
            // Try incremental format: cuplivo_incr_20260703-123456-123456_20260701-000000.zip
            final incrMatch = RegExp(
              r'cuplivo_incr_(\d{8})-(\d{6})-(\d{6})_\d{8}-\d{6}\.zip',
            ).firstMatch(name);
            if (incrMatch != null) {
              try {
                final raw =
                    '${incrMatch.group(1)}T${incrMatch.group(2)}.${incrMatch.group(3)}';
                // raw = 20260703T123456.123456
                mtime = DateTime.parse(raw);
              } catch (_) {}
            }
          }
        }
      }

      // Skip directories
      if (abs.endsWith('/')) continue;
      final fullHref = Uri.parse(abs);
      items.add(
        BackupFileItem(
          href: fullHref,
          displayName: name,
          size: size,
          lastModified: mtime,
        ),
      );
    }
    items.sort(
      (a, b) => (b.lastModified ?? DateTime(0)).compareTo(
        a.lastModified ?? DateTime(0),
      ),
    );
    return items;
  }

  Future<void> restoreFromWebDav(
    WebDavConfig cfg,
    BackupFileItem item, {
    RestoreMode mode = RestoreMode.overwrite,
    RestoreProgressCallback? onProgress,
  }) async {
    // Stream the download to a file instead of buffering in memory.
    final client = http.Client();
    File? file;
    try {
      final req = http.Request('GET', item.href);
      req.headers.addAll({..._authHeaders(cfg), ..._extraHeaders(cfg)});
      final streamed = await client.send(req);
      if (streamed.statusCode < 200 || streamed.statusCode >= 300) {
        // Drain the response body to allow the client to close cleanly.
        await streamed.stream.drain<void>();
        throw Exception('Download failed: ${streamed.statusCode}');
      }
      final tmpDir = await _ensureTempDir();
      file = File(p.join(tmpDir.path, item.displayName));
      final sink = file.openWrite();
      await streamed.stream.pipe(sink);
      await _restoreFromBackupFile(
        file,
        cfg,
        mode: mode,
        onProgress: onProgress,
      );
    } finally {
      client.close();
      await _deleteFileQuietly(file);
    }
  }

  Future<void> deleteWebDavBackupFile(
    WebDavConfig cfg,
    BackupFileItem item,
  ) async {
    final req = http.Request('DELETE', item.href);
    req.headers.addAll({..._authHeaders(cfg), ..._extraHeaders(cfg)});
    final res = await http.Client().send(req).then(http.Response.fromStream);
    if (res.statusCode < 200 || res.statusCode >= 300) {
      throw Exception('Delete failed: ${res.statusCode}');
    }
  }

  Future<File> exportToFile(
    WebDavConfig cfg, {
    IncrementalBackupConfig? incremental,
    BackupStageCallback? onStage,
    BackupFormat format = BackupFormat.jsonl,
  }) => prepareBackupFile(
    cfg,
    incremental: incremental,
    onStage: onStage,
    format: format,
  );

  Future<void> restoreFromLocalFile(
    File file,
    WebDavConfig cfg, {
    RestoreMode mode = RestoreMode.overwrite,
    RestoreProgressCallback? onProgress,
    ConflictPrecedence precedence = ConflictPrecedence.auto,
  }) async {
    if (!await file.exists()) throw Exception('备份文件不存在');
    await _restoreFromBackupFile(
      file,
      cfg,
      mode: mode,
      onProgress: onProgress,
      precedence: precedence,
    );
  }

  // ===== Internal helpers =====
  /// Ensures the temporary directory exists (some macOS installs may not create the cache folder until first use).
  Future<Directory> _ensureTempDir() async {
    Directory dir = await getTemporaryDirectory();
    if (!await dir.exists()) {
      try {
        await dir.create(recursive: true);
      } catch (_) {}
    }
    if (!await dir.exists()) {
      dir = await Directory.systemTemp.createTemp('kelivo_tmp_');
    }
    return dir;
  }

  Future<File> _writeTempText(
    Directory directory,
    String name,
    String content,
  ) async {
    final f = File(p.join(directory.path, name));
    await f.writeAsString(content);
    return f;
  }

  Future<Directory> _getUploadDir() async {
    return await AppDirectories.getUploadDirectory();
  }

  Future<Directory> _getImagesDir() async {
    return await AppDirectories.getImagesDirectory();
  }

  Future<Directory> _getAvatarsDir() async {
    return await AppDirectories.getAvatarsDirectory();
  }

  Future<Directory> _getFontsDir() async {
    return await AppDirectories.getFontsDirectory();
  }

  Future<Directory> _getSkillsDir() async {
    return await AppDirectories.getSkillsDirectory();
  }

  Future<Directory> _getWorkspacesDir() async {
    return await AppDirectories.getWorkspacesDirectory();
  }

  /// Returns the set of locally-existing ids for a given entity type.
  /// Used by deleted.json import to filter markers to only those that
  /// still exist locally (no point marking something that's already gone).
  Future<Set<String>> _getLocalIdsForType(String type) async {
    // Use the coordinator resolver if available (covers all 7 types).
    final resolver = _localIdResolver;
    if (resolver != null) {
      return resolver(type);
    }
    // Fallback: Drift-only types (used when coordinator is not available,
    // e.g. in tests or old code paths that construct DataSync directly).
    switch (type) {
      case DeletionEntityType.conversation:
        return chatService
            .getAllCompleteConversations()
            .map((c) => c.id)
            .toSet();
      case DeletionEntityType.message:
        final ids = <String>{};
        for (final conv in chatService.getAllCompleteConversations()) {
          for (final m in chatService.getMessages(conv.id)) {
            ids.add(m.id);
          }
        }
        return ids;
      case DeletionEntityType.assistant:
        return (await chatService.getAllAssistants()).map((a) => a.id).toSet();
      default:
        return <String>{};
    }
  }

  /// WorkspaceFile "still exists locally" = the wire path resolves to a file
  /// OR directory inside the local @workspaces tree. Paths on unknown mounts
  /// (e.g. external desktop mounts absent on this device) never match.
  /// Dot-prefixed segments are rejected (never-synced content must not get
  /// meaningful remote markers), and `..` is checked per segment — the same
  /// rule as the wire-format resolver.
  Future<List<({String id, DateTime deletedAt})>> _filterExistingWorkspaceFiles(
    List<({String id, DateTime deletedAt})> entries,
  ) async {
    final ws = await _getWorkspacesDir();
    final wsRoot = p.normalize(ws.path);
    final out = <({String id, DateTime deletedAt})>[];
    for (final e in entries) {
      final id = e.id;
      if (!id.startsWith('@workspaces/')) continue;
      final rel = id.substring('@workspaces/'.length);
      if (rel.isEmpty) continue;
      final segments = rel.split(RegExp(r'[\\/]'));
      // Same segment rule as the wire resolver: dot-prefixed (never-synced
      // content) plus unsafe segments (`..`, Win32 trailing-dot/space forms)
      // never match.
      if (segments.any((s) => s.startsWith('.') || !isSafeWireSegment(s))) {
        continue;
      }
      final host = p.normalize(p.join(wsRoot, segments.join(p.separator)));
      if (!host.startsWith('$wsRoot${p.separator}')) continue;
      final exists =
          await File(host).exists() || await Directory(host).exists();
      if (exists) out.add(e);
    }
    return out;
  }

  /// Messages qualifying for incremental export, at version-group granularity.
  ///
  /// Edited versions preserve the original message timestamp, so a
  /// timestamp-only filter would drop them while `versionSelections` still
  /// references the missing version. `version > 0` also matches multi-AI
  /// adopted threads (renumbered without being edited), which only ever
  /// produces superset exports. Qualify by group: every message whose group
  /// contains a changed or versioned message is included.
  List<ChatMessage> _incrementalQualifiedMessages(
    List<ChatMessage> msgs,
    bool Function(DateTime) sinceCheck,
  ) {
    final qualifiedGroups = msgs
        .where((m) => sinceCheck(m.timestamp) || m.version > 0)
        .map((m) => m.groupId ?? m.id)
        .toSet();
    return msgs
        .where((m) => qualifiedGroups.contains(m.groupId ?? m.id))
        .toList();
  }

  /// Analyze incremental scope for preview purposes — scans conversations and
  /// files to produce metadata counts and representative titles.
  /// Does not modify any state; safe to call repeatedly.
  Future<IncrementalScope> analyzeIncrementalScope(
    IncrementalBackupConfig config,
  ) async {
    if (!chatService.initialized) await chatService.init();

    final allConvs = chatService.getAllCompleteConversations();
    final since = config.since;
    final sinceCheck = config.sinceCheck;
    final scope = config.effectiveScope;

    final newConvs = <Conversation>[];
    final updatedConvs = <Conversation>[];
    int newMsgCount = 0;
    int updatedMsgCount = 0;

    for (final c in allConvs) {
      if (sinceCheck(c.createdAt)) {
        final msgs = chatService.getMessages(c.id);
        newMsgCount += msgs.length;
        newConvs.add(c);
      } else if (c.updatedAt.isAfter(since) ||
          c.updatedAt.isAtSameMomentAs(since)) {
        final filtered = _incrementalQualifiedMessages(
          chatService.getMessages(c.id),
          sinceCheck,
        );
        final count = filtered.length;
        if (count > 0) {
          updatedMsgCount += count;
          updatedConvs.add(c);
        }
      }
    }

    newConvs.sort((a, b) => a.createdAt.compareTo(b.createdAt));
    updatedConvs.sort((a, b) => a.createdAt.compareTo(b.createdAt));

    final counted = await _countFilesForSince(since, scope: scope);

    return IncrementalScope(
      newConversations: ConvRange(
        count: newConvs.length,
        messageCount: newMsgCount,
        oldestTitle: newConvs.isNotEmpty ? newConvs.first.title : null,
        newestTitle: newConvs.length > 1 ? newConvs.last.title : null,
      ),
      updatedConversations: ConvRange(
        count: updatedConvs.length,
        messageCount: updatedMsgCount,
        oldestTitle: updatedConvs.isNotEmpty ? updatedConvs.first.title : null,
        newestTitle: updatedConvs.length > 1 ? updatedConvs.last.title : null,
      ),
      newFileCount: counted.fileCount,
      totalFileSizeBytes: counted.totalBytes,
    );
  }

  /// Counts the files a LAN sync peer would pack from this device for the
  /// given [since], and their total bytes. Stat-only — never reads file
  /// contents. Mirrors `_packZipSync` exactly (mtime >= [since]; `skills/`
  /// always counted; `workspaces/` skips dot-prefixed entries; mtime-read
  /// failures counted conservatively) so a preview never drifts from the
  /// actual zip payload.
  Future<({int fileCount, int totalBytes})> countFilesForSince(
    DateTime since,
  ) => _countFilesForSince(since, scope: const BackupContentScope());

  /// Shared implementation behind [countFilesForSince] and
  /// [analyzeIncrementalScope]. Counts each tree only when its section bit is
  /// set, mirroring `_packZipSync`.
  Future<({int fileCount, int totalBytes})> _countFilesForSince(
    DateTime since, {
    BackupContentScope scope = const BackupContentScope(),
  }) async {
    var fileCount = 0;
    var totalBytes = 0;

    Future<void> countDir(Directory dir, {required bool skipDot}) async {
      if (!await dir.exists()) return;
      try {
        // Pruned walk with the same dot rule as the pack: dot dirs (e.g.
        // .sandbox rootfs) are never descended into, so the preview matches
        // the actual zip payload without paying for a full traversal.
        for (final ent in _listFiles(dir, skipDot: skipDot)) {
          try {
            final mod = await ent.file.lastModified();
            if (mod.isBefore(since)) continue;
          } catch (_) {
            // Cannot read modification time — include conservatively
          }
          fileCount++;
          try {
            totalBytes += await ent.file.length();
          } catch (_) {
            // Cannot read size — counted with unknown size
          }
        }
      } catch (e) {
        // A preview stat walk must not fail the sync plan: log and skip the
        // unreadable tree (the pack itself will surface a real error later).
        debugPrint('countFilesForSince: failed to scan ${dir.path}: $e');
      }
    }

    if (scope.attachments) {
      await countDir(await _getUploadDir(), skipDot: false);
      await countDir(await _getImagesDir(), skipDot: false);
    }
    if (scope.fontsAndAvatars) {
      await countDir(await _getAvatarsDir(), skipDot: false);
      await countDir(await _getFontsDir(), skipDot: false);
    }
    if (scope.workspaces) {
      await countDir(await _getWorkspacesDir(), skipDot: true);
    }
    if (scope.skills) {
      await countDir(await _getSkillsDir(), skipDot: false);
    }

    return (fileCount: fileCount, totalBytes: totalBytes);
  }

  /// Builds this device's file manifest for LAN sync: zip-entry path →
  /// (size, ms mtime). Keys exactly mirror the ZIP packer's entry names
  /// (`<root>/<relPosix>`), so a delta computed against a peer's manifest
  /// plugs straight into `_packZipSync(includeFilePaths:)`. Mirrors the
  /// `_packZipSync` rules: `workspaces/` skips dot-prefixed entries, `skills/`
  /// is always covered.
  ///
  /// Strict by design: an unreadable tree/file throws (with context) instead
  /// of producing a partial manifest — a partial manifest would silently drop
  /// the missing files from the delta and the peer would never receive them.
  /// The pack path fails loudly on the same files, so this is consistent.
  Future<Map<String, FileManifestEntry>> buildFileManifest() async {
    final result = <String, FileManifestEntry>{};

    Future<void> walk(
      String dirPath,
      String zipPrefix, {
      required bool skipDot,
    }) async {
      // A tree that has never been created is legitimately empty — skip it.
      // Any other failure while listing/stat-ing throws (strict manifest).
      if (!await Directory(dirPath).exists()) return;
      for (final ent in _listFiles(Directory(dirPath), skipDot: skipDot)) {
        final stat = await ent.file.stat();
        result['$zipPrefix/${ent.rel}'] = FileManifestEntry(
          size: stat.size,
          mtimeMs: stat.modified.millisecondsSinceEpoch,
        );
      }
    }

    await walk((await _getUploadDir()).path, 'upload', skipDot: false);
    await walk((await _getAvatarsDir()).path, 'avatars', skipDot: false);
    await walk((await _getImagesDir()).path, 'images', skipDot: false);
    await walk((await _getFontsDir()).path, 'fonts', skipDot: false);
    await walk((await _getWorkspacesDir()).path, 'workspaces', skipDot: true);
    await walk((await _getSkillsDir()).path, 'skills', skipDot: false);

    return result;
  }

  /// Builds settings.json + its LWW companion settings_meta.json.
  ///
  /// The meta file maps each exported business key to its KV `updated_at`
  /// (microseconds UTC). Keys missing from the KV table (not yet migrated or
  /// written) are absent from the meta file and fall back to legacy merge
  /// semantics on restore. Local-only/entity keys never appear in either.
  Future<({Map<String, dynamic> settings, Map<String, int> updatedAt})>
  _exportSettingsPayloads() async {
    final prefs = SharedPreferencesAsync(_preferences);
    final map = await prefs.snapshot();
    // `assistants_v1` removed from SharedPreferences
    if (chatService.initialized) {
      try {
        final assistants = await chatService.getAllAssistants();
        if (assistants.isNotEmpty) {
          map['assistants_v1'] = Assistant.encodeList(assistants);
        }
      } catch (_) {}
    }
    // Derive Kelivo-compatible image-compression keys from the current
    // one_click_compress_* values, so a Cuplivo backup restores the
    // compression settings in Kelivo natively too. Derived at export time —
    // prefs never hold a mirror copy (no dual truth, no staleness).
    map.addAll(KelivoImageSettingsMapper.translateToUpstream(map));
    _retainCloudAsrForExport(map);

    // Kelivo's business router validates search_services_v1 entries and
    // requires `apiKeys` to be a plain List<String> (round-robin pool).
    // Cuplivo persists structured ApiKeyConfig objects there, so on export
    // we split the payload: full objects move to `keyConfigs` (Cuplivo reads
    // them back losslessly) and `apiKeys` becomes the string list Kelivo
    // accepts. `apiKey` stays as the primary key string both sides read.
    final searchServicesRaw = map['search_services_v1'];
    if (searchServicesRaw is String && searchServicesRaw.isNotEmpty) {
      try {
        final decoded = jsonDecode(searchServicesRaw) as List;
        final converted = <Map<String, dynamic>>[];
        for (final entry in decoded) {
          final service = (entry as Map).cast<String, dynamic>();
          final rawKeys = service['apiKeys'];
          if (rawKeys is List &&
              rawKeys.isNotEmpty &&
              rawKeys.every((e) => e is Map)) {
            service['keyConfigs'] = rawKeys;
            service['apiKeys'] = [
              for (final k in rawKeys.cast<Map<String, dynamic>>())
                if ((k['key'] as String? ?? '').trim().isNotEmpty)
                  (k['key'] as String).trim(),
            ];
          }
          converted.add(service);
        }
        map['search_services_v1'] = jsonEncode(converted);
      } catch (e) {
        debugPrint(
          'prepareBackupFile: search_services_v1 conversion failed: $e',
        );
      }
    }

    final updatedAt = <String, int>{};
    for (final key in map.keys) {
      final ts = _preferences.updatedAtFor(key);
      if (ts != null) updatedAt[key] = ts;
    }
    return (settings: map, updatedAt: updatedAt);
  }

  /// Section-aware settings.json partition (backup content scope):
  /// assistant-owned keys ride `chatsAndAssistants`, everything else rides
  /// `settings`. The meta file only carries the written keys, so the LWW
  /// merge stays key-exact with the payload.
  ({Map<String, dynamic> settings, Map<String, int> updatedAt})
  _splitSettingsSections(
    Map<String, dynamic> settings,
    Map<String, int> updatedAt,
    BackupContentScope scope,
  ) {
    const assistantKeys = {'assistants_v1', 'assistant_memories_v1'};
    final out = <String, dynamic>{};
    final meta = <String, int>{};
    for (final entry in settings.entries) {
      final isAssistant = assistantKeys.contains(entry.key);
      final bit = isAssistant ? scope.chatsAndAssistants : scope.settings;
      if (!bit) continue;
      out[entry.key] = entry.value;
      final ts = updatedAt[entry.key];
      if (ts != null) meta[entry.key] = ts;
    }
    return (settings: out, updatedAt: meta);
  }

  /// Local KV updated_at for [key], or null when the key has no business row
  /// (device-local or never-written; LWW cannot apply).
  int? _localUpdatedAtFor(String key) => _preferences.updatedAtFor(key);

  /// Streams chat data to the Kelivo-legacy `chats.json` v1 blob.
  ///
  /// Kelivo's legacy importer only accepts a single chats.json with
  /// `version: 1` (or the field absent) — the JSONL v2 streams Cuplivo
  /// normally exports would restore nothing there. Used exclusively by the
  /// BackupFormat.kelivoLegacy export button; full backups only.
  Future<File> _exportChatsToLegacyFile(
    Directory directory, {
    IncrementalBackupConfig? incremental,
  }) async {
    if (!chatService.initialized) {
      await chatService.init();
    }
    var conversations = chatService.getAllCompleteConversations();
    final perConvSince = incremental?.conversationSince;
    if (incremental != null && perConvSince != null) {
      conversations = conversations
          .where((c) => perConvSince.containsKey(c.id))
          .toList();
    } else if (incremental != null) {
      final sinceCheck = incremental.sinceCheck;
      final since = incremental.since;
      conversations = conversations.where((c) {
        if (sinceCheck(c.createdAt)) {
          return true;
        }
        if (c.updatedAt.isBefore(since)) return false;
        final msgs = chatService.getMessages(c.id);
        return _incrementalQualifiedMessages(msgs, sinceCheck).isNotEmpty;
      }).toList();
    }

    final file = File(p.join(directory.path, '_bk_chats.json'));
    final sink = file.openWrite();
    try {
      sink.write('{"version":$_kelivoChatsJsonVersion,');

      // --- conversations ---
      sink.write('"conversations":[');
      for (var i = 0; i < conversations.length; i++) {
        if (i > 0) sink.write(',');
        sink.write(jsonEncode(conversations[i].toJson()));
        if (i % 50 == 0) await Future<void>.delayed(Duration.zero);
      }
      sink.write('],');

      // --- messages, toolEvents, geminiThoughtSigs ---
      sink.write('"messages":[');
      final toolEvents = <String, List<Map<String, dynamic>>>{};
      final geminiThoughtSigs = <String, String>{};
      bool firstMsg = true;
      for (final c in conversations) {
        var msgs = chatService.getMessages(c.id);
        if (incremental != null && !c.isGroup) {
          final perConv = incremental.conversationSince;
          if (perConv != null) {
            final convSince = perConv[c.id];
            if (convSince != null) {
              msgs = _incrementalQualifiedMessages(
                msgs,
                (t) => convSince.isBefore(t) || convSince.isAtSameMomentAs(t),
              );
            }
          } else if (c.createdAt.isBefore(incremental.since)) {
            msgs = _incrementalQualifiedMessages(msgs, incremental.sinceCheck);
          }
        }
        for (final m in msgs) {
          if (!firstMsg) sink.write(',');
          firstMsg = false;
          sink.write(jsonEncode(m.toJson()));
          if (m.role == 'assistant') {
            final ev = chatService.getToolEvents(m.id);
            if (ev.isNotEmpty) toolEvents[m.id] = ev;
            final sig = chatService.getGeminiThoughtSignature(m.id);
            if (sig != null && sig.isNotEmpty) geminiThoughtSigs[m.id] = sig;
          }
        }
        await Future<void>.delayed(Duration.zero);
      }
      sink.write('],');

      // --- toolEvents ---
      sink.write('"toolEvents":');
      sink.write(jsonEncode(toolEvents));
      sink.write(',');

      // --- geminiThoughtSigs ---
      sink.write('"geminiThoughtSigs":');
      sink.write(jsonEncode(geminiThoughtSigs));
      sink.write(',');

      // --- group chats ---
      final groups = await chatService.repo.getAllGroupChats();
      final groupPayload = <Map<String, dynamic>>[];
      final memberPayload = <Map<String, dynamic>>[];
      final exportedConversationIds = conversations.map((c) => c.id).toSet();
      for (final g in groups) {
        if (incremental != null &&
            g.updatedAt.isBefore(incremental.since) &&
            !exportedConversationIds.contains(g.conversationId)) {
          continue;
        }
        groupPayload.add(g.toJson());
        final members = await chatService.repo.getGroupMembers(g.id);
        memberPayload.addAll(members.map((m) => m.toJson()));
      }
      sink.write('"groupChats":');
      sink.write(jsonEncode(groupPayload));
      sink.write(',');
      sink.write('"groupMembers":');
      sink.write(jsonEncode(memberPayload));

      sink.write('}');
    } finally {
      await sink.flush();
      await sink.close();
    }
    return file;
  }

  /// Streams chat data to JSONL temp files (v2 format; issue #123) instead
  /// of a single chats.json blob. Returns the chats_meta.json file; the
  /// conversations/messages streams sit alongside it in [directory].
  ///
  /// Wire format:
  /// - `_bk_chats_meta.json` — sentinel + schema + counts + group payloads,
  ///   written LAST so a half-written backup is never mistaken for complete.
  /// - `_bk_conversations.jsonl` — one wrapped object per line:
  ///   `{"conversation": {...}}`
  /// - `_bk_messages.jsonl` — one wrapped object per message:
  ///   `{"message": {...}, "toolEvents": [...], "geminiSignature": "..."}`
  Future<File> _exportChatsToFile(
    Directory directory, {
    IncrementalBackupConfig? incremental,
  }) async {
    if (!chatService.initialized) {
      await chatService.init();
    }
    var conversations = chatService.getAllCompleteConversations();
    final perConvSince = incremental?.conversationSince;
    final metadataOnly = incremental?.metadataOnlyConversationIds;
    if (incremental != null && (perConvSince != null || metadataOnly != null)) {
      // LAN-sync per-conversation mode: export exactly the conversations that
      // have a delta on this device (presence in the map) plus the
      // metadata-only conflicts (issue #615 category D — identical message
      // lists, different row: the row ships but its messages must never
      // duplicate or drop). Conversations absent from both are identical on
      // both peers and skipped entirely. Each exported conversation is then
      // scoped to its own fork-point timestamp in the messages loop below
      // (null → one-sided conversation, exported in full). This removes the
      // global-since over/under-inclusion.
      conversations = conversations
          .where(
            (c) =>
                (perConvSince?.containsKey(c.id) ?? false) ||
                (metadataOnly?.contains(c.id) ?? false),
          )
          .toList();
    } else if (incremental != null) {
      final sinceCheck = incremental.sinceCheck;
      final since = incremental.since;
      // Message-level filtering with updatedAt pre-check optimization.
      // Conversations created after since always qualify.
      // Conversations with updatedAt before since have no activity.
      // Remaining conversations need message-level check.
      conversations = conversations.where((c) {
        if (sinceCheck(c.createdAt)) {
          return true;
        }
        if (c.updatedAt.isBefore(since)) return false;
        final msgs = chatService.getMessages(c.id);
        // Edited versions keep the original message timestamp, so a
        // timestamp-only check would miss edit-only activity.
        return _incrementalQualifiedMessages(msgs, sinceCheck).isNotEmpty;
      }).toList();
    }

    final convFile = File(p.join(directory.path, '_bk_conversations.jsonl'));
    final msgFile = File(p.join(directory.path, '_bk_messages.jsonl'));
    final convSink = convFile.openWrite();
    final msgSink = msgFile.openWrite();

    var conversationCount = 0;
    var messageCount = 0;
    try {
      // --- conversations ---
      for (final c in conversations) {
        convSink.write(jsonEncode({'conversation': c.toJson()}));
        convSink.write('\n');
        conversationCount++;
        // Yield periodically so the main isolate can process UI frames
        if (conversationCount % 50 == 0) {
          await Future<void>.delayed(Duration.zero);
        }
      }

      // --- messages (+ inline toolEvents/geminiThoughtSigs) ---
      for (final c in conversations) {
        var msgs = chatService.getMessages(c.id);
        // Group transcripts are all-or-nothing: a partial message list would
        // corrupt member assistants' private context after restore.
        if (incremental != null && !c.isGroup) {
          // Category D (issue #615): metadata-only rows ship WITHOUT their
          // messages — the message-ID lists are identical on both peers, so
          // carrying them would only duplicate (and never resolve anything).
          if (metadataOnly?.contains(c.id) ?? false) {
            msgs = const <ChatMessage>[];
          } else {
            final perConv = incremental.conversationSince;
            if (perConv != null) {
              // Per-conversation window (LAN sync): null since = one-sided
              // conversation whose whole transcript is the increment — export
              // every message.
              final convSince = perConv[c.id];
              if (convSince != null) {
                msgs = _incrementalQualifiedMessages(
                  msgs,
                  (t) => convSince.isBefore(t) || convSince.isAtSameMomentAs(t),
                );
              }
            } else if (c.createdAt.isBefore(incremental.since)) {
              msgs = _incrementalQualifiedMessages(
                msgs,
                incremental.sinceCheck,
              );
            }
          }
        }
        for (final m in msgs) {
          final record = <String, dynamic>{'message': m.toJson()};
          if (m.role == 'assistant') {
            final ev = chatService.getToolEvents(m.id);
            if (ev.isNotEmpty) record['toolEvents'] = ev;
            final sig = chatService.getGeminiThoughtSignature(m.id);
            if (sig != null && sig.isNotEmpty) {
              record['geminiSignature'] = sig;
            }
          }
          msgSink.write(jsonEncode(record));
          msgSink.write('\n');
          messageCount++;
        }
        // Yield after each conversation
        await Future<void>.delayed(Duration.zero);
      }
    } finally {
      await convSink.flush();
      await convSink.close();
      await msgSink.flush();
      await msgSink.close();
    }

    // --- group chats (small; kept as a JSON payload inside the meta) ---
    final groups = await chatService.repo.getAllGroupChats();
    final groupPayload = <Map<String, dynamic>>[];
    final memberPayload = <Map<String, dynamic>>[];
    // Incremental scope: a group qualifies when it was active since `since`,
    // or when its conversation made it into this export. A qualifying group
    // carries its FULL members — the director session is ephemeral (rebuilt
    // from the public transcript) and is never stored or exported.
    final exportedConversationIds = conversations.map((c) => c.id).toSet();
    for (final g in groups) {
      if (incremental != null &&
          g.updatedAt.isBefore(incremental.since) &&
          !exportedConversationIds.contains(g.conversationId)) {
        continue;
      }
      groupPayload.add(g.toJson());
      final members = await chatService.repo.getGroupMembers(g.id);
      memberPayload.addAll(members.map((m) => m.toJson()));
    }

    // Sentinel written LAST: a zip only ever packs it once complete.
    final metaFile = File(p.join(directory.path, '_bk_chats_meta.json'));
    await metaFile.writeAsString(
      jsonEncode({
        'format_version': 2,
        'tables': ['conversations', 'messages'],
        'conversation_count': conversationCount,
        'message_count': messageCount,
        'zip_tables': {
          'conversations': 'conversations.jsonl',
          'messages': 'messages.jsonl',
        },
        'groupChats': groupPayload,
        'groupMembers': memberPayload,
      }),
    );
    return metaFile;
  }

  /// Counts non-empty JSONL lines (tolerates a missing trailing newline).
  static Future<int> _countJsonlLines(File file) async {
    if (!await file.exists()) return 0;
    var count = 0;
    await file
        .openRead()
        .transform(const Utf8Decoder())
        .transform(const LineSplitter())
        .forEach((line) {
          if (line.trim().isNotEmpty) count++;
        });
    return count;
  }

  /// Streaming JSONL chats restore (v2 format; issue #123).
  ///
  /// Memory is bounded by one conversation: each conversation's messages are
  /// accumulated then written via [ChatService.restoreConversationsBatch].
  /// Both overwrite and merge stream; merge keeps today's ID-skip semantics
  /// (never LWW for chats) — except conversation *metadata* direction (issue
  /// #615): with [ConflictPrecedence.incomingWins] an already-existing
  /// conversation row is replaced wholesale by the incoming copy (winner's
  /// fields), while the message list stays the local append-union so the
  /// loser's exclusive messages survive. toolEvents/geminiSignatures ride
  /// inline per message. Group chat metadata rides the chats_meta.json payload.
  Future<void> _restoreChatsFromJsonl({
    required Directory extractDir,
    required Map<String, dynamic> chatsMeta,
    required RestoreMode mode,
    RestoreProgressCallback? onProgress,
    ConflictPrecedence precedence = ConflictPrecedence.auto,
  }) async {
    if (!chatService.initialized) await chatService.init();
    final conversationsFile = File(
      p.join(extractDir.path, 'conversations.jsonl'),
    );
    final messagesFile = File(p.join(extractDir.path, 'messages.jsonl'));

    final convs = <Conversation>[];
    await for (final line
        in conversationsFile
            .openRead()
            .transform(const Utf8Decoder())
            .transform(const LineSplitter())) {
      final trimmed = line.trim();
      if (trimmed.isEmpty) continue;
      try {
        final obj = jsonDecode(trimmed) as Map<String, dynamic>;
        final raw = obj['conversation'] as Map?;
        if (raw == null) continue;
        convs.add(Conversation.fromJson(raw.cast<String, dynamic>()));
      } catch (e) {
        throw StateError('backup_conversations_corrupt: $e');
      }
    }

    if (mode == RestoreMode.overwrite) {
      await chatService.clearAllData();
    } else {
      onProgress?.call(const RestoreProgress(stage: RestoreStage.mergingChats));
    }

    final existingConvsById = <String, Conversation>{};
    final existingConvIds = <String>{};
    final existingMsgIds = <String>{};
    if (mode == RestoreMode.merge) {
      for (final conv in chatService.getAllCompleteConversations()) {
        existingConvIds.add(conv.id);
        existingConvsById[conv.id] = conv;
        existingMsgIds.addAll(
          chatService.getMessages(conv.id).map((m) => m.id),
        );
      }
    }

    // Stream messages grouped by conversation (one conversation in memory).
    final byConv = <String, List<ChatMessage>>{};
    final toolEventsByMessageId = <String, List<Map<String, dynamic>>>{};
    final geminiSigsByMessageId = <String, String>{};
    var messageCount = 0;
    await for (final line
        in messagesFile
            .openRead()
            .transform(const Utf8Decoder())
            .transform(const LineSplitter())) {
      final trimmed = line.trim();
      if (trimmed.isEmpty) continue;
      try {
        final obj = jsonDecode(trimmed) as Map<String, dynamic>;
        final raw = obj['message'] as Map?;
        if (raw == null) continue;
        final message = ChatMessage.fromJson(raw.cast<String, dynamic>());
        (byConv[message.conversationId] ??= <ChatMessage>[]).add(message);
        if (obj['toolEvents'] is List) {
          toolEventsByMessageId[message.id] = (obj['toolEvents'] as List)
              .cast<Map>()
              .map((e) => e.cast<String, dynamic>())
              .toList();
        }
        final sig = obj['geminiSignature'];
        if (sig is String && sig.isNotEmpty) {
          geminiSigsByMessageId[message.id] = sig;
        }
        messageCount++;
      } catch (e) {
        throw StateError('backup_messages_corrupt: $e');
      }
      // Flush when the conversation changes.
      if (messageCount % 500 == 0) {
        await Future<void>.delayed(Duration.zero);
      }
    }

    if (mode == RestoreMode.overwrite) {
      await chatService.restoreConversationsBatch(
        conversations: convs,
        messagesByConversation: byConv,
        toolEventsByMessageId: toolEventsByMessageId,
        geminiSignaturesByMessageId: geminiSigsByMessageId,
      );
    } else {
      final batchConvs = <Conversation>[];
      final batchMsgs = <String, List<ChatMessage>>{};
      final batchToolEvents = <String, List<Map<String, dynamic>>>{};
      final batchGeminiSigs = <String, String>{};
      var mergedConvs = 0;
      final totalConvs = convs.length;
      for (final c in convs) {
        if (!existingConvIds.contains(c.id)) {
          batchConvs.add(c);
          final list = byConv[c.id] ?? const <ChatMessage>[];
          batchMsgs[c.id] = list;
          for (final msg in list) {
            if (toolEventsByMessageId.containsKey(msg.id)) {
              batchToolEvents[msg.id] = toolEventsByMessageId[msg.id]!;
            }
            if (geminiSigsByMessageId.containsKey(msg.id)) {
              batchGeminiSigs[msg.id] = geminiSigsByMessageId[msg.id]!;
            }
          }
        } else if (existingConvIds.contains(c.id)) {
          final incomingMsgs = byConv[c.id] ?? const <ChatMessage>[];
          final exclusiveMsgs = <ChatMessage>[
            for (final msg in incomingMsgs)
              if (!existingMsgIds.contains(msg.id)) msg,
          ];
          // Conversation metadata direction (issue #615, category D): with
          // incomingWins the winner's row replaces the loser's (id, createdAt
          // and messageIds exempt). Runs even when the incoming payload
          // carries NO messages for this conversation — a metadata-only row
          // (identical message-ID lists, different row fields) ships without
          // its messages, and must still apply the direction. Row-replace
          // happens first: the append path then keeps the union list (the
          // rider lifts updatedAt if a newly appended message is newer).
          if (precedence == ConflictPrecedence.incomingWins) {
            final local = existingConvsById[c.id];
            await chatService.replaceConversationRow(
              c.copyWith(
                createdAt: local?.createdAt,
                // The sort key must reflect the union's newest activity:
                // never regress below either side's updatedAt (winning copy
                // could be from a stale peer while the losing side holds
                // newer local-exclusive activity — the #545 sort sink would
                // otherwise re-appear).
                updatedAt:
                    (local != null && local.updatedAt.isAfter(c.updatedAt))
                    ? local.updatedAt
                    : c.updatedAt,
                messageIds: [
                  ...(local?.messageIds ?? const <String>[]),
                  for (final msg in exclusiveMsgs) msg.id,
                ],
              ),
            );
          }
          for (final msg in exclusiveMsgs) {
            await chatService.addMessageDirectly(c.id, msg);
          }
        }
        mergedConvs++;
        if (totalConvs > 0) {
          onProgress?.call(
            RestoreProgress(
              stage: RestoreStage.mergingChats,
              fraction: mergedConvs / totalConvs,
              conversationsMerged: mergedConvs,
              conversationsTotal: totalConvs,
            ),
          );
        }
      }
      if (batchConvs.isNotEmpty) {
        await chatService.restoreConversationsBatch(
          conversations: batchConvs,
          messagesByConversation: batchMsgs,
          toolEventsByMessageId: batchToolEvents,
          geminiSignaturesByMessageId: batchGeminiSigs,
        );
      }
      // Merge remaining events/sigs (entries already handled are skipped).
      for (final entry in toolEventsByMessageId.entries) {
        if (batchToolEvents.containsKey(entry.key)) continue;
        if (chatService.getToolEvents(entry.key).isEmpty) {
          try {
            await chatService.setToolEvents(entry.key, entry.value);
          } catch (_) {}
        }
      }
      for (final entry in geminiSigsByMessageId.entries) {
        if (batchGeminiSigs.containsKey(entry.key)) continue;
        if ((chatService.getGeminiThoughtSignature(entry.key) ?? '').isEmpty) {
          try {
            await chatService.setGeminiThoughtSignature(entry.key, entry.value);
          } catch (_) {}
        }
      }
    }

    // Group chat metadata rides the meta payload.
    final groupChatsRaw =
        (chatsMeta['groupChats'] as List?) ?? const <dynamic>[];
    final groupMembersRaw =
        (chatsMeta['groupMembers'] as List?) ?? const <dynamic>[];
    if (groupChatsRaw.isNotEmpty) {
      final existingGroupIds = mode == RestoreMode.merge
          ? (await chatService.repo.getAllGroupChats()).map((g) => g.id).toSet()
          : <String>{};
      for (final raw in groupChatsRaw) {
        try {
          final g = GroupChat.fromJson((raw as Map).cast<String, dynamic>());
          if (mode == RestoreMode.merge && existingGroupIds.contains(g.id)) {
            continue;
          }
          await chatService.repo.putGroupChat(g);
        } catch (e) {
          debugPrint('restoreData: groupChat row: $e');
        }
      }
      final membersByGroup = <String, List<GroupChatMember>>{};
      for (final raw in groupMembersRaw) {
        try {
          final m = GroupChatMember.fromJson(
            (raw as Map).cast<String, dynamic>(),
          );
          (membersByGroup[m.groupChatId] ??= []).add(m);
        } catch (e) {
          debugPrint('restoreData: groupMembers parse: $e');
        }
      }
      for (final entry in membersByGroup.entries) {
        if (mode == RestoreMode.merge && existingGroupIds.contains(entry.key)) {
          continue;
        }
        try {
          await chatService.repo.putGroupMembers(entry.key, entry.value);
        } catch (e) {
          debugPrint('restoreData: groupMembers: $e');
        }
      }
    }
  }

  Future<void> _restoreFromBackupFile(
    File file,
    WebDavConfig cfg, {
    RestoreMode mode = RestoreMode.overwrite,
    RestoreProgressCallback? onProgress,
    ConflictPrecedence precedence = ConflictPrecedence.auto,
  }) async {
    // Incremental backup detection: cuplivo_incr_ prefix forces merge mode
    if (mode == RestoreMode.overwrite &&
        p.basenameWithoutExtension(file.path).startsWith('cuplivo_incr_')) {
      mode = RestoreMode.merge;
    }

    // Extract to temp using file-stream decoding to avoid loading the full ZIP
    // into RAM (the old approach called file.readAsBytes() which for a 600-800 MB
    // file would allocate a contiguous byte array of the same size).
    final tmp = await _ensureTempDir();
    // Uniqueness is OS-atomic (createTemp), NOT millisecond-derived: two
    // concurrent restores in one process (e.g. LAN sync peers under test)
    // must never share an extract dir, or their chats_meta/messages streams
    // interleave and fail the count validation.
    final extractDir = await tmp.createTemp('restore_');

    try {
      onProgress?.call(const RestoreProgress(stage: RestoreStage.extracting));
      // Run ZIP extraction in an isolate to keep the UI responsive.
      await _runExtractInIsolate(file.path, extractDir.path);

      // Kelivo v2 (upstream) backups carry a manifest.json + database/
      // kelivo.db payload instead of chats.json. This build cannot import
      // them — importing would silently restore nothing. Surface a typed
      // error so the UI can redirect to the kelivo-helper compat page.
      // Detected before ANY write, so nothing local is destroyed.
      if (File(p.join(extractDir.path, 'manifest.json')).existsSync()) {
        throw KelivoV2BackupException();
      }
      // Backup content scope: the channel's scope piece admits/declines each
      // payload section (mirrors the exporter's gates).
      final scope = cfg.content;

      // chats_meta.json sentinel → JSONL v2 format (issue #123)
      final chatsMetaFile = File(p.join(extractDir.path, 'chats_meta.json'));
      final isJsonlFormat = await chatsMetaFile.exists();
      Map<String, dynamic> chatsMeta = const {};
      if (isJsonlFormat) {
        try {
          chatsMeta =
              jsonDecode(await chatsMetaFile.readAsString())
                  as Map<String, dynamic>;
        } catch (e) {
          // Malformed sentinel: abort BEFORE any write — a half-written
          // backup must never trigger a partial restore.
          throw StateError('backup_chats_meta_corrupt: $e');
        }
        // Count validation: the streams must match the advertised counts
        // (tolerant of a missing trailing newline; abort on mismatch).
        final expected = chatsMeta['message_count'];
        final actual = await _countJsonlLines(
          File(p.join(extractDir.path, 'messages.jsonl')),
        );
        if (expected is int && expected != actual) {
          throw StateError('backup_chats_count_mismatch');
        }
      }

      // Restore settings
      Object? backupAssistantsRaw;
      Object? backupLegacyOcrEnabled;
      final settingsFile = File(p.join(extractDir.path, 'settings.json'));
      if (scope.anySettings && await settingsFile.exists()) {
        try {
          final txt = await settingsFile.readAsString();
          final map = jsonDecode(txt) as Map<String, dynamic>;
          // Restore-side section gate (mirror of the exporter's
          // `_splitSettingsSections`): assistant-owned keys ride the chats
          // bit, everything else rides the settings bit. Whole-pack legacy
          // zips carry BOTH sections in one settings.json — a partial scope
          // must not smuggle in sections the user excluded.
          const assistantKeys = {'assistants_v1', 'assistant_memories_v1'};
          // Legacy global OCR toggle is an assistant-MIGRATION concern: it
          // follows the chats bit and is always stripped afterwards, so the
          // one-time per-assistant migration never re-runs on a later
          // restore.
          backupLegacyOcrEnabled = scope.chatsAndAssistants
              ? map.remove('ocr_enabled_v1')
              : null;
          map.remove('ocr_enabled_v1');
          for (final key in map.keys.toList()) {
            final bit = assistantKeys.contains(key)
                ? scope.chatsAndAssistants
                : scope.settings;
            if (!bit) map.remove(key);
          }
          backupAssistantsRaw = map.remove('assistants_v1');
          // Kelivo-originated backups carry upstream image-compression keys
          // (image_upload_quality_v1 et al.) instead of Cuplivo's native
          // one_click_compress_* keys. Translate them so the compression
          // settings survive a Kelivo -> Cuplivo migration. The mapper skips
          // files that already carry one_click_* keys (Cuplivo exports carry
          // BOTH key sets — they restore their own values verbatim). In
          // overwrite mode the translated keys win (migrating user); in merge
          // mode they only fill absent slots. Upstream keys are always
          // stripped so they never linger inert in prefs — exports re-derive
          // them from the current one_click_* values.
          final kelivoTranslation =
              KelivoImageSettingsMapper.translateFromUpstream(map);
          if (kelivoTranslation != null) {
            map.addAll(kelivoTranslation);
          }
          for (final key in KelivoImageSettingsMapper.upstreamKeys) {
            map.remove(key);
          }
          final prefs = SharedPreferencesAsync(_preferences);
          if (mode == RestoreMode.overwrite) {
            // For overwrite mode, restore all settings
            await prefs.restore(map);
          } else {
            // For merge mode, intelligently merge settings.
            //
            // LWW (issue #123): settings_meta.json maps business keys to
            // their KV updated_at on the backup device. For non-mergeable
            // scalar keys, "incoming strictly newer" wins wholesale; ties /
            // absent meta fall back to the legacy fill-absent rule below.
            final localMeta = <String, int>{};
            final backupMetaFile = File(
              p.join(extractDir.path, 'settings_meta.json'),
            );
            if (await backupMetaFile.exists()) {
              try {
                final raw = await backupMetaFile.readAsString();
                final decoded = jsonDecode(raw) as Map<String, dynamic>;
                for (final entry in decoded.entries) {
                  final ts = entry.value;
                  if (ts is int) localMeta[entry.key] = ts;
                }
              } catch (e) {
                debugPrint('restore: settings_meta.json parse failed: $e');
              }
            }
            final existing = await prefs.snapshot();

            // Keys that should be merged as JSON arrays/objects
            const mergeableKeys = {
              'assistant_memories_v1', // Assistant memory entries
              'provider_configs_v1', // Provider configurations
              'pinned_models_v1', // Pinned models list
              'providers_order_v1', // Provider order list
              'mcp_servers_v1', // MCP server configurations
              'provider_groups_v1', // provider group list
              'provider_group_map_v1', // providerKey -> groupId
              'provider_group_collapsed_v1', // groupId|__ungrouped__ -> bool
              'search_services_v1', // Search services configuration
              'assistant_tags_v1', // Ordered tag list [{id,name}]
              'assistant_tag_map_v1', // assistantId -> tagId
              'assistant_tag_collapsed_v1', // tagId -> bool
              'asr_services_v1', // ASR service configurations
            };

            for (final entry in map.entries) {
              final key = entry.key;
              final newValue = entry.value;

              if (mergeableKeys.contains(key)) {
                // Special handling for mergeable configurations
                if (key == 'provider_configs_v1' && existing.containsKey(key)) {
                  // Merge provider configs per provider key. Unless the local
                  // side wins (issue #615), the backup wins for all fields
                  // EXCEPT the proxy block, which is device-local: an existing
                  // provider's proxy is composed from its local block over the
                  // no-proxy defaults — the backup's proxy never lands on the
                  // device (issue #512). Brand-new providers keep their backup
                  // proxy. localWins flips the per-provider winner so the local
                  // config survives the merge untouched (new providers still
                  // get added from the backup).
                  try {
                    final existingConfigs =
                        jsonDecode(existing[key] as String)
                            as Map<String, dynamic>;
                    final newConfigs =
                        jsonDecode(newValue as String) as Map<String, dynamic>;

                    // Start from the local configs so providers absent from
                    // the backup survive the merge untouched.
                    final mergedConfigs = <String, dynamic>{...existingConfigs};
                    final localWins =
                        precedence == ConflictPrecedence.localWins;
                    for (final entry in newConfigs.entries) {
                      final providerKey = entry.key;
                      final incoming = entry.value;
                      final local = existingConfigs[providerKey];
                      if (incoming is! Map || local is! Map) {
                        // Malformed entry: keep the prior verbatim behavior
                        // for this entry and continue merging the rest.
                        mergedConfigs[providerKey] = incoming;
                        continue;
                      }
                      final localMap = local.cast<String, dynamic>();
                      if (localWins) {
                        // Local wins: incoming only fills fields the local
                        // config lacks; the proxy block is implicitly local.
                        final mergedLocal = <String, dynamic>{
                          ...incoming.cast<String, dynamic>(),
                          ...localMap,
                        };
                        mergedConfigs[providerKey] = mergedLocal;
                        continue;
                      }
                      // The proxy fields of an existing provider are composed
                      // from the local block (where present) over the
                      // no-proxy defaults — the backup's proxy never lands on
                      // the device, whether the local block is full, partial,
                      // or absent entirely.
                      final merged = <String, dynamic>{
                        ...incoming.cast<String, dynamic>(),
                        ..._noProxyProviderDefaults,
                        for (final field in _providerProxyFields)
                          if (localMap.containsKey(field))
                            field: localMap[field],
                      };
                      mergedConfigs[providerKey] = merged;
                    }
                    await prefs.restoreSingle(key, jsonEncode(mergedConfigs));
                  } catch (e) {
                    // If merge fails, keep existing
                  }
                } else if (key == 'assistant_memories_v1' &&
                    existing.containsKey(key)) {
                  try {
                    await prefs.restoreSingle(
                      key,
                      _mergeAssistantMemories(
                        existing[key] as String,
                        newValue as String,
                      ),
                    );
                  } catch (_) {}
                } else if (key == 'mcp_servers_v1' &&
                    existing.containsKey(key)) {
                  try {
                    await prefs.restoreSingle(
                      key,
                      _mergeJsonListById(
                        existing[key] as String,
                        newValue as String,
                        precedence: precedence,
                      ),
                    );
                  } catch (_) {}
                } else if (key == 'asr_services_v1' &&
                    existing.containsKey(key)) {
                  // Merge ASR services by id; prefer existing on conflicts
                  // (incomingWins flips the winner per id, issue #615).
                  try {
                    await prefs.restoreSingle(
                      key,
                      _mergeJsonListById(
                        existing[key] as String,
                        newValue as String,
                        precedence: precedence,
                      ),
                    );
                  } catch (_) {}
                } else if (key == 'pinned_models_v1' &&
                    existing.containsKey(key)) {
                  // Merge pinned models: combine and deduplicate
                  try {
                    final existingModels =
                        jsonDecode(existing[key] as String) as List;
                    final newModels = jsonDecode(newValue as String) as List;
                    final modelSet = <String>{};

                    // Add all models to set for deduplication
                    for (final model in existingModels) {
                      if (model is String) modelSet.add(model);
                    }
                    for (final model in newModels) {
                      if (model is String) modelSet.add(model);
                    }

                    await prefs.restoreSingle(
                      key,
                      jsonEncode(modelSet.toList()),
                    );
                  } catch (e) {
                    // If merge fails, keep existing
                  }
                } else if (key == 'assistant_tags_v1') {
                  // Merge tag list by id; keep existing order, append new tags
                  // at end (incoming order). incomingWins replaces the entry
                  // content on id conflict (issue #615).
                  try {
                    final existingStr = (existing[key] ?? '') as String?;
                    final newStr = (newValue ?? '') as String?;
                    final existingList =
                        (existingStr == null || existingStr.isEmpty)
                        ? <dynamic>[]
                        : (jsonDecode(existingStr) as List);
                    final newList = (newStr == null || newStr.isEmpty)
                        ? <dynamic>[]
                        : (jsonDecode(newStr) as List);

                    // Map existing by id and maintain order
                    final existingOrder = <String>[];
                    final tagById = <String, Map<String, dynamic>>{};
                    for (final e in existingList) {
                      if (e is Map && e['id'] != null) {
                        final id = e['id'].toString();
                        existingOrder.add(id);
                        tagById[id] = Map<String, dynamic>.from(e);
                      }
                    }
                    // Add new tags that don't exist yet; on id conflict,
                    // incomingWins replaces the local entry in place.
                    for (final e in newList) {
                      if (e is Map && e['id'] != null) {
                        final id = e['id'].toString();
                        if (!tagById.containsKey(id)) {
                          tagById[id] = Map<String, dynamic>.from(e);
                          existingOrder.add(id);
                        } else if (precedence ==
                            ConflictPrecedence.incomingWins) {
                          tagById[id] = Map<String, dynamic>.from(e);
                        }
                      }
                    }
                    final merged = [
                      for (final id in existingOrder) tagById[id],
                    ].whereType<Map<String, dynamic>>().toList();
                    await prefs.restoreSingle(key, jsonEncode(merged));
                  } catch (_) {
                    // If merge fails, fall back to existing (no action)
                  }
                } else if (key == 'assistant_tag_map_v1') {
                  // Merge assistant->tag mapping; prefer existing on conflicts
                  // (incomingWins flips the winner per key, issue #615).
                  try {
                    final existingStr = (existing[key] ?? '') as String?;
                    final newStr = (newValue ?? '') as String?;
                    final existingMap =
                        (existingStr == null || existingStr.isEmpty)
                        ? <String, dynamic>{}
                        : (jsonDecode(existingStr) as Map<String, dynamic>);
                    final newMap = (newStr == null || newStr.isEmpty)
                        ? <String, dynamic>{}
                        : (jsonDecode(newStr) as Map<String, dynamic>);
                    final merged = precedence == ConflictPrecedence.incomingWins
                        ? <String, dynamic>{...existingMap, ...newMap}
                        : <String, dynamic>{...newMap, ...existingMap};
                    await prefs.restoreSingle(key, jsonEncode(merged));
                  } catch (_) {}
                } else if (key == 'assistant_tag_collapsed_v1') {
                  // Merge collapse states; prefer existing on conflicts
                  // (incomingWins flips the winner per key, issue #615).
                  try {
                    final existingStr = (existing[key] ?? '') as String?;
                    final newStr = (newValue ?? '') as String?;
                    final existingMap =
                        (existingStr == null || existingStr.isEmpty)
                        ? <String, dynamic>{}
                        : (jsonDecode(existingStr) as Map<String, dynamic>);
                    final newMap = (newStr == null || newStr.isEmpty)
                        ? <String, dynamic>{}
                        : (jsonDecode(newStr) as Map<String, dynamic>);
                    final merged = precedence == ConflictPrecedence.incomingWins
                        ? <String, dynamic>{...existingMap, ...newMap}
                        : <String, dynamic>{...newMap, ...existingMap};
                    await prefs.restoreSingle(key, jsonEncode(merged));
                  } catch (_) {}
                } else if (key == 'provider_groups_v1') {
                  // Merge provider groups by id; keep existing order, append new groups at end (incoming order). incomingWins replaces the entry content on id conflict (issue #615).
                  try {
                    final existingStr = (existing[key] ?? '') as String?;
                    final newStr = (newValue ?? '') as String?;
                    final existingList =
                        (existingStr == null || existingStr.isEmpty)
                        ? <dynamic>[]
                        : (jsonDecode(existingStr) as List);
                    final newList = (newStr == null || newStr.isEmpty)
                        ? <dynamic>[]
                        : (jsonDecode(newStr) as List);

                    final existingOrder = <String>[];
                    final groupById = <String, Map<String, dynamic>>{};
                    for (final e in existingList) {
                      if (e is Map && e['id'] != null) {
                        final id = e['id'].toString();
                        existingOrder.add(id);
                        groupById[id] = Map<String, dynamic>.from(e);
                      }
                    }
                    for (final e in newList) {
                      if (e is Map && e['id'] != null) {
                        final id = e['id'].toString();
                        if (!groupById.containsKey(id)) {
                          groupById[id] = Map<String, dynamic>.from(e);
                          existingOrder.add(id);
                        } else if (precedence ==
                            ConflictPrecedence.incomingWins) {
                          groupById[id] = Map<String, dynamic>.from(e);
                        }
                      }
                    }
                    final merged = [
                      for (final id in existingOrder) groupById[id],
                    ].whereType<Map<String, dynamic>>().toList();
                    await prefs.restoreSingle(key, jsonEncode(merged));
                  } catch (_) {}
                } else if (key == 'provider_group_map_v1') {
                  // Merge provider->group mapping; prefer existing on conflicts
                  // (incomingWins flips the winner per key, issue #615).
                  try {
                    final existingStr = (existing[key] ?? '') as String?;
                    final newStr = (newValue ?? '') as String?;
                    final existingMap =
                        (existingStr == null || existingStr.isEmpty)
                        ? <String, dynamic>{}
                        : (jsonDecode(existingStr) as Map<String, dynamic>);
                    final newMap = (newStr == null || newStr.isEmpty)
                        ? <String, dynamic>{}
                        : (jsonDecode(newStr) as Map<String, dynamic>);
                    final merged = precedence == ConflictPrecedence.incomingWins
                        ? <String, dynamic>{...existingMap, ...newMap}
                        : <String, dynamic>{...newMap, ...existingMap};
                    await prefs.restoreSingle(key, jsonEncode(merged));
                  } catch (_) {}
                } else if (key == 'provider_group_collapsed_v1') {
                  // Merge collapse states; prefer existing on conflicts
                  // (incomingWins flips the winner per key, issue #615).
                  try {
                    final existingStr = (existing[key] ?? '') as String?;
                    final newStr = (newValue ?? '') as String?;
                    final existingMap =
                        (existingStr == null || existingStr.isEmpty)
                        ? <String, dynamic>{}
                        : (jsonDecode(existingStr) as Map<String, dynamic>);
                    final newMap = (newStr == null || newStr.isEmpty)
                        ? <String, dynamic>{}
                        : (jsonDecode(newStr) as Map<String, dynamic>);
                    final merged = precedence == ConflictPrecedence.incomingWins
                        ? <String, dynamic>{...existingMap, ...newMap}
                        : <String, dynamic>{...newMap, ...existingMap};
                    await prefs.restoreSingle(key, jsonEncode(merged));
                  } catch (_) {}
                } else if ((key == 'providers_order_v1' ||
                        key == 'search_services_v1') &&
                    existing.containsKey(key)) {
                  // For these lists, prefer the imported version if different
                  // (ensures new providers/services are properly ordered).
                  // localWins keeps the local list (issue #615); incomingWins
                  // keeps the incumbent replacing behavior.
                  if (precedence != ConflictPrecedence.localWins) {
                    await prefs.restoreSingle(key, newValue);
                  }
                } else {
                  // For new keys, add them
                  await prefs.restoreSingle(key, newValue);
                }
              } else if (existing.containsKey(key)) {
                // LWW scalar merge (issue #123): supply the incoming value
                // only when the backup's KV updated_at is strictly newer than
                // the local KV updated_at. No meta on either side → legacy
                // fill-absent behavior (the branch below). Direction overrides
                // the clock (issue #615): localWins keeps the local value,
                // incomingWins adopts the incoming value wholesale.
                if (precedence == ConflictPrecedence.incomingWins) {
                  await prefs.restoreSingle(key, newValue);
                } else if (precedence != ConflictPrecedence.localWins &&
                    localMeta.isNotEmpty) {
                  final backupTs = localMeta[key];
                  final localTs = _localUpdatedAtFor(key);
                  if (backupTs != null &&
                      localTs != null &&
                      backupTs > localTs) {
                    await prefs.restoreSingle(key, newValue);
                  }
                }
              } else if (!existing.containsKey(key)) {
                // For non-mergeable keys, only add if not existing
                await prefs.restoreSingle(key, newValue);
              }
              // Skip existing non-mergeable keys to preserve user preferences
            }
          }
        } catch (_) {}
      }

      // Parse the backup's assistants BEFORE any destructive write so a
      // malformed payload aborts cleanly instead of leaving a wiped-but-empty
      // assistant table (issue #475). The overwrite path is fully parsed into
      // [Assistant] objects here; the merge path only validates that the
      // payload is a list of maps (field-level parse happens against the
      // merged maps during the write phase, mirroring pre-refactor behavior).
      List<Map<String, dynamic>>? rawIncomingAssistants;
      List<Assistant>? parsedOverwriteAssistants;
      if (backupAssistantsRaw is String) {
        final decoded = jsonDecode(backupAssistantsRaw) as List;
        rawIncomingAssistants = decoded
            .whereType<Map>()
            .map((e) => Map<String, dynamic>.from(e))
            .toList();
        if (mode == RestoreMode.overwrite) {
          parsedOverwriteAssistants = rawIncomingAssistants
              .map(
                (e) => Assistant.fromJson(
                  _applyLegacyOcrModeToAssistantMap(e, backupLegacyOcrEnabled),
                ),
              )
              .toList();
        }
      }

      // Restore chats
      final chatsFile = File(p.join(extractDir.path, 'chats.json'));
      if (scope.chatsAndAssistants &&
          (await chatsFile.exists() || await chatsMetaFile.exists())) {
        if (isJsonlFormat) {
          await _restoreChatsFromJsonl(
            extractDir: extractDir,
            chatsMeta: chatsMeta,
            mode: mode,
            onProgress: onProgress,
            precedence: precedence,
          );
        } else {
          try {
            final obj =
                jsonDecode(await chatsFile.readAsString())
                    as Map<String, dynamic>;
            final convs =
                (obj['conversations'] as List?)
                    ?.map(
                      (e) => Conversation.fromJson(
                        (e as Map).cast<String, dynamic>(),
                      ),
                    )
                    .toList() ??
                const <Conversation>[];
            final msgs =
                (obj['messages'] as List?)
                    ?.map(
                      (e) => ChatMessage.fromJson(
                        (e as Map).cast<String, dynamic>(),
                      ),
                    )
                    .toList() ??
                const <ChatMessage>[];
            final toolEvents =
                ((obj['toolEvents'] as Map?) ?? const <String, dynamic>{}).map(
                  (k, v) => MapEntry(
                    k.toString(),
                    (v as List)
                        .cast<Map>()
                        .map((e) => e.cast<String, dynamic>())
                        .toList(),
                  ),
                );
            final geminiThoughtSigs =
                ((obj['geminiThoughtSigs'] as Map?) ??
                        const <String, dynamic>{})
                    .map((k, v) => MapEntry(k.toString(), v.toString()));

            if (mode == RestoreMode.overwrite) {
              await chatService.clearAllData();
              final byConv = <String, List<ChatMessage>>{};
              for (final m in msgs) {
                (byConv[m.conversationId] ??= <ChatMessage>[]).add(m);
              }
              await chatService.restoreConversationsBatch(
                conversations: convs,
                messagesByConversation: byConv,
                toolEventsByMessageId: toolEvents,
                geminiSignaturesByMessageId: geminiThoughtSigs,
              );
            } else {
              // Merge mode: Add only non-existing conversations and messages
              onProgress?.call(
                const RestoreProgress(stage: RestoreStage.mergingChats),
              );
              final existingConvs = chatService.getAllCompleteConversations();
              final existingConvIds = existingConvs.map((c) => c.id).toSet();
              final existingConvsById = <String, Conversation>{
                for (final cv in existingConvs) cv.id: cv,
              };

              // Create a map of message IDs to avoid duplicates
              final existingMsgIds = <String>{};
              for (final conv in existingConvs) {
                final messages = chatService.getMessages(conv.id);
                existingMsgIds.addAll(messages.map((m) => m.id));
              }

              // Group messages by conversation
              final byConv = <String, List<ChatMessage>>{};
              for (final m in msgs) {
                if (!existingMsgIds.contains(m.id)) {
                  (byConv[m.conversationId] ??= <ChatMessage>[]).add(m);
                }
              }

              // Batch-write new conversations; per-message for existing ones
              final batchConvs = <Conversation>[];
              final batchMsgs = <String, List<ChatMessage>>{};
              final batchToolEvents = <String, List<Map<String, dynamic>>>{};
              final batchGeminiSigs = <String, String>{};
              var mergedConvs = 0;
              final totalConvs = convs.length;
              for (final c in convs) {
                if (!existingConvIds.contains(c.id)) {
                  batchConvs.add(c);
                  final list = byConv[c.id] ?? const <ChatMessage>[];
                  batchMsgs[c.id] = list;
                  for (final msg in list) {
                    if (toolEvents.containsKey(msg.id)) {
                      batchToolEvents[msg.id] = toolEvents[msg.id]!;
                    }
                    if (geminiThoughtSigs.containsKey(msg.id)) {
                      batchGeminiSigs[msg.id] = geminiThoughtSigs[msg.id]!;
                    }
                  }
                } else if (byConv.containsKey(c.id)) {
                  final newMessages = byConv[c.id]!;
                  // Conversation metadata direction (issue #615, category D):
                  // with incomingWins the winner's row replaces the loser's
                  // (id, createdAt and messageIds exempt).
                  if (precedence == ConflictPrecedence.incomingWins) {
                    final local = existingConvsById[c.id];
                    await chatService.replaceConversationRow(
                      c.copyWith(
                        createdAt: local?.createdAt,
                        // Same rule as the JSONL branch: the sort key must
                        // never regress below either side's updatedAt.
                        updatedAt:
                            (local != null &&
                                local.updatedAt.isAfter(c.updatedAt))
                            ? local.updatedAt
                            : c.updatedAt,
                        messageIds: [
                          ...(local?.messageIds ?? const <String>[]),
                          for (final msg in newMessages) msg.id,
                        ],
                      ),
                    );
                  }
                  for (final msg in newMessages) {
                    await chatService.addMessageDirectly(c.id, msg);
                  }
                }
                mergedConvs++;
                if (totalConvs > 0) {
                  onProgress?.call(
                    RestoreProgress(
                      stage: RestoreStage.mergingChats,
                      fraction: mergedConvs / totalConvs,
                      conversationsMerged: mergedConvs,
                      conversationsTotal: totalConvs,
                    ),
                  );
                }
              }

              if (batchConvs.isNotEmpty) {
                await chatService.restoreConversationsBatch(
                  conversations: batchConvs,
                  messagesByConversation: batchMsgs,
                  toolEventsByMessageId: batchToolEvents,
                  geminiSignaturesByMessageId: batchGeminiSigs,
                );
              }

              // Merge remaining tool events and signatures
              // (entries belonging to batch-handled messages are safely skipped
              //  since they already exist in DB)
              for (final entry in toolEvents.entries) {
                if (batchToolEvents.containsKey(entry.key)) continue;
                final existing = chatService.getToolEvents(entry.key);
                if (existing.isEmpty) {
                  try {
                    await chatService.setToolEvents(entry.key, entry.value);
                  } catch (_) {}
                }
              }
              for (final entry in geminiThoughtSigs.entries) {
                if (batchGeminiSigs.containsKey(entry.key)) continue;
                final existingSig = chatService.getGeminiThoughtSignature(
                  entry.key,
                );
                if (existingSig == null || existingSig.isEmpty) {
                  try {
                    await chatService.setGeminiThoughtSignature(
                      entry.key,
                      entry.value,
                    );
                  } catch (_) {}
                }
              }
            }

            // Restore group chat metadata. The groupChats/groupMembers keys are
            // present on both v1 and v2 exports and are always restored when
            // non-empty.
            final groupChatsRaw = obj['groupChats'] as List? ?? const [];
            final groupMembersRaw = obj['groupMembers'] as List? ?? const [];
            if (groupChatsRaw.isNotEmpty) {
              final existingGroupIds = mode == RestoreMode.merge
                  ? (await chatService.repo.getAllGroupChats())
                        .map((g) => g.id)
                        .toSet()
                  : <String>{};
              for (final raw in groupChatsRaw) {
                try {
                  final g = GroupChat.fromJson(
                    (raw as Map).cast<String, dynamic>(),
                  );
                  if (mode == RestoreMode.merge &&
                      existingGroupIds.contains(g.id)) {
                    continue;
                  }
                  await chatService.repo.putGroupChat(g);
                } catch (e) {
                  debugPrint('restoreData: groupChat row: $e');
                }
              }
              final membersByGroup = <String, List<GroupChatMember>>{};
              for (final raw in groupMembersRaw) {
                try {
                  final m = GroupChatMember.fromJson(
                    (raw as Map).cast<String, dynamic>(),
                  );
                  (membersByGroup[m.groupChatId] ??= []).add(m);
                } catch (e) {
                  debugPrint('restoreData: groupMembers parse: $e');
                }
              }
              for (final entry in membersByGroup.entries) {
                if (mode == RestoreMode.merge &&
                    existingGroupIds.contains(entry.key)) {
                  continue;
                }
                try {
                  await chatService.repo.putGroupMembers(
                    entry.key,
                    entry.value,
                  );
                } catch (e) {
                  debugPrint('restoreData: groupMembers: $e');
                }
              }
            }
          } catch (e, st) {
            debugPrint('restoreData: chats restore failed: $e\n$st');
          }
        }
      }
      // Restore assistants to SQLite. Runs AFTER clearAllData + chats but
      // BEFORE the fallible file/skill copying below, so a mid-restore file
      // failure can never leave the assistant table wiped-but-empty (issue
      // #475).
      if (rawIncomingAssistants != null) {
        if (!chatService.initialized) await chatService.init();
        if (mode == RestoreMode.overwrite) {
          final assistants = parsedOverwriteAssistants;
          if (assistants == null) {
            throw StateError('assistants_parse_incomplete');
          }
          await chatService.putAssistants(assistants);
        } else {
          final existing = await chatService.getAllAssistants();
          final existingMaps = existing.map((a) => a.toJson()).toList();
          final merged = _mergeAssistantMaps(
            existingMaps,
            rawIncomingAssistants,
            precedence: precedence,
          );
          // Local assistants always carry an explicit ocrMode; only
          // brand-new incoming assistants can still lack it.
          final assistants = merged
              .map(
                (m) => Assistant.fromJson(
                  _applyLegacyOcrModeToAssistantMap(m, backupLegacyOcrEnabled),
                ),
              )
              .toList();
          await chatService.putAssistants(assistants);
        }
      }

      // Restore deleted.json markers (merge mode only — overwrite wipes local)
      if (scope.chatsAndAssistants && mode == RestoreMode.merge) {
        final deletedFile = File(p.join(extractDir.path, 'deleted.json'));
        if (await deletedFile.exists()) {
          try {
            final deletedJson = await deletedFile.readAsString();
            final parsed = parseDeletedJson(deletedJson);
            final store = chatService.deletedRecordsStore;
            if (store != null) {
              for (final entry in parsed.entries) {
                final type = entry.key;
                final entries = entry.value;
                // Only write markers for ids that still exist locally.
                // The caller (UI) will show them as "远端已删除" and offer
                // one-click local deletion.
                final List<({String id, DateTime deletedAt})> toWrite;
                if (type == DeletionEntityType.workspaceFile) {
                  toWrite = await _filterExistingWorkspaceFiles(entries);
                } else {
                  final localIds = await _getLocalIdsForType(type);
                  toWrite = entries
                      .where((e) => localIds.contains(e.id))
                      .toList();
                }
                if (toWrite.isNotEmpty) {
                  await store.recordRemoteDeletions(
                    type: type,
                    entries: toWrite,
                  );
                }
              }
            }
          } catch (e) {
            debugPrint('restoreData: failed to import deleted.json: $e');
          }
        }
      }

      // LAN-sync file manifest: exact ms mtimes of the packed files, so a
      // restored file's mtime matches the sender's and the next sync's delta
      // comparison sees no drift. Absent in normal backups / old-peer zips —
      // fall back to the zip's own (second-granularity) mtimes.
      Map<String, ({int size, int mtimeMs})>? syncManifest;
      final syncManifestFile = File(
        p.join(extractDir.path, 'sync_manifest.json'),
      );
      if (await syncManifestFile.exists()) {
        try {
          final raw =
              jsonDecode(await syncManifestFile.readAsString())
                  as Map<String, dynamic>;
          syncManifest = raw.map((key, value) {
            final m = (value as Map).cast<String, dynamic>();
            return MapEntry(key, (
              size: m['size'] as int,
              mtimeMs: m['mtime'] as int,
            ));
          });
        } catch (e) {
          debugPrint('restoreData: failed to parse sync_manifest.json: $e');
        }
      }

      // Restore files. File copying is best-effort: a single locked or unusual
      // file must not abort the whole restore — conversations and assistants
      // are already committed at this point.
      if (scope.anyFiles) {
        var totalFiles = 0;
        var totalBytes = 0;
        var copiedFiles = 0;
        var copiedBytes = 0;
        double? lastReportedFraction;

        void reportFiles() {
          // totalFiles jumps at directory boundaries (upload → images → …),
          // so the raw fraction can regress after a directory completes; the
          // progress bar must never move backwards. copiedFiles only grows,
          // so clamping to the last reported fraction is the true lower bound.
          var fraction = totalFiles == 0 ? null : copiedFiles / totalFiles;
          if (fraction != null &&
              lastReportedFraction != null &&
              fraction < lastReportedFraction!) {
            fraction = lastReportedFraction;
          }
          if (fraction != null) lastReportedFraction = fraction;
          onProgress?.call(
            RestoreProgress(
              stage: RestoreStage.copyingFiles,
              fraction: fraction,
              filesCopied: copiedFiles,
              filesTotal: totalFiles,
              bytesCopied: copiedBytes,
              bytesTotal: totalBytes,
            ),
          );
        }

        void bumpCopied(File file) {
          // Progress counts *processed* entries — including ones kept local
          // (copy-if-absent skips, newer-wins ties) — so the fraction tracks
          // walk progress, which is what the progress bar needs.
          copiedFiles++;
          try {
            copiedBytes += file.lengthSync();
          } catch (_) {}
          reportFiles();
        }

        try {
          if (mode == RestoreMode.overwrite) {
            // Overwrite mode: Delete existing directories and copy all
            // Restore upload directory
            final uploadSrc = Directory(p.join(extractDir.path, 'upload'));
            if (scope.attachments && await uploadSrc.exists()) {
              final entries = _listFiles(uploadSrc);
              final dst = await _getUploadDir();
              if (await dst.exists()) {
                try {
                  await dst.delete(recursive: true);
                } catch (_) {}
              }
              await dst.create(recursive: true);
              totalFiles += entries.length;
              for (final e in entries) {
                try {
                  totalBytes += e.file.lengthSync();
                } catch (_) {}
              }
              for (final e in entries) {
                final target = File(p.join(dst.path, e.rel));
                await target.parent.create(recursive: true);
                await e.file.copy(target.path);
                try {
                  await _setTargetMtime(
                    target,
                    e.file,
                    extractDir.path,
                    syncManifest,
                  );
                } catch (_) {}
                bumpCopied(e.file);
              }
            }

            // Restore images directory
            final imagesSrc = Directory(p.join(extractDir.path, 'images'));
            if (scope.attachments && await imagesSrc.exists()) {
              final entries = _listFiles(imagesSrc);
              final dst = await _getImagesDir();
              if (await dst.exists()) {
                try {
                  await dst.delete(recursive: true);
                } catch (_) {}
              }
              await dst.create(recursive: true);
              totalFiles += entries.length;
              for (final e in entries) {
                try {
                  totalBytes += e.file.lengthSync();
                } catch (_) {}
              }
              for (final e in entries) {
                final target = File(p.join(dst.path, e.rel));
                await target.parent.create(recursive: true);
                await e.file.copy(target.path);
                try {
                  await _setTargetMtime(
                    target,
                    e.file,
                    extractDir.path,
                    syncManifest,
                  );
                } catch (_) {}
                bumpCopied(e.file);
              }
            }

            // Restore avatars directory
            final avatarsSrc = Directory(p.join(extractDir.path, 'avatars'));
            if (scope.fontsAndAvatars && await avatarsSrc.exists()) {
              final entries = _listFiles(avatarsSrc);
              final dst = await _getAvatarsDir();
              if (await dst.exists()) {
                try {
                  await dst.delete(recursive: true);
                } catch (_) {}
              }
              await dst.create(recursive: true);
              totalFiles += entries.length;
              for (final e in entries) {
                try {
                  totalBytes += e.file.lengthSync();
                } catch (_) {}
              }
              for (final e in entries) {
                final target = File(p.join(dst.path, e.rel));
                await target.parent.create(recursive: true);
                await e.file.copy(target.path);
                try {
                  await _setTargetMtime(
                    target,
                    e.file,
                    extractDir.path,
                    syncManifest,
                  );
                } catch (_) {}
                bumpCopied(e.file);
              }
            }

            // Restore managed local fonts directory
            final fontsSrc = Directory(p.join(extractDir.path, 'fonts'));
            if (scope.fontsAndAvatars && await fontsSrc.exists()) {
              final entries = _listFiles(fontsSrc);
              final dst = await _getFontsDir();
              if (await dst.exists()) {
                try {
                  await dst.delete(recursive: true);
                } catch (_) {}
              }
              await dst.create(recursive: true);
              totalFiles += entries.length;
              for (final e in entries) {
                try {
                  totalBytes += e.file.lengthSync();
                } catch (_) {}
              }
              for (final e in entries) {
                final target = File(p.join(dst.path, e.rel));
                await target.parent.create(recursive: true);
                await e.file.copy(target.path);
                try {
                  await _setTargetMtime(
                    target,
                    e.file,
                    extractDir.path,
                    syncManifest,
                  );
                } catch (_) {}
                bumpCopied(e.file);
              }
            }

            // Restore @workspaces sandbox directory (dot-prefixed entries are
            // never exported, so none should appear here; skip them defensively)
            final workspacesSrc = Directory(
              p.join(extractDir.path, 'workspaces'),
            );
            if (scope.workspaces && await workspacesSrc.exists()) {
              final entries = _listFiles(workspacesSrc, skipDot: true);
              final dst = await _getWorkspacesDir();
              if (await dst.exists()) {
                try {
                  await dst.delete(recursive: true);
                } catch (_) {}
              }
              await dst.create(recursive: true);
              totalFiles += entries.length;
              for (final e in entries) {
                try {
                  totalBytes += e.file.lengthSync();
                } catch (_) {}
              }
              for (final e in entries) {
                final target = File(p.join(dst.path, e.rel));
                await target.parent.create(recursive: true);
                await e.file.copy(target.path);
                try {
                  await _setTargetMtime(
                    target,
                    e.file,
                    extractDir.path,
                    syncManifest,
                  );
                } catch (_) {}
                bumpCopied(e.file);
              }
            }
          } else {
            // Merge mode: per-file newer-wins across every tree (see the
            // per-tree blocks below) — a backup entry replaces the local copy
            // only when strictly newer; ties/older keep local. This converges
            // bidirectional sync; copy-if-absent (the old behavior) would keep
            // a peer's stale copy forever.
            // Merge upload directory
            final uploadSrc = Directory(p.join(extractDir.path, 'upload'));
            if (scope.attachments && await uploadSrc.exists()) {
              final entries = _listFiles(uploadSrc);
              final dst = await _getUploadDir();
              if (!await dst.exists()) {
                await dst.create(recursive: true);
              }
              totalFiles += entries.length;
              for (final e in entries) {
                try {
                  totalBytes += e.file.lengthSync();
                } catch (_) {}
              }
              for (final e in entries) {
                final target = File(p.join(dst.path, e.rel));
                // Merge semantics: newer-wins per file (same rule as
                // workspaces/skills) — a backup entry replaces the local copy
                // only when strictly newer. Copy-if-absent (the old behavior)
                // would never propagate an updated upload file across LAN sync.
                var keepLocal = false;
                if (await target.exists()) {
                  try {
                    final backupMod = await _backupFileMtime(
                      e.file,
                      extractDir.path,
                      syncManifest,
                    );
                    final localMod = await target.lastModified();
                    keepLocal = !backupMod.isAfter(localMod);
                  } catch (_) {
                    // Cannot compare mtimes — keep the local copy conservatively
                    keepLocal = true;
                  }
                }
                if (!keepLocal) {
                  await target.parent.create(recursive: true);
                  await e.file.copy(target.path);
                  try {
                    await _setTargetMtime(
                      target,
                      e.file,
                      extractDir.path,
                      syncManifest,
                    );
                  } catch (_) {}
                }
                bumpCopied(e.file);
              }
            }

            // Merge images directory
            final imagesSrc = Directory(p.join(extractDir.path, 'images'));
            if (scope.attachments && await imagesSrc.exists()) {
              final entries = _listFiles(imagesSrc);
              final dst = await _getImagesDir();
              if (!await dst.exists()) {
                await dst.create(recursive: true);
              }
              totalFiles += entries.length;
              for (final e in entries) {
                try {
                  totalBytes += e.file.lengthSync();
                } catch (_) {}
              }
              for (final e in entries) {
                final target = File(p.join(dst.path, e.rel));
                var keepLocal = false;
                if (await target.exists()) {
                  try {
                    final backupMod = await _backupFileMtime(
                      e.file,
                      extractDir.path,
                      syncManifest,
                    );
                    final localMod = await target.lastModified();
                    keepLocal = !backupMod.isAfter(localMod);
                  } catch (_) {
                    // Cannot compare mtimes — keep the local copy conservatively
                    keepLocal = true;
                  }
                }
                if (!keepLocal) {
                  await target.parent.create(recursive: true);
                  await e.file.copy(target.path);
                  try {
                    await _setTargetMtime(
                      target,
                      e.file,
                      extractDir.path,
                      syncManifest,
                    );
                  } catch (_) {}
                }
                bumpCopied(e.file);
              }
            }

            // Merge avatars directory
            final avatarsSrc = Directory(p.join(extractDir.path, 'avatars'));
            if (scope.fontsAndAvatars && await avatarsSrc.exists()) {
              final entries = _listFiles(avatarsSrc);
              final dst = await _getAvatarsDir();
              if (!await dst.exists()) {
                await dst.create(recursive: true);
              }
              totalFiles += entries.length;
              for (final e in entries) {
                try {
                  totalBytes += e.file.lengthSync();
                } catch (_) {}
              }
              for (final e in entries) {
                final target = File(p.join(dst.path, e.rel));
                var keepLocal = false;
                if (await target.exists()) {
                  try {
                    final backupMod = await _backupFileMtime(
                      e.file,
                      extractDir.path,
                      syncManifest,
                    );
                    final localMod = await target.lastModified();
                    keepLocal = !backupMod.isAfter(localMod);
                  } catch (_) {
                    // Cannot compare mtimes — keep the local copy conservatively
                    keepLocal = true;
                  }
                }
                if (!keepLocal) {
                  await target.parent.create(recursive: true);
                  await e.file.copy(target.path);
                  try {
                    await _setTargetMtime(
                      target,
                      e.file,
                      extractDir.path,
                      syncManifest,
                    );
                  } catch (_) {}
                }
                bumpCopied(e.file);
              }
            }

            // Merge managed local fonts directory
            final fontsSrc = Directory(p.join(extractDir.path, 'fonts'));
            if (scope.fontsAndAvatars && await fontsSrc.exists()) {
              final entries = _listFiles(fontsSrc);
              final dst = await _getFontsDir();
              if (!await dst.exists()) {
                await dst.create(recursive: true);
              }
              totalFiles += entries.length;
              for (final e in entries) {
                try {
                  totalBytes += e.file.lengthSync();
                } catch (_) {}
              }
              for (final e in entries) {
                final target = File(p.join(dst.path, e.rel));
                var keepLocal = false;
                if (await target.exists()) {
                  try {
                    final backupMod = await _backupFileMtime(
                      e.file,
                      extractDir.path,
                      syncManifest,
                    );
                    final localMod = await target.lastModified();
                    keepLocal = !backupMod.isAfter(localMod);
                  } catch (_) {
                    // Cannot compare mtimes — keep the local copy conservatively
                    keepLocal = true;
                  }
                }
                if (!keepLocal) {
                  await target.parent.create(recursive: true);
                  await e.file.copy(target.path);
                  try {
                    await _setTargetMtime(
                      target,
                      e.file,
                      extractDir.path,
                      syncManifest,
                    );
                  } catch (_) {}
                }
                bumpCopied(e.file);
              }
            }

            // Merge @workspaces sandbox directory (skip dot-prefixed entries).
            // Merge semantics: newer-wins per file (same as skills) — a backup
            // entry replaces the local copy only when strictly newer. This
            // converges bidirectional sync to the newest content; copy-if-absent
            // (the old behavior) would keep a peer's stale copy forever.
            final workspacesSrc = Directory(
              p.join(extractDir.path, 'workspaces'),
            );
            if (scope.workspaces && await workspacesSrc.exists()) {
              final entries = _listFiles(workspacesSrc, skipDot: true);
              final dst = await _getWorkspacesDir();
              if (!await dst.exists()) {
                await dst.create(recursive: true);
              }
              totalFiles += entries.length;
              for (final e in entries) {
                try {
                  totalBytes += e.file.lengthSync();
                } catch (_) {}
              }
              for (final e in entries) {
                final target = File(p.join(dst.path, e.rel));
                var keepLocal = false;
                if (await target.exists()) {
                  try {
                    final backupMod = await _backupFileMtime(
                      e.file,
                      extractDir.path,
                      syncManifest,
                    );
                    final localMod = await target.lastModified();
                    keepLocal = !backupMod.isAfter(localMod);
                  } catch (_) {
                    // Cannot compare mtimes — keep the local copy conservatively
                    keepLocal = true;
                  }
                }
                if (!keepLocal) {
                  await target.parent.create(recursive: true);
                  await e.file.copy(target.path);
                  try {
                    await _setTargetMtime(
                      target,
                      e.file,
                      extractDir.path,
                      syncManifest,
                    );
                  } catch (_) {}
                }
                bumpCopied(e.file);
              }
            }
          }
        } catch (e, st) {
          debugPrint('restoreData: files restore failed: $e\n$st');
        }
      }

      // Restore skills/ -- scope-gated (the "always included" rule was
      // dropped with the 6-section backup content scope).
      // Best-effort like files/: a skill-file failure must not abort the
      // whole restore.
      var skillTotalFiles = 0;
      var skillTotalBytes = 0;
      var skillCopiedFiles = 0;
      var skillCopiedBytes = 0;

      void reportSkills() {
        onProgress?.call(
          RestoreProgress(
            stage: RestoreStage.restoringSkills,
            fraction: skillTotalFiles == 0
                ? null
                : skillCopiedFiles / skillTotalFiles,
            filesCopied: skillCopiedFiles,
            filesTotal: skillTotalFiles,
            bytesCopied: skillCopiedBytes,
            bytesTotal: skillTotalBytes,
          ),
        );
      }

      try {
        final skillsSrc = Directory(p.join(extractDir.path, 'skills'));
        if (scope.skills && await skillsSrc.exists()) {
          final entries = _listFiles(skillsSrc);
          final dst = await _getSkillsDir();
          if (mode == RestoreMode.overwrite && await dst.exists()) {
            try {
              await dst.delete(recursive: true);
            } catch (_) {}
          }
          if (!await dst.exists()) {
            await dst.create(recursive: true);
          }
          skillTotalFiles += entries.length;
          for (final e in entries) {
            try {
              skillTotalBytes += e.file.lengthSync();
            } catch (_) {}
          }
          for (final e in entries) {
            final target = File(p.join(dst.path, e.rel));
            var keepLocal = false;
            if (mode == RestoreMode.merge && await target.exists()) {
              // Newer-wins per file: replace a local copy only when the
              // backup entry is strictly newer; ties/older keep local.
              try {
                final backupMod = await _backupFileMtime(
                  e.file,
                  extractDir.path,
                  syncManifest,
                );
                final localMod = await target.lastModified();
                keepLocal = !backupMod.isAfter(localMod);
              } catch (_) {
                // Cannot compare mtimes — keep the local copy conservatively
                keepLocal = true;
              }
            }
            if (!keepLocal) {
              await target.parent.create(recursive: true);
              await e.file.copy(target.path);
              try {
                await _setTargetMtime(
                  target,
                  e.file,
                  extractDir.path,
                  syncManifest,
                );
              } catch (_) {}
            }
            skillCopiedFiles++;
            try {
              skillCopiedBytes += e.file.lengthSync();
            } catch (_) {}
            reportSkills();
          }
        }
      } catch (e, st) {
        debugPrint('restoreData: skills restore failed: $e\n$st');
      }

      // Always re-sync conversation cache from disk after restore so UI/providers
      // do not keep a wiped in-memory view while SQLite already has rows.
      if (chatService.initialized) {
        try {
          await chatService.reloadCachesFromDb();
        } catch (e, st) {
          debugPrint('restoreData: reloadCachesFromDb failed: $e\n$st');
        }
      }
    } finally {
      await _deleteDirectoryQuietly(extractDir);
    }
  }

  /// Merges two JSON-encoded lists keyed by `id`. By default the existing
  /// entry wins on id conflict and brand-new ids are appended in incoming
  /// order. `incomingWins` replaces the local entry in place on id conflict
  /// (issue #615); `localWins` is the incumbent behavior.
  static String _mergeJsonListById(
    String existingRaw,
    String incomingRaw, {
    ConflictPrecedence precedence = ConflictPrecedence.auto,
  }) {
    final existingList = jsonDecode(existingRaw) as List;
    final incomingList = jsonDecode(incomingRaw) as List;
    final byId = <String, Map<String, dynamic>>{};
    final order = <String>[];

    void addIfNew(dynamic item) {
      if (item is! Map || item['id'] == null) return;
      final id = item['id'].toString();
      if (id.isEmpty || byId.containsKey(id)) return;
      byId[id] = Map<String, dynamic>.from(item);
      order.add(id);
    }

    for (final item in existingList) {
      addIfNew(item);
    }
    for (final item in incomingList) {
      final id = item is Map ? item['id']?.toString() : null;
      if (id != null &&
          byId.containsKey(id) &&
          precedence == ConflictPrecedence.incomingWins) {
        byId[id] = Map<String, dynamic>.from(item);
        continue;
      }
      addIfNew(item);
    }

    return jsonEncode([for (final id in order) byId[id]]);
  }

  static const _cloudAsrKinds = {
    'openai_realtime',
    'openAiRealtime',
    'dashscope',
    'dashScope',
    'volcengine',
    'mimo',
    'step',
  };

  /// Removes device-bound recognizers from the portable backup payload:
  /// sherpa models embed local paths and system recognizers are device
  /// bound, so only cloud services (and their credentials) are exported.
  static void _retainCloudAsrForExport(Map<String, Object?> data) {
    const asrServicesKey = 'asr_services_v1';
    const asrSelectedServiceKey = 'asr_selected_service_id_v1';
    if (!data.containsKey(asrServicesKey)) {
      data.remove(asrSelectedServiceKey);
      return;
    }
    final cloudServices = _decodeAsrServices(data[asrServicesKey])
        .where((service) => _cloudAsrKinds.contains(service['kind']))
        .toList(growable: false);
    data[asrServicesKey] = jsonEncode(cloudServices);
    final selectedId = data[asrSelectedServiceKey];
    if (selectedId is! String ||
        !cloudServices.any((service) => service['id'] == selectedId)) {
      data.remove(asrSelectedServiceKey);
    }
  }

  static List<Map<String, Object?>> _decodeAsrServices(Object? raw) {
    if (raw == null) return const <Map<String, Object?>>[];
    if (raw is! String) throw const FormatException('asr_services_v1');
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List || decoded.any((entry) => entry is! Map)) {
        throw const FormatException('asr_services_v1');
      }
      return [
        for (final entry in decoded)
          (entry as Map).map(
            (key, value) => MapEntry(key.toString(), value as Object?),
          ),
      ];
    } on FormatException {
      throw const FormatException('asr_services_v1');
    }
  }

  /// Applies the legacy `ocr_enabled_v1` mapping to an assistant map that
  /// predates per-assistant `ocrMode` (true -> 'auto', false -> 'never').
  /// Assistants that already carry an `ocrMode` field are left untouched.
  static Map<String, dynamic> _applyLegacyOcrModeToAssistantMap(
    Map<String, dynamic> map,
    Object? legacyOcrEnabled,
  ) {
    if (legacyOcrEnabled is bool && !map.containsKey('ocrMode')) {
      return {...map, 'ocrMode': legacyOcrEnabled ? 'auto' : 'never'};
    }
    return map;
  }

  /// Merges assistant maps by id. Incoming fields win today (except non-empty
  /// local avatar/background). `localWins` flips the per-field winner so the
  /// local copy survives the merge (issue #615); brand-new assistant ids still
  /// merge in wholesale.
  static List<Map<String, dynamic>> _mergeAssistantMaps(
    List<Map<String, dynamic>> existing,
    List<Map<String, dynamic>> incoming, {
    ConflictPrecedence precedence = ConflictPrecedence.auto,
  }) {
    final assistantMap = <String, Map<String, dynamic>>{};

    // Seed map with existing assistants
    for (final a in existing) {
      final id = a['id']?.toString();
      if (id != null && id.isNotEmpty) {
        assistantMap[id] = Map<String, dynamic>.from(a);
      }
    }

    final localWins = precedence == ConflictPrecedence.localWins;

    // Merge with incoming assistants
    for (final a in incoming) {
      final id = a['id']?.toString();
      if (id == null || id.isEmpty) continue;
      final inc = Map<String, dynamic>.from(a);

      if (!assistantMap.containsKey(id)) {
        assistantMap[id] = inc;
        continue;
      }

      final local = assistantMap[id]!;
      final merged = localWins
          ? <String, dynamic>{...inc, ...local}
          : <String, dynamic>{...local, ...inc};

      // Special rule: do not override existing non-empty avatar
      final localAvatar = (local['avatar'] ?? '').toString();
      final incomingAvatar = (inc['avatar'] ?? '');
      if (localAvatar.trim().isNotEmpty) {
        merged['avatar'] = localAvatar;
      } else {
        final s = incomingAvatar is String
            ? incomingAvatar
            : incomingAvatar?.toString();
        if (s == null || s.trim().isEmpty) {
          merged['avatar'] = null;
        } else {
          merged['avatar'] = s;
        }
      }

      // Special rule: do not override existing non-empty background
      final localBg = (local['background'] ?? '').toString();
      final incomingBg = (inc['background'] ?? '');
      if (localBg.trim().isNotEmpty) {
        merged['background'] = localBg;
      } else {
        final sb = incomingBg is String ? incomingBg : incomingBg?.toString();
        if (sb == null || sb.trim().isEmpty) {
          merged['background'] = null;
        } else {
          merged['background'] = sb;
        }
      }

      assistantMap[id] = merged;
    }

    return assistantMap.values.toList();
  }

  static String _mergeAssistantMemories(
    String existingRaw,
    String incomingRaw,
  ) {
    final existingList = jsonDecode(existingRaw) as List;
    final incomingList = jsonDecode(incomingRaw) as List;
    final merged = <Map<String, dynamic>>[];
    final contentKeys = <String>{};
    var maxId = 0;

    void addExisting(dynamic item) {
      if (item is! Map) return;
      final map = Map<String, dynamic>.from(item);
      final id = (map['id'] as num?)?.toInt() ?? 0;
      if (id > maxId) maxId = id;
      final key = _assistantMemoryContentKey(map);
      if (key != null) contentKeys.add(key);
      merged.add(map);
    }

    for (final item in existingList) {
      addExisting(item);
    }

    for (final item in incomingList) {
      if (item is! Map) continue;
      final incoming = Map<String, dynamic>.from(item);
      final key = _assistantMemoryContentKey(incoming);
      if (key != null && contentKeys.contains(key)) continue;

      final id = (incoming['id'] as num?)?.toInt() ?? 0;
      final idTaken = merged.any(
        (e) => ((e['id'] as num?)?.toInt() ?? 0) == id,
      );
      if (id <= 0 || idTaken) {
        maxId += 1;
        incoming['id'] = maxId;
      } else if (id > maxId) {
        maxId = id;
      }

      if (key != null) contentKeys.add(key);
      merged.add(incoming);
    }

    return jsonEncode(merged);
  }

  static String? _assistantMemoryContentKey(Map<String, dynamic> memory) {
    final assistantId = (memory['assistantId'] ?? '').toString().trim();
    final content = (memory['content'] ?? '').toString().trim();
    if (assistantId.isEmpty || content.isEmpty) return null;
    return '$assistantId\n$content';
  }
}

class _StreamingZipWriter {
  _StreamingZipWriter(String outPath) : _output = OutputFileStream(outPath);

  static const int _localFileHeaderSignature = 0x04034b50;
  static const int _centralDirectoryHeaderSignature = 0x02014b50;
  static const int _endOfCentralDirectorySignature = 0x06054b50;
  static const int _dataDescriptorSignature = 0x08074b50;
  static const int _versionNeeded = 20;
  static const int _utf8Flag = 1 << 11;
  static const int _dataDescriptorFlag = 1 << 3;
  static const int _deflateMethod = 8;
  static const int _maxZip32 = 0xffffffff;
  static const int _maxZipEntries = 0xffff;
  static const int _chunkSize = 1024 * 1024;

  final OutputFileStream _output;
  final List<_StreamingZipEntry> _entries = <_StreamingZipEntry>[];
  bool _closed = false;

  void addFile(File file, String entryName) {
    if (_closed) {
      throw StateError('Cannot add files after the ZIP writer is closed.');
    }
    if (entryName.isEmpty) return;

    final stat = file.statSync();
    final uncompressedSize = stat.size;
    _checkZip32(uncompressedSize, 'file size');
    _checkZip32(_output.length, 'local header offset');

    final modified = stat.modified;
    final modTime = _zipTime(modified);
    final modDate = _zipDate(modified);
    // UT (0x5455) extended timestamp: DOS time rounds down to even seconds,
    // which would bias the newer-wins merge comparison against odd-second
    // mtimes. The UT field carries the true Unix-second mtime.
    final utExtra = _utExtraField(modified);
    final nameBytes = utf8.encode(entryName);
    final localHeaderOffset = _output.length;

    _writeLocalHeader(
      nameBytes: nameBytes,
      modTime: modTime,
      modDate: modDate,
      utExtra: utExtra,
    );

    final written = _writeDeflatedFile(file);
    _checkZip32(written.compressedSize, 'compressed size');
    _checkZip32(written.uncompressedSize, 'uncompressed size');

    _writeDataDescriptor(written);

    _entries.add(
      _StreamingZipEntry(
        nameBytes: nameBytes,
        modTime: modTime,
        modDate: modDate,
        utExtra: utExtra,
        crc32: written.crc32,
        compressedSize: written.compressedSize,
        uncompressedSize: written.uncompressedSize,
        localHeaderOffset: localHeaderOffset,
        mode: stat.mode,
      ),
    );
  }

  /// Adds an in-memory byte payload (e.g. the LAN-sync `sync_manifest.json`)
  /// as a ZIP entry. [mtimeMs] defaults to now when null.
  void addBytes(Uint8List bytes, String entryName, {int? mtimeMs}) {
    if (_closed) {
      throw StateError('Cannot add files after the ZIP writer is closed.');
    }
    if (entryName.isEmpty) return;

    final modified = mtimeMs != null
        ? DateTime.fromMillisecondsSinceEpoch(mtimeMs)
        : DateTime.now();
    final modTime = _zipTime(modified);
    final modDate = _zipDate(modified);
    final utExtra = _utExtraField(modified);
    final nameBytes = utf8.encode(entryName);
    final localHeaderOffset = _output.length;

    _writeLocalHeader(
      nameBytes: nameBytes,
      modTime: modTime,
      modDate: modDate,
      utExtra: utExtra,
    );

    final written = _writeDeflatedBytes(bytes);
    _checkZip32(written.compressedSize, 'compressed size');
    _checkZip32(written.uncompressedSize, 'uncompressed size');

    _writeDataDescriptor(written);

    _entries.add(
      _StreamingZipEntry(
        nameBytes: nameBytes,
        modTime: modTime,
        modDate: modDate,
        utExtra: utExtra,
        crc32: written.crc32,
        compressedSize: written.compressedSize,
        uncompressedSize: written.uncompressedSize,
        localHeaderOffset: localHeaderOffset,
        mode: 0,
      ),
    );
  }

  void closeSync() {
    if (_closed) return;
    _checkEntryCount();

    final centralDirectoryOffset = _output.length;
    _checkZip32(centralDirectoryOffset, 'central directory offset');
    for (final entry in _entries) {
      _writeCentralDirectoryHeader(entry);
    }
    final centralDirectorySize = _output.length - centralDirectoryOffset;
    _checkZip32(centralDirectorySize, 'central directory size');

    _writeEndOfCentralDirectory(
      centralDirectoryOffset: centralDirectoryOffset,
      centralDirectorySize: centralDirectorySize,
    );
    _output.closeSync();
    _closed = true;
  }

  void closeIfNeededSync() {
    if (!_closed) {
      _output.closeSync();
      _closed = true;
    }
  }

  void _writeLocalHeader({
    required List<int> nameBytes,
    required int modTime,
    required int modDate,
    required List<int> utExtra,
  }) {
    _output.writeUint32(_localFileHeaderSignature);
    _output.writeUint16(_versionNeeded);
    _output.writeUint16(_utf8Flag | _dataDescriptorFlag);
    _output.writeUint16(_deflateMethod);
    _output.writeUint16(modTime);
    _output.writeUint16(modDate);
    _output.writeUint32(0);
    _output.writeUint32(0);
    _output.writeUint32(0);
    _output.writeUint16(nameBytes.length);
    _output.writeUint16(utExtra.length);
    _output.writeBytes(nameBytes);
    _output.writeBytes(utExtra);
  }

  _StreamingZipWrittenFile _writeDeflatedFile(File file) {
    final compressedSink = _CountingOutputSink(_output);
    final inputSink = ZLibCodec(
      level: ZLibOption.defaultLevel,
      raw: true,
    ).encoder.startChunkedConversion(compressedSink);

    final raf = file.openSync();
    final buffer = Uint8List(_chunkSize);
    var crc32 = 0;
    var uncompressedSize = 0;
    try {
      while (true) {
        final read = raf.readIntoSync(buffer);
        if (read == 0) break;
        final chunk = Uint8List.sublistView(buffer, 0, read);
        crc32 = getCrc32(chunk, crc32);
        uncompressedSize += read;
        inputSink.add(chunk);
      }
      inputSink.close();
    } finally {
      raf.closeSync();
    }

    return _StreamingZipWrittenFile(
      crc32: crc32,
      compressedSize: compressedSink.bytesWritten,
      uncompressedSize: uncompressedSize,
    );
  }

  _StreamingZipWrittenFile _writeDeflatedBytes(Uint8List bytes) {
    final compressedSink = _CountingOutputSink(_output);
    final inputSink = ZLibCodec(
      level: ZLibOption.defaultLevel,
      raw: true,
    ).encoder.startChunkedConversion(compressedSink);

    var crc32 = 0;
    for (var i = 0; i < bytes.length; i += _chunkSize) {
      final end = i + _chunkSize < bytes.length ? i + _chunkSize : bytes.length;
      final chunk = Uint8List.sublistView(bytes, i, end);
      crc32 = getCrc32(chunk, crc32);
      inputSink.add(chunk);
    }
    inputSink.close();

    return _StreamingZipWrittenFile(
      crc32: crc32,
      compressedSize: compressedSink.bytesWritten,
      uncompressedSize: bytes.length,
    );
  }

  void _writeDataDescriptor(_StreamingZipWrittenFile written) {
    _output.writeUint32(_dataDescriptorSignature);
    _output.writeUint32(written.crc32);
    _output.writeUint32(written.compressedSize);
    _output.writeUint32(written.uncompressedSize);
  }

  void _writeCentralDirectoryHeader(_StreamingZipEntry entry) {
    _output.writeUint32(_centralDirectoryHeaderSignature);
    _output.writeUint16(_versionNeeded);
    _output.writeUint16(_versionNeeded);
    _output.writeUint16(_utf8Flag | _dataDescriptorFlag);
    _output.writeUint16(_deflateMethod);
    _output.writeUint16(entry.modTime);
    _output.writeUint16(entry.modDate);
    _output.writeUint32(entry.crc32);
    _output.writeUint32(entry.compressedSize);
    _output.writeUint32(entry.uncompressedSize);
    _output.writeUint16(entry.nameBytes.length);
    _output.writeUint16(entry.utExtra.length); // extra field length
    _output.writeUint16(0); // comment length
    _output.writeUint16(0); // disk number start
    _output.writeUint16(0); // internal file attributes
    _output.writeUint32(entry.mode << 16); // external file attributes
    _output.writeUint32(entry.localHeaderOffset);
    _output.writeBytes(entry.nameBytes);
    _output.writeBytes(entry.utExtra);
  }

  void _writeEndOfCentralDirectory({
    required int centralDirectoryOffset,
    required int centralDirectorySize,
  }) {
    _output.writeUint32(_endOfCentralDirectorySignature);
    _output.writeUint16(0);
    _output.writeUint16(0);
    _output.writeUint16(_entries.length);
    _output.writeUint16(_entries.length);
    _output.writeUint32(centralDirectorySize);
    _output.writeUint32(centralDirectoryOffset);
    _output.writeUint16(0);
  }

  static int _zipTime(DateTime value) {
    return ((value.hour & 0x1f) << 11) |
        ((value.minute & 0x3f) << 5) |
        ((value.second ~/ 2) & 0x1f);
  }

  static int _zipDate(DateTime value) {
    final year = value.year < 1980 ? 1980 : value.year;
    return (((year - 1980) & 0x7f) << 9) |
        ((value.month & 0x0f) << 5) |
        (value.day & 0x1f);
  }

  /// Extended Timestamp extra field (0x5455): flags (mtime present) + the
  /// file's mtime in Unix seconds. Standard ZIP field — readers that do not
  /// understand it (Kelivo, archive_io, OS tools) ignore it and fall back to
  /// the DOS timestamp.
  static List<int> _utExtraField(DateTime modified) {
    final secs = modified.millisecondsSinceEpoch ~/ 1000;
    return <int>[
      0x55, 0x54, // id 0x5455 (little-endian)
      0x05, 0x00, // data size = 5
      0x01, // flags: mtime present
      secs & 0xff,
      (secs >> 8) & 0xff,
      (secs >> 16) & 0xff,
      (secs >> 24) & 0xff,
    ];
  }

  static void _checkZip32(int value, String field) {
    if (value > _maxZip32) {
      throw FileSystemException('ZIP entry exceeds ZIP32 limit: $field');
    }
  }

  void _checkEntryCount() {
    if (_entries.length > _maxZipEntries) {
      throw FileSystemException('ZIP entry count exceeds ZIP32 limit');
    }
  }
}

class _CountingOutputSink implements Sink<List<int>> {
  _CountingOutputSink(this._output);

  final OutputFileStream _output;
  int bytesWritten = 0;

  @override
  void add(List<int> data) {
    if (data.isEmpty) return;
    _output.writeBytes(data);
    bytesWritten += data.length;
  }

  @override
  void close() {}
}

class _StreamingZipEntry {
  const _StreamingZipEntry({
    required this.nameBytes,
    required this.modTime,
    required this.modDate,
    required this.utExtra,
    required this.crc32,
    required this.compressedSize,
    required this.uncompressedSize,
    required this.localHeaderOffset,
    required this.mode,
  });

  final List<int> nameBytes;
  final int modTime;
  final int modDate;

  /// UT (0x5455) extended-timestamp extra field bytes (empty for none).
  final List<int> utExtra;
  final int crc32;
  final int compressedSize;
  final int uncompressedSize;
  final int localHeaderOffset;
  final int mode;
}

class _StreamingZipWrittenFile {
  const _StreamingZipWrittenFile({
    required this.crc32,
    required this.compressedSize,
    required this.uncompressedSize,
  });

  final int crc32;
  final int compressedSize;
  final int uncompressedSize;
}

// ===== Business preferences snapshot/restore helpers =====

/// Async snapshot/restore over the business-preferences facade (issue #123).
///
/// Storage is the SQLite KV table behind [BusinessPreferences]; the legacy
/// `_localOnlyKeys` set is superseded by [BusinessKeyRegistry.localOnlyKeys]
/// (device-bound keys never enter the facade and therefore never appear in
/// backups). The interface is unchanged so restore-merge logic in this file
/// keeps operating on key↔value maps.
class SharedPreferencesAsync {
  SharedPreferencesAsync(this._preferences);

  final BusinessPreferences _preferences;

  /// All business keys currently in the facade cache.
  Future<Map<String, dynamic>> snapshot() async {
    final prefs = _preferences;
    return {
      for (final key in prefs.getKeys())
        if (prefs.containsKey(key)) key: prefs.get(key),
    };
  }

  /// Writes a single pref, normalizing int values for double-typed keys:
  /// kelivo-helper-migrated RikkaHub backups may carry them as int, and
  /// storing them as int makes `getDouble` reads throw. Device-bound keys
  /// (localOnly) are skipped — they never leave/enter a device via backup.
  Future<void> _writePref(
    BusinessPreferences prefs,
    String key,
    dynamic value,
  ) async {
    final disposition = BusinessKeyRegistry.classify(key);
    if (disposition == BusinessKeyDisposition.localOnly ||
        disposition == BusinessKeyDisposition.discarded ||
        disposition == BusinessKeyDisposition.entity) {
      return;
    }
    if (value is bool) {
      await prefs.setBool(key, value);
    } else if (value is int) {
      if (doublePrefKeys.contains(key)) {
        await prefs.setDouble(key, value.toDouble());
      } else {
        await prefs.setInt(key, value);
      }
    } else if (value is double) {
      await prefs.setDouble(key, value);
    } else if (value is String) {
      await prefs.setString(key, value);
    } else if (value is List) {
      await prefs.setStringList(key, value.whereType<String>().toList());
    }
  }

  Future<void> restore(Map<String, dynamic> data) async {
    final prefs = _preferences;
    for (final entry in data.entries) {
      await _writePref(prefs, entry.key, entry.value);
    }
  }

  Future<void> restoreSingle(String key, dynamic value) async {
    final prefs = _preferences;
    await _writePref(prefs, key, value);
  }
}
