import 'package:flutter/foundation.dart';

import 'harness_home_models.dart';

/// A user-actionable failure from the remote catalog.
///
/// The seam never carries protocol or transport types across itself: the
/// adapter that implements it over `DshGateway` maps a `DshGatewayException`
/// into this class, and the home surface renders one localized sentence plus
/// retry. [cause] stays for logs only.
class HarnessCatalogException implements Exception {
  const HarnessCatalogException({this.cause, this.userMessage});

  /// The technical cause (a gateway/protocol exception), for logs.
  final Object? cause;

  /// Host-supplied, already user-readable text when the server sent one.
  final String? userMessage;

  @override
  String toString() =>
      'HarnessCatalogException(${userMessage ?? cause ?? 'unknown'})';
}

/// The remote session/workspace catalog the home surface renders.
///
/// One decision one implementation: the sidebar and the rail both read this
/// interface, and the adapter over `DshGateway` is the only writer of its
/// values. The surface binds to it as a [Listenable], so a live `session/list`
/// change repaints the drawer without a second state store.
///
/// Capability parity is part of the contract: a surface renders a control only
/// when the matching [HarnessSessionCapabilities] flag is true. An
/// implementation that cannot reach the Host reports [isAvailable] false and
/// the UI shows an honest unavailable state instead of pretending to work.
abstract class HarnessSessionCatalog extends ChangeNotifier {
  /// False until a remote catalog is wired and readable (the foundation slice
  /// ships no protocol adapter, so this is false there).
  bool get isAvailable;

  /// A read is in flight. The home surface keeps the previous rows visible
  /// while it is true; only a first load shows the skeleton.
  bool get isLoading;

  /// The failure of the last read/mutation, cleared by the next success.
  HarnessCatalogException? get error;

  HarnessSessionCapabilities get capabilities;

  /// Workspace sections, in the Host's workspace order.
  List<HarnessWorkspaceGroup> get workspaces;

  /// Sessions the Host did not assign to a workspace, newest first.
  List<HarnessSessionSummary> get ungroupedSessions;

  /// No workspace and no session at all.
  bool get isEmpty;

  /// Re-reads `session.list` + the workspace baseline.
  Future<void> refresh();

  /// Creates a session, optionally inside [workspaceId], and returns its id.
  Future<String?> createSession({String? workspaceId});

  Future<void> renameSession(String sessionId, String title);

  Future<void> setPinned(String sessionId, bool pinned);

  Future<void> archiveSession(String sessionId);

  /// Forks [sessionId] and returns the new session's id.
  Future<String?> forkSession(String sessionId);

  /// Only rendered when [HarnessSessionCapabilities.delete] is true; DSH
  /// 0.2.2-rc.1 serves archive instead, so this is hidden in practice.
  Future<void> deleteSession(String sessionId);
}

/// The honest state before a protocol adapter is wired.
///
/// Every read is empty and every mutation refuses with
/// [HarnessCatalogException], so no control that depends on the remote can be
/// enabled by accident.
class HarnessUnavailableSessionCatalog extends HarnessSessionCatalog {
  HarnessUnavailableSessionCatalog({this.explanation});

  /// Optional technical note for the unavailable state (never rendered raw).
  final String? explanation;

  HarnessCatalogException get _refused => HarnessCatalogException(
    cause: explanation ?? 'remote session catalog is not wired',
  );

  @override
  bool get isAvailable => false;

  @override
  bool get isLoading => false;

  @override
  HarnessCatalogException? get error => null;

  @override
  HarnessSessionCapabilities get capabilities =>
      HarnessSessionCapabilities.none;

  @override
  List<HarnessWorkspaceGroup> get workspaces => const <HarnessWorkspaceGroup>[];

  @override
  List<HarnessSessionSummary> get ungroupedSessions =>
      const <HarnessSessionSummary>[];

  @override
  bool get isEmpty => true;

  @override
  Future<void> refresh() async {}

  @override
  Future<String?> createSession({String? workspaceId}) async => throw _refused;

  @override
  Future<void> renameSession(String sessionId, String title) async =>
      throw _refused;

  @override
  Future<void> setPinned(String sessionId, bool pinned) async => throw _refused;

  @override
  Future<void> archiveSession(String sessionId) async => throw _refused;

  @override
  Future<String?> forkSession(String sessionId) async => throw _refused;

  @override
  Future<void> deleteSession(String sessionId) async => throw _refused;
}

/// Read-only `workspaceFiles/*` access for the right rail's 工作区文件 page.
///
/// Scoped to one session: the Host roots file access at the session's
/// workspace, so there is no other identifier to carry. Null means the build
/// has no file API wired and the rail renders the honest unavailable state.
abstract interface class HarnessWorkspaceFiles {
  /// Lists one directory. [path] is '' for the workspace root.
  Future<HarnessWorkspaceFileListing> list(String path);

  /// Reads a text file (the rail previews text; binary files are not opened).
  Future<HarnessWorkspaceFileText> readText(String path);

  /// Reads bytes for an image preview.
  Future<Uint8List> readBytes(String path);
}
