import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:uuid/uuid.dart';

import '../../../core/providers/chat_owners_provider.dart';
import '../models/dsh_provider_settings.dart';
import '../models/dsh_remote.dart';
import '../models/dsh_web_ui_link.dart';
import '../services/dsh_credential_store.dart';
import '../services/dsh_remote_store.dart';
import 'dsh_gateway.dart';

/// All remote DeepSeek Harness records this device knows, and the live link of
/// each one.
///
/// This is the single writer of [DshRemoteStore] and of the secure-store
/// cookie entries, exactly like `ChatOwnersProvider` is the single writer of
/// the shared owner order: the creation form, the assistant settings page and
/// the later home/chat slices all go through this provider instead of touching
/// persistence themselves. Later slices read remote data through [catalogFor],
/// [sessionControlsFor], [gatewayFor] and [openSession]; they never construct a
/// gateway, so "one live link per remote" holds.
///
/// It also implements [HarnessOwnerSource], the narrow seam that lets the
/// shared owner list order remote owners without `lib/core` importing the DSH
/// feature. A remote is listed under `harness:<id>` keys in the same
/// `chat_owner_order_v1` list as assistants and groups.
///
/// The gateway factory is injected (`main.dart` passes the adapter over
/// `lib/core/dsh/`); without one, connecting fails with
/// [DshFailure.notConfigured] instead of pretending to work. Everything else —
/// create, rename, delete, the owner order, the cookie reference — works
/// without a live protocol adapter.
class DshConnectionsProvider extends ChangeNotifier
    implements HarnessOwnerSource {
  DshConnectionsProvider({
    required this._store,
    required this._credentials,
    this._gatewayFactory,
  }) {
    loaded = _load();
  }

  static const Uuid _uuid = Uuid();

  final DshRemoteStore _store;
  final DshCredentialStore _credentials;
  final DshGatewayFactory? _gatewayFactory;

  final List<DshRemote> _remotes = <DshRemote>[];
  final Map<String, DshLinkStatus> _links = <String, DshLinkStatus>{};
  final Map<String, DshCatalogSnapshot> _catalogs =
      <String, DshCatalogSnapshot>{};
  final Map<String, Map<String, DshSessionControl>> _sessionControls =
      <String, Map<String, DshSessionControl>>{};
  final Map<String, DshGateway> _gateways = <String, DshGateway>{};
  final Map<String, StreamSubscription<DshRemoteUpdate>> _updateSubs =
      <String, StreamSubscription<DshRemoteUpdate>>{};
  final Map<String, StreamSubscription<DshLinkStatus>> _linkSubs =
      <String, StreamSubscription<DshLinkStatus>>{};
  final Set<String> _deleting = <String>{};

  bool _loaded = false;
  bool _disposed = false;
  Object? _loadError;

  /// Completes when the stored records have been read. The owner list can be
  /// built before that; it reconciles again on the notification this lands.
  late final Future<void> loaded;

  /// Every remote, in creation order. Display order comes from
  /// `ChatOwnersProvider`, not from here.
  List<DshRemote> get remotes => List<DshRemote>.unmodifiable(_remotes);

  bool get isLoaded => _loaded;

  /// Non-null when the stored blob could not be decoded. The list is then
  /// empty rather than crashing the app.
  Object? get loadError => _loadError;

  /// Whether a protocol adapter factory was injected. False in the foundation
  /// slice; the settings page renders a localized "not wired" failure instead
  /// of a dead connect button.
  bool get isGatewayWired => _gatewayFactory != null;

  DshRemote? remoteById(String id) {
    for (final remote in _remotes) {
      if (remote.id == id) return remote;
    }
    return null;
  }

  @override
  Iterable<String> get harnessOwnerIds => [
    for (final remote in _remotes) remote.id,
  ];

  DshLinkStatus linkStatus(String id) =>
      _links[id] ?? const DshLinkStatus.idle();

  /// The latest catalog snapshot, or null when the remote was never connected
  /// (or its first read failed). The home slice builds the drawer from this;
  /// [DshCatalogSnapshot.allSessions] and `workspaces` are the session list.
  DshCatalogSnapshot? catalogFor(String id) => _catalogs[id];

  /// Live `session/control` projections by session id, patched as the remote
  /// pushes them.
  Map<String, DshSessionControl> sessionControlsFor(String id) =>
      Map<String, DshSessionControl>.unmodifiable(
        _sessionControls[id] ?? const <String, DshSessionControl>{},
      );

  DshSessionControl? sessionControlFor(String id, String sessionId) =>
      _sessionControls[id]?[sessionId];

  /// The live gateway of one remote, or null when it is not connected. Later
  /// slices (home, chat) open sessions and write session state through this.
  DshGateway? gatewayFor(String id) => _gateways[id];

  /// The provider-settings seam for one remote when its adapter implements it.
  ///
  /// The 模型 tab passes this into `DshModelsTabBody`; null means the build has
  /// no settings adapter and the tab shows the remote's live model catalog
  /// read-only instead of inventing editable data.
  DshProviderSettingsGateway? providerSettingsFor(String id) {
    final Object? gateway = _gateways[id];
    if (gateway is DshProviderSettingsHost) return gateway.providerSettings;
    return null;
  }

  Future<void> _load() async {
    try {
      final stored = await _store.getAll();
      if (_disposed) return;
      _remotes
        ..clear()
        ..addAll(stored);
      for (final remote in stored) {
        _links.putIfAbsent(remote.id, () => const DshLinkStatus.idle());
      }
    } catch (error) {
      // A corrupt blob must not take the app down; it also must not be
      // rewritten from the empty list (the store's read refused to decode, so
      // no write happens until the user creates a remote, which is a complete
      // snapshot of what the app intends to keep).
      _loadError = error;
    }
    _loaded = true;
    _notify();
  }

  /// Persists a new remote from the creation form. The caller then calls
  /// [connect] with the parsed link's launch token.
  Future<DshRemote> createRemote({
    required String name,
    required DshWebUiLink link,
  }) async {
    final remote = DshRemote(
      id: _uuid.v4(),
      name: name.trim(),
      baseUrl: link.baseUrl,
      authority: link.authority,
      secure: link.secure,
      createdAt: DateTime.now(),
    );
    await _store.add(remote);
    _remotes.add(remote);
    _links[remote.id] = const DshLinkStatus.idle();
    _notify();
    return remote;
  }

  /// Persists an edited record (name, address) and re-reads the list.
  Future<DshRemote> updateRemote(DshRemote remote) async {
    await _store.update(remote);
    _replaceRemote(remote);
    _notify();
    return remote;
  }

  /// Removes the record, its cookie and any live link. DeepSeek Harness keeps
  /// all of its own data; nothing remote is deleted.
  Future<void> deleteRemote(String id) async {
    if (!_deleting.add(id)) return;
    try {
      await _closeGateway(id);
      _links.remove(id);
      _catalogs.remove(id);
      _sessionControls.remove(id);
      await _store.remove(id);
      _remotes.removeWhere((remote) => remote.id == id);
      await _credentials.deleteCookie(id);
    } finally {
      _deleting.remove(id);
    }
    _notify();
  }

  /// Logs in and moves the link to
  /// `connecting → ready | failed`.
  ///
  /// [launchToken] comes from a just-pasted WebUI link and is used only for
  /// this call. Without one the gateway reconnects with the stored cookie; a
  /// 401 comes back as [DshFailure.auth] and the settings page asks for a fresh
  /// link. A successful login's cookie is persisted before the link is
  /// reported ready, so a restart can reuse it.
  Future<DshLinkStatus> connect(String id, {String? launchToken}) async {
    final remote = remoteById(id);
    if (remote == null) {
      return const DshLinkStatus.failed(DshFailure.notConfigured);
    }
    final current = _links[id];
    if (current != null && current.isConnecting) return current;

    final factory = _gatewayFactory;
    if (factory == null) {
      const status = DshLinkStatus.failed(DshFailure.notConfigured);
      _links[id] = status;
      await _recordFailure(remote, DshFailure.notConfigured);
      _notify();
      return status;
    }

    _links[id] = const DshLinkStatus.connecting();
    _notify();

    final gateway = _gateways[id] ?? factory(id);
    try {
      String? cookie;
      if (launchToken == null) {
        try {
          cookie = await _credentials.readCookie(id);
        } catch (_) {
          // A locked keychain is a missing credential, not a crash: the login
          // proceeds without it and fails as auth if the server rejects it.
        }
      }
      final result = await gateway.connect(
        remote: remote,
        launchToken: launchToken,
        storedCookie: cookie,
      );
      if (_deleting.contains(id)) {
        await gateway.disconnect();
        return _links[id] ?? const DshLinkStatus.idle();
      }
      if (result.cookie != null && result.cookie!.isNotEmpty) {
        try {
          await _credentials.writeCookie(id, result.cookie!);
        } catch (_) {
          // The link works for this run; the next launch asks for a re-paste.
        }
      }
      _gateways[id] = gateway;
      _catalogs[id] = result.catalog;
      _sessionControls.remove(id);
      _listenToGateway(id, gateway);
      final connected = remote.copyWith(
        lastConnectedAt: DateTime.now(),
        lastError: null,
      );
      await _store.update(connected);
      _replaceRemote(connected);
      const status = DshLinkStatus.ready();
      _links[id] = status;
      _notify();
      return status;
    } on DshGatewayException catch (error) {
      await _closeGateway(id);
      final status = DshLinkStatus.failed(error.failure, detail: error.detail);
      _links[id] = status;
      await _recordFailure(remote, error.failure);
      _notify();
      return status;
    } catch (error) {
      await _closeGateway(id);
      final status = DshLinkStatus.failed(
        DshFailure.unknown,
        detail: error.toString(),
      );
      _links[id] = status;
      await _recordFailure(remote, DshFailure.unknown);
      _notify();
      return status;
    }
  }

  /// Reconnects a link that dropped after it was ready, reusing the stored
  /// cookie. The adapter reports the intermediate states on its own status
  /// stream; this method returns the final one so a button can await it.
  Future<DshLinkStatus> retry(String id) async {
    final gateway = _gateways[id];
    if (gateway == null) return connect(id);
    _links[id] = const DshLinkStatus.connecting();
    _notify();
    try {
      await gateway.retry();
      const status = DshLinkStatus.ready();
      _links[id] = status;
      _notify();
      return status;
    } on DshGatewayException catch (error) {
      final status = DshLinkStatus.failed(error.failure, detail: error.detail);
      _links[id] = status;
      final remote = remoteById(id);
      if (remote != null) await _recordFailure(remote, error.failure);
      _notify();
      return status;
    } catch (error) {
      final status = DshLinkStatus.failed(
        DshFailure.unknown,
        detail: error.toString(),
      );
      _links[id] = status;
      final remote = remoteById(id);
      if (remote != null) await _recordFailure(remote, DshFailure.unknown);
      _notify();
      return status;
    }
  }

  /// Drops the live link but keeps the record and the cookie (the next connect
  /// reuses it).
  Future<void> disconnect(String id) async {
    await _closeGateway(id);
    _catalogs.remove(id);
    _sessionControls.remove(id);
    if (_links.containsKey(id)) {
      _links[id] = const DshLinkStatus.idle();
    }
    _notify();
  }

  /// Re-reads the catalog of a ready remote (after a server-side change or an
  /// invalidating patch).
  Future<DshCatalogSnapshot?> refreshCatalog(String id) async {
    final gateway = _gateways[id];
    if (gateway == null) return null;
    final catalog = await gateway.refreshCatalog();
    _catalogs[id] = catalog;
    _notify();
    return catalog;
  }

  /// Writes one of the two general settings the brief exposes. Throws
  /// [DshGatewayException] when the link is not ready or the server refuses,
  /// and updates the cached catalog only after the write succeeded.
  Future<void> updateGeneralSettings(
    String id,
    DshGeneralSettings settings,
  ) async {
    final gateway = _gateways[id];
    if (gateway == null) {
      throw const DshGatewayException(DshFailure.notConfigured);
    }
    await gateway.updateGeneralSettings(settings);
    final catalog = _catalogs[id];
    if (catalog != null) {
      _catalogs[id] = catalog.copyWith(generalSettings: settings);
    }
    _notify();
  }

  /// Opens one remote session for the later home/chat slices. The caller owns
  /// the handle and must close it; the provider only guarantees the gateway
  /// outlives it while this remote stays connected.
  Future<DshSessionHandle> openSession(String remoteId, String sessionId) {
    final gateway = _gateways[remoteId];
    if (gateway == null) {
      throw const DshGatewayException(DshFailure.notConfigured);
    }
    return gateway.openSession(sessionId);
  }

  void _listenToGateway(String id, DshGateway gateway) {
    unawaited(_updateSubs.remove(id)?.cancel());
    _updateSubs[id] = gateway.updates.listen(
      (update) => _onRemoteUpdate(id, update),
      onError: (Object _) {
        // Link errors are reported through [DshGateway.linkStatusStream], not
        // through the data stream; keep the last good view.
      },
    );
    unawaited(_linkSubs.remove(id)?.cancel());
    _linkSubs[id] = gateway.linkStatusStream.listen((status) {
      if (_disposed) return;
      _links[id] = status;
      if (status.isFailed) {
        final remote = remoteById(id);
        if (remote != null) {
          unawaited(
            _recordFailure(remote, status.failure ?? DshFailure.unknown),
          );
        }
      }
      _notify();
    });
  }

  void _onRemoteUpdate(String id, DshRemoteUpdate update) {
    if (_disposed) return;
    switch (update) {
      case DshCatalogPatchUpdate(:final patch):
        _applyPatch(id, patch);
      case DshSessionControlUpdate(:final control):
        (_sessionControls[id] ??=
                <String, DshSessionControl>{})[control.sessionId] =
            control;
        _notify();
    }
  }

  void _applyPatch(String id, DshCatalogPatch patch) {
    if (patch is DshCatalogInvalidated) {
      unawaited(_refreshCatalogSilently(id));
      return;
    }
    final catalog = _catalogs[id];
    if (catalog == null) return;
    switch (patch) {
      case DshCatalogInvalidated():
        return;
      case DshSessionUpsert(:final session):
        _catalogs[id] = _mergeSession(catalog, session);
      case DshSessionRemoved(:final sessionId):
        _catalogs[id] = _removeSession(catalog, sessionId);
        _sessionControls[id]?.remove(sessionId);
      case DshWorkspaceUpsert(:final workspace):
        _catalogs[id] = _mergeWorkspace(catalog, workspace);
      case DshWorkspaceRemoved(:final workspaceId):
        _catalogs[id] = catalog.copyWith(
          workspaces: [
            for (final item in catalog.workspaces)
              if (item.id != workspaceId) item,
          ],
        );
      case DshWorkspaceOrder(:final workspaceIds):
        final byId = {
          for (final workspace in catalog.workspaces) workspace.id: workspace,
        };
        final ordered = <DshWorkspace>[];
        for (final workspaceId in workspaceIds) {
          final workspace = byId.remove(workspaceId);
          if (workspace != null) ordered.add(workspace);
        }
        ordered.addAll(byId.values);
        _catalogs[id] = catalog.copyWith(workspaces: ordered);
    }
    _notify();
  }

  DshCatalogSnapshot _mergeSession(
    DshCatalogSnapshot catalog,
    DshSessionSummary session,
  ) {
    final withoutSession = _removeSession(catalog, session.id);
    var placed = false;
    final workspaces = <DshWorkspace>[];
    for (final workspace in withoutSession.workspaces) {
      if (!placed && workspace.id == session.workspaceId) {
        workspaces.add(
          workspace.copyWith(sessions: [...workspace.sessions, session]),
        );
        placed = true;
      } else {
        workspaces.add(workspace);
      }
    }
    final ungrouped = [...withoutSession.ungroupedSessions];
    if (!placed) ungrouped.add(session);
    return withoutSession.copyWith(
      workspaces: workspaces,
      ungroupedSessions: ungrouped,
    );
  }

  DshCatalogSnapshot _removeSession(
    DshCatalogSnapshot catalog,
    String sessionId,
  ) {
    return catalog.copyWith(
      workspaces: [
        for (final workspace in catalog.workspaces)
          workspace.copyWith(
            sessions: [
              for (final session in workspace.sessions)
                if (session.id != sessionId) session,
            ],
          ),
      ],
      ungroupedSessions: [
        for (final session in catalog.ungroupedSessions)
          if (session.id != sessionId) session,
      ],
    );
  }

  DshCatalogSnapshot _mergeWorkspace(
    DshCatalogSnapshot catalog,
    DshWorkspace workspace,
  ) {
    final movedIds = {for (final session in workspace.sessions) session.id};
    final workspaces = <DshWorkspace>[
      for (final existing in catalog.workspaces)
        if (existing.id != workspace.id)
          existing.copyWith(
            sessions: [
              for (final session in existing.sessions)
                if (!movedIds.contains(session.id)) session,
            ],
          ),
    ];
    final index = catalog.workspaces.indexWhere(
      (existing) => existing.id == workspace.id,
    );
    if (index == -1) {
      workspaces.add(workspace);
    } else {
      workspaces.insert(index.clamp(0, workspaces.length), workspace);
    }
    return catalog.copyWith(
      workspaces: workspaces,
      ungroupedSessions: [
        for (final session in catalog.ungroupedSessions)
          if (!movedIds.contains(session.id)) session,
      ],
    );
  }

  Future<void> _refreshCatalogSilently(String id) async {
    try {
      await refreshCatalog(id);
    } catch (_) {
      // The next connect/retry re-reads it; a failed silent refresh keeps the
      // last known catalog rather than blanking the drawer.
    }
  }

  Future<void> _recordFailure(DshRemote remote, DshFailure failure) async {
    try {
      final failed = remote.copyWith(lastError: failure.name);
      await _store.update(failed);
      _replaceRemote(failed);
    } catch (_) {
      // Persisting a failure diagnostic must never turn a failed connect into
      // an exception the UI has to handle twice.
    }
  }

  void _replaceRemote(DshRemote updated) {
    final index = _remotes.indexWhere((remote) => remote.id == updated.id);
    if (index == -1) {
      _remotes.add(updated);
    } else {
      _remotes[index] = updated;
    }
  }

  Future<void> _closeGateway(String id) async {
    unawaited(_updateSubs.remove(id)?.cancel());
    unawaited(_linkSubs.remove(id)?.cancel());
    final gateway = _gateways.remove(id);
    if (gateway == null) return;
    try {
      await gateway.disconnect();
    } catch (_) {
      // Closing is best effort: the remote may already be gone.
    }
  }

  void _notify() {
    if (_disposed) return;
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    for (final subscription in _updateSubs.values) {
      unawaited(subscription.cancel());
    }
    for (final subscription in _linkSubs.values) {
      unawaited(subscription.cancel());
    }
    _updateSubs.clear();
    _linkSubs.clear();
    final gateways = _gateways.values.toList();
    _gateways.clear();
    for (final gateway in gateways) {
      unawaited(
        gateway.disconnect().catchError((Object _) {
          // Nothing left to report during teardown.
        }),
      );
    }
    super.dispose();
  }
}
