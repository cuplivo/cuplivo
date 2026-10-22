import 'dart:io';
import 'dart:isolate';

import 'package:path/path.dart' as p;

import '../../../utils/app_directories.dart';
import 'sync_limits.dart';
import 'sync_models.dart';

/// The content index of one managed workspace: every file that rides, as
/// relative path → (size, mtime).
///
/// Deliberately stat-only. A workspace can hold gigabytes, and sync has to
/// answer "did anything change here?" without reading a byte: the size and the
/// mtime of each file are the whole change detector (ADR-0003 slice 18), which
/// is what keeps planning proportional to the file *count* rather than to the
/// bytes on disk. The price is the documented limit: an edit that keeps both
/// the size and the mtime (within the filesystem's own granularity) is
/// invisible.
class WorkspaceContentIndex {
  const WorkspaceContentIndex(
    this.files, {
    required this.totalBytes,
    this.truncated = false,
    this.incomplete = false,
  });

  /// Relative path (posix separators, always) → version stamp. Empty for a
  /// workspace that holds nothing that rides.
  final Map<String, WorkspaceFileStamp> files;

  /// Sum of the indexed files' sizes. A lower bound when [truncated].
  final int totalBytes;

  /// The caps aborted the walk, so [files] and [totalBytes] are lower bounds
  /// and the workspace is not shared at all — a partial transfer is worse than
  /// none: it would install a fraction of a tree the user believes is whole.
  final bool truncated;

  /// Something under the root could not be read (a directory that refused to
  /// list, a file that refused to stat), so this index is a *subset* of what
  /// the workspace holds.
  ///
  /// An incomplete index must never be shared, and that is a data-safety rule
  /// rather than a courtesy: a table missing a file says "I do not have this",
  /// which is exactly what makes the peer delete its own copy. A file that
  /// could not be read is indistinguishable from a deleted one in a table, so
  /// the whole workspace sits this session out — nothing is deleted on either
  /// side, and the next session (with the directory readable again) resumes
  /// normal service.
  final bool incomplete;

  bool get isEmpty => files.isEmpty;
}

/// Directory names that never ride: version-control stores (their history is
/// the interesting part and it is not a file tree), dependency and build
/// output (reproducible from the manifest, orders of magnitude larger than the
/// sources), and editor/OS scratch.
///
/// Pruned by name at every depth, compared case-insensitively because a
/// case-insensitive filesystem would otherwise hand back `Node_Modules` for a
/// rule written against `node_modules`.
const Set<String> _prunedDirectoryNames = {
  '.git',
  '.svn',
  '.hg',
  '.jj',
  'node_modules',
  '.venv',
  'venv',
  '.tox',
  '__pycache__',
  '.dart_tool',
  '.pub-cache',
  'build',
  'dist',
  'target',
  'out',
  '.next',
  '.nuxt',
  '.gradle',
  '.terraform',
  'pods',
  '.idea',
  '.vscode',
  '.cache',
};

/// File names that never ride: the bookkeeping files Explorer and Finder drop
/// into every directory they touch. Two identical trees would otherwise differ
/// by them on every session.
const Set<String> _prunedFileNames = {
  '.ds_store',
  'thumbs.db',
  'desktop.ini',
  '.localized',
};

/// Every name starting with this is the sync plane's own scratch: staging
/// directories and trashed bodies (see `SkillDirectorySync`, which reserves the
/// same prefix). A workspace that carried them would sync its own transfer
/// debris back and forth.
const String _scratchPrefix = '.sync-';

/// Whether a directory named [name] carries its contents into sync.
bool workspaceDirectoryCarries(String name) {
  final lower = name.toLowerCase();
  if (lower.startsWith(_scratchPrefix)) return false;
  return !_prunedDirectoryNames.contains(lower);
}

/// Whether a file named [name] carries itself into sync.
bool workspaceFileCarries(String name) {
  final lower = name.toLowerCase();
  if (lower.startsWith(_scratchPrefix)) return false;
  return !_prunedFileNames.contains(lower);
}

/// Walks [rootPath] and stat-only indexes every file that rides, off the
/// calling isolate.
///
/// Off an isolate because a first sync indexes every workspace at once: a few
/// thousand `stat` calls are milliseconds of syscalls but they are *blocking*
/// syscalls, and doing them on the UI isolate would show up as a stalled frame
/// on the very screen that started the session.
///
/// The caps are parameters so a test can prove the abort with three files
/// instead of two thousand; production always takes the defaults.
Future<WorkspaceContentIndex> indexWorkspaceContent(
  String rootPath, {
  int maxFiles = kMaxWorkspaceFiles,
  int maxBytes = kMaxWorkspaceBytes,
}) => Isolate.run(
  () => indexWorkspaceContentSync(
    rootPath,
    maxFiles: maxFiles,
    maxBytes: maxBytes,
  ),
);

/// The walk itself, synchronous so it can run inside an isolate. Returns as
/// soon as either cap is passed — the point is to never walk a tree that will
/// not be transferred anyway.
WorkspaceContentIndex indexWorkspaceContentSync(
  String rootPath, {
  int maxFiles = kMaxWorkspaceFiles,
  int maxBytes = kMaxWorkspaceBytes,
}) {
  final files = <String, WorkspaceFileStamp>{};
  var totalBytes = 0;
  var incomplete = false;
  final stack = <String>[rootPath];
  while (stack.isNotEmpty) {
    final current = stack.removeLast();
    final List<FileSystemEntity> children;
    try {
      children = Directory(current).listSync(followLinks: false);
    } on FileSystemException {
      // A directory that vanished (or that this process may not read) is not a
      // reason to abandon the rest of the workspace: its files simply do not
      // ride this session, exactly as if they had been deleted. What it *is* is
      // a reason to stop trusting this index as complete — see
      // [WorkspaceContentIndex.incomplete].
      incomplete = true;
      continue;
    }
    for (final entity in children) {
      final name = p.basename(entity.path);
      if (entity is Directory) {
        if (!workspaceDirectoryCarries(name)) continue;
        stack.add(entity.path);
        continue;
      }
      // A link is neither a file nor a directory to this walk: symlinks never
      // ride, on either side (a link's target is a fact about one machine's
      // filesystem, and following them can walk out of the workspace).
      if (entity is! File) continue;
      if (!workspaceFileCarries(name)) continue;
      final FileStat stat;
      try {
        stat = entity.statSync();
      } on FileSystemException {
        incomplete = true;
        continue;
      }
      final rel = p.relative(entity.path, from: rootPath).replaceAll('\\', '/');
      files[rel] = WorkspaceFileStamp(
        size: stat.size,
        mtimeMs: stat.modified.millisecondsSinceEpoch,
      );
      totalBytes += stat.size;
      if (files.length > maxFiles || totalBytes > maxBytes) {
        return WorkspaceContentIndex(
          files,
          totalBytes: totalBytes,
          truncated: true,
          incomplete: incomplete,
        );
      }
    }
  }
  return WorkspaceContentIndex(
    files,
    totalBytes: totalBytes,
    incomplete: incomplete,
  );
}

/// Whether [relPath] may be joined onto a workspace root and written to.
///
/// The path arrived from the peer's file table, so this is the boundary that
/// keeps a crafted one (`../../.ssh/authorized_keys`, `C:\Windows\...`, a UNC
/// path) from escaping the workspace. Rejected on principle are: an absolute
/// path, a Windows drive or alternate-data-stream colon, a backslash separator
/// (the wire is always posix), a NUL, an empty or `.`/`..` segment, a trailing
/// dot or space in a segment (Windows silently strips both, so `evil. ` and
/// `evil` are the same file there), and a reserved device name.
bool isSafeWorkspaceRelativePath(String relPath) {
  if (relPath.isEmpty) return false;
  if (relPath.contains('\u0000')) return false;
  if (relPath.contains('\\')) return false;
  if (p.posix.isAbsolute(relPath)) return false;
  final segments = relPath.split('/');
  for (final segment in segments) {
    if (!isSafePathSegment(segment)) return false;
  }
  return true;
}

/// The absolute path [relPath] names inside [root], or null when the path is
/// not a legal workspace-relative one. Lexical containment is checked as well
/// as the segment rules: the two agree today, and this is the one place a
/// relaxation of either would otherwise leak.
String? workspacePathWithin(String root, String relPath) {
  if (!isSafeWorkspaceRelativePath(relPath)) return null;
  final canonicalRoot = p.canonicalize(root);
  final target = p.canonicalize(p.join(canonicalRoot, relPath));
  if (!p.isWithin(canonicalRoot, target)) return null;
  return target;
}
