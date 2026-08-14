import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:provider/provider.dart';
import 'package:uuid/uuid.dart';

import '../../../features/home/services/local_tools_service.dart';
import '../../../features/home/services/message_builder_service.dart';
import '../../../features/home/services/message_generation_service.dart';
import '../../../features/home/services/tool_handler_service.dart';
import '../../../l10n/app_localizations.dart';
import '../../models/assistant.dart';
import '../../models/scheduled_task.dart';
import '../../models/workspace.dart';
import '../../providers/assistant_provider.dart';
import '../../providers/mcp_provider.dart';
import '../../providers/scheduled_task_provider.dart';
import '../../providers/settings_provider.dart';
import '../../providers/workspace_provider.dart';
import '../chat/chat_service.dart';
import '../generation_engine.dart';
import 'scheduled_task_tool_service.dart';

class ScheduledTaskExecutionResult {
  const ScheduledTaskExecutionResult({
    required this.handled,
    this.success = false,
    this.taskName,
    this.error,
    this.notificationBody,
  });

  final bool handled;
  final bool success;
  final String? taskName;
  final String? error;
  final String? notificationBody;

  Map<String, dynamic> toMap() => <String, dynamic>{
    'handled': handled,
    'success': success,
    if (taskName != null) 'taskName': taskName,
    if (error != null) 'error': error,
    if (notificationBody != null) 'notificationBody': notificationBody,
  };
}

/// Executes a Shortcut-triggered task through the same tool-bearing generation
/// engine used by normal chats and handoffs.
///
/// The task always creates a fresh conversation. Interactive tools are removed
/// from the background tool list rather than being allowed to block forever on
/// an approval/ask-user UI that cannot be answered while the app is headless.
class ScheduledTaskExecutionService {
  const ScheduledTaskExecutionService._();

  static const Uuid _uuid = Uuid();

  static Future<List<ScheduledTaskExecutionResult>> executeDueTasks({
    required BuildContext context,
  }) async {
    final taskProvider = context.read<ScheduledTaskProvider>();
    await taskProvider.ensureLoaded();

    final now = DateTime.now();
    final dueTasks = taskProvider.tasks.where((task) {
      if (!task.enabled || task.isCompleted) return false;
      return task.schedule.occurrenceKey(now) != null;
    }).toList(growable: false);

    final results = <ScheduledTaskExecutionResult>[];
    for (final task in dueTasks) {
      final result = await _executeTask(
        // ignore: use_build_context_synchronously (root context, valid for app lifetime)
        context: context,
        taskProvider: taskProvider,
        task: task,
        now: now,
      );
      if (result.handled) results.add(result);
    }
    return results;
  }

  static Future<ScheduledTaskExecutionResult> _executeTask({
    required BuildContext context,
    required ScheduledTaskProvider taskProvider,
    required ScheduledTask task,
    required DateTime now,
  }) async {
    if (!task.enabled || task.isCompleted) {
      return const ScheduledTaskExecutionResult(handled: false);
    }

    final occurrenceKey = task.schedule.occurrenceKey(now);
    if (occurrenceKey == null) {
      return const ScheduledTaskExecutionResult(handled: false);
    }
    final claimed = await taskProvider.claimOccurrence(
      taskId: task.id,
      triggerId: task.triggerId,
      occurrenceKey: occurrenceKey,
    );
    if (!claimed) {
      return const ScheduledTaskExecutionResult(handled: false);
    }

    final startedAt = now;
    String? conversationId;
    // ignore: use_build_context_synchronously (root context, valid for app lifetime)
    final l10n = AppLocalizations.of(context);

    try {
      // ignore: use_build_context_synchronously (root context, valid for app lifetime)
      final chatService = context.read<ChatService>();
      await chatService.init();
      // ignore: use_build_context_synchronously (root context, valid for app lifetime)
      final assistantProvider = context.read<AssistantProvider>();
      await assistantProvider.ensureLoaded();
      final assistant = assistantProvider.getById(task.assistantId);
      if (assistant == null) {
        throw StateError('assistant_not_found');
      }

      final conversation = await chatService.createConversation(
        title: task.name,
        assistantId: assistant.id,
        mcpServerIds: assistant.mcpServerIds,
        setAsCurrent: false,
      );
      conversationId = conversation.id;
      await chatService.addMessage(
        conversationId: conversation.id,
        role: 'user',
        content: task.prompt,
      );

      // Cold App Intent launches can reach generation before lazily-loaded
      // providers finish initialization. Wait for workspace metadata and the
      // selected MCP connections for a short bounded window so the scheduled
      // assistant inherits the same non-interactive capabilities it normally
      // has in a foreground conversation.
      // ignore: use_build_context_synchronously (root context, valid for app lifetime)
      final workspaceProvider = context.read<WorkspaceProvider>();
      await workspaceProvider.init();
      // ignore: use_build_context_synchronously (root context, valid for app lifetime)
      final mcpProvider = context.read<McpProvider>();
      await mcpProvider.ensureLoaded();
      await _waitForSelectedMcpConnections(mcpProvider, assistant);

      // ignore: use_build_context_synchronously (root context, valid for app lifetime)
      final settings = context.read<SettingsProvider>();
      await settings.ensureLoaded();
      final providerKey =
          assistant.chatModelProvider ?? settings.currentModelProvider;
      final modelId = assistant.chatModelId ?? settings.currentModelId;
      if (providerKey == null ||
          providerKey.isEmpty ||
          modelId == null ||
          modelId.isEmpty) {
        throw StateError('model_not_configured');
      }
      final config = settings.getProviderConfig(providerKey);

      final builder = MessageBuilderService(
        chatService: chatService,
        // ignore: use_build_context_synchronously (root context, valid for app lifetime)
        contextProvider: context,
      );
      final messages = chatService.getMessages(conversation.id);
      final apiMessages = builder.buildApiMessages(
        messages: messages,
        versionSelections: const <String, int>{},
        currentConversation: conversation,
      );
      await builder.processUserMessagesForApi(
        apiMessages,
        settings,
        assistant,
        providerKey: providerKey,
        modelId: modelId,
      );
      builder.injectSystemPrompt(apiMessages, assistant, modelId);
      await builder.injectMemoryAndRecentChats(
        apiMessages,
        assistant,
        currentConversationId: conversation.id,
      );
      final hasBuiltInSearch = builder.hasBuiltInSearch(
        settings,
        providerKey,
        modelId,
      );
      builder.injectSearchPrompt(
        apiMessages,
        settings,
        assistant,
        hasBuiltInSearch,
      );
      await builder.injectInstructionPrompts(apiMessages, assistant.id);
      await builder.injectWorldBookPrompts(apiMessages, assistant.id);
      await builder.injectSkillListPrompt(apiMessages, assistant.id);
      builder.injectTimeNote(apiMessages, assistant);
      builder.applyContextLimit(apiMessages, assistant);
      await builder.inlineLocalImages(apiMessages);

      // ignore: use_build_context_synchronously (root context, valid for app lifetime)
      final toolHandler = ToolHandlerService(contextProvider: context);
      var toolDefs = toolHandler.buildToolDefinitions(
        settings,
        assistant,
        providerKey,
        modelId,
        hasBuiltInSearch,
        isToolModel: (_, _) => true,
      );
      toolDefs = _removeInteractiveTools(
        // ignore: use_build_context_synchronously (root context, valid for app lifetime)
        context: context,
        assistant: assistant,
        definitions: toolDefs,
      );
      final onToolCall = toolDefs.isEmpty
          ? null
          : toolHandler.buildToolCallHandler(
              settings,
              assistant,
              approvalService: null,
              askUserService: null,
              conversationId: conversation.id,
            );

      final placeholder = await chatService.addMessage(
        conversationId: conversation.id,
        role: 'assistant',
        content: '',
        modelId: modelId,
        providerId: providerKey,
        isStreaming: true,
      );

      // ignore: use_build_context_synchronously (root context, valid for app lifetime)
      final engine = context.read<GenerationEngine>();
      engine.startRound(
        conversationId: conversation.id,
        slots: <GenerationSlotRequest>[
          GenerationSlotRequest(
            assistantMessageId: placeholder.id,
            apiMessages: apiMessages,
            config: config,
            modelId: modelId,
            toolDefs: toolDefs.isEmpty ? null : toolDefs,
            onToolCall: onToolCall,
            assistant: assistant,
            thinkingBudget:
                assistant.thinkingBudget ?? settings.thinkingBudget,
            temperature: assistant.temperature,
            topP: assistant.topP,
            maxTokens: assistant.maxTokens,
            stream: assistant.streamOutput,
            extraHeaders: buildConversationRequestHeaders(
              conversationId: conversation.id,
              customHeaders: _customHeaders(assistant),
            ),
            extraBody: _customBody(assistant),
            autoCollapseThinking: settings.autoCollapseThinking,
          ),
        ],
        wait: true,
        targetName: assistant.name,
      );

      final result = await engine.waitFor(conversation.id);
      if (result.cancelled) throw StateError('generation_cancelled');
      if (result.error != null) throw StateError(result.error!);

      final finishedAt = DateTime.now();
      await taskProvider.recordLog(
        task.id,
        ScheduledTaskLog(
          id: _uuid.v4(),
          triggeredAt: startedAt,
          finishedAt: finishedAt,
          status: ScheduledTaskExecutionStatus.success,
          conversationId: conversation.id,
        ),
      );
      if (task.schedule.frequency == ScheduledTaskFrequency.once) {
        await taskProvider.markOnceCompleted(task.id, finishedAt);
      }
      return ScheduledTaskExecutionResult(
        handled: true,
        success: true,
        taskName: task.name,
        notificationBody:
            l10n?.scheduledTaskCompletedNotification ?? task.name,
      );
    } catch (error, stack) {
      debugPrint('[ScheduledTask] execution failed: $error\n$stack');
      final errorText = error.toString();
      final failedAt = DateTime.now();
      await taskProvider.recordLog(
        task.id,
        ScheduledTaskLog(
          id: _uuid.v4(),
          triggeredAt: startedAt,
          finishedAt: failedAt,
          status: ScheduledTaskExecutionStatus.failure,
          conversationId: conversationId,
          error: errorText,
        ),
      );
      if (task.schedule.frequency == ScheduledTaskFrequency.once) {
        await taskProvider.markOnceCompleted(task.id, failedAt);
      }
      return ScheduledTaskExecutionResult(
        handled: true,
        success: false,
        taskName: task.name,
        error: errorText,
        notificationBody:
            l10n?.scheduledTaskFailedNotification ?? errorText,
      );
    }
  }

  static Future<void> _waitForSelectedMcpConnections(
    McpProvider provider,
    Assistant assistant,
  ) async {
    final selectedIds = assistant.mcpServerIds.toSet();
    if (selectedIds.isEmpty) return;

    final deadline = DateTime.now().add(const Duration(seconds: 3));
    while (DateTime.now().isBefore(deadline)) {
      final selected = provider.servers.where(
        (server) => selectedIds.contains(server.id) && server.enabled,
      );
      if (selected.isNotEmpty &&
          selected.every((server) {
            if (server.oauth != null && server.oauthToken == null) return true;
            final status = provider.statusFor(server.id);
            return status == McpStatus.connected || status == McpStatus.error;
          })) {
        return;
      }
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
  }

  static List<Map<String, dynamic>> _removeInteractiveTools({
    required BuildContext context,
    required Assistant assistant,
    required List<Map<String, dynamic>> definitions,
  }) {
    final denied = <String>{
      LocalToolNames.askUser,
      // Handoffs can spawn a child assistant that asks for approval/user
      // input. Keep scheduled execution strictly non-interactive end-to-end.
      LocalToolNames.handoff,
      LocalToolNames.handoffSync,
    };

    try {
      final mcp = context.read<McpProvider>();
      final boundIds = assistant.mcpServerIds.toSet();
      for (final server in mcp.connectedServers) {
        if (!boundIds.contains(server.id) || !server.enabled) continue;
        for (final tool in server.tools) {
          if (!tool.enabled || !tool.needsApproval) continue;
          denied.add(
            server.toolPrefix.isEmpty
                ? tool.name
                : '${server.toolPrefix}_${tool.name}',
          );
        }
      }
    } catch (error) {
      debugPrint('[ScheduledTask] MCP approval filter unavailable: $error');
    }

    if (assistant.workspaceEnabled) {
      try {
        final workspaces = context.read<WorkspaceProvider>();
        final workspaceId = assistant.workspaceId;
        final workspace = workspaceId == null
            ? null
            : workspaces.getById(workspaceId);
        for (final name in WorkspaceToolNames.allTools) {
          if (workspace?.isToolNeedsApproval(name) ??
              WorkspaceToolNames.defaultApprovalFor(name)) {
            denied.add(name);
          }
        }
      } catch (error) {
        debugPrint(
          '[ScheduledTask] workspace approval filter unavailable: $error',
        );
      }
    }

    try {
      final scheduled = context.read<ScheduledTaskProvider>();
      if (scheduled.aiRequiresApproval) {
        denied.addAll(ScheduledTaskToolNames.writes);
      }
    } catch (_) {}

    return definitions.where((definition) {
      final function = definition['function'];
      if (function is! Map) return true;
      final name = function['name']?.toString();
      return name == null || !denied.contains(name);
    }).toList(growable: false);
  }

  static Map<String, String>? _customHeaders(Assistant assistant) {
    final headers = <String, String>{
      for (final entry in assistant.customHeaders)
        if ((entry['name'] ?? '').trim().isNotEmpty)
          entry['name']!.trim(): entry['value'] ?? '',
    };
    return headers.isEmpty ? null : headers;
  }

  static Map<String, dynamic>? _customBody(Assistant assistant) {
    final body = <String, dynamic>{
      for (final entry in assistant.customBody)
        if ((entry['key'] ?? '').trim().isNotEmpty)
          entry['key']!.trim(): entry['value'] ?? '',
    };
    return body.isEmpty ? null : body;
  }
}
