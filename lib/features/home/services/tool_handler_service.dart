import 'dart:async';
import 'dart:convert';

import 'package:flutter/widgets.dart';
import 'package:provider/provider.dart';
import '../../../core/models/assistant.dart';
import '../../../core/models/assistant_memory.dart';
import '../../../core/providers/assistant_provider.dart';
import '../../../core/providers/mcp_provider.dart';
import '../../../core/providers/memory_provider.dart';
import '../../../core/providers/settings_provider.dart';
import '../../../core/providers/tts_provider.dart';
import '../../../core/services/api/chat_api_service.dart';
import '../../../core/services/headless_generation_service.dart';
import '../../../core/services/mcp/mcp_tool_service.dart';
import '../../../core/services/search/search_tool_service.dart';
import 'ask_user_interaction_service.dart';
import 'local_tools_service.dart';
import 'tool_approval_service.dart';

/// 工具调用处理服务
///
/// 处理各类工具调用：
/// - MCP 工具
/// - Memory 工具 (create/edit/delete)
/// - Search 工具
enum CollisionSource { builtin, mcpVsMcp }

class ToolNameCollision {
  final String toolName;
  final CollisionSource source;
  final List<McpServerConfig> servers;

  const ToolNameCollision({
    required this.toolName,
    required this.source,
    required this.servers,
  });
}

class ToolHandlerService {
  ToolHandlerService({required this.contextProvider});

  /// Build context (used for accessing providers)
  final BuildContext contextProvider;

  // ============================================================================
  // Tool Schema Sanitization
  // ============================================================================

  /// Sanitize/translate JSON Schema to each provider's accepted subset.
  ///
  /// Different providers (Google, OpenAI, Claude) have different requirements
  /// for tool parameter schemas. This method normalizes schemas to work across
  /// all providers.
  static Map<String, dynamic> sanitizeToolParametersForProvider(
    Map<String, dynamic> schema,
    ProviderKind kind,
  ) {
    Map<String, dynamic> clone = _deepCloneMap(schema);
    clone = _sanitizeNode(clone, kind) as Map<String, dynamic>;
    return clone;
  }

  static dynamic _sanitizeNode(dynamic node, ProviderKind kind) {
    if (node is List) {
      return node.map((e) => _sanitizeNode(e, kind)).toList();
    }
    if (node is! Map) return node;

    final m = Map<String, dynamic>.from(node);
    // Remove $schema as it's not needed for tool definitions
    m.remove(r'$schema');

    // Convert 'const' to 'enum' for compatibility
    if (m.containsKey('const')) {
      final v = m['const'];
      if (v is String || v is num || v is bool) {
        m['enum'] = [v];
      }
      m.remove('const');
    }

    // Flatten anyOf/oneOf/allOf to first variant for simplicity
    for (final key in [
      'anyOf',
      'oneOf',
      'allOf',
      'any_of',
      'one_of',
      'all_of',
    ]) {
      if (m[key] is List && (m[key] as List).isNotEmpty) {
        final first = (m[key] as List).first;
        final flattened = _sanitizeNode(first, kind);
        m.remove(key);
        if (flattened is Map<String, dynamic>) {
          m
            ..remove('type')
            ..remove('properties')
            ..remove('items');
          m.addAll(flattened);
        }
      }
    }

    // Normalize type array to single type
    final t = m['type'];
    if (t is List && t.isNotEmpty) m['type'] = t.first.toString();

    // Normalize items array to single item
    final items = m['items'];
    if (items is List && items.isNotEmpty) m['items'] = items.first;
    if (m['items'] is Map) m['items'] = _sanitizeNode(m['items'], kind);

    // Recursively sanitize properties
    if (m['properties'] is Map) {
      final props = Map<String, dynamic>.from(m['properties']);
      final norm = <String, dynamic>{};
      props.forEach((k, v) {
        norm[k] = _sanitizeNode(v, kind);
      });
      m['properties'] = norm;
    }

    // additionalProperties may be a bool or a subschema (Map). When Map,
    // recurse so nested nodes (e.g. $schema, const) are normalized too.
    if (m['additionalProperties'] is Map) {
      m['additionalProperties'] = _sanitizeNode(
        m['additionalProperties'],
        kind,
      );
    }

    // Keep only allowed keys based on provider
    Set<String> allowed;
    switch (kind) {
      case ProviderKind.google:
        allowed = {
          'type',
          'description',
          'properties',
          'required',
          'items',
          'enum',
        };
        break;
      case ProviderKind.openai:
      case ProviderKind.claude:
        allowed = {
          'type',
          'description',
          'properties',
          'required',
          'items',
          'enum',
          // Standard JSON Schema field. Must be preserved so MCP servers
          // that declare open/free-form object params are not silently
          // narrowed to closed objects. Strict models (e.g. GLM-5.1)
          // otherwise refuse to fill undeclared params.
          // Google/Gemini rejects this key so it stays dropped there.
          'additionalProperties',
        };
        break;
    }
    m.removeWhere((k, v) => !allowed.contains(k));
    return m;
  }

  static Map<String, dynamic> _deepCloneMap(Map<String, dynamic> input) {
    return jsonDecode(jsonEncode(input)) as Map<String, dynamic>;
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

  // ============================================================================
  // Collision Detection & Prefix Validation
  // ============================================================================

  static final RegExp _prefixPattern = RegExp(r'^[a-zA-Z_][a-zA-Z0-9_]{0,15}$');

  /// Validate a tool prefix string.
  ///
  /// Returns null if valid, or a localization key string if invalid.
  static String? validateToolPrefix(String prefix, McpServerConfig server) {
    if (prefix.isEmpty) return null;
    if (!_prefixPattern.hasMatch(prefix)) {
      return 'prefixFormatInvalid';
    }
    final maxToolLen = server.tools.isEmpty
        ? 0
        : server.tools
              .map((t) => t.name.length)
              .reduce((a, b) => a > b ? a : b);
    if (prefix.length + 1 + maxToolLen > 64) {
      return 'prefixTooLong';
    }
    return null;
  }

  static Set<String> _getBuiltinToolNames(Assistant? assistant) {
    final names = <String>{};
    if (assistant == null) return names;
    if (assistant.searchEnabled == true) {
      names.add(SearchToolService.toolName);
    }
    if (assistant.enableMemory == true) {
      names.add('create_memory');
      names.add('edit_memory');
      names.add('delete_memory');
      if (assistant.memoryMode == 'tool') {
        names.add('read_memory');
      }
    }
    for (final id in assistant.localToolIds) {
      names.add(id);
    }
    if (assistant.skillIds.isNotEmpty) {
      names.add(LocalToolNames.loadSkill);
      names.add(LocalToolNames.readSkillFile);
    }
    return names;
  }

  /// Detect tool name collisions for the given assistant.
  ///
  /// Returns a list of [ToolNameCollision] objects describing each collision.
  /// Empty list means no collisions — safe to send.
  static List<ToolNameCollision> detectToolNameCollisions({
    required McpProvider mcp,
    required Assistant? assistant,
  }) {
    final collisions = <ToolNameCollision>[];
    if (assistant == null) return collisions;

    final builtinNames = _getBuiltinToolNames(assistant);
    final selectedIds = assistant.mcpServerIds.toSet();
    final boundServers = mcp.connectedServers
        .where((s) => selectedIds.contains(s.id) && s.enabled)
        .toList();

    // Group MCP tools by effective (after-prefix) name
    final effectiveToServers = <String, List<McpServerConfig>>{};
    for (final server in boundServers) {
      for (final tool in server.tools.where((t) => t.enabled)) {
        final effective = server.toolPrefix.isNotEmpty
            ? '${server.toolPrefix}_${tool.name}'
            : tool.name;
        effectiveToServers.putIfAbsent(effective, () => []).add(server);
      }
    }

    for (final entry in effectiveToServers.entries) {
      final effectiveName = entry.key;
      final servers = entry.value;

      // MCP-vs-built-in: effective name matches a built-in (only happens when
      // all contributing servers have no prefix, since prefixed names like
      // "mem_create_memory" won't appear in builtinNames)
      if (builtinNames.contains(effectiveName)) {
        collisions.add(
          ToolNameCollision(
            toolName: effectiveName,
            source: CollisionSource.builtin,
            servers: servers,
          ),
        );
        continue; // skip MCP-vs-MCP check; builtin collision is the main issue
      }

      // MCP-vs-MCP: same effective name across multiple servers
      if (servers.length > 1) {
        collisions.add(
          ToolNameCollision(
            toolName: effectiveName,
            source: CollisionSource.mcpVsMcp,
            servers: servers,
          ),
        );
      }
    }

    return collisions;
  }

  // ============================================================================
  // Tool Definitions Builder
  // ============================================================================

  /// Build tool definitions for API call.
  ///
  /// Returns a list of tool definitions including:
  /// - Search tool (if enabled and model supports tools)
  /// - Memory tools (if assistant has memory enabled)
  /// - MCP tools (from selected servers for the assistant)
  List<Map<String, dynamic>> buildToolDefinitions(
    SettingsProvider settings,
    Assistant? assistant,
    String providerKey,
    String modelId,
    bool hasBuiltInSearch, {
    required bool Function(String providerKey, String modelId) isToolModel,
  }) {
    final List<Map<String, dynamic>> toolDefs = <Map<String, dynamic>>[];
    final supportsTools = isToolModel(providerKey, modelId);

    // Search tool (skip when Gemini built-in search is active)
    if (assistant?.searchEnabled == true &&
        !hasBuiltInSearch &&
        supportsTools) {
      toolDefs.add(SearchToolService.getToolDefinition());
    }

    // Memory tools
    if (assistant?.enableMemory == true && supportsTools) {
      toolDefs.addAll(
        _buildMemoryToolDefinitions(memoryMode: assistant!.memoryMode),
      );
    }

    // Local tools
    toolDefs.addAll(
      LocalToolsService.buildToolDefinitions(
        assistant: assistant,
        supportsTools: supportsTools,
      ),
    );

    // MCP tools
    final mcpTools = _buildMcpToolDefinitions(
      settings: settings,
      assistant: assistant,
      providerKey: providerKey,
      supportsTools: supportsTools,
    );
    toolDefs.addAll(mcpTools);

    return toolDefs;
  }

  /// Build memory tool definitions (create/edit/delete + read_memory in tool mode).
  List<Map<String, dynamic>> _buildMemoryToolDefinitions({
    String memoryMode = 'injection',
  }) {
    final tools = <Map<String, dynamic>>[
      if (memoryMode == 'tool')
        const {
          'type': 'function',
          'function': {
            'name': 'read_memory',
            'description':
                'Read all stored memory records for this assistant. '
                'Call this at the start of a conversation before the first response '
                'to load existing memories.',
            'parameters': {'type': 'object', 'properties': <String, dynamic>{}},
          },
        },
    ];
    tools.addAll(<Map<String, dynamic>>[
      {
        'type': 'function',
        'function': {
          'name': 'create_memory',
          'description':
              'Create a new long-term memory record that persists across conversations for user preferences, personal details, plans, work facts, and other important context. Act like a personal secretary by actively recording useful information when you learn it, without waiting for the user to ask. If the user has just shared important new personal information, call this tool (or edit_memory to update an existing record) before writing your response, so you don\'t forget. Check existing memories first to avoid duplicated memory for the same fact. DO NOT store sensitive information (ethnicity, religion, sexual orientation, political views, criminal records, or other protected data). DO NOT inform the user about the memory write unless they explicitly ask you to.',
          'parameters': {
            'type': 'object',
            'properties': {
              'content': {
                'type': 'string',
                'description': 'The content of the memory record',
              },
            },
            'required': ['content'],
          },
        },
      },
      {
        'type': 'function',
        'function': {
          'name': 'edit_memory',
          'description':
              'Update an existing memory record identified by its numeric "id" (shown in the <memories> context). Use when a stored memory is outdated, incorrect, or needs supplementary details. Only update the specific fact that changed. Keep each record focused on one topic — do not merge different categories into the same record. If new information belongs to a different category, use create_memory instead. DO NOT delete unrelated information. DO NOT use this to create new memories (use create_memory instead). Do NOT inform the user about the update unless they explicitly ask you to.',
          'parameters': {
            'type': 'object',
            'properties': {
              'id': {
                'type': 'integer',
                'description': 'The id of the memory record',
              },
              'content': {
                'type': 'string',
                'description': 'The content of the memory record',
              },
            },
            'required': ['id', 'content'],
          },
        },
      },
      {
        'type': 'function',
        'function': {
          'name': 'delete_memory',
          'description':
              'Delete a memory record identified by its numeric "id" (shown in the <memories> context). Use when a memory is no longer relevant, outdated, incorrectly recorded, or a duplicate. Before deleting, consider whether edit_memory is more appropriate. Do NOT delete memories that may still be useful. DO NOT inform the user about the deletion unless they explicitly ask.',
          'parameters': {
            'type': 'object',
            'properties': {
              'id': {
                'type': 'integer',
                'description': 'The id of the memory record',
              },
            },
            'required': ['id'],
          },
        },
      },
    ]);
    return tools;
  }

  /// Build MCP tool definitions from connected servers.
  List<Map<String, dynamic>> _buildMcpToolDefinitions({
    required SettingsProvider settings,
    required Assistant? assistant,
    required String providerKey,
    required bool supportsTools,
  }) {
    if (!supportsTools) return [];

    final mcp = contextProvider.read<McpProvider>();
    final assistantProvider = contextProvider.read<AssistantProvider>();
    final a = (assistant?.id != null)
        ? assistantProvider.getById(assistant!.id)
        : assistantProvider.currentAssistant;
    final selectedIds = (a?.mcpServerIds ?? const <String>[]).toSet();
    final boundServers = mcp.connectedServers
        .where((s) => selectedIds.contains(s.id) && s.enabled)
        .toList();
    if (boundServers.isEmpty) return [];

    final providerCfg = settings.getProviderConfig(providerKey);
    final providerKind = ProviderConfig.classify(
      providerCfg.id,
      explicitType: providerCfg.providerType,
    );

    final results = <Map<String, dynamic>>[];
    for (final server in boundServers) {
      for (final tool in server.tools.where((t) => t.enabled)) {
        final effectiveName = server.toolPrefix.isNotEmpty
            ? '${server.toolPrefix}_${tool.name}'
            : tool.name;

        Map<String, dynamic> baseSchema;
        if (tool.schema != null && tool.schema!.isNotEmpty) {
          baseSchema = Map<String, dynamic>.from(tool.schema!);
        } else {
          final props = <String, dynamic>{
            for (final p in tool.params) p.name: {'type': (p.type ?? 'string')},
          };
          final required = [
            for (final p in tool.params.where((e) => e.required)) p.name,
          ];
          baseSchema = {
            'type': 'object',
            'properties': props,
            if (required.isNotEmpty) 'required': required,
          };
        }
        final sanitized = sanitizeToolParametersForProvider(
          baseSchema,
          providerKind,
        );
        results.add({
          'type': 'function',
          'function': {
            'name': effectiveName,
            if ((tool.description ?? '').isNotEmpty)
              'description': tool.description,
            'parameters': sanitized,
          },
        });
      }
    }
    return results;
  }

  // ============================================================================
  // Tool Call Handler
  // ============================================================================

  /// Build tool call handler function.
  ///
  /// Returns a function that handles tool calls by name and arguments.
  /// Supports:
  /// - Search tool calls
  /// - Memory tool calls (create/edit/delete)
  /// - MCP tool calls
  ToolCallHandler? buildToolCallHandler(
    SettingsProvider settings,
    Assistant? assistant, {
    ToolApprovalService? approvalService,
    AskUserInteractionService? askUserService,
    String? conversationId,
  }) {
    final mcp = contextProvider.read<McpProvider>();
    final toolSvc = contextProvider.read<McpToolService>();
    // Capture AssistantProvider reference before async gap to avoid
    // use_build_context_synchronously warning
    final assistantProvider = contextProvider.read<AssistantProvider>();

    return (name, args, {toolCallId}) async {
      try {
        // Resolve MCP prefix — longest-prefix-first to avoid ambiguity
        // (e.g. prefix "ab" must win over "a" for tool "ab_tool").
        // Only consider servers bound to this assistant.
        String resolvedName = name;
        McpServerConfig? mcpServer;
        bool hasMcpPrefix = false;
        final boundIds = (assistant?.mcpServerIds ?? const <String>[]).toSet();
        final prefixedServers =
            mcp.connectedServers
                .where(
                  (s) => s.toolPrefix.isNotEmpty && boundIds.contains(s.id),
                )
                .toList()
              ..sort(
                (a, b) => b.toolPrefix.length.compareTo(a.toolPrefix.length),
              );
        for (final s in prefixedServers) {
          final prefixWithSep = '${s.toolPrefix}_';
          if (name.startsWith(prefixWithSep)) {
            resolvedName = name.substring(prefixWithSep.length);
            mcpServer = s;
            hasMcpPrefix = true;
            break;
          }
        }

        // If the tool name has a known MCP prefix, bypass built-in tools
        // and route directly to that MCP server
        if (hasMcpPrefix) {
          // Approval gate (using original unprefixed name)
          if (approvalService != null && mcp.toolNeedsApproval(resolvedName)) {
            final callId =
                '${resolvedName}_${DateTime.now().microsecondsSinceEpoch}';
            final result = await approvalService.requestApproval(
              toolCallId: callId,
              toolName: resolvedName,
              arguments: args,
              conversationId: conversationId,
            );
            if (!result.approved) {
              return _toolError(
                error: 'approval_denied',
                message: result.denyReason ?? 'User denied the tool call',
                tool: resolvedName,
              );
            }
          }

          final text = await toolSvc.callToolTextForAssistant(
            mcp,
            assistantProvider,
            assistantId: assistant?.id,
            toolName: resolvedName,
            arguments: args,
            targetServerId: mcpServer!.id,
          );
          return await _afterSyncHandoff(resolvedName, text);
        }

        // Search tool
        if (name == SearchToolService.toolName &&
            assistant?.searchEnabled == true) {
          final q = (args['query'] ?? '').toString();
          return await SearchToolService.executeSearch(q, settings);
        }

        // Memory tools
        final memoryResult = await _handleMemoryToolCall(name, args, assistant);
        if (memoryResult != null) {
          return memoryResult;
        }

        // Local tools
        final localResult = await LocalToolsService.tryHandleToolCall(
          name,
          args,
          assistant,
          onSpeakText: (text) async {
            final tts = contextProvider.read<TtsProvider>();
            if (!tts.isAvailable) {
              throw StateError('Text-to-speech is unavailable.');
            }
            unawaited(
              tts.speak(text).catchError((Object error, StackTrace stack) {
                FlutterError.reportError(
                  FlutterErrorDetails(
                    exception: error,
                    stack: stack,
                    library: 'Kelivo local tools',
                    context: ErrorDescription('while playing text-to-speech'),
                  ),
                );
              }),
            );
          },
        );
        if (localResult != null) {
          return localResult;
        }

        if (name == LocalToolNames.askUser &&
            assistant != null &&
            assistant.localToolIds.contains(LocalToolNames.askUser)) {
          if (askUserService == null) {
            return _toolError(
              error: 'ask_user_unavailable',
              message: 'Ask user interaction service is unavailable.',
              tool: name,
            );
          }
          try {
            final result = await askUserService.requestAnswer(
              toolCallId: (toolCallId?.trim().isNotEmpty == true)
                  ? toolCallId!.trim()
                  : '${name}_${DateTime.now().microsecondsSinceEpoch}',
              arguments: args,
              conversationId: conversationId,
            );
            return result.toJsonString();
          } on AskUserInvalidRequestException catch (e) {
            return _toolError(
              error: 'invalid_ask_user_request',
              message: e.message,
              tool: name,
            );
          }
        }

        // Approval gate for MCP tools
        if (approvalService != null && mcp.toolNeedsApproval(name)) {
          // Generate a unique id for this tool call approval request
          final toolCallId = '${name}_${DateTime.now().microsecondsSinceEpoch}';
          final result = await approvalService.requestApproval(
            toolCallId: toolCallId,
            toolName: name,
            arguments: args,
            conversationId: conversationId,
          );
          if (!result.approved) {
            return _toolError(
              error: 'approval_denied',
              message: result.denyReason ?? 'User denied the tool call',
              tool: name,
            );
          }
        }

        // MCP tools (unprefixed fallback)
        final text = await toolSvc.callToolTextForAssistant(
          mcp,
          assistantProvider,
          assistantId: assistant?.id,
          toolName: name,
          arguments: args,
        );
        return await _afterSyncHandoff(name, text);
      } catch (e) {
        // Catch unexpected exceptions and return error JSON to LLM
        // This prevents tool failures from terminating the chat flow
        return _toolError(
          error: 'execution_error',
          message: e.toString(),
          tool: name,
          instruction:
              'The tool execution failed unexpectedly. You may try again with different parameters or inform the user about the issue.',
        );
      }
    };
  }

  /// Wait-mode handoff (`kelivo_handoff_sync`): the fast MCP response carries
  /// the child conversation UUID; block ABOVE the MCP layer until the
  /// sub-generation completes, then return its full output (or a
  /// cancellation/error marker) as the tool result. Any other tool passes
  /// through unchanged.
  Future<String> _afterSyncHandoff(String name, String mcpText) async {
    if (name != 'kelivo_handoff_sync') return mcpText;

    String? childId;
    try {
      final decoded = jsonDecode(mcpText);
      if (decoded is Map) {
        final id = (decoded['conversation'] ?? '').toString();
        if (id.isNotEmpty) childId = id;
      }
    } catch (e) {
      debugPrint('[SyncHandoff] unparseable result: $e');
    }
    if (childId == null) {
      return _toolError(
        error: 'subagent_bad_result',
        message:
            'kelivo_handoff_sync returned an unparseable result: '
            '$mcpText',
        tool: name,
      );
    }

    final headlessGen = contextProvider.read<HeadlessGenerationService>();
    final result = await headlessGen.waitFor(childId);
    if (result.cancelled) {
      return _toolError(
        error: 'subagent_cancelled',
        message: 'The sub-agent was cancelled by the user before finishing.',
        tool: name,
        instruction:
            'The sub-agent did not finish. Summarize what was accomplished '
            'or ask the user whether to retry.',
      );
    }
    if (result.error != null) {
      return _toolError(
        error: 'subagent_error',
        message: result.error!,
        tool: name,
      );
    }
    return result.text;
  }

  /// Handle memory tool calls (create/edit/delete).
  ///
  /// Returns null if the tool is not a memory tool or memory is not enabled.
  Future<String?> _handleMemoryToolCall(
    String name,
    Map<String, dynamic> args,
    Assistant? assistant,
  ) async {
    if (assistant?.enableMemory != true) return null;
    if (name != 'create_memory' &&
        name != 'edit_memory' &&
        name != 'delete_memory' &&
        name != 'read_memory') {
      return null;
    }

    try {
      final mp = contextProvider.read<MemoryProvider>();

      if (name == 'create_memory') {
        final content = (args['content'] ?? '').toString();
        if (content.isEmpty) {
          return _toolError(
            error: 'invalid_memory_content',
            message: 'Memory content must not be empty.',
            tool: name,
          );
        }
        final m = await mp.add(assistantId: assistant!.id, content: content);
        return AssistantMemory.buildRecordXml(m.id, m.content);
      } else if (name == 'edit_memory') {
        final id = (args['id'] as num?)?.toInt() ?? -1;
        final content = (args['content'] ?? '').toString();
        if (id <= 0) {
          return _toolError(
            error: 'invalid_memory_id',
            message: 'Memory id must be a positive integer.',
            tool: name,
          );
        }
        if (content.isEmpty) {
          return _toolError(
            error: 'invalid_memory_content',
            message: 'Memory content must not be empty.',
            tool: name,
          );
        }
        final m = await mp.update(id: id, content: content);
        if (m == null) {
          return _toolError(
            error: 'memory_not_found',
            message: 'No memory record was found for id $id.',
            tool: name,
            instruction:
                'Use the available memory records shown in context, or create a new memory instead of editing a missing one.',
          );
        }
        return AssistantMemory.buildRecordXml(m.id, m.content);
      } else if (name == 'delete_memory') {
        final id = (args['id'] as num?)?.toInt() ?? -1;
        if (id <= 0) {
          return _toolError(
            error: 'invalid_memory_id',
            message: 'Memory id must be a positive integer.',
            tool: name,
          );
        }
        final ok = await mp.delete(id: id);
        if (!ok) {
          return _toolError(
            error: 'memory_not_found',
            message: 'No memory record was found for id $id.',
            tool: name,
            instruction:
                'Use the available memory records shown in context, or skip deleting a missing memory.',
          );
        }
        return 'deleted';
      } else if (name == 'read_memory') {
        await mp.initialize();
        final mems = mp.getForAssistant(assistant!.id);
        return AssistantMemory.buildMemoryXml(mems);
      }
    } catch (e) {
      return _toolError(
        error: 'memory_execution_error',
        message: e.toString(),
        tool: name,
        instruction:
            'The memory tool failed. Retry only after correcting the parameters, or inform the user about the issue.',
      );
    }

    return null;
  }
}
