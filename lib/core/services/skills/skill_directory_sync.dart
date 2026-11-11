import 'dart:io';
import 'dart:isolate';

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:path/path.dart' as p;

import 'skill_archive.dart';
import 'skill_body_policy.dart';

export 'skill_body_policy.dart';

/// Hands the body a swap has just displaced — already out of the live root,
/// still inside it under a scratch name — to the recycle bin, so the version it
/// replaced can be brought back (ADR-0016).
///
/// False means the bin could not take it. The body then stays under its scratch
/// name, which is lossy at the next startup sweep but never silent and never the
/// only copy of anything live: what it holds is the version a peer's newer body
/// already replaced.
typedef SkillBodyPreserver =
    Future<bool> Function(String skillId, Directory displaced);

/// One directory rename, as the swap performs it.
typedef SkillRenamer = Future<void> Function(String from, String to);

Future<void> _renameDirectory(String from, String to) async {
  await Directory(from).rename(to);
}

/// Skill-directory carriage for LAN sync (ADR-0003 slice 3): a skill travels as
/// its entity record plus its on-disk directory as one zip blob keyed by a
/// directory hash — sha256 over the sorted `relpath\0fileDigest` lines (see
/// `skill_body_policy.dart`, which owns what a body is). The record's
/// `updated_at` does not track content edits, so the hash is the only content
/// clock.
///
/// Apply is staging + directory swap, re-hashed on receipt before the swap;
/// extraction reuses the `skill_archive` hardened unpacker, so zip-slip and size
/// caps are enforced by the same code the import flow trusts.
class SkillDirectorySync {
  SkillDirectorySync(this.root, {this.preserveBody, SkillRenamer? rename})
    : _rename = rename ?? _renameDirectory;

  /// The skills root (`<appData>/skills`).
  final Directory root;

  /// Where a displaced body goes. Null in a harness with no bin: the swap still
  /// works and the old body waits under its scratch name for the sweep.
  final SkillBodyPreserver? preserveBody;

  /// The rename the swap performs. Injected only to force one to fail: the
  /// second rename of a swap is the failure whose recovery matters most — the
  /// old body has to come back so the next round is a retry rather than a loss —
  /// and no filesystem this project targets can be made to refuse it on demand.
  /// Production never passes it.
  final SkillRenamer _rename;

  /// Per-launch memo: a fingerprint that has not changed cannot have changed
  /// content, so the hash is reused. Fingerprints are recomputed on every call;
  /// hashing is the expensive half.
  final Map<String, _SkillHashMemo> _memos = {};

  /// Whether the startup sweep has already run for this instance.
  bool _swept = false;

  /// Creates the root if it is not there, and reclaims the scratch this plane
  /// left behind the last time it ran — an interrupted apply's staging
  /// directory, a swap's parked body, the served-zip cache.
  ///
  /// Once per instance, and only ever direct children matched by the policy's
  /// own names: the sweep is the one operation here that deletes something it
  /// did not create in this run, so it is the one that refuses to guess.
  Future<void> ensureRoot() async {
    if (!await root.exists()) {
      await root.create(recursive: true);
    }
    if (_swept) return;
    _swept = true;
    await sweepSkillRootScratch(root);
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

  /// Applies a received zip: extract to staging, re-hash, and only then swap the
  /// directory in. Returns false when the re-hash does not match [dirHash]
  /// (corrupt or truncated transfer — nothing is installed) or when the swap
  /// could not complete (the body that was here is still here).
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
        // The one caller that filters: what a peer's body becomes must hold
        // exactly the names its hash counted, or the re-hash below fails on a
        // difference no sender ever produced. An import passes no filter.
        await Isolate.run(
          () => extractSkillArchive(
            zipPath,
            stagingPath,
            installsName: carriesSkillEntry,
          ),
        );
      }
      final received = await Isolate.run(() => hashSkillBody(stagingPath));
      if (received != dirHash) return false;
      if (!await _swapIn(staging, dest, skillId)) return false;
      // Observed from the directory that is now installed, not from the staging
      // one: they hold the same bytes, but what the next `hashesOf` reads is
      // this path, and a memo keyed to a path that no longer exists is a memo
      // that can only ever be wrong.
      _memos[skillId] = _SkillHashMemo(
        fingerprintOfSkillBody(dest.path),
        received,
      );
      return true;
    } finally {
      if (await staging.exists()) {
        await _deleteBestEffort(staging.path);
      }
    }
  }

  /// Moves [staging] into [dest], keeping the body it replaces.
  ///
  /// A directory swap is two renames and no platform makes the pair atomic, so
  /// the order is chosen for the state an interruption leaves behind:
  ///
  /// 1. the body that is here goes to a scratch name **first** — still inside
  ///    the root, still O(1), and never a delete;
  /// 2. the new body takes its place;
  /// 3. the old body goes into the recycle bin.
  ///
  /// A failure at 2 renames the displaced body straight back, so the record, the
  /// content clock and the next session's plan all read the state before the
  /// attempt: the identity is intact and the next round retries. A failure at 3
  /// (or no bin at all) leaves the body under its scratch name, which the rescan
  /// refuses to adopt and [sweepSkillRootScratch] reclaims. What cannot happen,
  /// in either case, is the old body being destroyed while its replacement was
  /// never installed — which is what "moved, not deleted" is worth.
  Future<bool> _swapIn(
    Directory staging,
    Directory dest,
    String skillId,
  ) async {
    if (!await dest.exists()) {
      try {
        await _rename(staging.path, dest.path);
        return true;
      } catch (error) {
        debugPrint(
          'sync skill: installing the body of $skillId failed: $error',
        );
        return false;
      }
    }
    final displaced = Directory(
      p.join(
        root.path,
        skillParkedBodyName(skillId, DateTime.now().microsecondsSinceEpoch),
      ),
    );
    try {
      await _rename(dest.path, displaced.path);
    } catch (error) {
      // Nothing has moved: the body that is here is the body that stays.
      debugPrint(
        'sync skill: could not move the body of $skillId aside: $error',
      );
      return false;
    }
    try {
      await _rename(staging.path, dest.path);
    } catch (error) {
      debugPrint(
        'sync skill: installing the body of $skillId failed, putting the old '
        'one back: $error',
      );
      await _putBack(displaced, dest);
      return false;
    }
    await _keepDisplacedBody(skillId, displaced);
    return true;
  }

  /// Puts a displaced body back where it came from after a failed install.
  Future<void> _putBack(Directory displaced, Directory dest) async {
    try {
      await _rename(displaced.path, dest.path);
    } catch (error) {
      // The body is not lost — it is under a scratch name, which is what the
      // startup sweep collects — but the live root is now missing it, so this
      // is worth a log line rather than a swallow.
      debugPrint(
        'sync skill: the body of ${p.basename(dest.path)} could not be put '
        'back and waits in ${displaced.path}: $error',
      );
    }
  }

  /// Hands the body a swap displaced to the recycle bin, or leaves it for the
  /// sweep when there is no bin or the bin could not take it.
  Future<void> _keepDisplacedBody(String skillId, Directory displaced) async {
    final preserve = preserveBody;
    if (preserve == null) return;
    try {
      if (await preserve(skillId, displaced)) return;
    } catch (error) {
      debugPrint('sync skill: preserving the body of $skillId failed: $error');
    }
  }

  /// Zips one skill into the serving cache, keyed by content hash, and reuses an
  /// existing archive. The cache lives in a dot-directory beside the skills, so
  /// directory hashing and zip building never see it.
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
  ///
  /// This is the path a build with no recycle bin has, and the fallback a bin
  /// that could not take the body leaves: everything else moves the body into
  /// the bin instead (ADR-0016).
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
