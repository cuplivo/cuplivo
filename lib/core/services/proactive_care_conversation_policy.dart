import '../models/assistant.dart';
import '../models/conversation.dart';

/// A persisted conversation schedule resolved with its fixed owner assistant.
class ProactiveCareConversationTarget {
  const ProactiveCareConversationTarget({
    required this.conversation,
    required this.assistant,
  });

  final Conversation conversation;
  final Assistant assistant;

  DateTime get expectedAt => conversation.proactiveCareNextMessageAt!;
}

/// Why a future-dated schedule is not in the re-arm's payload.
enum ProactiveCareScheduleOmission {
  /// No fixed owner, so the letter can never be armed.
  ownerless,

  /// The fixed owner id has no assistant in the loaded store.
  ownerGone,

  /// Care is switched off for this conversation.
  switchedOff,
}

/// One pass over a snapshot: what a re-arm would arm, and why it drops the
/// rest of the future schedules.
class ProactiveCareSchedulePlan {
  const ProactiveCareSchedulePlan({
    required this.pending,
    required this.omitted,
  });

  final List<ProactiveCareConversationTarget> pending;

  /// Future schedules left out of [pending], counted per reason. Empty when
  /// every future schedule is eligible.
  final Map<ProactiveCareScheduleOmission, int> omitted;

  int get omittedCount => omitted.values.fold(0, (sum, count) => sum + count);
}

class ProactiveCareConversationPolicy {
  const ProactiveCareConversationPolicy._();

  /// A conversation is owned when it has a fixed owner assistant. Temporary
  /// conversations are never scheduled: they have no persisted schedule.
  static bool isOwnedNormalConversation(
    Conversation conversation,
    Assistant assistant,
  ) =>
      conversation.assistantId != null &&
      conversation.assistantId == assistant.id;

  static bool isEffectivelyEnabled(
    Conversation conversation,
    Assistant assistant,
  ) =>
      conversation.proactiveCareEnabledOverride ??
      assistant.enableProactiveCare;

  static bool isEligible(Conversation conversation, Assistant assistant) =>
      isOwnedNormalConversation(conversation, assistant) &&
      isEffectivelyEnabled(conversation, assistant);

  /// Classifies every future-dated schedule once. A schedule that is past due
  /// is neither armed nor counted as omitted: the re-arm cancels those on
  /// purpose.
  static ProactiveCareSchedulePlan plan({
    required List<Conversation> conversations,
    required List<Assistant> assistants,
    DateTime? now,
  }) {
    final current = now ?? DateTime.now();
    final assistantsById = <String, Assistant>{
      for (final assistant in assistants) assistant.id: assistant,
    };
    final pending = <ProactiveCareConversationTarget>[];
    final omitted = <ProactiveCareScheduleOmission, int>{};
    void omit(ProactiveCareScheduleOmission reason) =>
        omitted.update(reason, (count) => count + 1, ifAbsent: () => 1);

    for (final conversation in conversations) {
      final nextAt = conversation.proactiveCareNextMessageAt;
      if (nextAt == null || !nextAt.isAfter(current)) continue;
      if (conversation.assistantId case final String assistantId) {
        if (assistantsById[assistantId] case final Assistant assistant) {
          if (isEffectivelyEnabled(conversation, assistant)) {
            pending.add(
              ProactiveCareConversationTarget(
                conversation: conversation,
                assistant: assistant,
              ),
            );
          } else {
            omit(ProactiveCareScheduleOmission.switchedOff);
          }
        } else {
          omit(ProactiveCareScheduleOmission.ownerGone);
        }
      } else {
        omit(ProactiveCareScheduleOmission.ownerless);
      }
    }
    return ProactiveCareSchedulePlan(pending: pending, omitted: omitted);
  }

  static List<ProactiveCareConversationTarget> pending({
    required List<Conversation> conversations,
    required List<Assistant> assistants,
    DateTime? now,
  }) => plan(
    conversations: conversations,
    assistants: assistants,
    now: now,
  ).pending;
}
