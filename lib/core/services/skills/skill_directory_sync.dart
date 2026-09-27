import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:crypto/crypto.dart' as crypto;
import 'package:path/path.dart' as p;

import 'skill_archive.dart';

/// Skill-directory carriage for LAN sync (ADR-0003 slice 3): a skill travels
/// as its entity record plus its on-disk directory as one zip blob keyed by a
/// directory hash — sha256 over the sorted `relpath\0fileDigest` lines. The
/// record's `updated_at` does not track content edits, so the hash is the
/// only content clock.
///
/// Apply is staging + atomic directory swap, re-hashed on receipt before the
/// swap; extraction reuses the `skill_archive` hardened unpacker, so zip-slip
/// and size caps are enforced by the same code the import flow trusts.
class SkillDirectorySync {
  SkillDirectorySync(this.root);

  /// The skills root (`<appData>/skills`).
  final Directory root;

  /// Per-launch memo: a fingerprint (file count, total size, max mtime) that
  /// has not changed cannot have changed content, so the hash is reused.
  /// Fingerprints are recomputed on every call; hashing is the expensive half.
  final Map<String, _SkillHashMemo> _memos = {};

  Future<void> ensureRoot() async {
    if (!await root.exists()) {
      await root.create(recursive: true);
    }
  }

  /// The directory of [skillId], or null when the id is not contained in the
  /// skills root. Skill ids arrive from the wire (a peer's manifest names
  /// them), so every path this class builds from one goes through here: a
  /// crafted id (`../victim`, an absolute path) is refused before any stat,
  /// create, rename or delete can leave the root — the same rule
  /// [deleteDirectory] has always enforced, now applied to every entry point.
  Directory? _skillDir(String skillId) {
    final rootCanonical = p.canonicalize(root.path);
    final dest = p.canonicalize(p.join(rootCanonical, skillId));
    if (!p.isWithin(rootCanonical, dest)) return null;
    return Directory(dest);
  }

  /// The directory hash of one skill, or null when it has no body here.
  Future<String?> hashOf(String skillId) async {
    final hashes = await hashesOf({skillId});
    return hashes[skillId];
  }

  /// Directory hashes for the named skills (missing bodies are absent).
  Future<Map<String, String>> hashesOf(Set<String> skillIds) async {
    final out = <String, String>{};
    for (final id in skillIds) {
      final dir = _skillDir(id);
      if (dir == null) continue;
      if (!await dir.exists()) continue;
      final fingerprint = _fingerprintOf(dir.path);
      final memo = _memos[id];
      if (memo != null && memo.fingerprint == fingerprint) {
        out[id] = memo.dirHash;
        continue;
      }
      final dirPath = dir.path;
      final dirHash = await Isolate.run(() => _hashSkillDirectory(dirPath));
      _memos[id] = _SkillHashMemo(fingerprint, dirHash);
      out[id] = dirHash;
    }
    return out;
  }

  /// Writes the skill's body as a zip to [output], refusing when the current
  /// directory hash is not [dirHash] (it changed while a session was running)
  /// or the body exceeds the import byte cap.
  Future<void> zipFor({
    required String skillId,
    required String dirHash,
    required File output,
  }) async {
    final dirPath = _skillDir(skillId)?.path;
    if (dirPath == null) {
      throw StateError('skill id escapes the skills root: $skillId');
    }
    final current = await Isolate.run(() => _hashSkillDirectory(dirPath));
    if (current != dirHash) {
      throw StateError('skill body changed while serving: $skillId');
    }
    await Isolate.run(() => _writeSkillZip(dirPath, output.path));
  }

  /// Applies a received zip: extract to staging, re-hash, and only then swap
  /// the directory atomically. Returns false when the re-hash does not match
  /// [dirHash] (corrupt or truncated transfer — nothing is installed).
  Future<bool> applyZip({
    required String skillId,
    required String dirHash,
    required File zip,
  }) async {
    final dest = _skillDir(skillId);
    if (dest == null) return false;
    await ensureRoot();
    if (zip.lengthSync() > kSkillImportMaxBytes) {
      throw const FormatException('skill blob exceeds 200 MB');
    }
    final staging = Directory(
      p.join(
        root.path,
        '.sync-apply-$skillId-${DateTime.now().microsecondsSinceEpoch}',
      ),
    );
    await staging.create(recursive: true);
    try {
      final zipPath = zip.path;
      final stagingPath = staging.path;
      await Isolate.run(() => extractSkillArchive(zipPath, stagingPath));
      final received = await Isolate.run(
        () => _hashSkillDirectory(stagingPath),
      );
      if (received != dirHash) return false;
      _memos[skillId] = _SkillHashMemo(_fingerprintOf(staging.path), received);

      final trash =
          '${dest.path}.sync-old-${DateTime.now().microsecondsSinceEpoch}';
      if (await dest.exists()) {
        await dest.rename(trash);
      }
      await staging.rename(dest.path);
      await _deleteBestEffort(trash);
      return true;
    } finally {
      if (await staging.exists()) {
        await _deleteBestEffort(staging.path);
      }
    }
  }

  /// Zips one skill into the serving cache, keyed by content hash, and reuses
  /// an existing archive. The cache lives in a dot-directory beside the skills,
  /// so directory hashing and zip building never see it.
  Future<File> zipToCache({
    required String skillId,
    required String dirHash,
  }) async {
    final cacheDir = Directory(p.join(root.path, _blobCacheDirName));
    if (!await cacheDir.exists()) await cacheDir.create(recursive: true);
    final output = File(p.join(cacheDir.path, '$dirHash.zip'));
    if (await output.exists()) return output;
    await zipFor(skillId: skillId, dirHash: dirHash, output: output);
    return output;
  }

  /// Drops every cached archive: they are reproducible from the live
  /// directories, so a launch starts empty rather than accumulating.
  Future<void> clearBlobCache() async {
    await _deleteBestEffort(p.join(root.path, _blobCacheDirName));
  }

  static const String _blobCacheDirName = '.sync-blob-cache';

  /// Deletes one skill body. The repository row delete happens next to this
  /// call — a row-less directory would be resurrected as a fresh record by
  /// the skills rescan, and a directory-less row installs a broken skill.
  Future<void> deleteDirectory(String skillId) async {
    final dir = _skillDir(skillId);
    if (dir == null) return;
    if (await dir.exists()) {
      await dir.delete(recursive: true);
    }
    _memos.remove(skillId);
  }

  Future<void> _deleteBestEffort(String path) async {
    try {
      final entity = FileSystemEntity.typeSync(path, followLinks: false);
      if (entity == FileSystemEntityType.directory) {
        await Directory(path).delete(recursive: true);
      } else if (entity == FileSystemEntityType.file) {
        await File(path).delete();
      }
    } catch (_) {}
  }

  /// Cheap stat walk used as the memo fingerprint.
  _SkillFingerprint _fingerprintOf(String dirPath) {
    var count = 0;
    var totalSize = 0;
    var maxMtime = 0;
    final stack = <String>[dirPath];
    while (stack.isNotEmpty) {
      final current = stack.removeLast();
      for (final entity in Directory(current).listSync(followLinks: false)) {
        final name = p.basename(entity.path);
        if (!_carriesSkillEntry(name)) continue;
        if (entity is Directory) {
          stack.add(entity.path);
        } else if (entity is File) {
          final stat = entity.statSync();
          count++;
          totalSize += stat.size;
          final mtime = stat.modified.millisecondsSinceEpoch;
          if (mtime > maxMtime) maxMtime = mtime;
        }
      }
    }
    return _SkillFingerprint(count, totalSize, maxMtime);
  }
}

/// Whether a skill-directory entry rides the body. The hash, the fingerprint
/// and the zip must agree on this set: the extractor installs every entry of a
/// received archive, so any name the hash ignores is a divergence the content
/// clock can never see — an edit touching only those names would never
/// converge between two devices.
///
/// Excluded are the sync plane's own scratch directories (`.sync-blob-cache`
/// beside the skills, the `.sync-apply-*` staging and `.sync-old-*` trashed
/// bodies) and the bookkeeping files Finder and Explorer drop in, which would
/// otherwise make two identical bodies hash differently per platform.
bool _carriesSkillEntry(String name) {
  if (name == '.DS_Store' || name == 'Thumbs.db' || name == 'desktop.ini') {
    return false;
  }
  return !name.startsWith('.sync-');
}

/// sha256 over the sorted `relpath\0fileDigest` lines of every regular file
/// under [dirPath]. Deterministic across platforms (posix separators, UTF-8,
/// sorted) and independent of mtimes.
String _hashSkillDirectory(String dirPath) {
  final lines = <String>[];
  final stack = <String>[dirPath];
  while (stack.isNotEmpty) {
    final current = stack.removeLast();
    for (final entity in Directory(current).listSync(followLinks: false)) {
      final name = p.basename(entity.path);
      if (!_carriesSkillEntry(name)) continue;
      if (entity is Directory) {
        stack.add(entity.path);
      } else if (entity is File) {
        final rel = p
            .relative(entity.path, from: dirPath)
            .replaceAll('\\', '/');
        final digest = crypto.sha256.convert(entity.readAsBytesSync());
        lines.add('$rel\u0000$digest');
      }
    }
  }
  lines.sort();
  return crypto.sha256.convert(utf8.encode(lines.join('\n'))).toString();
}

void _writeSkillZip(String dirPath, String outputPath) {
  final files = <String, List<int>>{};
  final stack = <String>[dirPath];
  var total = 0;
  while (stack.isNotEmpty) {
    final current = stack.removeLast();
    for (final entity in Directory(current).listSync(followLinks: false)) {
      final name = p.basename(entity.path);
      if (!_carriesSkillEntry(name)) continue;
      if (entity is Directory) {
        stack.add(entity.path);
      } else if (entity is File) {
        final rel = p
            .relative(entity.path, from: dirPath)
            .replaceAll('\\', '/');
        final bytes = entity.readAsBytesSync();
        total += bytes.length;
        if (total > kSkillImportMaxBytes) {
          throw const FormatException('skill body exceeds 200 MB');
        }
        files[rel] = bytes;
      }
    }
  }
  if (files.isEmpty) {
    throw const FormatException('skill body has no files');
  }
  File(outputPath).writeAsBytesSync(encodeSkillZip(files), flush: true);
}

final class _SkillFingerprint {
  final int count;
  final int totalSize;
  final int maxMtimeMs;

  const _SkillFingerprint(this.count, this.totalSize, this.maxMtimeMs);

  @override
  bool operator ==(Object other) =>
      other is _SkillFingerprint &&
      other.count == count &&
      other.totalSize == totalSize &&
      other.maxMtimeMs == maxMtimeMs;

  @override
  int get hashCode => Object.hash(count, totalSize, maxMtimeMs);
}

final class _SkillHashMemo {
  final _SkillFingerprint fingerprint;
  final String dirHash;

  const _SkillHashMemo(this.fingerprint, this.dirHash);
}
