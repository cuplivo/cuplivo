import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:uuid/uuid.dart';

import '../../../utils/app_directories.dart';

/// What a bin entry holds — and, with it, where its snapshot travels.
///
/// Small row sets (`businessEntity`, `preference`) keep their tables inside
/// `entry.json` itself, so a losing settings row or memory entry is exactly one
/// file. The two shapes that can be large travel beside it: a conversation
/// subtree as `body.json`, a workspace file's bytes as `body` (moved, never
/// re-encoded).
enum RecycleEntryType {
  conversation('conversation'),
  businessEntity('businessEntity'),
  preference('preference'),
  workspaceFile('workspaceFile');

  const RecycleEntryType(this.wire);

  final String wire;

  RecycleBodyKind get bodyKind => switch (this) {
    RecycleEntryType.conversation => RecycleBodyKind.jsonFile,
    RecycleEntryType.workspaceFile => RecycleBodyKind.byteFile,
    RecycleEntryType.businessEntity ||
    RecycleEntryType.preference => RecycleBodyKind.inline,
  };

  static RecycleEntryType? fromWire(Object? wire) {
    for (final type in values) {
      if (type.wire == wire) return type;
    }
    return null;
  }
}

/// Where an entry's snapshot actually lives on disk.
enum RecycleBodyKind {
  /// The tables are a field of `entry.json`.
  inline('inline'),

  /// The tables are `body.json` beside the entry.
  jsonFile('json'),

  /// The body is the moved file itself (`body`).
  byteFile('file');

  const RecycleBodyKind(this.wire);

  final String wire;

  static RecycleBodyKind? fromWire(Object? wire) {
    for (final kind in values) {
      if (kind.wire == wire) return kind;
    }
    return null;
  }
}

/// Who removed the thing a bin entry preserves.
enum RecycleOrigin {
  /// A delete this device performed (its own UI, or a cascade it ran).
  local('local'),

  /// A change that arrived over LAN sync.
  remote('remote');

  const RecycleOrigin(this.wire);

  final String wire;

  static RecycleOrigin? fromWire(Object? wire) {
    for (final origin in values) {
      if (origin.wire == wire) return origin;
    }
    return null;
  }
}

/// Why the thing is in the bin.
enum RecycleReason {
  /// It was deleted.
  deleted('deleted'),

  /// It was still present, but a last-write-wins comparison replaced its
  /// content with a peer's newer version.
  overwritten('overwritten');

  const RecycleReason(this.wire);

  final String wire;

  static RecycleReason? fromWire(Object? wire) {
    for (final reason in values) {
      if (reason.wire == wire) return reason;
    }
    return null;
  }
}

/// One staged item, as `entry.json` records it.
///
/// The snapshot's tables are deliberately absent: the bin list reads this
/// metadata only, so it never pays for a multi-megabyte conversation subtree.
class RecycleEntry {
  const RecycleEntry({
    required this.id,
    required this.type,
    required this.origin,
    required this.reason,
    required this.key,
    required this.title,
    required this.deletedAt,
    required this.sizeBytes,
    required this.bodyKind,
    this.kindWire,
    this.workspaceId,
    this.relPath,
    this.mtimeMs,
  });

  /// The entry directory's name, which is also its age sort key.
  final String id;
  final RecycleEntryType type;
  final RecycleOrigin origin;
  final RecycleReason reason;

  /// Identity inside [type]: a conversation id, entity id, preference key, or
  /// `workspaceId\u0000relPath`. Restoring one entry retires every entry that
  /// shares it, so a repeated delete cannot leave two live rows competing.
  final String key;
  final String title;
  final DateTime deletedAt;
  final int sizeBytes;
  final RecycleBodyKind bodyKind;

  /// The business entity's sync wire kind, when [type] is
  /// [RecycleEntryType.businessEntity].
  final String? kindWire;

  /// Workspace file entries only.
  final String? workspaceId;
  final String? relPath;
  final int? mtimeMs;

  static RecycleEntry? fromJson(Object? decoded, {required String id}) {
    if (decoded is! Map) return null;
    final type = RecycleEntryType.fromWire(decoded['type']);
    final origin = RecycleOrigin.fromWire(decoded['origin']);
    final reason = RecycleReason.fromWire(decoded['reason']);
    final key = decoded['key'];
    final title = decoded['title'];
    final deletedAtUs = decoded['deletedAtUs'];
    final sizeBytes = decoded['sizeBytes'];
    if (type == null ||
        origin == null ||
        reason == null ||
        key is! String ||
        key.isEmpty ||
        title is! String ||
        deletedAtUs is! int ||
        sizeBytes is! int) {
      return null;
    }
    return RecycleEntry(
      id: id,
      type: type,
      origin: origin,
      reason: reason,
      key: key,
      title: title,
      deletedAt: DateTime.fromMicrosecondsSinceEpoch(deletedAtUs, isUtc: true),
      sizeBytes: sizeBytes,
      bodyKind: RecycleBodyKind.fromWire(decoded['body']) ?? type.bodyKind,
      kindWire: decoded['kindWire'] is String
          ? decoded['kindWire'] as String
          : null,
      workspaceId: decoded['workspaceId'] is String
          ? decoded['workspaceId'] as String
          : null,
      relPath: decoded['relPath'] is String
          ? decoded['relPath'] as String
          : null,
      mtimeMs: decoded['mtimeMs'] is int ? decoded['mtimeMs'] as int : null,
    );
  }
}

/// The device-local recycle bin: `<appData>/recycle`.
///
/// It exists so two kinds of loss can be undone:
///
/// * a deletion — of a conversation, or of a user-managed row (an assistant,
///   a provider, a memory entry, a synced preference);
/// * a last-write-wins comparison whose local side lost the row.
///
/// Three properties are load-bearing and intentional:
///
/// * **No schema change.** Nothing here writes to `kelivo.db`, so the schema
///   version, the sync manifests, `BusinessSnapshot` and the backup archive are
///   all untouched. The bin is device-local by construction: no sync kind
///   enumerates it, no indexer walks it, and no backup entry names it — the
///   same standing as `<appData>/sync` (device identity and checkpoints).
/// * **Uncompressed and self-describing.** An entry is a directory holding an
///   `entry.json`; small row sets inline their tables there, and only the two
///   shapes that can be large get a separate body. A conversation subtree is
///   JSON, exactly the column maps the database stores; a workspace file is
///   moved, so the bytes and the mtime are preserved rather than re-encoded.
/// * **Best effort, never a veto.** Staging is called on the delete/apply path,
///   so it fails open: an unwritable bin logs and returns null, and the
///   deletion or the merge proceeds. The bin is a safety net, not a write
///   barrier.
class RecycleStore {
  RecycleStore({
    Future<Directory> Function()? directory,
    this.retention = defaultRetention,
    this.maxBytes = defaultMaxBytes,
    this.maxEntries = defaultMaxEntries,
  }) : _directory = directory ?? AppDirectories.getRecycleDirectory;

  /// How long an entry stays restorable. Matches the conversation tombstone
  /// retention: past it, a device that was offline long enough to still need
  /// this entry is better served by a backup.
  static const Duration defaultRetention = Duration(days: 90);

  /// Bytes of staged snapshots kept in total. Conversations dominate this.
  static const int defaultMaxBytes = 256 << 20;

  /// Entries kept in total. A sync session can lose a whole list of rows
  /// (memories, settings) at once, and this is what bounds the file count.
  static const int defaultMaxEntries = 1000;

  final Duration retention;
  final int maxBytes;
  final int maxEntries;

  static const String _entryFileName = 'entry.json';
  static const String _bodyFileName = 'body.json';
  static const String _fileBodyName = 'body';
  static const String _stagingPrefix = '.tmp-';
  static const int _titleMaxLength = 200;

  final Future<Directory> Function() _directory;

  /// Stages a row-shaped snapshot: a conversation subtree, one business entity
  /// row, or one synced preference row.
  ///
  /// Returns null when nothing was staged (an invalid key, or a filesystem that
  /// refused the write) — callers proceed with what they were doing either way.
  Future<RecycleEntry?> stageRows({
    required RecycleEntryType type,
    required RecycleOrigin origin,
    required RecycleReason reason,
    required String key,
    required String title,
    required Map<String, List<Map<String, Object?>>> tables,
    String? kindWire,
  }) async {
    if (type == RecycleEntryType.workspaceFile || key.isEmpty) return null;
    final deletedAt = DateTime.now().toUtc();
    final id = _entryId(deletedAt);
    final bodyKind = type.bodyKind;
    final String entryJson;
    final String? bodyJson;
    final int sizeBytes;
    try {
      bodyJson = bodyKind == RecycleBodyKind.jsonFile
          ? jsonEncode(<String, Object?>{'tables': tables})
          : null;
      var encoded = jsonEncode(
        _envelope(
          id: id,
          type: type,
          bodyKind: bodyKind,
          origin: origin,
          reason: reason,
          key: key,
          title: title,
          kindWire: kindWire,
          deletedAt: deletedAt,
          sizeBytes: 0,
          tables: bodyKind == RecycleBodyKind.inline ? tables : null,
        ),
      );
      sizeBytes =
          _byteLength(encoded) + (bodyJson == null ? 0 : _byteLength(bodyJson));
      // Re-encoded with the real size so the list can report disk usage without
      // reading any body.
      encoded = jsonEncode(
        _envelope(
          id: id,
          type: type,
          bodyKind: bodyKind,
          origin: origin,
          reason: reason,
          key: key,
          title: title,
          kindWire: kindWire,
          deletedAt: deletedAt,
          sizeBytes: sizeBytes,
          tables: bodyKind == RecycleBodyKind.inline ? tables : null,
        ),
      );
      entryJson = encoded;
    } catch (error) {
      // A value this bin cannot encode must not fail the delete that staged it.
      debugPrint('recycle: encoding a ${type.wire} entry failed: $error');
      return null;
    }

    final staged = await _stage(
      id: id,
      entryJson: entryJson,
      bodyJson: bodyJson,
      moveSource: null,
    );
    if (!staged) return null;
    await evict(keepId: id);
    return _entry(
      id: id,
      type: type,
      bodyKind: bodyKind,
      origin: origin,
      reason: reason,
      key: key,
      title: title,
      kindWire: kindWire,
      deletedAt: deletedAt,
      sizeBytes: sizeBytes,
    );
  }

  /// Moves [source] into the bin, preserving its bytes and its mtime.
  ///
  /// Used by the workspace-file side of sync, which owns both the four gates
  /// that keep a landed path inside its workspace root and the decision of
  /// whether a replacement may proceed: this returns null when the move failed,
  /// so the caller can fall back to its ordinary delete rather than assume the
  /// file is safe.
  Future<RecycleEntry?> stageFile({
    required String workspaceId,
    required String relPath,
    required File source,
    required RecycleOrigin origin,
    required RecycleReason reason,
    String? title,
  }) async {
    if (workspaceId.isEmpty || relPath.isEmpty) return null;
    final FileStat stat;
    try {
      stat = await source.stat();
    } catch (error) {
      debugPrint('recycle: cannot stat "${source.path}": $error');
      return null;
    }
    if (stat.type != FileSystemEntityType.file) return null;
    final deletedAt = DateTime.now().toUtc();
    final id = _entryId(deletedAt);
    final mtimeMs = stat.modified.millisecondsSinceEpoch;
    final key = '$workspaceId\u0000$relPath';
    final String entryJson;
    final int sizeBytes;
    try {
      var encoded = jsonEncode(
        _envelope(
          id: id,
          type: RecycleEntryType.workspaceFile,
          bodyKind: RecycleBodyKind.byteFile,
          origin: origin,
          reason: reason,
          key: key,
          title: title ?? relPath,
          kindWire: null,
          deletedAt: deletedAt,
          sizeBytes: stat.size,
          tables: null,
          workspaceId: workspaceId,
          relPath: relPath,
          mtimeMs: mtimeMs,
        ),
      );
      sizeBytes = _byteLength(encoded) + stat.size;
      encoded = jsonEncode(
        _envelope(
          id: id,
          type: RecycleEntryType.workspaceFile,
          bodyKind: RecycleBodyKind.byteFile,
          origin: origin,
          reason: reason,
          key: key,
          title: title ?? relPath,
          kindWire: null,
          deletedAt: deletedAt,
          sizeBytes: sizeBytes,
          tables: null,
          workspaceId: workspaceId,
          relPath: relPath,
          mtimeMs: mtimeMs,
        ),
      );
      entryJson = encoded;
    } catch (error) {
      debugPrint('recycle: encoding a workspace file entry failed: $error');
      return null;
    }
    final staged = await _stage(
      id: id,
      entryJson: entryJson,
      bodyJson: null,
      moveSource: source,
    );
    if (!staged) return null;
    await evict(keepId: id);
    return _entry(
      id: id,
      type: RecycleEntryType.workspaceFile,
      bodyKind: RecycleBodyKind.byteFile,
      origin: origin,
      reason: reason,
      key: key,
      title: title ?? relPath,
      kindWire: null,
      deletedAt: deletedAt,
      sizeBytes: sizeBytes,
      workspaceId: workspaceId,
      relPath: relPath,
      mtimeMs: mtimeMs,
    );
  }

  /// Every staged entry, newest first.
  ///
  /// Entries that share a [RecycleEntry.key] collapse to the newest one: a row
  /// deleted twice, or a merge that lost the same row in two sessions, must not
  /// appear as two recoverable items that would then fight over one row.
  /// Unreadable directories are left for [evict] to reclaim, so listing stays
  /// read-only.
  Future<List<RecycleEntry>> list() async {
    final scan = await _scan();
    final newest = <String, RecycleEntry>{};
    for (final entry in scan.entries) {
      final dedupeKey = '${entry.type.wire}\u0000${entry.key}';
      final existing = newest[dedupeKey];
      if (existing == null || entry.deletedAt.isAfter(existing.deletedAt)) {
        newest[dedupeKey] = entry;
      }
    }
    final entries = newest.values.toList()
      ..sort((a, b) => b.deletedAt.compareTo(a.deletedAt));
    return entries;
  }

  /// The staged tables of one entry, or null when its body is unreadable.
  Future<Map<String, List<Map<String, Object?>>>?> readTables(
    RecycleEntry entry,
  ) async {
    if (entry.bodyKind == RecycleBodyKind.byteFile) return null;
    final directory = await _entryDirectory(entry.id);
    final file = entry.bodyKind == RecycleBodyKind.jsonFile
        ? File(p.join(directory.path, _bodyFileName))
        : File(p.join(directory.path, _entryFileName));
    try {
      final decoded = jsonDecode(await file.readAsString());
      if (decoded is! Map) return null;
      final tables = decoded['tables'];
      if (tables is! Map) return null;
      return {
        for (final table in tables.entries)
          if (table.value is List)
            table.key.toString(): <Map<String, Object?>>[
              for (final row in table.value as List)
                if (row is Map)
                  row.map(
                    (key, value) => MapEntry(key.toString(), value as Object?),
                  ),
            ],
      };
    } catch (error) {
      debugPrint('recycle: reading entry ${entry.id} failed: $error');
      return null;
    }
  }

  /// The moved file of a [RecycleEntryType.workspaceFile] entry, or null when
  /// it is not there any more.
  Future<File?> bodyFile(RecycleEntry entry) async {
    if (entry.bodyKind != RecycleBodyKind.byteFile) return null;
    final directory = await _entryDirectory(entry.id);
    final file = File(p.join(directory.path, _fileBodyName));
    return await file.exists() ? file : null;
  }

  /// Removes one entry directory.
  Future<void> purge(RecycleEntry entry) async {
    final directory = await _entryDirectory(entry.id);
    await _deleteQuietly(directory);
  }

  /// Removes every entry that staged [key] — what a restore owes the bin, so a
  /// recovered row cannot also be restored again into a second copy.
  Future<int> purgeKey(RecycleEntryType type, String key) async {
    final scan = await _scan();
    var removed = 0;
    for (final entry in scan.entries) {
      if (entry.type != type || entry.key != key) continue;
      await purge(entry);
      removed++;
    }
    return removed;
  }

  /// Empties the bin.
  Future<void> clear() async {
    final root = await _directory();
    if (!await root.exists()) return;
    final scan = await _scan();
    for (final entry in scan.entries) {
      await purge(entry);
    }
    for (final orphan in scan.orphans) {
      await _deleteQuietly(Directory(p.join(root.path, orphan)));
    }
  }

  /// Drops expired entries and evicts oldest-first until both caps hold.
  ///
  /// [keepId] is never evicted: the entry just staged is the one the user's
  /// action produced, and a cap that instantly deleted it would make the
  /// newest deletion the one thing the bin cannot show. It still counts toward
  /// the caps, so a bin that is over budget by exactly one oversized entry does
  /// not thrash.
  Future<int> evict({String? keepId, DateTime? now}) async {
    final root = await _directory();
    if (!await root.exists()) return 0;
    final scan = await _scan();
    var removed = 0;
    for (final orphan in scan.orphans) {
      await _deleteQuietly(Directory(p.join(root.path, orphan)));
      removed++;
    }
    final cutoff = (now ?? DateTime.now().toUtc()).subtract(retention);
    final ordered = scan.entries.toList()
      ..sort((a, b) => a.deletedAt.compareTo(b.deletedAt));
    var bytes = ordered.fold<int>(0, (sum, entry) => sum + entry.sizeBytes);
    var count = ordered.length;
    for (final entry in ordered) {
      final expired = entry.deletedAt.isBefore(cutoff);
      final overBudget = bytes > maxBytes || count > maxEntries;
      if (!expired && !overBudget) continue;
      if (entry.id == keepId) continue;
      await purge(entry);
      bytes -= entry.sizeBytes;
      count--;
      removed++;
    }
    return removed;
  }

  /// Bytes the bin currently holds, as the entries report themselves.
  Future<int> totalBytes() async {
    final scan = await _scan();
    return scan.entries.fold<int>(0, (sum, entry) => sum + entry.sizeBytes);
  }

  static String _entryId(DateTime deletedAt) =>
      '${deletedAt.microsecondsSinceEpoch}-${const Uuid().v4().substring(0, 8)}';

  static int _byteLength(String value) => utf8.encode(value).length;

  static Map<String, Object?> _envelope({
    required String id,
    required RecycleEntryType type,
    required RecycleBodyKind bodyKind,
    required RecycleOrigin origin,
    required RecycleReason reason,
    required String key,
    required String title,
    required String? kindWire,
    required DateTime deletedAt,
    required int sizeBytes,
    required Map<String, List<Map<String, Object?>>>? tables,
    String? workspaceId,
    String? relPath,
    int? mtimeMs,
  }) => <String, Object?>{
    'v': 1,
    'type': type.wire,
    'body': bodyKind.wire,
    'origin': origin.wire,
    'reason': reason.wire,
    'key': key,
    'title': title.length > _titleMaxLength
        ? title.substring(0, _titleMaxLength)
        : title,
    if (kindWire != null) 'kindWire': kindWire,
    'deletedAtUs': deletedAt.microsecondsSinceEpoch,
    'sizeBytes': sizeBytes,
    if (workspaceId != null) 'workspaceId': workspaceId,
    if (relPath != null) 'relPath': relPath,
    if (mtimeMs != null) 'mtimeMs': mtimeMs,
    if (tables != null) 'tables': tables,
  };

  static RecycleEntry _entry({
    required String id,
    required RecycleEntryType type,
    required RecycleBodyKind bodyKind,
    required RecycleOrigin origin,
    required RecycleReason reason,
    required String key,
    required String title,
    required String? kindWire,
    required DateTime deletedAt,
    required int sizeBytes,
    String? workspaceId,
    String? relPath,
    int? mtimeMs,
  }) => RecycleEntry(
    id: id,
    type: type,
    origin: origin,
    reason: reason,
    key: key,
    title: title,
    deletedAt: deletedAt,
    sizeBytes: sizeBytes,
    bodyKind: bodyKind,
    kindWire: kindWire,
    workspaceId: workspaceId,
    relPath: relPath,
    mtimeMs: mtimeMs,
  );

  /// Writes one entry directory atomically: the whole entry is built under a
  /// `.tmp-` name and renamed into place, so a reader never sees a half-written
  /// entry and a crash leaves only an orphan the next [evict] reclaims.
  Future<bool> _stage({
    required String id,
    required String entryJson,
    required String? bodyJson,
    required File? moveSource,
  }) async {
    final root = await _directory();
    final staging = Directory(p.join(root.path, '$_stagingPrefix$id'));
    try {
      await root.create(recursive: true);
      await staging.create();
      await File(
        p.join(staging.path, _entryFileName),
      ).writeAsString(entryJson, flush: true);
      if (bodyJson != null) {
        await File(
          p.join(staging.path, _bodyFileName),
        ).writeAsString(bodyJson, flush: true);
      }
      if (moveSource != null) {
        await _moveInto(moveSource, p.join(staging.path, _fileBodyName));
      }
      await staging.rename(p.join(root.path, id));
      return true;
    } catch (error) {
      debugPrint('recycle: staging $id failed: $error');
      await _deleteQuietly(staging);
      return false;
    }
  }

  /// Moves [source] into the bin, falling back to copy-then-delete when the two
  /// paths are on different volumes (a rename cannot cross one).
  ///
  /// A failed copy leaves the source untouched and the staging directory is
  /// discarded, so the caller's file is never lost by trying to preserve it.
  static Future<void> _moveInto(File source, String target) async {
    try {
      await source.rename(target);
      return;
    } on FileSystemException {
      // Different volume, or a platform that refuses the rename: copy instead.
    }
    await source.copy(target);
    await source.delete();
  }

  Future<Directory> _entryDirectory(String id) async {
    final root = await _directory();
    return Directory(p.join(root.path, id));
  }

  /// Every readable entry plus the directory names that are not one.
  ///
  /// Orphans are the `.tmp-` directories a crash left behind and directories
  /// whose `entry.json` is absent or no longer parses. Neither can be restored,
  /// so only [evict] removes them.
  ///
  /// A directory that exists but could not be *read* right now — a sharing
  /// violation, a file another process is holding — is deliberately neither: a
  /// failed read is not a verdict that the entry is unusable, and reaping it
  /// here would turn a transient lock into a permanent loss of the one copy the
  /// bin holds. It stays, and the next pass reads it.
  Future<({List<RecycleEntry> entries, List<String> orphans})> _scan() async {
    final root = await _directory();
    if (!await root.exists()) {
      return (entries: const <RecycleEntry>[], orphans: const <String>[]);
    }
    final entries = <RecycleEntry>[];
    final orphans = <String>[];
    await for (final entity in root.list(followLinks: false)) {
      if (entity is! Directory) continue;
      final name = p.basename(entity.path);
      if (name.startsWith(_stagingPrefix)) {
        orphans.add(name);
        continue;
      }
      final file = File(p.join(entity.path, _entryFileName));
      final String raw;
      try {
        raw = await file.readAsString();
      } on PathNotFoundException {
        // Nothing readable there at all: the entry cannot be one.
        orphans.add(name);
        continue;
      } on FileSystemException catch (error) {
        debugPrint('recycle: entry $name could not be read: $error');
        continue;
      }
      final entry = RecycleEntry.fromJson(_tryDecode(raw), id: name);
      if (entry == null) {
        // Readable bytes that do not describe an entry: damaged, not locked.
        debugPrint('recycle: entry $name is damaged and will be reclaimed');
        orphans.add(name);
        continue;
      }
      entries.add(entry);
    }
    return (entries: entries, orphans: orphans);
  }

  static Object? _tryDecode(String raw) {
    try {
      return jsonDecode(raw);
    } catch (_) {
      return null;
    }
  }

  static Future<void> _deleteQuietly(FileSystemEntity entity) async {
    try {
      if (await entity.exists()) await entity.delete(recursive: true);
    } catch (error) {
      debugPrint('recycle: deleting ${entity.path} failed: $error');
    }
  }
}
