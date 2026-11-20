import 'package:flutter/foundation.dart';

import 'package:Cuplivo/core/models/chat_message.dart';
import 'package:Cuplivo/core/models/message_part.dart';
import 'package:Cuplivo/features/chat/widgets/chat_message_widget.dart'
    show ToolUIPart;
import 'package:Cuplivo/features/harness/controllers/dsh_chat_session.dart';
import 'package:Cuplivo/features/home/controllers/stream_controller.dart'
    as stream_ctrl;

/// A non-message row of the remote log, rendered as a banner by the chat.
@immutable
class DshTranscriptNotice {
  const DshTranscriptNotice({
    required this.id,
    required this.kind,
    required this.text,
  });

  final String id;
  final DshNoticeKind kind;
  final String text;
}

/// The remote transcript folded into exactly the structures Cuplivo's own
/// renderer already consumes.
///
/// `MessageListView`/`ChatMessageWidget` are unchanged: the fold produces
/// [ChatMessage]s plus the per-message maps for reasoning segments, tool cards
/// and content splits, so every Cuplivo rendering setting (markdown, code,
/// thinking cards, tool cards, font scale, appearance) applies to remote turns
/// exactly as it does to local ones.
@immutable
class DshFoldedTranscript {
  const DshFoldedTranscript({
    this.messages = const <ChatMessage>[],
    this.reasoning = const <String, stream_ctrl.ReasoningData>{},
    this.reasoningSegments =
        const <String, List<stream_ctrl.ReasoningSegmentData>>{},
    this.contentSplits = const <String, stream_ctrl.ContentSplitData>{},
    this.toolParts = const <String, List<ToolUIPart>>{},
    this.notices = const <DshTranscriptNotice>[],
  });

  /// Renderer input, oldest first.
  final List<ChatMessage> messages;

  /// Scalar reasoning per message id (the renderer's per-message summary).
  final Map<String, stream_ctrl.ReasoningData> reasoning;

  /// Interleaved reasoning blocks per message id.
  final Map<String, List<stream_ctrl.ReasoningSegmentData>> reasoningSegments;

  /// Interleaving metadata; empty until the remote events carry an order the
  /// fold can prove (the renderer then lays reasoning/tools out by count).
  final Map<String, stream_ctrl.ContentSplitData> contentSplits;

  /// Tool cards per message id.
  final Map<String, List<ToolUIPart>> toolParts;

  /// Turn errors/cancellations that are not messages.
  final List<DshTranscriptNotice> notices;

  bool get isEmpty => messages.isEmpty;
}

/// A timestamp the renderer can always format, in the local zone like every
/// local-chat row.
///
/// The Host reports UTC epoch milliseconds; the renderer formats the value it
/// is given verbatim, so the conversion happens here. Rows without an
/// authoritative wire time (null, or the epoch-zero default a missing stamp
/// decodes to) keep epoch zero, which the message row treats as "no time" and
/// hides instead of printing 1970.
DateTime _renderTimestamp(DateTime? timestamp) {
  if (timestamp == null || timestamp.millisecondsSinceEpoch == 0) {
    return DateTime.fromMillisecondsSinceEpoch(0);
  }
  return timestamp.toLocal();
}

List<stream_ctrl.ReasoningSegmentData> _foldReasoning(
  List<DshReasoningSegment> segments,
) {
  return <stream_ctrl.ReasoningSegmentData>[
    for (final segment in segments)
      stream_ctrl.ReasoningSegmentData()
        ..text = segment.text
        ..startAt = segment.startedAt
        ..finishedAt = segment.finishedAt
        ..expanded = true
        ..toolStartIndex = 0,
  ];
}

List<ToolUIPart> _foldTools(List<DshToolCall> tools) {
  return <ToolUIPart>[
    for (final tool in tools)
      ToolUIPart(
        id: tool.id,
        toolName: tool.name,
        arguments: tool.arguments,
        content: tool.resultText,
        loading: tool.isRunning,
      ),
  ];
}

/// Folds [state]'s transcript into Cuplivo's rendering structures.
///
/// Pure: no widgets, no providers, no network. [conversationId] is a synthetic
/// in-memory key (`dsh:<remoteId>:<sessionId>`); no DSH row is ever written to
/// Cuplivo's database.
DshFoldedTranscript foldDshTranscript({
  required String conversationId,
  required DshChatViewState state,
}) {
  final messages = <ChatMessage>[];
  final reasoning = <String, stream_ctrl.ReasoningData>{};
  final reasoningSegments = <String, List<stream_ctrl.ReasoningSegmentData>>{};
  final toolParts = <String, List<ToolUIPart>>{};
  final notices = <DshTranscriptNotice>[];

  for (final item in state.items) {
    switch (item) {
      case DshUserMessageItem():
        messages.add(
          ChatMessage(
            id: item.id,
            role: 'user',
            parts: <MessagePart>[TextPart(item.text)],
            timestamp: _renderTimestamp(item.timestamp),
            conversationId: conversationId,
          ),
        );
      case DshAssistantMessageItem():
        final segments = _foldReasoning(item.reasoning);
        final foldedReasoning = stream_ctrl.ReasoningData();
        if (item.reasoning.isNotEmpty) {
          final text = item.reasoning
              .map((segment) => segment.text)
              .where((part) => part.isNotEmpty)
              .join('\n\n');
          foldedReasoning
            ..text = text
            ..startAt = item.reasoning.first.startedAt
            ..finishedAt = item.reasoning.last.finishedAt
            ..expanded = true;
        }
        messages.add(
          ChatMessage(
            id: item.id,
            role: 'assistant',
            parts: <MessagePart>[TextPart(item.text)],
            timestamp: _renderTimestamp(item.timestamp),
            conversationId: conversationId,
            isStreaming: item.isStreaming,
            modelId: item.modelId,
            providerId: item.providerId,
            reasoningText: foldedReasoning.text.isEmpty
                ? null
                : foldedReasoning.text,
            reasoningStartAt: foldedReasoning.startAt,
            reasoningFinishedAt: foldedReasoning.finishedAt,
            promptTokens: item.usage?.promptTokens,
            completionTokens: item.usage?.completionTokens,
            totalTokens: item.usage?.totalTokens,
          ),
        );
        if (segments.isNotEmpty) {
          reasoningSegments[item.id] = segments;
        }
        reasoning[item.id] = foldedReasoning;
        final tools = _foldTools(item.tools);
        if (tools.isNotEmpty) {
          toolParts[item.id] = tools;
        }
        final failure = (item.failureMessage ?? '').trim();
        if (failure.isNotEmpty) {
          notices.add(
            DshTranscriptNotice(
              id: '${item.id}:failure',
              kind: DshNoticeKind.error,
              text: failure,
            ),
          );
        }
      case DshNoticeItem():
        notices.add(
          DshTranscriptNotice(id: item.id, kind: item.kind, text: item.text),
        );
    }
  }

  return DshFoldedTranscript(
    messages: List<ChatMessage>.unmodifiable(messages),
    reasoning: Map<String, stream_ctrl.ReasoningData>.unmodifiable(reasoning),
    reasoningSegments:
        Map<String, List<stream_ctrl.ReasoningSegmentData>>.unmodifiable(
          reasoningSegments,
        ),
    contentSplits: const <String, stream_ctrl.ContentSplitData>{},
    toolParts: Map<String, List<ToolUIPart>>.unmodifiable(toolParts),
    notices: List<DshTranscriptNotice>.unmodifiable(notices),
  );
}

/// Renderer inputs the fold hands to `MessageListView` for its grouping
/// parameters: one message per group, version 0.
@immutable
class DshTranscriptGrouping {
  const DshTranscriptGrouping({
    required this.byGroup,
    required this.versionSelections,
  });

  final Map<String, List<ChatMessage>> byGroup;
  final Map<String, int> versionSelections;
}

DshTranscriptGrouping groupDshTranscript(List<ChatMessage> messages) {
  final byGroup = <String, List<ChatMessage>>{};
  final versionSelections = <String, int>{};
  for (final message in messages) {
    final groupId = message.groupId ?? message.id;
    byGroup.putIfAbsent(groupId, () => <ChatMessage>[]).add(message);
    versionSelections[groupId] = 0;
  }
  return DshTranscriptGrouping(
    byGroup: Map<String, List<ChatMessage>>.unmodifiable(byGroup),
    versionSelections: Map<String, int>.unmodifiable(versionSelections),
  );
}
