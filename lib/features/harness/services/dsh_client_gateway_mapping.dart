// Pure mapping from the protocol client's domain types to the gateway's view
// models.
//
// Everything here is a total function over client-owned values: no sockets, no
// clocks, no Flutter. That is what makes the adapter reviewable — the wire
// semantics stay in `lib/core/dsh/` and this file only renames/pivots them into
// the shapes the home, chat and settings slices render.

import 'dart:convert';

import 'package:Cuplivo/core/dsh/dsh_catalog.dart' as dsh;
import 'package:Cuplivo/core/dsh/dsh_errors.dart' as dsh;
import 'package:Cuplivo/core/dsh/dsh_events.dart' as dsh;
import 'package:Cuplivo/core/dsh/dsh_models.dart' as dsh;
import 'package:Cuplivo/core/dsh/dsh_projection.dart' as dsh;
import 'package:Cuplivo/core/dsh/dsh_session.dart' as dsh;
import 'package:Cuplivo/core/dsh/dsh_transport.dart' as dsh;

import '../state/dsh_gateway.dart';

const String _endpointSettings = 'settings/describe';
const String _endpointPermissionPresets = 'permissionPresets/catalog';
const String _endpointModelCatalog = 'session/modelCatalog';
const String _endpointWorkspaces = 'workspace/follow';
const String _endpointPlugins = 'pluginInventory/list';
const String _endpointCommands = 'commands/list';
const String _endpointSkills = 'skills/list';
const String _endpointFiles = 'workspaceFiles/list';

// ---------------------------------------------------------------------------
// Failures and link status
// ---------------------------------------------------------------------------

/// The user-actionable class of one client failure.
DshFailure dshFailureFromClient(dsh.DshException? error) {
  return switch (error) {
    null => DshFailure.unknown,
    dsh.DshAuthException() => DshFailure.auth,
    dsh.DshTransportException() => DshFailure.unreachable,
    dsh.DshUnsupportedException() => DshFailure.unsupported,
    dsh.DshEndpointException() => DshFailure.protocol,
    dsh.DshProtocolException() => DshFailure.protocol,
    dsh.DshClosedException() => DshFailure.unreachable,
    dsh.DshFileException(:final statusCode) =>
      statusCode == 404 ? DshFailure.unsupported : DshFailure.unknown,
    dsh.DshRemoteException(:final code) =>
      code.contains('auth') || code.contains('unauthorized')
          ? DshFailure.auth
          : code.contains('not-found') ||
                code.contains('unsupported') ||
                // `workspace-file/not-text` is a read refusal for a binary
                // body: the file exists, the preview kind is unsupported.
                code.contains('not-text')
          ? DshFailure.unsupported
          : DshFailure.unknown,
  };
}

/// Wraps a client failure for the gateway seam. Raw DSH exceptions never cross
/// it, exactly as `gateway-api.md` promises.
DshGatewayException dshGatewayExceptionFromClient(dsh.DshException error) {
  return DshGatewayException(
    dshFailureFromClient(error),
    detail: error.message,
  );
}

DshLinkStatus dshLinkStatusFromClient(dsh.DshConnectionState state) {
  return switch (state) {
    dsh.DshConnectionState.idle => const DshLinkStatus.idle(),
    dsh.DshConnectionState.connecting => const DshLinkStatus.connecting(),
    dsh.DshConnectionState.reconnecting => const DshLinkStatus.connecting(),
    dsh.DshConnectionState.connected => const DshLinkStatus.ready(),
    dsh.DshConnectionState.unauthorized => const DshLinkStatus.failed(
      DshFailure.auth,
      detail: 'the Host rejected this cookie; paste a fresh WebUI link',
    ),
    dsh.DshConnectionState.closed => const DshLinkStatus.idle(),
  };
}

// ---------------------------------------------------------------------------
// Stored credential codec
// ---------------------------------------------------------------------------

/// The cookie sits in the platform secure store as JSON; the launch token is
/// never part of it.
String encodeDshCookie(dsh.DshCookie cookie) => jsonEncode(cookie.toJson());

/// Decodes a persisted cookie; null means "no usable credential" (absent,
/// corrupt or not a cookie), never a partial credential.
dsh.DshCookie? decodeDshCookie(String? stored) {
  final text = stored?.trim();
  if (text == null || text.isEmpty) return null;
  try {
    final decoded = jsonDecode(text);
    if (decoded is! Map) return null;
    final cookie = dsh.DshCookie.fromJson(dsh.jsonMap(decoded));
    if (cookie.name.isEmpty || cookie.value.isEmpty) return null;
    return cookie;
  } on FormatException {
    return null;
  }
}

// ---------------------------------------------------------------------------
// Catalog
// ---------------------------------------------------------------------------

DshModelSelection? mapDshModelSelection(dsh.DshModelSelection? source) {
  if (source == null || source.provider.isEmpty || source.model.isEmpty) {
    return null;
  }
  return DshModelSelection(
    providerId: source.provider,
    modelId: source.model,
    reasoningEffortId: source.reasoningEffort,
  );
}

dsh.DshModelSelection mapModelSelectionToClient(DshModelSelection selection) {
  return dsh.DshModelSelection(
    provider: selection.providerId,
    model: selection.modelId,
    reasoningEffort: selection.reasoningEffortId,
  );
}

DshReasoningEffort mapDshReasoning(dsh.DshReasoningEffort source) {
  return DshReasoningEffort(id: source.id, title: source.name);
}

DshModelCatalog mapDshModelCatalog(dsh.DshModelCatalog source) {
  final failures = <String, String?>{
    for (final failure in source.failures) failure.id: failure.message,
  };
  return DshModelCatalog(
    defaultSelection: mapDshModelSelection(source.defaultSelection),
    providers: [
      for (final group in source.groups)
        DshProviderGroup(
          id: group.id,
          title: group.name,
          models: [
            for (final model in group.models)
              DshModel(
                providerId: group.id,
                modelId: model.id,
                title: model.name,
                reasoningEfforts: [
                  for (final effort in model.reasoning?.efforts ?? const [])
                    mapDshReasoning(effort),
                ],
                defaultReasoningEffortId: model.reasoning?.defaultEffort,
              ),
          ],
          failureMessage: failures[group.id],
        ),
      // A provider whose lookup failed is still listed (disabled with a
      // reason) instead of vanishing from the picker.
      for (final failure in source.failures)
        if (!source.groups.any((group) => group.id == failure.id))
          DshProviderGroup(
            id: failure.id,
            title: failure.name,
            failureMessage: failure.message ?? 'The provider is unavailable',
          ),
    ],
  );
}

DshSessionSummary mapDshSessionSummary(
  dsh.DshSessionSummary source, {
  String? workspaceId,
  Set<String> archivedIds = const <String>{},
  Set<String> pinnedIds = const <String>{},
}) {
  return DshSessionSummary(
    id: source.sessionId,
    title: source.title ?? '',
    workspaceId: workspaceId,
    cwd: source.cwd,
    running: source.running,
    pinned: pinnedIds.contains(source.sessionId),
    archived: archivedIds.contains(source.sessionId),
    blank: source.blank,
    agentPreset: source.agentPreset,
    updatedAt: source.updatedAt,
  );
}

DshCommand mapDshCommand(dsh.DshCommandDescriptor source) {
  return DshCommand(
    name: source.name,
    description: source.description,
    inputHint: source.inputHint,
    takesAttachments: source.inputAttachments,
  );
}

DshSkill mapDshSkill(dsh.DshSkill source) {
  return DshSkill(
    id: source.name,
    title: source.name,
    description: source.description,
  );
}

DshPluginEntry mapDshPluginEntry(dsh.DshPluginInventoryEntry source) {
  return DshPluginEntry(
    id: source.entryId.isNotEmpty ? source.entryId : source.moduleName,
    title: source.title?.resolve('en') ?? source.moduleName,
    moduleName: source.moduleName,
    localizedTitle: source.title?.values ?? const <String, String>{},
    description: source.description?.resolve('en'),
    enabled: source.enabled,
    phase: source.fiberPhase,
    diagnostic: source.diagnostic,
  );
}

DshAgentPresetPlugin mapDshAgentPresetPlugin(dsh.DshPresetPluginRow source) {
  return DshAgentPresetPlugin(
    moduleName: source.moduleName,
    title: source.title?.resolve('en'),
    localizedTitle: source.title?.values ?? const <String, String>{},
    enabled: source.enabled,
    conditional: source.conditional,
    condition: source.condition,
    phase: source.fiberPhase,
  );
}

DshAgentPresetGroup mapDshAgentPresetGroup(
  dsh.DshAgentPresetPluginGroup source,
) {
  return DshAgentPresetGroup(
    id: source.id,
    name: source.name,
    isDefault: source.isDefault,
    broken: source.broken,
    plugins: [for (final row in source.rows) mapDshAgentPresetPlugin(row)],
  );
}

/// The two settings the brief exposes, read back from the server truth.
DshGeneralSettings mapDshGeneralSettings(dsh.DshCatalogSnapshot source) {
  final logNs = source.settings.namespace('session-log-deepseek');
  final logValue = dsh.jsonMap(logNs?.value);
  return DshGeneralSettings(
    defaultPermissionPresetId: source.permissionPresets.defaultPreset,
    uploadSessionLog: logValue['enabled'] == true,
  );
}

DshCapabilities _mapCapabilities(dsh.DshCapabilities capabilities) {
  final supported = <DshCapability>{};
  if (capabilities.supports(_endpointModelCatalog)) {
    supported.add(DshCapability.modelCatalog);
  }
  if (capabilities.supports(_endpointWorkspaces)) {
    supported.add(DshCapability.workspaces);
  }
  if (capabilities.supports(_endpointPlugins)) {
    supported.add(DshCapability.plugins);
  }
  if (capabilities.supports(_endpointCommands)) {
    supported.add(DshCapability.commands);
  }
  if (capabilities.supports(_endpointSkills)) {
    supported.add(DshCapability.skills);
  }
  if (capabilities.supports(_endpointFiles)) {
    supported.add(DshCapability.sessionFiles);
  }
  // Approvals/questions are mux waterfalls, not HTTP endpoints: any connected
  // 0.2.2 Host can raise them, so the chat surface always offers the controls
  // and simply never sees a request from a Host that does not.
  supported.add(DshCapability.approvals);
  return DshCapabilities(supported: supported);
}

List<DshCatalogFailure> _mapCatalogFailures(dsh.DshCapabilities capabilities) {
  const sections = <String, DshCatalogSection>{
    _endpointSettings: DshCatalogSection.generalSettings,
    _endpointPermissionPresets: DshCatalogSection.permissionPresets,
    _endpointModelCatalog: DshCatalogSection.models,
    _endpointWorkspaces: DshCatalogSection.workspaces,
    _endpointPlugins: DshCatalogSection.plugins,
    _endpointCommands: DshCatalogSection.commands,
    _endpointSkills: DshCatalogSection.skills,
  };
  return [
    for (final entry in sections.entries)
      if (capabilities.lookup(entry.key) == false)
        DshCatalogFailure(
          section: entry.value,
          failure: DshFailure.unsupported,
          detail: 'The Host does not expose ${entry.key}',
        ),
  ];
}

/// One coherent read of the remote, flattened into the gateway's view model.
///
/// The client's snapshot already groups sessions, workspaces, archive state and
/// pin order; this function joins them (a workspace session needs its summary)
/// and adds the capability/failure envelope the UI reads.
DshCatalogSnapshot mapDshCatalog(dsh.DshCatalogSnapshot source) {
  final archivedIds = source.archivedSessionIds.toSet();
  final pinnedIds = source.pinnedSessionIds.toSet();
  final summaries = <String, DshSessionSummary>{
    for (final session in source.sessions)
      session.sessionId: mapDshSessionSummary(
        session,
        archivedIds: archivedIds,
        pinnedIds: pinnedIds,
      ),
  };
  final grouped = <String>{};
  final workspaces = <DshWorkspace>[];
  for (final workspace in source.workspaces) {
    final sessions = <DshSessionSummary>[];
    for (final sessionId in workspace.sessionIds) {
      final summary = summaries[sessionId];
      if (summary == null) continue;
      grouped.add(sessionId);
      sessions.add(summary.copyWith(workspaceId: workspace.workspaceId));
    }
    workspaces.add(
      DshWorkspace(
        id: workspace.workspaceId,
        title: workspace.title.isNotEmpty ? workspace.title : workspace.path,
        path: workspace.path,
        sessions: sessions,
      ),
    );
  }
  return DshCatalogSnapshot(
    generalSettings: mapDshGeneralSettings(source),
    permissionPresets: [
      for (final preset in source.permissionPresets.options)
        DshPermissionPreset(
          id: preset.value,
          title: preset.name,
          description: preset.description,
        ),
    ],
    models: mapDshModelCatalog(source.models),
    workspaces: workspaces,
    ungroupedSessions: [
      for (final session in source.sessions)
        if (!grouped.contains(session.sessionId)) summaries[session.sessionId]!,
    ],
    plugins: [
      for (final entry in source.plugins.entries) mapDshPluginEntry(entry),
    ],
    agentPresets: _mapAgentPresets(source),
    capabilities: _mapCapabilities(source.capabilities),
    failures: _mapCatalogFailures(source.capabilities),
    loadedAt: source.loadedAt,
  );
}

/// The roster surfaces the same declarations `pluginInventory/list` groups,
/// but it is the authority for order, copy and activation failures: it is what
/// the Host answers a selection with. Merge the two so a preset that only the
/// roster reports (an activation failure) still renders, and a composition that
/// only the inventory reports keeps its plugin rows for the settings tab.
List<DshAgentPresetGroup> _mapAgentPresets(dsh.DshCatalogSnapshot source) {
  final groups = <String, DshAgentPresetGroup>{
    for (final group in source.plugins.agentPresets)
      group.id: mapDshAgentPresetGroup(group),
  };
  final roster = source.agentPresets;
  if (roster.isEmpty) return groups.values.toList(growable: false);
  final seen = <String>{};
  final merged = <DshAgentPresetGroup>[];
  for (final preset in roster) {
    seen.add(preset.id);
    final group = groups[preset.id];
    merged.add(
      DshAgentPresetGroup(
        id: preset.id,
        name: preset.name ?? group?.name,
        description: preset.description ?? group?.description,
        isDefault: preset.isDefault,
        broken: preset.broken ?? group?.broken,
        plugins: group?.plugins ?? const <DshAgentPresetPlugin>[],
      ),
    );
  }
  for (final entry in groups.entries) {
    if (!seen.contains(entry.key)) merged.add(entry.value);
  }
  return List<DshAgentPresetGroup>.unmodifiable(merged);
}

// ---------------------------------------------------------------------------
// Live patches and session control
// ---------------------------------------------------------------------------

int _inboxCount(Object? inbox) {
  var count = 0;
  for (final key in const ['next-turn', 'next-step']) {
    count += dsh.jsonList(dsh.jsonMap(inbox)[key]).length;
  }
  return count;
}

/// One `session/control` projection as the sidebar reads it.
DshSessionControl mapDshSessionControl({
  required String sessionId,
  dsh.DshSessionProjections? projections,
  dsh.DshSessionSummary? summary,
  bool? running,
}) {
  return DshSessionControl(
    sessionId: sessionId,
    title: projections?.title ?? summary?.title,
    running: running ?? summary?.running ?? false,
    queued: _inboxCount(projections?.inbox),
    selectedModel: mapDshModelSelection(
      projections?.modelSelectionNext ?? summary?.nextModel,
    ),
    permissionPreset: projections?.permissionsCurrent,
  );
}

DshSessionUpsert mapDshSessionAdded(
  dsh.DshSessionSummary source, {
  String? workspaceId,
  Set<String> archivedIds = const <String>{},
  Set<String> pinnedIds = const <String>{},
}) {
  return DshSessionUpsert(
    mapDshSessionSummary(
      source,
      workspaceId: workspaceId,
      archivedIds: archivedIds,
      pinnedIds: pinnedIds,
    ),
  );
}

/// One `workspace/follow` frame as a catalog patch.
///
/// Baselines and the archive/pin sets have no patch shape in the gateway; they
/// invalidate the snapshot and the provider answers with `refreshCatalog()`
/// (which is also the reconnect path). Incremental workspace frames patch.
DshCatalogPatch mapDshWorkspaceUpdate(
  dsh.DshWorkspaceUpdate update, {
  required Map<String, dsh.DshSessionSummary> summaries,
  required Set<String> archivedIds,
  required Set<String> pinnedIds,
}) {
  return switch (update) {
    dsh.DshWorkspaceUpsertUpdate(:final workspace) => DshWorkspaceUpsert(
      DshWorkspace(
        id: workspace.workspaceId,
        title: workspace.title.isNotEmpty ? workspace.title : workspace.path,
        path: workspace.path,
        sessions: [
          for (final sessionId in workspace.sessionIds)
            if (summaries[sessionId] case final summary?)
              mapDshSessionSummary(
                summary,
                workspaceId: workspace.workspaceId,
                archivedIds: archivedIds,
                pinnedIds: pinnedIds,
              ),
        ],
      ),
    ),
    dsh.DshWorkspaceRemoveUpdate(:final workspaceId) => DshWorkspaceRemoved(
      workspaceId,
    ),
    dsh.DshWorkspaceOrderUpdate(:final workspaceIds) => DshWorkspaceOrder(
      workspaceIds,
    ),
    _ => const DshCatalogInvalidated(
      detail: 'workspace/follow delivered a state replacement',
    ),
  };
}

// ---------------------------------------------------------------------------
// Host requests
// ---------------------------------------------------------------------------

DshApprovalRequest mapDshApproval(dsh.DshApprovalRequest source) {
  return DshApprovalRequest(
    id: source.eventId,
    title: source.describe(),
    summary: source.reason,
    toolName: source.toolName,
    toolCallId: source.callId,
  );
}

DshQuestion mapDshQuestion(dsh.DshUserQuestion source) {
  return DshQuestion(
    id: source.id,
    prompt: source.question,
    options: [for (final option in source.options) option.label],
    allowMultiple: source.multiSelect,
  );
}

DshQuestionRequest mapDshQuestionRequest(dsh.DshUserQuestionRequest source) {
  final header = source.questions.isEmpty
      ? null
      : source.questions.first.header;
  return DshQuestionRequest(
    id: source.eventId,
    title: header ?? (source.questions.isEmpty ? 'Question' : 'Questions'),
    questions: [
      for (final question in source.questions) mapDshQuestion(question),
    ],
  );
}

/// Maps the chat UI's answers onto the wire shape: an option label is
/// `selected`, anything else is free `custom` text.
List<dsh.DshQuestionAnswer> mapDshQuestionAnswers(
  DshQuestionRequest request,
  List<DshQuestionAnswer> answers,
) {
  final byId = {
    for (final question in request.questions) question.id: question,
  };
  return [
    for (final answer in answers)
      dsh.DshQuestionAnswer(
        id: answer.questionId,
        selected: [
          if (byId[answer.questionId]?.options.contains(answer.text) ?? false)
            answer.text,
        ],
        custom:
            (byId[answer.questionId]?.options.contains(answer.text) ?? false)
            ? null
            : (answer.text.trim().isEmpty ? null : answer.text),
      ),
  ];
}

/// DSH 0.2.2 has no explicit "decline questions" waterfall. Replying with an
/// empty answer list is the documented approximation: the Host sees every
/// question unanswered and fails the waterfall closed.
List<dsh.DshQuestionAnswer> rejectedDshQuestionAnswers() => const [];

// ---------------------------------------------------------------------------
// Transcript
// ---------------------------------------------------------------------------

DshTokenUsage? _mapUsage(dsh.DshTokenUsage? usage) {
  if (usage == null) return null;
  return DshTokenUsage(
    inputTokens: usage.inputTokens,
    outputTokens: usage.outputTokens,
    cachedInputTokens: usage.cacheReadTokens,
  );
}

DshToolStatus _toolStatus(dsh.DshToolState state) {
  return switch (state) {
    dsh.DshToolState.running => DshToolStatus.running,
    dsh.DshToolState.succeeded => DshToolStatus.succeeded,
    dsh.DshToolState.failed => DshToolStatus.failed,
    dsh.DshToolState.cancelled => DshToolStatus.cancelled,
  };
}

List<DshPromptAttachment> _attachmentsOf(dsh.DshUserMessageRow row) {
  return [
    for (final image in row.images)
      DshPromptAttachment(
        receiptId: image.attachmentId,
        kind: DshAttachmentKind.image,
        name: image.name,
        mediaType: image.mediaType,
        width: image.width,
        height: image.height,
      ),
    for (final file in row.files)
      DshPromptAttachment(receiptId: file.attachmentId, name: file.name),
  ];
}

DshTranscriptEntry _mapRow(dsh.DshChatRow row) {
  return switch (row) {
    dsh.DshUserMessageRow(:final seq) => DshUserEntry(
      key: 'user:$seq',
      text: row.text,
      time: row.time,
      attachments: _attachmentsOf(row),
    ),
    dsh.DshAssistantMessageRow(:final seq) => DshAssistantEntry(
      key: 'assistant:$seq',
      text: row.text,
      time: row.time,
      reasoning: row.reasoning,
      streaming: false,
      interrupted: row.interrupted,
      toolCallIds: [for (final call in row.message.toolCalls) call.id],
      usage: _mapUsage(row.usage),
    ),
    dsh.DshToolRow(:final seq) => DshToolEntry(
      key: 'tool:$seq:${row.callId}',
      callId: row.callId,
      name: row.name,
      arguments: row.arguments,
      status: _toolStatus(row.state),
      resultText: row.state == dsh.DshToolState.failed ? null : row.resultText,
      failureText: row.state == dsh.DshToolState.failed ? row.resultText : null,
    ),
  };
}

/// The renderable rows of one transcript, including the live draft when one is
/// streaming. Keys are stable across rebuilds (seq/attempt based), which is what
/// the chat list uses for identity.
List<DshTranscriptEntry> mapDshTranscriptEntries(dsh.DshTranscript transcript) {
  final entries = <DshTranscriptEntry>[
    for (final row in transcript.rows) _mapRow(row),
  ];
  final draft = transcript.draft;
  if (draft != null && draft.hasContent) {
    final toolIds = <String>[];
    for (final call in draft.toolCalls) {
      final callId = call.id.isNotEmpty
          ? call.id
          : 'live:${draft.attemptId}:${call.index}';
      toolIds.add(callId);
      entries.add(
        DshToolEntry(
          key: 'draft-tool:${draft.attemptId}:${call.index}',
          callId: callId,
          name: call.name,
          arguments: call.arguments,
          status: DshToolStatus.streaming,
        ),
      );
    }
    entries.add(
      DshAssistantEntry(
        key: 'draft:${draft.attemptId}',
        text: draft.text,
        time: draft.time,
        reasoning: draft.reasoning,
        streaming: true,
        toolCallIds: toolIds,
      ),
    );
  }
  final failure = transcript.lastFailure;
  if (failure != null) {
    entries.add(
      DshNoticeEntry(
        key: 'notice:failure:${failure.message.hashCode}',
        kind: DshNoticeKind.error,
        text: failure.message,
      ),
    );
  }
  return List<DshTranscriptEntry>.unmodifiable(entries);
}

/// The full chat read model for one open session, folded from the client store.
DshSessionView mapDshSessionView({
  required String sessionId,
  required dsh.DshSessionStore store,
  DshFailure? linkFailure,
}) {
  final transcript = store.transcript;
  final connection = transcript.connection;
  var error = linkFailure;
  if (error == null) {
    if (connection == dsh.DshConnectionState.unauthorized) {
      error = DshFailure.auth;
    } else if (connection == dsh.DshConnectionState.reconnecting) {
      error = DshFailure.unreachable;
    } else if (connection == dsh.DshConnectionState.closed) {
      error = DshFailure.unreachable;
    }
  }
  final draft = transcript.draft;
  final pendingApprovals = [
    for (final request in transcript.pendingApprovals) mapDshApproval(request),
  ];
  final pendingQuestions = [
    for (final request in transcript.pendingQuestions)
      mapDshQuestionRequest(request),
  ];
  return DshSessionView(
    sessionId: sessionId,
    entries: mapDshTranscriptEntries(transcript),
    title: transcript.title,
    running: transcript.isRunning,
    streaming: draft != null,
    stale: connection == dsh.DshConnectionState.reconnecting,
    hasOlderHistory: store.session.hasMoreHistory,
    queued: _inboxCount(transcript.projections.inbox),
    selectedModel: mapDshModelSelection(transcript.modelSelection),
    permissionPreset: transcript.permissionPreset,
    pendingApprovals: pendingApprovals,
    pendingQuestions: pendingQuestions,
    usage: _mapUsage(transcript.usage),
    contextPressure: mapDshContextPressure(
      transcript.projections['contextPressure'],
    ),
    imageLimits: mapDshImageLimits(transcript.projections['imageLimits']),
    error: error,
  );
}

/// Maps the raw `contextPressure` projection; null when absent so the ring is
/// hidden rather than fed a guessed window.
DshContextPressure? mapDshContextPressure(Object? json) {
  final map = dsh.jsonMap(json);
  if (map.isEmpty) return null;
  return DshContextPressure(
    pressureTokens: dsh.jsonInt(map['pressureTokens']),
    projectedTokens: dsh.jsonInt(map['projectedTokens']),
    contextWindow: dsh.jsonInt(map['contextWindow']),
  );
}

/// Maps the raw `imageLimits` projection; null when absent.
DshImageLimits? mapDshImageLimits(Object? json) {
  final map = dsh.jsonMap(json);
  if (map.isEmpty) return null;
  return DshImageLimits(
    maxImageBytes: dsh.jsonInt(map['maxImageBytes']),
    maxImagesPerMessage: dsh.jsonInt(map['maxImagesPerMessage']),
    maxMessageImageBytes: dsh.jsonInt(map['maxMessageImageBytes']),
    maxImagePixels: dsh.jsonInt(map['maxImagePixels']),
    maxImageDimension: dsh.jsonInt(map['maxImageDimension']),
    mediaTypes: dsh.jsonStringList(map['mediaTypes']),
  );
}

// ---------------------------------------------------------------------------
// Workspace files
// ---------------------------------------------------------------------------

String workspaceFilePathForWire(String path) =>
    path.trim().isEmpty ? '.' : path;

String workspaceFileChildPath(String parent, String name) {
  if (parent.trim().isEmpty) return name;
  return '$parent/$name';
}

DshFileEntry mapWorkspaceFileEntry(Map<String, Object?> json, String path) {
  final name = dsh.jsonString(json['name']) ?? '';
  final type = dsh.jsonString(json['type']) ?? 'file';
  return DshFileEntry(
    name: name,
    path: workspaceFileChildPath(path, name),
    isDirectory: type == 'directory',
    size: dsh.jsonInt(json['size']),
  );
}

DshFileStat mapWorkspaceFileStat(dsh.DshFileStat stat, String path) {
  return DshFileStat(
    path: path,
    isDirectory: false,
    size: stat.bytes,
    absolutePath: stat.hasAbsolutePath ? stat.absolutePath : null,
    version: stat.version,
    mediaType: stat.mediaType,
  );
}
