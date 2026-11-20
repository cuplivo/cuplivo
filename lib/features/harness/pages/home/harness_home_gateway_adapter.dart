import 'dart:typed_data';

import '../../state/dsh_connections_provider.dart';
import '../../state/dsh_gateway.dart';
import 'harness_home_models.dart';
import 'harness_session_catalog.dart';

/// Adapts the DSH state layer to the home surface's narrow seams.
///
/// `DshConnectionsProvider` is the single live reader of a remote's catalog and
/// the single owner of its gateway; this adapter only projects that state into
/// the immutable view models the sidebar and rail render, and forwards user
/// intents to the gateway the provider already owns. Nothing here persists or
/// caches beyond the last projection.
///
/// Capability parity: the drawer's session controls are enabled from what the
/// gateway contract actually serves. DSH 0.2.2-rc.1 has no delete-session RPC
/// (archive only) and the gateway exposes no fork action, so both stay hidden
/// even on a ready link.
class DshHarnessSessionCatalog extends HarnessSessionCatalog {
  DshHarnessSessionCatalog({
    required this.connections,
    required this.remoteId,
  }) {
    connections.addListener(_onConnectionsChanged);
    _rebuild();
  }

  final DshConnectionsProvider connections;
  final String remoteId;

  List<HarnessWorkspaceGroup> _workspaces = const <HarnessWorkspaceGroup>[];
  List<HarnessSessionSummary> _ungrouped = const <HarnessSessionSummary>[];
  bool _available = false;
  bool _loading = false;
  HarnessCatalogException? _error;
  HarnessSessionCapabilities _capabilities = HarnessSessionCapabilities.none;
  bool _disposed = false;

  @override
  bool get isAvailable => _available;

  @override
  bool get isLoading => _loading;

  @override
  HarnessCatalogException? get error => _error;

  @override
  HarnessSessionCapabilities get capabilities => _capabilities;

  @override
  List<HarnessWorkspaceGroup> get workspaces => _workspaces;

  @override
  List<HarnessSessionSummary> get ungroupedSessions => _ungrouped;

  @override
  bool get isEmpty =>
      _workspaces.every((group) => group.sessions.isEmpty) &&
      _ungrouped.isEmpty;

  DshGateway? get _gateway => connections.gatewayFor(remoteId);

  @override
  Future<void> refresh() async {
    try {
      await connections.refreshCatalog(remoteId);
    } on DshGatewayException catch (error) {
      throw HarnessCatalogException(cause: error);
    }
  }

  @override
  Future<String?> createSession({String? workspaceId}) async {
    final gateway = _requireGateway();
    try {
      final session = await gateway.createSession(workspaceId: workspaceId);
      _mergeCreatedSession(session, workspaceId);
      return session.id;
    } on DshGatewayException catch (error) {
      throw HarnessCatalogException(cause: error);
    }
  }

  /// Inserts a just-created row locally so the drawer does not look like the
  /// create failed while the Host's catalog projection catches up. The next
  /// read of the remote replaces this list with the authoritative ordering.
  void _mergeCreatedSession(
    DshSessionSummary session,
    String? requestedWorkspaceId,
  ) {
    final workspaceId = session.workspaceId ?? requestedWorkspaceId;
    final summary = HarnessSessionSummary(
      sessionId: session.id,
      title: session.title,
      updatedAt: session.updatedAt,
      running: session.running,
      pinned: session.pinned,
      workspaceId: workspaceId,
    );
    if (workspaceId == null) {
      _ungrouped = <HarnessSessionSummary>[summary, ..._ungrouped];
      _available = true;
      notifyListeners();
      return;
    }
    final groups = <HarnessWorkspaceGroup>[];
    var found = false;
    for (final group in _workspaces) {
      if (group.workspaceId != workspaceId) {
        groups.add(group);
        continue;
      }
      found = true;
      groups.add(
        group.copyWith(
          sessions: <HarnessSessionSummary>[summary, ...group.sessions],
        ),
      );
    }
    if (!found) {
      groups.add(
        HarnessWorkspaceGroup(
          workspaceId: workspaceId,
          title: '',
          sessions: <HarnessSessionSummary>[summary],
        ),
      );
    }
    _workspaces = groups;
    _available = true;
    notifyListeners();
  }

  @override
  Future<void> renameSession(String sessionId, String title) async {
    final gateway = _requireGateway();
    try {
      await gateway.renameSession(sessionId, title);
    } on DshGatewayException catch (error) {
      throw HarnessCatalogException(cause: error);
    }
  }

  @override
  Future<void> setPinned(String sessionId, bool pinned) async {
    final gateway = _requireGateway();
    try {
      await gateway.setSessionPinned(sessionId, pinned: pinned);
    } on DshGatewayException catch (error) {
      throw HarnessCatalogException(cause: error);
    }
  }

  @override
  Future<void> archiveSession(String sessionId) async {
    final gateway = _requireGateway();
    try {
      await gateway.setSessionArchived(sessionId, archived: true);
    } on DshGatewayException catch (error) {
      throw HarnessCatalogException(cause: error);
    }
  }

  /// The gateway exposes no fork action today; the sidebar therefore never
  /// offers it. Kept as a refusal so a future control cannot silently no-op.
  @override
  Future<String?> forkSession(String sessionId) async =>
      throw const HarnessCatalogException(
        userMessage: 'session fork is not exposed by this DeepSeek Harness',
      );

  /// DSH has no delete-session RPC; the sidebar hides the action from
  /// [HarnessSessionCapabilities.delete].
  @override
  Future<void> deleteSession(String sessionId) async =>
      throw const HarnessCatalogException(
        userMessage: 'this DeepSeek Harness has no delete-session operation',
      );

  DshGateway _requireGateway() {
    final gateway = _gateway;
    if (gateway == null) {
      throw const HarnessCatalogException(cause: DshFailure.notConfigured);
    }
    return gateway;
  }

  void _onConnectionsChanged() {
    if (_disposed) return;
    _rebuild();
    notifyListeners();
  }

  void _rebuild() {
    final status = connections.linkStatus(remoteId);
    final catalog = connections.catalogFor(remoteId);
    _available = status.isReady && catalog != null;
    _loading = status.isConnecting || (status.isReady && catalog == null);
    _error = _failureFor(status, catalog);
    _capabilities = _available
        ? const HarnessSessionCapabilities(
            create: true,
            rename: true,
            pin: true,
            archive: true,
          )
        : HarnessSessionCapabilities.none;
    if (catalog == null) {
      _workspaces = const <HarnessWorkspaceGroup>[];
      _ungrouped = const <HarnessSessionSummary>[];
      return;
    }
    _workspaces = [
      for (final workspace in catalog.workspaces)
        HarnessWorkspaceGroup(
          workspaceId: workspace.id,
          title: workspace.title,
          sessions: [
            for (final session in workspace.sessions) _session(session),
          ],
        ),
    ];
    _ungrouped = [
      for (final session in catalog.ungroupedSessions) _session(session),
    ];
  }

  HarnessSessionSummary _session(DshSessionSummary session) {
    return HarnessSessionSummary(
      sessionId: session.id,
      title: session.title,
      updatedAt: session.updatedAt,
      running: session.running,
      blank: session.title.trim().isEmpty,
      pinned: session.pinned,
      workspaceId: session.workspaceId,
    );
  }

  HarnessCatalogException? _failureFor(
    DshLinkStatus status,
    DshCatalogSnapshot? catalog,
  ) {
    if (status.isFailed) {
      return HarnessCatalogException(
        cause: status.failure ?? DshFailure.unknown,
      );
    }
    if (catalog == null) return null;
    for (final failure in catalog.failures) {
      if (failure.section == DshCatalogSection.workspaces) {
        return HarnessCatalogException(cause: failure.failure);
      }
    }
    // The workspaces capability decides whether the sidebar can group at all;
    // without it the ungrouped list is still rendered.
    return null;
  }

  @override
  void dispose() {
    _disposed = true;
    connections.removeListener(_onConnectionsChanged);
    super.dispose();
  }
}

/// Adapts the gateway's workspace-file reads to the rail's file seam, scoped to
/// one open session.
class DshHarnessWorkspaceFiles implements HarnessWorkspaceFiles {
  const DshHarnessWorkspaceFiles({
    required this.connections,
    required this.remoteId,
    required this.sessionId,
  });

  final DshConnectionsProvider connections;
  final String remoteId;
  final String sessionId;

  DshGateway _requireGateway() {
    final gateway = connections.gatewayFor(remoteId);
    if (gateway == null) {
      throw const HarnessCatalogException(cause: DshFailure.notConfigured);
    }
    return gateway;
  }

  @override
  Future<HarnessWorkspaceFileListing> list(String path) async {
    final gateway = _requireGateway();
    try {
      final entries = await gateway.listFiles(sessionId, path);
      return HarnessWorkspaceFileListing(
        path: path,
        parentPath: _parentOf(path),
        entries: [
          for (final entry in entries)
            HarnessWorkspaceFileEntry(
              name: entry.name,
              path: entry.path,
              kind: entry.isDirectory
                  ? HarnessFileKind.directory
                  : HarnessFileKind.file,
              size: entry.size,
            ),
        ],
      );
    } on DshGatewayException catch (error) {
      throw HarnessCatalogException(cause: error);
    }
  }

  @override
  Future<HarnessWorkspaceFileText> readText(String path) async {
    final gateway = _requireGateway();
    try {
      final text = await gateway.readTextFile(sessionId, path);
      return HarnessWorkspaceFileText(path: path, text: text);
    } on DshGatewayException catch (error) {
      throw HarnessCatalogException(cause: error);
    }
  }

  @override
  Future<Uint8List> readBytes(String path) async {
    final gateway = _requireGateway();
    try {
      final bytes = await gateway.readFileBytes(sessionId, path);
      return Uint8List.fromList(bytes);
    } on DshGatewayException catch (error) {
      throw HarnessCatalogException(cause: error);
    }
  }

  /// `''` is the workspace root; `/`-separated paths mirror the Host's.
  static String? _parentOf(String path) {
    if (path.isEmpty) return null;
    final trimmed = path.endsWith('/')
        ? path.substring(0, path.length - 1)
        : path;
    final slash = trimmed.lastIndexOf('/');
    return slash <= 0 ? '' : trimmed.substring(0, slash);
  }
}
