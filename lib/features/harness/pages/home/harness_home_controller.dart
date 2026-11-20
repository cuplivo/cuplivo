import 'package:flutter/foundation.dart';

import '../../models/dsh_remote.dart';
import '../../services/dsh_surface_harvest.dart';
import 'harness_home_models.dart';
import 'harness_session_catalog.dart';

/// The page the right rail is showing.
///
/// R7's official tool cards navigate between the built-in instances below; the
/// Start page is the home of that navigation. The selector is an id-carrying
/// value instead of an enum so a future plugin panel (or a deep link) can name
/// a page without adding a member here — the same reason the settings tabs are
/// id-based. A plugin's own card opens the official WebUI page rather than a
/// rail page (the rail never embeds the WebUI, see the v2 reuse map §4), so
/// [plugin] pages are a routing seam, not another native surface.
@immutable
class HarnessRailPage {
  const HarnessRailPage._(this.id, this.label);

  /// Stable page id; `plugin:<entry id>` for a plugin-contributed page.
  final String id;

  /// Header title for pages Cuplivo cannot name statically (null falls back to
  /// the localized built-in title).
  final String? label;

  static const HarnessRailPage start = HarnessRailPage._('start', null);
  static const HarnessRailPage workspaceFiles = HarnessRailPage._(
    'workspaceFiles',
    null,
  );
  static const HarnessRailPage terminal = HarnessRailPage._('terminal', null);
  static const HarnessRailPage moreTools = HarnessRailPage._('moreTools', null);

  /// A page contributed by the remote (a harvested plugin rail card).
  ///
  /// The rail's card for a plugin still opens the full official WebUI page; a
  /// caller may pass this instance through the rail's generic page navigation
  /// instead of a native page when a future surface wants that.
  static HarnessRailPage plugin(String pluginId, {String? label}) =>
      HarnessRailPage._('plugin:${pluginId.trim()}', label?.trim());

  @override
  bool operator ==(Object other) =>
      identical(this, other) || other is HarnessRailPage && other.id == id;

  @override
  int get hashCode => id.hashCode;

  @override
  String toString() => 'HarnessRailPage($id)';
}

/// The home surface's state for one remote: the open session and the right
/// rail.
///
/// The local `HomePageController` owns local conversations and local models;
/// this controller owns nothing of that. It holds the two pieces of *remote
/// navigation* the home scaffold needs — which server session is on screen and
/// whether the rail is open — so the existing layouts can be driven without
/// teaching them DSH concepts.
///
/// The catalog is passed in and its lifetime is owned by the caller (the state
/// layer's adapter, which outlives a page rebuild): this controller only
/// listens to it and forwards intents.
class HarnessHomeController extends ChangeNotifier {
  HarnessHomeController({
    required this.remote,
    required this._catalog,
    this._workspaceFilesForSession,
    DshSurfaceInventory? surfaceInventory,
  }) : // Public injection name intentionally omits the private-field prefix.
       // ignore: prefer_initializing_formals
       _surfaceInventory = surfaceInventory {
    _catalog.addListener(_onCatalogChanged);
    _surfaceInventory?.addListener(_onCatalogChanged);
  }

  final DshRemote remote;
  final HarnessSessionCatalog _catalog;
  final HarnessWorkspaceFiles Function(String sessionId)?
  _workspaceFilesForSession;

  /// The injected official-WebUI harvest inventory (one per home state); null
  /// keeps the surfaces on the DSH built-ins only.
  final DshSurfaceInventory? _surfaceInventory;

  String? _selectedSessionId;
  bool _railOpen = false;
  bool _railExpanded = false;
  HarnessRailPage _railPage = HarnessRailPage.start;

  HarnessSessionCatalog get catalog => _catalog;

  /// The latest official-WebUI surface snapshot for this remote's authority.
  ///
  /// Empty until a remote page is opened once and its harvest posts back; the
  /// surfaces then render the harvested labels natively. One snapshot per
  /// authority, shared by R5 and R7.
  DshSurfaceSnapshot get surfaceSnapshot =>
      _surfaceInventory?.snapshotFor(remote.authority) ??
      DshSurfaceSnapshot.empty;

  /// Official sidebar rows for R5, in official order (empty pre-harvest).
  ///
  /// The labels only; 更多 is a `PanelMoreMenu`, not a panellist row, so it is
  /// not here and R5 always appends its built-in 更多 row.
  List<DshSurfaceEntry> get harvestedSidebarEntries => surfaceSnapshot.sidebar;

  /// Official right-rail entries for R7, in official order (empty pre-harvest).
  ///
  /// Carries the language-neutral page kind (e.g. `bw-diff`), which the rail
  /// landing script prefers over the visible label. The rail's built-in cards
  /// are filtered out at the call site, which owns their localized labels.
  List<DshSurfaceEntry> get harvestedRailEntries => surfaceSnapshot.rail;

  /// Read-only workspace file access for the rail, rooted at the open session;
  /// null before a session is open or when this build has no file API wired.
  HarnessWorkspaceFiles? get workspaceFiles {
    final id = _selectedSessionId;
    if (id == null) return null;
    return _workspaceFilesForSession?.call(id);
  }

  /// True when the remote's session catalog can be read.
  bool get isCatalogAvailable => _catalog.isAvailable;

  String? get selectedSessionId => _selectedSessionId;

  bool get railOpen => _railOpen;
  bool get railExpanded => _railExpanded;
  HarnessRailPage get railPage => _railPage;

  /// The selected session's summary, when the catalog currently lists it.
  HarnessSessionSummary? get selectedSession {
    final id = _selectedSessionId;
    if (id == null) return null;
    for (final group in _catalog.workspaces) {
      for (final session in group.sessions) {
        if (session.sessionId == id) return session;
      }
    }
    for (final session in _catalog.ungroupedSessions) {
      if (session.sessionId == id) return session;
    }
    return null;
  }

  HarnessWorkspaceGroup? workspaceForSession(String sessionId) {
    for (final group in _catalog.workspaces) {
      if (group.sessions.any((session) => session.sessionId == sessionId)) {
        return group;
      }
    }
    return null;
  }

  /// Opens a session the sidebar listed. Selecting the already-open session is
  /// a no-op so a tap does not rebuild the conversation.
  void selectSession(String sessionId) {
    if (sessionId == _selectedSessionId) return;
    _selectedSessionId = sessionId;
    notifyListeners();
  }

  /// Creates a session through the catalog and selects it.
  ///
  /// Returns the Host's new session id, or null when the Host did not report
  /// one. Throws [HarnessCatalogException] when the create was refused; the
  /// caller renders that with a snackbar and keeps the current session.
  Future<String?> startNewSession({String? workspaceId}) async {
    final id = await _catalog.createSession(workspaceId: workspaceId);
    if (id == null) return null;
    _selectedSessionId = id;
    notifyListeners();
    return id;
  }

  /// Drops the open session (the host keeps it); used when a session vanishes
  /// from the catalog.
  void clearSelectedSession() {
    if (_selectedSessionId == null) return;
    _selectedSessionId = null;
    notifyListeners();
  }

  Future<void> refreshCatalog() => _catalog.refresh();

  // --- Right rail ----------------------------------------------------------

  void openRail({HarnessRailPage page = HarnessRailPage.start}) {
    final changed = !_railOpen || _railPage != page;
    _railOpen = true;
    _railPage = page;
    if (changed) notifyListeners();
  }

  void closeRail() {
    if (!_railOpen && !_railExpanded) return;
    _railOpen = false;
    _railExpanded = false;
    notifyListeners();
  }

  void toggleRail() => _railOpen ? closeRail() : openRail();

  void showRailPage(HarnessRailPage page) {
    if (_railOpen && _railPage == page) return;
    _railOpen = true;
    _railPage = page;
    notifyListeners();
  }

  void showRailStart() => showRailPage(HarnessRailPage.start);

  /// The rail's expand action: a docked rail asks the host for the whole width
  /// (the conversation moves off-screen), an expanded one docks again.
  void setRailExpanded(bool value) {
    if (value) {
      if (_railOpen && _railExpanded) return;
      _railOpen = true;
      _railExpanded = true;
    } else {
      if (!_railOpen && !_railExpanded) return;
      _railExpanded = false;
    }
    notifyListeners();
  }

  void toggleRailExpanded() => setRailExpanded(!_railExpanded);

  /// A catalog read (sessions/workspaces/mutations) redraws the drawer and the
  /// rail even when the link status did not change.
  void _onCatalogChanged() => notifyListeners();

  @override
  void dispose() {
    // The catalog belongs to the state layer (one per remote), so this
    // controller detaches from it but never disposes it.
    _catalog.removeListener(_onCatalogChanged);
    _surfaceInventory?.removeListener(_onCatalogChanged);
    super.dispose();
  }
}
