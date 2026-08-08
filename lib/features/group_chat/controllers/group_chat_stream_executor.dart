// SOURCE PARITY: lib/features/home/controllers/chat_actions.dart
// Stream path for group-chat member assistants (tools + content).

import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../../core/models/token_usage.dart';
import '../../../core/providers/settings_provider.dart';
import '../../../core/services/api/chat_api_service.dart';
import '../../../core/services/chat/chat_service.dart';
import '../../home/controllers/stream_controller.dart' as stream_ctrl;

/// Stream source signature used by [GroupChatStreamExecutor].
typedef ChatStreamSender =
    Stream<ChatStreamChunk> Function({
      required ProviderConfig config,
      required String modelId,
      required List<Map<String, dynamic>> messages,
      List<String>? userMediaPaths,
      int? thinkingBudget,
      double? temperature,
      double? topP,
      int? maxTokens,
      List<Map<String, dynamic>>? tools,
      ToolCallHandler? onToolCall,
      Map<String, String>? extraHeaders,
      Map<String, dynamic>? extraBody,
      bool stream,
      String? requestId,
      bool allowImagesApiRouting,
      bool ocrActive,
    });

/// Stream executor for group chat member assistants.
class GroupChatStreamExecutor {
  GroupChatStreamExecutor({
    required this.chatService,
    required this.streamController,
    ChatStreamSender? sendMessageStream,
  }) : _sendMessageStream =
           sendMessageStream ?? ChatApiService.sendMessageStream;

  final ChatService chatService;
  final stream_ctrl.StreamController streamController;
  final ChatStreamSender _sendMessageStream;

  final Map<String, StreamSubscription<ChatStreamChunk>> _streams = {};
  final Map<String, _ActiveStream> _activeStreams = {};

  Future<void> executeStream(
    stream_ctrl.GenerationContext ctx, {
    String? streamKeyOverride,
    String? requestIdOverride,
  }) async {
    final state = stream_ctrl.StreamingState(ctx);
    final assistant = ctx.assistant;
    final streamKey = streamKeyOverride ?? state.conversationId;
    final requestId = requestIdOverride ?? state.conversationId;

    streamController.markStreamingStarted(state.messageId);

    final done = _activeStreams[streamKey] ??= _ActiveStream(
      messageId: state.messageId,
    );

    try {
      final stream = _sendMessageStream(
        config: ctx.config,
        modelId: ctx.modelId,
        messages: ctx.apiMessages,
        userMediaPaths: ctx.userMediaPaths,
        thinkingBudget:
            assistant?.thinkingBudget ?? ctx.settings.thinkingBudget,
        temperature: assistant?.temperature,
        topP: assistant?.topP,
        maxTokens: assistant?.maxTokens,
        tools: ctx.toolDefs.isEmpty ? null : ctx.toolDefs,
        onToolCall: ctx.onToolCall,
        extraHeaders: ctx.extraHeaders,
        extraBody: ctx.extraBody,
        stream: ctx.streamOutput,
        requestId: requestId,
        allowImagesApiRouting: ctx.allowImagesApiRouting,
        ocrActive: ctx.ocrActive,
      );

      await _streams[streamKey]?.cancel();
      // Process chunks sequentially (await handler before next event).
      final pending = <Future<void>>[];
      final sub = stream.listen(
        (chunk) {
          final prev = pending.isEmpty ? Future<void>.value() : pending.last;
          pending.add(prev.then((_) => _handleChunk(chunk, state)));
        },
        onError: (Object e, StackTrace st) {
          final prev = pending.isEmpty ? Future<void>.value() : pending.last;
          pending.add(
            prev
                .then((_) async {
                  await _handleError(e, state);
                  _complete(done);
                })
                .catchError((Object chainError, StackTrace chainStack) {
                  debugPrint(
                    '[GroupChatStreamExecutor] stream error chain: $chainError\n$chainStack',
                  );
                  _complete(done);
                }),
          );
        },
        onDone: () {
          final prev = pending.isEmpty ? Future<void>.value() : pending.last;
          pending.add(
            prev
                .then((_) async {
                  await _handleDone(state);
                  _complete(done);
                })
                .catchError((Object chainError, StackTrace chainStack) {
                  debugPrint(
                    '[GroupChatStreamExecutor] stream done chain: $chainError\n$chainStack',
                  );
                  _complete(done);
                }),
          );
        },
        cancelOnError: false,
      );
      _streams[streamKey] = sub;

      // Returned future must complete only when the stream really ended
      // (final content already persisted), so callers reading the message
      // right after this future see the finished row, not the placeholder.
      await done.completer.future;
    } catch (e, st) {
      debugPrint('[GroupChatStreamExecutor] start error: $e\n$st');
      await _handleError(e, state);
    } finally {
      _activeStreams.remove(streamKey);
      _complete(done);
    }
  }

  static void _complete(_ActiveStream active) {
    if (!active.completer.isCompleted) active.completer.complete();
  }

  Future<void> cancel(String streamKey) async {
    await _streams[streamKey]?.cancel();
    _streams.remove(streamKey);
    final active = _activeStreams.remove(streamKey);
    if (active != null) {
      // Mirror normal chat cancelStreaming: keep partial content, mark done.
      await _finishReasoningState(active.messageId);
      await chatService.updateMessage(active.messageId, isStreaming: false);
      _complete(active);
    }
    ChatApiService.cancelRequest(streamKey);
  }

  Future<void> _handleChunk(
    ChatStreamChunk chunk,
    stream_ctrl.StreamingState state,
  ) async {
    final messageId = state.messageId;
    var chunkContent = chunk.content;
    if (chunkContent.isNotEmpty) {
      chunkContent = streamController.captureGeminiThoughtSignature(
        chunkContent,
        messageId,
      );
    }

    if (chunk.reasoningDetails != null) {
      streamController.setReasoningDetails(messageId, chunk.reasoningDetails);
    }

    if ((chunk.reasoning ?? '').isNotEmpty && state.ctx.supportsReasoning) {
      await streamController.handleReasoningChunk(
        chunk,
        state,
        updateReasoningInDb:
            (
              String mid, {
              String? reasoningText,
              DateTime? reasoningStartAt,
              String? reasoningSegmentsJson,
            }) async {
              await chatService.updateMessageSilent(
                mid,
                reasoningText: reasoningText,
                reasoningStartAt: reasoningStartAt,
                reasoningSegmentsJson: reasoningSegmentsJson,
              );
            },
      );
    }

    if ((chunk.toolCalls ?? const []).isNotEmpty) {
      await streamController.handleToolCallsChunk(
        chunk,
        state,
        updateReasoningSegmentsInDb: (String mid, String json) async {
          await chatService.updateMessageSilent(
            mid,
            reasoningSegmentsJson: json,
          );
        },
        setToolEventsInDb:
            (String mid, List<Map<String, dynamic>> events) async {
              await chatService.setToolEvents(mid, events);
            },
        getToolEventsFromDb: (String mid) => chatService.getToolEvents(mid),
      );
    }

    if ((chunk.toolResults ?? const []).isNotEmpty) {
      await streamController.handleToolResultsChunk(
        chunk,
        state,
        upsertToolEventInDb:
            (
              String mid, {
              required String id,
              required String name,
              required Map<String, dynamic> arguments,
              String? content,
              Map<String, dynamic>? metadata,
            }) async {
              await chatService.upsertToolEvent(
                mid,
                id: id,
                name: name,
                arguments: arguments,
                content: content,
                metadata: metadata,
              );
            },
      );
    }

    if (chunkContent.isNotEmpty && !state.finishHandled) {
      // Record the thinking→body split for interleaved display, mirroring
      // chat_actions._handleContentChunk. Without it the reasoning card
      // renders below the body.
      if (state.hadThinkingBlock) {
        state.contentSplitOffsets.add(state.fullContentRaw.length);
        state.reasoningCountAtSplit.add(
          streamController.getReasoningSegmentCount(messageId),
        );
        state.toolCountAtSplit.add(
          streamController.getToolPartsCount(messageId),
        );
        state.hadThinkingBlock = false;
        streamController.setContentSplitData(
          messageId,
          stream_ctrl.ContentSplitData(
            offsets: List<int>.of(state.contentSplitOffsets),
            reasoningCounts: List<int>.of(state.reasoningCountAtSplit),
            toolCounts: List<int>.of(state.toolCountAtSplit),
          ),
        );
      }

      // The thinking phase ends when the body starts: stop the elapsed
      // timer and persist reasoningFinishedAt (mirror chat_actions).
      await streamController.finishReasoningAndPersist(
        messageId,
        updateReasoningInDb:
            (
              String mid, {
              String? reasoningText,
              DateTime? reasoningStartAt,
              DateTime? reasoningFinishedAt,
              String? reasoningSegmentsJson,
            }) async {
              await chatService.updateMessageSilent(
                mid,
                reasoningText: reasoningText,
                reasoningStartAt: reasoningStartAt,
                reasoningFinishedAt: reasoningFinishedAt,
                reasoningSegmentsJson: reasoningSegmentsJson,
              );
            },
      );

      state.fullContentRaw += chunkContent;
      state.streamStartedAt ??= DateTime.now();
      if (chunk.totalTokens > 0) {
        state.totalTokens = chunk.totalTokens;
      }
      if (chunk.usage != null) {
        state.usage = (state.usage ?? const TokenUsage()).merge(chunk.usage!);
        state.totalTokens = state.usage!.totalTokens;
      }
      await chatService.updateMessageSilent(
        messageId,
        content: state.fullContentRaw,
        totalTokens: state.totalTokens,
      );
      // Lightweight UI tick for ValueListenableBuilder consumers.
      streamController.streamingContentNotifier.updateContent(
        messageId,
        state.fullContentRaw,
        state.totalTokens,
      );
    }

    if (chunk.isDone) {
      await _finish(chunk, state);
    }
  }

  /// Set reasoningFinishedAt (in-memory + DB) so the elapsed time shows the
  /// real thinking duration instead of 0.0s. Idempotent.
  Future<void> _finishReasoningState(String messageId) async {
    await streamController.finishReasoningAndPersist(
      messageId,
      updateReasoningInDb:
          (
            String mid, {
            String? reasoningText,
            DateTime? reasoningStartAt,
            DateTime? reasoningFinishedAt,
            String? reasoningSegmentsJson,
          }) async {
            await chatService.updateMessageSilent(
              mid,
              reasoningText: reasoningText,
              reasoningStartAt: reasoningStartAt,
              reasoningFinishedAt: reasoningFinishedAt,
              reasoningSegmentsJson: reasoningSegmentsJson,
            );
          },
    );
  }

  Future<void> _finish(
    ChatStreamChunk chunk,
    stream_ctrl.StreamingState state,
  ) async {
    if (state.finishHandled) return;
    state.finishHandled = true;
    if (chunk.usage != null) {
      state.usage = (state.usage ?? const TokenUsage()).merge(chunk.usage!);
      state.totalTokens = state.usage!.totalTokens;
    }
    await _finishReasoningState(state.messageId);
    await chatService.updateMessage(
      state.messageId,
      content: state.fullContentRaw,
      isStreaming: false,
      totalTokens: state.totalTokens,
      promptTokens: state.usage?.promptTokens,
      completionTokens: state.usage?.completionTokens,
    );
    streamController.markStreamingEnded(state.messageId);
    streamController.cleanupTimers(state.messageId);
  }

  Future<void> _handleError(
    Object error,
    stream_ctrl.StreamingState state,
  ) async {
    debugPrint('[GroupChatStreamExecutor] stream error: $error');
    if (!state.finishHandled) {
      state.finishHandled = true;
      await _finishReasoningState(state.messageId);
      final existing = state.fullContentRaw;
      // Mirror chat_actions.dart: raw error text, no prefix.
      await chatService.updateMessage(
        state.messageId,
        isStreaming: false,
        content: existing.isNotEmpty ? existing : error.toString(),
      );
    }
    streamController.markStreamingEnded(state.messageId);
    streamController.cleanupTimers(state.messageId);
  }

  Future<void> _handleDone(stream_ctrl.StreamingState state) async {
    if (state.finishHandled) return;
    state.finishHandled = true;
    await _finishReasoningState(state.messageId);
    await chatService.updateMessage(
      state.messageId,
      content: state.fullContentRaw,
      isStreaming: false,
      totalTokens: state.totalTokens,
    );
    streamController.markStreamingEnded(state.messageId);
    streamController.cleanupTimers(state.messageId);
  }

  void dispose() {
    for (final s in _streams.values) {
      unawaited(s.cancel());
    }
    _streams.clear();
    for (final active in _activeStreams.values) {
      _complete(active);
    }
    _activeStreams.clear();
  }
}

/// Tracks one in-flight stream: the message row it writes to plus the
/// completion signal that fires only after the stream has fully ended
/// (or was cancelled).
class _ActiveStream {
  _ActiveStream({required this.messageId});
  final String messageId;
  final Completer<void> completer = Completer<void>();
}
