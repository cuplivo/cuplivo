import 'chat_input_data.dart';
import 'chat_message.dart';
import 'assistant.dart';

/// One turn waiting to land in a conversation, in queue order.
///
/// There is one queue per conversation and it is a plain FIFO: a message the user
/// queued and a finished subagent's result wait in the same line and take their
/// turn in the order they arrived. Nothing decides *whether* to deliver at the
/// moment of arrival — that is the queue's job, and it only ever looks at the
/// head.
sealed class QueuedTurn {
  const QueuedTurn(this.conversationId);

  final String conversationId;
}

/// A message the user sent while the conversation was busy.
final class QueuedUserInput extends QueuedTurn {
  const QueuedUserInput(super.conversationId, this.input);

  final ChatInputData input;
}

/// A finished delegation: its notice row, and — when the outcome is worth
/// reading — the turn that answers it.
///
/// Both halves land together, which is why the row is written here rather than
/// when the child finished: a divider with no continuation, or a continuation
/// with no divider, are both states the user cannot read. A cancellation and an
/// interruption are the exception the design already made: the divider says what
/// happened, and no generation is spent explaining the user's own Stop.
final class QueuedSubagentResult extends QueuedTurn {
  const QueuedSubagentResult(
    super.conversationId, {
    required this.notice,
    required this.assistant,
    this.followUp = true,
  });

  final ChatMessage notice;
  final Assistant assistant;

  /// Whether the parent is continued after the row lands.
  final bool followUp;
}
