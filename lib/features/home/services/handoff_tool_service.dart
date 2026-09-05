import 'package:Cuplivo/core/database/business_preferences.dart';
import 'dart:async';
import 'dart:convert';

import 'package:flutter/widgets.dart';
import 'package:provider/provider.dart';

import '../../../core/models/assistant.dart';
import '../../../core/models/conversation.dart';
import '../../../core/providers/assistant_provider.dart';
import '../../../core/providers/settings_provider.dart';
import '../../../core/services/api/chat_api_service.dart';
import '../../../core/services/chat/chat_service.dart';
import '../../../core/services/generation_engine.dart';
import '../../../core/services/quick_instruction_store.dart';
import '../../../utils/utf16_safe_cut.dart';
import 'ask_user_interaction_service.dart';
import 'local_tools_service.dart';
import 'message_builder_service.dart';
import 'quick_instruction_execution_policy.dart';
import 'tool_approval_service.dart';
import 'tool_handler_service.dart';

/// Executes the handoff local tool (`kelivo_handoff`).
///
/// Formerly the `@kelivo/subagent` in-memory MCP server, then a fire-and-forget
/// / wait-mode tool pair; since ADR-0045 the single wait-mode tool: create a
/// child conversation for the target assistant, dispatch the task, and block
/// until the child generation completes — returning its FULL output as the
/// tool result (or a cancellation/error marker — the await never hangs).
class HandoffToolService {
  const HandoffToolService._();

  static Future<String> execute({
    required Map<String, dynamic> args,
    required AssistantProvider assistants,
    required ChatService chatService,
    required GenerationEngine engine,
    required BuildContext context,
    Assistant? delegatingAssistant,
  }) async {
    final handoffId = (args['assistant'] ?? '').toString().trim();
    final task = (args['task'] ?? '').toString().trim();

    debugPrint(
      '[HandoffTool] request: assistant=$handoffId, '
      'task=${task.length > 80 ? '${task.substring(0, 80)}...' : task}',
    );

    if (task.isEmpty) {
      return _toolError(
        error: 'handoff_empty_task',
        message: 'Error: task must not be empty.',
        tool: LocalToolNames.handoff,
      );
    }
    if (handoffId.isEmpty) {
      return _toolError(
        error: 'handoff_empty_target',
        message: 'Error: "assistant" must name a valid handoff target.',
        tool: LocalToolNames.handoff,
      );
    }

    // Self-delegation is rejected: delegating a task to your own assistant
    // is equivalent to doing it yourself and can spin into unbounded
    // recursion, so the current assistant is never a valid target.
    final matches = assistants.assistants.where(
      (a) =>
          a.discoverable &&
          a.handoffId == handoffId &&
          a.id != delegatingAssistant?.id,
    );
    final target = matches.isNotEmpty ? matches.first : null;

    if (target == null) {
      final availableIds = assistants.assistants
          .where(
            (a) =>
                a.discoverable &&
                a.handoffId != null &&
                a.handoffId!.isNotEmpty &&
                a.id != delegatingAssistant?.id,
          )
          .map((a) => a.handoffId!)
          .toList();
      // Cap the listing: a huge error payload would waste context budget.
      const maxListed = 20;
      final shown = availableIds.take(maxListed).join(', ');
      final truncated = availableIds.length > maxListed ? ', ...' : '';
      return _toolError(
        error: 'handoff_target_not_found',
        message:
            'Error: no discoverable assistant with id \'$handoffId\'. '
            'Available: [${shown.isEmpty ? 'none' : shown}$truncated].',
        tool: LocalToolNames.handoff,
      );
    }

    final parentConversationId = chatService.currentConversationId;

    final conversation = await chatService.createConversation(
      assistantId: target.id,
      mcpServerIds: target.mcpServerIds,
      parentConversationId: parentConversationId,
      // The delegating conversation stays "current": the subagent panel keys
      // off ChatService.currentConversationId, and nested handoffs must
      // attribute their parent to the real delegating conversation, not to
      // whichever child was created last.
      setAsCurrent: false,
    );
    await chatService.addMessage(
      conversationId: conversation.id,
      role: 'user',
      content: task,
    );

    debugPrint(
      '[HandoffTool] conversation created: ${conversation.id} '
      '(parent: $parentConversationId, assistant: ${target.name})',
    );

    // The caller creates the assistant placeholder (ADR-0034 slot model: the
    // engine streams into a pre-created message row and never creates rows
    // itself). It is created NOW so the round/slot registered below carries
    // the row id — the 子代理面板 binds to the slot from the dispatch moment,
    // before the async pipeline build.
    final assistantMsg = await chatService.addMessage(
      conversationId: conversation.id,
      role: 'assistant',
      content: '',
      isStreaming: true,
    );

    // Register the round BEFORE starting the generation: the generation's
    // synchronous section may fail immediately (failRound below must find
    // the round), and the waitFor below must find the round in both the
    // synchronous and suspended-start cases.
    engine.prepareRound(
      conversationId: conversation.id,
      assistantMessageId: assistantMsg.id,
      parentConversationId: parentConversationId,
      wait: true,
      targetName: target.name,
    );

    unawaited(
      _startGeneration(
        // ignore: use_build_context_synchronously (root context, valid for app lifetime)
        context,
        chatService,
        engine,
        conversation,
        target,
        assistantMessageId: assistantMsg.id,
      ),
    );

    // No MCP JSON-RPC boundary anymore: await the child generation directly.
    // waitFor always resolves (normal, error, or cancelled) — never hangs.
    final result = await engine.waitFor(conversation.id);
    if (result.cancelled) {
      return _toolError(
        error: 'subagent_cancelled',
        message: 'The sub-agent was cancelled by the user before finishing.',
        tool: LocalToolNames.handoff,
        instruction:
            'The sub-agent did not finish. Summarize what was accomplished '
            'or ask the user whether to retry.',
      );
    }
    if (result.error != null) {
      return _toolError(
        error: 'subagent_error',
        message: result.error!,
        tool: LocalToolNames.handoff,
      );
    }
    return result.text;
  }

  static Future<void> _startGeneration(
    BuildContext context,
    ChatService chatService,
    GenerationEngine engine,
    Conversation conversation,
    Assistant target, {
    required String assistantMessageId,
  }) async {
    try {
      // ignore: use_build_context_synchronously (root context, valid for app lifetime)
      final settings = context.read<SettingsProvider>();
      final providerKey =
          target.chatModelProvider ?? settings.currentModelProvider ?? '';
      final modelId = target.chatModelId ?? settings.currentModelId ?? '';
      final config = settings.getProviderConfig(providerKey);
      final preferences = context.read<BusinessPreferences>();
      final toolHandler = ToolHandlerService(contextProvider: context);
      final quickInstructionStore = QuickInstructionStore.shared(preferences);
      final approvalService = context.read<ToolApprovalService>();
      final askUserService = context.read<AskUserInteractionService>();

      debugPrint(
        '[HandoffTool] building pipeline for ${conversation.id} '
        '(provider: $providerKey, model: $modelId)',
      );

      final messageBuilder = MessageBuilderService(
        chatService: chatService,
        // ignore: use_build_context_synchronously (root context)
        contextProvider: context,
        preferences: preferences,
      );
      final allMessages = chatService.getMessages(conversation.id);
      final apiMessages = messageBuilder.buildApiMessages(
        messages: allMessages,
        versionSelections: <String, int>{},
        currentConversation: conversation,
      );
      await messageBuilder.processUserMessagesForApi(
        apiMessages,
        settings,
        target,
        providerKey: providerKey,
        modelId: modelId,
      );
      final quickInstructionPolicy =
          QuickInstructionExecutionPolicy.fromSources(
            systemInstructions: await quickInstructionStore.getActives(
              assistantId: target.id,
            ),
            anchorInvocations: const [],
          );
      final workspaceExecutionContext = toolHandler
          .resolveWorkspaceExecutionContext(target, conversation);
      messageBuilder.injectSystemPrompt(apiMessages, target, modelId);
      await messageBuilder.injectWorkspaceAgentsMdInstructions(
        apiMessages,
        assistant: target,
        workspaceExecutionContext: workspaceExecutionContext,
      );
      await messageBuilder.injectMemoryAndRecentChats(
        apiMessages,
        target,
        currentConversationId: conversation.id,
      );
      await messageBuilder.injectInstructionPrompts(apiMessages, target.id);
      await messageBuilder.injectWorldBookPrompts(apiMessages, target.id);
      messageBuilder.injectSkillListPrompt(apiMessages, target.id);
      messageBuilder.injectTimeNote(apiMessages, target);
      messageBuilder.applyContextLimit(apiMessages, target);

      messageBuilder.injectWorkspacePrompt(
        apiMessages,
        toolHandler.buildWorkspacePromptReminder(
          assistant: target,
          conversation: conversation,
          executionContext: workspaceExecutionContext,
        ),
      );
      final toolDefs = toolHandler.buildToolDefinitions(
        settings,
        target,
        providerKey,
        modelId,
        false,
        isToolModel: (_, _) => true,
        conversation: conversation,
        workspaceExecutionContext: workspaceExecutionContext,
      );
      final onToolCall = toolDefs.isNotEmpty
          ? toolHandler.buildToolCallHandler(
              settings,
              target,
              // Approval/ask_user must be answerable from the parent panel
              // and the child conversation (dual visibility).
              approvalService: approvalService,
              askUserService: askUserService,
              conversationId: conversation.id,
              conversation: conversation,
              workspaceExecutionContext: workspaceExecutionContext,
              quickInstructionPolicy: quickInstructionPolicy.isEmpty
                  ? null
                  : quickInstructionPolicy,
            )
          : null;

      debugPrint(
        '[HandoffTool] starting generation for ${conversation.id} '
        '(${apiMessages.length} messages, ${toolDefs.length} tools)',
      );

      engine.startRound(
        conversationId: conversation.id,
        slots: [
          GenerationSlotRequest(
            assistantMessageId: assistantMessageId,
            apiMessages: apiMessages,
            config: config,
            modelId: modelId,
            toolDefs: toolDefs.isEmpty ? null : toolDefs,
            onToolCall: onToolCall,
            assistant: target,
            thinkingBudget: target.thinkingBudget ?? settings.thinkingBudget,
            temperature: target.temperature,
            topP: target.topP,
            maxTokens: target.maxTokens,
            stream: target.streamOutput,
            autoCollapseThinking: settings.autoCollapseThinking,
            onSlotComplete: () =>
                _generateTitle(context, chatService, conversation.id, target),
          ),
        ],
        parentConversationId: conversation.parentConversationId,
        wait: true,
        targetName: target.name,
      );
    } catch (e, st) {
      debugPrint(
        '[HandoffTool] generation failed for ${conversation.id}: $e\n$st',
      );
      // The placeholder was created in execute but never streamed into —
      // remove the empty row (build failure before start).
      try {
        await chatService.deleteMessage(assistantMessageId);
      } catch (cleanupError) {
        debugPrint('[HandoffTool] placeholder cleanup failed: $cleanupError');
      }
      // Resolve the waiter: a wait-mode handoff must never leave the
      // orchestrator's await hanging (see ADR-0026 iron rule).
      engine.failRound(conversation.id, e);
    }
  }

  static void _generateTitle(
    BuildContext context,
    ChatService chatService,
    String conversationId,
    Assistant assistant,
  ) {
    unawaited(
      _generateTitleAsync(context, chatService, conversationId, assistant),
    );
  }

  static Future<void> _generateTitleAsync(
    BuildContext context,
    ChatService chatService,
    String conversationId,
    Assistant assistant,
  ) async {
    try {
      // ignore: use_build_context_synchronously (root context)
      final settings = context.read<SettingsProvider>();

      final provKey =
          settings.titleModelProvider ??
          assistant.chatModelProvider ??
          settings.currentModelProvider;
      final mdlId =
          settings.titleModelId ??
          assistant.chatModelId ??
          settings.currentModelId;
      if (provKey == null || mdlId == null) return;
      final cfg = settings.getProviderConfig(provKey);
      final budget = settings.titleGenerationThinkingBudgetFor(
        assistant.thinkingBudget,
      );

      final msgs = chatService.getMessages(conversationId);
      final joined = msgs
          .where((m) => m.content.isNotEmpty)
          .map(
            (m) =>
                '${m.role == 'assistant' ? 'Assistant' : 'User'}: ${m.content}',
          )
          .join('\n\n');
      final content = truncateHeadUtf16Safe(joined, 3000);
      final locale = Localizations.localeOf(context).toLanguageTag();

      final prompt = settings.titlePrompt
          .replaceAll('{locale}', locale)
          .replaceAll('{content}', content);

      final title = (await ChatApiService.generateText(
        config: cfg,
        modelId: mdlId,
        prompt: prompt,
        thinkingBudget: budget,
      )).trim();
      if (title.isNotEmpty) {
        await chatService.renameConversation(conversationId, title);
        debugPrint('[HandoffTool] title generated for $conversationId: $title');
      }
    } catch (e) {
      debugPrint(
        '[HandoffTool] title generation failed for $conversationId: $e',
      );
    }
  }

  static String _toolError({
    required String error,
    required String message,
    required String tool,
    String? instruction,
  }) {
    return jsonEncode({
      'type': 'tool_error',
      'error': error,
      'message': message,
      'tool': tool,
      if (instruction != null) 'instruction': instruction,
    });
  }
}
