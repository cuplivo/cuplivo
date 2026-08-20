/// Unified `memory_tool` (one tool, three actions) for the 3-layer migration.
///
/// Why a single tool with an `action` discriminator instead of three tools
/// (`create_memory` / `edit_memory` / `delete_memory`):
///
/// - Tumin's reference implementation exposes exactly one `memory_tool` with
///   an `action` enum so the model can decide create/edit/delete from the
///   same prompt surface.
/// - Existing Cuplivo v15 assistants that already enable
///   `create_memory` / `edit_memory` / `delete_memory` keep those tools
///   working — `_handleMemoryToolCall` in `tool_handler_service.dart`
///   dispatches both the new `memory_tool` and the legacy three by name.
/// - When the assistant opts into 3-layer memory, the new tool is the
///   preferred surface; the legacy three are kept as a fallback for
///   assistants that were created before this migration and have not been
///   re-prompted.
///
/// The tool's executor delegates to [MemoryProvider] (the same one used by
/// the legacy three tools) so the on-disk format is identical — there's no
/// new persistence path to back-fill.
library;

import 'dart:convert';

import '../providers/memory_provider.dart';

class MemoryTool {
  const MemoryTool._();

  /// Wire name. Stable — changing it requires migrating every persisted
  /// assistant's `localToolIds` / implicit tool list.
  static const String toolName = 'memory_tool';

  static const String actionCreate = 'create';
  static const String actionEdit = 'edit';
  static const String actionDelete = 'delete';

  /// OpenAI-compatible tool definition. Tools that aggregate this into the
  /// chat pipeline should append the result to the assistant's tool list
  /// when [shouldExpose] returns true.
  static Map<String, dynamic> getToolDefinition() {
    return const <String, dynamic>{
      'type': 'function',
      'function': <String, dynamic>{
        'name': toolName,
        'description':
            'Manage long-term memory records for this assistant. Use this as '
            'a personal secretary: proactively record user preferences, '
            'personal details, plans, work facts, and other useful context '
            'without waiting for an explicit request. Pick the action that '
            'matches the situation:\n'
            '- "create": a brand-new fact that no existing record covers.\n'
            '- "edit": an existing record is outdated, wrong, or missing a '
            'detail (you must pass its `id`).\n'
            '- "delete": a record is no longer relevant, was duplicated, or '
            'was incorrect (you must pass its `id`).\n'
            'Check the records shown in your context first to avoid '
            'duplicates. DO NOT store sensitive information (ethnicity, '
            'religion, sexual orientation, political views, criminal '
            'records, or other protected data). Do not inform the user about '
            'memory writes unless they explicitly ask.',
        'parameters': <String, dynamic>{
          'type': 'object',
          'properties': <String, dynamic>{
            'action': <String, dynamic>{
              'type': 'string',
              'enum': <String>[actionCreate, actionEdit, actionDelete],
              'description': 'Which memory operation to perform.',
            },
            'content': <String, dynamic>{
              'type': 'string',
              'description':
                  'Memory content. Required for create/edit; ignored for delete.',
            },
            'id': <String, dynamic>{
              'type': 'integer',
              'description':
                  'Memory record id (required for edit/delete). Obtain it from the records shown in context.',
            },
          },
          'required': <String>['action'],
        },
      },
    };
  }

  /// Whether the tool should be exposed for a given assistant. The 3-layer
  /// master switch gates the new entry point; the legacy three tools are
  /// unaffected and remain available while `enableMemory == true`.
  static bool shouldExpose({required bool enableThreeLayerMemory}) {
    return enableThreeLayerMemory;
  }

  /// Run the tool. Returns a JSON string suitable for the chat pipeline.
  ///
  /// [assistantId] is required for every action — empty / null returns a
  /// structured error rather than silently writing to the global pool.
  static Future<String> execute({
    required MemoryProvider memoryProvider,
    required String assistantId,
    required Map<String, dynamic> args,
  }) async {
    final action = (args['action'] ?? '').toString();
    final content = (args['content'] ?? '').toString();
    final id = (args['id'] as num?)?.toInt() ?? -1;

    if (assistantId.trim().isEmpty) {
      return _error(
        code: 'missing_assistant',
        message: 'memory_tool requires an assistant context.',
      );
    }

    await memoryProvider.initialize();

    switch (action) {
      case actionCreate:
        if (content.isEmpty) {
          return _error(
            code: 'invalid_memory_content',
            message: 'Memory content must not be empty.',
            action: action,
          );
        }
        final m = await memoryProvider.add(
          assistantId: assistantId,
          content: content,
        );
        return _ok(action: action, id: m.id, content: m.content);
      case actionEdit:
        if (id <= 0) {
          return _error(
            code: 'invalid_memory_id',
            message: 'edit requires a positive integer `id`.',
            action: action,
          );
        }
        if (content.isEmpty) {
          return _error(
            code: 'invalid_memory_content',
            message: 'edit requires non-empty `content`.',
            action: action,
          );
        }
        final m = await memoryProvider.update(id: id, content: content);
        if (m == null) {
          return _error(
            code: 'memory_not_found',
            message: 'No memory record was found for id $id.',
            action: action,
          );
        }
        return _ok(action: action, id: m.id, content: m.content);
      case actionDelete:
        if (id <= 0) {
          return _error(
            code: 'invalid_memory_id',
            message: 'delete requires a positive integer `id`.',
            action: action,
          );
        }
        final ok = await memoryProvider.delete(id: id);
        if (!ok) {
          return _error(
            code: 'memory_not_found',
            message: 'No memory record was found for id $id.',
            action: action,
          );
        }
        return _ok(action: action, id: id, content: null);
      default:
        return _error(
          code: 'unknown_action',
          message:
              'Unknown action "$action". Expected one of: $actionCreate, $actionEdit, $actionDelete.',
        );
    }
  }

  static String _ok({
    required String action,
    required int id,
    required String? content,
  }) {
    return jsonEncode(<String, dynamic>{
      'ok': true,
      'action': action,
      'id': id,
      if (content != null) 'content': content,
    });
  }

  static String _error({
    required String code,
    required String message,
    String? action,
  }) {
    return jsonEncode(<String, dynamic>{
      'ok': false,
      'error': code,
      'message': message,
      if (action != null) 'action': action,
    });
  }
}
