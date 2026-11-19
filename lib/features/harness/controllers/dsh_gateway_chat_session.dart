import 'dart:async';
import 'dart:convert';

import 'package:Cuplivo/features/harness/controllers/dsh_chat_session.dart'
    as chat;
import 'package:Cuplivo/features/harness/models/dsh_remote.dart';
import 'package:Cuplivo/features/harness/state/dsh_connections_provider.dart';
import 'package:Cuplivo/features/harness/state/dsh_gateway.dart';
import 'package:Cuplivo/features/harness/state/dsh_gateway_models.dart' as gw;

/// Stage-2 binding: one [chat.DshChatSession] over the gateway's session
/// handle.
///
/// The adapter never constructs a client and never talks HTTP: it opens the
/// handle through [DshConnectionsProvider.openSession] (the only entry point
/// the state layer exposes), folds every full-state `DshSessionView` into the
/// chat's view models, and maps the composer's intents back to handle calls.
/// Dedicated write paths intentionally follow the protocol:
///
/// - permission changes go through the server's command path
///   (`runPermissionCommand`), never a set-permission RPC;
/// - model/write methods complete only after the server accepted the write, so
///   `ChatInputBar` clears the draft only on a real acceptance.
class DshGatewayChatSession extends chat.DshChatSession {
  DshGatewayChatSession({
    required DshConnectionsProvider connections,
    required DshRemote remote,
    required String sessionId,
  }) : _connections = connections,
       _remote = remote,
       _sessionId = sessionId {
    _connections.addListener(_handleConnectionsChanged);
    unawaited(_attach());
  }

  final DshConnectionsProvider _connections;
  final DshRemote _remote;
  final String _sessionId;

  DshSessionHandle? _handle;
  StreamSubscription<gw.DshSessionView>? _views;
  gw.DshSessionView? _view;
  bool _disposed = false;
  bool _sending = false;
  bool _changingPermission = false;
  bool _catalogLoading = false;
  gw.DshFailure? _linkFailure;
  chat.DshChatViewState _state = const chat.DshChatViewState();
  Timer? _streamFlush;

  /// The adapter folds a *full* view per frame, so a token-by-token stream can
  /// notify faster than the list should rebuild. Streaming frames coalesce into
  /// one repaint per [streamingFrameInterval]; anything that is not a live
  /// draft (durable message, error, request) paints immediately.
  static const Duration streamingFrameInterval = Duration(milliseconds: 50);

  @override
  chat.DshChatViewState get state => _state;

  @override
  bool get canSend =>
      !_disposed &&
      _handle != null &&
      _view != null &&
      _linkFailure == null &&
      (_view?.error == null);

  String get _remoteId => _remote.id;

  // -------------------------------------------------------------------------
  // Lifecycle
  // -------------------------------------------------------------------------

  Future<void> _attach() async {
    if (_disposed) return;
    try {
      final handle = await _connections.openSession(_remoteId, _sessionId);
      if (_disposed) {
        unawaited(handle.close());
        return;
      }
      _handle = handle;
      _subscribe(handle);
      final current = handle.current;
      if (current != null) {
        _view = current;
      }
      _linkFailure = null;
    } on DshGatewayException catch (error) {
      _linkFailure = error.failure;
    } catch (_) {
      _linkFailure = gw.DshFailure.unknown;
    }
    _rebuild();
  }

  void _subscribe(DshSessionHandle handle) {
    unawaited(_views?.cancel());
    _views = handle.views.listen(
      (view) {
        if (_disposed) return;
        _view = view;
        _linkFailure = null;
        if (view.streaming) {
          _scheduleStreamingRebuild();
        } else {
          _streamFlush?.cancel();
          _streamFlush = null;
          _rebuild();
        }
      },
      onError: (Object error) {
        if (_disposed) return;
        _linkFailure = error is DshGatewayException
            ? error.failure
            : gw.DshFailure.unknown;
        _rebuild();
      },
    );
  }

  void _scheduleStreamingRebuild() {
    if (_streamFlush != null) return;
    _streamFlush = Timer(streamingFrameInterval, () {
      _streamFlush = null;
      _rebuild();
    });
  }

  void _handleConnectionsChanged() {
    if (_disposed) return;
    _rebuild();
  }

  @override
  void dispose() {
    _disposed = true;
    _streamFlush?.cancel();
    _streamFlush = null;
    _connections.removeListener(_handleConnectionsChanged);
    unawaited(_views?.cancel());
    final handle = _handle;
    _handle = null;
    if (handle != null) unawaited(handle.close());
    super.dispose();
  }

  // -------------------------------------------------------------------------
  // Mapping: transcript
  // -------------------------------------------------------------------------

  List<chat.DshChatItem> _mapEntries(gw.DshSessionView? view) {
    if (view == null || view.entries.isEmpty) {
      return const <chat.DshChatItem>[];
    }
    final tools = <String, gw.DshToolEntry>{};
    for (final entry in view.entries) {
      if (entry is gw.DshToolEntry) tools[entry.callId] = entry;
    }
    final consumed = <String>{};
    final items = <chat.DshChatItem>[];
    for (final entry in view.entries) {
      if (entry is gw.DshUserEntry) {
        items.add(
          chat.DshUserMessageItem(
            id: entry.key,
            timestamp: entry.time,
            text: entry.text,
          ),
        );
        continue;
      }
      if (entry is gw.DshAssistantEntry) {
        final toolCalls = <chat.DshToolCall>[];
        for (final callId in entry.toolCallIds) {
          final tool = tools[callId];
          if (tool == null) continue;
          consumed.add(callId);
          toolCalls.add(_mapTool(tool));
        }
        items.add(
          chat.DshAssistantMessageItem(
            id: entry.key,
            text: entry.text,
            reasoning: entry.reasoning.trim().isEmpty
                ? const <chat.DshReasoningSegment>[]
                : <chat.DshReasoningSegment>[
                    chat.DshReasoningSegment(text: entry.reasoning),
                  ],
            tools: toolCalls,
            isStreaming: entry.streaming,
            interrupted: entry.interrupted,
            modelId: entry.modelId,
            providerId: entry.providerId,
            usage: _mapUsage(entry.usage),
          ),
        );
        continue;
      }
      if (entry is gw.DshNoticeEntry) {
        items.add(
          chat.DshNoticeItem(
            id: entry.key,
            timestamp: entry.time,
            kind: _mapNoticeKind(entry.kind),
            text: entry.text,
          ),
        );
        continue;
      }
      // A tool row renders through the assistant that names it in
      // `toolCallIds`, or as an orphan group below when no assistant does.
    }
    final orphans = <gw.DshToolEntry>[
      for (final entry in tools.values)
        if (!consumed.contains(entry.callId)) entry,
    ];
    if (orphans.isNotEmpty) {
      items.add(
        chat.DshAssistantMessageItem(
          id: 'tools:${orphans.first.key}',
          tools: <chat.DshToolCall>[
            for (final entry in orphans) _mapTool(entry),
          ],
        ),
      );
    }
    return List<chat.DshChatItem>.unmodifiable(items);
  }

  chat.DshToolCall _mapTool(gw.DshToolEntry tool) {
    return chat.DshToolCall(
      id: tool.callId,
      name: tool.name,
      arguments: _decodeArguments(tool.arguments),
      resultText: tool.resultText ?? tool.failureText,
      isRunning:
          tool.status == gw.DshToolStatus.streaming ||
          tool.status == gw.DshToolStatus.running ||
          tool.status == gw.DshToolStatus.awaitingApproval,
      isError: tool.status == gw.DshToolStatus.failed,
    );
  }

  static Map<String, dynamic> _decodeArguments(String raw) {
    final text = raw.trim();
    if (text.isEmpty) return const <String, dynamic>{};
    try {
      final decoded = jsonDecode(text);
      if (decoded is Map<String, dynamic>) return decoded;
      if (decoded is Map) {
        return <String, dynamic>{
          for (final entry in decoded.entries)
            entry.key.toString(): entry.value,
        };
      }
      return <String, dynamic>{'raw': raw};
    } catch (_) {
      return <String, dynamic>{'raw': raw};
    }
  }

  static chat.DshUsage? _mapUsage(gw.DshTokenUsage? usage) {
    if (usage == null) return null;
    final prompt = usage.inputTokens;
    final completion = usage.outputTokens;
    final total = prompt != null && completion != null
        ? prompt + completion
        : null;
    if (prompt == null && completion == null && total == null) return null;
    return chat.DshUsage(
      promptTokens: prompt,
      completionTokens: completion,
      totalTokens: total,
    );
  }

  static chat.DshNoticeKind _mapNoticeKind(gw.DshNoticeKind kind) {
    return switch (kind) {
      gw.DshNoticeKind.error => chat.DshNoticeKind.error,
      gw.DshNoticeKind.aborted ||
      gw.DshNoticeKind.interrupted => chat.DshNoticeKind.cancelled,
      gw.DshNoticeKind.retry ||
      gw.DshNoticeKind.command ||
      gw.DshNoticeKind.approval ||
      gw.DshNoticeKind.info => chat.DshNoticeKind.info,
    };
  }

  // -------------------------------------------------------------------------
  // Mapping: model catalog, permissions, host requests
  // -------------------------------------------------------------------------

  chat.DshModelCatalog _mapCatalog(gw.DshCatalogSnapshot? catalog) {
    if (catalog == null) {
      return chat.DshModelCatalog(isLoading: _catalogLoading);
    }
    final groups = <chat.DshModelProviderGroup>[
      for (final provider in catalog.models.providers)
        chat.DshModelProviderGroup(
          id: provider.id,
          name: provider.title,
          failureMessage: provider.failureMessage,
          models: <chat.DshModelOption>[
            for (final model in provider.models)
              chat.DshModelOption(
                id: model.modelId,
                name: model.title,
                reasoningEfforts: <chat.DshReasoningEffort>[
                  for (final effort in model.reasoningEfforts)
                    chat.DshReasoningEffort(id: effort.id, name: effort.title),
                ],
                defaultReasoningEffortId: model.defaultReasoningEffortId,
              ),
          ],
        ),
    ];
    final failures = <chat.DshModelCatalogFailure>[
      for (final failure in catalog.failures)
        if (failure.section == gw.DshCatalogSection.models)
          chat.DshModelCatalogFailure(
            id: 'models',
            name: failure.section.name,
            message: failure.detail,
          ),
    ];
    return chat.DshModelCatalog(
      groups: groups,
      failures: failures,
      defaultSelection: _mapSelection(catalog.models.defaultSelection),
      isLoading: _catalogLoading,
    );
  }

  chat.DshPermissionState? _mapPermissions(gw.DshCatalogSnapshot? catalog) {
    final presets =
        catalog?.permissionPresets ?? const <gw.DshPermissionPreset>[];
    if (presets.isEmpty) return null;
    return chat.DshPermissionState(
      options: <chat.DshPermissionOption>[
        for (final preset in presets)
          chat.DshPermissionOption(
            value: preset.id,
            name: preset.title,
            description: preset.description,
          ),
      ],
      currentValue: _view?.permissionPreset ?? '',
      isChanging: _changingPermission,
    );
  }

  List<chat.DshPendingApproval> _mapApprovals() {
    final requests = _view?.pendingApprovals ?? const <gw.DshApprovalRequest>[];
    return <chat.DshPendingApproval>[
      for (final request in requests)
        chat.DshPendingApproval(
          id: request.id,
          toolName: request.toolName ?? request.title,
          reason: request.summary,
          callId: request.toolCallId,
        ),
    ];
  }

  List<chat.DshPendingQuestion> _mapQuestions() {
    final requests = _view?.pendingQuestions ?? const <gw.DshQuestionRequest>[];
    return <chat.DshPendingQuestion>[
      for (final request in requests)
        chat.DshPendingQuestion(
          id: request.id,
          questions: <chat.DshUserQuestion>[
            for (final question in request.questions)
              chat.DshUserQuestion(
                id: question.id,
                question: question.prompt,
                options: <chat.DshQuestionOption>[
                  for (final option in question.options)
                    chat.DshQuestionOption(label: option),
                ],
                multiSelect: question.allowMultiple,
              ),
          ],
        ),
    ];
  }

  String? _workspaceLabel(gw.DshCatalogSnapshot? catalog) {
    if (catalog == null) return null;
    for (final workspace in catalog.workspaces) {
      for (final session in workspace.sessions) {
        if (session.id != _sessionId) continue;
        final path = (workspace.path ?? '').trim();
        if (path.isNotEmpty) return path;
        final cwd = (session.cwd ?? '').trim();
        if (cwd.isNotEmpty) return cwd;
        final title = workspace.title.trim();
        return title.isEmpty ? null : title;
      }
    }
    for (final session in catalog.ungroupedSessions) {
      if (session.id != _sessionId) continue;
      final cwd = (session.cwd ?? '').trim();
      return cwd.isEmpty ? null : cwd;
    }
    return null;
  }

  static chat.DshModelSelection? _mapSelection(
    gw.DshModelSelection? selection,
  ) {
    if (selection == null) return null;
    return chat.DshModelSelection(
      providerId: selection.providerId,
      modelId: selection.modelId,
      reasoningEffortId: selection.reasoningEffortId,
    );
  }

  static gw.DshModelSelection _mapSelectionToGateway(
    chat.DshModelSelection selection,
  ) {
    return gw.DshModelSelection(
      providerId: selection.providerId,
      modelId: selection.modelId,
      reasoningEffortId: selection.reasoningEffortId,
    );
  }

  static chat.DshConnectionProblem? _mapFailure(gw.DshFailure? failure) {
    return switch (failure) {
      null => null,
      gw.DshFailure.notConfigured => chat.DshConnectionProblem.notConfigured,
      gw.DshFailure.unreachable => chat.DshConnectionProblem.unreachable,
      gw.DshFailure.auth => chat.DshConnectionProblem.auth,
      gw.DshFailure.protocol => chat.DshConnectionProblem.protocol,
      gw.DshFailure.unsupported => chat.DshConnectionProblem.unsupported,
      gw.DshFailure.unknown => chat.DshConnectionProblem.unknown,
    };
  }

  void _rebuild() {
    if (_disposed) return;
    final catalog = _connections.catalogFor(_remoteId);
    final view = _view;
    _state = chat.DshChatViewState(
      items: _mapEntries(view),
      title: view?.title,
      workspaceLabel: _workspaceLabel(catalog),
      running: view?.running ?? false,
      isSending: _sending,
      queuedPromptCount: view?.queued ?? 0,
      stale: view?.stale ?? false,
      connectionProblem: _mapFailure(_linkFailure ?? view?.error),
      modelSelection: _mapSelection(
        view?.selectedModel ?? catalog?.models.defaultSelection,
      ),
      modelCatalog: _mapCatalog(catalog),
      permissions: _mapPermissions(catalog),
      approvals: _mapApprovals(),
      questions: _mapQuestions(),
    );
    notifyListeners();
  }

  DshSessionHandle _requireHandle() {
    final handle = _handle;
    if (handle == null) {
      throw const DshGatewayException(gw.DshFailure.unreachable);
    }
    return handle;
  }

  // -------------------------------------------------------------------------
  // Composer intents
  // -------------------------------------------------------------------------

  @override
  Future<chat.DshPromptSendResult> sendPrompt(String text) async {
    if (!canSend) {
      return const chat.DshPromptSendResult.rejected(null);
    }
    final handle = _handle!;
    _sending = true;
    _rebuild();
    try {
      await handle.prompt(text);
      return const chat.DshPromptSendResult.accepted();
    } on DshGatewayException catch (error) {
      return chat.DshPromptSendResult.rejected(error.detail);
    } catch (_) {
      return const chat.DshPromptSendResult.rejected(null);
    } finally {
      _sending = false;
      _rebuild();
    }
  }

  @override
  Future<void> cancelTurn() => _requireHandle().cancel();

  @override
  Future<chat.DshModelSelection?> selectModel(
    chat.DshModelSelection selection,
  ) async {
    await _requireHandle().selectModel(_mapSelectionToGateway(selection));
    return selection;
  }

  @override
  Future<void> refreshModelCatalog() async {
    if (_catalogLoading || _disposed) return;
    _catalogLoading = true;
    _rebuild();
    try {
      await _connections.refreshCatalog(_remoteId);
    } finally {
      _catalogLoading = false;
      _rebuild();
    }
  }

  @override
  Future<void> setPermission(String value) async {
    if (_changingPermission) return;
    _changingPermission = true;
    _rebuild();
    try {
      await _requireHandle().runPermissionCommand(value);
    } finally {
      _changingPermission = false;
      _rebuild();
    }
  }

  // -------------------------------------------------------------------------
  // Host requests
  // -------------------------------------------------------------------------

  gw.DshApprovalRequest _approvalById(String requestId) {
    final requests = _view?.pendingApprovals ?? const <gw.DshApprovalRequest>[];
    for (final request in requests) {
      if (request.id == requestId) return request;
    }
    throw const DshGatewayException(gw.DshFailure.protocol);
  }

  gw.DshQuestionRequest _questionById(String requestId) {
    final requests = _view?.pendingQuestions ?? const <gw.DshQuestionRequest>[];
    for (final request in requests) {
      if (request.id == requestId) return request;
    }
    throw const DshGatewayException(gw.DshFailure.protocol);
  }

  @override
  Future<void> answerApproval(String requestId, {required bool allow}) {
    final request = _approvalById(requestId);
    return _requireHandle().answerApproval(request, approved: allow);
  }

  @override
  Future<void> answerQuestions(
    String requestId,
    List<chat.DshQuestionAnswer> answers,
  ) {
    final request = _questionById(requestId);
    return _requireHandle().answerQuestions(request, <gw.DshQuestionAnswer>[
      for (final answer in answers)
        gw.DshQuestionAnswer(
          questionId: answer.questionId,
          text: _answerText(answer),
        ),
    ]);
  }

  static String _answerText(chat.DshQuestionAnswer answer) {
    final custom = (answer.custom ?? '').trim();
    if (custom.isNotEmpty) return custom;
    return answer.selected.join(', ');
  }

  @override
  Future<void> rejectQuestions(String requestId) {
    final request = _questionById(requestId);
    return _requireHandle().rejectQuestions(request);
  }

  // -------------------------------------------------------------------------
  // Reconnect
  // -------------------------------------------------------------------------

  @override
  Future<void> reload() async {
    await _views?.cancel();
    _views = null;
    final handle = _handle;
    _handle = null;
    _view = null;
    if (handle != null) unawaited(handle.close());
    final status = await _connections.retry(_remoteId);
    if (_disposed) return;
    if (status.isFailed) {
      _linkFailure = status.failure;
      _rebuild();
      return;
    }
    _linkFailure = null;
    await _attach();
  }
}
