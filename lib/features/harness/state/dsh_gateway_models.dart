import 'package:flutter/foundation.dart';

/// UI-facing view models for one remote DeepSeek Harness link.
///
/// These are the *adaptation* layer: the protocol client under `lib/core/dsh/`
/// speaks in its own wire/domain types, and the adapter in
/// `lib/features/harness/services/` maps them to these. The feature layer and
/// this state layer never import `lib/core/dsh/` directly, so a wire change
/// (or replacing the client) stops at the adapter. Nothing here is persisted:
/// DeepSeek Harness owns all of it, and a disconnect drops it.
///
/// Shapes are intentionally flattened for rendering: the home drawer reads
/// workspaces with their sessions, the chat page reads one session view, the
/// settings page reads catalog sections. Unknown/absent server capabilities are
/// carried as explicit flags or section failures so a surface can hide or
/// explain a control instead of silently showing an empty list.

/// A user-actionable failure class. The UI maps it to a localized sentence;
/// technical detail stays in the gateway exception's `detail` for logs only.
enum DshFailure {
  /// No protocol adapter is wired yet (the foundation slice ships without
  /// `lib/core/dsh/`), so connecting cannot start.
  notConfigured,

  /// The host did not answer: wrong address, server down, LAN/firewall.
  unreachable,

  /// The server refused the credential: a re-paste of the WebUI link is
  /// required (the launch token rotates with each `dsh web` process).
  auth,

  /// The server answered with something the client cannot parse.
  protocol,

  /// The installed DeepSeek Harness does not expose the needed capability.
  unsupported,

  /// Anything else; the detail carries the technical cause.
  unknown,
}

/// How far one remote link has progressed.
///
/// The state layer owns one of these per remote and moves it
/// `idle → connecting → ready | failed`; [DshConnectionsProvider] is the only
/// writer. A failed link keeps its reason until the next connect attempt — the
/// UI renders it in Cuplivo's inline error style, never as a raw stack trace.
enum DshLinkState { idle, connecting, ready, failed }

/// Parses a persisted `DshRemote.lastError` back into its class.
DshFailure? dshFailureFromName(String? name) {
  if (name == null || name.isEmpty) return null;
  for (final failure in DshFailure.values) {
    if (failure.name == name) return failure;
  }
  return null;
}

@immutable
class DshLinkStatus {
  const DshLinkStatus._(this.state, {this.failure, this.detail});

  const DshLinkStatus.idle() : this._(DshLinkState.idle);

  const DshLinkStatus.connecting() : this._(DshLinkState.connecting);

  const DshLinkStatus.ready() : this._(DshLinkState.ready);

  const DshLinkStatus.failed(DshFailure failure, {String? detail})
    : this._(DshLinkState.failed, failure: failure, detail: detail);

  final DshLinkState state;

  /// Set only when [state] is [DshLinkState.failed].
  final DshFailure? failure;

  /// Technical cause for logs; never rendered as-is.
  final String? detail;

  bool get isIdle => state == DshLinkState.idle;
  bool get isConnecting => state == DshLinkState.connecting;
  bool get isReady => state == DshLinkState.ready;
  bool get isFailed => state == DshLinkState.failed;
  bool get isBusy => isConnecting;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is DshLinkStatus &&
          other.state == state &&
          other.failure == failure &&
          other.detail == detail;

  @override
  int get hashCode => Object.hash(state, failure, detail);

  @override
  String toString() =>
      isFailed ? 'DshLinkStatus.failed($failure)' : 'DshLinkStatus($state)';
}

/// Thrown by a [DshGateway] for a failure the user can act on.
///
/// [failure] is what the UI localizes; [detail] is a short technical cause for
/// logs. A gateway must not throw raw exceptions across this interface — the
/// state layer catches anything else as [DshFailure.unknown].
class DshGatewayException implements Exception {
  const DshGatewayException(this.failure, {this.detail});

  final DshFailure failure;
  final String? detail;

  @override
  String toString() =>
      'DshGatewayException(${failure.name}${detail == null ? '' : ': $detail'})';
}

/// What a successful login produced.
@immutable
class DshConnectResult {
  const DshConnectResult({required this.catalog, this.cookie});

  final DshCatalogSnapshot catalog;

  /// The v1 browser cookie minted by this login, or null when the gateway
  /// reused a stored cookie. The state layer is the only writer: it persists
  /// this in the secure store and drops it from memory.
  final String? cookie;
}

// ---------------------------------------------------------------------------
// Catalog
// ---------------------------------------------------------------------------

/// One permission preset the remote offers for new sessions.
///
/// [title] is the remote's own wording (e.g. `Read Only`): Cuplivo renders the
/// server's presets rather than inventing a local permission model, per the
/// capability-parity rule.
@immutable
class DshPermissionPreset {
  const DshPermissionPreset({
    required this.id,
    required this.title,
    this.description,
  });

  final String id;
  final String title;
  final String? description;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is DshPermissionPreset &&
          other.id == id &&
          other.title == title &&
          other.description == description;

  @override
  int get hashCode => Object.hash(id, title, description);
}

/// The DeepSeek Harness general settings Cuplivo exposes.
///
/// The brief hides every official rendering setting (language, appearance,
/// working-step display, shortcuts, …) because Cuplivo governs those; only the
/// two settings that live outside Cuplivo's scope are here. The values are the
/// server's, written back through [DshGateway.updateGeneralSettings].
@immutable
class DshGeneralSettings {
  const DshGeneralSettings({
    this.defaultPermissionPresetId,
    this.uploadSessionLog = false,
  });

  /// `null` means "follow the server's own default".
  final String? defaultPermissionPresetId;

  /// 在使用官方模型API时上传Session Log.
  final bool uploadSessionLog;

  DshGeneralSettings copyWith({
    Object? defaultPermissionPresetId = _unset,
    bool? uploadSessionLog,
  }) {
    return DshGeneralSettings(
      defaultPermissionPresetId: identical(defaultPermissionPresetId, _unset)
          ? this.defaultPermissionPresetId
          : defaultPermissionPresetId as String?,
      uploadSessionLog: uploadSessionLog ?? this.uploadSessionLog,
    );
  }

  static const Object _unset = Object();

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is DshGeneralSettings &&
          other.defaultPermissionPresetId == defaultPermissionPresetId &&
          other.uploadSessionLog == uploadSessionLog;

  @override
  int get hashCode => Object.hash(defaultPermissionPresetId, uploadSessionLog);
}

/// One reasoning-effort choice a model advertises (e.g. `low`, `high`).
@immutable
class DshReasoningEffort {
  const DshReasoningEffort({required this.id, required this.title});

  final String id;
  final String title;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is DshReasoningEffort && other.id == id && other.title == title;

  @override
  int get hashCode => Object.hash(id, title);
}

/// One model as the remote's catalog describes it.
@immutable
class DshModel {
  const DshModel({
    required this.providerId,
    required this.modelId,
    required this.title,
    this.reasoningEfforts = const <DshReasoningEffort>[],
    this.defaultReasoningEffortId,
  });

  final String providerId;
  final String modelId;
  final String title;
  final List<DshReasoningEffort> reasoningEfforts;
  final String? defaultReasoningEffortId;

  String get key => '$providerId::$modelId';

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is DshModel &&
          other.providerId == providerId &&
          other.modelId == modelId &&
          other.title == title &&
          listEquals(other.reasoningEfforts, reasoningEfforts) &&
          other.defaultReasoningEffortId == defaultReasoningEffortId;

  @override
  int get hashCode => Object.hash(
    providerId,
    modelId,
    title,
    Object.hashAll(reasoningEfforts),
    defaultReasoningEffortId,
  );
}

/// A provider group in the model catalog (the models settings page and the
/// composer's model picker both list these).
@immutable
class DshProviderGroup {
  const DshProviderGroup({
    required this.id,
    required this.title,
    this.models = const <DshModel>[],
    this.failureMessage,
  });

  final String id;
  final String title;
  final List<DshModel> models;

  /// Non-null when this provider is present but unusable (missing credential,
  /// discovery failure). The UI shows the reason instead of hiding the group.
  final String? failureMessage;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is DshProviderGroup &&
          other.id == id &&
          other.title == title &&
          listEquals(other.models, models) &&
          other.failureMessage == failureMessage;

  @override
  int get hashCode =>
      Object.hash(id, title, Object.hashAll(models), failureMessage);
}

/// A model choice: what the session's `next` projection holds.
@immutable
class DshModelSelection {
  const DshModelSelection({
    required this.providerId,
    required this.modelId,
    this.reasoningEffortId,
  });

  final String providerId;
  final String modelId;
  final String? reasoningEffortId;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is DshModelSelection &&
          other.providerId == providerId &&
          other.modelId == modelId &&
          other.reasoningEffortId == reasoningEffortId;

  @override
  int get hashCode => Object.hash(providerId, modelId, reasoningEffortId);
}

/// The model catalog: provider groups, the remote's default selection, and
/// per-provider failures.
@immutable
class DshModelCatalog {
  const DshModelCatalog({
    this.providers = const <DshProviderGroup>[],
    this.defaultSelection,
  });

  final List<DshProviderGroup> providers;
  final DshModelSelection? defaultSelection;

  List<DshModel> get models => [
    for (final provider in providers) ...provider.models,
  ];

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is DshModelCatalog &&
          listEquals(other.providers, providers) &&
          other.defaultSelection == defaultSelection;

  @override
  int get hashCode => Object.hash(Object.hashAll(providers), defaultSelection);
}

/// One session row as the remote lists it (projection data only).
@immutable
class DshSessionSummary {
  const DshSessionSummary({
    required this.id,
    required this.title,
    this.workspaceId,
    this.cwd,
    this.running = false,
    this.queued = 0,
    this.pinned = false,
    this.archived = false,
    this.updatedAt,
  });

  final String id;
  final String title;
  final String? workspaceId;
  final String? cwd;
  final bool running;
  final int queued;
  final bool pinned;
  final bool archived;
  final DateTime? updatedAt;

  DshSessionSummary copyWith({
    String? title,
    String? workspaceId,
    bool? running,
    int? queued,
    bool? pinned,
    bool? archived,
    DateTime? updatedAt,
  }) {
    return DshSessionSummary(
      id: id,
      title: title ?? this.title,
      workspaceId: workspaceId ?? this.workspaceId,
      cwd: cwd,
      running: running ?? this.running,
      queued: queued ?? this.queued,
      pinned: pinned ?? this.pinned,
      archived: archived ?? this.archived,
      updatedAt: updatedAt ?? this.updatedAt,
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is DshSessionSummary &&
          other.id == id &&
          other.title == title &&
          other.workspaceId == workspaceId &&
          other.cwd == cwd &&
          other.running == running &&
          other.queued == queued &&
          other.pinned == pinned &&
          other.archived == archived &&
          other.updatedAt == updatedAt;

  @override
  int get hashCode => Object.hash(
    id,
    title,
    workspaceId,
    cwd,
    running,
    queued,
    pinned,
    archived,
    updatedAt,
  );
}

/// A workspace (a host directory registered on the server) with its sessions,
/// in server order.
@immutable
class DshWorkspace {
  const DshWorkspace({
    required this.id,
    required this.title,
    this.path,
    this.sessions = const <DshSessionSummary>[],
  });

  final String id;
  final String title;
  final String? path;
  final List<DshSessionSummary> sessions;

  DshWorkspace copyWith({
    String? title,
    String? path,
    List<DshSessionSummary>? sessions,
  }) {
    return DshWorkspace(
      id: id,
      title: title ?? this.title,
      path: path ?? this.path,
      sessions: sessions ?? this.sessions,
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is DshWorkspace &&
          other.id == id &&
          other.title == title &&
          other.path == path &&
          listEquals(other.sessions, sessions);

  @override
  int get hashCode => Object.hash(id, title, path, Object.hashAll(sessions));
}

/// One plugin entry the remote exposes (drawer/plug-in entry points; the panel
/// body is a WebView and is not part of this view model).
@immutable
class DshPluginEntry {
  const DshPluginEntry({
    required this.id,
    required this.title,
    this.moduleName = '',
    this.localizedTitle = const <String, String>{},
    this.description,
    this.enabled = true,
    this.phase,
    this.diagnostic,
  });

  final String id;

  /// Display title resolved to English, or the module name when the plugin
  /// reports no `meta.title`.
  final String title;

  /// Module name from the Host inventory (`@scope/plugin`); the 内置插件 row
  /// shows it under the title.
  final String moduleName;

  /// `meta.title` values exactly as the plugin authored them, so a settings
  /// tab can use the plugin's own localized label instead of a Cuplivo key.
  final Map<String, String> localizedTitle;
  final String? description;
  final bool enabled;

  /// Loader phase (`pending`, `loading`, `active`, `failed`, `unloading`);
  /// null when the Host does not report one.
  final String? phase;

  /// Non-null when the plugin is installed but unhealthy; the row shows it.
  final String? diagnostic;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is DshPluginEntry &&
          other.id == id &&
          other.title == title &&
          other.moduleName == moduleName &&
          mapEquals(other.localizedTitle, localizedTitle) &&
          other.description == description &&
          other.enabled == enabled &&
          other.phase == phase &&
          other.diagnostic == diagnostic;

  @override
  int get hashCode => Object.hash(
    id,
    title,
    moduleName,
    Object.hashAll(localizedTitle.entries),
    description,
    enabled,
    phase,
    diagnostic,
  );
}

/// One plugin row inside an agent preset composition (read-only).
@immutable
class DshAgentPresetPlugin {
  const DshAgentPresetPlugin({
    required this.moduleName,
    this.title,
    this.localizedTitle = const <String, String>{},
    this.enabled = true,
    this.conditional = false,
    this.condition,
    this.phase,
  });

  final String moduleName;
  final String? title;
  final Map<String, String> localizedTitle;
  final bool enabled;

  /// The row's `!!js` disabled expression needs a Loader context to evaluate.
  final bool conditional;
  final String? condition;
  final String? phase;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is DshAgentPresetPlugin &&
          other.moduleName == moduleName &&
          other.title == title &&
          mapEquals(other.localizedTitle, localizedTitle) &&
          other.enabled == enabled &&
          other.conditional == conditional &&
          other.condition == condition &&
          other.phase == phase;

  @override
  int get hashCode => Object.hash(
    moduleName,
    title,
    Object.hashAll(localizedTitle.entries),
    enabled,
    conditional,
    condition,
    phase,
  );
}

/// One agent preset's plugin composition as `pluginInventory/list` reports it.
@immutable
class DshAgentPresetGroup {
  const DshAgentPresetGroup({
    required this.id,
    this.name,
    this.isDefault = false,
    this.broken,
    this.plugins = const <DshAgentPresetPlugin>[],
  });

  final String id;
  final String? name;
  final bool isDefault;

  /// Why the composition cannot be read (the plugin list is empty then).
  final String? broken;
  final List<DshAgentPresetPlugin> plugins;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is DshAgentPresetGroup &&
          other.id == id &&
          other.name == name &&
          other.isDefault == isDefault &&
          other.broken == broken &&
          listEquals(other.plugins, plugins);

  @override
  int get hashCode =>
      Object.hash(id, name, isDefault, broken, Object.hashAll(plugins));
}

/// One command the remote advertises for the composer's plus menu.
@immutable
class DshCommand {
  const DshCommand({
    required this.name,
    this.description,
    this.inputHint,
    this.takesAttachments = false,
  });

  final String name;
  final String? description;

  /// The Host's hint for the argument the command expects (e.g. a preset name),
  /// or null for a command that runs on its own.
  final String? inputHint;

  /// True when the command's input definition accepts attachments.
  final bool takesAttachments;

  bool get takesInput => (inputHint ?? '').trim().isNotEmpty;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is DshCommand &&
          other.name == name &&
          other.description == description &&
          other.inputHint == inputHint &&
          other.takesAttachments == takesAttachments;

  @override
  int get hashCode =>
      Object.hash(name, description, inputHint, takesAttachments);
}

/// One skill the remote advertises.
@immutable
class DshSkill {
  const DshSkill({required this.id, required this.title, this.description});

  final String id;
  final String title;
  final String? description;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is DshSkill &&
          other.id == id &&
          other.title == title &&
          other.description == description;

  @override
  int get hashCode => Object.hash(id, title, description);
}

/// A server capability the UI may ask about. Absent capabilities hide the
/// corresponding control instead of rendering a dead one (capability parity).
enum DshCapability {
  modelCatalog,
  workspaces,
  plugins,
  commands,
  skills,
  sessionFiles,
  approvals,
  terminal,
}

@immutable
class DshCapabilities {
  const DshCapabilities({this.supported = const <DshCapability>{}});

  final Set<DshCapability> supported;

  bool supports(DshCapability capability) => supported.contains(capability);

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is DshCapabilities && setEquals(other.supported, supported);

  @override
  int get hashCode => Object.hashAll(supported);
}

/// Catalog sections that can fail independently. A failed section keeps the
/// remote connected and usable; only that surface shows an explanatory state.
enum DshCatalogSection {
  generalSettings,
  permissionPresets,
  models,
  workspaces,
  plugins,
  commands,
  skills,
}

/// One failed catalog read, kept apart from the sections that succeeded.
@immutable
class DshCatalogFailure {
  const DshCatalogFailure({
    required this.section,
    required this.failure,
    this.detail,
  });

  final DshCatalogSection section;
  final DshFailure failure;
  final String? detail;
}

/// One coherent read of everything the UI shows about a remote.
///
/// [refreshCatalog] replaces it wholesale; live patches patch it. Each family
/// is optional on the wire, so an absent family is an empty collection plus a
/// capability flag, and a failed one is listed in [failures] — never a silent
/// null.
@immutable
class DshCatalogSnapshot {
  const DshCatalogSnapshot({
    this.generalSettings = const DshGeneralSettings(),
    this.permissionPresets = const <DshPermissionPreset>[],
    this.models = const DshModelCatalog(),
    this.workspaces = const <DshWorkspace>[],
    this.ungroupedSessions = const <DshSessionSummary>[],
    this.plugins = const <DshPluginEntry>[],
    this.agentPresets = const <DshAgentPresetGroup>[],
    this.commands = const <DshCommand>[],
    this.skills = const <DshSkill>[],
    this.capabilities = const DshCapabilities(),
    this.failures = const <DshCatalogFailure>[],
    this.loadedAt,
  });

  final DshGeneralSettings generalSettings;
  final List<DshPermissionPreset> permissionPresets;
  final DshModelCatalog models;
  final List<DshWorkspace> workspaces;

  /// Sessions the remote reports outside any workspace (no `workspaceId`), so
  /// the drawer still lists them.
  final List<DshSessionSummary> ungroupedSessions;
  final List<DshPluginEntry> plugins;

  /// Agent preset compositions reported by `pluginInventory/list`; read-only
  /// in v2 because the `agentPresets/*` RPCs are not in core yet.
  final List<DshAgentPresetGroup> agentPresets;
  final List<DshCommand> commands;
  final List<DshSkill> skills;
  final DshCapabilities capabilities;
  final List<DshCatalogFailure> failures;
  final DateTime? loadedAt;

  /// The permission preset title for [id], or null when the remote no longer
  /// lists it.
  String? permissionPresetTitle(String? id) {
    if (id == null) return null;
    for (final preset in permissionPresets) {
      if (preset.id == id) return preset.title;
    }
    return null;
  }

  bool get hasFailures => failures.isNotEmpty;

  /// Every session the remote reports, workspace order first, then the
  /// ungrouped ones.
  List<DshSessionSummary> get allSessions => [
    for (final workspace in workspaces) ...workspace.sessions,
    ...ungroupedSessions,
  ];

  DshCatalogSnapshot copyWith({
    DshGeneralSettings? generalSettings,
    List<DshPermissionPreset>? permissionPresets,
    DshModelCatalog? models,
    List<DshWorkspace>? workspaces,
    List<DshSessionSummary>? ungroupedSessions,
    List<DshPluginEntry>? plugins,
    List<DshAgentPresetGroup>? agentPresets,
    List<DshCommand>? commands,
    List<DshSkill>? skills,
    DshCapabilities? capabilities,
    List<DshCatalogFailure>? failures,
    DateTime? loadedAt,
  }) {
    return DshCatalogSnapshot(
      generalSettings: generalSettings ?? this.generalSettings,
      permissionPresets: permissionPresets ?? this.permissionPresets,
      models: models ?? this.models,
      workspaces: workspaces ?? this.workspaces,
      ungroupedSessions: ungroupedSessions ?? this.ungroupedSessions,
      plugins: plugins ?? this.plugins,
      agentPresets: agentPresets ?? this.agentPresets,
      commands: commands ?? this.commands,
      skills: skills ?? this.skills,
      capabilities: capabilities ?? this.capabilities,
      failures: failures ?? this.failures,
      loadedAt: loadedAt ?? this.loadedAt,
    );
  }
}

// ---------------------------------------------------------------------------
// Live patches
// ---------------------------------------------------------------------------

/// One incremental change the remote pushes after a catalog read.
///
/// `workspace/follow` delivers baselines and deltas; the adapter reduces them
/// to these patches so the state layer only has to merge, not understand the
/// wire. A patch the adapter cannot reduce becomes [DshCatalogInvalidated],
/// which the provider answers with a `refreshCatalog()`.
sealed class DshCatalogPatch {
  const DshCatalogPatch();
}

final class DshSessionUpsert extends DshCatalogPatch {
  const DshSessionUpsert(this.session);

  final DshSessionSummary session;
}

final class DshSessionRemoved extends DshCatalogPatch {
  const DshSessionRemoved(this.sessionId);

  final String sessionId;
}

final class DshWorkspaceUpsert extends DshCatalogPatch {
  const DshWorkspaceUpsert(this.workspace);

  final DshWorkspace workspace;
}

final class DshWorkspaceRemoved extends DshCatalogPatch {
  const DshWorkspaceRemoved(this.workspaceId);

  final String workspaceId;
}

final class DshWorkspaceOrder extends DshCatalogPatch {
  const DshWorkspaceOrder(this.workspaceIds);

  final List<String> workspaceIds;
}

final class DshCatalogInvalidated extends DshCatalogPatch {
  const DshCatalogInvalidated({this.detail});

  final String? detail;
}

/// One live state update for a single session (`session/control` projection).
@immutable
class DshSessionControl {
  const DshSessionControl({
    required this.sessionId,
    this.title,
    this.running = false,
    this.queued = 0,
    this.selectedModel,
    this.permissionPreset,
    this.pendingApprovals = 0,
    this.pendingQuestions = 0,
    this.unread = false,
  });

  final String sessionId;
  final String? title;
  final bool running;
  final int queued;
  final DshModelSelection? selectedModel;
  final String? permissionPreset;
  final int pendingApprovals;
  final int pendingQuestions;
  final bool unread;

  DshSessionControl copyWith({
    String? title,
    bool? running,
    int? queued,
    DshModelSelection? selectedModel,
    String? permissionPreset,
    int? pendingApprovals,
    int? pendingQuestions,
    bool? unread,
  }) {
    return DshSessionControl(
      sessionId: sessionId,
      title: title ?? this.title,
      running: running ?? this.running,
      queued: queued ?? this.queued,
      selectedModel: selectedModel ?? this.selectedModel,
      permissionPreset: permissionPreset ?? this.permissionPreset,
      pendingApprovals: pendingApprovals ?? this.pendingApprovals,
      pendingQuestions: pendingQuestions ?? this.pendingQuestions,
      unread: unread ?? this.unread,
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is DshSessionControl &&
          other.sessionId == sessionId &&
          other.title == title &&
          other.running == running &&
          other.queued == queued &&
          other.selectedModel == selectedModel &&
          other.permissionPreset == permissionPreset &&
          other.pendingApprovals == pendingApprovals &&
          other.pendingQuestions == pendingQuestions &&
          other.unread == unread;

  @override
  int get hashCode => Object.hash(
    sessionId,
    title,
    running,
    queued,
    selectedModel,
    permissionPreset,
    pendingApprovals,
    pendingQuestions,
    unread,
  );
}

/// Everything the state layer receives from a connected link, in one stream, so
/// the adapter owns generation/reconnect and the provider only merges.
sealed class DshRemoteUpdate {
  const DshRemoteUpdate();
}

final class DshCatalogPatchUpdate extends DshRemoteUpdate {
  const DshCatalogPatchUpdate(this.patch);

  final DshCatalogPatch patch;
}

final class DshSessionControlUpdate extends DshRemoteUpdate {
  const DshSessionControlUpdate(this.control);

  final DshSessionControl control;
}

// ---------------------------------------------------------------------------
// One open session
// ---------------------------------------------------------------------------

/// How a prompt is submitted while a turn is running.
enum DshPromptMode { queue, steer }

/// Whether one prompt attachment travels inline (image) or as an upload receipt
/// (any other file).
enum DshAttachmentKind { image, file }

/// One attachment reference handed to a prompt, or one already on a user row.
///
/// Files are uploaded first and referenced by the `uploadFileBinary` receipt;
/// images travel inline as base64 in `session/prompt` and are referenced by the
/// stored attachment id when they come back as history.
@immutable
class DshPromptAttachment {
  const DshPromptAttachment({
    required this.receiptId,
    this.kind = DshAttachmentKind.file,
    this.name,
    this.mediaType,
    this.bytes,
    this.width,
    this.height,
  });

  /// Upload receipt id (files) or stored attachment id (images).
  final String receiptId;
  final DshAttachmentKind kind;
  final String? name;
  final String? mediaType;

  /// Inline image bytes, when the caller already holds them. They are sent in
  /// the prompt's image part, never re-uploaded.
  final List<int>? bytes;
  final int? width;
  final int? height;

  bool get isImage => kind == DshAttachmentKind.image;

  /// True when a composer can build a prompt part from this reference: images
  /// need their inline bytes, files need an upload receipt.
  bool get isPromptReady =>
      isImage ? (bytes?.isNotEmpty ?? false) : receiptId.trim().isNotEmpty;
}

/// The Host's in-band outcome of one `commands/execute` call.
///
/// Commands answer success/failure in the payload rather than as an RPC error,
/// so the composer shows [text] instead of treating a refusal as a link failure.
@immutable
class DshCommandOutcome {
  const DshCommandOutcome({required this.success, this.text});

  final bool success;
  final String? text;
}

/// One accepted `uploadFileBinary` response: the receipt id the prompt's file
/// part carries.
@immutable
class DshUploadReceipt {
  const DshUploadReceipt({
    required this.receiptId,
    this.name,
    this.mediaType,
    this.width,
    this.height,
  });

  final String receiptId;
  final String? name;
  final String? mediaType;
  final int? width;
  final int? height;
}

// ---------------------------------------------------------------------------
// Context pressure / composer limits (session projections)
// ---------------------------------------------------------------------------

/// `contextPressure` projection: the Host's own token pressure for the session.
///
/// `pressureTokens / contextWindow` is the ring's ratio; [projectedTokens] is
/// the Host's projected total after the next prompt and is shown as a secondary
/// line, never mixed into the ratio.
@immutable
class DshContextPressure {
  const DshContextPressure({
    this.pressureTokens,
    this.projectedTokens,
    this.contextWindow,
  });

  final int? pressureTokens;
  final int? projectedTokens;
  final int? contextWindow;

  bool get hasWindow => (contextWindow ?? 0) > 0;

  bool get isValid =>
      hasWindow && pressureTokens != null && pressureTokens! >= 0;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is DshContextPressure &&
          other.pressureTokens == pressureTokens &&
          other.projectedTokens == projectedTokens &&
          other.contextWindow == contextWindow;

  @override
  int get hashCode =>
      Object.hash(pressureTokens, projectedTokens, contextWindow);
}

/// `imageLimits` projection: the Host's composer image budget.
@immutable
class DshImageLimits {
  const DshImageLimits({
    this.maxImageBytes,
    this.maxImagesPerMessage,
    this.maxMessageImageBytes,
    this.maxImagePixels,
    this.maxImageDimension,
    this.mediaTypes = const <String>[],
  });

  final int? maxImageBytes;
  final int? maxImagesPerMessage;
  final int? maxMessageImageBytes;
  final int? maxImagePixels;
  final int? maxImageDimension;
  final List<String> mediaTypes;

  /// The media types the Host accepts, or Cuplivo's own narrow default when the
  /// Host sent none (the protocol allows omitting the list).
  List<String> get acceptedMediaTypes => mediaTypes.isEmpty
      ? const <String>['image/png', 'image/jpeg', 'image/webp', 'image/gif']
      : mediaTypes;
}

@immutable
class DshTokenUsage {
  const DshTokenUsage({
    this.inputTokens,
    this.outputTokens,
    this.cachedInputTokens,
  });

  final int? inputTokens;
  final int? outputTokens;
  final int? cachedInputTokens;
}

/// A renderable transcript row. The chat slice maps these to Cuplivo widgets;
/// no server/wire type crosses this seam.
sealed class DshTranscriptEntry {
  const DshTranscriptEntry({required this.key});

  /// Stable row identity for list keys/diffing.
  final String key;
}

final class DshUserEntry extends DshTranscriptEntry {
  const DshUserEntry({
    required super.key,
    required this.text,
    this.time,
    this.attachments = const <DshPromptAttachment>[],
  });

  final String text;
  final DateTime? time;
  final List<DshPromptAttachment> attachments;
}

final class DshAssistantEntry extends DshTranscriptEntry {
  const DshAssistantEntry({
    required super.key,
    required this.text,
    this.time,
    this.reasoning = '',
    this.streaming = false,
    this.interrupted = false,
    this.toolCallIds = const <String>[],
    this.providerId,
    this.modelId,
    this.usage,
  });

  final String text;

  /// When the Host recorded this message; null when the row carried no stamp.
  final DateTime? time;
  final String reasoning;
  final bool streaming;
  final bool interrupted;
  final List<String> toolCallIds;
  final String? providerId;
  final String? modelId;
  final DshTokenUsage? usage;
}

enum DshToolStatus {
  streaming,
  running,
  awaitingApproval,
  succeeded,
  failed,
  denied,
  cancelled,
}

final class DshToolEntry extends DshTranscriptEntry {
  const DshToolEntry({
    required super.key,
    required this.callId,
    required this.name,
    required this.arguments,
    required this.status,
    this.resultText,
    this.failureText,
    this.pendingApprovalId,
  });

  final String callId;
  final String name;

  /// Raw JSON argument text (the tool card formats it).
  final String arguments;
  final DshToolStatus status;
  final String? resultText;
  final String? failureText;
  final String? pendingApprovalId;
}

enum DshNoticeKind {
  error,
  aborted,
  interrupted,
  retry,
  command,
  approval,
  info,
}

final class DshNoticeEntry extends DshTranscriptEntry {
  const DshNoticeEntry({
    required super.key,
    required this.kind,
    required this.text,
    this.time,
  });

  final DshNoticeKind kind;
  final String text;
  final DateTime? time;
}

/// A host approval request the transcript cannot answer by itself.
@immutable
class DshApprovalRequest {
  const DshApprovalRequest({
    required this.id,
    required this.title,
    this.summary,
    this.toolName,
    this.toolCallId,
  });

  final String id;
  final String title;
  final String? summary;
  final String? toolName;
  final String? toolCallId;
}

/// One question of a host question request.
@immutable
class DshQuestion {
  const DshQuestion({
    required this.id,
    required this.prompt,
    this.options = const <String>[],
    this.allowMultiple = false,
  });

  final String id;
  final String prompt;
  final List<String> options;
  final bool allowMultiple;
}

@immutable
class DshQuestionRequest {
  const DshQuestionRequest({
    required this.id,
    required this.title,
    this.questions = const <DshQuestion>[],
  });

  final String id;
  final String title;
  final List<DshQuestion> questions;
}

@immutable
class DshQuestionAnswer {
  const DshQuestionAnswer({required this.questionId, required this.text});

  final String questionId;
  final String text;
}

/// The chat page's complete read model for one open session.
///
/// The adapter folds the protocol projection into this full-state view on every
/// change, so the Flutter controller only replaces its state and repaints. That
/// is simpler than delta replay and keeps reconnect semantics in one place (a
/// new snapshot after every generation, per the client contract).
@immutable
class DshSessionView {
  const DshSessionView({
    required this.sessionId,
    required this.entries,
    this.title,
    this.running = false,
    this.streaming = false,
    this.stale = false,
    this.hasOlderHistory = false,
    this.queued = 0,
    this.selectedModel,
    this.permissionPreset,
    this.pendingApprovals = const <DshApprovalRequest>[],
    this.pendingQuestions = const <DshQuestionRequest>[],
    this.usage,
    this.contextPressure,
    this.imageLimits,
    this.error,
  });

  final String sessionId;
  final List<DshTranscriptEntry> entries;
  final String? title;
  final bool running;

  /// A live assistant draft is being folded (the durable message replaces it).
  final bool streaming;

  /// Showing the last known transcript after a lost generation.
  final bool stale;
  final bool hasOlderHistory;
  final int queued;
  final DshModelSelection? selectedModel;
  final String? permissionPreset;
  final List<DshApprovalRequest> pendingApprovals;
  final List<DshQuestionRequest> pendingQuestions;
  final DshTokenUsage? usage;

  /// The Host's own token pressure for the context ring; null when the
  /// projection is absent, which hides the ring instead of guessing a window.
  final DshContextPressure? contextPressure;

  /// The Host's composer image budget; null when the projection is absent.
  final DshImageLimits? imageLimits;

  /// Non-null while the live link is broken; the transcript stays rendered.
  final DshFailure? error;
}

// ---------------------------------------------------------------------------
// Workspace files (right rail)
// ---------------------------------------------------------------------------

@immutable
class DshFileEntry {
  const DshFileEntry({
    required this.name,
    required this.path,
    this.isDirectory = false,
    this.size,
    this.modifiedAt,
  });

  final String name;
  final String path;
  final bool isDirectory;
  final int? size;
  final DateTime? modifiedAt;
}

@immutable
class DshFileStat {
  const DshFileStat({
    required this.path,
    required this.isDirectory,
    this.size,
    this.modifiedAt,
    this.absolutePath,
    this.version,
    this.mediaType,
  });

  final String path;
  final bool isDirectory;
  final int? size;
  final DateTime? modifiedAt;

  /// Absolute Host path returned by `workspaceFiles/stat`; `GET /api/file`
  /// consumes it for the WebView-based previews (PDF/office).
  final String? absolutePath;

  /// Cache/version token for `GET /api/file?path=…&v=…`.
  final String? version;

  /// Host-reported media type, when the workspace listing carries one.
  final String? mediaType;

  bool get hasAbsolutePath => absolutePath != null && absolutePath!.isNotEmpty;
}
