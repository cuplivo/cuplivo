import '../../models/chat_context_message.dart';
import '../../models/chat_message.dart';
import '../../models/group_chat_message.dart';

/// Projects group timeline entries into the shared chat context model.
///
/// It intentionally does not encode provider API maps. Tool calls, reasoning,
/// timestamps, templates, and prompt injections remain owned by the ordinary
/// message-building pipeline.
class GroupChatContextProjector {
  const GroupChatContextProjector._();

  static final RegExp _geminiThoughtSignature = RegExp(
    r'<!--\s*gemini_thought_signatures:.*?-->',
    dotAll: true,
  );

  static List<ChatContextMessage> project({
    required List<GroupChatMessage> messages,
    required String speakerAssistantId,
    Map<String, String> assistantNames = const <String, String>{},
  }) {
    return messages
        .map((message) {
          final isUser =
              message.role == 'user' || message.speakerAssistantId == null;
          final isCurrentSpeaker =
              message.speakerAssistantId == speakerAssistantId;
          final content = isUser || isCurrentSpeaker
              ? message.content
              : _otherSpeakerContent(message, assistantNames);
          final adapted = toChatMessage(message, content: content);
          return isUser || isCurrentSpeaker
              ? ChatContextMessage.full(adapted)
              : ChatContextMessage.contentOnly(adapted);
        })
        .toList(growable: false);
  }

  static ChatMessage toChatMessage(
    GroupChatMessage message, {
    String? content,
  }) {
    return ChatMessage(
      id: message.id,
      role: message.role,
      content: content ?? message.content,
      timestamp: message.timestamp,
      modelId: message.modelId,
      providerId: message.providerId,
      totalTokens: message.totalTokens,
      conversationId: message.groupId,
      isStreaming: message.isStreaming,
      reasoningText: message.reasoningText,
      reasoningStartAt: message.reasoningStartAt,
      reasoningFinishedAt: message.reasoningFinishedAt,
      reasoningSegmentsJson: message.reasoningSegmentsJson,
      groupId: message.id,
      version: 0,
      promptTokens: message.promptTokens,
      completionTokens: message.completionTokens,
      cachedTokens: message.cachedTokens,
      durationMs: message.durationMs,
    );
  }

  static String _otherSpeakerContent(
    GroupChatMessage message,
    Map<String, String> assistantNames,
  ) {
    final assistantId = message.speakerAssistantId;
    final name = assistantId == null ? null : assistantNames[assistantId];
    final normalizedName = name?.trim() ?? '';
    final content = message.content
        .replaceAll(_geminiThoughtSignature, '')
        .trimRight();
    if (normalizedName.isEmpty || content.isEmpty) {
      return content;
    }
    return '[$normalizedName]: $content';
  }
}
