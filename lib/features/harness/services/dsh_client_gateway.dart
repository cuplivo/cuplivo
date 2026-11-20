import 'dart:async';

import 'package:Cuplivo/core/dsh/dsh_client.dart' as dsh;
import 'package:Cuplivo/core/dsh/dsh_endpoint.dart' as dsh;
import 'package:Cuplivo/core/dsh/dsh_errors.dart' as dsh;
import 'package:Cuplivo/core/dsh/dsh_events.dart' as dsh;
import 'package:Cuplivo/core/dsh/dsh_mux.dart' as dsh;
import 'package:Cuplivo/core/dsh/dsh_models.dart' as dsh;
import 'package:Cuplivo/core/dsh/dsh_transport.dart' as dsh;

import '../models/dsh_provider_settings.dart';
import '../models/dsh_remote.dart';
import '../state/dsh_gateway.dart';
import 'dsh_client_gateway_mapping.dart';
import 'dsh_client_session_handle.dart';
import 'dsh_file_preview_host.dart';
import 'dsh_terminal_runtime.dart';
import 'dsh_provider_settings_adapter.dart';

/// The real [DshGateway]: one DeepSeek Harness connection over
/// `lib/core/dsh/`.
///
/// Ownership and lifetime:
/// * one gateway instance belongs to one `DshRemote` and is created by
///   `DshConnectionsProvider` through [DshGatewayFactory];
/// * [connect] performs pairing (launch token login, or stored-cookie resume),
///   waits for the mux ready generation, reads the catalog batch and only then
///   subscribes the live streams — a failure at any step closes whatever was
///   opened and surfaces [DshGatewayException];
/// * [disconnect] is idempotent and also safe after a failed [connect];
/// * the gateway never writes credentials: it returns the minted cookie in
///   [DshConnectResult] and the provider persists it.
class DshClientGateway
    implements
        DshGateway,
        DshProviderSettingsHost,
        DshFilePreviewHost,
        DshTerminalRuntimeHost {
  DshClientGateway({
    this._httpClient,
    this.muxOptions = const dsh.DshMuxOptions(),
    this.includePlugins = true,
    this.includeSettings = true,
  }) {
    _updates = StreamController<DshRemoteUpdate>.broadcast(
      onListen: _replayControls,
    );
  }

  final dsh.DshHttpClient? _httpClient;
  final dsh.DshMuxOptions muxOptions;
  final bool includePlugins;
  final bool includeSettings;

  late final StreamController<DshRemoteUpdate> _updates;
  final StreamController<DshLinkStatus> _links =
      StreamController<DshLinkStatus>.broadcast();

  dsh.DshClient? _client;
  dsh.DshConnectionState? _lastState;

  final Map<String, dsh.DshSessionSummary> _summaries =
      <String, dsh.DshSessionSummary>{};
  final Map<String, dsh.DshSessionProjections> _projections =
      <String, dsh.DshSessionProjections>{};
  final Map<String, bool> _running = <String, bool>{};

  /// Which workspace each known session belongs to; protocol summaries do not
  /// carry it, so a session upsert must be told or it would move to ungrouped.
  final Map<String, String> _sessionWorkspaceIds = <String, String>{};
  final Map<String, DshClientSessionHandle> _handles =
      <String, DshClientSessionHandle>{};
  final Map<String, DshSessionControl> _lastControls =
      <String, DshSessionControl>{};
  Set<String> _archived = <String>{};
  Set<String> _pinned = <String>{};

  DshGeneralSettings _generalSettings = const DshGeneralSettings();
  DshLinkStatus? _lastLinkStatus;

  final List<StreamSubscription<Object?>> _subscriptions =
      <StreamSubscription<Object?>>[];
  StreamSubscription<Object?>? _controlSubscription;
  StreamSubscription<Object?>? _workspaceSubscription;
  bool _watchersClosed = false;
  bool _connected = false;

  @override
  Stream<DshLinkStatus> get linkStatusStream => _links.stream;

  @override
  Stream<DshRemoteUpdate> get updates => _updates.stream;

  /// One adapter per gateway: the 模型 tab compares the seam by identity, so a
  /// fresh adapter on every build would reload the provider list each time.
  DshProviderSettingsGateway? _providerSettings;

  @override
  DshProviderSettingsGateway? get providerSettings =>
      _providerSettings ??= DshClientProviderSettings(client: _requireClient);

  // ---------------------------------------------------------------------------
  // Connect / disconnect / retry

  @override
  Future<DshConnectResult> connect({
    required DshRemote remote,
    String? launchToken,
    String? storedCookie,
  }) async {
    await _teardown();
    dsh.DshClient? client;
    try {
      final endpoint = dsh.DshEndpoint.parse(remote.baseUrl);
      final token = launchToken?.trim();
      if (token != null && token.isNotEmpty) {
        final input = endpoint.indexUri
            .replace(queryParameters: {'token': token})
            .toString();
        client = await dsh.DshClient.pair(
          input,
          httpClient: _httpClient,
          muxOptions: muxOptions,
        );
      } else {
        final cookie = _decodeCookie(
          storedCookie,
          authority: endpoint.authority,
        );
        if (cookie == null) {
          throw const dsh.DshAuthException(
            'No stored cookie: paste the full dsh web URL including ?token=',
          );
        }
        client = await dsh.DshClient.pair(
          remote.baseUrl,
          storedCookie: cookie,
          httpClient: _httpClient,
          muxOptions: muxOptions,
        );
      }
      final catalog = await _readCatalog(client);
      unawaited(_ensureDefaultModel(client));
      final minted = client.cookie;
      final result = DshConnectResult(
        catalog: catalog,
        cookie: minted == null ? null : encodeDshCookie(minted),
      );
      _client = client;
      _connected = true;
      _subscribe(client);
      return result;
    } on dsh.DshException catch (error) {
      await client?.close();
      throw dshGatewayExceptionFromClient(error);
    } catch (error) {
      await client?.close();
      throw DshGatewayException(DshFailure.unknown, detail: error.toString());
    }
  }

  @override
  Future<void> disconnect() async {
    await _teardown();
  }

  @override
  Future<void> retry() async {
    final client = _requireClient(allowDisconnected: true);
    try {
      await client.mux.reconnect();
      await _readCatalog(client);
      _connected = true;
      // A watcher that died on the old generation is reopened on the new one;
      // a new baseline then invalidates the catalog as usual.
      if (_watchersClosed) _openWatchers(client);
      _emitInvalidated('the link was re-established');
    } on dsh.DshException catch (error) {
      throw dshGatewayExceptionFromClient(error);
    }
  }

  @override
  Future<DshCatalogSnapshot> refreshCatalog() async {
    final client = _requireClient();
    try {
      return await _readCatalog(client);
    } on dsh.DshException catch (error) {
      throw dshGatewayExceptionFromClient(error);
    }
  }

  // ---------------------------------------------------------------------------
  // Settings

  @override
  Future<void> updateGeneralSettings(DshGeneralSettings settings) async {
    final client = _requireClient();
    final presetChanged =
        settings.defaultPermissionPresetId !=
        _generalSettings.defaultPermissionPresetId;
    final uploadChanged =
        settings.uploadSessionLog != _generalSettings.uploadSessionLog;
    if (!presetChanged && !uploadChanged) return;
    try {
      // One describe gives both the current revision CAS tokens.
      final description = await client.catalog.describeSettings();
      if (presetChanged) {
        final namespace = description.namespace('permission');
        const path = ['defaultPreset'];
        await client.catalog.mutateSettings('permission', [
          if (settings.defaultPermissionPresetId == null)
            dsh.DshSettingsUnsetOp(path)
          else
            dsh.DshSettingsSetOp(path, settings.defaultPermissionPresetId),
        ], expectedRevision: namespace?.revision);
      }
      if (uploadChanged) {
        final namespace = description.namespace('session-log-deepseek');
        await client.catalog.mutateSettings('session-log-deepseek', [
          dsh.DshSettingsSetOp(const ['enabled'], settings.uploadSessionLog),
        ], expectedRevision: namespace?.revision);
      }
      _generalSettings = settings;
      // The written value is only local until the next `settings/describe`;
      // a refresh keeps the provider's catalog copy honest.
      _emitInvalidated('general settings were written');
    } on dsh.DshException catch (error) {
      throw dshGatewayExceptionFromClient(error);
    }
  }

  // ---------------------------------------------------------------------------
  // Sessions

  @override
  Future<DshSessionSummary> createSession({
    String? workspaceId,
    String? cwd,
  }) async {
    final client = _requireClient();
    try {
      final session = await client.createSession(
        cwd: cwd,
        workspaceId: workspaceId,
      );
      final source = dsh.DshSessionSummary(
        sessionId: session.sessionId,
        updatedAt: DateTime.now(),
        cwd: cwd,
        raw: const <String, Object?>{},
      );
      // The sidebar can show the new row before `api-session/added` arrives;
      // the Host event later upserts the authoritative summary.
      _summaries[source.sessionId] = source;
      if (workspaceId != null) {
        _sessionWorkspaceIds[source.sessionId] = workspaceId;
      }
      _emitSessionUpsert(source.sessionId, summary: source);
      return mapDshSessionSummary(
        source,
        workspaceId: workspaceId,
        archivedIds: _archived,
        pinnedIds: _pinned,
      );
    } on dsh.DshException catch (error) {
      throw dshGatewayExceptionFromClient(error);
    }
  }

  @override
  Future<void> renameSession(String sessionId, String title) async {
    final client = _requireClient();
    try {
      await client.catalog.renameSession(sessionId, title);
      // `saveTitle` returns no snapshot; the authoritative title arrives as a
      // `session/control` projection, which only the chat view folds. A cheap
      // refresh keeps the sidebar row in step with the chat header.
      _emitInvalidated('a session was renamed');
    } on dsh.DshException catch (error) {
      throw dshGatewayExceptionFromClient(error);
    }
  }

  @override
  Future<void> setSessionPinned(
    String sessionId, {
    required bool pinned,
  }) async {
    final client = _requireClient();
    try {
      final pinnedIds = await client.catalog.pinSession(
        sessionId,
        pinned: pinned,
      );
      _pinned = pinnedIds.toSet();
      _emitSessionUpsert(sessionId);
    } on dsh.DshException catch (error) {
      throw dshGatewayExceptionFromClient(error);
    }
  }

  @override
  Future<void> setSessionArchived(
    String sessionId, {
    required bool archived,
  }) async {
    final client = _requireClient();
    try {
      final archivedIds = archived
          ? await client.catalog.archiveSession(sessionId)
          : await client.catalog.unarchiveSession(sessionId);
      _archived = archivedIds.toSet();
      _emitSessionUpsert(sessionId);
    } on dsh.DshException catch (error) {
      throw dshGatewayExceptionFromClient(error);
    }
  }

  @override
  Future<DshSessionHandle> openSession(String sessionId) async {
    final client = _requireClient();
    try {
      final store = await client.store(sessionId);
      final handle = DshClientSessionHandle(
        sessionId: sessionId,
        client: client,
        store: store,
        onClosed: _forgetHandle,
      );
      _handles[sessionId] = handle;
      await handle.start();
      return handle;
    } on dsh.DshException catch (error) {
      throw dshGatewayExceptionFromClient(error);
    }
  }

  void _forgetHandle(String sessionId) {
    _handles.remove(sessionId);
  }

  // ---------------------------------------------------------------------------
  // Workspace files
  // ---------------------------------------------------------------------------

  @override
  Future<List<DshFileEntry>> listFiles(String sessionId, String path) async {
    final client = _requireClient();
    try {
      final value = await client.rpc.call(
        'workspaceFiles/list',
        args: {
          'workspaceFileScopeId': sessionId,
          'path': workspaceFilePathForWire(path),
        },
        idempotent: true,
      );
      return [
        for (final entry in dsh.jsonList(dsh.jsonMap(value)['entries']))
          mapWorkspaceFileEntry(dsh.jsonMap(entry), path),
      ];
    } on dsh.DshException catch (error) {
      throw dshGatewayExceptionFromClient(error);
    }
  }

  @override
  Future<String> readTextFile(String sessionId, String path) async {
    final client = _requireClient();
    try {
      final value = await client.rpc.call(
        'workspaceFiles/read',
        args: {
          'workspaceFileScopeId': sessionId,
          'path': workspaceFilePathForWire(path),
          'range': const {'offset': 0},
        },
        idempotent: true,
      );
      return dsh.jsonString(dsh.jsonMap(value)['text']) ?? '';
    } on dsh.DshException catch (error) {
      throw dshGatewayExceptionFromClient(error);
    }
  }

  @override
  Future<DshFileStat> statFile(String sessionId, String path) async {
    final client = _requireClient();
    try {
      final stat = await client.statWorkspaceFile(
        sessionId,
        workspaceFilePathForWire(path),
        timeout: const Duration(seconds: 20),
      );
      return mapWorkspaceFileStat(stat, path);
    } on dsh.DshException catch (error) {
      throw dshGatewayExceptionFromClient(error);
    }
  }

  @override
  Future<List<int>> readFileBytes(String sessionId, String path) async {
    final client = _requireClient();
    try {
      return await client.readFileBytes(
        sessionId,
        workspaceFilePathForWire(path),
        timeout: const Duration(seconds: 30),
      );
    } on dsh.DshException catch (error) {
      throw dshGatewayExceptionFromClient(error);
    }
  }

  @override
  Uri? fileUri(String absolutePath, {String? version}) {
    if (absolutePath.isEmpty) return null;
    return _client?.endpoint.fileUri(absolutePath, version: version);
  }

  @override
  DshWorkspaceRuntime? terminalRuntimeFor(String sessionId) {
    final client = _client;
    if (client == null || sessionId.isEmpty) return null;
    return DshWorkspaceRuntime(client: client, sessionId: sessionId);
  }

  // ---------------------------------------------------------------------------
  // Streams

  void _subscribe(dsh.DshClient client) {
    _lastState = null;
    _subscriptions
      ..add(
        client.states.listen(
          _onState,
          onError: (Object error) => _onStreamError(error),
        ),
      )
      ..add(
        client.hostEvents.listen(
          _onHostEvent,
          onError: (Object error) => _onStreamError(error),
        ),
      );
    _openWatchers(client);
  }

  /// The two catalog watchers are the only streams that can close while the
  /// mux stays up (the client's `_watch` loop stops on a terminal error), so
  /// they are tracked separately and reopened by [retry].
  void _openWatchers(dsh.DshClient client) {
    _watchersClosed = false;
    unawaited(_controlSubscription?.cancel());
    unawaited(_workspaceSubscription?.cancel());
    _controlSubscription = client.catalog.watchSessionControl().listen(
      _onControl,
      onError: _onWatcherError,
      onDone: _onWatcherDone,
    );
    _workspaceSubscription = client.catalog.watchWorkspaces().listen(
      _onWorkspace,
      onError: _onWatcherError,
      onDone: _onWatcherDone,
    );
    _subscriptions
      ..add(_controlSubscription!)
      ..add(_workspaceSubscription!);
  }

  void _onWatcherError(Object error) {
    _watchersClosed = true;
    _onStreamError(error);
  }

  void _onWatcherDone() {
    _watchersClosed = true;
  }

  void _onStreamError(Object error) {
    final failure = error is dsh.DshException
        ? dshFailureFromClient(error)
        : DshFailure.unknown;
    _emitInvalidated('a live stream failed: ${error.toString()}');
    if (failure == DshFailure.auth) {
      final status = DshLinkStatus.failed(
        failure,
        detail: error is dsh.DshException ? error.message : error.toString(),
      );
      _publishLink(status);
    }
  }

  void _onState(dsh.DshConnectionState state) {
    if (state == _lastState) return;
    _lastState = state;
    final base = dshLinkStatusFromClient(state);
    final detail = base.isFailed ? _client?.lastError?.message : null;
    _publishLink(
      base.isFailed
          ? DshLinkStatus.failed(base.failure!, detail: detail ?? base.detail)
          : base,
    );
    final sessionFailure = switch (state) {
      dsh.DshConnectionState.unauthorized => DshFailure.auth,
      dsh.DshConnectionState.reconnecting ||
      dsh.DshConnectionState.closed => DshFailure.unreachable,
      _ => null,
    };
    for (final handle in List<DshClientSessionHandle>.of(_handles.values)) {
      handle.setLinkFailure(sessionFailure);
    }
  }

  void _publishLink(DshLinkStatus status) {
    if (_lastLinkStatus == status) return;
    _lastLinkStatus = status;
    if (!_links.isClosed) _links.add(status);
  }

  void _onControl(dsh.DshSessionControlUpdate update) {
    switch (update) {
      case dsh.DshSessionControlBaseline(:final projections):
        _projections
          ..clear()
          ..addAll(projections);
        for (final sessionId in _projections.keys) {
          _emitControl(sessionId);
        }
      case dsh.DshSessionControlProjection(
        :final sessionId,
        :final changes,
        :final seq,
      ):
        final merged =
            (_projections[sessionId] ?? dsh.DshSessionProjections.empty)
                .withChanges(seq, [
                  for (final change in changes)
                    MapEntry(change.key, change.value),
                ]);
        _projections[sessionId] = merged;
        _handles[sessionId]?.applyControlChanges(changes, seq);
        _emitControl(sessionId);
    }
  }

  void _emitControl(String sessionId, {bool? running}) {
    final control = mapDshSessionControl(
      sessionId: sessionId,
      projections: _projections[sessionId],
      summary: _summaries[sessionId],
      running: running ?? _running[sessionId],
    );
    if (_lastControls[sessionId] == control) return;
    _lastControls[sessionId] = control;
    if (!_updates.isClosed) _updates.add(DshSessionControlUpdate(control));
  }

  void _replayControls() {
    if (_updates.isClosed) return;
    for (final control in _lastControls.values) {
      _updates.add(DshSessionControlUpdate(control));
    }
  }

  void _onWorkspace(dsh.DshWorkspaceUpdate update) {
    switch (update) {
      case dsh.DshWorkspaceBaselineUpdate(:final baseline) ||
          dsh.DshWorkspaceReplaceUpdate(:final baseline):
        _archived = baseline.archivedSessionIds.toSet();
        _pinned = baseline.pinnedSessionIds.toSet();
        _sessionWorkspaceIds
          ..clear()
          ..addAll({
            for (final workspace in baseline.items)
              for (final sessionId in workspace.sessionIds)
                sessionId: workspace.workspaceId,
          });
      case dsh.DshWorkspaceUpsertUpdate(:final workspace):
        for (final sessionId in workspace.sessionIds) {
          _sessionWorkspaceIds[sessionId] = workspace.workspaceId;
        }
      case dsh.DshWorkspaceRemoveUpdate(:final workspaceId):
        _sessionWorkspaceIds.removeWhere(
          (sessionId, owner) => owner == workspaceId,
        );
      default:
        break;
    }
    final patch = mapDshWorkspaceUpdate(
      update,
      summaries: _summaries,
      archivedIds: _archived,
      pinnedIds: _pinned,
    );
    if (patch is DshCatalogInvalidated) {
      _emitInvalidated(patch.detail ?? 'workspace state was replaced');
      return;
    }
    if (!_updates.isClosed) _updates.add(DshCatalogPatchUpdate(patch));
  }

  void _onHostEvent(dsh.DshHostEvent event) {
    if (event is! dsh.DshHostEmit) return;
    final summary = event.sessionSummary;
    if (summary != null) {
      _summaries[summary.sessionId] = summary;
      _emitSessionUpsert(summary.sessionId, summary: summary);
      return;
    }
    final running = event.running;
    final sessionId = event.arg0;
    if (running != null && sessionId != null) {
      _running[sessionId] = running;
      _emitControl(sessionId, running: running);
      final cached = _summaries[sessionId];
      if (cached != null) {
        final updated = dsh.DshSessionSummary(
          sessionId: cached.sessionId,
          updatedAt: cached.updatedAt,
          raw: cached.raw,
          running: running,
          blank: cached.blank,
          agentAvailable: cached.agentAvailable,
          cwd: cached.cwd,
          formatStatus: cached.formatStatus,
          parentSessionId: cached.parentSessionId,
          origin: cached.origin,
          projections: cached.projections,
        );
        _summaries[sessionId] = updated;
      }
    }
  }

  // ---------------------------------------------------------------------------
  // Catalog reads

  /// `session/initializeDefaultModel` is an idempotent bootstrap the official
  /// UI runs once after connect (protocol §session/initializeDefaultModel); it
  /// is not a setter. A Host that does not expose it stays fully usable.
  Future<void> _ensureDefaultModel(dsh.DshClient client) async {
    try {
      await client.catalog.initializeDefaultModel();
    } on dsh.DshException {
      // Capability parity: absence is fine, and the catalog already carries
      // the default selection the UI needs.
    }
  }

  Future<DshCatalogSnapshot> _readCatalog(dsh.DshClient client) async {
    final source = await client.loadCatalog(
      includePlugins: includePlugins,
      includeSettings: includeSettings,
      includeAccount: false,
    );
    _summaries
      ..clear()
      ..addAll({
        for (final summary in source.sessions) summary.sessionId: summary,
      });
    _archived = source.archivedSessionIds.toSet();
    _pinned = source.pinnedSessionIds.toSet();
    _sessionWorkspaceIds
      ..clear()
      ..addAll({
        for (final workspace in source.workspaces)
          for (final sessionId in workspace.sessionIds)
            sessionId: workspace.workspaceId,
      });
    // A refresh replaces the session set; drop control state for sessions the
    // remote no longer lists so a replayed control cannot resurrect them.
    final sessionIds = _summaries.keys.toSet();
    _lastControls.removeWhere(
      (sessionId, _) => !sessionIds.contains(sessionId),
    );
    _projections.removeWhere((sessionId, _) => !sessionIds.contains(sessionId));
    _running.removeWhere((sessionId, _) => !sessionIds.contains(sessionId));
    var catalog = mapDshCatalog(source);
    // `commands/list` and `skills/list` are session-scoped (protocol §commands),
    // while the gateway snapshot carries one global roster. Ask the first
    // listed session for a representative roster, best-effort: a Host that does
    // not expose either endpoint stays connected with an empty list plus a
    // per-section failure, and a session whose preset differs only narrows what
    // this first paint shows (the seam has no per-session command read yet).
    String? representative;
    for (final session in source.sessions) {
      if (session.agentAvailable) {
        representative = session.sessionId;
        break;
      }
    }
    if (representative != null &&
        (catalog.commands.isEmpty || catalog.skills.isEmpty)) {
      catalog = await _enrichRoster(client, catalog, representative);
    }
    _generalSettings = catalog.generalSettings;
    return catalog;
  }

  Future<DshCatalogSnapshot> _enrichRoster(
    dsh.DshClient client,
    DshCatalogSnapshot catalog,
    String sessionId,
  ) async {
    final supported = <DshCapability>{...catalog.capabilities.supported};
    final failures = <DshCatalogFailure>[...catalog.failures];
    var commands = catalog.commands;
    var skills = catalog.skills;
    if (commands.isEmpty) {
      try {
        commands = [
          for (final command in await client.catalog.listCommands(sessionId))
            mapDshCommand(command),
        ];
        supported.add(DshCapability.commands);
      } on dsh.DshUnsupportedException {
        failures.add(
          const DshCatalogFailure(
            section: DshCatalogSection.commands,
            failure: DshFailure.unsupported,
          ),
        );
      } on dsh.DshException {
        // A live link that answers but cannot list commands is not fatal; the
        // composer simply has no server commands this generation.
      }
    }
    if (skills.isEmpty) {
      try {
        skills = [
          for (final skill in await client.catalog.listSkills(sessionId))
            mapDshSkill(skill),
        ];
        supported.add(DshCapability.skills);
      } on dsh.DshUnsupportedException {
        failures.add(
          const DshCatalogFailure(
            section: DshCatalogSection.skills,
            failure: DshFailure.unsupported,
          ),
        );
      } on dsh.DshException {
        // Same as commands.
      }
    }
    return catalog.copyWith(
      commands: commands,
      skills: skills,
      capabilities: DshCapabilities(supported: supported),
      failures: failures,
    );
  }

  void _emitSessionUpsert(String sessionId, {dsh.DshSessionSummary? summary}) {
    final source = summary ?? _summaries[sessionId];
    if (source == null) return;
    _summaries[sessionId] = source;
    if (_updates.isClosed) return;
    _updates.add(
      DshCatalogPatchUpdate(
        mapDshSessionAdded(
          source,
          workspaceId: _sessionWorkspaceIds[sessionId],
          archivedIds: _archived,
          pinnedIds: _pinned,
        ),
      ),
    );
  }

  void _emitInvalidated(String detail) {
    if (!_updates.isClosed) {
      _updates.add(
        DshCatalogPatchUpdate(DshCatalogInvalidated(detail: detail)),
      );
    }
  }

  // ---------------------------------------------------------------------------
  // Cookie codec

  static dsh.DshCookie? _decodeCookie(
    String? stored, {
    required String authority,
  }) {
    final decoded = decodeDshCookie(stored);
    if (decoded == null) return null;
    if (decoded.authority != authority) {
      // Never send a credential minted for another Host to this one.
      throw const dsh.DshAuthException(
        'The stored cookie belongs to a different Host; paste a fresh link',
      );
    }
    return decoded;
  }

  // ---------------------------------------------------------------------------
  // Lifecycle helpers

  dsh.DshClient _requireClient({bool allowDisconnected = false}) {
    final client = _client;
    if (client == null || (!allowDisconnected && !_connected)) {
      throw const DshGatewayException(
        DshFailure.notConfigured,
        detail: 'the remote is not connected',
      );
    }
    return client;
  }

  Future<void> _teardown() async {
    _connected = false;
    for (final handle in List<DshClientSessionHandle>.of(_handles.values)) {
      await handle.close();
    }
    _handles.clear();
    for (final subscription in _subscriptions) {
      await subscription.cancel();
    }
    _subscriptions.clear();
    _controlSubscription = null;
    _workspaceSubscription = null;
    _watchersClosed = false;
    final client = _client;
    _client = null;
    if (client != null) {
      try {
        await client.close();
      } catch (_) {
        // Closing is best-effort: the sockets may already be gone.
      }
    }
    _lastState = null;
    _summaries.clear();
    _projections.clear();
    _running.clear();
    _sessionWorkspaceIds.clear();
    _lastControls.clear();
    _publishLink(const DshLinkStatus.idle());
  }
}
