import 'dart:async';
import 'package:flutter/widgets.dart';
import 'package:provider/provider.dart';
import '../../../core/models/assistant.dart';
import '../../../core/models/chat_input_data.dart';
import '../../../core/models/chat_message.dart';
import '../../../core/models/conversation.dart';
import '../../../core/providers/assistant_provider.dart';
import '../../../core/providers/settings_provider.dart';
import '../../../core/services/chat/chat_service.dart';
import '../../../core/services/api/retry_policy.dart';
import '../../../core/services/generation_engine.dart';
import '../../../core/services/ios_background_generation.dart';
import '../../../core/services/ios_keep_alive.dart';
import '../../../core/services/logging/flutter_logger.dart';
import '../../../l10n/app_localizations.dart';
import '../../../shared/widgets/snackbar.dart';
import '../services/ask_user_interaction_service.dart';
import '../services/message_generation_service.dart';
import '../services/message_pipeline.dart';
import '../services/tool_approval_service.dart';
import 'chat_controller.dart';
import 'generation_controller.dart';
import 'home_view_model.dart';
import 'stream_controller.dart' as stream_ctrl;

/// Result of a send/regenerate action.
class ChatActionResult {
  final bool success;
  final String? errorMessage;
  final ChatMessage? assistantMessage;

  ChatActionResult({
    required this.success,
    this.errorMessage,
    this.assistantMessage,
  });

  factory ChatActionResult.success(ChatMessage assistantMessage) =>
      ChatActionResult(success: true, assistantMessage: assistantMessage);

  factory ChatActionResult.error(String message) =>
      ChatActionResult(success: false, errorMessage: message);

  factory ChatActionResult.noModel() =>
      ChatActionResult(success: false, errorMessage: 'no_model');
}

/// Actions class for chat operations (send, regenerate, cancel, streaming).
///
/// This class contains ONLY business logic, NO UI operations.
/// It operates on messages, calls services/streams, and returns results.
/// UI layer is responsible for handling snackbars, scrolling, animations, etc.
///
/// Key responsibilities:
/// - Send new messages
/// - Regenerate existing messages
/// - Cancel streaming
/// - Handle stream chunks (reasoning, tools, content)
/// - Manage streaming state
class ChatActions {
  ChatActions({
    required this.chatService,
    required this.chatController,
    required this.streamController,
    required this.generationController,
    required this.messageGenerationService,
    required this.contextProvider,
    required this.viewModel,
    required this.getTitleForLocale,
    this.hasActiveTranslation,
  }) {
    _pipeline = MessagePipeline(
      chatService: chatService,
      messageGenerationService: messageGenerationService,
      streamController: streamController,
      generationController: generationController,
      executeStream: executeStream,
    );
  }

  final HomeViewModel viewModel;
  final ChatService chatService;
  final ChatController chatController;
  final stream_ctrl.StreamController streamController;
  final GenerationController generationController;
  final MessageGenerationService messageGenerationService;
  final BuildContext contextProvider;
  final String Function(BuildContext context) getTitleForLocale;
  final bool Function(String messageId)? hasActiveTranslation;

  late final MessagePipeline _pipeline;

  /// Shared prepare-execute pipeline for single-chat send/regenerate/continue
  /// and Multi-AI threads. It owns reasoning initialization, API-message
  /// preparation, per-message request-metadata replay (ADR-0033), and stream
  /// dispatch. Group chat keeps its own instance in `GroupChatOrchestrator`.
  ///
  /// Owned by [ChatActions] and constructed in its constructor;
  /// [HomePageController] forwards this same instance into [MultiAIEngine].
  MessagePipeline get pipeline => _pipeline;

  // ============================================================================
  // Callbacks for UI updates (set by HomeViewModel)
  // ============================================================================

  /// Called when messages list is updated.
  VoidCallback? onMessagesChanged;

  /// Called when conversation loading state changes.
  void Function(String conversationId, bool loading)? onLoadingChanged;

  /// Called when stream content is updated (for throttled updates).
  void Function(String messageId, String content, int totalTokens)?
  onContentUpdated;

  /// Called when an error occurs during streaming.
  void Function(String error)? onStreamError;

  /// Called when stream finishes and title may need to be generated.
  void Function(String conversationId)? onMaybeGenerateTitle;

  /// Called when summary may need to be generated (every N messages).
  void Function(String conversationId)? onMaybeGenerateSummary;

  /// Called when chat suggestions may need to be generated.
  void Function(String conversationId)? onMaybeGenerateSuggestions;

  /// Called when streaming finishes.
  VoidCallback? onStreamFinished;

  /// Called when a successful assistant reply is finalized.
  void Function(ChatMessage message)? onAssistantMessageFinished;

  /// Called after an assistant reply to maybe update proactive care timing.
  void Function(String conversationId)? onMaybeUpdateProactiveCare;

  /// Reports completion of a registered Multi-AI response slot.
  void Function(String messageId, bool succeeded)? onMultiAISlotSettled;

  /// Called when file processing starts.
  VoidCallback? onFileProcessingStarted;

  /// Called when file processing finishes.
  VoidCallback? onFileProcessingFinished;

  // ============================================================================
  // Private Helpers
  // ============================================================================

  AppLocalizations? get _l10n => AppLocalizations.of(contextProvider);

  void _logIosBackgroundGenerationFailure(
    String operation,
    Object error,
    StackTrace stackTrace,
  ) {
    debugPrint('[IosBackgroundGeneration] $operation failed: $error');
    debugPrint('$stackTrace');
  }

  Future<void> _startIosBackgroundGeneration(
    stream_ctrl.GenerationContext ctx,
  ) async {
    final settings = ctx.settings;
    final l10n = _l10n;
    if (l10n == null) return;
    try {
      // Push keep-alive toggles and open a keep-alive session before the
      // native background task starts, so silent-audio / location legs can
      // arm as soon as the app backgrounds.
      await IosKeepAliveService.instance.configure(
        masterEnabled: settings.iosKeepAliveEnabled,
        silentAudioEnabled: settings.iosSilentAudioKeepAliveEnabled,
        locationEnabled: settings.iosLocationKeepAliveEnabled,
        liveActivityPrivacyMode: settings.iosLiveActivityPrivacyMode,
      );
      // Only open a keep-alive session when background generation is enabled;
      // otherwise there is no task running in the background to keep alive.
      if (settings.iosBackgroundGenerationEnabled) {
        await IosKeepAliveService.instance.beginSession();
      }
      final privacy = settings.iosLiveActivityPrivacyMode;
      await IosBackgroundGenerationService.instance.start(
        enabled: settings.iosBackgroundGenerationEnabled,
        liveActivityEnabled: settings.iosLiveActivityEnabled,
        notificationsEnabled: settings.iosBackgroundNotificationsEnabled,
        refreshEnabled: settings.iosBackgroundTaskRefreshEnabled,
        title: privacy
            ? l10n.iosBackgroundGenerationPrivacyActiveTitle
            : l10n.iosBackgroundGenerationActiveTitle,
        detail: privacy
            ? l10n.iosBackgroundGenerationPrivacyActiveDetail
            : l10n.iosBackgroundGenerationActiveDetail,
        tokenLabel: privacy ? '' : l10n.iosBackgroundGenerationTokenCount(0),
      );
    } catch (error, stackTrace) {
      _logIosBackgroundGenerationFailure('start', error, stackTrace);
    }
  }

  Future<void> _updateIosBackgroundGeneration(int totalTokens) async {
    final l10n = _l10n;
    if (l10n == null) return;
    try {
      final settings = contextProvider.read<SettingsProvider>();
      final privacy = settings.iosLiveActivityPrivacyMode;
      await IosBackgroundGenerationService.instance.update(
        detail: privacy
            ? l10n.iosBackgroundGenerationPrivacyActiveDetail
            : l10n.iosBackgroundGenerationStreamingDetail,
        tokenLabel: privacy
            ? ''
            : l10n.iosBackgroundGenerationTokenCount(totalTokens),
        tokenCount: totalTokens,
      );
    } catch (error, stackTrace) {
      _logIosBackgroundGenerationFailure('update', error, stackTrace);
    }
  }

  Future<void> _finishIosBackgroundGeneration({
    required bool success,
    String? detail,
  }) async {
    // End the keep-alive session BEFORE the l10n guard — if localization is
    // unavailable we must still release the native keep-alive, otherwise the
    // silent-audio / location legs keep running forever.
    await IosKeepAliveService.instance.endSession();
    final l10n = _l10n;
    if (l10n == null) return;
    try {
      await IosBackgroundGenerationService.instance.finish(
        title: success
            ? l10n.iosBackgroundGenerationCompleteTitle
            : l10n.iosBackgroundGenerationInterruptedTitle,
        detail:
            detail ??
            (success
                ? l10n.iosBackgroundGenerationCompleteDetail
                : l10n.iosBackgroundGenerationInterruptedDetail),
        success: success,
      );
    } catch (error, stackTrace) {
      _logIosBackgroundGenerationFailure('finish', error, stackTrace);
    }
  }

  Future<void> _cancelIosBackgroundGeneration() async {
    await IosKeepAliveService.instance.endSession();
    final l10n = _l10n;
    try {
      await IosBackgroundGenerationService.instance.cancel(
        detail: l10n?.iosBackgroundGenerationCancelledDetail,
      );
    } catch (error, stackTrace) {
      _logIosBackgroundGenerationFailure('cancel', error, stackTrace);
    }
  }

  List<ChatMessage> get _messages => chatController.messages;
  Map<String, int> get _versionSelections => chatController.versionSelections;

  /// Guard against re-entrant cancelStreaming calls and
  /// concurrent engine slot-error cleanup.
  bool _isCancelling = false;

  void _setConversationLoading(String conversationId, bool loading) {
    chatController.setConversationLoading(conversationId, loading);
    onLoadingChanged?.call(conversationId, loading);
  }

  /// Unified preparation-failure teardown for send / regenerate / continue:
  /// log, clear the page-level file-processing indicator (prepare fires
  /// `onFileProcessingStarted` without a matching finish when it throws), run
  /// the placeholder cleanup, and map a user cancel to a silent success.
  Future<ChatActionResult> _handlePreparationError(
    Object error,
    ChatMessage placeholder,
    String conversationId,
    String logTag,
  ) async {
    FlutterLogger.log('[$logTag] $error', tag: 'ChatActions');
    onFileProcessingFinished?.call();
    await _cleanupStreamingError(placeholder, conversationId);
    if (isUserCancelError(error)) {
      return ChatActionResult.success(placeholder);
    }
    return ChatActionResult.error(error.toString());
  }

  Conversation _conversationForMessageContext(
    Conversation conversation,
    List<ChatMessage> messages, {
    int? maxRawTruncateIndex,
  }) {
    final completeConversation = chatController
        .conversationForCompleteHistoryContext(conversation);
    return conversationForMessageContext(
      conversation: completeConversation,
      messages: messages,
      maxRawTruncateIndex: maxRawTruncateIndex,
    );
  }

  @visibleForTesting
  static Conversation conversationForMessageContext({
    required Conversation conversation,
    required List<ChatMessage> messages,
    int? maxRawTruncateIndex,
  }) {
    final rawTruncateIndex = conversation.truncateIndex;
    if (maxRawTruncateIndex != null && rawTruncateIndex > maxRawTruncateIndex) {
      return conversation.copyWith(truncateIndex: -1);
    }
    if (rawTruncateIndex < 0 || rawTruncateIndex <= messages.length) {
      return conversation;
    }
    return conversation.copyWith(truncateIndex: -1);
  }

  bool _supportsAudioAttachmentsForProvider(
    SettingsProvider settings, {
    required String providerKey,
    required String modelId,
  }) {
    return messageGenerationService.supportsAudioAttachmentsForProvider(
      settings,
      providerKey: providerKey,
      modelId: modelId,
    );
  }

  bool _hasUnsupportedAudioAttachments({
    required List<ChatMessage> messages,
    required Conversation conversation,
    required SettingsProvider settings,
    required String providerKey,
    required String modelId,
    ChatInputData? pendingInput,
    int? maxRawTruncateIndex,
  }) {
    if (_supportsAudioAttachmentsForProvider(
      settings,
      providerKey: providerKey,
      modelId: modelId,
    )) {
      return false;
    }

    if (pendingInput != null &&
        messageGenerationService.inputContainsAudioAttachments(pendingInput)) {
      return true;
    }

    // buildApiMessages output carries internal `_`-prefixed keys
    // (_isPresetKey, _timestampKey). Safe to use here because
    // apiMessagesContainAudioAttachments only inspects 'content' and never
    // forwards the list to a provider. If this consumer is ever changed to
    // forward messages to a provider, route through
    // processUserMessagesForApi first. See the contract on
    // MessageBuilderService.buildApiMessages.
    final apiMessages = messageGenerationService.messageBuilderService
        .buildApiMessages(
          messages: messages,
          versionSelections: _versionSelections,
          currentConversation: _conversationForMessageContext(
            conversation,
            messages,
            maxRawTruncateIndex: maxRawTruncateIndex,
          ),
        );
    return messageGenerationService.apiMessagesContainAudioAttachments(
      apiMessages,
    );
  }

  @visibleForTesting
  static List<ChatMessage> projectMessagesForRegenerationContext({
    required List<ChatMessage> messages,
    required int lastKeep,
    required String? targetGroupId,
  }) {
    if (lastKeep >= messages.length - 1) {
      return List<ChatMessage>.of(messages);
    }

    final keepGroups = <String>{};
    for (int i = 0; i <= lastKeep && i < messages.length; i++) {
      keepGroups.add(messages[i].groupId ?? messages[i].id);
    }
    if (targetGroupId != null) keepGroups.add(targetGroupId);

    final projected = <ChatMessage>[];
    for (int i = 0; i < messages.length; i++) {
      if (i <= lastKeep) {
        projected.add(messages[i]);
        continue;
      }
      final gid = messages[i].groupId ?? messages[i].id;
      if (keepGroups.contains(gid)) {
        projected.add(messages[i]);
      }
    }
    return projected;
  }

  @visibleForTesting
  static List<ChatMessage> buildRegenerationMessages({
    required List<ChatMessage> messages,
    required int lastKeep,
    required String? targetGroupId,
    required ChatMessage assistantPlaceholder,
  }) {
    return <ChatMessage>[
      ...projectMessagesForRegenerationContext(
        messages: messages,
        lastKeep: lastKeep,
        targetGroupId: targetGroupId,
      ),
      assistantPlaceholder,
    ];
  }

  // ============================================================================
  // Send Message
  // ============================================================================

  /// Send a new message and start generating assistant response.
  ///
  /// Returns [ChatActionResult] with success status and the assistant message.
  /// UI is responsible for:
  /// - Adding messages to the list (user + assistant)
  /// - Showing snackbars on errors
  /// - Scrolling to bottom
  /// - Haptic feedback
  Future<ChatActionResult> sendMessage({
    required ChatInputData input,
    required Conversation conversation,
  }) async {
    final content = input.text.trim();
    if (content.isEmpty &&
        input.imagePaths.isEmpty &&
        input.documents.isEmpty &&
        input.quickInstructions.isEmpty) {
      return ChatActionResult.error('empty_input');
    }

    final settings = contextProvider.read<SettingsProvider>();
    // Capture approval service reference before async gap
    ToolApprovalService? approvalService;
    AskUserInteractionService? askUserService;
    try {
      approvalService = contextProvider.read<ToolApprovalService>();
    } catch (_) {}
    try {
      askUserService = contextProvider.read<AskUserInteractionService>();
    } catch (_) {}
    final assistant = await contextProvider
        .read<AssistantProvider>()
        .getLoadedCurrentAssistant();
    final modelConfig = messageGenerationService.getModelConfig(
      settings,
      assistant,
      conversation: conversation,
      conversationModelIndependent: settings.conversationModelIndependent,
    );

    if (modelConfig.providerKey == null || modelConfig.modelId == null) {
      return ChatActionResult.noModel();
    }
    final providerKey = modelConfig.providerKey!;
    final modelId = modelConfig.modelId!;

    if (chatController.hasMoreAfter) {
      final loaded = chatController.loadEndWindow();
      if (loaded) {
        viewModel.restoreMessageUiState();
      }
    }

    final existingContextMessages = chatController
        .messagesForCompleteHistoryContext(conversation);
    if (_hasUnsupportedAudioAttachments(
      messages: existingContextMessages,
      conversation: conversation,
      settings: settings,
      providerKey: providerKey,
      modelId: modelId,
      pendingInput: input,
      maxRawTruncateIndex: null,
    )) {
      return ChatActionResult.error('audio_attachment_unsupported');
    }

    // Create user message
    final userMessage = await messageGenerationService.createUserMessage(
      conversationId: conversation.id,
      input: input,
      assistant: assistant,
    );
    if (chatController.appendPersistedTailMessage(userMessage)) {
      viewModel.restoreMessageUiState();
    }
    onMessagesChanged?.call();

    _setConversationLoading(conversation.id, true);

    // Create assistant message placeholder
    final assistantMessage = await messageGenerationService
        .createAssistantPlaceholder(
          conversationId: conversation.id,
          modelId: modelId,
          providerKey: providerKey,
        );

    // Pre-create streaming notifier BEFORE adding message to list
    // so that MessageListView can detect it's streaming on first render
    streamController.markStreamingStarted(assistantMessage.id);

    if (chatController.appendPersistedTailMessage(assistantMessage)) {
      viewModel.restoreMessageUiState();
    }
    onMessagesChanged?.call();

    // Reset tool parts before the shared pipeline prepares the turn.
    streamController.toolParts.remove(assistantMessage.id);

    // File-processing indicators are page-level: keep them wired before the
    // pipeline runs prepareApiMessagesWithInjections.
    messageGenerationService.onFileProcessingStarted = onFileProcessingStarted;
    messageGenerationService.onFileProcessingFinished =
        onFileProcessingFinished;

    final apiContextMessages = chatController.messagesForCompleteHistoryContext(
      conversation,
    );
    final messageContextConversation = _conversationForMessageContext(
      conversation,
      apiContextMessages,
    );
    Object? prepareError;
    await _pipeline.executeAssistantResponse(
      assistantMessage: assistantMessage,
      providerKey: providerKey,
      modelId: modelId,
      context: ModelExecutionContext(
        conversation: messageContextConversation,
        settings: settings,
        assistant: assistant,
        approvalService: approvalService,
        askUserService: askUserService,
        versionSelections: _versionSelections,
      ),
      completeMessages: apiContextMessages,
      inputData: input,
      allowImagesApiRouting: input.allowImagesApiRouting,
      generateTitleOnFinish: true,
      onPreparationError: (error, _) {
        prepareError = error;
      },
    );

    if (prepareError != null) {
      return _handlePreparationError(
        prepareError!,
        assistantMessage,
        conversation.id,
        'SendMessage',
      );
    }
    return ChatActionResult.success(assistantMessage);
  }

  // ============================================================================
  // Regenerate Message
  // ============================================================================

  /// Regenerate response at a specific message.
  ///
  /// Returns [ChatActionResult] with success status and the new assistant message.
  /// UI is responsible for:
  /// - Adding new assistant placeholder
  /// - Showing snackbars on errors
  /// - Haptic feedback
  Future<ChatActionResult> regenerateAtMessage({
    required ChatMessage message,
    required Conversation conversation,
    bool assistantAsNewReply = false,
    bool allowImagesApiRouting = true,
  }) async {
    // Avoid using BuildContext across async gaps (this class holds a BuildContext).
    final settings = contextProvider.read<SettingsProvider>();
    // Capture approval service reference before async gap
    ToolApprovalService? regenApprovalService;
    AskUserInteractionService? regenAskUserService;
    try {
      regenApprovalService = contextProvider.read<ToolApprovalService>();
    } catch (_) {}
    try {
      regenAskUserService = contextProvider.read<AskUserInteractionService>();
    } catch (_) {}
    final shouldGenerateTitleOnRetry =
        conversation.title == getTitleForLocale(contextProvider);
    final assistant = await contextProvider
        .read<AssistantProvider>()
        .getLoadedCurrentAssistant();

    await cancelStreaming(conversation);

    final completeMessages = chatController.messagesForCompleteHistoryContext(
      conversation,
    );
    final idx = completeMessages.indexWhere((m) => m.id == message.id);
    if (idx < 0) {
      return ChatActionResult.error('message_not_found');
    }

    // Calculate versioning using service
    final versioning = messageGenerationService.calculateRegenerationVersioning(
      message: message,
      messages: completeMessages,
      assistantAsNewReply: assistantAsNewReply,
    );
    if (versioning.lastKeep < 0) {
      return ChatActionResult.error('invalid_versioning');
    }

    // Get model config
    final modelConfig = messageGenerationService.getModelConfig(
      settings,
      assistant,
      conversation: conversation,
      conversationModelIndependent: settings.conversationModelIndependent,
    );

    if (modelConfig.providerKey == null || modelConfig.modelId == null) {
      return ChatActionResult.noModel();
    }
    final providerKey = modelConfig.providerKey!;
    final modelId = modelConfig.modelId!;

    final projectedMessages = ChatActions.projectMessagesForRegenerationContext(
      messages: completeMessages,
      lastKeep: versioning.lastKeep,
      targetGroupId: versioning.targetGroupId,
    );
    if (_hasUnsupportedAudioAttachments(
      messages: projectedMessages,
      conversation: conversation,
      settings: settings,
      providerKey: providerKey,
      modelId: modelId,
      maxRawTruncateIndex: versioning.lastKeep,
    )) {
      return ChatActionResult.error('audio_attachment_unsupported');
    }

    if (settings.regenerateDeleteTrailingMessages) {
      final removeIds = await messageGenerationService.removeTrailingMessages(
        messages: completeMessages,
        lastKeep: versioning.lastKeep,
        targetGroupId: versioning.targetGroupId,
      );
      if (removeIds.isNotEmpty) {
        chatController.reloadMessages();
        viewModel.restoreMessageUiState();
        onMessagesChanged?.call();
      }
    }

    // Create assistant message placeholder (new version)
    final assistantMessage = await messageGenerationService
        .createAssistantPlaceholder(
          conversationId: conversation.id,
          modelId: modelId,
          providerKey: providerKey,
          groupId: versioning.targetGroupId,
          version: versioning.nextVersion,
        );

    // Pre-create streaming notifier BEFORE adding message to list
    // so that MessageListView can detect it's streaming on first render
    streamController.markStreamingStarted(assistantMessage.id);

    // Persist version selection
    final gid = assistantMessage.groupId ?? assistantMessage.id;
    _versionSelections[gid] = assistantMessage.version;
    await chatService.setSelectedVersion(
      conversation.id,
      gid,
      assistantMessage.version,
    );

    final regenerationMessages = ChatActions.buildRegenerationMessages(
      messages: completeMessages,
      lastKeep: versioning.lastKeep,
      targetGroupId: versioning.targetGroupId,
      assistantPlaceholder: assistantMessage,
    );

    if (chatController.appendPersistedTailMessage(assistantMessage)) {
      viewModel.restoreMessageUiState();
    }
    onMessagesChanged?.call();

    _setConversationLoading(conversation.id, true);

    final messageContextConversation = _conversationForMessageContext(
      conversation,
      regenerationMessages,
      maxRawTruncateIndex: versioning.lastKeep,
    );
    Object? prepareError;
    await _pipeline.executeAssistantResponse(
      assistantMessage: assistantMessage,
      providerKey: providerKey,
      modelId: modelId,
      context: ModelExecutionContext(
        conversation: messageContextConversation,
        settings: settings,
        assistant: assistant,
        approvalService: regenApprovalService,
        askUserService: regenAskUserService,
        versionSelections: _versionSelections,
      ),
      completeMessages: regenerationMessages,
      inputData: null,
      allowImagesApiRouting: allowImagesApiRouting,
      generateTitleOnFinish: shouldGenerateTitleOnRetry,
      onPreparationError: (error, _) {
        prepareError = error;
      },
    );

    if (prepareError != null) {
      return _handlePreparationError(
        prepareError!,
        assistantMessage,
        conversation.id,
        'regenerate',
      );
    }
    return ChatActionResult.success(assistantMessage);
  }

  Future<ChatActionResult> continueAssistantMessageAfterToolAnswer({
    required ChatMessage message,
    required Conversation conversation,
    bool allowImagesApiRouting = true,
  }) async {
    final settings = contextProvider.read<SettingsProvider>();
    ToolApprovalService? approvalService;
    AskUserInteractionService? askUserService;
    try {
      approvalService = contextProvider.read<ToolApprovalService>();
    } catch (_) {}
    try {
      askUserService = contextProvider.read<AskUserInteractionService>();
    } catch (_) {}
    final assistant = await contextProvider
        .read<AssistantProvider>()
        .getLoadedCurrentAssistant();

    final visibleIndex = _messages.indexWhere(
      (candidate) => candidate.id == message.id,
    );
    if (visibleIndex < 0 || message.role != 'assistant') {
      return ChatActionResult.error('message_not_found');
    }
    final completeMessages = chatController.messagesForCompleteHistoryContext(
      conversation,
    );
    final contextIndex = completeMessages.indexWhere(
      (candidate) => candidate.id == message.id,
    );
    if (contextIndex < 0) {
      return ChatActionResult.error('message_not_found');
    }

    final modelConfig = messageGenerationService.getModelConfig(
      settings,
      assistant,
      conversation: conversation,
      conversationModelIndependent: settings.conversationModelIndependent,
    );
    if (modelConfig.providerKey == null || modelConfig.modelId == null) {
      return ChatActionResult.noModel();
    }
    final providerKey = modelConfig.providerKey!;
    final modelId = modelConfig.modelId!;

    final streamingMessage = _messages[visibleIndex].copyWith(
      isStreaming: true,
    );
    _messages[visibleIndex] = streamingMessage;
    await chatService.updateMessage(streamingMessage.id, isStreaming: true);
    onMessagesChanged?.call();
    _setConversationLoading(conversation.id, true);

    final apiContextMessages = List<ChatMessage>.of(completeMessages);
    apiContextMessages[contextIndex] = apiContextMessages[contextIndex]
        .copyWith(content: '', isStreaming: true);

    final messageContextConversation = _conversationForMessageContext(
      conversation,
      apiContextMessages,
    );
    Object? prepareError;
    await _pipeline.executeAssistantResponse(
      assistantMessage: streamingMessage,
      providerKey: providerKey,
      modelId: modelId,
      context: ModelExecutionContext(
        conversation: messageContextConversation,
        settings: settings,
        assistant: assistant,
        approvalService: approvalService,
        askUserService: askUserService,
        versionSelections: _versionSelections,
      ),
      completeMessages: apiContextMessages,
      inputData: null,
      allowImagesApiRouting: allowImagesApiRouting,
      generateTitleOnFinish: false,
      onPreparationError: (error, _) {
        prepareError = error;
      },
    );

    if (prepareError != null) {
      return _handlePreparationError(
        prepareError!,
        streamingMessage,
        conversation.id,
        'ContinueAssistantMessageAfterToolAnswer',
      );
    }
    return ChatActionResult.success(streamingMessage);
  }

  // ============================================================================
  // Cancel Streaming
  // ============================================================================

  /// Cancel the active streaming for the current conversation.
  ///
  /// Delegates to the GenerationEngine: cancelling the conversation cancels
  /// every slot (normal chat + Multi-AI threads + cascading wait-mode
  /// sub-agents). Each slot's stream errors out, the engine persists the
  /// partial content with `isStreaming: false`, and the page's per-slot
  /// error handler (see [_onEngineSlotError]) finalizes the in-memory list.
  Future<void> cancelStreaming(Conversation? conversation) async {
    final cid = conversation?.id;
    if (cid == null || _isCancelling) {
      debugPrint(
        '[CancelTrace] cancelStreaming SKIPPED: cid=$cid _isCancelling=$_isCancelling',
      );
      return;
    }
    debugPrint('[CancelTrace] cancelStreaming ENTER: cid=$cid');
    _isCancelling = true;
    try {
      // Cancel any pending tool approval requests to prevent deadlock
      try {
        contextProvider.read<ToolApprovalService>().cancelAll();
      } catch (_) {
        // ToolApprovalService may not be registered yet
      }
      try {
        contextProvider.read<AskUserInteractionService>().cancelAll();
      } catch (_) {
        // AskUserInteractionService may not be registered yet
      }

      // Reset file processing state on cancel
      onFileProcessingFinished?.call();

      // Cascading cancellation: the conversation's slots (including
      // wait-mode sub-agents spawned by it) are cancelled; fire-and-forget
      // sub-agents keep running. No-op when nothing runs here.
      try {
        // ignore: use_build_context_synchronously (root context)
        contextProvider.read<GenerationEngine>().cancelConversation(cid);
      } catch (e) {
        debugPrint('[CancelTrace] engine cancel failed: $e');
      }

      chatController.forceClearConversationLoading(cid);
      onLoadingChanged?.call(cid, false);
      await _cancelIosBackgroundGeneration();
    } finally {
      debugPrint(
        '[CancelTrace] cancelStreaming EXIT: cid=$cid _isCancelling->false',
      );
      _isCancelling = false;
    }
  }

  // ============================================================================
  // Stream Execution
  // ============================================================================

  /// Public wrapper for [__executeGeneration] — used by MultiAIEngine.
  Future<void> executeStream(
    stream_ctrl.GenerationContext ctx, {
    String? streamKeyOverride,
    String? requestIdOverride,
  }) {
    return _executeGeneration(
      ctx,
      streamKeyOverride: streamKeyOverride,
      requestIdOverride: requestIdOverride,
    );
  }

  /// Execute generation with the given context via the GenerationEngine
  /// (ADR-0034: the page path streams into engine slots; the engine owns the
  /// chunk pipeline, persistence, reasoning segments, sanitization and the
  /// smooth live ramp).
  ///
  /// If [streamKeyOverride]/[requestIdOverride] are provided they are
  /// ignored — the engine keys slots by `assistantMessageId` (Multi-AI: N
  /// slots share one conversation round, each with its own CancelToken).
  Future<void> _executeGeneration(
    stream_ctrl.GenerationContext ctx, {
    String? streamKeyOverride,
    String? requestIdOverride,
  }) async {
    final assistant = ctx.assistant;
    final mid = ctx.assistantMessage.id;
    final cid = ctx.assistantMessage.conversationId;
    final settings = ctx.settings;

    // Mark this message as actively streaming + pre-create its notifier so
    // MessageListView's streaming gate detects it.
    streamController.markStreamingStarted(mid);

    try {
      await _startIosBackgroundGeneration(ctx);
      debugPrint(
        '[GenerationEngine] page slot start: msgId=$mid modelId=${ctx.modelId} providerKey=${ctx.providerKey}',
      );
      // ignore: use_build_context_synchronously (root context, valid for app lifetime)
      final engine = contextProvider.read<GenerationEngine>();
      final notifier = streamController.streamingContentNotifier;
      engine.startRound(
        conversationId: cid,
        slots: [
          GenerationSlotRequest(
            assistantMessageId: mid,
            apiMessages: ctx.apiMessages,
            config: ctx.config,
            modelId: ctx.modelId,
            toolDefs: ctx.toolDefs,
            onToolCall: ctx.onToolCall,
            assistant: assistant is Assistant ? assistant : null,
            thinkingBudget:
                assistant?.thinkingBudget ?? settings.thinkingBudget,
            temperature: assistant?.temperature,
            topP: assistant?.topP,
            maxTokens: assistant?.maxTokens,
            stream: ctx.streamOutput,
            userMediaPaths: ctx.userMediaPaths,
            allowImagesApiRouting: ctx.allowImagesApiRouting,
            ocrActive: ctx.ocrActive,
            extraHeaders: ctx.extraHeaders,
            extraBody: ctx.extraBody,
            supportsReasoning: ctx.supportsReasoning,
            autoCollapseThinking: settings.autoCollapseThinking,
            partialImageNotice: _l10n == null
                ? null
                : (received, requested) =>
                      _l10n!.imageGenPartialNotice('$received', '$requested'),
            onContentUpdated: (id, content, tokens) {
              onContentUpdated?.call(id, content, tokens);
              unawaited(_updateIosBackgroundGeneration(tokens));
            },
            onStreamTick: () => streamController.onStreamTick?.call(),
            onSlotComplete: () => _onEngineSlotComplete(ctx, mid, cid),
            onSlotError: (error) =>
                unawaited(_onEngineSlotError(ctx, mid, cid, error)),
            onUiState: (state) =>
                streamController.syncEngineUiState(mid, state),
          ),
        ],
      );
      // Register the page notifier for live rendering (the engine's ramp
      // publishes to it; safe to register after start — the ramp syncs on
      // attach and the accumulated state is seeded on demand).
      final slot = engine.slotForMessage(mid);
      if (slot != null) {
        slot.uiNotifier = notifier;
        final text = slot.streamedText.toString();
        if (text.isNotEmpty) {
          notifier.updateContent(mid, text, 0);
        }
      }
    } catch (e, st) {
      debugPrint('[MultiAIDebug] _executeGeneration CAUGHT: $e');
      debugPrint('[MultiAIDebug] _executeGeneration stack: $st');
      // The engine never touched the row on a synchronous start failure —
      // release the streaming flag so the placeholder is not stuck forever.
      try {
        await chatService.updateMessage(mid, isStreaming: false);
      } catch (persistError) {
        debugPrint(
          '[GenerationEngine] start-failure cleanup persist failed: '
          '$persistError',
        );
      }
      await _onEngineSlotError(ctx, mid, cid, e);
    }
  }

  /// Engine slot finished successfully: finalize the page-side state (list
  /// row, notifier teardown, loading flags, follow-up hooks).
  void _onEngineSlotComplete(
    stream_ctrl.GenerationContext ctx,
    String mid,
    String cid,
  ) {
    debugPrint('[GenerationEngine] page slot done: msgId=$mid');
    final engine = contextProvider.read<GenerationEngine>();
    final slot = engine.slotForMessage(mid);
    final content = slot?.finalText ?? '';
    final ui = slot?.finalUiState;
    final index = _messages.indexWhere((m) => m.id == mid);
    if (index != -1) {
      _messages[index] = _finalizedRow(
        _messages[index],
        content: content,
        ui: ui,
      );
      onMessagesChanged?.call();
    }
    if (hasActiveTranslation?.call(mid) != true) {
      streamController.removeStreamingNotifier(mid);
    }
    streamController.markStreamingEnded(mid);
    _setConversationLoading(cid, false);
    onFileProcessingFinished?.call();
    _showTruncationWarning(ui?.truncationReason);
    final finalized = index != -1 ? _messages[index] : null;
    if (finalized != null) {
      onAssistantMessageFinished?.call(finalized);
    }
    onStreamFinished?.call();
    if (ctx.assistantMessage.subgroupId == null) {
      onMaybeUpdateProactiveCare?.call(cid);
    } else {
      onMultiAISlotSettled?.call(mid, true);
    }
    if (ctx.generateTitleOnFinish) {
      onMaybeGenerateTitle?.call(cid);
    }
    onMaybeGenerateSummary?.call(cid);
    onMaybeGenerateSuggestions?.call(cid);
    unawaited(_finishIosBackgroundGeneration(success: true));
  }

  /// Copies the settled slot state into the in-memory list row (the DB row is
  /// authoritative; this keeps the list row consistent without a reload).
  /// Without a settled snapshot only content/isStreaming are touched — the
  /// sentinel-pattern copyWith would otherwise CLEAR the token fields.
  ChatMessage _finalizedRow(
    ChatMessage row, {
    required String content,
    GenerationSlotUiState? ui,
  }) {
    if (ui == null) {
      return row.copyWith(content: content, isStreaming: false);
    }
    return row.copyWith(
      content: content,
      isStreaming: false,
      totalTokens: ui.totalTokens,
      contextTokens: ui.contextTokens,
      promptTokens: ui.promptTokens,
      completionTokens: ui.completionTokens,
      cachedTokens: ui.cachedTokens,
      durationMs: ui.durationMs > 0 ? ui.durationMs : null,
      reasoningText: ui.reasoningText.isNotEmpty ? ui.reasoningText : null,
    );
  }

  /// Surfaces the response-truncated warning (page policy; mirrors the
  /// pre-engine `_handleStreamFinish` behavior).
  void _showTruncationWarning(String? truncationReason) {
    if (truncationReason == null) return;
    if (!contextProvider.mounted) return;
    final l10n = _l10n;
    if (l10n == null) return;
    final reasonText = truncationReason == 'max_tokens'
        ? l10n.truncationReasonMaxTokens
        : l10n.truncationReasonContextExceeded;
    showAppSnackBar(
      contextProvider,
      message: l10n.responseTruncated(reasonText),
      type: NotificationType.warning,
      duration: const Duration(seconds: 30),
    );
  }

  /// Engine slot failed or was cancelled: the engine already persisted the
  /// partial/'Error' content with `isStreaming: false`; finalize the
  /// page-side state and surface the error (suppressed for user cancels).
  Future<void> _onEngineSlotError(
    stream_ctrl.GenerationContext ctx,
    String mid,
    String cid,
    Object error,
  ) async {
    onFileProcessingFinished?.call();
    final engine = contextProvider.read<GenerationEngine>();
    final slot = engine.slotForMessage(mid);
    final cancelled = slot?.status == SlotStatus.cancelled;
    final errorText = error.toString();
    debugPrint(
      '[GenerationEngine] page slot error: msgId=$mid cancelled=$cancelled $errorText',
    );

    streamController.markStreamingEnded(mid);
    final content = slot?.finalText ?? '';
    final ui = slot?.finalUiState;
    final index = _messages.indexWhere((m) => m.id == mid);
    if (index != -1) {
      _messages[index] = _finalizedRow(
        _messages[index],
        content: content.isNotEmpty ? content : errorText,
        ui: ui,
      );
      onMessagesChanged?.call();
    }
    if (hasActiveTranslation?.call(mid) != true) {
      streamController.removeStreamingNotifier(mid);
    }

    if (!cancelled) {
      _setConversationLoading(cid, false);
      onStreamError?.call(errorText);
    }
    if (ctx.assistantMessage.subgroupId != null) {
      onMultiAISlotSettled?.call(mid, false);
    }
    onStreamFinished?.call();
    await _finishIosBackgroundGeneration(success: false, detail: errorText);
  }

  // ============================================================================
  // Flush Progress (for switching conversations)
  // ============================================================================

  /// Persist latest in-flight assistant message content and reasoning.
  Future<void> flushConversationProgress(Conversation? conversation) async {
    final cid = conversation?.id;
    if (cid == null || _messages.isEmpty) return;

    // Find the latest streaming assistant message in the current conversation
    ChatMessage? streaming;
    for (var i = _messages.length - 1; i >= 0; i--) {
      final m = _messages[i];
      if (m.role == 'assistant' && m.isStreaming && m.conversationId == cid) {
        streaming = m;
        break;
      }
    }
    if (streaming == null) return;

    // Use the UI-side content snapshot (may be ahead of last persisted chunk)
    String latestContent = streaming.content;
    // Also capture reasoning progress if tracked in-memory
    final r = streamController.reasoning[streaming.id];
    final segs = streamController.reasoningSegments[streaming.id];

    try {
      await chatService.updateMessage(
        streaming.id,
        content: latestContent,
        totalTokens: streaming.totalTokens,
        // Do not flip isStreaming here; just flush progress
      );
      if (r != null) {
        await chatService.updateMessage(
          streaming.id,
          reasoningText: r.text,
          reasoningStartAt: r.startAt ?? DateTime.now(),
          // keep finishedAt as-is (may be null while thinking)
        );
      }
      if (segs != null && segs.isNotEmpty) {
        await chatService.updateMessage(
          streaming.id,
          reasoningSegmentsJson: stream_ctrl
              .serializeReasoningSegmentsWithSplits(
                segs,
                contentSplitOffsets: streamController
                    .getContentSplitData(streaming.id)
                    ?.offsets,
                reasoningCountAtSplit: streamController
                    .getContentSplitData(streaming.id)
                    ?.reasoningCounts,
                toolCountAtSplit: streamController
                    .getContentSplitData(streaming.id)
                    ?.toolCounts,
                reasoningDetails:
                    streamController.reasoningDetails[streaming.id],
              ),
        );
      } else if (streamController.getContentSplitData(streaming.id) != null) {
        final splits = streamController.getContentSplitData(streaming.id)!;
        await chatService.updateMessage(
          streaming.id,
          reasoningSegmentsJson: stream_ctrl
              .serializeReasoningSegmentsWithSplits(
                const [],
                contentSplitOffsets: splits.offsets,
                reasoningCountAtSplit: splits.reasoningCounts,
                toolCountAtSplit: splits.toolCounts,
                reasoningDetails:
                    streamController.reasoningDetails[streaming.id],
              ),
        );
      }
    } catch (_) {}
  }

  /// Clean up streaming state after an error before streaming started.
  Future<void> _cleanupStreamingError(
    ChatMessage message,
    String conversationId,
  ) async {
    streamController.markStreamingEnded(message.id);
    final msgIdx = _messages.indexWhere((m) => m.id == message.id);
    if (msgIdx != -1) {
      _messages[msgIdx] = message.copyWith(isStreaming: false);
    }
    await chatService.updateMessage(message.id, isStreaming: false);
    _setConversationLoading(conversationId, false);
  }
}
