import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart' as crypto;
import 'package:flutter/foundation.dart' show debugPrint;
import 'package:path/path.dart' as p;

import '../../../utils/app_directories.dart';

/// What a skill body *is*, in one file: the names that ride it, the walk the
/// hash and the served zip both read, the equivalence the content clock is
/// memoised on, the root-level scratch names this plane writes beside a body,
/// and the one rule that turns a skill id into a path.
///
/// Every one of those used to be answered in several places, and three of them
/// answered it differently — the body hash and the zip skipped names starting
/// with `.sync-` while the swap parked a displaced body *after* the skill id
/// (`<id>.sync-old-<micros>`), so the rescan adopted the parked copy as a new
/// skill and the ghost outlived every session (F2). Names are now produced here
/// and recognised here, so no spelling can be written but not looked for.

/// The sync plane's own scratch prefix: the staging directory of an apply, the
/// parked body of a swap and the served-zip cache all start with it, and they
/// all live inside the skills root because that root is the one place a body can
/// be moved in O(1).
const String kSyncScratchPrefix = '.sync-';

/// The marker of the parked form an older build wrote *after* the skill id
/// (`<id>.sync-old-<micros>`). It is recognised, never produced: a displaced
/// body now goes to the recycle bin, and an install that crashed before that
/// change still has one on disk. The rescan refusing it is what keeps it from
/// becoming a skill; [sweepSkillRootScratch] reclaims the space.
const String kParkedBodyMarker = '.sync-old-';

/// The staging directory of one apply: `.sync-apply-<id>-<micros>`.
String skillApplyScratchName(String skillId, int micros) =>
    '${kSyncScratchPrefix}apply-$skillId-$micros';

/// The prefix of a parked body's name: `.sync-park-<id>-<micros>`.
const String kParkedBodyPrefix = '${kSyncScratchPrefix}park-';

/// The parked body of a swap: `.sync-park-<id>-<micros>`.
///
/// The id comes *first* here, unlike the form an older build wrote
/// (`<id>.sync-old-<micros>`), so a reader that only knows the prefix cannot see
/// the old spelling and a reader that knows the marker cannot see this one. Both
/// are named by the same file and recognised by [isSyncScratchName].
String skillParkedBodyName(String skillId, int micros) =>
    '$kParkedBodyPrefix$skillId-$micros';

/// The served-zip cache beside the bodies.
const String kSkillBlobCacheName = '${kSyncScratchPrefix}blob-cache';

/// Whether [name] carries the sync plane's scratch *prefix*.
///
/// The narrow facet, and the one a workspace reads: a workspace holds the user's
/// own files, so its prune rule stays what it has always been — a name starting
/// with `.sync-` is this plane's, and nothing else is. It must not inherit the
/// skill root's parked-body spelling below, which is written *after* an id and
/// which a user's file may perfectly well contain (`report.sync-old-v2.docx`).
bool isSyncScratchPrefix(String name) => name.startsWith(kSyncScratchPrefix);

/// Whether [name] is the sync plane's own scratch rather than content.
///
/// The recogniser for the skills root, where both spellings exist on disk: the
/// prefix one this build writes, and the parked one an older build left behind.
/// A reader that knew only the prefix is how a parked body became a skill.
bool isSyncScratchName(String name) =>
    isSyncScratchPrefix(name) || name.contains(kParkedBodyMarker);

/// The skill id a parked body's name encodes, or null when [name] is not one.
///
/// The two spellings put the microsecond stamp in different places, and that is
/// the whole of the difference:
///
/// * `.sync-park-<id>-<micros>` — the stamp is appended *after* the id, so it is
///   the last dash-separated field and that field alone may come off. Ids contain
///   dashes themselves (`my-skill-2` is what a second skill called "my skill"
///   becomes), which is why it is the **last** one.
/// * `<id>.sync-old-<micros>` — the marker *is* the delimiter, so what precedes
///   it is the id entire, and what follows it must be the stamp. Stripping a
///   field from the id here reads `my-skill-2.sync-old-1723` as `my-skill` — a
///   body put back under a stranger's id — and reads an id with no dash as
///   `null`, which is how the sweep came to delete the only copy it was meant to
///   recover.
String? parkedBodySkillId(String name) {
  final String id;
  if (name.startsWith(kParkedBodyPrefix)) {
    final rest = name.substring(kParkedBodyPrefix.length);
    final cut = rest.lastIndexOf('-');
    if (cut <= 0 || !_isStamp(rest.substring(cut + 1))) return null;
    id = rest.substring(0, cut);
  } else {
    final at = name.lastIndexOf(kParkedBodyMarker);
    if (at <= 0) return null;
    if (!_isStamp(name.substring(at + kParkedBodyMarker.length))) return null;
    id = name.substring(0, at);
  }
  return id.isEmpty ? null : id;
}

bool _isStamp(String value) {
  if (value.isEmpty) return false;
  for (final unit in value.codeUnits) {
    if (unit < 0x30 || unit > 0x39) return false;
  }
  return true;
}

/// Whether a skill-directory entry rides the body.
///
/// The hash, the zip, the extraction and the fingerprint all read this: a name
/// the hash ignores but the extractor installs is a divergence the content clock
/// can never see, and a name only the fingerprint saw would move a hash that
/// never changed.
///
/// Excluded are the sync plane's own scratch names (above) and the bookkeeping
/// files Finder and Explorer drop in, which would otherwise make two identical
/// bodies hash differently per platform.
bool carriesSkillEntry(String name) {
  if (name == '.DS_Store' || name == 'Thumbs.db' || name == 'desktop.ini') {
    return false;
  }
  return !isSyncScratchName(name);
}

/// One file that rides a body, as the walk sees it.
final class SkillBodyFile {
  const SkillBodyFile({
    required this.relPath,
    required this.path,
    required this.size,
    required this.mtimeMs,
  });

  /// Posix relative path — the identity the content clock and the fingerprint
  /// are both built from.
  final String relPath;

  /// Absolute path of the file itself.
  final String path;
  final int size;
  final int mtimeMs;
}

/// Every file that rides [dirPath], sorted by [SkillBodyFile.relPath].
///
/// The one walk. It is what makes the hash, the served zip and the fingerprint
/// agree by construction: they cannot disagree about a name or about a path,
/// because they are looking at the same list.
List<SkillBodyFile> walkSkillBody(String dirPath) {
  final files = <SkillBodyFile>[];
  final stack = <String>[dirPath];
  while (stack.isNotEmpty) {
    final current = stack.removeLast();
    for (final entity in Directory(current).listSync(followLinks: false)) {
      final name = p.basename(entity.path);
      if (!carriesSkillEntry(name)) continue;
      if (entity is Directory) {
        stack.add(entity.path);
        continue;
      }
      // A link is neither a file nor a directory to this walk: its target is a
      // fact about one machine's filesystem, and following it can walk out of
      // the body.
      if (entity is! File) continue;
      final stat = entity.statSync();
      files.add(
        SkillBodyFile(
          relPath: p.relative(entity.path, from: dirPath).replaceAll('\\', '/'),
          path: entity.path,
          size: stat.size,
          mtimeMs: stat.modified.millisecondsSinceEpoch,
        ),
      );
    }
  }
  files.sort((a, b) => a.relPath.compareTo(b.relPath));
  return files;
}

/// sha256 over the sorted `relpath\0fileDigest` lines of [dirPath] — the wire
/// value of a body (ADR-0003), and the only content clock a skill has: the
/// record's `updatedAt` does not track edits to the files.
///
/// Deterministic across platforms (posix separators, UTF-8, sorted) and
/// independent of mtimes and of write order.
String hashSkillBody(String dirPath) {
  final lines = <String>[
    for (final file in walkSkillBody(dirPath))
      '${file.relPath}\u0000'
          '${crypto.sha256.convert(File(file.path).readAsBytesSync())}',
  ];
  lines.sort();
  return crypto.sha256.convert(utf8.encode(lines.join('\n'))).toString();
}

/// The body hash of a skill whose carried set is empty — a directory that holds
/// nothing that rides (or only names the policy excludes). It is a real body,
/// and the hash, the zip and the extraction have to agree on it: when they did
/// not, a peer holding this hash asked for a body this device could never
/// produce, so the record stayed deferred session after session.
final String kEmptySkillBodyHash = crypto.sha256
    .convert(const <int>[])
    .toString();

/// What a memo compares before it reuses a hash.
typedef SkillBodyFingerprint = String;

/// Every file's path, size and mtime, as one string the memo compares.
///
/// The digest is the expensive half and this is the input it is computed over,
/// so an unchanged fingerprint cannot have produced a different hash — with one
/// limit, the same one the workspace file plane documents: an edit that keeps
/// both the size and the mtime, within the filesystem's own granularity, is
/// invisible here.
///
/// The stamp is **per file**, not the newest mtime of the body. One maximum is a
/// different statement and a weaker one: an edit lands at "now", so it takes that
/// slot only if it is the newest file in the body, while any file dated ahead of
/// it — copied with preserved timestamps, unpacked from an archive that carried
/// them, written before a clock correction — leaves a same-size edit with an
/// unchanged fingerprint, and the pre-edit hash for the rest of the launch. What
/// the shape adds to the stamps is the paths: a rename or a move changes no
/// file's size or mtime, and F4 is exactly that case.
SkillBodyFingerprint fingerprintOfSkillBody(String dirPath) {
  final lines = <String>[
    for (final file in walkSkillBody(dirPath))
      '${file.relPath}\u0000${file.size}\u0000${file.mtimeMs}',
  ];
  lines.sort();
  return lines.join('\n');
}

/// The body directory of [skillId] under [root], or null when the id is not a
/// single safe path segment inside it.
///
/// Skill ids arrive from the wire — a peer's manifest names them — so every path
/// built from one goes through here: a crafted id (`../victim`, an absolute
/// path, a drive-relative one) is refused before any stat, create, rename or
/// delete can leave the root. The recycle bin asks the same function before it
/// moves a body in or out, so a restore cannot put one where an apply could not.
Directory? skillBodyDirectory(Directory root, String skillId) {
  if (!isSafePathSegment(skillId)) return null;
  final rootCanonical = p.canonicalize(root.path);
  final dest = p.canonicalize(p.join(rootCanonical, skillId));
  if (!p.isWithin(rootCanonical, dest)) return null;
  return Directory(dest);
}

/// The parked copy of [skillId]'s body, when a swap left one behind.
///
/// A swap parks the body it displaces before installing the replacement, so in
/// the window between the two renames the live path is empty and this directory
/// holds the only copy of that skill's files. Direct children of [root] only,
/// named by the shared recogniser and parsed by [parkedBodySkillId]: nothing is
/// followed and no body is walked into.
Future<Directory?> parkedSkillBody(Directory root, String skillId) async {
  final List<FileSystemEntity> children;
  try {
    if (!await root.exists()) return null;
    children = await root.list(followLinks: false).toList();
  } catch (error) {
    debugPrint('sync skill: could not list ${root.path} for $skillId: $error');
    return null;
  }
  for (final entity in children) {
    if (entity is! Directory) continue;
    final name = p.basename(entity.path);
    if (!isSyncScratchName(name)) continue;
    if (parkedBodySkillId(name) != skillId) continue;
    return entity;
  }
  return null;
}

/// The directory [skillId]'s body is in right now: the live path, or the parked
/// copy of a swap that did not finish. Null when it has neither.
///
/// A caller that must not lose a body reads this instead of
/// [skillBodyDirectory], because in that window the live path is empty and the
/// parked directory is all there is — the delete that hands a body to the bin,
/// and the bin itself when it resolves the directory it moves.
Future<Directory?> liveOrParkedSkillBody(Directory root, String skillId) async {
  final live = skillBodyDirectory(root, skillId);
  if (live == null) return null;
  if (await live.exists()) return live;
  return parkedSkillBody(root, skillId);
}

/// Settles the sync plane's scratch that sits directly under [root]: **recovers**
/// what an interrupted swap left recoverable, then **reclaims** the rest — the
/// staging directory of an apply that was interrupted and the served-zip cache
/// (which is reproducible from the live bodies).
///
/// The recovery is the part that cannot be skipped and the order is why. A
/// parked body is the body of its skill, moved out of the live root by a swap
/// that did not finish installing the replacement: the process died between the
/// two renames, or the second rename and the put-back both failed. In that state
/// `<root>/<id>` is empty and the parked directory is **the only copy of that
/// skill's body** — so deleting it, and then letting the rescan drop the record
/// for want of a `SKILL.md` at the path the recovery was about to fill, loses a
/// skill twice over at the one moment this plane is looking for debris.
///
/// Otherwise the parked copy is debris and goes — **except** in one state, which
/// is the mirror of the first: the live path is empty *and* no record describes
/// the skill any more. Then this is not an interrupted swap but the body of a
/// skill the user deleted while it was parked (that delete found an empty live
/// path and staged nothing), and both of the obvious answers are wrong: renaming
/// it back invents a skill they deleted, and deleting it destroys the only copy
/// there is. It goes to [intoBin]; when no bin will take it, it stays where it
/// is — inert, named as scratch, and asked about again next launch.
///
/// [livingSkillIds] is what makes that distinction possible, and it comes from
/// the records. Passing none means "no record set is known here", which recovers
/// unconditionally: that is what the sync plane's own entry point does, because
/// the records it will have are decided after this runs.
///
/// Nothing here guesses: direct children of the root only, matched by
/// [isSyncScratchName] alone, a name that parses to a safe id or it is not a
/// body, nothing followed and no body walked into. A user's own directory that
/// merely looks similar (`sync-notes`, `.sync-backup`) is not a scratch name and
/// is never touched, which is the whole of the risk this carries.
Future<void> sweepSkillRootScratch(
  Directory root, {
  Set<String>? livingSkillIds,
  ParkedBodySink? intoBin,
}) async {
  final List<FileSystemEntity> children;
  try {
    if (!await root.exists()) return;
    children = await root.list(followLinks: false).toList();
  } catch (error) {
    debugPrint('sync skill: could not list ${root.path} to sweep: $error');
    return;
  }
  final debris = <FileSystemEntity>[];
  for (final entity in children) {
    if (!isSyncScratchName(p.basename(entity.path))) continue;
    if (await _settleParkedBody(root, entity, livingSkillIds, intoBin)) {
      continue;
    }
    debris.add(entity);
  }
  for (final entity in debris) {
    try {
      await entity.delete(recursive: true);
    } catch (error) {
      debugPrint('sync skill: sweeping ${entity.path} failed: $error');
    }
  }
}

/// Where a parked body goes when the skill it belonged to has no record left:
/// the bin. True means the bin took it.
typedef ParkedBodySink = Future<bool> Function(Directory parked, String id);

/// Whether [entity] was settled in place — put back, handed to the bin, or kept
/// because it is the only copy of a skill no record describes. False means
/// debris: a staging directory, the blob cache, a name that is not a body, or a
/// parked copy whose replacement landed.
Future<bool> _settleParkedBody(
  Directory root,
  FileSystemEntity entity,
  Set<String>? livingSkillIds,
  ParkedBodySink? intoBin,
) async {
  final id = parkedBodySkillId(p.basename(entity.path));
  if (id == null || entity is! Directory) return false;
  final live = skillBodyDirectory(root, id);
  if (live == null) return false;
  try {
    if (await live.exists()) return false;
    if (livingSkillIds != null && !livingSkillIds.contains(id)) {
      if (intoBin != null && await intoBin(entity, id)) {
        debugPrint('sync skill: the body of the deleted $id went to the bin');
      } else {
        debugPrint(
          'sync skill: keeping ${entity.path}: no record for $id and no bin '
          'would take it',
        );
      }
      return true;
    }
    await entity.rename(live.path);
    debugPrint('sync skill: put the parked body ${entity.path} back as $id');
  } catch (error) {
    // A rename that threw is not a verdict on the body: it is the only copy of
    // that skill, so keeping it is always better than the debris list, and the
    // next launch asks again.
    debugPrint(
      'sync skill: could not settle ${entity.path}, keeping it: $error',
    );
  }
  return true;
}
