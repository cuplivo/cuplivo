import 'package:flutter/foundation.dart';

/// View models for the DeepSeek Harness home surface.
///
/// These are plain immutable values: the server owns every session, workspace
/// and transcript, so nothing here is persisted and every field is a projection
/// of one catalog read. The home widgets render these directly, which keeps the
/// catalog seam (`harness_session_catalog.dart`) free of network types.

/// One remote session row in the sidebar.
@immutable
class HarnessSessionSummary {
  const HarnessSessionSummary({
    required this.sessionId,
    this.title,
    this.updatedAt,
    this.running = false,
    this.blank = false,
    this.pinned = false,
    this.workspaceId,
  });

  /// The Host's session id; never converted to a Cuplivo id.
  final String sessionId;

  /// The `title` projection; null/empty on a session the Host has not titled
  /// yet (the sidebar then shows the localized `新会话`).
  final String? title;

  final DateTime? updatedAt;

  /// A turn is executing on the Host (the row shows a running dot).
  final bool running;

  /// The Host marks a session with no user prompt yet as blank.
  final bool blank;

  /// The Host pinned this session inside its workspace
  /// (`workspace.pinSession`), which is a workspace-order property, not a
  /// session field.
  final bool pinned;

  /// Owning workspace id when the Host groups this session under one.
  final String? workspaceId;

  /// Trimmed title, or null when there is nothing to show.
  String? get trimmedTitle {
    final value = (title ?? '').trim();
    return value.isEmpty ? null : value;
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is HarnessSessionSummary &&
          other.sessionId == sessionId &&
          other.title == title &&
          other.updatedAt == updatedAt &&
          other.running == running &&
          other.blank == blank &&
          other.pinned == pinned &&
          other.workspaceId == workspaceId;

  @override
  int get hashCode => Object.hash(
    sessionId,
    title,
    updatedAt,
    running,
    blank,
    pinned,
    workspaceId,
  );

  @override
  String toString() => 'HarnessSessionSummary($sessionId)';
}

/// One workspace section: a Host-registered directory and its sessions.
@immutable
class HarnessWorkspaceGroup {
  const HarnessWorkspaceGroup({
    required this.workspaceId,
    required this.title,
    this.sessions = const <HarnessSessionSummary>[],
  });

  /// The Host's workspace id (a catalog key, never a Cuplivo Workspace id).
  final String workspaceId;

  /// The Host's title for the workspace; may be empty (the UI falls back to the
  /// localized default-workspace label).
  final String title;

  /// Sessions assigned to this workspace, newest first.
  final List<HarnessSessionSummary> sessions;

  String get displayTitle => title.trim();

  HarnessWorkspaceGroup copyWith({
    String? workspaceId,
    String? title,
    List<HarnessSessionSummary>? sessions,
  }) {
    return HarnessWorkspaceGroup(
      workspaceId: workspaceId ?? this.workspaceId,
      title: title ?? this.title,
      sessions: sessions ?? this.sessions,
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is HarnessWorkspaceGroup &&
          other.workspaceId == workspaceId &&
          other.title == title &&
          listEquals(other.sessions, sessions);

  @override
  int get hashCode => Object.hash(workspaceId, title, Object.hashAll(sessions));

  @override
  String toString() =>
      'HarnessWorkspaceGroup($workspaceId, ${sessions.length} sessions)';
}

/// What the connected Host lets the home surface do.
///
/// Capability parity: a control is rendered only when the Host serves it. The
/// initial shape mirrors DSH 0.2.2-rc.1 (`create/rename/pin/archive/fork`; there
/// is no delete-session RPC, only archive), and a later catalog adapter flips a
/// flag on as the Host exposes more.
@immutable
class HarnessSessionCapabilities {
  const HarnessSessionCapabilities({
    this.create = false,
    this.rename = false,
    this.pin = false,
    this.archive = false,
    this.fork = false,
    this.delete = false,
  });

  final bool create;
  final bool rename;
  final bool pin;
  final bool archive;
  final bool fork;
  final bool delete;

  /// The state the foundation slice ships before a live protocol adapter is
  /// wired: every session control stays hidden.
  static const HarnessSessionCapabilities none = HarnessSessionCapabilities();

  /// The capabilities DSH 0.2.2-rc.1 actually serves through a connected host.
  static const HarnessSessionCapabilities dsh022 = HarnessSessionCapabilities(
    create: true,
    rename: true,
    pin: true,
    archive: true,
    fork: true,
  );

  bool get hasAnySessionAction => rename || pin || archive || fork || delete;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is HarnessSessionCapabilities &&
          other.create == create &&
          other.rename == rename &&
          other.pin == pin &&
          other.archive == archive &&
          other.fork == fork &&
          other.delete == delete;

  @override
  int get hashCode => Object.hash(create, rename, pin, archive, fork, delete);
}

// ---------------------------------------------------------------------------
// Workspace files (right rail 工作区文件)
// ---------------------------------------------------------------------------

/// The kind of a workspace-file entry. The rail only browses read-only, so the
/// only distinction it needs is "enterable directory" vs "previewable file".
enum HarnessFileKind { directory, file }

/// One entry of a `workspaceFiles/list` answer.
@immutable
class HarnessWorkspaceFileEntry {
  const HarnessWorkspaceFileEntry({
    required this.name,
    required this.path,
    required this.kind,
    this.size,
  });

  final String name;

  /// Path relative to the session's workspace root, exactly as the Host
  /// reports it (the rail never normalizes Host paths).
  final String path;

  final HarnessFileKind kind;
  final int? size;

  bool get isDirectory => kind == HarnessFileKind.directory;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is HarnessWorkspaceFileEntry &&
          other.name == name &&
          other.path == path &&
          other.kind == kind &&
          other.size == size;

  @override
  int get hashCode => Object.hash(name, path, kind, size);

  @override
  String toString() => 'HarnessWorkspaceFileEntry($path)';
}

/// One directory listing plus its parent path (null at the workspace root).
@immutable
class HarnessWorkspaceFileListing {
  const HarnessWorkspaceFileListing({
    required this.path,
    required this.entries,
    this.parentPath,
  });

  /// The listed path, relative to the workspace root ('' is the root).
  final String path;

  final List<HarnessWorkspaceFileEntry> entries;

  /// Parent path, or null when [path] is the workspace root.
  final String? parentPath;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is HarnessWorkspaceFileListing &&
          other.path == path &&
          other.parentPath == parentPath &&
          listEquals(other.entries, entries);

  @override
  int get hashCode => Object.hash(path, parentPath, Object.hashAll(entries));
}

/// One text page of a workspace file. The rail previews text only; binary
/// files report [isText] false and are not previewed.
@immutable
class HarnessWorkspaceFileText {
  const HarnessWorkspaceFileText({
    required this.path,
    required this.text,
    this.truncated = false,
  });

  final String path;
  final String text;

  /// The Host returned a page, not the whole file.
  final bool truncated;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is HarnessWorkspaceFileText &&
          other.path == path &&
          other.text == text &&
          other.truncated == truncated;

  @override
  int get hashCode => Object.hash(path, text, truncated);
}
