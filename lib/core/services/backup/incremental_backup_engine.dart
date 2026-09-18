import 'dart:convert';
import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import '../../models/conversation.dart';
import '../../models/incremental_backup.dart';
import '../chat/chat_service.dart';
import '../sync/lan_sync_models.dart';
import 'data_sync.dart';

/// Builds and applies incremental backup ZIPs on the working-tree stack.
///
/// Fork lineage context: the fork's incremental engine lived inside its
/// JSONL-based `DataSync`. The working tree's primary backup is a whole-database
/// drift snapshot, so the incremental layer rides the legacy mergeable
/// `chats.json` format instead (the same shape the first-run v3 migration and
/// old-Kelivo restores already parse): conversations updated-or-created after
/// `since` with only the messages appended after the fork point, plus optional
/// settings and asset files filtered by mtime or an explicit path set (LAN
/// delta). Applying merges per conversation — new conversations insert, changed
/// conversations update their metadata and append missing messages in order —
/// which is exactly what `RestoreMode.merge` means for chat content here.
class IncrementalBackupEngine {
  IncrementalBackupEngine({required this.chatService, required this.dataSync});

  final ChatService chatService;
  final DataSync dataSync;

  static const String manifestEntryName = 'incremental.json';
  static const String chatsEntryName = 'chats.json';
  static const String settingsEntryName = 'settings.json';

  /// Builds the incremental chats payload: conversations whose [Conversation.updatedAt]
  /// is at/after `since` (or that appear in [config.conversationSince]), each
  /// carrying only messages created at/after that conversation's own cut-off.
  Future<Map<String, dynamic>> buildIncrementalChatsPayload(
    IncrementalBackupConfig config,
  ) async {
    final conversations = <Map<String, dynamic>>[];
    final messages = <Map<String, dynamic>>[];
    final metadataOnly = config.metadataOnlyConversationIds ?? const <String>{};

    for (final conversation in chatService.getAllConversations()) {
      final since = _sinceFor(conversation, config);
      if (since == null) continue;
      if (!config.sinceCheck(conversation.updatedAt) &&
          !config.sinceCheck(conversation.createdAt)) {
        // Neither touched nor created inside the window.
        continue;
      }
      conversations.add(conversation.toJson());
      if (metadataOnly.contains(conversation.id)) continue;

      final conversationMessages = await chatService.loadMessages(
        conversation.id,
      );
      for (final message in conversationMessages) {
        if (!config.sinceCheck(message.timestamp)) continue;
        messages.add(message.toJson());
      }
    }

    return {'version': 1, 'conversations': conversations, 'messages': messages};
  }

  DateTime? _sinceFor(Conversation conversation, IncrementalBackupConfig cfg) {
    final perConversation = cfg.conversationSince;
    if (perConversation != null) {
      if (!perConversation.containsKey(conversation.id)) return null;
      return perConversation[conversation.id] ?? conversation.createdAt;
    }
    final updatedAtWindow = configUpdatedAtWindow(cfg);
    return updatedAtWindow;
  }

  DateTime? configUpdatedAtWindow(IncrementalBackupConfig cfg) => cfg.since;

  /// Exports the incremental ZIP to a temp file. Caller owns the file.
  Future<File> exportToFile({
    required IncrementalBackupConfig config,
    Map<String, dynamic>? settingsJson,
  }) async {
    final chats = await buildIncrementalChatsPayload(config);
    final archive = Archive();

    archive.addFile(
      ArchiveFile.string(
        manifestEntryName,
        jsonEncode({
          'format': 'cuplivo-incremental-v1',
          'since': config.since.toIso8601String(),
          'scope': config.effectiveScope.toJson(),
          'exportedAt': DateTime.now().toIso8601String(),
        }),
      ),
    );
    archive.addFile(ArchiveFile.string(chatsEntryName, jsonEncode(chats)));
    if (settingsJson != null && config.effectiveScope.settings) {
      archive.addFile(
        ArchiveFile.string(settingsEntryName, jsonEncode(settingsJson)),
      );
    }

    final fileSet = config.includeFilePaths;
    await for (final entry in _assetFiles()) {
      final included = fileSet != null
          ? fileSet.contains(entry.zipPath)
          : config.sinceCheck(entry.mtime);
      if (!included) continue;
      final bytes = await entry.file.readAsBytes();
      archive.addFile(
        ArchiveFile(entry.zipPath, bytes.length, bytes)
          ..lastModTime = entry.mtime.millisecondsSinceEpoch ~/ 1000,
      );
    }

    final tmp = await Directory.systemTemp.createTemp('cuplivo_incr_');
    final outFile = File(
      p.join(
        tmp.path,
        '${_incrementalBaseName(DateTime.now(), config.since)}.zip',
      ),
    );
    final output = OutputFileStream(outFile.path);
    try {
      ZipEncoder().encode(archive, output: output);
    } finally {
      await output.close();
    }
    return outFile;
  }

  /// All packable asset files as (zipPath, mtime) entries.
  Stream<({File file, String zipPath, DateTime mtime})> _assetFiles() async* {
    final roots = await dataSync.assetRootPaths();
    for (final root in roots.entries) {
      final dir = Directory(root.value);
      if (!await dir.exists()) continue;
      await for (final entity in dir.list(
        recursive: true,
        followLinks: false,
      )) {
        if (entity is! File) continue;
        final rel = p.relative(entity.path, from: root.value);
        if (rel.split(p.separator).any((s) => s.startsWith('.'))) continue;
        final stat = await entity.stat();
        if (stat.type != FileSystemEntityType.file) continue;
        yield (file: entity, zipPath: '${root.key}/$rel', mtime: stat.modified);
      }
    }
  }

  /// File manifest of all asset roots (LAN sync exchange).
  Future<Map<String, FileManifestEntry>> buildFileManifest() async {
    final result = <String, FileManifestEntry>{};
    await for (final entry in _assetFiles()) {
      final stat = await entry.file.stat();
      result[entry.zipPath] = FileManifestEntry(
        size: stat.size,
        mtimeMs: stat.modified.millisecondsSinceEpoch,
      );
    }
    return result;
  }

  /// Stats of files changed at/after [since] (UI estimate).
  Future<({int fileCount, int totalBytes})> countFilesForSince(
    DateTime since,
  ) async {
    var count = 0;
    var bytes = 0;
    await for (final entry in _assetFiles()) {
      if (entry.mtime.isBefore(since)) continue;
      final stat = await entry.file.stat();
      count++;
      bytes += stat.size;
    }
    return (fileCount: count, totalBytes: bytes);
  }

  /// Parses an incremental ZIP: returns the chats payload and settings JSON.
  Future<({Map<String, dynamic> chats, Map<String, dynamic>? settings})>
  readIncrementalZip(File file) async {
    final archive = ZipDecoder().decodeBytes(await file.readAsBytes());
    Map<String, dynamic>? chats;
    Map<String, dynamic>? settings;
    for (final entry in archive) {
      if (entry.isFile) {
        final content = utf8.decode(entry.content as List<int>);
        if (entry.name == chatsEntryName) {
          chats = jsonDecode(content) as Map<String, dynamic>;
        } else if (entry.name == settingsEntryName) {
          settings = jsonDecode(content) as Map<String, dynamic>;
        }
      }
    }
    if (chats == null) {
      throw const FormatException('incremental zip: chats.json missing');
    }
    return (chats: chats, settings: settings);
  }

  /// Extracts an incremental ZIP's asset entries under [targetDir].
  Future<void> extractAssetFiles(File file, Directory targetDir) async {
    final archive = ZipDecoder().decodeBytes(await file.readAsBytes());
    final excluded = {manifestEntryName, chatsEntryName, settingsEntryName};
    for (final entry in archive) {
      if (!entry.isFile || excluded.contains(entry.name)) continue;
      final dest = File(p.join(targetDir.path, entry.name));
      await dest.parent.create(recursive: true);
      await dest.writeAsBytes(entry.content as List<int>, flush: true);
      if (entry.lastModTime > 0) {
        final mtime = DateTime.fromMillisecondsSinceEpoch(
          entry.lastModTime * 1000,
        );
        try {
          await dest.setLastModified(mtime);
        } catch (e) {
          debugPrint(
            'incremental restore: mtime set failed for '
            '${entry.name}: $e',
          );
        }
      }
    }
  }

  /// Merge-format base name: `cuplivo_incr_<export_ts>_<since_ts>` (fork
  /// contract, so the website helper and old peers recognize the file).
  static String incrementalBaseName(DateTime now, DateTime since) =>
      _incrementalBaseName(now, since);
}

String _incrementalBaseName(DateTime now, DateTime since) {
  String d(int n, int width) => n.toString().padLeft(width, '0');
  final e =
      '${d(now.year, 4)}${d(now.month, 2)}${d(now.day, 2)}'
      '-${d(now.hour, 2)}${d(now.minute, 2)}${d(now.second, 2)}'
      '-${d(now.microsecond, 6)}';
  final s =
      '${d(since.year, 4)}${d(since.month, 2)}${d(since.day, 2)}'
      '-${d(since.hour, 2)}${d(since.minute, 2)}${d(since.second, 2)}';
  return 'cuplivo_incr_${e}_$s';
}
