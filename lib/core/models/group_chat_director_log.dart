/// The public trigger that caused one director invocation.
enum GroupChatDirectorLogTrigger { user, assistant, capMerge }

/// Runtime-only metadata captured for one director invocation.
///
/// This type deliberately contains no request transcript. The request is
/// reconstructed from the public group conversation when the log page is
/// opened, while this object only preserves details that cannot be inferred
/// later (for example retry errors and the model's decision reason).
class GroupChatDirectorRuntimeLog {
  GroupChatDirectorRuntimeLog({
    required this.sourceMessageId,
    required this.trigger,
    required this.startedAt,
    required this.finishedAt,
    required this.providerKey,
    required this.modelId,
    required this.requestMessageCount,
    required this.attemptCount,
    required List<String> attemptErrors,
    this.decisionKind,
    this.assistantId,
    this.reason,
    this.fallback = false,
    this.freeText,
    this.failure,
  }) : attemptErrors = List.unmodifiable(attemptErrors);

  final String? sourceMessageId;
  final GroupChatDirectorLogTrigger trigger;
  final DateTime startedAt;
  final DateTime finishedAt;
  final String? providerKey;
  final String? modelId;
  final int requestMessageCount;
  final int attemptCount;
  final List<String> attemptErrors;
  final String? decisionKind;
  final String? assistantId;
  final String? reason;
  final bool fallback;
  final String? freeText;
  final String? failure;

  bool get hasErrors => attemptErrors.isNotEmpty || failure != null;
}
