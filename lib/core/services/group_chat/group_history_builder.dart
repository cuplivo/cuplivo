import 'dart:convert';

import '../../models/group_chat_message.dart';

/// Builds the API message list sent to a **member** LLM for one group turn.
///
/// Rules (product):
/// - user messages: role + content as-is
/// - messages from [speakerAssistantId]: full assistant content; optional
///   reasoning and tool events
/// - messages from other assistants: role + content only (optional name prefix);
///   reasoning / tools stripped when [stripOtherReasoningAndTools] is true
/// - no "your turn" style prompts are injected here
class GroupHistoryBuilder {
  const GroupHistoryBuilder._();

  /// Convert group timeline messages into OpenAI-style API maps.
  ///
  /// [assistantNames] maps assistantId → display name for other-speaker prefixes.
  /// [toolEventsForMessage] returns completed tool events for an own-speaker
  /// assistant message id (same shape as [ChatService.getToolEvents]).
  static List<Map<String, dynamic>> buildApiMessages({
    required List<GroupChatMessage> messages,
    required String speakerAssistantId,
    Map<String, String> assistantNames = const <String, String>{},
    bool stripOtherReasoningAndTools = true,
    List<Map<String, dynamic>> Function(String messageId)? toolEventsForMessage,
    bool prefixOtherSpeakerNames = true,
  }) {
    final out = <Map<String, dynamic>>[];

    for (final m in messages) {
      if (m.role == 'user' || m.speakerAssistantId == null) {
        final content = m.content;
        if (content.isEmpty && !m.isStreaming) continue;
        out.add(<String, dynamic>{'role': 'user', 'content': content});
        continue;
      }

      final isSelf = m.speakerAssistantId == speakerAssistantId;

      if (isSelf) {
        _appendOwnAssistantMessage(
          out,
          m,
          toolEventsForMessage: toolEventsForMessage,
        );
        continue;
      }

      // Other speakers: content only.
      var content = m.content;
      if (content.isEmpty) continue;
      if (prefixOtherSpeakerNames) {
        final name = assistantNames[m.speakerAssistantId!];
        if (name != null && name.trim().isNotEmpty) {
          content = '[${name.trim()}]: $content';
        }
      }
      if (!stripOtherReasoningAndTools) {
        // Reserved: if product ever allows full other-speaker context,
        // reasoning could be attached here. Default path strips it.
      }
      out.add(<String, dynamic>{'role': 'assistant', 'content': content});
    }

    return out;
  }

  static void _appendOwnAssistantMessage(
    List<Map<String, dynamic>> out,
    GroupChatMessage m, {
    List<Map<String, dynamic>> Function(String messageId)? toolEventsForMessage,
  }) {
    final events =
        toolEventsForMessage?.call(m.id) ?? const <Map<String, dynamic>>[];
    if (events.isNotEmpty) {
      final hasPending = events.any((e) => e['content'] == null);
      if (!hasPending) {
        final calls = <Map<String, dynamic>>[];
        final toolMessages = <Map<String, dynamic>>[];
        for (var i = 0; i < events.length; i++) {
          final e = events[i];
          final name = (e['name'] ?? '').toString().trim();
          if (name.isEmpty) continue;
          final rawId = (e['id'] ?? '').toString().trim();
          final id = rawId.isNotEmpty
              ? rawId
              : 'call_${m.id.substring(0, m.id.length < 8 ? m.id.length : 8)}_$i';

          Map<String, dynamic> args = const <String, dynamic>{};
          final a = e['arguments'];
          if (a is Map) {
            args = a.map((k, v) => MapEntry(k.toString(), v));
          }
          var argumentsJson = '{}';
          try {
            argumentsJson = jsonEncode(args);
          } catch (_) {}

          calls.add(<String, dynamic>{
            'id': id,
            'type': 'function',
            'function': <String, dynamic>{
              'name': name,
              'arguments': argumentsJson,
            },
            if (e['metadata'] is Map)
              'metadata': (e['metadata'] as Map).cast<String, dynamic>(),
          });

          toolMessages.add(<String, dynamic>{
            'role': 'tool',
            'name': name,
            'tool_call_id': id,
            'content': (e['content'] ?? '').toString(),
            if (e['metadata'] is Map)
              'metadata': (e['metadata'] as Map).cast<String, dynamic>(),
          });
        }

        if (calls.isNotEmpty) {
          final toolCallMsg = <String, dynamic>{
            'role': 'assistant',
            'content': '\n\n',
            'tool_calls': calls,
          };
          final reasoning = (m.reasoningText ?? '').trim();
          if (reasoning.isNotEmpty) {
            toolCallMsg['reasoning_content'] = reasoning;
          }
          out.add(toolCallMsg);
          out.addAll(toolMessages);
        }
      }
    }

    final content = m.content;
    if (content.isEmpty) return;

    final msg = <String, dynamic>{'role': 'assistant', 'content': content};
    final reasoning = (m.reasoningText ?? '').trim();
    if (reasoning.isNotEmpty) {
      msg['reasoning_content'] = reasoning;
    }
    out.add(msg);
  }
}
