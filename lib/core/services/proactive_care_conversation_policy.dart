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

class ProactiveCareConversationPolicy {
  const ProactiveCareConversationPolicy._();

  static bool isOwnedNormalConversation(
    Conversation conversation,
    Assistant assistant,
  ) =>
      conversation.conversationKind == Conversation.kindNormal &&
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

  static List<ProactiveCareConversationTarget> pending({
    required List<Conversation> conversations,
    required List<Assistant> assistants,
    DateTime? now,
  }) {
    final current = now ?? DateTime.now();
    final assistantsById = <String, Assistant>{
      for (final assistant in assistants) assistant.id: assistant,
    };
    return <ProactiveCareConversationTarget>[
      for (final conversation in conversations)
        if (conversation.assistantId case final String assistantId)
          if (assistantsById[assistantId] case final Assistant assistant)
            if (isEligible(conversation, assistant) &&
                conversation.proactiveCareNextMessageAt != null &&
                conversation.proactiveCareNextMessageAt!.isAfter(current))
              ProactiveCareConversationTarget(
                conversation: conversation,
                assistant: assistant,
              ),
    ];
  }
}
