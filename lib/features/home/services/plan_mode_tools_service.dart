import 'dart:convert';

import 'package:flutter/widgets.dart';
import 'package:provider/provider.dart';

import '../../../core/models/plan_mode.dart';
import '../../../core/providers/plan_mode_provider.dart';
import '../../../core/services/api/chat_api_service.dart';

class PlanToolNames {
  static const create = 'create_plan';
  static const replace = 'replace_plan';
  static const updateItem = 'update_plan_item';
  static const setItemStatus = 'set_plan_item_status';
  static const addItem = 'add_plan_item';
  static const removeItem = 'remove_plan_item';
  static const requestApproval = 'request_plan_approval';

  static const all = <String>{
    create,
    replace,
    updateItem,
    setItemStatus,
    addItem,
    removeItem,
    requestApproval,
  };
}

/// Hidden built-in tools used only while a conversation is in Plan Mode.
class PlanModeToolsService {
  PlanModeToolsService._();

  static Map<String, dynamic> _planSchema(String name, String description) => {
    'type': 'function',
    'function': {
      'name': name,
      'description': description,
      'parameters': {
        'type': 'object',
        'properties': {
          'title': {
            'type': 'string',
            'description': 'Short title for the overall plan.',
          },
          'items': {
            'type': 'array',
            'minItems': 1,
            'maxItems': 20,
            'items': {
              'type': 'object',
              'properties': {
                'title': {
                  'type': 'string',
                  'description': 'Short action-oriented task title.',
                },
                'description': {
                  'type': 'string',
                  'description':
                      'One or two concise sentences explaining what this task will accomplish.',
                },
              },
              'required': ['title', 'description'],
            },
          },
        },
        'required': ['title', 'items'],
      },
    },
  };

  static List<Map<String, dynamic>> definitionsFor(ConversationPlan plan) {
    if (!plan.active) return const <Map<String, dynamic>>[];
    final management = <Map<String, dynamic>>[
      _planSchema(
        PlanToolNames.replace,
        'Replace the entire current plan only when a substantial re-plan is necessary. Prefer local edits for small changes.',
      ),
      {
        'type': 'function',
        'function': {
          'name': PlanToolNames.updateItem,
          'description':
              'Update only one existing plan item. Do not rewrite unrelated items.',
          'parameters': {
            'type': 'object',
            'properties': {
              'item_id': {'type': 'string'},
              'title': {'type': 'string'},
              'description': {'type': 'string'},
            },
            'required': ['item_id'],
          },
        },
      },
      {
        'type': 'function',
        'function': {
          'name': PlanToolNames.setItemStatus,
          'description':
              'Update the execution status of exactly one plan item. Mark an item in_progress before working on it, completed after success, or error after failure.',
          'parameters': {
            'type': 'object',
            'properties': {
              'item_id': {'type': 'string'},
              'status': {
                'type': 'string',
                'enum': ['pending', 'in_progress', 'completed', 'error'],
              },
            },
            'required': ['item_id', 'status'],
          },
        },
      },
      {
        'type': 'function',
        'function': {
          'name': PlanToolNames.addItem,
          'description':
              'Add a new task to the current plan when execution discovers a necessary extra step.',
          'parameters': {
            'type': 'object',
            'properties': {
              'title': {'type': 'string'},
              'description': {'type': 'string'},
              'after_index': {'type': 'integer', 'minimum': -1},
            },
            'required': ['title', 'description'],
          },
        },
      },
      {
        'type': 'function',
        'function': {
          'name': PlanToolNames.removeItem,
          'description':
              'Remove one obsolete plan item. Do not remove unrelated tasks.',
          'parameters': {
            'type': 'object',
            'properties': {
              'item_id': {'type': 'string'},
            },
            'required': ['item_id'],
          },
        },
      },
      {
        'type': 'function',
        'function': {
          'name': PlanToolNames.requestApproval,
          'description':
              'Ask the user to approve the current plan after planning or revising it. Do not begin execution before approval.',
          'parameters': {'type': 'object', 'properties': <String, dynamic>{}},
        },
      },
    ];
    if (!plan.hasPlan) {
      return <Map<String, dynamic>>[
        _planSchema(
          PlanToolNames.create,
          'Create the initial execution plan for the user request. This is the first action in Plan Mode.',
        ),
        ...management,
      ];
    }
    return management;
  }

  static String instructionFor(ConversationPlan plan) {
    final items = plan.items
        .map(
          (item) =>
              '- ${item.id} [${planItemStatusToString(item.status)}] ${item.title}: ${item.description}',
        )
        .join('\n');

    if (!plan.hasPlan) {
      return '''
<cuplivo_plan_mode>
Plan Mode is active. Before doing anything else for the user's task, you MUST call the hidden create_plan tool. Do not answer with normal text and do not call any other tool before create_plan. Make a practical ordered plan with concise task titles and one or two sentence descriptions. The user will approve or reject it before execution.
</cuplivo_plan_mode>''';
    }

    final phaseText = switch (plan.phase) {
      PlanPhase.planning =>
        'The plan is not approved. You may discuss, research, or locally revise it, but MUST NOT execute the plan as a task. When the revised plan is ready, call request_plan_approval.',
      PlanPhase.awaitingApproval =>
        'The plan is awaiting user approval. Do not execute it until the approval tool result says approved.',
      PlanPhase.executing =>
        'The plan is approved. Execute it in order. Before working on an item call set_plan_item_status(in_progress); after success mark completed; after failure mark error. Keep at most one item in_progress. Change only plan items that genuinely need changing. When all planned work is finished, provide the final answer.',
      PlanPhase.completed =>
        'The current plan is completed. You may answer normally. If the user extends the task, add or revise only the necessary plan items and continue using Plan Mode.',
    };

    return '''
<cuplivo_plan_mode>
Plan Mode is active.
$phaseText
Current plan title: ${plan.title}
Current plan items:
$items
</cuplivo_plan_mode>''';
  }

  static bool handles(String name) => PlanToolNames.all.contains(name);

  static List<({String title, String description})> _parseItems(dynamic raw) {
    if (raw is! List) return const [];
    final out = <({String title, String description})>[];
    for (final value in raw) {
      if (value is! Map) continue;
      final title = (value['title'] ?? '').toString().trim();
      final description = (value['description'] ?? '').toString().trim();
      if (title.isEmpty) continue;
      out.add((title: title, description: description));
      if (out.length >= 20) break;
    }
    return out;
  }

  static String _snapshot(ConversationPlan? plan, {String? decision}) {
    return jsonEncode({
      'ok': plan != null,
      if (decision != null) 'decision': decision,
      if (decision == 'approved')
        'instruction': 'The user approved the plan. Execute it in order now. Before each item call set_plan_item_status with in_progress, then mark completed after success or error after failure. Keep at most one item in_progress. When the plan is finished, provide the final answer.',
      if (decision == 'rejected')
        'instruction': 'The user rejected this plan. Stop this turn now; do not execute tasks or emit an additional answer.',
      if (plan != null) ...{
        'title': plan.title,
        'phase': planPhaseToString(plan.phase),
        'items': [
          for (final item in plan.items)
            {
              'id': item.id,
              'title': item.title,
              'description': item.description,
              'status': planItemStatusToString(item.status),
            },
        ],
      },
    });
  }

  static Future<String> handle({
    required BuildContext context,
    required String conversationId,
    required String name,
    required Map<String, dynamic> arguments,
  }) async {
    final store = context.read<PlanModeProvider>();
    await store.initialize();
    final current = store.planFor(conversationId);
    if (current == null || !current.active) {
      return jsonEncode({'ok': false, 'error': 'plan_mode_inactive'});
    }

    switch (name) {
      case PlanToolNames.create:
      case PlanToolNames.replace:
        final items = _parseItems(arguments['items']);
        if (items.isEmpty) {
          return jsonEncode({'ok': false, 'error': 'plan_items_required'});
        }
        final plan = await store.createOrReplacePlan(
          conversationId: conversationId,
          title: (arguments['title'] ?? '').toString(),
          items: items,
          awaitingApproval: true,
        );
        final decision = await store.waitForApproval(conversationId);
        return _snapshot(
          store.planFor(conversationId) ?? plan,
          decision: decision == PlanApprovalDecision.approved
              ? 'approved'
              : 'rejected',
        );

      case PlanToolNames.requestApproval:
        if (current.items.isEmpty) {
          return jsonEncode({'ok': false, 'error': 'plan_is_empty'});
        }
        await store.markAwaitingApproval(conversationId);
        final decision = await store.waitForApproval(conversationId);
        return _snapshot(
          store.planFor(conversationId),
          decision: decision == PlanApprovalDecision.approved
              ? 'approved'
              : 'rejected',
        );

      case PlanToolNames.updateItem:
        final updated = await store.updateItem(
          conversationId: conversationId,
          itemId: (arguments['item_id'] ?? '').toString(),
          title: arguments['title']?.toString(),
          description: arguments['description']?.toString(),
          requireApproval: current.phase != PlanPhase.executing,
        );
        return _snapshot(updated);

      case PlanToolNames.setItemStatus:
        if (current.phase != PlanPhase.executing &&
            current.phase != PlanPhase.completed) {
          return jsonEncode({'ok': false, 'error': 'plan_not_approved'});
        }
        final status = planItemStatusFromString(
          arguments['status']?.toString(),
        );
        final updated = await store.setItemStatus(
          conversationId: conversationId,
          itemId: (arguments['item_id'] ?? '').toString(),
          status: status,
        );
        return _snapshot(updated);

      case PlanToolNames.addItem:
        final rawAfter = arguments['after_index'];
        final updated = await store.addItem(
          conversationId: conversationId,
          title: (arguments['title'] ?? '').toString(),
          description: (arguments['description'] ?? '').toString(),
          afterIndex: rawAfter is num ? rawAfter.toInt() : null,
          requireApproval: current.phase != PlanPhase.executing,
        );
        return _snapshot(updated);

      case PlanToolNames.removeItem:
        final updated = await store.removeItem(
          conversationId: conversationId,
          itemId: (arguments['item_id'] ?? '').toString(),
          requireApproval: current.phase != PlanPhase.executing,
        );
        return _snapshot(updated);
    }

    return jsonEncode({'ok': false, 'error': 'unknown_plan_tool'});
  }

  static ToolCallHandler wrapHandler({
    required BuildContext context,
    required String conversationId,
    ToolCallHandler? fallback,
  }) {
    return (name, arguments, {String? toolCallId}) async {
      if (handles(name)) {
        return handle(
          context: context,
          conversationId: conversationId,
          name: name,
          arguments: arguments,
        );
      }
      if (fallback != null) {
        return fallback(name, arguments, toolCallId: toolCallId);
      }
      return jsonEncode({'ok': false, 'error': 'unknown_tool', 'tool': name});
    };
  }
}
