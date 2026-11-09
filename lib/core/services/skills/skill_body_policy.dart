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

/// The parked body of a swap: `.sync-old-<id>-<micros>`.
String skillParkedBodyName(String skillId, int micros) =>
    '${kSyncScratchPrefix}park-$skillId-$micros';

/// The served-zip cache beside the bodies.
const String kSkillBlobCacheName = '${kSyncScratchPrefix}blob-cache';

/// Whether [name] is the sync plane's own scratch rather than content.
///
/// The one recogniser. Both spellings exist on disk — the prefix one this build
/// writes, and the parked one an older build left behind — and a reader that
/// knew only the prefix is how a parked body became a skill.
bool isSyncScratchName(String name) =>
    name.startsWith(kSyncScratchPrefix) || name.contains(kParkedBodyMarker);

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
typedef SkillBodyFingerprint = ({String shape, int maxMtimeMs});

/// The shape of the hash input — the same sorted `relpath\0…` lines with the
/// file digests taken out — plus the newest mtime.
///
/// The digests are the expensive half and the shape is what they are computed
/// over, so an unchanged shape cannot have produced a different hash. Any
/// operation that moves a path — a rename, a file into a subdirectory, a swap of
/// two names — moves the shape, which is exactly what a count-and-size
/// fingerprint could not see (F4: a script renamed to an equal-length name with
/// its mtime untouched hashed to the old value for the rest of the launch). The
/// mtime stays because a same-size edit in place changes neither path nor size.
SkillBodyFingerprint fingerprintOfSkillBody(String dirPath) {
  final lines = <String>[];
  var maxMtime = 0;
  for (final file in walkSkillBody(dirPath)) {
    lines.add('${file.relPath}\u0000${file.size}');
    if (file.mtimeMs > maxMtime) maxMtime = file.mtimeMs;
  }
  lines.sort();
  return (shape: lines.join('\n'), maxMtimeMs: maxMtime);
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

/// Deletes the sync plane's scratch names that sit directly under [root] — the
/// staging directory of an apply that was interrupted, the parked body of a swap
/// that died between its renames, and the served-zip cache (reproducible from
/// the live bodies).
///
/// The one owner of what may be swept, and deliberately narrow: direct children
/// of the root only, matched by [isSyncScratchName] alone, nothing followed and
/// no body walked into. A user's own directory that merely looks similar
/// (`sync-notes`, `.sync-backup`) is not a scratch name and is never touched,
/// which is the whole of the risk this sweep carries.
Future<void> sweepSkillRootScratch(Directory root) async {
  final List<FileSystemEntity> children;
  try {
    if (!await root.exists()) return;
    children = await root.list(followLinks: false).toList();
  } catch (error) {
    debugPrint('sync skill: could not list ${root.path} to sweep: $error');
    return;
  }
  for (final entity in children) {
    if (!isSyncScratchName(p.basename(entity.path))) continue;
    try {
      await entity.delete(recursive: true);
    } catch (error) {
      debugPrint('sync skill: sweeping ${entity.path} failed: $error');
    }
  }
}
