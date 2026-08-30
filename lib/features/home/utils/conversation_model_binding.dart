import '../../../core/models/conversation.dart';

/// Where an in-conversation model selection should be persisted.
enum ConversationModelWriteTarget {
  /// Write the conversation's own binding (freezes this conversation).
  conversationBinding,

  /// Update the assistant's chat model (status quo: unbound + toggle off).
  assistant,

  /// Update the global default (settings contexts).
  global,
}

/// Write-target rule for in-conversation model switches (ADR-0045):
/// - bound conversation → its own binding, regardless of the toggle;
/// - unbound + toggle on → its own binding (the first switch creates it);
/// - unbound + toggle off → the assistant (status quo).
ConversationModelWriteTarget resolveConversationModelWriteTarget({
  required bool conversationModelIndependent,
  required Conversation? conversation,
}) {
  if (conversation == null) return ConversationModelWriteTarget.assistant;
  if (conversationModelBindingActive(conversation) ||
      conversationModelIndependent) {
    return ConversationModelWriteTarget.conversationBinding;
  }
  return ConversationModelWriteTarget.assistant;
}

/// True when the conversation carries a model binding (fully or partially).
bool conversationModelBindingActive(Conversation? conversation) {
  if (conversation == null) return false;
  return conversation.chatModelProvider != null ||
      conversation.chatModelId != null;
}
