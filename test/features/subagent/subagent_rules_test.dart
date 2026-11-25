import 'package:flutter_test/flutter_test.dart';

import 'package:Cuplivo/core/models/assistant.dart';
import 'package:Cuplivo/core/models/tool_permission_mode.dart';
import 'package:Cuplivo/core/models/workspace_binding.dart';
import 'package:Cuplivo/features/subagent/services/subagent_rules.dart';
import 'package:Cuplivo/features/subagent/services/subagent_target.dart';
import 'package:Cuplivo/utils/single_line_text.dart';

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
        levels: 1,
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
        levels: 1,
      );

      expect(spec.extras.keys, isNot(contains(WorkspaceBinding.keyId)));
      expect(spec.extras.keys, isNot(contains(WorkspaceBinding.keyCwd)));
      expect(spec.extras[SubagentExtrasKeys.parent], 'parent-1');
      expect(spec.extras[SubagentExtrasKeys.root], 'parent-1');
      expect(spec.extras[SubagentExtrasKeys.depth], 1);
      expect(spec.extras[SubagentExtrasKeys.levels], 1);
      expect(
        spec.extras[SubagentExtrasKeys.target],
        SubagentExtrasKeys.generalTarget,
      );
    });

    test('depth accumulates and the root stays the first conversation', () {
      final first = buildChildSpec(
        parentConversationId: 'parent-1',
        parentExtras: const <String, dynamic>{},
        levels: 2,
      );
      final second = buildChildSpec(
        parentConversationId: 'child-1',
        parentExtras: first.extras,
        levels: 1,
      );

      expect(first.depth, 1);
      expect(second.depth, 2);
      // The budget travels with the conversation: the grandchild got what the
      // child had left, not a number recomputed from the current settings.
      expect(first.extras[SubagentExtrasKeys.levels], 2);
      expect(second.extras[SubagentExtrasKeys.levels], 1);
      // A grandchild still names the conversation a user recognises.
      expect(second.extras[SubagentExtrasKeys.root], 'parent-1');
      expect(second.extras[SubagentExtrasKeys.parent], 'child-1');
    });

    test(
      'a named target is stored as one value, exactly as the model sent it',
      () {
        final target = SubagentTarget.assistant('a-2');
        final spec = buildChildSpec(
          parentConversationId: 'parent-1',
          parentExtras: const <String, dynamic>{},
          target: target.encode(),
          levels: 1,
        );

        // One key, not two: nothing has to join an id to a kind.
        expect(spec.extras[SubagentExtrasKeys.target], 'assistant:a-2');
        // A target contributes no grant and no workspace of its own.
        expect(spec.extras.keys, isNot(contains(ToolPermissionMode.extrasKey)));
        expect(spec.extras.keys, isNot(contains(WorkspaceBinding.keyId)));
      },
    );
  });

  group('delegableAssistants', () {
    Assistant assistant(
      String id, {
      String name = 'A',
      List<String>? targets,
    }) => Assistant(id: id, name: name, subagentTargetIds: targets ?? const []);

    test('an assistant with nothing selected offers nothing', () {
      // The default is "none": no target parameter, no token spent, byte-for-byte
      // the schema that shipped before targets existed.
      final delegator = assistant('self');
      expect(
        delegableAssistants(
          delegator: delegator,
          all: <Assistant>[delegator, assistant('a'), assistant('b')],
        ),
        isEmpty,
      );
    });

    test('only the selected ones, never the delegator itself', () {
      final self = assistant('self', targets: <String>['self', 'a']);
      final offered = delegableAssistants(
        delegator: self,
        all: <Assistant>[assistant('a'), self, assistant('b')],
      );
      expect(offered.map((a) => a.id), <String>['a']);
    });

    test('a deleted assistant is skipped without disturbing the rest', () {
      final self = assistant('self', targets: <String>['gone', 'b']);
      final offered = delegableAssistants(
        delegator: self,
        all: <Assistant>[self, assistant('b')],
      );
      expect(offered.map((a) => a.id), <String>['b']);
    });

    test('order follows the app, not the selection', () {
      final self = assistant('self', targets: <String>['c', 'a', 'b']);
      final offered = delegableAssistants(
        delegator: self,
        all: <Assistant>[assistant('a'), assistant('b'), assistant('c')],
      );
      expect(offered.map((a) => a.id), <String>['a', 'b', 'c']);
    });
  });

  group('targetMenuLine', () {
    test('carries the value to emit, the name and what it is for', () {
      final line = targetMenuLine(
        Assistant(id: 'a-1', name: 'SQL 专家', description: '把需求写成 SQL\n并解释执行计划'),
      );

      // The value the model must copy back comes first, unchanged.
      expect(line, startsWith('assistant:a-1 — '));
      expect(line, contains('SQL 专家'));
      // Folded to one line: a menu entry is one line, and a newline would break it.
      expect(line, isNot(contains('\n')));
      expect(line, contains('把需求写成 SQL 并解释执行计划'));
    });

    test('an empty description leaves the name alone', () {
      expect(
        targetMenuLine(Assistant(id: 'a-1', name: '翻译官')),
        'assistant:a-1 — 翻译官',
      );
    });

    test('a nameless assistant is named by its id rather than by nothing', () {
      expect(
        targetMenuLine(Assistant(id: 'a-1', name: '  ')),
        'assistant:a-1 — a-1',
      );
    });
  });

  group('oneLineText', () {
    test('flattens newlines and collapses runs of whitespace', () {
      expect(oneLineText('  a\n\nb\tc  '), 'a b c');
    });

    test('bounds a long description with an ellipsis', () {
      final text = oneLineText('x' * 200, max: 20);
      expect(text.length, 21);
      expect(text.endsWith('…'), isTrue);
    });

    test('never tears a surrogate pair at the cut', () {
      // Each emoji is two UTF-16 code units; a cut inside one would leave a
      // lone surrogate, which jsonEncode refuses.
      final text = oneLineText('😀' * 20, max: 5);
      expect(text.length, lessThanOrEqualTo(6));
      expect(() => text.runes.toList(), returnsNormally);
    });
  });

  group('delegation depth', () {
    Assistant assistant({int depth = 1, String id = 'a'}) =>
        Assistant(id: id, name: id, subagentDepth: depth);

    test('a root conversation carries its assistant ceiling', () {
      // Depth counts levels below the conversation, the first child included.
      expect(
        delegationLevels(
          delegator: assistant(depth: 1),
          extras: const <String, dynamic>{},
        ),
        1,
      );
      expect(
        delegationLevels(
          delegator: assistant(depth: 3),
          extras: const <String, dynamic>{},
        ),
        3,
      );
    });

    test('a child reads the number it was handed, not a fresh lookup', () {
      // An assistant edited after the chain started must not re-price it.
      final extras = <String, dynamic>{SubagentExtrasKeys.levels: 2};
      expect(
        delegationLevels(delegator: assistant(depth: 1), extras: extras),
        2,
      );
    });

    test('the child gets one level less, capped by its own assistant', () {
      // Same assistant throughout: 3 asks for three levels, and gets them.
      expect(childLevels(parentLevels: 3, child: assistant(depth: 3)), 2);
      expect(childLevels(parentLevels: 2, child: assistant(depth: 3)), 1);
      expect(childLevels(parentLevels: 1, child: assistant(depth: 3)), 0);
      // A shallower target stops the chain where its own setting says — one
      // level below itself — and a deeper one cannot raise what is left.
      expect(childLevels(parentLevels: 3, child: assistant(depth: 1)), 1);
      expect(childLevels(parentLevels: 3, child: assistant(depth: 2)), 2);
    });

    test('a chain of three is reachable with the default of every level', () {
      final self = assistant(depth: 3);
      var levels = delegationLevels(
        delegator: self,
        extras: const <String, dynamic>{},
      );
      final reached = <int>[];
      while (levels >= 1) {
        reached.add(levels);
        levels = childLevels(parentLevels: levels, child: self);
      }
      // Three delegations, then the fourth conversation has nothing left.
      expect(reached, <int>[3, 2, 1]);
      expect(levels, 0);
    });

    test('mayDelegate is the same rule, read at one place', () {
      expect(
        mayDelegate(delegator: assistant(depth: 1), extras: const {}),
        isTrue,
      );
      expect(
        mayDelegate(
          delegator: assistant(depth: 3),
          extras: const <String, dynamic>{SubagentExtrasKeys.levels: 0},
        ),
        isFalse,
      );
    });

    test('a junk budget reads as the assistant ceiling', () {
      expect(
        delegationLevels(
          delegator: assistant(depth: 2),
          extras: const <String, dynamic>{SubagentExtrasKeys.levels: 'x'},
        ),
        2,
      );
      expect(
        parentDepth(const <String, dynamic>{SubagentExtrasKeys.depth: -3}),
        0,
      );
    });

    test('a stored budget above the ceiling is clamped, not obeyed', () {
      expect(
        delegationLevels(
          delegator: assistant(depth: 3),
          extras: const <String, dynamic>{SubagentExtrasKeys.levels: 99},
        ),
        kSubagentDepthMax,
      );
    });
  });

  group('escalation narrows down the chain', () {
    SubagentEscalation chainOf(
      SubagentEscalation inherited,
      SubagentEscalation own,
    ) {
      final spec = buildChildSpec(
        parentConversationId: 'parent-1',
        parentExtras: <String, dynamic>{
          SubagentExtrasKeys.escalation: inherited.name,
        },
        escalation: own,
        levels: 1,
      );
      final stored = spec.extras[SubagentExtrasKeys.escalation] as String;
      return SubagentEscalation.values.firstWhere((v) => v.name == stored);
    }

    test('the stricter of the two wins, in every combination', () {
      // A child cannot grant itself more than the conversation that created it
      // held: deny < ask < allow.
      expect(
        chainOf(SubagentEscalation.allow, SubagentEscalation.allow),
        SubagentEscalation.allow,
      );
      expect(
        chainOf(SubagentEscalation.allow, SubagentEscalation.ask),
        SubagentEscalation.ask,
      );
      expect(
        chainOf(SubagentEscalation.allow, SubagentEscalation.deny),
        SubagentEscalation.deny,
      );
      expect(
        chainOf(SubagentEscalation.ask, SubagentEscalation.allow),
        SubagentEscalation.ask,
      );
      expect(
        chainOf(SubagentEscalation.ask, SubagentEscalation.deny),
        SubagentEscalation.deny,
      );
      expect(
        chainOf(SubagentEscalation.deny, SubagentEscalation.allow),
        SubagentEscalation.deny,
      );
    });

    test('a root conversation has nothing to narrow against', () {
      final spec = buildChildSpec(
        parentConversationId: 'parent-1',
        parentExtras: const <String, dynamic>{},
        escalation: SubagentEscalation.allow,
        levels: 1,
      );
      expect(
        spec.extras[SubagentExtrasKeys.escalation],
        SubagentEscalation.allow.name,
      );
    });

    test('an unreadable chain policy asks, it does not fall back to allow', () {
      // A value this build cannot read is not "no chain": the decision was made
      // by an ancestor, and guessing upward would widen a consent somebody
      // already narrowed. The other reader of this key answers `ask` too.
      for (final broken in <Object?>['always', '', 3, true]) {
        final spec = buildChildSpec(
          parentConversationId: 'parent-1',
          parentExtras: <String, dynamic>{
            SubagentExtrasKeys.escalation: broken,
          },
          escalation: SubagentEscalation.allow,
          levels: 1,
        );
        expect(
          spec.extras[SubagentExtrasKeys.escalation],
          SubagentEscalation.ask.name,
          reason: 'unreadable $broken must not widen the chain',
        );
      }
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
