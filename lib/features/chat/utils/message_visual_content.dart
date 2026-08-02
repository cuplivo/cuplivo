import 'dart:convert';

import 'package:flutter/widgets.dart';
import 'package:provider/provider.dart';

import '../../../core/models/assistant.dart';
import '../../../core/models/assistant_regex.dart';
import '../../../core/models/chat_message.dart';
import '../../../core/providers/assistant_provider.dart';
import '../../../core/services/chat/chat_service.dart';
import '../../../utils/assistant_regex.dart';
import 'thinking_tag_parser.dart';

/// Minimum visual-content length (characters) for the reading-mode entry to
/// appear in the message "More" menu.
const int kReadingModeMinChars = 800;

/// Mirrors the renderer-consumed content pipeline of
/// `ChatMessageWidget._buildAssistantMessage`
/// (lib/features/chat/widgets/chat_message_widget.dart): legacy `<think>`
/// blocks are stripped unless structured reasoning is present, then the
/// assistant's visual regex transforms are applied. Change both together.
String messageVisualContent(ChatMessage message, {Assistant? assistant}) {
  final visibleContent = _hasStructuredReasoning(message)
      ? message.content
      : ThinkingTagParser.parseLegacyInlineBlocks(
          message.content,
        ).visibleContent;
  return applyAssistantRegexes(
    visibleContent,
    assistant: assistant,
    scope: AssistantRegexScope.assistant,
    target: AssistantRegexTransformTarget.visual,
  );
}

/// Structured reasoning is present when `reasoningText` is non-empty, or the
/// persisted `reasoningSegmentsJson` parses to a NON-EMPTY segment list
/// (both the list form `[...]` and the map form `{"segments": [...]}`).
/// Empty (`[]` / `segments: []`) or malformed payloads count as absent —
/// `serializeReasoningSegmentsWithSplits` persists `[]` for empty streams.
/// Mirrors `message_builder_service.dart` `_reasoningContentForToolContinuation`.
bool _hasStructuredReasoning(ChatMessage message) {
  if (message.reasoningText?.isNotEmpty ?? false) return true;
  final raw = (message.reasoningSegmentsJson ?? '').trim();
  if (raw.isEmpty) return false;
  try {
    final decoded = jsonDecode(raw);
    final segmentsRaw = switch (decoded) {
      Map<String, dynamic> map => map['segments'],
      List<dynamic> list => list,
      _ => null,
    };
    if (segmentsRaw is! List) return false;
    return segmentsRaw.isNotEmpty;
  } catch (_) {
    return false;
  }
}

/// Resolves the assistant whose visual regex transforms apply to a message:
/// the group-chat speaker (`speakerAssistantId`) first, then the owning
/// conversation's assistant. Mirrors `ChatMessageWidget._assistantForMessage`
/// (lib/features/chat/widgets/chat_message_widget.dart) — change both
/// together. Returns null when unavailable (no providers, deleted assistant).
Assistant? assistantForMessage(BuildContext context, ChatMessage message) {
  try {
    final ap = context.read<AssistantProvider>();
    final speakerId = message.speakerAssistantId;
    if (speakerId != null && speakerId.isNotEmpty) {
      final speaker = ap.getById(speakerId);
      if (speaker != null) return speaker;
    }
    final chat = context.read<ChatService>();
    final convo = chat.getConversation(message.conversationId);
    final aId = convo?.assistantId;
    if (aId == null || aId.isEmpty) return null;
    return ap.getById(aId);
  } catch (_) {
    return null;
  }
}

/// Gate for the reading-mode entry: assistant-only, not streaming, and the
/// visual content must exceed [kReadingModeMinChars].
bool canUseReadingMode(ChatMessage message) {
  return message.role != 'user' &&
      !message.isStreaming &&
      messageVisualContent(message).length > kReadingModeMinChars;
}
