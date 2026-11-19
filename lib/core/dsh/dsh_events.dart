/// Wire vocabulary for `/api/remote.mux` streams and the session log.
///
/// Every frame is parsed tolerantly: unknown event types become
/// [DshUnknownSessionEvent] (kept for ordering, not rendered), unknown content
/// blocks become [DshUnknownPart], and additive JSON fields are ignored. DSH
/// treats these vocabularies as merge-extensible; a strict parser would break
/// on the next plugin or Host minor version.
library;

// The event subclasses forward one parsed envelope to the private base
// constructor; super parameters are not usable with a named private
// super-constructor here (and the envelope is intentionally not public API).
// ignore_for_file: use_super_parameters

import 'dsh_errors.dart';
import 'dsh_models.dart';

/// Lifecycle of the physical mux connection.
enum DshConnectionState {
  idle,
  connecting,
  connected,
  reconnecting,

  /// The Host rejected this peer (401/403/409). Retrying with the same cookie
  /// cannot succeed; the UI must ask for a fresh WebUI URL.
  unauthorized,

  /// Caller closed it.
  closed,
}

// =============================================================================
// remote.mux frames
// =============================================================================

/// One decoded mux frame.
sealed class DshMuxFrame {
  const DshMuxFrame();

  /// Parses one decoded JSON text frame; malformed/unknown frames stay opaque.
  static DshMuxFrame parse(Object? json) {
    final map = jsonMap(json);
    final streamId = jsonString(map['streamId']) ?? '';
    switch (jsonString(map['type'])) {
      case 'item':
        return DshMuxItem(streamId, map['value']);
      case 'end':
        return DshMuxEnd(streamId);
      case 'error':
        return DshMuxError.fromJson(streamId, map['error']);
      default:
        return DshMuxUnknown(map);
    }
  }
}

final class DshMuxItem extends DshMuxFrame {
  const DshMuxItem(this.streamId, this.value);
  final String streamId;
  final Object? value;
}

final class DshMuxEnd extends DshMuxFrame {
  const DshMuxEnd(this.streamId);
  final String streamId;
}

final class DshMuxError extends DshMuxFrame {
  const DshMuxError(this.streamId, this.code, this.message, this.details);

  factory DshMuxError.fromJson(String streamId, Object? json) {
    final map = jsonMap(json);
    return DshMuxError(
      streamId,
      jsonString(map['code']) ?? 'gateway/internal',
      jsonString(map['message']) ?? 'The stream failed',
      jsonMap(map['details']),
    );
  }

  final String streamId;
  final String code;
  final String message;
  final Map<String, Object?> details;
}

final class DshMuxUnknown extends DshMuxFrame {
  const DshMuxUnknown(this.raw);
  final Map<String, Object?> raw;
}

// =============================================================================
// session/follow snapshot and durable events
// =============================================================================

class _EventEnvelope {
  _EventEnvelope(this.raw)
    : type = jsonString(raw['type']) ?? 'unknown',
      seq = jsonInt(raw['seq']) ?? 0,
      time =
          jsonEpochMs(raw['time']) ??
          DateTime.fromMillisecondsSinceEpoch(0, isUtc: true),
      data = jsonMap(raw['data']),
      surfaceOpRaw = raw['surfaceOp'],
      sourceEventSeqs = jsonList(
        raw['sourceEventSeqs'],
      ).whereType<num>().map((n) => n.toInt()).toList(growable: false),
      ignorable = raw['ignorable'] == true;

  final Map<String, Object?> raw;
  final String type;
  final int seq;
  final DateTime time;
  final Map<String, Object?> data;

  /// `'append'`, a replacement object, or null (older Hosts / non-surface
  /// events); replacement forms are model context, not transcript rows.
  final Object? surfaceOpRaw;
  final List<int> sourceEventSeqs;
  final bool ignorable;
}

/// One durable session-log event.
class DshSessionEvent {
  DshSessionEvent._(this._env);

  factory DshSessionEvent.fromJson(Object? json) {
    final env = _EventEnvelope(jsonMap(json));
    switch (env.type) {
      case 'turn/start':
        return DshTurnStarted._(env);
      case 'turn/end':
        return DshTurnEnded._(env);
      case 'step/start':
        return DshStepStarted._(env);
      case 'step/end':
        return DshStepEnded._(env);
      case 'user/message':
        return DshUserMessageEvent._(env);
      case 'assistant/message':
        return DshAssistantMessageEvent._(env);
      case 'assistant/attempt':
        return DshAssistantAttemptEvent._(env);
      case 'tool/call':
        return DshToolCallEvent._(env);
      case 'tool/result':
        return DshToolResultEvent._(env);
      case 'session/title':
        return DshTitleEvent._(env);
      case 'model/selection':
        return DshModelSelectionEvent._(env);
      case 'permission/preset':
        return DshPermissionPresetEvent._(env);
      case 'sandbox/mode':
        return DshSandboxModeEvent._(env);
      case 'approval/policy':
        return DshApprovalPolicyEvent._(env);
      case 'approval/asked':
        return DshApprovalAskedEvent._(env);
      case 'approval/decided':
        return DshApprovalDecidedEvent._(env);
      case 'command/run':
        return DshCommandRunEvent._(env);
      case 'command/done':
        return DshCommandDoneEvent._(env);
      case 'agent/inbox/spliced':
        return DshInboxSplicedEvent._(env);
      case 'llm/retry':
        return DshLlmRetryEvent._(env);
      case 'working-directory/change':
        return DshWorkingDirectoryChangedEvent._(env);
      case 'agent-preset/selected':
        return DshAgentPresetSelectedEvent._(env);
      default:
        return DshUnknownSessionEvent._(env);
    }
  }

  final _EventEnvelope _env;

  String get type => _env.type;
  int get seq => _env.seq;
  DateTime get time => _env.time;

  /// `'append'` when the event entered the model-visible surface at its own
  /// position; a replacement object means it shadowed earlier nodes (model-only).
  String? get surfaceOp =>
      _env.surfaceOpRaw is String ? _env.surfaceOpRaw as String : null;

  bool get isAppendOrigin => surfaceOp == null || surfaceOp == 'append';

  List<int> get sourceEventSeqs => _env.sourceEventSeqs;
  bool get ignorable => _env.ignorable;
  Map<String, Object?> get data => _env.data;
  Map<String, Object?> get raw => _env.raw;

  @override
  String toString() => 'DshSessionEvent($type @$seq)';
}

final class DshTurnStarted extends DshSessionEvent {
  DshTurnStarted._(_EventEnvelope env) : super._(env);
  int get turn => jsonInt(data['turn']) ?? 0;
}

/// Why a turn ended: `completed`, `aborted`, `blocked`, `error`, `max-tokens`,
/// `interrupted`, `forked`.
class DshTurnEndReason {
  const DshTurnEndReason({
    required this.kind,
    this.failure,
    this.raw = const {},
  });

  factory DshTurnEndReason.fromJson(Object? json) {
    final map = jsonMap(json);
    return DshTurnEndReason(
      kind: jsonString(map['kind']) ?? 'unknown',
      failure: map['error'] == null
          ? null
          : DshLlmFailure.fromJson(map['error']),
      raw: map,
    );
  }

  final String kind;
  final DshLlmFailure? failure;
  final Map<String, Object?> raw;

  bool get isError => kind == 'error';
  bool get isAborted => kind == 'aborted';
  bool get isCompleted => kind == 'completed';
}

final class DshTurnEnded extends DshSessionEvent {
  DshTurnEnded._(_EventEnvelope env) : super._(env);

  int get turn => jsonInt(data['turn']) ?? 0;

  DshTurnEndReason get reason => DshTurnEndReason.fromJson(data['reason']);
}

final class DshStepStarted extends DshSessionEvent {
  DshStepStarted._(_EventEnvelope env) : super._(env);
  int get turn => jsonInt(data['turn']) ?? 0;
  int get step => jsonInt(data['step']) ?? 0;
}

final class DshStepEnded extends DshSessionEvent {
  DshStepEnded._(_EventEnvelope env) : super._(env);
  int get turn => jsonInt(data['turn']) ?? 0;
  int get step => jsonInt(data['step']) ?? 0;
}

final class DshUserMessageEvent extends DshSessionEvent {
  DshUserMessageEvent._(_EventEnvelope env) : super._(env);

  DshMessage get message => DshMessage.fromJson(data);

  bool get isHumanPrompt => isAppendOrigin && message.source.kind == 'user';
}

final class DshAssistantMessageEvent extends DshSessionEvent {
  DshAssistantMessageEvent._(_EventEnvelope env) : super._(env);

  int get turn => jsonInt(data['turn']) ?? 0;
  int get step => jsonInt(data['step']) ?? 0;
  DshMessage get message => DshMessage.fromJson(data['message']);
  DshTokenUsage? get usage =>
      data['usage'] == null ? null : DshTokenUsage.fromJson(data['usage']);
  bool get interrupted => data['interrupted'] == true;

  /// Raw compacted stream records (presentation reconstruction; not rendered).
  List<Object?> get stream => jsonList(data['stream']);
}

final class DshAssistantAttemptEvent extends DshSessionEvent {
  DshAssistantAttemptEvent._(_EventEnvelope env) : super._(env);

  int get turn => jsonInt(data['turn']) ?? 0;
  int get step => jsonInt(data['step']) ?? 0;
  String? get attemptId => jsonString(data['attemptId']);
  List<Object?> get stream => jsonList(data['stream']);
}

final class DshToolCallEvent extends DshSessionEvent {
  DshToolCallEvent._(_EventEnvelope env) : super._(env);

  int get turn => jsonInt(data['turn']) ?? 0;
  int get step => jsonInt(data['step']) ?? 0;
  String get callId => jsonString(data['callId']) ?? '';
  String get name => jsonString(data['name']) ?? 'tool';

  /// Raw JSON text as produced by the model (may need lenient decoding).
  String get arguments => jsonString(data['arguments']) ?? '';
}

final class DshToolResultEvent extends DshSessionEvent {
  DshToolResultEvent._(_EventEnvelope env) : super._(env);

  int get turn => jsonInt(data['turn']) ?? 0;
  int get step => jsonInt(data['step']) ?? 0;
  DshMessage get message => DshMessage.fromJson(data['message']);
  String get callId =>
      message.raw['toolCallId'] as String? ?? jsonString(data['callId']) ?? '';
  DshLlmFailure? get failure =>
      data['error'] == null ? null : DshLlmFailure.fromJson(data['error']);
  bool get isError => message.raw['isError'] == true || failure != null;

  /// Tool-owned presentation data (diff, patch, path, …).
  Object? get meta => data['meta'];
}

final class DshTitleEvent extends DshSessionEvent {
  DshTitleEvent._(_EventEnvelope env) : super._(env);
  String get title => jsonString(data['title']) ?? '';
}

final class DshModelSelectionEvent extends DshSessionEvent {
  DshModelSelectionEvent._(_EventEnvelope env) : super._(env);
  DshModelSelection get selection => DshModelSelection.fromJson(data);
}

final class DshPermissionPresetEvent extends DshSessionEvent {
  DshPermissionPresetEvent._(_EventEnvelope env) : super._(env);
  String get preset => jsonString(data['preset']) ?? '';
}

final class DshSandboxModeEvent extends DshSessionEvent {
  DshSandboxModeEvent._(_EventEnvelope env) : super._(env);
  String get mode => jsonString(data['mode']) ?? '';
}

final class DshApprovalPolicyEvent extends DshSessionEvent {
  DshApprovalPolicyEvent._(_EventEnvelope env) : super._(env);
  String get policy => jsonString(data['policy']) ?? '';
}

final class DshApprovalAskedEvent extends DshSessionEvent {
  DshApprovalAskedEvent._(_EventEnvelope env) : super._(env);
  String get id => jsonString(data['id']) ?? '';
  String get toolName => jsonString(data['toolName']) ?? 'tool';
  String? get callId => jsonString(data['callId']);
  String? get reason => jsonString(data['reason']);
}

final class DshApprovalDecidedEvent extends DshSessionEvent {
  DshApprovalDecidedEvent._(_EventEnvelope env) : super._(env);
  String get id => jsonString(data['id']) ?? '';
  DshApprovalOutcome get outcome => DshApprovalOutcome.parse(data['outcome']);
}

final class DshCommandRunEvent extends DshSessionEvent {
  DshCommandRunEvent._(_EventEnvelope env) : super._(env);
  String get commandId => jsonString(data['commandId']) ?? '';
  String get name => jsonString(data['name']) ?? '';
  String? get line => jsonString(data['line']);
}

final class DshCommandDoneEvent extends DshSessionEvent {
  DshCommandDoneEvent._(_EventEnvelope env) : super._(env);
  String get commandId => jsonString(data['commandId']) ?? '';
  DshCommandResult get result => DshCommandResult.fromJson(data['result']);
}

final class DshInboxSplicedEvent extends DshSessionEvent {
  DshInboxSplicedEvent._(_EventEnvelope env) : super._(env);
  String get target => jsonString(data['target']) ?? 'next-turn';
  int get start => jsonInt(data['start']) ?? 0;
  int get removedCount => jsonInt(data['removedCount']) ?? 0;
  List<DshMessage> get inserted => jsonList(
    data['inserted'],
  ).map(DshMessage.fromJson).toList(growable: false);
}

final class DshLlmRetryEvent extends DshSessionEvent {
  DshLlmRetryEvent._(_EventEnvelope env) : super._(env);
  int get turn => jsonInt(data['turn']) ?? 0;
  int get step => jsonInt(data['step']) ?? 0;
  int get retry => jsonInt(data['retry']) ?? 0;
  int get maxRetries => jsonInt(data['maxRetries']) ?? 0;
  int? get delayMs => jsonInt(data['delayMs']);
  DshLlmFailure? get failure =>
      data['failure'] == null ? null : DshLlmFailure.fromJson(data['failure']);
}

final class DshWorkingDirectoryChangedEvent extends DshSessionEvent {
  DshWorkingDirectoryChangedEvent._(_EventEnvelope env) : super._(env);
  String get cwd => jsonString(data['cwd']) ?? '';
}

final class DshAgentPresetSelectedEvent extends DshSessionEvent {
  DshAgentPresetSelectedEvent._(_EventEnvelope env) : super._(env);
  String get agentPreset => jsonString(data['agentPreset']) ?? '';
}

/// A plugin/future event this client does not render; kept for `seq` ordering.
final class DshUnknownSessionEvent extends DshSessionEvent {
  DshUnknownSessionEvent._(_EventEnvelope env) : super._(env);
}

// =============================================================================
// session/follow snapshot and live assistant stream
// =============================================================================

class DshSessionSnapshot {
  const DshSessionSnapshot({
    required this.header,
    required this.cursor,
    required this.records,
    required this.hasMore,
    required this.projections,
    required this.assistantStream,
  });

  factory DshSessionSnapshot.fromJson(Object? json) {
    final map = jsonMap(json);
    return DshSessionSnapshot(
      header: DshSessionHeader.fromJson(map['header']),
      cursor: jsonInt(map['cursor']) ?? 0,
      records: jsonList(map['records'])
          .map((record) => DshSessionEvent.fromJson(jsonMap(record)['event']))
          .toList(growable: false),
      hasMore: map['hasMore'] == true,
      projections: map['projections'] == null
          ? DshSessionProjections.empty
          : DshSessionProjections.fromJson(map['projections']),
      assistantStream: DshAssistantStreamBaseline.fromJson(
        map['assistantStream'],
      ),
    );
  }

  final DshSessionHeader header;
  final int cursor;
  final List<DshSessionEvent> records;

  /// True when the snapshot window starts mid-log (older history exists).
  final bool hasMore;
  final DshSessionProjections projections;
  final DshAssistantStreamBaseline assistantStream;
}

/// Reconnect baseline for the process-local live assistant stream.
class DshAssistantStreamBaseline {
  const DshAssistantStreamBaseline({this.revision = 0, this.activeAttempt});

  factory DshAssistantStreamBaseline.fromJson(Object? json) {
    final map = jsonMap(json);
    return DshAssistantStreamBaseline(
      revision: jsonInt(map['revision']) ?? 0,
      activeAttempt: map['activeAttempt'] == null
          ? null
          : DshAssistantStreamAttempt.fromJson(map['activeAttempt']),
    );
  }

  final int revision;
  final DshAssistantStreamAttempt? activeAttempt;
}

/// An attempt already mid-flight when a follow generation opened.
class DshAssistantStreamAttempt {
  const DshAssistantStreamAttempt({
    required this.attemptId,
    required this.startedAfterSeq,
    required this.turn,
    required this.step,
    required this.nextIndex,
    required this.stream,
  });

  factory DshAssistantStreamAttempt.fromJson(Object? json) {
    final map = jsonMap(json);
    return DshAssistantStreamAttempt(
      attemptId: jsonString(map['attemptId']) ?? '',
      startedAfterSeq: jsonInt(map['startedAfterSeq']) ?? 0,
      turn: jsonInt(map['turn']) ?? 0,
      step: jsonInt(map['step']) ?? 0,
      nextIndex: jsonInt(map['nextIndex']) ?? 0,
      stream: jsonList(
        map['stream'],
      ).map(DshStreamChunk.fromJson).toList(growable: false),
    );
  }

  final String attemptId;
  final int startedAfterSeq;
  final int turn;
  final int step;
  final int nextIndex;
  final List<DshStreamChunk> stream;
}

/// One live assistant frame (`session/follow` item type `assistant-stream`).
sealed class DshAssistantStreamFrame {
  const DshAssistantStreamFrame({
    required this.attemptId,
    required this.revision,
  });

  factory DshAssistantStreamFrame.fromJson(Object? json) {
    final map = jsonMap(json);
    final attemptId = jsonString(map['attemptId']) ?? '';
    final revision = jsonInt(map['revision']) ?? 0;
    switch (jsonString(map['type'])) {
      case 'start':
        return DshAssistantStreamStart(
          attemptId: attemptId,
          revision: revision,
          turn: jsonInt(map['turn']) ?? 0,
          step: jsonInt(map['step']) ?? 0,
          startedAfterSeq: jsonInt(map['startedAfterSeq']) ?? 0,
        );
      case 'chunk':
        return DshAssistantStreamChunkFrame(
          attemptId: attemptId,
          revision: revision,
          index: jsonInt(map['index']) ?? 0,
          time: jsonEpochMs(map['time']),
          chunk: DshStreamChunk.fromJson(map['chunk']),
        );
      case 'end':
        return DshAssistantStreamEnd(
          attemptId: attemptId,
          revision: revision,
          index: jsonInt(map['index']) ?? 0,
          outcome: DshAssistantStreamOutcome.fromJson(map['outcome']),
        );
      default:
        return DshAssistantStreamUnknown(
          attemptId: attemptId,
          revision: revision,
          raw: map,
        );
    }
  }

  final String attemptId;

  /// Generation counter for the live view: a higher revision voids old frames.
  final int revision;
}

final class DshAssistantStreamStart extends DshAssistantStreamFrame {
  const DshAssistantStreamStart({
    required super.attemptId,
    required super.revision,
    required this.turn,
    required this.step,
    required this.startedAfterSeq,
  });

  final int turn;
  final int step;

  /// Last durable seq observed when the attempt started.
  final int startedAfterSeq;
}

final class DshAssistantStreamChunkFrame extends DshAssistantStreamFrame {
  const DshAssistantStreamChunkFrame({
    required super.attemptId,
    required super.revision,
    required this.index,
    required this.chunk,
    this.time,
  });

  final int index;
  final DateTime? time;
  final DshStreamChunk chunk;
}

final class DshAssistantStreamEnd extends DshAssistantStreamFrame {
  const DshAssistantStreamEnd({
    required super.attemptId,
    required super.revision,
    required this.index,
    required this.outcome,
  });

  final int index;
  final DshAssistantStreamOutcome outcome;
}

final class DshAssistantStreamUnknown extends DshAssistantStreamFrame {
  const DshAssistantStreamUnknown({
    required super.attemptId,
    required super.revision,
    required this.raw,
  });

  final Map<String, Object?> raw;
}

/// Terminal marker of one live attempt.
sealed class DshAssistantStreamOutcome {
  const DshAssistantStreamOutcome();

  factory DshAssistantStreamOutcome.fromJson(Object? json) {
    final map = jsonMap(json);
    return switch (jsonString(map['kind'])) {
      'committed' => DshAssistantStreamCommitted(
        eventType: jsonString(map['eventType']) ?? 'assistant/message',
        seq: jsonInt(map['seq']) ?? 0,
      ),
      'abandoned' => const DshAssistantStreamAbandoned(),
      _ => DshAssistantStreamAbandoned(),
    };
  }
}

final class DshAssistantStreamCommitted extends DshAssistantStreamOutcome {
  const DshAssistantStreamCommitted({
    required this.eventType,
    required this.seq,
  });

  /// `assistant/message` (or `assistant/attempt`) at [seq] is authoritative.
  final String eventType;
  final int seq;
}

final class DshAssistantStreamAbandoned extends DshAssistantStreamOutcome {
  const DshAssistantStreamAbandoned();
}

/// One dense live stream chunk.
sealed class DshStreamChunk {
  const DshStreamChunk();

  factory DshStreamChunk.fromJson(Object? json) {
    final map = jsonMap(json);
    switch (jsonString(map['type'])) {
      case 'block-start':
        return DshBlockStartChunk(
          index: jsonInt(map['index']) ?? 0,
          blockType: jsonString(map['blockType']) ?? 'unknown',
        );
      case 'text-delta':
        return DshTextDeltaChunk(
          index: jsonInt(map['index']) ?? 0,
          text: jsonString(map['text']) ?? '',
        );
      case 'reasoning-delta':
        return DshReasoningDeltaChunk(
          index: jsonInt(map['index']) ?? 0,
          text: jsonString(map['text']) ?? '',
        );
      case 'tool-call-delta':
        return DshToolCallDeltaChunk(
          index: jsonInt(map['index']) ?? 0,
          id: jsonString(map['id']) ?? '',
          name: jsonString(map['name']),
          argumentsDelta: jsonString(map['argumentsDelta']) ?? '',
        );
      case 'block-end':
        return DshBlockEndChunk(
          index: jsonInt(map['index']) ?? 0,
          block: DshPart.fromJson(map['block']),
        );
      case 'usage':
        return DshUsageChunk(DshTokenUsage.fromJson(map['usage']));
      case 'finish':
        return DshFinishChunk(reason: DshFinishReason.fromJson(map['reason']));
      default:
        return DshUnknownChunk(jsonString(map['type']) ?? 'unknown', map);
    }
  }
}

final class DshBlockStartChunk extends DshStreamChunk {
  const DshBlockStartChunk({required this.index, required this.blockType});
  final int index;

  /// `text`, `reasoning`, `tool-call`, `image`, `file`.
  final String blockType;
}

final class DshTextDeltaChunk extends DshStreamChunk {
  const DshTextDeltaChunk({required this.index, required this.text});
  final int index;
  final String text;
}

final class DshReasoningDeltaChunk extends DshStreamChunk {
  const DshReasoningDeltaChunk({required this.index, required this.text});
  final int index;
  final String text;
}

final class DshToolCallDeltaChunk extends DshStreamChunk {
  const DshToolCallDeltaChunk({
    required this.index,
    required this.id,
    this.name,
    required this.argumentsDelta,
  });
  final int index;
  final String id;
  final String? name;

  /// Append to the argument JSON buffer.
  final String argumentsDelta;
}

final class DshBlockEndChunk extends DshStreamChunk {
  const DshBlockEndChunk({required this.index, required this.block});
  final int index;
  final DshPart block;
}

final class DshUsageChunk extends DshStreamChunk {
  const DshUsageChunk(this.usage);
  final DshTokenUsage usage;
}

class DshFinishReason {
  const DshFinishReason({required this.kind, this.failure});

  factory DshFinishReason.fromJson(Object? json) {
    final map = jsonMap(json);
    return DshFinishReason(
      kind: jsonString(map['kind']) ?? 'unknown',
      failure: map['error'] == null
          ? null
          : DshLlmFailure.fromJson(map['error']),
    );
  }

  final String kind;
  final DshLlmFailure? failure;
}

final class DshFinishChunk extends DshStreamChunk {
  const DshFinishChunk({required this.reason});
  final DshFinishReason reason;
}

final class DshUnknownChunk extends DshStreamChunk {
  const DshUnknownChunk(this.type, this.raw);
  final String type;
  final Map<String, Object?> raw;
}

// =============================================================================
// $events host events
// =============================================================================

/// One item delivered by the Gateway-internal `$events` stream.
sealed class DshHostEvent {
  const DshHostEvent({required this.event, this.raw = const {}});

  factory DshHostEvent.fromJson(Object? json) {
    final map = jsonMap(json);
    switch (jsonString(map['type'])) {
      case 'ready':
        return DshHostReady(
          clientId: jsonString(map['clientId']) ?? '',
          home: jsonString(jsonMap(map['host'])['home']) ?? '',
          raw: map,
        );
      case 'emit':
        return DshHostEmit(
          event: jsonString(map['event']) ?? '',
          args: jsonList(map['args']),
          raw: map,
        );
      case 'waterfall':
        final eventId = jsonString(map['eventId']) ?? '';
        final sessionId = jsonString(map['agentId']) ?? '';
        final name = jsonString(map['event']) ?? '';
        final request = jsonMap(map['request']);
        return switch (name) {
          'approval/request' => DshApprovalRequest.fromJson(
            eventId: eventId,
            sessionId: sessionId,
            request: request,
            raw: map,
          ),
          'user-questions/request' => DshUserQuestionRequest.fromJson(
            eventId: eventId,
            sessionId: sessionId,
            request: request,
            raw: map,
          ),
          _ => DshUnknownHostRequest(
            event: name,
            eventId: eventId,
            sessionId: sessionId,
            request: request,
            raw: map,
          ),
        };
      case 'cancel':
        return DshHostRequestCancelled(
          eventId: jsonString(map['eventId']) ?? '',
          raw: map,
        );
      default:
        return DshHostUnknown(map);
    }
  }

  final String event;
  final Map<String, Object?> raw;
}

final class DshHostReady extends DshHostEvent {
  const DshHostReady({required this.clientId, required this.home, super.raw})
    : super(event: r'$events/ready');

  final String clientId;
  final String home;
}

/// Fire-and-forget Host notification. The event names a Client caches on are
/// listed in `protocol.md` §4.7; unknown names must be ignored, never fatal.
final class DshHostEmit extends DshHostEvent {
  const DshHostEmit({required super.event, required this.args, super.raw});

  final List<Object?> args;

  /// First positional string arg (usually the session id).
  String? get arg0 => args.isEmpty
      ? null
      : args.first is String
      ? args.first as String
      : null;

  String? get namespace => event.contains('/') ? event.split('/').first : null;
  String? get name =>
      event.contains('/') ? event.split('/').skip(1).join('/') : event;

  /// `api-session/added` carries the full summary as its only argument.
  DshSessionSummary? get sessionSummary =>
      event == 'api-session/added' && args.isNotEmpty
      ? DshSessionSummary.fromJson(args.first)
      : null;

  /// `api-session/status` carries `[sessionId, running]`.
  bool? get running => event == 'api-session/status' && args.length >= 2
      ? args[1] == true
      : null;

  /// `settings/document-updated` carries `[ns, revision]`.
  int? get revision => event == 'settings/document-updated' && args.length >= 2
      ? jsonInt(args[1])
      : null;
}

/// Pending Host request answered through `$events/result`.
sealed class DshHostRequest extends DshHostEvent {
  const DshHostRequest({
    required super.event,
    required this.eventId,
    required this.sessionId,
    super.raw,
  });

  /// Stable across reconnect generations; key UI state and dedupe by it.
  final String eventId;

  /// Agent/session identity the request belongs to.
  final String sessionId;
}

enum DshApprovalDecision {
  /// One-shot grant (`allowed-once`); there is no "always allow" in 0.2.2.
  allowOnce('allowed-once'),
  reject('rejected'),

  /// Delegate to another client / the Host's next answerer (fails closed).
  pass('next');

  const DshApprovalDecision(this.wire);
  final String wire;
}

class DshApprovalRequest extends DshHostRequest {
  const DshApprovalRequest({
    required super.eventId,
    required super.sessionId,
    required this.toolName,
    super.raw,
    this.callId,
    this.reason,
    this.displayReason = const {},
  }) : super(event: 'approval/request');

  factory DshApprovalRequest.fromJson({
    required String eventId,
    required String sessionId,
    required Map<String, Object?> request,
    Map<String, Object?> raw = const {},
  }) {
    final display = <String, String>{};
    jsonMap(request['displayReason']).forEach((key, value) {
      if (value is String) display[key] = value;
    });
    return DshApprovalRequest(
      eventId: eventId,
      sessionId: sessionId,
      toolName: jsonString(request['toolName']) ?? 'tool',
      callId: jsonString(request['callId']),
      reason: jsonString(request['reason']),
      displayReason: display,
      raw: raw,
    );
  }

  final String toolName;

  /// The exact `tool/call` being decided, when the asker supplied one.
  final String? callId;
  final String? reason;

  /// Localized presentation text keyed by locale (`en` always present).
  final Map<String, String> displayReason;

  String describe([String locale = 'en']) =>
      displayReason[locale] ??
      displayReason['en'] ??
      reason ??
      'Allow $toolName?';
}

class DshQuestionOption {
  const DshQuestionOption({required this.label, this.description});

  factory DshQuestionOption.fromJson(Object? json) {
    final map = jsonMap(json);
    return DshQuestionOption(
      label: jsonString(map['label']) ?? '',
      description: jsonString(map['description']),
    );
  }

  final String label;
  final String? description;
}

class DshUserQuestion {
  const DshUserQuestion({
    required this.id,
    required this.question,
    this.detail,
    this.header,
    this.options = const [],
    this.multiSelect = false,
    this.intent,
  });

  factory DshUserQuestion.fromJson(Object? json) {
    final map = jsonMap(json);
    return DshUserQuestion(
      id: jsonString(map['id']) ?? '',
      question: jsonString(map['question']) ?? '',
      detail: jsonString(map['detail']),
      header: jsonString(map['header']),
      options: jsonList(
        map['options'],
      ).map(DshQuestionOption.fromJson).toList(growable: false),
      multiSelect: map['multiSelect'] == true,
      intent: map['intent'] == null ? null : jsonMap(map['intent']),
    );
  }

  final String id;
  final String question;

  /// Markdown detail (the plan text for `intent.kind == 'plan-review'`).
  final String? detail;
  final String? header;
  final List<DshQuestionOption> options;
  final bool multiSelect;

  /// Presentation intent (`plan-review`, `approval`, …); encoding is identical.
  final Map<String, Object?>? intent;
}

/// Timed-wait metadata on a question request.
class DshQuestionWait {
  const DshQuestionWait({this.callId, this.timed = false});

  factory DshQuestionWait.fromJson(Object? json) {
    final map = jsonMap(json);
    return DshQuestionWait(
      callId: jsonString(map['callId']),
      timed: map['timed'] == true,
    );
  }

  final String? callId;
  final bool timed;
}

class DshUserQuestionRequest extends DshHostRequest {
  const DshUserQuestionRequest({
    required super.eventId,
    required super.sessionId,
    required this.questions,
    super.raw,
    this.wait,
  }) : super(event: 'user-questions/request');

  factory DshUserQuestionRequest.fromJson({
    required String eventId,
    required String sessionId,
    required Map<String, Object?> request,
    Map<String, Object?> raw = const {},
  }) {
    return DshUserQuestionRequest(
      eventId: eventId,
      sessionId: sessionId,
      questions: jsonList(
        request['questions'],
      ).map(DshUserQuestion.fromJson).toList(growable: false),
      wait: request['wait'] == null
          ? null
          : DshQuestionWait.fromJson(request['wait']),
      raw: raw,
    );
  }

  final List<DshUserQuestion> questions;
  final DshQuestionWait? wait;
}

/// Answer to one question: selected option **labels**, plus optional free text.
class DshQuestionAnswer {
  const DshQuestionAnswer({
    required this.id,
    this.selected = const [],
    this.custom,
  });

  final String id;
  final List<String> selected;
  final String? custom;

  Map<String, Object?> toJson() => {
    'id': id,
    'selected': selected,
    if (custom != null && custom!.isNotEmpty) 'custom': custom,
  };
}

/// A waterfall this client does not handle (plugin-defined).
class DshUnknownHostRequest extends DshHostRequest {
  const DshUnknownHostRequest({
    required super.event,
    required super.eventId,
    required super.sessionId,
    required this.request,
    super.raw,
  });

  final Map<String, Object?> request;
}

final class DshHostRequestCancelled extends DshHostEvent {
  const DshHostRequestCancelled({required this.eventId, super.raw})
    : super(event: r'$events/cancel');

  final String eventId;
}

final class DshHostUnknown extends DshHostEvent {
  const DshHostUnknown(Map<String, Object?> raw)
    : super(event: 'unknown', raw: raw);
}

// =============================================================================
// workspace/follow updates
// =============================================================================

sealed class DshWorkspaceUpdate {
  const DshWorkspaceUpdate();

  /// Parses one `workspace/follow` item; unknown frames are ignored.
  static DshWorkspaceUpdate? tryParse(Object? json) {
    final map = jsonMap(json);
    switch (jsonString(map['type'])) {
      case 'baseline':
        return DshWorkspaceBaselineUpdate(
          DshWorkspaceBaseline.fromJson(map['value']),
        );
      case 'replace':
        return DshWorkspaceReplaceUpdate(
          DshWorkspaceBaseline.fromJson(map['value']),
        );
      case 'upsert':
        return DshWorkspaceUpsertUpdate(
          DshWorkspace.fromJson(map['workspace']),
        );
      case 'remove':
        return DshWorkspaceRemoveUpdate(jsonString(map['workspaceId']) ?? '');
      case 'order':
        return DshWorkspaceOrderUpdate(jsonStringList(map['workspaceIds']));
      case 'archived':
        return DshWorkspaceArchivedUpdate(
          jsonStringList(map['archivedSessionIds']),
        );
      case 'pinned':
        return DshWorkspacePinnedUpdate(
          jsonStringList(map['pinnedSessionIds']),
        );
      default:
        return null;
    }
  }
}

final class DshWorkspaceBaselineUpdate extends DshWorkspaceUpdate {
  const DshWorkspaceBaselineUpdate(this.baseline);
  final DshWorkspaceBaseline baseline;
}

/// Complete state replacement inside one generation (not a new generation).
final class DshWorkspaceReplaceUpdate extends DshWorkspaceUpdate {
  const DshWorkspaceReplaceUpdate(this.baseline);
  final DshWorkspaceBaseline baseline;
}

final class DshWorkspaceUpsertUpdate extends DshWorkspaceUpdate {
  const DshWorkspaceUpsertUpdate(this.workspace);
  final DshWorkspace workspace;
}

final class DshWorkspaceRemoveUpdate extends DshWorkspaceUpdate {
  const DshWorkspaceRemoveUpdate(this.workspaceId);
  final String workspaceId;
}

final class DshWorkspaceOrderUpdate extends DshWorkspaceUpdate {
  const DshWorkspaceOrderUpdate(this.workspaceIds);
  final List<String> workspaceIds;
}

final class DshWorkspaceArchivedUpdate extends DshWorkspaceUpdate {
  const DshWorkspaceArchivedUpdate(this.archivedSessionIds);
  final List<String> archivedSessionIds;
}

final class DshWorkspacePinnedUpdate extends DshWorkspaceUpdate {
  const DshWorkspacePinnedUpdate(this.pinnedSessionIds);
  final List<String> pinnedSessionIds;
}

// =============================================================================
// Session watch updates
// =============================================================================

/// Everything `DshSession.watch()` emits.
sealed class DshSessionUpdate {
  const DshSessionUpdate();
}

final class DshSessionSnapshotUpdate extends DshSessionUpdate {
  const DshSessionSnapshotUpdate(this.snapshot);
  final DshSessionSnapshot snapshot;
}

final class DshSessionEventUpdate extends DshSessionUpdate {
  const DshSessionEventUpdate(this.event);
  final DshSessionEvent event;
}

final class DshSessionAssistantFrameUpdate extends DshSessionUpdate {
  const DshSessionAssistantFrameUpdate(this.frame);
  final DshAssistantStreamFrame frame;
}

final class DshSessionHostRequestUpdate extends DshSessionUpdate {
  const DshSessionHostRequestUpdate(this.event);
  final DshHostEvent event;
}

final class DshSessionConnectionUpdate extends DshSessionUpdate {
  const DshSessionConnectionUpdate(this.state, this.error);
  final DshConnectionState state;
  final DshException? error;
}
