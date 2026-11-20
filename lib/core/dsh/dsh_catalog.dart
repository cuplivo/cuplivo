/// Typed reads and writes over the Remote namespaces the feature needs:
/// sessions, workspaces, models and providers, permissions, commands, skills,
/// plugins, engine settings, account and credentials.
///
/// This is the *query* layer: it never caches beyond capability probes and does
/// not own UI state. [load] performs one batch for first paint; live surfaces
/// use [watchWorkspaces] and [watchSessionControl], whose streams re-open on a
/// new mux generation and re-deliver the Host baseline (consumers replace).
library;

import 'dart:async';

import 'dsh_errors.dart';
import 'dsh_events.dart';
import 'dsh_models.dart';
import 'dsh_mux.dart';
import 'dsh_rpc.dart';

/// Which endpoints this Host actually exposes, learned from 404 answers.
class DshCapabilities {
  final Map<String, bool> _known = {};

  /// Endpoints already probed/read, mapped to present/absent.
  Map<String, bool> get known => Map<String, bool>.unmodifiable(_known);

  bool? lookup(String endpoint) => _known[endpoint];

  /// False for endpoints never probed: capability parity starts hidden.
  bool supports(String endpoint) => _known[endpoint] ?? false;

  void record(String endpoint, bool present) {
    _known[endpoint] = present;
  }
}

/// Everything the UI needs for its first paint after connect.
class DshCatalogSnapshot {
  const DshCatalogSnapshot({
    required this.sessions,
    required this.workspaces,
    required this.archivedSessionIds,
    required this.pinnedSessionIds,
    required this.models,
    required this.providers,
    required this.configurableProviders,
    required this.permissionPresets,
    required this.plugins,
    required this.settings,
    required this.capabilities,
    required this.loadedAt,
    this.account,
  });

  final List<DshSessionSummary> sessions;
  final List<DshWorkspace> workspaces;
  final List<String> archivedSessionIds;
  final List<String> pinnedSessionIds;
  final DshModelCatalog models;
  final List<DshProviderInfo> providers;
  final List<DshConfigurableProvider> configurableProviders;
  final DshPermissionPresetCatalog permissionPresets;
  final DshPluginInventory plugins;
  final DshSettingsDescription settings;
  final DshAccountState? account;
  final DshCapabilities capabilities;
  final DateTime loadedAt;
}

/// Reader/writer over one connected Host.
class DshCatalog {
  DshCatalog(this.rpc, this.mux);

  final DshRpc rpc;
  final DshMux mux;
  final DshCapabilities capabilities = DshCapabilities();

  // ---------------------------------------------------------------------------
  // Batched first paint

  /// Reads the whole catalog, tolerating endpoints this DSH version lacks
  /// (capability false, empty collection) but propagating auth/transport
  /// failures — a broken connection must not look like an empty server.
  Future<DshCatalogSnapshot> load({
    bool includePlugins = true,
    bool includeSettings = true,
    bool includeAccount = true,
  }) async {
    final sessionsFuture = _read(
      'session/list',
      listSessions,
      const <DshSessionSummary>[],
      required: true,
    );
    final workspacesFuture = _read(
      'workspace/follow',
      loadWorkspaces,
      DshWorkspaceBaseline.empty,
    );
    final modelsFuture = _read(
      'session/modelCatalog',
      loadModelCatalog,
      DshModelCatalog.empty,
    );
    final providersFuture = _read(
      'llm/listProviders',
      listProviders,
      const <DshProviderInfo>[],
    );
    final configurableFuture = _read(
      'llm/listConfigurableProviders',
      listConfigurableProviders,
      const <DshConfigurableProvider>[],
    );
    final presetsFuture = _read(
      'permissionPresets/catalog',
      loadPermissionPresets,
      const DshPermissionPresetCatalog(
        options: [],
        defaultOptions: [],
        defaultPreset: null,
      ),
    );
    final pluginsFuture = includePlugins
        ? _read(
            'pluginInventory/list',
            loadPluginInventory,
            DshPluginInventory.empty,
          )
        : Future<DshPluginInventory>.value(DshPluginInventory.empty);
    final settingsFuture = includeSettings
        ? _read(
            'settings/describe',
            describeSettings,
            DshSettingsDescription.empty,
          )
        : Future<DshSettingsDescription>.value(DshSettingsDescription.empty);
    final accountFuture = includeAccount
        ? _read<DshAccountState?>('account/getState', accountState, null)
        : Future<DshAccountState?>.value();

    final sessions = await sessionsFuture;
    final workspaces = await workspacesFuture;
    final models = await modelsFuture;
    final providers = await providersFuture;
    final configurableProviders = await configurableFuture;
    final permissionPresets = await presetsFuture;
    final plugins = await pluginsFuture;
    final settings = await settingsFuture;
    final account = await accountFuture;

    return DshCatalogSnapshot(
      sessions: sessions,
      workspaces: workspaces.items,
      archivedSessionIds: workspaces.archivedSessionIds,
      pinnedSessionIds: workspaces.pinnedSessionIds,
      models: models,
      providers: providers,
      configurableProviders: configurableProviders,
      permissionPresets: permissionPresets,
      plugins: plugins,
      settings: settings,
      account: account,
      capabilities: capabilities,
      loadedAt: DateTime.now().toUtc(),
    );
  }

  Future<T> _read<T>(
    String endpoint,
    Future<T> Function() read,
    T fallback, {
    bool required = false,
  }) async {
    try {
      final value = await read();
      capabilities.record(endpoint, true);
      return value;
    } on DshUnsupportedException {
      capabilities.record(endpoint, false);
      if (required) rethrow;
      return fallback;
    }
  }

  // ---------------------------------------------------------------------------
  // Sessions

  /// Every stored session, newest first (including archived and subagent
  /// sessions — grouping/filtering is the caller's job).
  Future<List<DshSessionSummary>> listSessions() async {
    final value = jsonMap(
      await rpc.call(
        'session/list',
        args: {'_request': <String, Object?>{}},
        idempotent: true,
      ),
    );
    return jsonList(
      value['items'],
    ).map(DshSessionSummary.fromJson).toList(growable: false);
  }

  /// Creates a session in [workspaceId] or [cwd] (mutually exclusive); with
  /// [sessionId] it reuses/adopts a stored blank session. The returned id is
  /// authoritative — the Host may reuse a stored blank session.
  Future<DshSessionCreated> createSession({
    String? cwd,
    String? workspaceId,
    String? agentPreset,
    String? sessionId,
  }) async {
    if (cwd != null && workspaceId != null) {
      throw ArgumentError('cwd and workspaceId are mutually exclusive');
    }
    final value = jsonMap(
      await rpc.call(
        'session/create',
        args: {
          'request': {
            if (cwd != null) 'cwd': cwd,
            if (workspaceId != null) 'workspaceId': workspaceId,
            if (agentPreset != null) 'agentPreset': agentPreset,
            if (sessionId != null) 'sessionId': sessionId,
          },
        },
      ),
    );
    return DshSessionCreated.fromJson(value);
  }

  /// Renames and pins the session title (automatic titling stops).
  Future<String> renameSession(String sessionId, String title) async {
    final value = jsonMap(
      await rpc.call(
        'session/rename',
        args: {
          'request': {'sessionId': sessionId, 'title': title},
        },
      ),
    );
    return jsonString(value['title']) ?? title;
  }

  /// Forks a session at [atSeq] (or the latest completed turn).
  Future<String> forkSession(
    String sessionId, {
    int? atSeq,
    bool allowMigration = false,
  }) async {
    final value = jsonMap(
      await rpc.call(
        'session/fork',
        args: {
          'request': {
            'sessionId': sessionId,
            if (atSeq != null) 'atSeq': atSeq,
            if (allowMigration) 'allowMigration': true,
          },
        },
      ),
    );
    final forked = jsonString(value['sessionId']);
    if (forked == null || forked.isEmpty) {
      throw const DshProtocolException('session/fork returned no session id');
    }
    return forked;
  }

  Future<DshSessionState> sessionState(String sessionId) async {
    final value = await rpc.call(
      'session/state',
      args: {
        'request': {'sessionId': sessionId},
      },
      idempotent: true,
    );
    return DshSessionState.fromJson(value);
  }

  /// Current projection values, or null when the Host cannot serve them.
  Future<DshSessionProjections?> sessionProjections(String sessionId) async {
    final value = jsonMap(
      await rpc.call(
        'session/projections',
        args: {
          'request': {'sessionId': sessionId},
        },
        idempotent: true,
      ),
    );
    if (value.isEmpty || jsonString(value['kind']) != 'sequenced') return null;
    return DshSessionProjections.fromJson(value);
  }

  // ---------------------------------------------------------------------------
  // Workspaces

  /// Reads the registry through `workspace/follow` (there is no unary list):
  /// opens the stream, takes the opening baseline, cancels.
  Future<DshWorkspaceBaseline> loadWorkspaces() async {
    final stream = await mux.open('workspace/follow', autoReopen: false);
    try {
      final item = await stream.items.first.timeout(
        const Duration(seconds: 10),
      );
      final update = DshWorkspaceUpdate.tryParse(item);
      return switch (update) {
        DshWorkspaceBaselineUpdate(:final baseline) => baseline,
        DshWorkspaceReplaceUpdate(:final baseline) => baseline,
        _ => throw const DshProtocolException(
          'workspace/follow did not open with a baseline',
        ),
      };
    } finally {
      await stream.cancel();
    }
  }

  /// Live workspace registry: opening baseline then increments, re-opened on a
  /// new generation (a new baseline replaces local state).
  Stream<DshWorkspaceUpdate> watchWorkspaces() {
    return _watch('workspace/follow', DshWorkspaceUpdate.tryParse);
  }

  Future<DshWorkspaceCreated> createWorkspace(String path) async {
    final value = jsonMap(
      await rpc.call(
        'workspace/create',
        args: {
          'request': {'path': path},
        },
      ),
    );
    return DshWorkspaceCreated.fromJson(value);
  }

  Future<DshWorkspace> renameWorkspace(String workspaceId, String title) async {
    final value = jsonMap(
      await rpc.call(
        'workspace/rename',
        args: {
          'request': {'workspaceId': workspaceId, 'title': title},
        },
      ),
    );
    return DshWorkspace.fromJson(jsonMap(value['workspace']));
  }

  Future<void> deleteWorkspace(String workspaceId) async {
    await rpc.call(
      'workspace/delete',
      args: {
        'request': {'workspaceId': workspaceId},
      },
    );
  }

  /// Complete workspace order after moving one workspace.
  Future<List<String>> reorderWorkspaces(
    String workspaceId, {
    String? beforeWorkspaceId,
  }) async {
    final value = jsonMap(
      await rpc.call(
        'workspace/insertBefore',
        args: {
          'request': {
            'workspaceId': workspaceId,
            if (beforeWorkspaceId != null)
              'beforeWorkspaceId': beforeWorkspaceId,
          },
        },
      ),
    );
    return jsonStringList(value['workspaceIds']);
  }

  /// The workspace row (with its new `sessionIds` order) after moving a
  /// session inside it.
  Future<DshWorkspace> reorderWorkspaceSessions(
    String workspaceId,
    String sessionId, {
    String? beforeSessionId,
  }) async {
    final value = jsonMap(
      await rpc.call(
        'workspace/insertSessionBefore',
        args: {
          'request': {
            'workspaceId': workspaceId,
            'sessionId': sessionId,
            if (beforeSessionId != null) 'beforeSessionId': beforeSessionId,
          },
        },
      ),
    );
    return DshWorkspace.fromJson(jsonMap(value['workspace']));
  }

  /// Ensures the Host has a default workspace (idempotent); null when absent.
  Future<DshWorkspace?> initializeDefaultWorkspace() async {
    final value = jsonMap(
      await rpc.call('workspace/initializeDefault', args: const {}),
    );
    final workspace = jsonMap(value['workspace']);
    return workspace.isEmpty ? null : DshWorkspace.fromJson(workspace);
  }

  Future<List<String>> archiveSession(
    String sessionId, {
    bool? stopActivity,
  }) async {
    final value = jsonMap(
      await rpc.call(
        'workspace/archiveSession',
        args: {
          'request': {
            'sessionId': sessionId,
            if (stopActivity != null) 'stopActivity': stopActivity,
          },
        },
      ),
    );
    return jsonStringList(value['archivedSessionIds']);
  }

  Future<List<String>> unarchiveSession(String sessionId) async {
    final value = jsonMap(
      await rpc.call(
        'workspace/unarchiveSession',
        args: {
          'request': {'sessionId': sessionId},
        },
      ),
    );
    return jsonStringList(value['archivedSessionIds']);
  }

  Future<List<String>> pinSession(
    String sessionId, {
    required bool pinned,
  }) async {
    final value = jsonMap(
      await rpc.call(
        pinned ? 'workspace/pinSession' : 'workspace/unpinSession',
        args: {
          'request': {'sessionId': sessionId},
        },
      ),
    );
    return jsonStringList(value['pinnedSessionIds']);
  }

  // ---------------------------------------------------------------------------
  // Models and providers

  Future<DshModelCatalog> loadModelCatalog() async {
    final value = await rpc.call(
      'session/modelCatalog',
      args: const {},
      idempotent: true,
    );
    return DshModelCatalog.fromJson(value);
  }

  Future<DshModelSelection> selectModel(
    String sessionId,
    DshModelSelection selection,
  ) async {
    final value = jsonMap(
      await rpc.call(
        'session/selectModel',
        args: {
          'request': {'sessionId': sessionId, ...selection.toJson()},
        },
      ),
    );
    final selected = jsonMap(value['selected']);
    return selected.isEmpty ? selection : DshModelSelection.fromJson(selected);
  }

  /// Makes the current default model the new-session default.
  Future<void> initializeDefaultModel() async {
    await rpc.call('session/initializeDefaultModel', args: const {});
  }

  Future<List<DshProviderInfo>> listProviders() async {
    final value = await rpc.call(
      'llm/listProviders',
      args: const {},
      idempotent: true,
    );
    return jsonList(
      value,
    ).map(DshProviderInfo.fromJson).toList(growable: false);
  }

  Future<List<DshConfigurableProvider>> listConfigurableProviders() async {
    final value = await rpc.call(
      'llm/listConfigurableProviders',
      args: const {},
      idempotent: true,
    );
    return jsonList(
      value,
    ).map(DshConfigurableProvider.fromJson).toList(growable: false);
  }

  /// Asks the Host to list the models a draft provider route offers (provider
  /// credentials may be needed; slow).
  Future<List<DshDiscoveredModel>> discoverModels(
    String settingsNs,
    DshModelDiscoveryRequest request, {
    Duration timeout = const Duration(seconds: 120),
  }) async {
    final value = await rpc.call(
      'llm/discoverModels',
      args: {'settingsNs': settingsNs, 'request': request.toJson()},
      timeout: timeout,
    );
    return jsonList(
      value,
    ).map(DshDiscoveredModel.fromJson).toList(growable: false);
  }

  Future<Map<String, DshCredentialInfo>> describeCredentials(
    List<String> refs,
  ) async {
    final value = jsonMap(
      await rpc.call(
        'credentials/describe',
        args: {'refs': refs},
        idempotent: true,
      ),
    );
    return {
      for (final entry in value.entries)
        entry.key: DshCredentialInfo.fromJson(entry.value),
    };
  }

  Future<void> setCredential(String ref, String value) async {
    await rpc.call('credentials/set', args: {'ref': ref, 'value': value});
  }

  Future<void> unsetCredential(String ref) async {
    await rpc.call('credentials/unset', args: {'ref': ref});
  }

  // ---------------------------------------------------------------------------
  // Permissions, commands, skills

  Future<DshPermissionPresetCatalog> loadPermissionPresets() async {
    final value = await rpc.call(
      'permissionPresets/catalog',
      args: const {},
      idempotent: true,
    );
    return DshPermissionPresetCatalog.fromJson(value);
  }

  /// Changes the session's current permission preset. This is a command on the
  /// wire (`/permission <preset>`), not an RPC; the durable event and the
  /// `session/control` projection frame are the confirmation.
  Future<DshCommandExecution> setSessionPermission(
    String sessionId,
    String preset,
  ) {
    return executeCommand(sessionId, '/permission $preset');
  }

  Future<List<DshCommandDescriptor>> listCommands(String sessionId) async {
    final value = await rpc.call(
      'commands/list',
      args: {'agentId': sessionId},
      idempotent: true,
    );
    return jsonList(
      value,
    ).map(DshCommandDescriptor.fromJson).toList(growable: false);
  }

  Future<DshCommandExecution> executeCommand(
    String sessionId,
    String line, {
    List<Map<String, Object?>> submittedAttachments = const [],
  }) async {
    final value = jsonMap(
      await rpc.call(
        'commands/execute',
        args: {
          'agentId': sessionId,
          'line': line,
          'submittedAttachments': submittedAttachments,
        },
      ),
    );
    return DshCommandExecution.fromJson(value);
  }

  Future<List<DshSkill>> listSkills(String sessionId) async {
    final value = jsonMap(
      await rpc.call(
        'skills/list',
        args: {
          'request': {'sessionId': sessionId},
        },
        idempotent: true,
      ),
    );
    return jsonList(
      value['skills'],
    ).map(DshSkill.fromJson).toList(growable: false);
  }

  // ---------------------------------------------------------------------------
  // Plugins

  /// `agentPresets/list` — the selectable agent presets in Host order.
  ///
  /// The value is `{presets:[{id,order,isDefault}]}`; a bare list is accepted
  /// defensively. A 404 means the Host does not expose presets.
  Future<List<DshAgentPresetSummary>> listAgentPresets() async {
    final value = await rpc.call('agentPresets/list', idempotent: true);
    final map = jsonMap(value);
    final presets = map.containsKey('presets')
        ? jsonList(map['presets'])
        : jsonList(value);
    return presets.map(DshAgentPresetSummary.fromJson).toList(growable: false);
  }

  Future<DshPluginInventory> loadPluginInventory() async {
    final value = await rpc.call(
      'pluginInventory/list',
      args: const {},
      idempotent: true,
    );
    return DshPluginInventory.fromJson(value);
  }

  Future<List<DshPluginBundleInfo>> listPluginBundles() async {
    final value = await rpc.call(
      'pluginManager/listBundles',
      args: const {},
      idempotent: true,
    );
    return jsonList(
      value,
    ).map(DshPluginBundleInfo.fromJson).toList(growable: false);
  }

  Future<List<DshPluginInfo>> listPlugins() async {
    final value = await rpc.call(
      'pluginManager/listPlugins',
      args: const {},
      idempotent: true,
    );
    return jsonList(value).map(DshPluginInfo.fromJson).toList(growable: false);
  }

  Future<DshPluginChangeResult> setBundleEnabled(
    String name,
    bool enabled,
  ) async {
    final value = await rpc.call(
      'pluginManager/setBundleEnabled',
      args: {'name': name, 'enabled': enabled},
    );
    return DshPluginChangeResult.fromJson(value);
  }

  Future<DshPluginChangeResult> setPluginEnabled(
    String entryId,
    bool enabled,
  ) async {
    final value = await rpc.call(
      'pluginManager/setPluginEnabled',
      args: {'id': entryId, 'enabled': enabled},
    );
    return DshPluginChangeResult.fromJson(value);
  }

  // ---------------------------------------------------------------------------
  // Settings, account

  Future<DshSettingsDescription> describeSettings() async {
    final value = await rpc.call(
      'settings/describe',
      args: const {},
      idempotent: true,
    );
    return DshSettingsDescription.fromJson(value);
  }

  Future<DshSettingsNamespace> updateSettings(
    String ns,
    Map<String, Object?> patch, {
    int? expectedRevision,
  }) async {
    final value = await rpc.call(
      'settings/update',
      args: {
        'ns': ns,
        'patch': patch,
        if (expectedRevision != null) 'expectedRevision': expectedRevision,
      },
    );
    return DshSettingsNamespace.fromJson(value);
  }

  Future<DshSettingsNamespace> replaceSettings(
    String ns,
    Map<String, Object?> section, {
    int? expectedRevision,
  }) async {
    final value = await rpc.call(
      'settings/replace',
      args: {
        'ns': ns,
        'section': section,
        if (expectedRevision != null) 'expectedRevision': expectedRevision,
      },
    );
    return DshSettingsNamespace.fromJson(value);
  }

  Future<DshSettingsNamespace> mutateSettings(
    String ns,
    List<DshSettingsPathOp> ops, {
    int? expectedRevision,
  }) async {
    final value = await rpc.call(
      'settings/mutate',
      args: {
        'ns': ns,
        'ops': ops.map((op) => op.toJson()).toList(growable: false),
        if (expectedRevision != null) 'expectedRevision': expectedRevision,
      },
    );
    return DshSettingsNamespace.fromJson(value);
  }

  /// The brief's "default permission for new sessions" setting: a write to
  /// `permission.defaultPreset` (volatile, applies live).
  Future<void> setDefaultPermissionPreset(String preset) async {
    final description = await describeSettings();
    final ns = description.namespace('permission');
    await mutateSettings('permission', [
      DshSettingsSetOp(const ['defaultPreset'], preset),
    ], expectedRevision: ns?.revision);
  }

  /// The brief's "upload Session Log when using the official model API"
  /// setting: `session-log-deepseek.enabled`.
  Future<void> setSessionLogUpload(bool enabled) async {
    final description = await describeSettings();
    final ns = description.namespace('session-log-deepseek');
    await updateSettings('session-log-deepseek', {
      'enabled': enabled,
    }, expectedRevision: ns?.revision);
  }

  Future<DshAccountState> accountState() async {
    final value = await rpc.call(
      'account/getState',
      args: const {},
      idempotent: true,
    );
    return DshAccountState.fromJson(value);
  }

  // ---------------------------------------------------------------------------
  // Live control surface

  /// Global projection channel: one baseline per generation, then replacement
  /// frames with only the changed keys.
  Stream<DshSessionControlUpdate> watchSessionControl() {
    return _watch('session/control', _parseControlFrame);
  }

  static DshSessionControlUpdate? _parseControlFrame(Object? json) {
    final map = jsonMap(json);
    switch (jsonString(map['type'])) {
      case 'baseline':
        final value = jsonMap(map['value']);
        final projections = <String, DshSessionProjections>{};
        jsonMap(value['projections']).forEach((sessionId, block) {
          final blockMap = jsonMap(block);
          projections[sessionId] = DshSessionProjections(
            asOfSeq: jsonInt(blockMap['asOfSeq']) ?? 0,
            values: jsonMap(blockMap['values']),
          );
        });
        return DshSessionControlBaseline(projections);
      case 'projection':
        final sessionId = jsonString(map['sessionId']) ?? '';
        final seq = jsonInt(map['seq']) ?? 0;
        final changes = <DshSessionControlChange>[];
        for (final raw in jsonList(map['changes'])) {
          final change = jsonMap(raw);
          changes.add(
            DshSessionControlChange(
              key: jsonString(change['key']) ?? '',
              value: change['val'] ?? change['value'],
            ),
          );
        }
        if (changes.isEmpty) return null;
        return DshSessionControlProjection(
          sessionId: sessionId,
          changes: changes,
          seq: seq,
        );
      default:
        return null;
    }
  }

  /// Feature presence, cached. Calls the endpoint with `{}`: a 404 means the
  /// capability is absent, any other answer means it is mounted (business
  /// rejection included). Never used to *perform* an action.
  Future<bool> supports(String endpoint) async {
    final known = capabilities.lookup(endpoint);
    if (known != null) return known;
    try {
      await rpc.call(
        endpoint,
        args: const {},
        timeout: const Duration(seconds: 10),
      );
      capabilities.record(endpoint, true);
      return true;
    } on DshUnsupportedException {
      capabilities.record(endpoint, false);
      return false;
    } on DshRemoteException {
      // Mounted but rejected our empty args / disabled by config.
      capabilities.record(endpoint, true);
      return true;
    }
  }

  // ---------------------------------------------------------------------------
  // Generic live watcher

  /// Streams one mux endpoint, reopening it after a lost generation. The Host
  /// re-delivers the opening baseline, so consumers must treat it as replace.
  Stream<T> _watch<T>(String endpoint, T? Function(Object? value) parse) {
    late StreamController<T> controller;
    DshStream? current;
    var stopped = false;

    Future<void> run() async {
      while (!stopped) {
        try {
          final stream = await mux.open(endpoint, autoReopen: true);
          current = stream;
          await for (final item in stream.items) {
            if (stopped) break;
            final parsed = parse(item);
            if (parsed != null && !controller.isClosed) controller.add(parsed);
          }
          if (!stopped) {
            await Future<void>.delayed(const Duration(milliseconds: 500));
          }
        } on DshClosedException {
          break;
        } on DshException catch (error) {
          if (!stopped && !controller.isClosed) controller.addError(error);
          break;
        }
      }
      if (!controller.isClosed) await controller.close();
    }

    controller = StreamController<T>(
      onListen: () => unawaited(run()),
      onCancel: () async {
        stopped = true;
        await current?.cancel();
      },
    );
    return controller.stream;
  }
}
