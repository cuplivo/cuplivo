import 'dart:async';
import 'dart:convert';

import 'package:mcp_client/mcp_client.dart' as mcp;

import 'package:flutter/widgets.dart';
import 'package:provider/provider.dart';

import '../../../models/assistant.dart';
import '../../../models/conversation.dart';
import '../../../providers/assistant_provider.dart';
import '../../../providers/settings_provider.dart';
import '../../../../features/chat/utils/thinking_tag_parser.dart';
import '../../../../features/home/services/ask_user_interaction_service.dart';
import '../../../../features/home/services/message_builder_service.dart';
import '../../../../features/home/services/tool_approval_service.dart';
import '../../../../features/home/services/tool_handler_service.dart';
import '../../api/chat_api_service.dart';
import '../../chat/chat_service.dart';
import '../../headless_generation_service.dart';

/// @kelivo/subagent — In-memory MCP server engine and transport (Flutter/Dart)
class KelivoSubagentMcpServerEngine {
  KelivoSubagentMcpServerEngine({
    required this._assistants,
    required this._chatService,
    required this._headlessGen,
    required this._contextProvider,
  });

  final AssistantProvider _assistants;
  final ChatService _chatService;
  final HeadlessGenerationService _headlessGen;
  final BuildContext Function() _contextProvider;
  bool _closed = false;

  Future<dynamic> handleMessage(dynamic message) async {
    if (_closed) return null;
    if (message is List) {
      final out = <dynamic>[];
      for (final m in message) {
        out.add(await _handleSingle(m));
      }
      return out;
    }
    return await _handleSingle(message);
  }

  Future<Map<String, dynamic>> _handleSingle(dynamic raw) async {
    dynamic requestId;
    try {
      if (raw is! Map) {
        return _error(null, code: -32600, message: 'Invalid Request');
      }
      final req = raw.cast<String, dynamic>();
      requestId = req['id'];
      final method = (req['method'] ?? '').toString();
      final params = (req['params'] is Map)
          ? (req['params'] as Map).cast<String, dynamic>()
          : <String, dynamic>{};

      switch (method) {
        case mcp.McpProtocol.methodInitialize:
          return _ok(
            requestId,
            result: {
              'serverInfo': {'name': '@kelivo/subagent', 'version': '1.0.0'},
              'protocolVersion': mcp.McpProtocol.defaultVersion,
              'capabilities': {
                'tools': {'listChanged': false},
              },
            },
          );

        case mcp.McpProtocol.methodListTools:
          return _ok(requestId, result: {'tools': _toolDefinitions()});

        case mcp.McpProtocol.methodCallTool:
          final name = (params['name'] ?? '').toString();
          final arguments = (params['arguments'] is Map)
              ? (params['arguments'] as Map).cast<String, dynamic>()
              : <String, dynamic>{};

          if (name == 'kelivo_handoff') {
            return _ok(requestId, result: await _handleHandoff(arguments));
          }
          if (name == 'kelivo_handoff_sync') {
            return _ok(
              requestId,
              result: await _handleHandoff(arguments, waitForResult: true),
            );
          }
          return _error(
            requestId,
            code: -32101,
            message: 'Tool not found: $name',
          );

        default:
          if (requestId == null) return _noop();
          return _error(
            requestId,
            code: -32601,
            message: 'Method not found: $method',
          );
      }
    } catch (e) {
      return _error(requestId, code: -32603, message: 'Internal error: $e');
    }
  }

  Future<Map<String, dynamic>> _handleHandoff(
    Map<String, dynamic> arguments, {
    bool waitForResult = false,
  }) async {
    final handoffId = (arguments['assistant'] ?? '').toString().trim();
    final task = (arguments['task'] ?? '').toString().trim();

    debugPrint(
      '[Subagent] handoff request: assistant=$handoffId, '
      'task=${task.length > 80 ? '${task.substring(0, 80)}...' : task}',
    );

    if (task.isEmpty) {
      return _toolResult(isError: true, text: 'Error: task must not be empty.');
    }

    final matches = _assistants.assistants.where(
      (a) => a.discoverable && a.handoffId == handoffId,
    );
    final target = matches.isNotEmpty ? matches.first : null;

    if (target == null) {
      final available = _assistants.assistants
          .where(
            (a) =>
                a.discoverable &&
                a.handoffId != null &&
                a.handoffId!.isNotEmpty,
          )
          .map((a) => a.handoffId)
          .join(', ');
      return _toolResult(
        isError: true,
        text:
            'Error: no discoverable assistant with id \'$handoffId\'. '
            'Available: [${available.isEmpty ? 'none' : available}].',
      );
    }

    final parentConversationId = _chatService.currentConversationId;

    final conversation = await _chatService.createConversation(
      assistantId: target.id,
      mcpServerIds: target.mcpServerIds,
      parentConversationId: parentConversationId,
      // The delegating conversation stays "current": the 子代理面板 keys off
      // ChatService.currentConversationId, and nested handoffs must
      // attribute their parent to the real delegating conversation, not to
      // whichever child was created last.
      setAsCurrent: false,
    );
    await _chatService.addMessage(
      conversationId: conversation.id,
      role: 'user',
      content: task,
    );

    debugPrint(
      '[Subagent] conversation created: ${conversation.id} '
      '(parent: $parentConversationId, assistant: ${target.name})',
    );

    if (waitForResult) {
      // Register the job record BEFORE starting the generation: the
      // generation's synchronous section may fail immediately (failJob below
      // must find the record), and the `started` JSON response travels back
      // through pure microtasks while the generation suspends on real I/O —
      // the handler's waitFor must find the job in both cases.
      _headlessGen.prepareJob(
        conversationId: conversation.id,
        parentConversationId: parentConversationId,
        wait: true,
        targetName: target.name,
      );
    }

    unawaited(
      _startGeneration(conversation, target, waitForResult: waitForResult),
    );

    if (waitForResult) {
      // Structured JSON: the tool-handler layer extracts the UUID and awaits
      // the completion future above the MCP boundary (never blocks the
      // JSON-RPC response, which is bounded by the client request timeout).
      return _toolResult(
        text: jsonEncode({
          'conversation': conversation.id,
          'status': 'started',
        }),
      );
    }
    return _toolResult(
      text: 'Handoff dispatched. Conversation: ${conversation.id}',
    );
  }

  Future<void> _startGeneration(
    Conversation conversation,
    Assistant target, {
    bool waitForResult = false,
  }) async {
    try {
      // ignore: use_build_context_synchronously (root context, valid for app lifetime)
      final ctx = _contextProvider();
      // ignore: use_build_context_synchronously
      final settings = ctx.read<SettingsProvider>();
      final providerKey =
          target.chatModelProvider ?? settings.currentModelProvider ?? '';
      final modelId = target.chatModelId ?? settings.currentModelId ?? '';
      final config = settings.getProviderConfig(providerKey);

      debugPrint(
        '[Subagent] building pipeline for ${conversation.id} '
        '(provider: $providerKey, model: $modelId)',
      );

      final messageBuilder = MessageBuilderService(
        chatService: _chatService,
        // ignore: use_build_context_synchronously (root context)
        contextProvider: ctx,
      );
      final allMessages = _chatService.getMessages(conversation.id);
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
      messageBuilder.injectSystemPrompt(apiMessages, target, modelId);
      await messageBuilder.injectMemoryAndRecentChats(
        apiMessages,
        target,
        currentConversationId: conversation.id,
      );
      messageBuilder.injectInstructionPrompts(apiMessages, target.id);
      await messageBuilder.injectWorldBookPrompts(apiMessages, target.id);
      messageBuilder.injectSkillListPrompt(apiMessages, target.id);
      messageBuilder.injectTimeNote(apiMessages, target);
      messageBuilder.applyContextLimit(apiMessages, target);

      // ignore: use_build_context_synchronously (root context)
      final toolHandler = ToolHandlerService(contextProvider: ctx);
      final toolDefs = toolHandler.buildToolDefinitions(
        settings,
        target,
        providerKey,
        modelId,
        false,
        isToolModel: (_, _) => true,
      );
      final onToolCall = toolDefs.isNotEmpty
          ? toolHandler.buildToolCallHandler(
              settings,
              target,
              // Approval/ask_user must be answerable from the parent panel
              // and the child conversation (dual visibility). v1 omitted
              // these — needsApproval tools silently auto-executed.
              // ignore: use_build_context_synchronously (root context)
              approvalService: ctx.read<ToolApprovalService>(),
              // ignore: use_build_context_synchronously (root context)
              askUserService: ctx.read<AskUserInteractionService>(),
              conversationId: conversation.id,
            )
          : null;

      debugPrint(
        '[Subagent] starting generation for ${conversation.id} '
        '(${apiMessages.length} messages, ${toolDefs.length} tools)',
      );

      _headlessGen.start(
        conversationId: conversation.id,
        assistantId: target.id,
        apiMessages: apiMessages,
        config: config,
        modelId: modelId,
        toolDefs: toolDefs.isEmpty ? null : toolDefs,
        onToolCall: onToolCall,
        thinkingBudget: target.thinkingBudget ?? settings.thinkingBudget,
        temperature: target.temperature,
        topP: target.topP,
        maxTokens: target.maxTokens,
        stream: target.streamOutput,
        onComplete: () => _generateTitle(conversation.id, target),
        parentConversationId: conversation.parentConversationId,
        wait: waitForResult,
        targetName: target.name,
      );
    } catch (e, st) {
      debugPrint(
        '[Subagent] generation failed for ${conversation.id}: $e\n$st',
      );
      // Resolve the waiter: a wait-mode handoff must never leave the
      // orchestrator's await hanging (see ADR-0024 iron rule). No-op for
      // fire-and-forget (nothing listens to the completer).
      _headlessGen.failJob(conversation.id, e);
    }
  }

  void _generateTitle(String conversationId, Assistant assistant) {
    unawaited(_generateTitleAsync(conversationId, assistant));
  }

  Future<void> _generateTitleAsync(
    String conversationId,
    Assistant assistant,
  ) async {
    try {
      // ignore: use_build_context_synchronously (root context)
      final ctx = _contextProvider();
      // ignore: use_build_context_synchronously
      final settings = ctx.read<SettingsProvider>();

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

      final msgs = _chatService.getMessages(conversationId);
      final joined = msgs
          .where((m) => m.content.isNotEmpty)
          .map(
            (m) =>
                '${m.role == 'assistant' ? 'Assistant' : 'User'}: ${m.content}',
          )
          .join('\n\n');
      final content = joined.length > 3000 ? joined.substring(0, 3000) : joined;
      final locale = Localizations.localeOf(ctx).toLanguageTag();

      final prompt = settings.titlePrompt
          .replaceAll('{locale}', locale)
          .replaceAll('{content}', content);

      final raw = (await ChatApiService.generateText(
        config: cfg,
        modelId: mdlId,
        prompt: prompt,
        thinkingBudget: budget,
      )).trim();
      final title = ThinkingTagParser.parseLegacyInlineBlocks(
        raw,
      ).visibleContent;
      if (title.isNotEmpty) {
        await _chatService.renameConversation(conversationId, title);
        debugPrint('[Subagent] title generated for $conversationId: $title');
      }
    } catch (e) {
      debugPrint('[Subagent] title generation failed for $conversationId: $e');
    }
  }

  void close() {
    _closed = true;
  }

  List<Map<String, dynamic>> _toolDefinitions() {
    final targets = _assistants.assistants
        .where(
          (a) =>
              a.discoverable && a.handoffId != null && a.handoffId!.isNotEmpty,
        )
        .toList();

    final descBuffer = StringBuffer();
    descBuffer.write(
      'Delegate a task to another specialized assistant. '
      'A new conversation is created with full tool access. '
      'The user can navigate to it from the conversation list.\n',
    );
    if (targets.isEmpty) {
      descBuffer.write(
        'No assistants are currently available. '
        'Ask the user to enable "discoverable" on a target assistant.',
      );
    } else {
      descBuffer.write('Available targets:\n');
      for (final t in targets) {
        descBuffer.write(
          '- ${t.handoffId}: ${t.handoffDescription ?? t.name}\n',
        );
      }
    }

    final syncDescBuffer = StringBuffer();
    syncDescBuffer.write(
      'Delegate a task to another specialized assistant AND WAIT for it to '
      'finish. The sub-agent\'s complete output is returned as the tool '
      'result, so you can synthesize from it. Unlike kelivo_handoff, the '
      'result may be long and this call may take minutes. '
      'The user can watch progress in the panel and visit the sub-conversation.\n',
    );
    if (targets.isEmpty) {
      syncDescBuffer.write(
        'No assistants are currently available. '
        'Ask the user to enable "discoverable" on a target assistant.',
      );
    } else {
      syncDescBuffer.write('Available targets:\n');
      for (final t in targets) {
        syncDescBuffer.write(
          '- ${t.handoffId}: ${t.handoffDescription ?? t.name}\n',
        );
      }
    }

    return [
      {
        'name': 'kelivo_handoff',
        'description': descBuffer.toString(),
        'inputSchema': {
          'type': 'object',
          'properties': {
            'assistant': {
              'type': 'string',
              'description': 'The handoff ID of the target assistant',
            },
            'task': {
              'type': 'string',
              'description':
                  'The complete task prompt for the target assistant. '
                  'Include all necessary context — the target has no access '
                  'to this conversation\'s history.',
            },
          },
          'required': ['assistant', 'task'],
        },
      },
      {
        'name': 'kelivo_handoff_sync',
        'description': syncDescBuffer.toString(),
        'inputSchema': {
          'type': 'object',
          'properties': {
            'assistant': {
              'type': 'string',
              'description': 'The handoff ID of the target assistant',
            },
            'task': {
              'type': 'string',
              'description':
                  'The complete task prompt for the target assistant. '
                  'Include all necessary context — the target has no access '
                  'to this conversation\'s history.',
            },
          },
          'required': ['assistant', 'task'],
        },
      },
    ];
  }

  Map<String, dynamic> _ok(dynamic id, {required Map<String, dynamic> result}) {
    return {'jsonrpc': '2.0', if (id != null) 'id': id, 'result': result};
  }

  Map<String, dynamic> _error(
    dynamic id, {
    required int code,
    required String message,
  }) {
    return {
      'jsonrpc': '2.0',
      if (id != null) 'id': id,
      'error': {'code': code, 'message': message},
    };
  }

  Map<String, dynamic> _noop() => {'jsonrpc': '2.0'};

  Map<String, dynamic> _toolResult({String text = '', bool isError = false}) {
    return {
      'content': [
        {'type': 'text', 'text': text},
      ],
      if (isError) 'isError': true,
    };
  }
}

class KelivoSubagentInMemoryClientTransport implements mcp.ClientTransport {
  final KelivoSubagentMcpServerEngine _server;
  final _messageController = StreamController<dynamic>.broadcast();
  final _closeCompleter = Completer<void>();
  bool _closed = false;

  KelivoSubagentInMemoryClientTransport(this._server);

  @override
  Stream<dynamic> get onMessage => _messageController.stream;

  @override
  Future<void> get onClose => _closeCompleter.future;

  @override
  void send(dynamic message) {
    if (_closed) return;
    Future.microtask(() async {
      final resp = await _server.handleMessage(message);
      if (_closed) return;
      if (resp != null) {
        _messageController.add(resp);
      }
    });
  }

  @override
  void close() {
    if (_closed) return;
    _closed = true;
    try {
      _server.close();
    } catch (_) {}
    if (!_messageController.isClosed) _messageController.close();
    if (!_closeCompleter.isCompleted) _closeCompleter.complete();
  }
}
