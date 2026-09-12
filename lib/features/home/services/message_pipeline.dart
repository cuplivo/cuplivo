import 'dart:async';
import 'package:flutter/foundation.dart';
import '../../../core/models/assistant.dart';
import '../../../core/models/chat_input_data.dart';
import '../../../core/models/chat_message.dart';
import '../../../core/models/conversation.dart';
import '../../../core/providers/settings_provider.dart';
import '../../../core/services/chat/chat_service.dart';
import '../controllers/generation_controller.dart';
import '../controllers/stream_controller.dart' as stream_ctrl;
import 'ask_user_interaction_service.dart';
import 'message_generation_service.dart';
import 'tool_approval_service.dart';

/// Stable context for one invocation of [MessagePipeline.executeAssistantResponse].
/// Bundles parameters that stay constant across multiple model executions
/// within the same round (e.g. multi-AI N threads).
// ignore_for_file: prefer_initializing_formals

class ModelExecutionContext {
  const ModelExecutionContext({
    required this.conversation,
    required this.settings,
    this.assistant,
    this.approvalService,
    this.askUserService,
    required this.versionSelections,
    this.includeUserQuickInstructions = true,
  });

  /// Pre-resolved conversation used for message preparation. Callers must
  /// apply any context clamp (e.g. `conversationForMessageContext`) before
  /// passing it; the pipeline does not re-resolve it.
  final Conversation conversation;
  final SettingsProvider settings;
  final Assistant? assistant;
  final ToolApprovalService? approvalService;
  final AskUserInteractionService? askUserService;
  final Map<String, int> versionSelections;
  final bool includeUserQuickInstructions;

  String? get assistantId => assistant?.id;
}

/// Shared pipeline for preparing and executing one model's response.
///
/// Encapsulates the common "initialize reasoning → prepare API messages →
/// build context → execute stream → handle preparation errors" sequence used
/// by single-chat send / regenerate / continue, and by Multi-AI start rounds
/// and retries. Group chat constructs its own instance in
/// `GroupChatOrchestrator` and runs the same sequence.
///
/// Caller is responsible for:
///   - Creating the placeholder via [MessageGenerationService.createAssistantPlaceholder]
///   - Managing the message list (append/insert)
///   - Marking streaming started via [StreamController.markStreamingStarted]
///   - Resetting tool parts via [StreamController.toolParts.remove]
///
/// [onStreamComplete] fires when the stream finishes (success or error),
/// or immediately if preparation fails.
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
  /// Returns a future that completes after reasoning initialization and
  /// API message preparation. The stream execution is fire-and-forget;
  /// [onStreamComplete] fires when the stream ends (success or error).
  ///
  /// If preparation fails before the stream starts, [onStreamComplete] fires
  /// immediately and the placeholder is cleaned up.
  ///
  /// [requestMetadataAnchorMessageId] overrides the per-message request
  /// metadata replay anchor for callers whose [completeMessages] extends past
  /// the generated turn (e.g. Multi-AI retries append the placeholder at the
  /// tail): the replay scans up to and including that user message. Supplying
  /// the anchor always implies inclusive scanning; there is no exclusive mode
  /// for an explicit anchor.
  Future<void> executeAssistantResponse({
    required ChatMessage assistantMessage,
    required String providerKey,
    required String modelId,
    required ModelExecutionContext context,
    required List<ChatMessage> completeMessages,
    ChatInputData? inputData,
    String? requestMetadataAnchorMessageId,
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
            includeUserQuickInstructions: context.includeUserQuickInstructions,
          );

      final userMediaPaths = _messageGenerationService.buildUserMediaPaths(
        input: inputData,
        lastUserMediaPaths: prepared.lastUserImagePaths,
        settings: settings,
        providerKey: providerKey,
        modelId: modelId,
        assistant: assistant,
      );

      // When there is no live composer input (group second turns, resend,
      // regenerate or Multi-AI retries), the per-message request metadata
      // persisted at send time (AD-0033) is the source of truth: replay it
      // from the history of the turn that produced this assistant message.
      // The anchor bound keeps a newer turn's metadata from leaking in when
      // [completeMessages] extends past [assistantMessage]. Callers whose
      // prepared list ends past the turn (Multi-AI retries append the
      // placeholder at the tail) pass the turn's user message explicitly.
      final (
        allowImagesApiRouting: resolvedRouting,
        requestExtraBody: resolvedExtraBody,
      ) = inputData == null
          ? MessageGenerationService.resolveRequestOptionsFromMessages(
              completeMessages,
              fallbackAllowImagesApiRouting: allowImagesApiRouting,
              anchorMessageId:
                  requestMetadataAnchorMessageId ?? assistantMessage.id,
              anchorInclusive: requestMetadataAnchorMessageId != null,
            )
          : (
              allowImagesApiRouting: allowImagesApiRouting,
              requestExtraBody: inputData.extraBody,
            );

      final ctx = _messageGenerationService.buildGenerationContext(
        assistantMessage: assistantMessage,
        prepared: prepared,
        userMediaPaths: userMediaPaths,
        allowImagesApiRouting: resolvedRouting,
        providerKey: providerKey,
        modelId: modelId,
        assistant: assistant,
        settings: settings,
        supportsReasoning: supportsReasoning,
        enableReasoning: enableReasoning,
        generateTitleOnFinish: generateTitleOnFinish,
        requestExtraBody: resolvedExtraBody,
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
