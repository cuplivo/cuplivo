import 'package:flutter_test/flutter_test.dart';

import 'package:Cuplivo/core/models/tool_permission_mode.dart';
import 'package:Cuplivo/core/models/workspace_binding.dart';
import 'package:Cuplivo/features/subagent/services/subagent_rules.dart';

void main() {
  group('buildChildSpec', () {
    test('copies the parent binding and nothing else', () {
      final spec = buildChildSpec(
        parentConversationId: 'parent-1',
        parentExtras: <String, dynamic>{
          WorkspaceBinding.keyId: 'ws-9',
          WorkspaceBinding.keyCwd: '/work/app',
          WorkspaceBinding.keyToolsUsed: true,
          ToolPermissionMode.extrasKey: ToolPermissionMode.fullAccess.name,
          ToolPermissionMode.allowAllExtrasKey: true,
          'subagent.depth': 0,
        },
      );

      expect(spec.extras[WorkspaceBinding.keyId], 'ws-9');
      expect(spec.extras[WorkspaceBinding.keyCwd], '/work/app');
      // A grant is per conversation; the child never inherits one.
      expect(spec.extras.keys, isNot(contains(ToolPermissionMode.extrasKey)));
      expect(
        spec.extras.keys,
        isNot(contains(ToolPermissionMode.allowAllExtrasKey)),
      );
      // `tools_used` is a fact about the parent's conversation, not an
      // inheritance.
      expect(spec.extras.keys, isNot(contains(WorkspaceBinding.keyToolsUsed)));
    });

    test('an unbound parent yields an unbound child', () {
      final spec = buildChildSpec(
        parentConversationId: 'parent-1',
        parentExtras: const <String, dynamic>{},
      );

      expect(spec.extras.keys, isNot(contains(WorkspaceBinding.keyId)));
      expect(spec.extras.keys, isNot(contains(WorkspaceBinding.keyCwd)));
      expect(spec.extras[SubagentExtrasKeys.parent], 'parent-1');
      expect(spec.extras[SubagentExtrasKeys.root], 'parent-1');
      expect(spec.extras[SubagentExtrasKeys.depth], 1);
      expect(
        spec.extras[SubagentExtrasKeys.target],
        SubagentExtrasKeys.generalTarget,
      );
    });

    test('depth accumulates and the root stays the first conversation', () {
      final first = buildChildSpec(
        parentConversationId: 'parent-1',
        parentExtras: const <String, dynamic>{},
      );
      final second = buildChildSpec(
        parentConversationId: 'child-1',
        parentExtras: first.extras,
      );

      expect(first.depth, 1);
      expect(second.depth, 2);
      // A grandchild still names the conversation a user recognises.
      expect(second.extras[SubagentExtrasKeys.root], 'parent-1');
      expect(second.extras[SubagentExtrasKeys.parent], 'child-1');
    });
  });

  group('mayDelegate', () {
    test('an ordinary conversation may delegate', () {
      expect(mayDelegate(const <String, dynamic>{}), isTrue);
    });

    test('a conversation at the limit may not', () {
      expect(
        mayDelegate(const <String, dynamic>{SubagentExtrasKeys.depth: 1}),
        isFalse,
      );
    });

    test('a junk depth reads as an ordinary conversation', () {
      expect(
        mayDelegate(const <String, dynamic>{SubagentExtrasKeys.depth: 'x'}),
        isTrue,
      );
      expect(
        parentDepth(const <String, dynamic>{SubagentExtrasKeys.depth: -3}),
        0,
      );
    });
  });

  group('childTitle', () {
    test('the model label wins', () {
      expect(childTitle(label: '跑测试', task: 'run the tests, then fix'), '跑测试');
    });

    test('a missing label falls back to the task’s first sentence', () {
      expect(childTitle(label: null, task: '修掉三个用例。别改公开接口。'), '修掉三个用例');
      // Bounded by the same budget as a label: one ellipsised sidebar line, in
      // any language.
      expect(
        childTitle(label: '   ', task: 'Fix the three red tests in test/auth'),
        'Fix the three red te…',
      );
    });

    test('a long fallback is bounded instead of wrapping the sidebar', () {
      final title = childTitle(
        label: null,
        task: 'a task description that runs on and on without a stop',
      );
      expect(title.length, lessThanOrEqualTo(21));
      expect(title.endsWith('…'), isTrue);
    });

    test('a long label is bounded too', () {
      final title = childTitle(label: 'x' * 40, task: 'ignored');
      expect(title.length, lessThanOrEqualTo(21));
      expect(title.endsWith('…'), isTrue);
    });
  });

  group('mail text', () {
    test('names the sender for the model, from either side', () {
      expect(
        mailToChildText('  use YAML '),
        'The delegator sent a message: use YAML',
      );
      expect(
        mailToParentText(label: 'auth', text: ' found it '),
        'Subagent auth sent a message: found it',
      );
      expect(
        mailToParentText(label: '  ', text: 'x'),
        'The subagent sent a message: x',
      );
    });
  });

  group('resultBrief', () {
    test('carries the outcome, the child text and the conversation hint', () {
      final brief = resultBrief(
        label: '跑测试',
        outcome: 'completed',
        text: '三个用例都过了。',
        childConversationId: 'child-7',
      );

      expect(brief, contains('跑测试'));
      expect(brief, contains('completed'));
      expect(brief, contains('三个用例都过了。'));
      expect(brief, contains('child-7'));
      expect(brief, contains('Do not claim you did this work yourself.'));
    });

    test('an empty closing text does not leave a blank paragraph', () {
      final brief = resultBrief(
        label: '跑测试',
        outcome: 'failed: upstream_timeout',
        childConversationId: 'child-7',
      );

      expect(brief, contains('failed: upstream_timeout'));
      expect(brief.split('\n').where((line) => line.trim().isEmpty), isEmpty);
    });
  });
}
