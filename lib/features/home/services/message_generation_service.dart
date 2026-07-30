import 'dart:async';
import 'package:flutter/widgets.dart';
import '../../../core/models/assistant.dart';
import '../../../core/models/chat_context_message.dart';
import '../../../core/models/chat_input_data.dart';
import '../../../core/models/chat_message.dart';
import '../../../core/models/conversation.dart';
import '../../../core/providers/settings_provider.dart';
import '../../../core/services/api/chat_api_service.dart';
import '../../../core/services/chat/chat_service.dart';
import '../../../core/services/model_override_payload_parser.dart';
import '../../../core/utils/multimodal_input_utils.dart';
import '../../../core/utils/openai_model_compat.dart';
import '../../../utils/assistant_regex.dart';
import '../../../core/models/assistant_regex.dart';
import '../controllers/stream_controller.dart' as stream_ctrl;
import '../controllers/generation_controller.dart';
import 'ask_user_interaction_service.dart';
import 'message_builder_service.dart';
import 'tool_approval_service.dart';

/// Callback types for UI updates from MessageGenerationService
typedef OnMessagesChanged = void Function();
typedef OnConversationLoadingChanged =
    void Function(String conversationId, bool loading);
typedef OnScrollToBottom = void Function();
typedef OnShowError = void Function(String message);
typedef OnShowWarning = void Function(String message);
typedef OnHapticFeedback = void Function();

const String conversationIdHeaderName = 'X-Conversation-Id';
const String _conversationIdHeaderNameLower = 'x-conversation-id';

Map<String, String>? buildConversationRequestHeaders({
  required String conversationId,
  Map<String, String>? customHeaders,
}) {
  final headers = <String, String>{
    if (customHeaders != null)
      for (final entry in customHeaders.entries)
        if (entry.key.toLowerCase() != _conversationIdHeaderNameLower)
          entry.key: entry.value,
  };
  final normalizedConversationId = conversationId.trim();
  if (normalizedConversationId.isNotEmpty) {
    headers[conversationIdHeaderName] = normalizedConversationId;
  }
  return headers.isEmpty ? null : headers;
}

/// Result of preparing a message generation
class PreparedGeneration {
  final List<Map<String, dynamic>> apiMessages;
  final List<Map<String, dynamic>> toolDefs;
  final ToolCallHandler? onToolCall;
  final bool hasBuiltInSearch;
  final List<String> lastUserImagePaths;

  PreparedGeneration({
    required this.apiMessages,
    required this.toolDefs,
    this.onToolCall,
    required this.hasBuiltInSearch,
    required this.lastUserImagePaths,
  });
}

typedef SharedToolDefinitionsBuilder =
    List<Map<String, dynamic>> Function(
      SettingsProvider settings,
      Assistant? assistant,
      String providerKey,
      String modelId,
      bool hasBuiltInSearch,
    );
typedef SharedToolCallHandlerBuilder =
    ToolCallHandler? Function(
      SettingsProvider settings,
      Assistant? assistant, {
      ToolApprovalService? approvalService,
      AskUserInteractionService? askUserService,
    });

/// Provider-neutral preparation shared by ordinary and group member chat.
class ChatGenerationPreparationService {
  const ChatGenerationPreparationService({
    required this.messageBuilderService,
    required this.buildToolDefinitions,
    required this.buildToolCallHandler,
  });

  final MessageBuilderService messageBuilderService;
  final SharedToolDefinitionsBuilder buildToolDefinitions;
  final SharedToolCallHandlerBuilder buildToolCallHandler;

  Future<PreparedGeneration> prepare({
    required List<ChatMessage> messages,
    List<ChatContextMessage>? contextMessages,
    required Map<String, int> versionSelections,
    required Conversation? currentConversation,
    required SettingsProvider settings,
    required Assistant? assistant,
    required String? assistantId,
    required String providerKey,
    required String modelId,
    ToolApprovalService? approvalService,
    AskUserInteractionService? askUserService,
    VoidCallback? onFileProcessingStarted,
    VoidCallback? onFileProcessingFinished,
  }) async {
    final config = settings.getProviderConfig(providerKey);
    final kind = ProviderConfig.classify(
      providerKey,
      explicitType: config.providerType,
    );
    final includeToolMessages = switch (kind) {
      ProviderKind.openai || ProviderKind.claude || ProviderKind.google => true,
    };

    onFileProcessingStarted?.call();
    try {
      var effectiveContextMessages = contextMessages;
      if (effectiveContextMessages != null &&
          assistant != null &&
          assistant.regexRules.isNotEmpty) {
        effectiveContextMessages = effectiveContextMessages
            .map((entry) {
              final message = entry.message;
              if (message.role != 'assistant' ||
                  !entry.applyAssistantSendTransform ||
                  message.content.isEmpty) {
                return entry;
              }
              return ChatContextMessage(
                message: message.copyWith(
                  content: applyAssistantRegexes(
                    message.content,
                    assistant: assistant,
                    scope: AssistantRegexScope.assistant,
                    target: AssistantRegexTransformTarget.send,
                  ),
                ),
                includeArtifacts: entry.includeArtifacts,
                applyAssistantSendTransform: entry.applyAssistantSendTransform,
              );
            })
            .toList(growable: false);
      }

      final apiMessages = effectiveContextMessages == null
          ? messageBuilderService.buildApiMessages(
              messages: messages,
              versionSelections: versionSelections,
              currentConversation: currentConversation,
              includeToolMessages: includeToolMessages,
            )
          : messageBuilderService.buildApiMessagesFromContext(
              contextMessages: effectiveContextMessages,
              versionSelections: versionSelections,
              currentConversation: currentConversation,
              includeToolMessages: includeToolMessages,
            );

      if (contextMessages == null &&
          assistant != null &&
          assistant.regexRules.isNotEmpty) {
        for (final message in apiMessages) {
          if ((message['role'] ?? '').toString() != 'assistant') continue;
          final raw = (message['content'] ?? '').toString();
          if (raw.isEmpty) continue;
          message['content'] = applyAssistantRegexes(
            raw,
            assistant: assistant,
            scope: AssistantRegexScope.assistant,
            target: AssistantRegexTransformTarget.send,
          );
        }
      }

      final lastUserImagePaths = await messageBuilderService
          .processUserMessagesForApi(apiMessages, settings, assistant);

      messageBuilderService.injectSystemPrompt(apiMessages, assistant, modelId);
      await messageBuilderService.injectMemoryAndRecentChats(
        apiMessages,
        assistant,
        currentConversationId: currentConversation?.id,
      );

      final hasBuiltInSearch = messageBuilderService.hasBuiltInSearch(
        settings,
        providerKey,
        modelId,
      );
      messageBuilderService.injectSearchPrompt(
        apiMessages,
        settings,
        assistant,
        hasBuiltInSearch,
      );
      await messageBuilderService.injectInstructionPrompts(
        apiMessages,
        assistantId,
      );
      await messageBuilderService.injectWorldBookPrompts(
        apiMessages,
        assistantId,
      );
      await messageBuilderService.injectSkillListPrompt(
        apiMessages,
        assistantId,
      );
      messageBuilderService.injectTimeNote(apiMessages, assistant);
      messageBuilderService.applyContextLimit(apiMessages, assistant);
      await messageBuilderService.inlineLocalImages(apiMessages);

      final toolDefs = buildToolDefinitions(
        settings,
        assistant,
        providerKey,
        modelId,
        hasBuiltInSearch,
      );
      final onToolCall = toolDefs.isEmpty
          ? null
          : buildToolCallHandler(
              settings,
              assistant,
              approvalService: approvalService,
              askUserService: askUserService,
            );

      return PreparedGeneration(
        apiMessages: apiMessages,
        toolDefs: toolDefs,
        onToolCall: onToolCall,
        hasBuiltInSearch: hasBuiltInSearch,
        lastUserImagePaths: lastUserImagePaths,
      );
    } finally {
      onFileProcessingFinished?.call();
    }
  }
}

/// Service for handling message generation orchestration.
///
/// This service coordinates:
/// - Message creation (user + assistant placeholder)
/// - API message preparation with all injections
/// - Stream execution and management
/// - Reasoning state initialization
///
/// UI updates are communicated through callbacks to maintain separation.
class MessageGenerationService {
  MessageGenerationService({
    required this.chatService,
    required this.messageBuilderService,
    required this.generationController,
    required this.streamController,
    required this.contextProvider,
  });

  final ChatService chatService;
  final MessageBuilderService messageBuilderService;
  final GenerationController generationController;
  final stream_ctrl.StreamController streamController;
  final BuildContext contextProvider;

  // Callbacks for UI updates (set by home_page)
  OnMessagesChanged? onMessagesChanged;
  OnConversationLoadingChanged? onConversationLoadingChanged;
  OnScrollToBottom? onScrollToBottom;
  OnShowError? onShowError;
  OnShowWarning? onShowWarning;
  OnHapticFeedback? onHapticFeedback;

  /// Called when file processing starts.
  VoidCallback? onFileProcessingStarted;

  /// Called when file processing finishes.
  VoidCallback? onFileProcessingFinished;

  /// Check if reasoning is enabled for given budget
  bool isReasoningEnabled(int? budget) {
    if (budget == null) return true;
    if (budget == -1) return true;
    return budget >= 1024;
  }

  /// Prepare API messages with all injections applied.
  Future<PreparedGeneration> prepareApiMessagesWithInjections({
    required List<ChatMessage> messages,
    List<ChatContextMessage>? contextMessages,
    required Map<String, int> versionSelections,
    required Conversation? currentConversation,
    required SettingsProvider settings,
    required Assistant? assistant,
    required String? assistantId,
    required String providerKey,
    required String modelId,
    ToolApprovalService? approvalService,
    AskUserInteractionService? askUserService,
  }) {
    return ChatGenerationPreparationService(
      messageBuilderService: messageBuilderService,
      buildToolDefinitions: generationController.buildToolDefinitions,
      buildToolCallHandler: generationController.buildToolCallHandler,
    ).prepare(
      messages: messages,
      contextMessages: contextMessages,
      versionSelections: versionSelections,
      currentConversation: currentConversation,
      settings: settings,
      assistant: assistant,
      assistantId: assistantId,
      providerKey: providerKey,
      modelId: modelId,
      approvalService: approvalService,
      askUserService: askUserService,
      onFileProcessingStarted: onFileProcessingStarted,
      onFileProcessingFinished: onFileProcessingFinished,
    );
  }

  /// Create user message from input data.
  Future<ChatMessage> createUserMessage({
    required String conversationId,
    required ChatInputData input,
    required Assistant? assistant,
    String? groupId,
  }) async {
    return chatService.addMessage(
      conversationId: conversationId,
      role: 'user',
      content: MessageGenerationService.buildPersistedUserMessageContent(
        input,
        assistant: assistant,
      ),
      groupId: groupId,
    );
  }

  /// Build the persisted content string for a user message.
  static String buildPersistedUserMessageContent(
    ChatInputData input, {
    required Assistant? assistant,
  }) {
    final content = input.text.trim();
    final imageMarkers = input.imagePaths.map((p) => '\n[image:$p]').join();
    final docMarkers = input.documents
        .map((d) => '\n[file:${d.path}|${d.fileName}|${d.mime}]')
        .join();

    final processedUserText = applyAssistantRegexes(
      content,
      assistant: assistant,
      scope: AssistantRegexScope.user,
      target: AssistantRegexTransformTarget.persist,
    );

    return processedUserText + imageMarkers + docMarkers;
  }

  /// Create assistant message placeholder.
  Future<ChatMessage> createAssistantPlaceholder({
    required String conversationId,
    required String modelId,
    required String providerKey,
    String? groupId,
    String? subgroupId,
    int version = 0,
  }) async {
    return chatService.addMessage(
      conversationId: conversationId,
      role: 'assistant',
      content: '',
      modelId: modelId,
      providerId: providerKey,
      isStreaming: true,
      groupId: groupId,
      subgroupId: subgroupId,
      version: version,
    );
  }

  /// Initialize reasoning state for a message if reasoning is enabled.
  Future<void> initializeReasoningState({
    required String messageId,
    required bool enableReasoning,
  }) async {
    if (enableReasoning) {
      final rd = stream_ctrl.ReasoningData();
      streamController.reasoning[messageId] = rd;
      await chatService.updateMessage(
        messageId,
        reasoningStartAt: DateTime.now(),
      );
    }
  }

  /// Build GenerationContext for streaming.
  stream_ctrl.GenerationContext buildGenerationContext({
    required ChatMessage assistantMessage,
    required PreparedGeneration prepared,
    required List<String> userMediaPaths,
    required bool allowImagesApiRouting,
    required String providerKey,
    required String modelId,
    required Assistant? assistant,
    required SettingsProvider settings,
    required bool supportsReasoning,
    required bool enableReasoning,
    required bool generateTitleOnFinish,
  }) {
    final bool ocrActive =
        settings.ocrEnabled &&
        settings.ocrModelProvider != null &&
        settings.ocrModelId != null;

    return stream_ctrl.GenerationContext(
      assistantMessage: assistantMessage,
      apiMessages: prepared.apiMessages,
      userMediaPaths: userMediaPaths,
      allowImagesApiRouting: allowImagesApiRouting,
      providerKey: providerKey,
      modelId: modelId,
      assistant: assistant,
      settings: settings,
      config: settings.getProviderConfig(providerKey),
      toolDefs: prepared.toolDefs,
      onToolCall: prepared.onToolCall,
      extraHeaders: buildConversationRequestHeaders(
        conversationId: assistantMessage.conversationId,
        customHeaders: generationController.buildCustomHeaders(assistant),
      ),
      extraBody: generationController.buildCustomBody(assistant),
      supportsReasoning: supportsReasoning,
      enableReasoning: enableReasoning,
      streamOutput: assistant?.streamOutput ?? true,
      ocrActive: ocrActive,
      generateTitleOnFinish: generateTitleOnFinish,
    );
  }

  /// Get current model and provider from assistant or global settings.
  ({String? providerKey, String? modelId}) getModelConfig(
    SettingsProvider settings,
    Assistant? assistant,
  ) {
    return (
      providerKey:
          assistant?.chatModelProvider ?? settings.currentModelProvider,
      modelId: assistant?.chatModelId ?? settings.currentModelId,
    );
  }

  /// Calculate version info for regeneration.
  ({String? targetGroupId, int nextVersion, int lastKeep})
  calculateRegenerationVersioning({
    required ChatMessage message,
    required List<ChatMessage> messages,
    required bool assistantAsNewReply,
  }) {
    final idx = messages.indexWhere((m) => m.id == message.id);
    if (idx < 0) {
      return (targetGroupId: null, nextVersion: 0, lastKeep: -1);
    }

    String? targetGroupId;
    int nextVersion = 0;
    int lastKeep;

    if (message.role == 'assistant') {
      lastKeep = idx;
      if (assistantAsNewReply) {
        targetGroupId = null;
        nextVersion = 0;
      } else {
        targetGroupId = message.groupId ?? message.id;
        int maxVer = -1;
        for (final m in messages) {
          final gid = (m.groupId ?? m.id);
          if (gid == targetGroupId) {
            if (m.version > maxVer) maxVer = m.version;
          }
        }
        nextVersion = maxVer + 1;
      }
    } else {
      // User message
      final userGroupId = message.groupId ?? message.id;
      int userFirst = -1;
      for (int i = 0; i < messages.length; i++) {
        final gid0 = (messages[i].groupId ?? messages[i].id);
        if (gid0 == userGroupId) {
          userFirst = i;
          break;
        }
      }
      if (userFirst < 0) userFirst = idx;

      int aid = -1;
      for (int i = userFirst + 1; i < messages.length; i++) {
        if (messages[i].role == 'assistant') {
          aid = i;
          break;
        }
      }

      if (aid >= 0) {
        lastKeep = aid;
        targetGroupId = messages[aid].groupId ?? messages[aid].id;
        int maxVer = -1;
        for (final m in messages) {
          final gid = (m.groupId ?? m.id);
          if (gid == targetGroupId) {
            if (m.version > maxVer) maxVer = m.version;
          }
        }
        nextVersion = maxVer + 1;
      } else {
        lastKeep = userFirst;
        targetGroupId = null;
        nextVersion = 0;
      }
    }

    return (
      targetGroupId: targetGroupId,
      nextVersion: nextVersion,
      lastKeep: lastKeep,
    );
  }

  /// Remove trailing messages after regeneration cut point.
  @visibleForTesting
  static List<String> collectTrailingMessageIdsForRemoval({
    required List<ChatMessage> messages,
    required int lastKeep,
    required String? targetGroupId,
  }) {
    if (lastKeep >= messages.length - 1) {
      return const [];
    }

    final keepGroups = <String>{};
    for (int i = 0; i <= lastKeep && i < messages.length; i++) {
      keepGroups.add(messages[i].groupId ?? messages[i].id);
    }
    if (targetGroupId != null) keepGroups.add(targetGroupId);

    final removeIds = <String>[];
    for (final message in messages.sublist(lastKeep + 1)) {
      final groupId = message.groupId ?? message.id;
      if (!keepGroups.contains(groupId)) {
        removeIds.add(message.id);
      }
    }
    return removeIds;
  }

  /// Remove trailing messages after regeneration cut point.
  Future<List<String>> removeTrailingMessages({
    required List<ChatMessage> messages,
    required int lastKeep,
    required String? targetGroupId,
  }) async {
    final removeIds = collectTrailingMessageIdsForRemoval(
      messages: messages,
      lastKeep: lastKeep,
      targetGroupId: targetGroupId,
    );

    for (final id in removeIds) {
      try {
        await chatService.deleteMessage(id);
      } catch (_) {}
      streamController.reasoning.remove(id);
      streamController.toolParts.remove(id);
      streamController.reasoningSegments.remove(id);
    }

    return removeIds;
  }

  bool _shouldIncludeAudioForProvider(
    SettingsProvider settings, {
    required String providerKey,
    required String modelId,
  }) {
    final cfg = settings.getProviderConfig(providerKey);
    if (ProviderConfig.classify(providerKey, explicitType: cfg.providerType) !=
        ProviderKind.openai) {
      return false;
    }
    final override = ModelOverridePayloadParser.modelOverride(
      cfg.modelOverrides,
      modelId,
    );
    final upstreamModelId = resolveApiModelIdOverride(override, modelId);
    return isLongCatOmniModelId(upstreamModelId);
  }

  bool supportsAudioAttachmentsForProvider(
    SettingsProvider settings, {
    required String providerKey,
    required String modelId,
  }) {
    return _shouldIncludeAudioForProvider(
      settings,
      providerKey: providerKey,
      modelId: modelId,
    );
  }

  String _effectiveAttachmentMime(DocumentAttachment attachment) {
    return resolveDocumentAttachmentMime(attachment);
  }

  bool inputContainsAudioAttachments(ChatInputData input) {
    for (final attachment in input.documents) {
      if (isAudioMime(_effectiveAttachmentMime(attachment))) {
        return true;
      }
    }
    return false;
  }

  bool apiMessagesContainAudioAttachments(List<Map<String, dynamic>> messages) {
    for (final message in messages) {
      if ((message['role'] ?? '').toString() != 'user') continue;
      final parsed = messageBuilderService.parseInputFromRaw(
        (message['content'] ?? '').toString(),
      );
      if (parsed.documents.any(
        (attachment) => isAudioMime(_effectiveAttachmentMime(attachment)),
      )) {
        return true;
      }
    }
    return false;
  }

  List<String> _filterMediaPathsForProvider(
    List<String> paths, {
    required bool includeAudio,
  }) {
    return paths
        .where((path) {
          final mime = inferMediaMimeFromSource(
            path,
            fallbackMime: 'image/png',
          );
          if (isAudioMime(mime)) return includeAudio;
          return isImageMime(mime) ||
              isVideoMime(mime) ||
              isOfficeDocumentMime(mime);
        })
        .toList(growable: false);
  }

  /// Build user media paths (images, videos, audio, office docs) considering OCR mode.
  List<String> buildUserMediaPaths({
    required ChatInputData? input,
    required List<String> lastUserMediaPaths,
    required SettingsProvider settings,
    required String providerKey,
    required String modelId,
    Assistant? assistant,
  }) {
    final bool ocrActive =
        settings.ocrEnabled &&
        settings.ocrModelProvider != null &&
        settings.ocrModelId != null;

    final includeAudio = _shouldIncludeAudioForProvider(
      settings,
      providerKey: providerKey,
      modelId: modelId,
    );

    /// Skip office docs in 'extract' mode: their text is already injected
    /// into the API message via processUserMessagesForApi.
    bool skipOfficeDoc(String mime) {
      final lower = mime.toLowerCase();
      if (assistant != null) {
        if (lower == 'application/pdf') return assistant.pdfMode != 'direct';
        if (lower ==
            'application/vnd.openxmlformats-officedocument.wordprocessingml.document') {
          return assistant.docxMode != 'direct';
        }
        if (isOfficeDocumentMime(lower)) {
          return assistant.otherOfficeMode != 'direct';
        }
        return true;
      }
      // No assistant — use defaults:
      if (lower == 'application/pdf' ||
          lower ==
              'application/vnd.openxmlformats-officedocument.wordprocessingml.document') {
        return true; // default extract
      }
      if (isOfficeDocumentMime(lower)) return false; // default direct
      return true;
    }

    if (input != null) {
      final currentMediaPaths = <String>[];
      for (final d in input.documents) {
        final effectiveMime = _effectiveAttachmentMime(d);
        if (isVideoMime(effectiveMime) ||
            (isOfficeDocumentMime(effectiveMime) &&
                !skipOfficeDoc(effectiveMime)) ||
            (includeAudio && isAudioMime(effectiveMime))) {
          currentMediaPaths.add(d.path);
        }
      }
      return _filterMediaPathsForProvider(<String>[
        if (!ocrActive) ...input.imagePaths,
        ...currentMediaPaths,
      ], includeAudio: includeAudio);
    }

    return _filterMediaPathsForProvider(
      lastUserMediaPaths
          .where((path) {
            if (!ocrActive) return true;
            return !isImageMime(
              inferMediaMimeFromSource(path, fallbackMime: 'image/png'),
            );
          })
          .toList(growable: false),
      includeAudio: includeAudio,
    );
  }
}
