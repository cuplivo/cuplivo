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
import '../../../core/models/workspace_binding.dart';
import '../../../core/services/chat/chat_service.dart';
import 'subagent_rules.dart';

/// How the host starts one turn inside the child conversation.
typedef SubagentTurnStarter =
    Future<SubagentTurnStart> Function({
      required String conversationId,
      required Assistant assistant,
      required String task,
    });

/// How the host continues the parent conversation once a child is done.
///
/// Returns whether a turn actually started: the parent may have begun
/// generating between the check and the call, and the coordinator retries in
/// that case.
typedef SubagentParentWaker =
    Future<bool> Function({
      required String parentConversationId,
      required ChatMessage result,
      required Assistant assistant,
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
  });

  final String? key;
  final String parentConversationId;
  final String childConversationId;

  /// The model's short name for the job, already bounded by `childTitle`.
  final String title;
  final DateTime startedAt;
  final Assistant assistant;

  SubagentPhase phase = SubagentPhase.running;
  SubagentWaitReason? waitReason;
  String? runId;
  String? failureReason;
  Duration? elapsed;

  /// The brief the parent conversation was given, kept so `await_job` can hand
  /// back the conclusion without re-reading the message.
  String? brief;

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
    required this.parentWaker,
    this.canWake,
    this.waitReasonFor,
    this.openConversation,
    this.cancelTurn,
    this.refreshTimeline,
  });

  final SubagentTurnStarter turnStarter;
  final SubagentParentWaker parentWaker;

  /// Whether [parentConversationId] may be continued right now. Null: always.
  ///
  /// Asynchronous because the honest answers need one: whether the app is in
  /// front has to be asked of the background coordinator, which only learns it
  /// asynchronously.
  final Future<bool> Function(String parentConversationId)? canWake;

  /// Whether [childConversationId] is parked on an approval or an `ask_user`
  /// card, and which. The two services that know live above this coordinator,
  /// so the page hands the question over rather than the service.
  final SubagentWaitReason? Function(String childConversationId)? waitReasonFor;

  /// Opens a conversation, so the strip and the divider can lead the user to
  /// the child that needs them.
  final void Function(String conversationId)? openConversation;

  /// Stops the generation running in a child conversation.
  final Future<void> Function(String conversationId)? cancelTurn;

  /// Reloads the visible timeline of [conversationId] after a write that did not
  /// go through the chat flow. Without it a result row sits in the database but
  /// not on screen until the next send or conversation switch.
  final Future<void> Function(String conversationId)? refreshTimeline;
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

  /// Delegates [task] to a fresh child conversation and returns at once.
  ///
  /// [workspaceExists] answers "does this workspace id still exist". When the
  /// parent is bound to a workspace that has since been deleted, the delegation
  /// is refused here: a child with no workspace would fail every useful tool
  /// later, long after the model told the user it had started.
  Future<SubagentStart> begin({
    required String parentConversationId,
    required String toolCallId,
    required String task,
    required String? label,
    required Assistant assistant,
    bool Function(String workspaceId)? workspaceExists,
  }) async {
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
    );
    final workspaceId = spec.extras[WorkspaceBinding.keyId] as String?;
    if (workspaceId == null) {
      // A subagent without a workspace can read and answer, but every useful
      // part of the job needs files. Refusing here tells the model something it
      // can act on instead of starting work that cannot finish.
      return const SubagentRefused(
        'no_workspace',
        'This conversation has no workspace, so there is nothing for a '
            'subagent to work on. Ask the user to bind a workspace first.',
      );
    }
    if (workspaceExists != null && !workspaceExists(workspaceId)) {
      return const SubagentRefused(
        'workspace_not_ready',
        'The workspace this conversation uses no longer exists.',
      );
    }

    final title = childTitle(label: label, task: task);
    final child = await _chat.createConversation(
      title: title.isEmpty ? null : title,
      assistantId: parent.assistantId,
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
    );
    if (key != null) _byKey[key] = entry;
    _byChild[child.id] = entry;
    notifyListeners();

    SubagentTurnStart turn;
    try {
      turn = await host.turnStarter(
        conversationId: child.id,
        assistant: assistant,
        task: task,
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
    if (entry.phase == SubagentPhase.completed) {
      return <String, dynamic>{
        'status': 'completed',
        'payload': <String, dynamic>{
          'conversation_id': entry.childConversationId,
          'text': entry.brief ?? '',
        },
      };
    }
    return <String, dynamic>{
      'status': 'failed',
      'reason': entry.failureReason ?? entry.phase.name,
      'conversation_id': entry.childConversationId,
    };
  }

  Future<void> _watch(SubagentEntry entry) async {
    final runId = entry.runId;
    final repository = _chat.chatRepositoryOrNull;
    if (runId == null || repository == null) return;
    while (!_disposed) {
      await Future<void>.delayed(pollInterval);
      if (_disposed) return;
      final run = await repository.getGenerationRun(runId);
      if (_disposed) return;
      if (run == null) {
        // The row outlives the process, so a missing one means the child's
        // conversation was deleted underneath us.
        await _finish(entry, SubagentPhase.interrupted, 'run_missing');
        return;
      }
      if (!run.state.isTerminal) {
        // The run is still open, but "open" and "working" are different things:
        // a child parked on an approval or an `ask_user` card will never finish
        // on its own, and the user needs to be told that instead of a ticking
        // timer. Recompute every tick because answering the card unparks it.
        _noteWaiting(entry);
        continue;
      }
      await _finish(
        entry,
        _phaseOf(run.state),
        run.errorCode,
        targetMessageId: run.targetRevisionId,
      );
      return;
    }
  }

  void _noteWaiting(SubagentEntry entry) {
    final probe = _host?.waitReasonFor;
    if (probe == null) return;
    final reason = probe(entry.childConversationId);
    final next = reason == null
        ? SubagentPhase.running
        : SubagentPhase.waitingForInput;
    if (entry.phase == next && entry.waitReason == reason) return;
    entry.phase = next;
    entry.waitReason = reason;
    notifyListeners();
  }

  Future<void> _finish(
    SubagentEntry entry,
    SubagentPhase phase,
    String? reason, {
    String? targetMessageId,
  }) async {
    if (!entry.isLive) return;
    entry.failureReason = reason;
    entry.elapsed = _clock().difference(entry.startedAt);

    // Write before flipping the phase. `awaitJob` waits for the phase to stop
    // being live and then reads `brief`, so a flip first would answer with an
    // empty conclusion to a model that is blocked on it.
    ChatMessage? result;
    try {
      result = await _writeResult(
        entry,
        phase,
        reason,
        targetMessageId: targetMessageId,
      );
    } finally {
      // A failed write must not leave the entry looking alive forever.
      entry.phase = phase;
      notifyListeners();
    }

    if (result == null) return;
    // The row is now in the database but not in the open timeline: nothing else
    // reloads a conversation that was written by something other than the chat
    // flow.
    await _host?.refreshTimeline?.call(entry.parentConversationId);
    // A cancellation is the user's own doing and an interruption is the
    // environment's; neither should spend another generation explaining it.
    // A failure should: one line in the timeline is easy to scroll past, and
    // the user's next move depends on knowing the work did not happen.
    if (phase == SubagentPhase.completed || phase == SubagentPhase.failed) {
      await _wakeParentIfAllowed(entry, result);
    }
  }

  Future<ChatMessage?> _writeResult(
    SubagentEntry entry,
    SubagentPhase phase,
    String? reason, {
    String? targetMessageId,
  }) async {
    final text = await _childClosingText(entry, targetMessageId);
    final elapsed = entry.elapsed;
    final brief = resultBrief(
      label: entry.title,
      outcome: _outcomeWord(phase, reason),
      text: text,
      childConversationId: entry.childConversationId,
    );
    final message = ChatMessage(
      id: SubagentResultPart.messageIdFor(entry.childConversationId),
      role: 'user',
      conversationId: entry.parentConversationId,
      parts: <MessagePart>[
        SubagentResultPart(
          childConversationId: entry.childConversationId,
          elapsedMs: elapsed?.inMilliseconds,
          label: entry.title,
          outcome: phase.name,
        ),
        TextPart(brief),
      ],
      timestamp: _clock(),
    );
    // The id is derived from the child, so calling this twice cannot add a row.
    await _chat.addMessageDirectly(entry.parentConversationId, message);
    entry.brief = brief;
    return message;
  }

  /// How long a wake keeps retrying while the parent is busy.
  static const Duration _wakeRetryDelay = Duration(seconds: 2);
  static const int _wakeAttempts = 15;

  /// Continues the parent, waiting out a busy turn.
  ///
  /// The wake is the only thing that puts the notice in front of the user
  /// without them acting, so "the parent happened to be generating" must not be
  /// the end of the story: the notice would sit there until the user's next
  /// message. A turn ends in seconds, so a bounded retry covers the real case; a
  /// parent that stays busy for half a minute (a draft, a long compression) keeps
  /// the notice for the next turn, which is where it would have landed anyway.
  Future<void> _wakeParentIfAllowed(
    SubagentEntry entry,
    ChatMessage result,
  ) async {
    if (_chat.getConversation(entry.parentConversationId) == null) return;
    for (var attempt = 0; attempt < _wakeAttempts; attempt++) {
      if (_disposed) return;
      final host = _host;
      if (host == null) return;
      final canWake = host.canWake;
      if (canWake == null || await canWake(entry.parentConversationId)) {
        if (_chat.getConversation(entry.parentConversationId) == null) return;
        final woken = await host.parentWaker(
          parentConversationId: entry.parentConversationId,
          result: result,
          assistant: entry.assistant,
        );
        // A turn that could not start (the parent started generating in the
        // meantime) is worth another attempt for the same reason as above.
        if (woken) return;
      }
      await Future<void>.delayed(_wakeRetryDelay);
    }
  }

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
