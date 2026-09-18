// ignore_for_file: prefer_initializing_formals
import 'dart:async';

import 'package:flutter/foundation.dart';

import 'package:Cuplivo/core/models/assistant.dart';
import 'package:Cuplivo/core/models/chat_input_data.dart';
import 'package:Cuplivo/core/models/chat_message.dart';
import 'package:Cuplivo/core/models/conversation.dart';
import 'package:Cuplivo/core/providers/settings_provider.dart';
import 'package:Cuplivo/core/services/chat/chat_service.dart';
import 'package:Cuplivo/features/home/controllers/generation_controller.dart';
import 'package:Cuplivo/features/home/controllers/stream_controller.dart'
    as stream_ctrl;
import 'package:Cuplivo/features/home/services/ask_user_interaction_service.dart';
import 'package:Cuplivo/features/home/services/message_generation_service.dart';
import 'package:Cuplivo/features/home/services/tool_approval_service.dart';

/// Pre-resolved execution context for one model run.
class ModelExecutionContext {
  const ModelExecutionContext({
    required this.conversation,
    required this.settings,
    this.assistant,
    this.approvalService,
    this.askUserService,
    required this.versionSelections,
  });

  /// Pre-resolved conversation used for message preparation. Callers must
  /// apply any context clamp before passing it; the pipeline does not
  /// re-resolve it.
  final Conversation conversation;
  final SettingsProvider settings;
  final Assistant? assistant;
  final ToolApprovalService? approvalService;
  final AskUserInteractionService? askUserService;
  final Map<String, int> versionSelections;

  String? get assistantId => assistant?.id;
}

/// Shared pipeline for preparing and executing one model's response.
///
/// Encapsulates the "initialize reasoning → prepare API messages → build
/// context → execute stream → handle preparation errors" sequence used by
/// Multi-AI start rounds and retries.
///
/// Caller is responsible for:
///   - Creating the placeholder via
///     [MessageGenerationService.createAssistantPlaceholder]
///   - Managing the message list (append/insert)
///   - Marking streaming started via
///     [stream_ctrl.StreamController.markStreamingStarted]
class MessagePipeline {
  MessagePipeline({
    required ChatService chatService,
    required MessageGenerationService messageGenerationService,
    required stream_ctrl.StreamController streamController,
    required GenerationController generationController,
    required Future<void> Function(
      stream_ctrl.GenerationContext ctx, {
      String? streamKeyOverride,
      String? requestIdOverride,
    })
    executeStream,
  }) : _chatService = chatService,
       _messageGenerationService = messageGenerationService,
       _streamController = streamController,
       _generationController = generationController,
       _executeStream = executeStream;

  final ChatService _chatService;
  final MessageGenerationService _messageGenerationService;
  final stream_ctrl.StreamController _streamController;
  final GenerationController _generationController;
  final Future<void> Function(
    stream_ctrl.GenerationContext ctx, {
    String? streamKeyOverride,
    String? requestIdOverride,
  })
  _executeStream;

  /// Prepare API context and execute the stream for one assistant response.
  ///
  /// Returns a future that completes after reasoning initialization and API
  /// message preparation. The stream execution is fire-and-forget;
  /// [onStreamComplete] fires when the stream ends (success or error).
  ///
  /// If preparation fails before the stream starts, [onStreamComplete] fires
  /// immediately and the placeholder is cleaned up.
  Future<void> executeAssistantResponse({
    required ChatMessage assistantMessage,
    required String providerKey,
    required String modelId,
    required ModelExecutionContext context,
    required List<ChatMessage> completeMessages,
    ChatInputData? inputData,
    bool allowImagesApiRouting = true,
    bool generateTitleOnFinish = false,
    void Function(Object error, StackTrace stackTrace)? onPreparationError,
    VoidCallback? onStreamComplete,
  }) async {
    final assistant = context.assistant;
    final settings = context.settings;

    // Initialize reasoning state
    final supportsReasoning = _generationController.isReasoningModel(
      providerKey,
      modelId,
    );
    final enableReasoning =
        supportsReasoning &&
        _generationController.isReasoningEnabled(
          assistant?.thinkingBudget ?? settings.thinkingBudget,
        );

    try {
      await _messageGenerationService.initializeReasoningState(
        messageId: assistantMessage.id,
        enableReasoning: enableReasoning,
      );

      final currentConversation = context.conversation;

      final prepared = await _messageGenerationService
          .prepareApiMessagesWithInjections(
            messages: completeMessages,
            versionSelections: context.versionSelections,
            currentConversation: currentConversation,
            settings: settings,
            assistant: assistant,
            assistantId: context.assistantId,
            providerKey: providerKey,
            modelId: modelId,
            approvalService: context.approvalService,
            askUserService: context.askUserService,
            processingMessageId: assistantMessage.id,
          );

      final userImagePaths = _messageGenerationService.buildUserImagePaths(
        input: inputData,
        lastUserImagePaths: prepared.lastUserImagePaths,
        settings: settings,
        providerKey: providerKey,
        modelId: modelId,
        assistant: assistant,
      );

      final ctx = _messageGenerationService.buildGenerationContext(
        assistantMessage: assistantMessage,
        prepared: prepared,
        userImagePaths: userImagePaths,
        allowImagesApiRouting: allowImagesApiRouting,
        imageOptionsBody: inputData?.imageOptionsBody ?? const {},
        providerKey: providerKey,
        modelId: modelId,
        assistant: assistant,
        settings: settings,
        supportsReasoning: supportsReasoning,
        enableReasoning: enableReasoning,
        generateTitleOnFinish: generateTitleOnFinish,
      );

      unawaited(
        _executeStream(
          ctx,
          streamKeyOverride: assistantMessage.id,
          requestIdOverride: assistantMessage.id,
        ).whenComplete(() => onStreamComplete?.call()).catchError((e) {
          debugPrint('[MessagePipeline][$modelId] stream error: $e');
        }),
      );
    } catch (e, st) {
      // Preparation error — clean up the placeholder
      _streamController.markStreamingEnded(assistantMessage.id);
      await _chatService.updateMessage(assistantMessage.id, isStreaming: false);
      onPreparationError?.call(e, st);
      onStreamComplete?.call();
      debugPrint('[MessagePipeline][$modelId] preparation error: $e');
    }
  }
}
