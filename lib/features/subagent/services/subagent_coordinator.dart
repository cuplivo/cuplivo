/// Owns the life of one delegation.
///
/// One place decides the things that must agree:
///
/// * whether this tool call already delegated (the key is the parent
///   conversation plus the tool call id, so a re-render or a remount never pays
///   for the same work twice);
/// * what the child conversation inherits — the parent's workspace binding and
///   nothing else (see `subagent_rules.dart` for why);
/// * when the child is done: the child's own `GenerationRun` reaching a terminal
///   state, not a second state machine invented here;
/// * what the parent conversation gains: one `user` message carrying a
///   [SubagentResultPart] and the brief as its text, written under a
///   deterministic id so a second delivery collides instead of duplicating;
/// * whether the parent then continues on its own.
///
/// Liveness is in memory only. A killed process leaves the child's run behind as
/// `interrupted` (the startup sweep terminalises it) and leaves no result
/// message — the renderer reads that combination instead of a stored flag.
library;

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart' show BuildContext;
import 'package:provider/provider.dart';

import '../../../core/database/generation_run.dart';
import '../../../core/models/assistant.dart';
import '../../../core/models/chat_message.dart';
import '../../../core/models/message_part.dart';
import '../../../core/models/tool_permission_mode.dart';
import '../../../core/models/workspace_binding.dart';
import '../../../core/services/chat/chat_service.dart';
import 'subagent_rules.dart';
import 'subagent_target.dart';

/// How the host starts one turn inside the child conversation.
///
/// [assistant] is who runs the turn — the target, not the delegator — and
/// [delegator] is who handed the task over. Both are passed because the model
/// a child runs on is resolved from the pair, and today that rule reads only
/// the delegator's override.
typedef SubagentTurnStarter =
    Future<SubagentTurnStart> Function({
      required String conversationId,
      required Assistant assistant,
      required String task,
      Assistant? delegator,
      SubagentTarget? target,
    });

/// What a turn starter produced.
final class SubagentTurnStart {
  const SubagentTurnStart.started({required this.runId}) : refusal = null;

  const SubagentTurnStart.refused(this.refusal) : runId = null;

  final String? runId;

  /// Machine-readable reason the turn could not start; null when it did.
  final String? refusal;
}

/// Why a child conversation is parked. Both mean "only a person can unblock it",
/// but they send the user to different cards, so the wording differs.
enum SubagentWaitReason {
  /// An `ask_user` question is showing in the child conversation.
  answer,

  /// A tool call is waiting for an approval in the child conversation.
  approval,
}

/// Where one delegation stands. Terminal phases are exactly the terminal
/// `GenerationRun` states plus `cancelled`, so the mapping never invents one.
enum SubagentPhase {
  running,

  /// Parked on something only a person can answer: a tool approval request or
  /// an `ask_user` card in the child conversation. Not a failure and never
  /// timed out — the child's run is still open, it is just waiting.
  waitingForInput,
  completed,
  failed,

  /// The delegator's model asked it to stop (`interrupt`). Unlike [cancelled],
  /// which is the user's own Stop, this one is a pause: the conversation keeps
  /// its history and a later `send_message` starts it again.
  stopped,
  cancelled,
  interrupted,
}

/// One delegation, as the parent conversation sees it.
final class SubagentEntry {
  SubagentEntry({
    required this.key,
    required this.parentConversationId,
    required this.childConversationId,
    required this.title,
    required this.startedAt,
    required this.assistant,
    this.target = const GeneralSubagentTarget(),
    this.targetName,
  });

  final String? key;
  final String parentConversationId;
  final String childConversationId;

  /// The model's short name for the job, already bounded by `childTitle`.
  final String title;
  /// When the current segment started. A continued delegation resets it, so the
  /// panel measures this turn rather than the whole lifetime.
  DateTime startedAt;

  /// Who delegated: the assistant that is woken with the result. It is not the
  /// assistant running the child when the task was named to somebody else.
  final Assistant assistant;

  /// Who runs the task. `general` means a copy of [assistant].
  final SubagentTarget target;

  /// What [target] is called, resolved once when the delegation starts so the
  /// panel never has to look an assistant up mid-build.
  final String? targetName;

  SubagentPhase phase = SubagentPhase.running;
  SubagentWaitReason? waitReason;
  String? runId;
  String? failureReason;
  Duration? elapsed;

  /// The brief the parent conversation was given, kept so `await_job` can hand
  /// back the conclusion without re-reading the message.
  String? brief;

  /// How many turns are blocked in [SubagentCoordinator.awaitJob] right now. A
  /// non-zero count means somebody is already waiting to report this outcome, so
  /// the terminal write must not wake the parent a second time.
  int waiters = 0;

  /// Whether the delegator's model asked for the stop ([SubagentCoordinator
  /// .interruptChild]) rather than the user pressing Stop. A run row cannot tell
  /// the two apart — both end `cancelled` — so the request is remembered here.
  bool stoppedByModel = false;

  /// The run whose outcome was already reported. A continued delegation waits
  /// for a run other than this one before it starts watching again.
  String? settledRunId;

  /// Identifies the watcher that may report this entry. Starting a new one (a
  /// continuation arriving just as the previous watcher settles) bumps this, so
  /// the old loop exits instead of two watchers reporting one turn.
  int watchGeneration = 0;

  bool get isLive =>
      phase == SubagentPhase.running || phase == SubagentPhase.waitingForInput;

  /// True while the child is parked on a question or an approval. The strip says
  /// so instead of claiming it is still working.
  bool get needsInput => phase == SubagentPhase.waitingForInput;
}

/// What [SubagentCoordinator.begin] produced.
sealed class SubagentStart {
  const SubagentStart();

  /// Exactly what the tool answers with.
  Map<String, dynamic> toToolResult();
}

final class SubagentStarted extends SubagentStart {
  const SubagentStarted(this.entry);

  final SubagentEntry entry;

  @override
  Map<String, dynamic> toToolResult() => <String, dynamic>{
    'status': 'started',
    'conversation_id': entry.childConversationId,
    'job_id': entry.childConversationId,
    // Echoed so a model that named several targets in one turn can tell which
    // receipt belongs to which job, and so the card can render without
    // re-reading the call's arguments.
    'target': entry.target.encode(),
  };
}

final class SubagentRefused extends SubagentStart {
  const SubagentRefused(this.code, this.message);

  /// Machine-readable reason, so the model can tell the user what to fix.
  final String code;
  final String message;

  @override
  Map<String, dynamic> toToolResult() => <String, dynamic>{
    'status': 'rejected',
    'reason': code,
    'message': message,
  };
}

/// How this coordinator reaches the page that owns the conversations.
///
/// It cannot be a construction argument: the coordinator is provided above the
/// page (so the tool handler can read it), while the page is the only thing that
/// can start a turn in another conversation. The page therefore attaches itself
/// once, and detaches when it goes away.
final class SubagentHost {
  const SubagentHost({
    required this.turnStarter,
    this.enqueueResult,
    this.waitReasonFor,
    this.openConversation,
    this.cancelTurn,
    this.enqueueMail,
    this.isTurnRunning,
    this.hasPendingMail,
  });

  final SubagentTurnStarter turnStarter;

  /// Hands a finished result to the parent's queue, as one unit: the notice row
  /// and the turn that reads it.
  ///
  /// The coordinator does not decide when it may land — that is the queue's one
  /// job, and asking here is what made a second delegation's result vanish behind
  /// the first one's answer.
  final void Function({
    required String parentConversationId,
    required ChatMessage notice,
    required Assistant assistant,
    required bool followUp,
  })?
  enqueueResult;

  /// Whether [childConversationId] is parked on an approval or an `ask_user`
  /// card, and which. The two services that know live above this coordinator,
  /// so the page hands the question over rather than the service.
  final SubagentWaitReason? Function(String childConversationId)? waitReasonFor;

  /// Opens a conversation, so the strip and the divider can lead the user to
  /// the child that needs them.
  final void Function(String conversationId)? openConversation;

  /// Stops the generation running in a child conversation.
  final Future<void> Function(String conversationId)? cancelTurn;

  /// Hands one mail row to the conversation that must read it.
  ///
  /// The coordinator has already written the row; the host puts it in that
  /// conversation's inbox, and starts a turn from it when the conversation is
  /// idle. Delivery order and wake rules belong to the queue, not here — a
  /// second place deciding "may this start a turn" is how two messages end up
  /// crossing.
  final void Function({
    required String conversationId,
    required ChatMessage message,
  })?
  enqueueMail;

  /// Whether a turn is running in a conversation right now.
  ///
  /// A turn is a chain of runs: a message that arrives at a step boundary ends
  /// the segment it interrupted and starts a new one, so "the run I was watching
  /// is terminal" does not mean "the child is done". Asked every tick.
  final bool Function(String conversationId)? isTurnRunning;

  /// Whether a conversation has a mail row waiting for its turn to start.
  ///
  /// A turn can end with another message already queued for the child; the
  /// watcher must not report the delegation finished between those two turns.
  final bool Function(String conversationId)? hasPendingMail;
}

/// The coordinator above [context], or null when this subtree has none.
///
/// Look it up by its own type, for the same reason `imageJobCoordinatorOf` does:
/// asking the provider tree for a *nullable* type finds nothing and answers
/// null, which would read as "delegation is off" instead of "not provided".
SubagentCoordinator? subagentCoordinatorOf(BuildContext context) {
  try {
    return context.read<SubagentCoordinator>();
  } catch (_) {
    return null;
  }
}

class SubagentCoordinator extends ChangeNotifier {
  SubagentCoordinator(
    this._chat, {
    DateTime Function()? clock,
    this.pollInterval = const Duration(milliseconds: 500),
  }) : _clock = clock ?? DateTime.now;

  final ChatService _chat;
  final DateTime Function() _clock;

  /// How often the watcher asks the database whether the child's run ended.
  ///
  /// Polling rather than a stream because the run row is written by the
  /// generation pipeline, which owns no notifier for it; 500 ms is under the
  /// human noticing threshold and costs one indexed read.
  final Duration pollInterval;

  /// Pages that can start turns, newest last.
  ///
  /// A stack, not a slot: opening provider settings from the model selector
  /// pushes a second home page, and popping it must not take the host away from
  /// the page the user is still looking at.
  final List<SubagentHost> _hosts = <SubagentHost>[];

  SubagentHost? get _host => _hosts.isEmpty ? null : _hosts.last;

  /// Registers a page that can start turns. Pair it with [detachHost].
  void attachHost(SubagentHost host) {
    _hosts.remove(host);
    _hosts.add(host);
  }

  /// Removes [host], whichever position it holds. A page that was pushed over
  /// another one simply reveals the host underneath.
  void detachHost(SubagentHost host) => _hosts.remove(host);

  final Map<String, SubagentEntry> _byKey = <String, SubagentEntry>{};
  final Map<String, SubagentEntry> _byChild = <String, SubagentEntry>{};
  bool _disposed = false;

  /// Every delegation this process knows about, newest first.
  ///
  /// Keyed by child rather than by tool call: a delegation with no tool-call id
  /// is not idempotent, but it is still a delegation the user must see.
  List<SubagentEntry> get entries {
    final all = _byChild.values.toList(growable: false)
      ..sort((a, b) => b.startedAt.compareTo(a.startedAt));
    return all;
  }

  /// The live delegations started by [parentConversationId], newest first.
  List<SubagentEntry> liveFor(String parentConversationId) => entries
      .where((entry) => entry.parentConversationId == parentConversationId)
      .where((entry) => entry.isLive)
      .toList(growable: false);

  SubagentEntry? entryForKey(String key) => _byKey[key];

  /// Drops a delegation that never produced a turn.
  ///
  /// The child conversation stays — it exists and is empty — but the registry
  /// entry goes, so the strip stops ticking and a retry can delegate again.
  void _forget(SubagentEntry entry, String reason) {
    entry.phase = SubagentPhase.failed;
    entry.failureReason = reason;
    entry.elapsed = Duration.zero;
    if (entry.key != null) _byKey.remove(entry.key);
    _byChild.remove(entry.childConversationId);
    notifyListeners();
  }

  /// Opens the child conversation behind [childConversationId], if this process
  /// still knows it and the page can navigate.
  void openChild(String childConversationId) =>
      _host?.openConversation?.call(childConversationId);

  /// Stops the child's run, so a cancelled parent does not leave work running.
  ///
  /// The watcher then sees a `cancelled` run and writes the notice as usual; no
  /// second bookkeeping path is needed for a cancellation.
  Future<void> cancelChild(String childConversationId) async {
    final cancel = _host?.cancelTurn;
    if (cancel == null) return;
    final entry = _byChild[childConversationId];
    if (entry == null || !entry.isLive) return;
    await cancel(childConversationId);
  }

  /// Sends a delegator's message into a child it started.
  ///
  /// The row is written here, before the host is told about it: a delivery that
  /// the queue has not reached yet must already be visible in the child's
  /// transcript (and in a sync), or a restart would drop what the user can see.
  Future<Map<String, dynamic>> sendToChild({
    required String parentConversationId,
    required String jobId,
    required String text,
    required Assistant assistant,
    String? toolCallId,
  }) async {
    final body = text.trim();
    if (body.isEmpty) {
      return _refused('invalid_arguments', 'A message needs some text.');
    }
    final childId = jobId.trim();
    final child = _chat.getConversation(childId);
    if (child == null ||
        child.extras[SubagentExtrasKeys.parent] != parentConversationId) {
      return _refused(
        'not_found',
        'That job is not a subagent of this conversation.',
      );
    }
    var entry = _byChild[childId];
    if (entry != null && entry.phase == SubagentPhase.cancelled) {
      return _refused(
        'not_continuable',
        'The user stopped this subagent; it cannot be continued.',
      );
    }
    final enqueue = _host?.enqueueMail;
    if (enqueue == null) {
      return _refused('unavailable', 'Subagents are not available right now.');
    }
    final row = _mailRow(
      conversationId: childId,
      from: SubagentMailSender.delegator,
      senderConversationId: parentConversationId,
      // The body only: the attribution is added when the request is built, so
      // the transcript and the exports show a sentence a person can read in
      // their own language instead of an English model-facing prefix.
      text: body,
      toolCallId: toolCallId,
    );
    await _chat.addMessageDirectly(childId, row);
    final wasLive = entry?.isLive ?? false;
    if (entry == null) {
      // After a restart the registry is empty but the conversation is not: adopt
      // it, so the answer this message causes is still reported to the parent.
      // The run already in the table belongs to an earlier turn, so mark it as
      // settled before watching — otherwise the watcher would report that turn
      // as this message's answer.
      final previous = await _chat.chatRepositoryOrNull?.latestGenerationRun(
        childId,
      );
      entry = SubagentEntry(
        key: null,
        parentConversationId: parentConversationId,
        childConversationId: childId,
        title: child.title,
        startedAt: _clock(),
        assistant: assistant,
      )..settledRunId = previous?.id;
      _byChild[childId] = entry;
      notifyListeners();
    } else if (!wasLive) {
      // A finished or stopped delegation is not closed for good: the delegator's
      // model may continue it. The watcher skips the settled run and follows the
      // run this message starts, which is why the id stays behind.
      entry.phase = SubagentPhase.running;
      entry.failureReason = null;
      entry.waitReason = null;
      entry.stoppedByModel = false;
      entry.brief = null;
      entry.elapsed = null;
      // This segment's duration starts now: measuring from the first segment
      // would report the idle gap as time the child spent working.
      entry.startedAt = _clock();
      notifyListeners();
    }
    final running = _host?.isTurnRunning?.call(childId) ?? false;
    // Always watch the conversation, not only when the entry looked idle: the
    // previous watcher may be settling the old run right now, and its loop exits
    // as soon as the phase leaves live. The watcher this bumps is the one that
    // follows the turn this message starts.
    unawaited(_watch(entry));
    enqueue(conversationId: childId, message: row);
    return <String, dynamic>{
      'status': 'delivered',
      'message_id': row.id,
      'delivery': running ? 'next_step' : 'turn_started',
    };
  }

  /// Sends a subagent's message into the conversation that delegated to it.
  Future<Map<String, dynamic>> sendToParent({
    required String childConversationId,
    required String text,
    String? toolCallId,
  }) async {
    final body = text.trim();
    if (body.isEmpty) {
      return _refused('invalid_arguments', 'A message needs some text.');
    }
    final child = _chat.getConversation(childConversationId);
    final parentId = child?.extras[SubagentExtrasKeys.parent] as String?;
    if (child == null || parentId == null) {
      return _refused(
        'no_parent',
        'This conversation was not started by a delegator.',
      );
    }
    final enqueue = _host?.enqueueMail;
    if (enqueue == null) {
      return _refused('unavailable', 'Subagents are not available right now.');
    }
    final row = _mailRow(
      conversationId: parentId,
      from: SubagentMailSender.subagent,
      senderConversationId: childConversationId,
      // Body only, for the same reason as the other direction: the model-facing
      // attribution is added when the request is assembled.
      text: body,
      toolCallId: toolCallId,
    );
    await _chat.addMessageDirectly(parentId, row);
    enqueue(conversationId: parentId, message: row);
    return <String, dynamic>{
      'status': 'delivered',
      'message_id': row.id,
      'delivery': (_host?.isTurnRunning?.call(parentId) ?? false)
          ? 'next_step'
          : 'turn_started',
    };
  }

  /// Asks a child to stop, without treating it as the user's own Stop.
  ///
  /// Returns before anything has stopped, exactly as the tool description says:
  /// the run ends asynchronously and the watcher turns that into a `stopped`
  /// result. A later `send_message` may continue the conversation.
  Future<Map<String, dynamic>> interruptChild({
    required String parentConversationId,
    required String jobId,
  }) async {
    final childId = jobId.trim();
    final child = _chat.getConversation(childId);
    // The same parentage check `send_message` makes: a delegator may stop its
    // own job, not another conversation's.
    if (child == null ||
        child.extras[SubagentExtrasKeys.parent] != parentConversationId) {
      return _refused(
        'not_found',
        'That job is not a subagent of this conversation.',
      );
    }
    final entry = _byChild[childId];
    if (entry == null || !entry.isLive) {
      return <String, dynamic>{
        'status': 'accepted',
        'job_id': childId,
        'note': 'not running',
      };
    }
    entry.stoppedByModel = true;
    await _host?.cancelTurn?.call(childId);
    return <String, dynamic>{'status': 'accepted', 'job_id': childId};
  }

  static Map<String, dynamic> _refused(String reason, String message) =>
      <String, dynamic>{
        'status': 'rejected',
        'reason': reason,
        'message': message,
      };

  ChatMessage _mailRow({
    required String conversationId,
    required SubagentMailSender from,
    required String senderConversationId,
    required String text,
    String? toolCallId,
  }) => ChatMessage(
    id: SubagentMailPart.messageIdFor(senderConversationId, toolCallId ?? ''),
    role: 'user',
    conversationId: conversationId,
    parts: <MessagePart>[
      SubagentMailPart(from: from, senderConversationId: senderConversationId),
      TextPart(text),
    ],
    timestamp: _clock(),
  );

  /// Delegates [task] to a fresh child conversation and returns at once.
  ///
  /// [workspaceExists] answers "does this workspace id still exist". When the
  /// parent is bound to a workspace that has since been deleted, the delegation
  /// is refused here: a child with no workspace would fail every useful tool
  /// later, long after the model told the user it had started.
  ///
  /// [targetAssistant] is who runs the task and [assistant] is who delegated.
  /// They are the same assistant for a `general` delegation. The child's
  /// workspace and grant still come from the delegating conversation and never
  /// from the target: a task handed to another assistant runs in the files this
  /// conversation is working in, not in that assistant's default one.
  Future<SubagentStart> begin({
    required String parentConversationId,
    required String toolCallId,
    required String task,
    required String? label,
    required Assistant assistant,
    Assistant? targetAssistant,
    SubagentTarget? target,
    bool Function(String workspaceId)? workspaceExists,
  }) async {
    // Both default rather than being required: `general` is the whole feature
    // as it shipped, and a caller that has nothing to say about the target is
    // delegating to itself.
    final who = target ?? SubagentTarget.general();
    final runner = targetAssistant ?? assistant;
    // The two arguments describe one decision, so they must agree: an extras
    // value naming one assistant while another one runs the turn would make the
    // stored provenance a lie, and every later reader believes extras.
    final named = who.assistantId;
    if (named != null && runner.id != named) {
      return const SubagentRefused(
        'unknown_target',
        'That assistant is no longer available to this conversation.',
      );
    }
    final key = toolCallId.trim().isEmpty
        // No id means nothing to be idempotent about: deduplicating on the
        // parent alone would collapse every delegation in the conversation into
        // one.
        ? null
        : '$parentConversationId/${toolCallId.trim()}';
    if (key != null) {
      final existing = _byKey[key];
      if (existing != null) return SubagentStarted(existing);
    }

    final host = _host;
    if (host == null) {
      return const SubagentRefused(
        'unavailable',
        'Subagents are not available right now.',
      );
    }

    final parent = _chat.getConversation(parentConversationId);
    if (parent == null) {
      return const SubagentRefused(
        'no_conversation',
        'The conversation this delegation belongs to is gone.',
      );
    }
    // The tool list already hides the tool for these, but a model can emit any
    // function name it remembers; the refusal is what actually enforces it.
    final blocked = delegationBlockedFor(
      extras: parent.extras,
      isGroup: parent.isGroupConversation,
      isTemporary: _chat.isTemporaryConversation(parentConversationId),
    );
    if (blocked != null) {
      return SubagentRefused(blocked, switch (blocked) {
        'group_conversation' =>
          'A group conversation has no single assistant to hand to a '
              'subagent. Ask the user to delegate from a one-to-one chat.',
        'temporary_conversation' =>
          'This is a temporary chat: anything it creates would outlive the '
              'promise that it disappears. Ask the user to delegate from a '
              'saved conversation.',
        _ =>
          'Delegation is limited to $kMaxSubagentDepth level(s); this '
              'conversation is already at the limit.',
      });
    }

    final spec = buildChildSpec(
      parentConversationId: parentConversationId,
      parentExtras: parent.extras,
      escalation: assistant.subagentEscalation,
      // Snapshot the ceiling with the policy: a grant the parent gains or loses
      // while the child runs must not silently widen or withdraw this delegation.
      delegatorHasFullAccess:
          ToolPermissionMode.fromExtras(parent.extras) ==
          ToolPermissionMode.fullAccess,
      target: who.encode(),
    );
    // No workspace is not a refusal: a child inherits whatever the parent has,
    // including nothing. An unbound parent that still wants a second opinion gets
    // an unbound child, which can read and answer and simply has no files.
    final workspaceId = spec.extras[WorkspaceBinding.keyId] as String?;
    if (workspaceId != null &&
        workspaceExists != null &&
        !workspaceExists(workspaceId)) {
      return const SubagentRefused(
        'workspace_not_ready',
        'The workspace this conversation uses no longer exists.',
      );
    }

    final title = childTitle(label: label, task: task);
    final child = await _chat.createConversation(
      title: title.isEmpty ? null : title,
      // The target, not the parent: the child's prompt, model and tools are
      // the assistant the user named. Workspace and grant were decided above,
      // from the delegating side only.
      assistantId: runner.id,
      activate: false,
      extras: spec.extras,
    );
    final entry = SubagentEntry(
      key: key,
      parentConversationId: parentConversationId,
      childConversationId: child.id,
      title: title,
      startedAt: _clock(),
      assistant: assistant,
      target: who,
      // `general` is "a copy of yourself" and needs no name; a named target is
      // shown on the card and in the panel so the user can tell two delegations
      // of the same shape apart.
      targetName: who is AssistantSubagentTarget ? assistantName(runner) : null,
    );
    if (key != null) _byKey[key] = entry;
    _byChild[child.id] = entry;
    notifyListeners();

    SubagentTurnStart turn;
    try {
      turn = await host.turnStarter(
        conversationId: child.id,
        assistant: runner,
        task: task,
        delegator: assistant,
        target: who,
      );
    } catch (error) {
      // Nothing ran, and the entry must not outlive the attempt: a retry of the
      // same tool call has to delegate again rather than be handed back a
      // delegation that never started.
      _forget(entry, 'turn_failed');
      return SubagentRefused(
        'turn_failed',
        'The subagent could not start a turn: $error',
      );
    }
    if (turn.runId == null) {
      // Same reasoning as a throw: there is nothing to watch and nothing to
      // report, so the tool answers with the refusal and the child stays empty.
      _forget(entry, turn.refusal ?? 'turn_not_started');
      return SubagentRefused(
        'turn_not_started',
        'The subagent could not start a turn (${entry.failureReason}).',
      );
    }
    entry.runId = turn.runId;
    unawaited(_watch(entry));
    return SubagentStarted(entry);
  }

  /// Waits for one delegation to finish and reports what it produced.
  ///
  /// Blocks until the child ends, until it parks on something only the user can
  /// answer, or until the waiting turn is cancelled. There is **no default time
  /// limit**, deliberately: a delegation can run for half an hour, and the
  /// alternative to one long wait is the model calling this again every few
  /// seconds — each of those calls re-sends the whole conversation, so polling
  /// costs far more than waiting. Waiting is local, costs no tokens, and the
  /// turn is cancellable throughout.
  ///
  /// [timeout] exists for callers that need a bound; it is not the default.
  ///
  /// Only jobs this process started are known: the registry is memory, which is
  /// the whole reason a restart cannot leave a job "running" forever. An unknown
  /// id therefore answers `not_found` rather than guessing.
  Future<Map<String, dynamic>> awaitJob(
    String jobId, {
    Duration? timeout,
    Future<void>? cancelled,
  }) async {
    final entry = _byChild[jobId.trim()];
    if (entry == null) {
      return <String, dynamic>{'status': 'not_found'};
    }
    // Registering the wait is what stops the wake: a turn that chose to block is
    // the turn that reports the result, and waking it again would answer the same
    // event twice.
    entry.waiters++;
    try {
      final deadline = timeout == null ? null : DateTime.now().add(timeout);
      while (entry.isLive) {
        if (entry.needsInput) {
          // Waiting longer cannot help: the child's next step needs a person.
          return <String, dynamic>{
            'status': 'waiting_for_input',
            'reason': (entry.waitReason ?? SubagentWaitReason.answer).name,
            'conversation_id': entry.childConversationId,
          };
        }
        if (deadline != null && !DateTime.now().isBefore(deadline)) {
          return <String, dynamic>{
            'status': 'still_running',
            'elapsed_ms': DateTime.now()
                .difference(entry.startedAt)
                .inMilliseconds,
          };
        }
        if (cancelled == null) {
          await Future<void>.delayed(pollInterval);
          continue;
        }
        // A Stop must end the wait, not sit inside it: the generation is being
        // cancelled and the run has to be given the chance to close.
        final stopped = await Future.any<bool>(<Future<bool>>[
          Future<void>.delayed(pollInterval).then((_) => false),
          cancelled.then((_) => true),
        ]);
        if (stopped) return <String, dynamic>{'status': 'cancelled'};
      }
    } finally {
      entry.waiters--;
    }
    if (entry.phase == SubagentPhase.stopped) {
      return <String, dynamic>{
        'status': 'stopped',
        'conversation_id': entry.childConversationId,
        'payload': <String, dynamic>{
          'conversation_id': entry.childConversationId,
          'text': entry.brief ?? '',
        },
      };
    }
    if (entry.phase == SubagentPhase.completed) {
      return <String, dynamic>{
        'status': 'completed',
        'payload': <String, dynamic>{
          'conversation_id': entry.childConversationId,
          'text': entry.brief ?? '',
        },
      };
    }
    // Both outcomes carry the conclusion: a failed run's closing sentence is the
    // only place the parent learns *why*, and a wait that was told "failed" with
    // no text had to ask again with another call.
    return <String, dynamic>{
      'status': 'failed',
      'reason': entry.failureReason ?? entry.phase.name,
      'conversation_id': entry.childConversationId,
      'payload': <String, dynamic>{
        'conversation_id': entry.childConversationId,
        'text': entry.brief ?? '',
      },
    };
  }

  Future<void> _watch(SubagentEntry entry) async {
    final repository = _chat.chatRepositoryOrNull;
    if (repository == null) return;
    final generation = ++entry.watchGeneration;
    final childId = entry.childConversationId;
    DateTime? missingSince;
    DateTime? settledSince;
    while (!_disposed) {
      await Future<void>.delayed(pollInterval);
      if (_disposed || entry.watchGeneration != generation) return;
      var run = await repository.latestGenerationRun(childId);
      if (run == null && entry.runId != null) {
        // The conversation was just adopted and its run row is the one we were
        // told about; ask for that one before deciding it is gone.
        run = await repository.getGenerationRun(entry.runId!);
      }
      if (_disposed) return;
      if (run == null) {
        // The row outlives the process, so a missing one means the child's
        // conversation was deleted underneath us. The grace window covers the
        // gap between "a turn is about to start" and its run row existing.
        missingSince ??= DateTime.now();
        if (DateTime.now().difference(missingSince) >
            const Duration(seconds: 10)) {
          await _finish(entry, SubagentPhase.interrupted, 'run_missing');
          return;
        }
        continue;
      }
      missingSince = null;
      if (entry.settledRunId == run.id) {
        // The run this delegation already reported. A continuation is followed
        // by a different run. While its message is still waiting for a turn to
        // start, waiting is the answer — the app may be backgrounded, or the
        // context blocked on a compression review — and closing the delegation
        // then would report a failure for a turn that runs later, unwatched.
        if (_host?.hasPendingMail?.call(childId) ?? false) {
          settledSince = null;
          continue;
        }
        settledSince ??= DateTime.now();
        if (DateTime.now().difference(settledSince) >
            const Duration(seconds: 20)) {
          await _finish(entry, SubagentPhase.failed, 'turn_not_started');
          return;
        }
        continue;
      }
      settledSince = null;
      entry.runId = run.id;
      if (!run.state.isTerminal) {
        // The run is still open, but "open" and "working" are different things:
        // a child parked on an approval or an `ask_user` card will never finish
        // on its own, and the user needs to be told that instead of a ticking
        // timer. Recompute every tick because answering the card unparks it.
        //
        // Two witnesses, because neither is always present: the probe knows which
        // service holds the pending request (and which sentence the strip shows),
        // and `waitingTool` names the state even when the probe cannot see the
        // request. The probe has to be asked unconditionally — nothing in the app
        // currently *writes* `waitingTool`; it is only a declared transition.
        final reason = _host?.waitReasonFor?.call(childId);
        _noteWaiting(
          entry,
          parked: reason != null || run.state == GenerationRunState.waitingTool,
          reason: reason,
        );
        continue;
      }
      // A terminal run is one segment, not necessarily the whole turn: a message
      // that arrived at a step boundary ended it and started the next one. Report
      // only once neither a turn nor another message is outstanding.
      final busy = _host?.isTurnRunning?.call(childId) ?? false;
      final pending = _host?.hasPendingMail?.call(childId) ?? false;
      if (busy || pending) continue;
      await _finish(
        entry,
        _phaseOf(run.state),
        run.errorCode,
        targetMessageId: run.targetRevisionId,
      );
      return;
    }
  }

  void _noteWaiting(
    SubagentEntry entry, {
    required bool parked,
    SubagentWaitReason? reason,
  }) {
    final waiting = parked ? (reason ?? SubagentWaitReason.answer) : null;
    final next = waiting == null
        ? SubagentPhase.running
        : SubagentPhase.waitingForInput;
    if (entry.phase == next && entry.waitReason == waiting) return;
    entry.phase = next;
    entry.waitReason = waiting;
    notifyListeners();
  }

  Future<void> _finish(
    SubagentEntry entry,
    SubagentPhase phase,
    String? reason, {
    String? targetMessageId,
  }) async {
    if (!entry.isLive) return;
    // A run row cannot say who pressed Stop. The model's own `interrupt` is a
    // pause the conversation can be continued from; the user's Stop is final.
    final effective = phase == SubagentPhase.cancelled && entry.stoppedByModel
        ? SubagentPhase.stopped
        : phase;
    entry.failureReason = reason;
    entry.elapsed = _clock().difference(entry.startedAt);

    // A turn blocked in `await_job` receives this outcome as a tool result and
    // answers it itself. Writing the notice as well would put the same conclusion
    // into the conversation twice: a divider the user has to skip past, and a
    // second copy of the report in the next request's context.
    final waited = entry.waiters > 0;
    // The model's own stop is not news to the model: it asked for the stop and
    // got `accepted` back, and a stopped delegation has no conclusion to hand
    // over — it stopped where it was. A row here would tell the parent what it
    // just did.
    final stopped = effective == SubagentPhase.stopped;

    // Compute the conclusion before flipping the phase. `awaitJob` waits for the
    // phase to stop being live and then reads `brief`, so a flip first would
    // answer with an empty conclusion to a model that is blocked on it.
    ChatMessage? notice;
    try {
      // A throw here is a database read failing (a shutdown, a closed handle).
      // It must not swallow the outcome: the fallback brief still names the
      // delegation and its state, so the parent gets a row and a waiting turn gets
      // something to read instead of "done, nothing to say".
      entry.brief =
          await _briefFor(
            entry,
            effective,
            reason,
            targetMessageId: targetMessageId,
          ).catchError(
            (Object _) => resultBrief(
              label: entry.title,
              outcome: _outcomeWord(effective, reason),
              text: '',
              childConversationId: entry.childConversationId,
            ),
          );
      // Read again, not the snapshot: a wait that ended while the brief was being
      // read (a Stop, an explicit timeout) is gone, and its tool result will never
      // be seen. Trusting the stale read would leave the delegation with no row
      // and no continuation — a result that happened and left no trace.
      if (!stopped && (!waited || entry.waiters == 0)) {
        notice = _noticeFor(entry, effective, entry.brief!);
      }
    } finally {
      // A failed computation must not leave the entry looking alive forever.
      entry.phase = effective;
      entry.settledRunId = entry.runId;
      // The flag belongs to this settle only: a later, unrelated Stop on the
      // same entry must be read as the user's, not as the model's.
      entry.stoppedByModel = false;
      notifyListeners();
    }

    if (notice == null) return;
    // The handover: the result goes into the parent's queue as one unit (row and
    // continuation). Whether it may land now is the queue's question, not this
    // one's — asking it here is what silently dropped a second delegation when
    // the first was still being answered.
    //
    // The row is written here, not when the queue gets to it. It is the durable
    // part of a finished delegation: a process killed while the app is in the
    // background must still leave the divider behind, and `addMessageDirectly`
    // is idempotent on the notice's derived id, so the delivery below writing it
    // again costs nothing.
    await _chat.addMessageDirectly(entry.parentConversationId, notice);
    // What the queue decides is only whether the parent is *continued* now.
    final followUp =
        effective == SubagentPhase.completed ||
        effective == SubagentPhase.failed;
    final enqueue = _host?.enqueueResult;
    if (enqueue != null) {
      enqueue(
        parentConversationId: entry.parentConversationId,
        notice: notice,
        assistant: entry.assistant,
        followUp: followUp,
      );
    }
  }

  /// The one-sentence report the parent is given, in either delivery: the notice
  /// row, or the tool result of a turn that waited.
  Future<String> _briefFor(
    SubagentEntry entry,
    SubagentPhase phase,
    String? reason, {
    String? targetMessageId,
  }) async {
    final text = await _childClosingText(entry, targetMessageId);
    return resultBrief(
      label: entry.title,
      outcome: _outcomeWord(phase, reason),
      text: text,
      childConversationId: entry.childConversationId,
    );
  }

  /// The notice row itself: a `user` message carrying the part the renderer and
  /// the exports read, plus the one-sentence brief as its text.
  ChatMessage _noticeFor(
    SubagentEntry entry,
    SubagentPhase phase,
    String brief,
  ) => ChatMessage(
    id: SubagentResultPart.messageIdFor(
      entry.childConversationId,
      runId: entry.runId,
    ),
    role: 'user',
    conversationId: entry.parentConversationId,
    parts: <MessagePart>[
      SubagentResultPart(
        childConversationId: entry.childConversationId,
        elapsedMs: entry.elapsed?.inMilliseconds,
        label: entry.title,
        outcome: phase.name,
      ),
      TextPart(brief),
    ],
    timestamp: _clock(),
  );

  /// The child's last non-empty assistant text, which is what the parent reads.
  ///
  /// The run names the assistant message it was producing, so read that row
  /// first: the message cache is bounded and evicts conversations, and a brief
  /// that loses its body under memory pressure would silently turn "it fixed
  /// three tests" into "completed".
  Future<String> _childClosingText(
    SubagentEntry entry,
    String? targetMessageId,
  ) async {
    final repository = _chat.chatRepositoryOrNull;
    if (repository != null && targetMessageId != null) {
      final message = await repository.getMessage(targetMessageId);
      final content = message?.content.trim() ?? '';
      if (content.isNotEmpty) return content;
    }
    for (final message
        in _chat.getMessages(entry.childConversationId).reversed) {
      if (message.role == 'assistant' && message.content.trim().isNotEmpty) {
        return message.content.trim();
      }
    }
    return '';
  }

  static SubagentPhase _phaseOf(GenerationRunState state) => switch (state) {
    GenerationRunState.completed => SubagentPhase.completed,
    GenerationRunState.cancelled => SubagentPhase.cancelled,
    GenerationRunState.interrupted => SubagentPhase.interrupted,
    GenerationRunState.failed ||
    GenerationRunState.preparing ||
    GenerationRunState.requesting ||
    GenerationRunState.streaming ||
    GenerationRunState.waitingTool => SubagentPhase.failed,
  };

  static String _outcomeWord(SubagentPhase phase, String? reason) {
    final detail = (reason ?? '').trim();
    return switch (phase) {
      SubagentPhase.completed => 'completed',
      SubagentPhase.failed => detail.isEmpty ? 'failed' : 'failed: $detail',
      SubagentPhase.stopped => 'stopped',
      SubagentPhase.cancelled => 'cancelled',
      SubagentPhase.interrupted =>
        detail.isEmpty ? 'interrupted' : 'interrupted: $detail',
      SubagentPhase.running || SubagentPhase.waitingForInput => 'running',
    };
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}
