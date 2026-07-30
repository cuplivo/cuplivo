import 'chat_message.dart';

/// A persisted message plus policy used while preparing an LLM context.
///
/// Ordinary conversations use [full]. Group chat uses [contentOnly] for
/// messages spoken by a different assistant so private reasoning and tool
/// traces cannot cross member boundaries.
class ChatContextMessage {
  const ChatContextMessage({
    required this.message,
    this.includeArtifacts = true,
    this.applyAssistantSendTransform = true,
  });

  const ChatContextMessage.full(ChatMessage message) : this(message: message);

  const ChatContextMessage.contentOnly(ChatMessage message)
    : this(
        message: message,
        includeArtifacts: false,
        applyAssistantSendTransform: false,
      );

  final ChatMessage message;
  final bool includeArtifacts;
  final bool applyAssistantSendTransform;
}
