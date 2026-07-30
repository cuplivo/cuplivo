import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../../core/models/assistant.dart';
import '../../../core/models/group_chat_message.dart';
import '../../../core/models/token_usage.dart';
import '../../../core/providers/settings_provider.dart';
import '../../../core/services/chat/chat_service.dart';
import '../../../core/services/chat/group_chat_service.dart';
import '../../../core/services/chat/model_capability_service.dart';
import '../../../core/services/group_chat/group_chat_context_projector.dart';
import '../../../core/services/group_chat/group_chat_orchestrator.dart';
import '../../../utils/assistant_regex.dart';
import '../../../utils/markdown_media_sanitizer.dart';
import '../../../core/models/assistant_regex.dart';
import '../../home/controllers/stream_controller.dart' as stream_ctrl;

/// Shared stream-state adapter for group member replies.
///
/// The provider stream remains orchestrator-owned, while chunk interpretation,
/// reasoning segments, tool cards, signatures, throttling, and restoration use
/// the same [stream_ctrl.StreamController] as ordinary chat.
class GroupMemberStreamService extends ChangeNotifier {
  GroupMemberStreamService({
    required ChatService chatService,
    required this.groupChatService,
    required this.getSettings,
  }) {
    streamController = stream_ctrl.StreamController(
      chatService: chatService,
      onStateChanged: notifyListeners,
      getSettingsProvider: getSettings,
      getCurrentConversationId: () => groupChatService.currentGroupId,
      setGeminiThoughtSignatureCallback:
          groupChatService.setGeminiThoughtSignature,
      getGeminiThoughtSignatureCallback:
          groupChatService.getGeminiThoughtSignature,
    );
  }

  final GroupChatService groupChatService;
  final SettingsProvider Function() getSettings;
  late final stream_ctrl.StreamController streamController;

  void restoreMessages(List<GroupChatMessage> messages) {
    for (final message in messages) {
      streamController.restoreMessageUiState(
        GroupChatContextProjector.toChatMessage(message),
        getToolEventsFromDb: groupChatService.getToolEvents,
        getGeminiThoughtSigFromDb: groupChatService.getGeminiThoughtSignature,
      );
    }
    notifyListeners();
  }

  Future<GroupChatMessage> run({
    required GroupChatMessage placeholder,
    required Assistant assistant,
    required SettingsProvider settings,
    required String providerKey,
    required String modelId,
    required GroupMemberGenerationPreparation prepared,
    required GroupChatStreamFactory sendMessageStream,
    required bool Function() isCancelled,
  }) async {
    final messageId = placeholder.id;
    final groupId = placeholder.groupId;
    final config = settings.getProviderConfig(providerKey);
    final context = stream_ctrl.GenerationContext(
      assistantMessage: GroupChatContextProjector.toChatMessage(placeholder),
      apiMessages: prepared.apiMessages,
      userMediaPaths: prepared.userMediaPaths,
      allowImagesApiRouting: false,
      providerKey: providerKey,
      modelId: modelId,
      assistant: assistant,
      settings: settings,
      config: config,
      toolDefs: prepared.toolDefs,
      onToolCall: prepared.onToolCall,
      extraHeaders: prepared.extraHeaders,
      extraBody: prepared.extraBody,
      supportsReasoning: ModelCapabilityService.supportsReasoning(
        settings,
        providerKey,
        modelId,
      ),
      enableReasoning: true,
      streamOutput: assistant.streamOutput,
      ocrActive: false,
      generateTitleOnFinish: false,
    );
    final state = stream_ctrl.StreamingState(context);
    streamController.markStreamingStarted(messageId);

    var current = placeholder;
    final startedAt = DateTime.now();
    try {
      await for (final chunk in sendMessageStream(
        GroupChatStreamRequest(
          config: config,
          modelId: modelId,
          messages: prepared.apiMessages,
          userMediaPaths: prepared.userMediaPaths,
          tools: prepared.toolDefs.isEmpty ? null : prepared.toolDefs,
          onToolCall: prepared.onToolCall,
          thinkingBudget: assistant.thinkingBudget ?? settings.thinkingBudget,
          temperature: assistant.temperature,
          topP: assistant.topP,
          maxTokens: assistant.maxTokens,
          stream: assistant.streamOutput,
          requestId: messageId,
          extraHeaders: prepared.extraHeaders,
          extraBody: prepared.extraBody,
        ),
      )) {
        if (isCancelled()) throw const _GroupStreamCancelled();
        final content = chunk.content.isEmpty
            ? ''
            : streamController.captureGeminiThoughtSignature(
                chunk.content,
                messageId,
              );
        final capturedSignature = streamController.geminiThoughtSigs[messageId];
        if (capturedSignature != null && capturedSignature.isNotEmpty) {
          await groupChatService.setGeminiThoughtSignature(
            messageId,
            capturedSignature,
          );
        }
        if (chunk.reasoningDetails != null) {
          streamController.setReasoningDetails(
            messageId,
            chunk.reasoningDetails,
          );
        }
        if ((chunk.reasoning ?? '').isNotEmpty) {
          await streamController.handleReasoningChunk(
            chunk,
            state,
            updateReasoningInDb:
                (
                  _, {
                  reasoningText,
                  reasoningStartAt,
                  reasoningSegmentsJson,
                }) async {
                  current = _mergeReasoningUpdate(
                    current,
                    reasoningText: reasoningText,
                    reasoningStartAt: reasoningStartAt,
                    reasoningSegmentsJson: reasoningSegmentsJson,
                  );
                  await groupChatService.updateMessage(current, notify: false);
                },
          );
        }
        if ((chunk.toolCalls ?? const []).isNotEmpty) {
          await streamController.handleToolCallsChunk(
            chunk,
            state,
            updateReasoningSegmentsInDb: (_, json) async {
              current = current.copyWith(reasoningSegmentsJson: json);
              await groupChatService.updateMessage(current, notify: false);
            },
            setToolEventsInDb: groupChatService.setToolEvents,
            getToolEventsFromDb: groupChatService.getToolEvents,
          );
        }
        if ((chunk.toolResults ?? const []).isNotEmpty) {
          await streamController.handleToolResultsChunk(
            chunk,
            state,
            upsertToolEventInDb:
                (
                  _, {
                  required id,
                  required name,
                  required arguments,
                  content,
                  metadata,
                }) => groupChatService.upsertToolEvent(
                  messageId,
                  id: id,
                  name: name,
                  arguments: arguments,
                  content: content,
                  metadata: metadata,
                ),
          );
        }

        if (state.hadThinkingBlock && content.isNotEmpty) {
          state.contentSplitOffsets.add(state.fullContentRaw.length);
          state.reasoningCountAtSplit.add(
            streamController.getReasoningSegmentCount(messageId),
          );
          state.toolCountAtSplit.add(
            streamController.getToolPartsCount(messageId),
          );
          state.hadThinkingBlock = false;
        }
        state.fullContentRaw += content;
        state.streamStartedAt ??= DateTime.now();
        if (chunk.usage != null) {
          state.usage = (state.usage ?? const TokenUsage()).merge(chunk.usage!);
          state.totalTokens = state.usage!.totalTokens;
        } else if (chunk.totalTokens > 0) {
          state.totalTokens = chunk.totalTokens;
        }
        final transformed = _transform(state.fullContentRaw, assistant);
        current = current.copyWith(
          content: transformed,
          totalTokens: state.totalTokens,
          promptTokens: state.usage?.promptTokens,
          completionTokens: state.usage?.completionTokens,
          cachedTokens: state.usage?.cachedTokens,
          durationMs: DateTime.now().difference(startedAt).inMilliseconds,
        );
        await groupChatService.updateMessage(current, notify: false);
        streamController.scheduleThrottledUpdate(
          messageId,
          groupId,
          transformed,
          totalTokens: state.totalTokens,
          contentSplitOffsets: state.contentSplitOffsets,
          reasoningCountAtSplit: state.reasoningCountAtSplit,
          toolCountAtSplit: state.toolCountAtSplit,
          promptTokens: state.usage?.promptTokens,
          completionTokens: state.usage?.completionTokens,
          cachedTokens: state.usage?.cachedTokens,
          durationMs: current.durationMs,
          updateMessageInList: (_, __, ___) {},
        );
        if (content.isNotEmpty) {
          await _finishReasoning(messageId, () => current, (updated) {
            current = updated;
          });
        }
      }

      final sanitized = await MarkdownMediaSanitizer.replaceInlineBase64Images(
        _transform(state.fullContentRaw, assistant),
      );
      if (state.bufferedReasoning.isNotEmpty) {
        final finishedAt = DateTime.now();
        current = current.copyWith(
          reasoningText: state.bufferedReasoning,
          reasoningStartAt: state.reasoningStartAt ?? finishedAt,
          reasoningFinishedAt: finishedAt,
        );
      }
      current = current.copyWith(
        content: sanitized,
        isStreaming: false,
        totalTokens: state.totalTokens,
        promptTokens: state.usage?.promptTokens,
        completionTokens: state.usage?.completionTokens,
        cachedTokens: state.usage?.cachedTokens,
        durationMs: DateTime.now().difference(startedAt).inMilliseconds,
      );
      await _finishReasoning(messageId, () => current, (updated) {
        current = updated;
      });
      await groupChatService.updateMessage(current);
      return current;
    } catch (error, stackTrace) {
      debugPrint(
        '[GroupMemberStreamService] stream failed: $error\n$stackTrace',
      );
      current = current.copyWith(
        isStreaming: false,
        durationMs: DateTime.now().difference(startedAt).inMilliseconds,
      );
      await groupChatService.updateMessage(current);
      rethrow;
    } finally {
      streamController.markStreamingEnded(messageId);
      streamController.cleanupTimers(messageId);
      streamController.removeStreamingNotifier(messageId);
    }
  }

  Future<void> _finishReasoning(
    String messageId,
    GroupChatMessage Function() getCurrent,
    ValueChanged<GroupChatMessage> updateCurrent,
  ) {
    return streamController.finishReasoningAndPersist(
      messageId,
      updateReasoningInDb:
          (
            _, {
            reasoningText,
            reasoningFinishedAt,
            reasoningSegmentsJson,
          }) async {
            final updated = _mergeReasoningUpdate(
              getCurrent(),
              reasoningText: reasoningText,
              reasoningFinishedAt: reasoningFinishedAt,
              reasoningSegmentsJson: reasoningSegmentsJson,
            );
            updateCurrent(updated);
            await groupChatService.updateMessage(updated, notify: false);
          },
    );
  }

  GroupChatMessage _mergeReasoningUpdate(
    GroupChatMessage message, {
    String? reasoningText,
    DateTime? reasoningStartAt,
    DateTime? reasoningFinishedAt,
    String? reasoningSegmentsJson,
  }) {
    var updated = message;
    if (reasoningText != null) {
      updated = updated.copyWith(reasoningText: reasoningText);
    }
    if (reasoningStartAt != null) {
      updated = updated.copyWith(reasoningStartAt: reasoningStartAt);
    }
    if (reasoningFinishedAt != null) {
      updated = updated.copyWith(reasoningFinishedAt: reasoningFinishedAt);
    }
    if (reasoningSegmentsJson != null) {
      updated = updated.copyWith(reasoningSegmentsJson: reasoningSegmentsJson);
    }
    return updated;
  }

  String _transform(String content, Assistant assistant) {
    return applyAssistantRegexes(
      content,
      assistant: assistant,
      scope: AssistantRegexScope.assistant,
      target: AssistantRegexTransformTarget.persist,
    );
  }

  @override
  void dispose() {
    streamController.dispose();
    super.dispose();
  }
}

class _GroupStreamCancelled implements Exception {
  const _GroupStreamCancelled();
}
