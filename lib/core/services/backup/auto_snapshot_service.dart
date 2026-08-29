import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';

import '../../../utils/app_directories.dart';

/// Metadata describing one stored auto snapshot. Persisted as a JSON sidecar
/// (`<zipName>.json`) next to the snapshot zip so the list view can render
/// counts and sizes without opening the zip.
class SnapshotMetadata {
  const SnapshotMetadata({
    required this.fileName,
    required this.createdAt,
    required this.sizeBytes,
    required this.assistantCount,
    required this.conversationCount,
    required this.messageCount,
    required this.contentHash,
  });

  final String fileName;
  final DateTime createdAt;
  final int sizeBytes;
  final int assistantCount;
  final int conversationCount;
  final int messageCount;

  /// Deterministic digest of the backup payload (entry name + uncompressed
  /// size + CRC32 per zip entry). Zip headers carry volatile mtimes, so a
  /// whole-file hash can never be stable; this digest is.
  final String contentHash;

  Map<String, dynamic> toJson() => {
    'file_name': fileName,
    'created_at': createdAt.toIso8601String(),
    'size_bytes': sizeBytes,
    'assistant_count': assistantCount,
    'conversation_count': conversationCount,
    'message_count': messageCount,
    'content_hash': contentHash,
  };

  static SnapshotMetadata fromJson(Map<String, dynamic> json) =>
      SnapshotMetadata(
        fileName: json['file_name'] as String,
        createdAt: DateTime.parse(json['created_at'] as String),
        sizeBytes: json['size_bytes'] as int? ?? 0,
        assistantCount: json['assistant_count'] as int? ?? 0,
        conversationCount: json['conversation_count'] as int? ?? 0,
        messageCount: json['message_count'] as int? ?? 0,
        contentHash: json['content_hash'] as String? ?? '',
      );

  SnapshotMetadata copyWith({DateTime? createdAt}) => SnapshotMetadata(
    fileName: fileName,
    createdAt: createdAt ?? this.createdAt,
    sizeBytes: sizeBytes,
    assistantCount: assistantCount,
    conversationCount: conversationCount,
    messageCount: messageCount,
    contentHash: contentHash,
  );
}

/// Result of one [AutoSnapshotService.createSnapshot] attempt.
enum AutoSnapshotStatus { created, deduplicated }

class AutoSnapshotResult {
  const AutoSnapshotResult(this.status, this.metadata);

  final AutoSnapshotStatus status;
  final SnapshotMetadata? metadata;
}

/// One parsed zip central-directory entry: the stable, payload-derived facts
/// used for sentinel checks and content hashing.
class _ZipEntryInfo {
  const _ZipEntryInfo(this.name, this.uncompressedSize, this.crc32);

  final String name;
  final int uncompressedSize;
  final int crc32;
}

/// Result of a failed snapshot attempt: the local snapshot store must remain
/// completely untouched (atomic "as if it never happened" semantics).
class AutoSnapshotException implements Exception {
  AutoSnapshotException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// Creates and manages local auto snapshots: full backups, same payload as
/// the manual "Export to File" flow, capped at [maxSnapshots] with FIFO
/// eviction.
///
/// Atomicity contract: a snapshot only becomes visible after its zip has been
/// fully written elsewhere and moved into place; the sidecar is written after
/// the move, and eviction runs last. Any failure before those steps deletes
/// the temporary file and leaves the existing snapshots untouched.
class AutoSnapshotService {
  AutoSnapshotService({
    required Future<File> Function() exportBackup,
    required int Function() assistantCount,
    required int Function() conversationCount,
    required int Function() messageCount,
    Future<Directory> Function()? rootDirectoryResolver,
    this.maxSnapshots = 3,
  }) : _exportBackup = exportBackup,
       _assistantCount = assistantCount,
       _conversationCount = conversationCount,
       _messageCount = messageCount,
       _rootDirectoryResolver =
           rootDirectoryResolver ?? AppDirectories.getAppDataDirectory;

  static const String _zipPrefix = 'auto_snapshot_';
  static const String _sentinelEntryName = 'chats_meta.json';
  static const String _dirName = 'auto_snapshots';

  /// Resolves the stored zip for [fileName] (e.g. when restoring).
  static Future<File> resolveSnapshotFile(String fileName) async {
    final root = await AppDirectories.getAppDataDirectory();
    return File('${root.path}/$_dirName/$fileName');
  }

  final Future<File> Function() _exportBackup;
  final int Function() _assistantCount;
  final int Function() _conversationCount;
  final int Function() _messageCount;
  final Future<Directory> Function() _rootDirectoryResolver;
  final int maxSnapshots;

  Future<Directory> snapshotDirectory() async {
    final root = await _rootDirectoryResolver();
    return Directory('${root.path}/$_dirName');
  }

  /// Lists all snapshots, newest first.
  Future<List<SnapshotMetadata>> listSnapshots() async {
    final dir = await snapshotDirectory();
    if (!dir.existsSync()) return const [];
    final result = <SnapshotMetadata>[];
    for (final ent in dir.listSync()) {
      if (ent is! File || !ent.path.endsWith('.json')) continue;
      try {
        final json =
            jsonDecode(ent.readAsStringSync()) as Map<String, dynamic>;
        result.add(SnapshotMetadata.fromJson(json));
      } catch (_) {
        // Corrupt sidecar: fall back to what the filesystem itself tells us
        // so the user still sees the snapshot instead of it vanishing.
        final zip = File(ent.path.substring(0, ent.path.length - 5));
        if (!zip.existsSync()) continue;
        result.add(_fallbackMetadata(zip));
      }
    }
    // Orphan zips (sidecar write interrupted): derive metadata on the fly.
    final known = result.map((m) => m.fileName).toSet();
    for (final ent in dir.listSync()) {
      if (ent is! File || !ent.path.endsWith('.zip')) continue;
      final name = ent.uri.pathSegments.last;
      if (known.contains(name)) continue;
      result.add(_fallbackMetadata(ent));
    }
    result.sort((a, b) => b.createdAt.compareTo(a.createdAt));
    return result;
  }

  SnapshotMetadata _fallbackMetadata(File zip) {
    final stat = zip.statSync();
    final entries = _readZipEntries(zip.path);
    return SnapshotMetadata(
      fileName: zip.uri.pathSegments.last,
      createdAt: stat.modified,
      sizeBytes: stat.size,
      assistantCount: 0,
      conversationCount: 0,
      messageCount: 0,
      contentHash: _hashEntries(entries),
    );
  }

  /// Runs one snapshot attempt end to end.
  ///
  /// Returns [AutoSnapshotStatus.deduplicated] when the payload is identical
  /// to the newest existing snapshot; in that case nothing is written and the
  /// caller should treat the attempt as successful for anchor-reset purposes.
  Future<AutoSnapshotResult> createSnapshot() async {
    final dir = await snapshotDirectory();
    dir.createSync(recursive: true);

    final existing = await listSnapshots();
    final newestHash = existing.isEmpty ? null : existing.first.contentHash;

    final File tempBackup;
    try {
      tempBackup = await _exportBackup();
    } catch (e) {
      throw AutoSnapshotException(e.toString());
    }

    try {
      if (!tempBackup.existsSync()) {
        throw AutoSnapshotException('Backup export produced no file');
      }
      final entries = _readZipEntries(tempBackup.path);
      final names = entries.map((e) => e.name).toSet();
      if (!names.contains(_sentinelEntryName)) {
        // Sentinel is packed last — its absence means the zip is truncated.
        throw AutoSnapshotException('Backup zip is incomplete (no sentinel)');
      }
      final hash = _hashEntries(entries);

      if (newestHash != null && newestHash == hash) {
        // Payload identical to the newest snapshot — skip creation entirely.
        return const AutoSnapshotResult(
          AutoSnapshotStatus.deduplicated,
          null,
        );
      }

      final now = DateTime.now();
      final baseName = '$_zipPrefix${_fileTimestamp(now)}';
      var fileName = '$baseName.zip';
      // Second-precision timestamps can collide on rapid consecutive
      // snapshots — uniquify instead of silently overwriting.
      var counter = 1;
      while (File('${dir.path}/$fileName').existsSync()) {
        counter++;
        fileName = '${baseName}_$counter.zip';
      }
      final target = File('${dir.path}/$fileName');

      // Same-volume atomic move; fall back to copy+delete across volumes.
      try {
        tempBackup.renameSync(target.path);
      } catch (_) {
        tempBackup.copySync(target.path);
        tempBackup.deleteSync();
      }
      if (!target.existsSync()) {
        throw AutoSnapshotException('Snapshot move failed');
      }

      final meta = SnapshotMetadata(
        fileName: fileName,
        createdAt: now,
        sizeBytes: target.lengthSync(),
        assistantCount: _assistantCount(),
        conversationCount: _conversationCount(),
        messageCount: _messageCount(),
        contentHash: hash,
      );
      File('${dir.path}/$fileName.json').writeAsStringSync(
        jsonEncode(meta.toJson()),
      );

      await _evict(dir);
      return AutoSnapshotResult(AutoSnapshotStatus.created, meta);
    } finally {
      // The temp file only still exists on failure paths — clean it up.
      if (tempBackup.existsSync()) {
        try {
          tempBackup.deleteSync();
        } catch (_) {}
      }
    }
  }

  /// FIFO eviction: delete oldest beyond [maxSnapshots]. Runs after the new
  /// snapshot is durable, so a failure here can at worst leave one extra
  /// snapshot (self-heals on the next cycle) — never data loss.
  Future<void> _evict(Directory dir) async {
    final current = await listSnapshots();
    if (current.length <= maxSnapshots) return;
    for (final meta in current.skip(maxSnapshots)) {
      try {
        final zip = File('${dir.path}/${meta.fileName}');
        if (zip.existsSync()) zip.deleteSync();
        final sidecar = File('${dir.path}/${meta.fileName}.json');
        if (sidecar.existsSync()) sidecar.deleteSync();
      } catch (_) {}
    }
  }

  /// Hashes the payload identity of a backup zip: sorted
  /// `name:size:crc32` lines fed to SHA-256. Independent of zip header
  /// mtimes and compression metadata.
  String _hashEntries(List<_ZipEntryInfo> entries) {
    final lines = entries
        .map((e) => '${e.name}:${e.uncompressedSize}:${e.crc32}')
        .toList()
      ..sort();
    return sha256.convert(utf8.encode(lines.join('\n'))).toString();
  }

  /// Parses the zip central directory (header metadata only — no payload
  /// decompression, cheap even for large backups). Returns entries in file
  /// order.
  static List<_ZipEntryInfo> _readZipEntries(String zipPath) {
    final raf = File(zipPath).openSync();
    try {
      final length = raf.lengthSync();
      if (length < 22) return const [];
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
      if (eocdPos < 0) return const [];
      final view = ByteData.sublistView(tail);
      final cdSize = view.getUint32(eocdPos + 12, Endian.little);
      final cdOffset = view.getUint32(eocdPos + 16, Endian.little);
      if (cdOffset + cdSize > length) return const [];

      raf.setPositionSync(cdOffset);
      final cd = raf.readSync(cdSize);
      final cdView = ByteData.sublistView(cd);
      final result = <_ZipEntryInfo>[];
      var pos = 0;
      while (pos + 46 <= cd.length) {
        // Central directory header signature (0x02014b50).
        if (cdView.getUint32(pos, Endian.little) != 0x02014b50) break;
        final nameLen = cdView.getUint16(pos + 28, Endian.little);
        final extraLen = cdView.getUint16(pos + 30, Endian.little);
        final commentLen = cdView.getUint16(pos + 32, Endian.little);
        final crc32 = cdView.getUint32(pos + 16, Endian.little);
        final uncompressedSize = cdView.getUint32(pos + 24, Endian.little);
        final nameStart = pos + 46;
        final next = nameStart + nameLen + extraLen + commentLen;
        if (next > cd.length) break;
        final name = _decodeZipName(cd.sublist(nameStart, nameStart + nameLen));
        if (name != null) {
          result.add(_ZipEntryInfo(name, uncompressedSize, crc32));
        }
        pos = next;
      }
      return result;
    } finally {
      raf.closeSync();
    }
  }

  static String? _decodeZipName(List<int> bytes) {
    if (bytes.isEmpty) return null;
    try {
      return utf8.decode(bytes);
    } catch (_) {
      return String.fromCharCodes(bytes);
    }
  }

  /// Compact sortable timestamp for snapshot file names:
  /// `20260829T153004` (local time; uniqueness comes from second precision
  /// plus caller-side single-flight, collisions fall through to dedup).
  static String _fileTimestamp(DateTime dt) {
    final m = dt.month.toString().padLeft(2, '0');
    final d = dt.day.toString().padLeft(2, '0');
    final h = dt.hour.toString().padLeft(2, '0');
    final min = dt.minute.toString().padLeft(2, '0');
    final s = dt.second.toString().padLeft(2, '0');
    return '${dt.year}$m${d}T$h$min$s';
  }
}
