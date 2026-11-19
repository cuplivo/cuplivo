import 'package:flutter/foundation.dart';

import '../../models/dsh_remote.dart';
import 'harness_home_models.dart';
import 'harness_session_catalog.dart';

/// The page the right rail is showing.
///
/// R7's official tool cards are rail pages; the rail's Start page is the home
/// of this navigation. Plugin-contributed panels are added by the chat slice
/// later and do not belong to this enum (they render in a WebView page).
enum HarnessRailPage { start, workspaceFiles, terminal, moreTools }

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
    required HarnessSessionCatalog catalog,
    HarnessWorkspaceFiles Function(String sessionId)? workspaceFilesForSession,
  }) : _catalog = catalog,
       _workspaceFilesForSession = workspaceFilesForSession;

  final DshRemote remote;
  final HarnessSessionCatalog _catalog;
  final HarnessWorkspaceFiles Function(String sessionId)?
  _workspaceFilesForSession;

  String? _selectedSessionId;
  bool _railOpen = false;
  bool _railExpanded = false;
  HarnessRailPage _railPage = HarnessRailPage.start;

  HarnessSessionCatalog get catalog => _catalog;

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

  @override
  void dispose() {
    // The catalog belongs to the state layer (one per remote, shared with the
    // chat slice), so this controller never disposes it.
    super.dispose();
  }
}
