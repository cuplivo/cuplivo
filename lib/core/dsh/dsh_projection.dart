/// Folds `session/follow` snapshots, committed events and live assistant
/// frames into the rows a chat surface renders.
///
/// Rules held here (from `protocol.md` §5.6):
///
/// * only append-origin events become transcript rows; a replacement
///   `surfaceOp` is model context and is skipped;
/// * `assistant/message` is the durable answer; reasoning is collapsed;
/// * tool calls become tool cards paired with `tool/result` by `callId`;
/// * approvals/questions are not transcript rows (they are host requests), but
///   `approval/asked|decided` close the matching tool card;
/// * unknown event types, block types and projection keys are ignored, not
///   fatal;
/// * a new snapshot is a full rebuild; a higher assistant-stream `revision`
///   voids the previous draft; a stream `end` drops the draft and waits for the
///   durable message.
library;

import 'dsh_errors.dart';
import 'dsh_events.dart';
import 'dsh_models.dart';

/// Pairing state of one tool card.
enum DshToolState { running, succeeded, failed, cancelled }

/// One rendered chat row.
sealed class DshChatRow {
  const DshChatRow({required this.seq});
  final int seq;
}

final class DshUserMessageRow extends DshChatRow {
  const DshUserMessageRow({required super.seq, required this.message});
  final DshMessage message;

  String get text => message.text;
  List<DshImageAttachment> get images => message.images;
  List<DshFileAttachment> get files => message.files;

  /// Matches the prompt's `requestId` for optimistic-row reconciliation.
  String? get requestId => message.source.requestId;
}

final class DshAssistantMessageRow extends DshChatRow {
  const DshAssistantMessageRow({
    required super.seq,
    required this.message,
    this.turn = 0,
    this.step = 0,
    this.usage,
    this.interrupted = false,
  });

  final DshMessage message;
  final int turn;
  final int step;
  final DshTokenUsage? usage;
  final bool interrupted;

  String get text => message.text;
  String get reasoning => message.reasoning;
}

final class DshToolRow extends DshChatRow {
  const DshToolRow({
    required super.seq,
    required this.callId,
    required this.name,
    this.arguments = '',
    this.state = DshToolState.running,
    this.resultText,
    this.meta,
    this.approvalOutcome,
  });

  final String callId;
  final String name;

  /// Raw JSON text of the call (may be partial while streaming).
  final String arguments;
  final DshToolState state;
  final String? resultText;

  /// Tool-owned presentation data (diff/patch/path), opaque to the transcript.
  final Object? meta;
  final DshApprovalOutcome? approvalOutcome;

  Map<String, Object?>? get decodedArguments {
    if (arguments.isEmpty) return null;
    final decoded = tryDecodeJson(arguments);
    return decoded is Map ? jsonMap(decoded) : null;
  }

  DshToolRow copyWith({
    String? name,
    String? arguments,
    DshToolState? state,
    String? resultText,
    Object? meta,
    DshApprovalOutcome? approvalOutcome,
  }) {
    return DshToolRow(
      seq: seq,
      callId: callId,
      name: name ?? this.name,
      arguments: arguments ?? this.arguments,
      state: state ?? this.state,
      resultText: resultText ?? this.resultText,
      meta: meta ?? this.meta,
      approvalOutcome: approvalOutcome ?? this.approvalOutcome,
    );
  }
}

/// A live tool call inside the in-flight draft.
class DshLiveToolCall {
  const DshLiveToolCall({
    required this.index,
    this.id = '',
    this.name = '',
    this.arguments = '',
  });

  final int index;
  final String id;
  final String name;
  final String arguments;

  DshLiveToolCall copyWith({String? id, String? name, String? arguments}) {
    return DshLiveToolCall(
      index: index,
      id: id ?? this.id,
      name: name ?? this.name,
      arguments: arguments ?? this.arguments,
    );
  }
}

/// The in-flight assistant step (transient; replaced by the durable message).
class DshDraft {
  const DshDraft({
    required this.attemptId,
    required this.revision,
    this.turn = 0,
    this.step = 0,
    this.text = '',
    this.reasoning = '',
    this.toolCalls = const [],
    this.usage,
    this.failure,
    this.active = true,
  });

  final String attemptId;
  final int revision;
  final int turn;
  final int step;
  final String text;
  final String reasoning;
  final List<DshLiveToolCall> toolCalls;
  final DshTokenUsage? usage;
  final DshLlmFailure? failure;
  final bool active;

  bool get hasContent =>
      text.isNotEmpty || reasoning.isNotEmpty || toolCalls.isNotEmpty;

  DshDraft copyWith({
    int? revision,
    int? turn,
    int? step,
    String? text,
    String? reasoning,
    List<DshLiveToolCall>? toolCalls,
    DshTokenUsage? usage,
    DshLlmFailure? failure,
    bool? active,
  }) {
    return DshDraft(
      attemptId: attemptId,
      revision: revision ?? this.revision,
      turn: turn ?? this.turn,
      step: step ?? this.step,
      text: text ?? this.text,
      reasoning: reasoning ?? this.reasoning,
      toolCalls: toolCalls ?? this.toolCalls,
      usage: usage ?? this.usage,
      failure: failure ?? this.failure,
      active: active ?? this.active,
    );
  }
}

/// Folds session updates into rows, draft and pending-input state.
class DshTranscript {
  DshSessionHeader? header;
  DshConnectionState connection = DshConnectionState.idle;
  DshException? connectionError;

  DshSessionSnapshot? _snapshot;
  final List<DshChatRow> _rows = [];
  final Map<String, int> _toolRowIndex = {};
  DshDraft? _draft;
  int? _activeTurn;
  DshTurnEndReason? _lastTurnReason;
  DshLlmFailure? _lastFailure;
  DshTokenUsage? _liveUsage;

  Map<String, Object?> _values = {};
  int _asOfSeq = -1;

  final List<DshApprovalRequest> _pendingApprovals = [];
  final List<DshUserQuestionRequest> _pendingQuestions = [];
  final Map<String, String?> _approvalCallIds = {};
  final List<DshApprovalRequest> _decidedApprovals = [];

  /// Rendered rows in transcript order (oldest first).
  List<DshChatRow> get rows => List<DshChatRow>.unmodifiable(_rows);

  /// The transient live step, if one is streaming.
  DshDraft? get draft => _draft;

  DshTokenUsage? get usage => _liveUsage;

  DshSessionHeader? get sessionHeader => header;

  /// Chat title from the projection (null means "New chat").
  String? get title => jsonString(_values['title']);

  /// Projection values at the last applied `seq`.
  DshSessionProjections get projections => DshSessionProjections(
    asOfSeq: _asOfSeq,
    values: Map.unmodifiable(_values),
  );

  DshImageLimits get imageLimits =>
      DshImageLimits.fromJson(_values['imageLimits']);

  /// Current permission preset (`read-only`, `workspace-write`, `danger-full-access`).
  String? get permissionPreset {
    final permissions = jsonMap(_values['permissions']);
    return jsonString(permissions['currentValue']);
  }

  /// Per-session model override (null = follow the rollout default).
  DshModelSelection? get modelSelection {
    final selection = jsonMap(_values['modelSelection']);
    final next = jsonMap(selection['next']);
    return next.isEmpty ? null : DshModelSelection.fromJson(next);
  }

  /// Number of the turn currently running, or null when idle.
  int? get activeTurn => _activeTurn;

  bool get isRunning => _activeTurn != null;

  DshTurnEndReason? get lastTurnReason => _lastTurnReason;

  /// Last model failure (turn error or finish failure); UI shows a banner.
  DshLlmFailure? get lastFailure => _lastFailure;

  List<DshApprovalRequest> get pendingApprovals =>
      List<DshApprovalRequest>.unmodifiable(_pendingApprovals);

  List<DshUserQuestionRequest> get pendingQuestions =>
      List<DshUserQuestionRequest>.unmodifiable(_pendingQuestions);

  /// Approvals already decided in this transcript (for the audit tray).
  List<DshApprovalRequest> get decidedApprovals =>
      List<DshApprovalRequest>.unmodifiable(_decidedApprovals);

  bool get awaitingInput =>
      _pendingApprovals.isNotEmpty || _pendingQuestions.isNotEmpty;

  /// The first prompt row of the turn (used for titles/previews).
  DshUserMessageRow? get firstUserMessage {
    for (final row in _rows) {
      if (row is DshUserMessageRow) return row;
    }
    return null;
  }

  DshSessionSnapshot? get snapshot => _snapshot;

  void setConnection(DshConnectionState state, {DshException? error}) {
    connection = state;
    connectionError = error;
  }

  // ---------------------------------------------------------------------------
  // Snapshot / history

  /// Full rebuild from a follow snapshot (also the reconnect path).
  void applySnapshot(DshSessionSnapshot snapshot) {
    _snapshot = snapshot;
    header = snapshot.header;
    _rows.clear();
    _toolRowIndex.clear();
    _draft = null;
    _liveUsage = null;
    _activeTurn = null;
    _lastTurnReason = null;
    _lastFailure = null;
    _values = Map<String, Object?>.of(snapshot.projections.values);
    _asOfSeq = snapshot.projections.asOfSeq;
    _pendingApprovals.clear();
    _pendingQuestions.clear();
    _approvalCallIds.clear();
    for (final event in snapshot.records) {
      _applyEventToState(event, updateProjections: false);
    }
    final baseline = snapshot.assistantStream.activeAttempt;
    if (baseline != null) {
      _draft = DshDraft(
        attemptId: baseline.attemptId,
        revision: snapshot.assistantStream.revision,
        turn: baseline.turn,
        step: baseline.step,
      );
      for (final chunk in baseline.stream) {
        _applyChunk(chunk);
      }
    }
  }

  /// Prepends older history (ascending `seq`) loaded through `session/page`.
  void prepend(List<DshSessionEvent> events) {
    if (events.isEmpty) return;
    final existing = _rows.map((row) => row.seq).toSet();
    final older = <DshChatRow>[];
    for (final event in events) {
      if (existing.contains(event.seq)) continue;
      final before = _rows.length;
      _applyEventToState(event, updateProjections: false);
      // The helper appends to _rows only; move the appended row into `older`
      // so rows stay in ascending seq order after the prepend.
      if (_rows.length != before) {
        older.add(_rows.removeLast());
      }
    }
    if (older.isEmpty) return;
    _rows.insertAll(0, older);
    _toolRowIndex.clear();
    for (var i = 0; i < _rows.length; i += 1) {
      final row = _rows[i];
      if (row is DshToolRow) _toolRowIndex[row.callId] = i;
    }
  }

  // ---------------------------------------------------------------------------
  // Live updates

  void applyEvent(DshSessionEvent event) {
    _applyEventToState(event, updateProjections: true);
  }

  void applyProjection(String key, Object? value, int seq) {
    if (seq < _asOfSeq) return;
    _asOfSeq = seq;
    _values[key] = value;
    _recomputePendingFromProjections();
  }

  void applyAssistantFrame(DshAssistantStreamFrame frame) {
    final revision = frame.revision;
    switch (frame) {
      case DshAssistantStreamStart():
        final existing = _draft;
        if (existing != null && existing.attemptId == frame.attemptId) return;
        _draft = DshDraft(
          attemptId: frame.attemptId,
          revision: revision,
          turn: frame.turn,
          step: frame.step,
        );
        _activeTurn ??= frame.turn;
      case DshAssistantStreamChunkFrame(:final chunk):
        final existing = _draft;
        if (existing == null || existing.attemptId != frame.attemptId) {
          _draft = DshDraft(
            attemptId: frame.attemptId,
            revision: revision,
            turn: existing?.turn ?? _activeTurn ?? 0,
            step: existing?.step ?? 0,
          );
        } else {
          // `revision` is a per-frame counter, not per-attempt: keep the latest
          // one to drop out-of-order frames without resetting the draft.
          if (revision < existing.revision) return;
          _draft = existing.copyWith(revision: revision);
        }
        _applyChunk(chunk);
      case DshAssistantStreamEnd():
        final draft = _draft;
        if (draft == null || draft.attemptId != frame.attemptId) return;
        _liveUsage = draft.usage;
        _lastFailure = draft.failure ?? _lastFailure;
        // Durable assistant/message (or assistant/attempt) follows; waiting for
        // it prevents a flash of duplicate content.
        _draft = null;
      case DshAssistantStreamUnknown():
        break;
    }
  }

  void applyHostEvent(DshHostEvent event) {
    switch (event) {
      case final DshApprovalRequest request:
        if (_pendingApprovals.any((item) => item.eventId == request.eventId)) {
          return;
        }
        _pendingApprovals.add(request);
      case final DshUserQuestionRequest request:
        if (_pendingQuestions.any((item) => item.eventId == request.eventId)) {
          return;
        }
        _pendingQuestions.add(request);
      case DshHostRequestCancelled(:final eventId):
        _pendingApprovals.removeWhere((item) => item.eventId == eventId);
        _pendingQuestions.removeWhere((item) => item.eventId == eventId);
        _approvalCallIds.remove(eventId);
      default:
        break;
    }
  }

  // ---------------------------------------------------------------------------
  // Internals

  void _applyEventToState(
    DshSessionEvent event, {
    required bool updateProjections,
  }) {
    if (updateProjections) _applyStateEvent(event);
    switch (event) {
      case DshTurnStarted(:final turn):
        _activeTurn = turn;
      case DshTurnEnded(:final reason):
        _activeTurn = null;
        _lastTurnReason = reason;
        _lastFailure = reason.failure ?? _lastFailure;
      case DshUserMessageEvent(:final message):
        if (!event.isAppendOrigin || !event.isHumanPrompt) break;
        _appendRow(DshUserMessageRow(seq: event.seq, message: message));
      case DshAssistantMessageEvent(:final message):
        if (!event.isAppendOrigin) break;
        _appendRow(
          DshAssistantMessageRow(
            seq: event.seq,
            message: message,
            turn: event.turn,
            step: event.step,
            usage: event.usage,
            interrupted: event.interrupted,
          ),
        );
        if (event.usage != null) _liveUsage = event.usage;
        final draft = _draft;
        if (draft != null &&
            (event.turn > draft.turn ||
                (event.turn == draft.turn && event.step >= draft.step))) {
          _draft = null;
        }
      case DshToolCallEvent():
        if (!event.isAppendOrigin) break;
        _upsertTool(
          event.seq,
          event.callId,
          name: event.name,
          arguments: event.arguments,
        );
      case DshToolResultEvent():
        if (!event.isAppendOrigin) break;
        final callId = event.callId;
        final index = _toolRowIndex[callId];
        final resultText = event.message.text;
        if (index != null) {
          final row = _rows[index] as DshToolRow;
          _rows[index] = row.copyWith(
            state: event.isError ? DshToolState.failed : DshToolState.succeeded,
            resultText: resultText,
            meta: event.meta,
          );
        } else {
          _appendRow(
            DshToolRow(
              seq: event.seq,
              callId: callId,
              name: jsonString(event.message.raw['toolName']) ?? 'tool',
              state: event.isError
                  ? DshToolState.failed
                  : DshToolState.succeeded,
              resultText: resultText,
              meta: event.meta,
            ),
          );
        }
      case DshApprovalAskedEvent():
        _approvalCallIds[event.id] = event.callId;
        final callId = event.callId;
        if (callId != null) {
          _patchTool(callId, approvalOutcome: DshApprovalOutcome.unknown);
        }
      case DshApprovalDecidedEvent():
        final callId = _approvalCallIds.remove(event.id);
        _patchTool(callId, approvalOutcome: event.outcome);
        final index = _pendingApprovals.indexWhere(
          (item) => item.eventId == event.id,
        );
        if (index >= 0) {
          _decidedApprovals.add(_pendingApprovals.removeAt(index));
        }
      case DshCommandRunEvent():
        // The visible effect arrives as ordinary events; the row itself is a
        // collapsed notice, which the UI can derive from the projection.
        break;
      default:
        break;
    }
  }

  void _applyStateEvent(DshSessionEvent event) {
    switch (event) {
      case DshTitleEvent(:final title):
        _values['title'] = title;
        _asOfSeq = event.seq;
      case DshModelSelectionEvent(:final selection):
        final existing = jsonMap(_values['modelSelection']);
        _values['modelSelection'] = {...existing, 'next': selection.toJson()};
        _asOfSeq = event.seq;
      case DshPermissionPresetEvent(:final preset):
        _values['permissions'] = {'currentValue': preset};
        _asOfSeq = event.seq;
      case DshWorkingDirectoryChangedEvent(:final cwd):
        _values['workingDirectory'] = cwd;
        _asOfSeq = event.seq;
      case DshAgentPresetSelectedEvent(:final agentPreset):
        _values['agentPreset'] = agentPreset;
        _asOfSeq = event.seq;
      default:
        break;
    }
  }

  void _applyChunk(DshStreamChunk chunk) {
    final draft = _draft;
    if (draft == null) return;
    switch (chunk) {
      case DshBlockStartChunk():
        break;
      case DshTextDeltaChunk(:final text):
        _draft = draft.copyWith(text: draft.text + text);
      case DshReasoningDeltaChunk(:final text):
        _draft = draft.copyWith(reasoning: draft.reasoning + text);
      case DshToolCallDeltaChunk(
        :final index,
        :final id,
        :final name,
        :final argumentsDelta,
      ):
        final calls = List<DshLiveToolCall>.of(draft.toolCalls);
        var position = calls.indexWhere(
          (call) => (id.isNotEmpty && call.id == id) || call.index == index,
        );
        if (position < 0) {
          calls.add(DshLiveToolCall(index: index, id: id, name: name ?? ''));
          position = calls.length - 1;
        } else {
          final call = calls[position];
          calls[position] = call.copyWith(
            id: id.isEmpty ? call.id : id,
            name: name ?? call.name,
            arguments: call.arguments + argumentsDelta,
          );
        }
        _draft = draft.copyWith(toolCalls: calls);
      case DshBlockEndChunk(:final block):
        if (block is DshToolCallPart) {
          final calls = List<DshLiveToolCall>.of(draft.toolCalls);
          final position = calls.indexWhere(
            (call) => call.id.isNotEmpty && call.id == block.id,
          );
          if (position >= 0) {
            calls[position] = calls[position].copyWith(
              name: block.name,
              arguments: block.arguments,
            );
          } else {
            calls.add(
              DshLiveToolCall(
                index: calls.length,
                id: block.id,
                name: block.name,
                arguments: block.arguments,
              ),
            );
          }
          _draft = draft.copyWith(toolCalls: calls);
        }
      case DshUsageChunk(:final usage):
        _liveUsage = usage;
        _draft = draft.copyWith(usage: usage);
      case DshFinishChunk(:final reason):
        if (reason.failure != null) {
          _lastFailure = reason.failure;
          _draft = draft.copyWith(failure: reason.failure, active: false);
        }
      case DshUnknownChunk():
        break;
    }
  }

  void _appendRow(DshChatRow row) {
    _rows.add(row);
    if (row is DshToolRow && row.callId.isNotEmpty) {
      _toolRowIndex[row.callId] = _rows.length - 1;
    }
  }

  void _upsertTool(
    int seq,
    String callId, {
    required String name,
    required String arguments,
  }) {
    if (callId.isEmpty) return;
    final index = _toolRowIndex[callId];
    if (index != null) {
      final row = _rows[index] as DshToolRow;
      _rows[index] = row.copyWith(name: name, arguments: arguments);
      return;
    }
    _appendRow(
      DshToolRow(seq: seq, callId: callId, name: name, arguments: arguments),
    );
  }

  void _patchTool(
    String? callId, {
    required DshApprovalOutcome approvalOutcome,
  }) {
    if (callId == null) return;
    final index = _toolRowIndex[callId];
    if (index == null) return;
    final row = _rows[index] as DshToolRow;
    _rows[index] = row.copyWith(approvalOutcome: approvalOutcome);
  }

  /// Reconciles pending questions against the `userQuestions` projection after
  /// a control update or reconnect.
  void _recomputePendingFromProjections() {
    if (!_values.containsKey('userQuestions')) return;
    final questions = jsonMap(_values['userQuestions']);
    final active = jsonList(questions['active']);
    if (active.isEmpty) {
      // Settled elsewhere: drop question requests the Host no longer lists.
      _pendingQuestions.removeWhere(
        (request) =>
            request.wait?.callId != null &&
            !active.any(
              (item) =>
                  jsonString(jsonMap(item)['callId']) == request.wait!.callId,
            ),
      );
    }
  }
}
