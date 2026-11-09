import 'dart:io';
import 'dart:isolate';

import 'package:path/path.dart' as p;

import 'skill_archive.dart';
import 'skill_body_policy.dart';

export 'skill_body_policy.dart';

/// Skill-directory carriage for LAN sync (ADR-0003 slice 3): a skill travels as
/// its entity record plus its on-disk directory as one zip blob keyed by a
/// directory hash — sha256 over the sorted `relpath\0fileDigest` lines (see
/// `skill_body_policy.dart`, which owns what a body is). The record's
/// `updated_at` does not track content edits, so the hash is the only content
/// clock.
///
/// Apply is staging + atomic directory swap, re-hashed on receipt before the
/// swap; extraction reuses the `skill_archive` hardened unpacker, so zip-slip and
/// size caps are enforced by the same code the import flow trusts.
class SkillDirectorySync {
  SkillDirectorySync(this.root);

  /// The skills root (`<appData>/skills`).
  final Directory root;

  /// Per-launch memo: a fingerprint that has not changed cannot have changed
  /// content, so the hash is reused. Fingerprints are recomputed on every call;
  /// hashing is the expensive half.
  final Map<String, _SkillHashMemo> _memos = {};

  Future<void> ensureRoot() async {
    if (!await root.exists()) {
      await root.create(recursive: true);
    }
  }

  /// The directory of [skillId], or null when the id is not one safe segment
  /// inside the root (see [skillBodyDirectory]).
  Directory? _skillDir(String skillId) => skillBodyDirectory(root, skillId);

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
      final fingerprint = fingerprintOfSkillBody(dir.path);
      final memo = _memos[id];
      if (memo != null && memo.fingerprint == fingerprint) {
        out[id] = memo.dirHash;
        continue;
      }
      final dirPath = dir.path;
      final dirHash = await Isolate.run(() => hashSkillBody(dirPath));
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
    final current = await Isolate.run(() => hashSkillBody(dirPath));
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
        skillApplyScratchName(skillId, DateTime.now().microsecondsSinceEpoch),
      ),
    );
    await staging.create(recursive: true);
    try {
      final zipPath = zip.path;
      final stagingPath = staging.path;
      // An empty body is a body: its zip carries no entries, which the archive
      // importer refuses outright, so staging is left as it is and the re-hash
      // below is the verification. `dirHash` is the contract either way — a
      // body that hashes to the empty set *is* the empty set.
      if (dirHash != kEmptySkillBodyHash) {
        await Isolate.run(() => extractSkillArchive(zipPath, stagingPath));
      }
      final received = await Isolate.run(() => hashSkillBody(stagingPath));
      if (received != dirHash) return false;
      _memos[skillId] = _SkillHashMemo(
        fingerprintOfSkillBody(staging.path),
        received,
      );

      final trash = p.join(
        root.path,
        skillParkedBodyName(skillId, DateTime.now().microsecondsSinceEpoch),
      );
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
    final cacheDir = Directory(p.join(root.path, kSkillBlobCacheName));
    if (!await cacheDir.exists()) await cacheDir.create(recursive: true);
    final output = File(p.join(cacheDir.path, '$dirHash.zip'));
    if (await output.exists()) return output;
    await zipFor(skillId: skillId, dirHash: dirHash, output: output);
    return output;
  }

  /// Drops every cached archive: they are reproducible from the live
  /// directories, so a launch starts empty rather than accumulating.
  Future<void> clearBlobCache() async {
    await _deleteBestEffort(p.join(root.path, kSkillBlobCacheName));
  }

  /// Deletes one skill body. The repository row delete happens next to this
  /// call — a row-less directory would be resurrected as a fresh record by the
  /// skills rescan, and a directory-less row installs a broken skill.
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
}

void _writeSkillZip(String dirPath, String outputPath) {
  final files = <String, List<int>>{};
  var total = 0;
  for (final entry in walkSkillBody(dirPath)) {
    final bytes = File(entry.path).readAsBytesSync();
    total += bytes.length;
    if (total > kSkillImportMaxBytes) {
      throw const FormatException('skill body exceeds 200 MB');
    }
    files[entry.relPath] = bytes;
  }
  // An empty carried set still produces the empty body's zip: the hash
  // advertised for it is servable, and the receiver converges to a directory
  // with nothing that rides — refusing to write it made that hash a body no
  // device could ever deliver.
  File(outputPath).writeAsBytesSync(encodeSkillZip(files), flush: true);
}

final class _SkillHashMemo {
  final SkillBodyFingerprint fingerprint;
  final String dirHash;

  const _SkillHashMemo(this.fingerprint, this.dirHash);
}
