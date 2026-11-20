import 'package:flutter/foundation.dart';

import 'package:Cuplivo/features/harness/controllers/dsh_chat_session.dart';
import 'package:Cuplivo/features/harness/models/dsh_remote.dart';

/// Creates the chat controller for one (remote, session) pair.
///
/// Stage 2 binds this to the real `DshGateway`/session handle; tests provide a
/// fake factory. The view never builds a client itself.
typedef DshChatSessionFactory =
    DshChatSession Function(DshRemote remote, String sessionId);

/// Owns the open chat controllers, one per (remote, session).
///
/// A controller is created on first use and kept until the home slice switches
/// away from that session (`release`). The provider is registered once in
/// `main.dart`, so the chat view can resolve its controller from `remote` +
/// `sessionId` alone — the embed contract the home slice codes to.
///
/// The provider also relays each open session's notifications, which is how the
/// home slice's app bar watches one session's title/model/running state without
/// owning the controller: `context.watch<DshChatControllersProvider>()` then
/// `viewState(remoteId, sessionId)`.
class DshChatControllersProvider extends ChangeNotifier {
  DshChatControllersProvider(this._factory);

  final DshChatSessionFactory _factory;
  final Map<String, DshChatSession> _sessions = <String, DshChatSession>{};

  /// Cache key: a remote may expose the same session id only within itself.
  static String keyFor(DshRemote remote, String sessionId) =>
      keyForIds(remote.id, sessionId);

  static String keyForIds(String remoteId, String sessionId) =>
      '$remoteId\u0000$sessionId';

  /// The controller for this session, created on first use.
  DshChatSession sessionFor(DshRemote remote, String sessionId) {
    final key = keyFor(remote, sessionId);
    final existing = _sessions[key];
    if (existing != null) return existing;
    final created = _factory(remote, sessionId);
    _sessions[key] = created;
    created.addListener(_handleSessionChanged);
    notifyListeners();
    return created;
  }

  /// The controller when one is already open, without creating it.
  DshChatSession? peek(DshRemote remote, String sessionId) =>
      _sessions[keyFor(remote, sessionId)];

  /// The latest frame of one open session.
  ///
  /// Returns an empty state when the session is not open yet, so a caller that
  /// watches this provider can paint the app bar before the chat view mounts.
  DshChatViewState viewState(String remoteId, String sessionId) =>
      _sessions[keyForIds(remoteId, sessionId)]?.state ??
      const DshChatViewState();

  /// Drops and disposes one controller; the home slice calls this when it
  /// truly leaves a session (switching sessions, disconnecting the remote).
  void release(DshRemote remote, String sessionId) {
    final key = keyFor(remote, sessionId);
    final removed = _sessions.remove(key);
    if (removed == null) return;
    removed.removeListener(_handleSessionChanged);
    removed.dispose();
    notifyListeners();
  }

  /// Disposes every controller of one remote (its connection went away).
  void releaseRemote(DshRemote remote) {
    final prefix = '${remote.id}\u0000';
    final keys = _sessions.keys.where((key) => key.startsWith(prefix)).toList();
    if (keys.isEmpty) return;
    for (final key in keys) {
      final session = _sessions.remove(key);
      if (session == null) continue;
      session.removeListener(_handleSessionChanged);
      session.dispose();
    }
    notifyListeners();
  }

  /// Closes every open controller (app shutdown, tests).
  void releaseAll() {
    if (_sessions.isEmpty) return;
    final sessions = _sessions.values.toList();
    _sessions.clear();
    for (final session in sessions) {
      session.removeListener(_handleSessionChanged);
      session.dispose();
    }
    notifyListeners();
  }

  void _handleSessionChanged() {
    notifyListeners();
  }

  @visibleForTesting
  int get openSessionCount => _sessions.length;

  @override
  void dispose() {
    for (final session in _sessions.values) {
      session.removeListener(_handleSessionChanged);
      session.dispose();
    }
    _sessions.clear();
    super.dispose();
  }
}
