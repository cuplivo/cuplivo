import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import 'app_directories.dart';

/// Where a workspace file may be written, and whether a directory really is
/// inside the workspace it claims.
///
/// One authority for the rule: a LAN landing and the restore of a file the
/// recycle bin staged both ask it, so a refusal cannot differ between the two
/// ways a file arrives. It lives here rather than beside either caller because
/// the bin is a product on its own — it exists whether or not the device has
/// ever synced.

/// Whether [relPath] may be joined onto a workspace root and written to.
///
/// The path can arrive from a peer's file table, so this is the boundary that
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

/// The deepest ancestor of [directory] that exists right now.
///
/// Containment has to be checked against this one rather than against
/// [directory] itself: an ancestor that does not exist yet cannot follow a
/// symlink, and `create(recursive: true)` follows the links of the ancestors it
/// does find.
Future<Directory> nearestExistingAncestor(Directory directory) async {
  var current = directory;
  while (!await current.exists()) {
    final parent = current.parent;
    if (p.equals(parent.path, current.path)) break;
    current = parent;
  }
  return current;
}

/// Whether [directory] resolves to a place inside [root], symlinks and all.
///
/// Fails closed: a containment this device cannot verify is a write it does not
/// make. The one authority for the rule — the landing path of a sync round and
/// the restore of a staged file both ask it, so a refusal cannot differ between
/// the two ways a file arrives.
Future<bool> isReallyInsideWorkspace(
  Directory root,
  Directory directory,
) async {
  try {
    final realRoot = await root.resolveSymbolicLinks();
    final realDirectory = await directory.resolveSymbolicLinks();
    return p.equals(p.canonicalize(realRoot), p.canonicalize(realDirectory)) ||
        p.isWithin(p.canonicalize(realRoot), p.canonicalize(realDirectory));
  } catch (error) {
    // Failing closed is the rule; failing *silently* is what makes a refusal
    // undiagnosable. A caller reports its own reason (a restore says
    // `unsupported`, which the user reads as "this build cannot do that"), so
    // the throw that produced it has to be in the log.
    debugPrint('workspace paths: containment check failed: $error');
    return false;
  }
}
