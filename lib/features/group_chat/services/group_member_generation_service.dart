import 'package:flutter/widgets.dart';
import 'package:provider/provider.dart';

import '../../../core/models/assistant.dart';
import '../../../core/models/conversation.dart';
import '../../../core/models/group_chat_message.dart';
import '../../../core/providers/settings_provider.dart';
import '../../../core/services/chat/assistant_request_options.dart';
import '../../../core/services/chat/chat_service.dart';
import '../../../core/services/chat/group_chat_service.dart';
import '../../../core/services/chat/model_capability_service.dart';
import '../../../core/services/group_chat/group_chat_context_projector.dart';
import '../../../core/services/group_chat/group_chat_orchestrator.dart';
import '../../home/services/ask_user_interaction_service.dart';
import '../../home/services/message_builder_service.dart';
import '../../home/services/message_generation_service.dart';
import '../../home/services/tool_approval_service.dart';
import '../../home/services/tool_handler_service.dart';

/// Adapts a group member turn to the ordinary chat preparation pipeline.
class GroupMemberGenerationService {
  GroupMemberGenerationService({
    required this.context,
    required this.chatService,
    required this.groupChatService,
  });

  final BuildContext context;
  final ChatService chatService;
  final GroupChatService groupChatService;

  Future<GroupMemberGenerationPreparation> prepare({
    required String groupId,
    required List<GroupChatMessage> timeline,
    required Assistant assistant,
    required Map<String, String> assistantNames,
    required String providerKey,
    required String modelId,
    required SettingsProvider settings,
  }) async {
    final contextMessages = GroupChatContextProjector.project(
      messages: timeline,
      speakerAssistantId: assistant.id,
      assistantNames: assistantNames,
    );
    final messageBuilder = MessageBuilderService(
      chatService: chatService,
      contextProvider: context,
      toolEventsForMessage: groupChatService.getToolEvents,
      latestPersistedMessage: (message) => message,
      geminiThoughtSignatureHandler: (message, content) {
        final signature = groupChatService.getGeminiThoughtSignature(
          message.id,
        );
        if (signature == null ||
            signature.isEmpty ||
            content.contains('gemini_thought_signatures:')) {
          return content;
        }
        return content.isEmpty ? signature : '$content\n$signature';
      },
    );
    final toolHandler = ToolHandlerService(contextProvider: context);
    final preparation = ChatGenerationPreparationService(
      messageBuilderService: messageBuilder,
      buildToolDefinitions:
          (
            appSettings,
            selectedAssistant,
            selectedProvider,
            selectedModel,
            hasBuiltInSearch,
          ) => toolHandler.buildToolDefinitions(
            appSettings,
            selectedAssistant,
            selectedProvider,
            selectedModel,
            hasBuiltInSearch,
            isToolModel: (provider, model) =>
                ModelCapabilityService.supportsTools(
                  appSettings,
                  provider,
                  model,
                ),
          ),
      buildToolCallHandler:
          (appSettings, selectedAssistant, {approvalService, askUserService}) =>
              toolHandler.buildToolCallHandler(
                appSettings,
                selectedAssistant,
                approvalService: approvalService,
                askUserService: askUserService,
              ),
    );

    final prepared = await preparation.prepare(
      messages: contextMessages.map((entry) => entry.message).toList(),
      contextMessages: contextMessages,
      versionSelections: const <String, int>{},
      currentConversation: Conversation(id: groupId, title: ''),
      settings: settings,
      assistant: assistant,
      assistantId: assistant.id,
      providerKey: providerKey,
      modelId: modelId,
      approvalService: context.read<ToolApprovalService>(),
      askUserService: context.read<AskUserInteractionService>(),
    );

    return GroupMemberGenerationPreparation(
      apiMessages: prepared.apiMessages,
      toolDefs: prepared.toolDefs,
      onToolCall: prepared.onToolCall,
      userMediaPaths: prepared.lastUserImagePaths,
      extraHeaders: buildConversationRequestHeaders(
        conversationId: groupId,
        customHeaders: buildAssistantCustomHeaders(assistant),
      ),
      extraBody: buildAssistantCustomBody(assistant),
    );
  }
}
