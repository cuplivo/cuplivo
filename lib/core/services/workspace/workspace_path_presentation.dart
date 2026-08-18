/// Model-facing path presentation for workspace tools.
///
/// Canonical wire paths (`@alias/rel/path`) remain the internal identity
/// format (deletion markers, backups, ADR-0022). This file translates
/// between that canonical form and the single vocabulary presented to the
/// model: `/workspace/rel/path`, where `/workspace` is the root of the
/// workspace bound to the current assistant (matches the Linux sandbox
/// shell view; filesystem tools and shell now share one vocabulary).
library;

import 'workspace_execution_context.dart';

/// Thrown when a model-supplied path cannot be resolved inside `/workspace`.
class ModelPathException implements Exception {
  final String message;
  ModelPathException(this.message);

  @override
  String toString() => message;
}

/// Resolves relative model paths from [workingDirectory]. Canonical
/// `@alias/...` paths and arbitrary absolute paths are rejected.
///
/// - `/` is passed through unchanged (engine special case: list mounts).
/// - `/workspace` → `@alias`; `/workspace/rel/path` → `@alias/rel/path`.
/// - Trailing slashes are preserved so the engine's existing validation
///   applies unchanged (read tolerates one, the other tools reject it).
/// - `.` and `..` are normalized, but traversal above `/workspace` is rejected.
/// - Remaining malformed segments are also checked by the filesystem engine.
String parseModelPath(
  String raw,
  String alias, {
  String workingDirectory = '/workspace',
}) {
  try {
    final resolved = resolveWorkspaceGuestPath(
      raw,
      baseDirectory: workingDirectory,
      preserveTrailingSlash: true,
    );
    if (resolved == '/') return '/';
    if (resolved == '/workspace') return '@$alias';
    return '@$alias/${resolved.substring('/workspace/'.length)}';
  } on WorkspacePathException catch (e) {
    throw ModelPathException('Invalid path: ${e.message}');
  }
}

/// Canonical wire path → model-facing `/workspace/...` form.
///
/// Only the bound workspace alias is presented as `/workspace`; anything
/// else (other mounts, already-presented paths) is returned unchanged.
String presentWirePath(String wirePath, String alias) {
  final prefix = '@$alias';
  if (wirePath == prefix) return '/workspace';
  if (wirePath.startsWith('$prefix/')) {
    return '/workspace/${wirePath.substring(prefix.length + 1)}';
  }
  return wirePath;
}

/// Rewrites tool-definition copy (model-visible text only) to the
/// `/workspace` vocabulary. Tool definitions are static presentation text —
/// no file content flows through here.
String presentDefText(String text) {
  return text
      .replaceAll('@default/', '/workspace/')
      .replaceAll('@default', '/workspace')
      .replaceAll('@alias/rel/path', '/workspace/rel/path')
      .replaceAll('Mount-relative', 'Workspace-relative')
      .replaceAll('mount-relative', 'workspace-relative');
}

/// Rewrites every string inside a tool-definition map (description /
/// inputSchema) with [presentDefText].
Map<String, dynamic> presentDefMap(Map<String, dynamic> def) {
  Map<String, dynamic> rewrite(Map<String, dynamic> m) => {
    for (final e in m.entries)
      e.key: e.value is Map
          ? rewrite((e.value as Map).cast<String, dynamic>())
          : e.value is String
          ? presentDefText(e.value as String)
          : e.value,
  };
  return rewrite(def);
}
