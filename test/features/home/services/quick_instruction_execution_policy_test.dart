import 'package:Cuplivo/core/models/quick_instruction.dart';
import 'package:Cuplivo/features/home/services/quick_instruction_execution_policy.dart';
import 'package:flutter_test/flutter_test.dart';

QuickInstruction _instruction(String title, QuickInstructionToolPolicy policy) {
  return QuickInstruction(
    id: title,
    title: title,
    prompt: title,
    placement: QuickInstructionPlacement.systemPrompt,
    toolPolicy: policy,
  );
}

QuickInstructionInvocationSnapshot _snapshot(
  String title,
  QuickInstructionToolPolicy policy,
) {
  return QuickInstructionInvocationSnapshot.fromInstruction(
    QuickInstruction(
      id: title,
      title: title,
      prompt: title,
      placement: QuickInstructionPlacement.beforeUserMessage,
      toolPolicy: policy,
    ),
    order: 0,
  );
}

void main() {
  group('QuickInstructionExecutionPolicy tools', () {
    test('disabled tools are merged as a union with source names', () {
      final policy = QuickInstructionExecutionPolicy.fromSources(
        systemInstructions: <QuickInstruction>[
          _instruction(
            'System safety',
            QuickInstructionToolPolicy(
              enabled: true,
              disabledLocalToolIds: const ['calendar_query'],
              disabledFilesystemToolNames: const ['write_file'],
            ),
          ),
        ],
        anchorInvocations: <QuickInstructionInvocationSnapshot>[
          _snapshot(
            'Turn safety',
            QuickInstructionToolPolicy(
              enabled: true,
              disabledMcpServerIds: const ['server-1'],
              shellDisabled: true,
            ),
          ),
        ],
      );

      expect(
        policy
            .checkTool(
              kind: QuickInstructionToolKind.local,
              id: 'calendar_query',
            )
            ?.instructionTitles,
        ['System safety'],
      );
      expect(
        policy
            .checkTool(kind: QuickInstructionToolKind.mcpServer, id: 'server-1')
            ?.instructionTitles,
        ['Turn safety'],
      );
      expect(
        policy
            .checkTool(
              kind: QuickInstructionToolKind.filesystem,
              id: 'write_file',
            )
            ?.reason,
        'filesystem_tool_disabled',
      );
      expect(
        policy
            .checkTool(kind: QuickInstructionToolKind.shell, id: 'shell')
            ?.reason,
        'shell_disabled',
      );
      expect(
        policy.checkTool(
          kind: QuickInstructionToolKind.local,
          id: 'calendar_create',
        ),
        isNull,
      );
    });

    test('disabled policy blocks are ignored', () {
      final policy = QuickInstructionExecutionPolicy.fromSources(
        systemInstructions: <QuickInstruction>[
          _instruction(
            'Inactive',
            QuickInstructionToolPolicy(
              disabledLocalToolIds: const ['calendar_query'],
            ),
          ),
        ],
        anchorInvocations: const <QuickInstructionInvocationSnapshot>[],
      );

      expect(policy.isEmpty, isTrue);
    });
  });

  group('QuickInstructionExecutionPolicy shell commands', () {
    test('commands not matched by a block-list remain allowed', () {
      final policy = QuickInstructionExecutionPolicy.fromSources(
        systemInstructions: <QuickInstruction>[
          _instruction(
            'Push block-list',
            QuickInstructionToolPolicy(
              enabled: true,
              shellBlockPatterns: const ['git push *'],
            ),
          ),
        ],
        anchorInvocations: const <QuickInstructionInvocationSnapshot>[],
      );

      expect(policy.checkShellCommand('git status'), isNull);
      expect(policy.checkShellCommand('echo ok'), isNull);
      final rejection = policy.checkShellCommand('git push origin main');
      expect(rejection?.reason, 'shell_command_blocked');
      expect(rejection?.instructionTitles, ['Push block-list']);
    });

    test('a trailing star blocks a command with or without arguments', () {
      final policy = QuickInstructionExecutionPolicy.fromSources(
        systemInstructions: <QuickInstruction>[
          _instruction(
            'Git block-list',
            QuickInstructionToolPolicy(
              enabled: true,
              shellBlockPatterns: const ['git *'],
            ),
          ),
        ],
        anchorInvocations: const <QuickInstructionInvocationSnapshot>[],
      );

      expect(policy.checkShellCommand('git'), isNotNull);
      expect(policy.checkShellCommand('git status'), isNotNull);
    });

    test('block-lists from multiple instructions are merged', () {
      final policy = QuickInstructionExecutionPolicy.fromSources(
        systemInstructions: <QuickInstruction>[
          _instruction(
            'Push block',
            QuickInstructionToolPolicy(
              enabled: true,
              shellBlockPatterns: const ['git push *'],
            ),
          ),
        ],
        anchorInvocations: <QuickInstructionInvocationSnapshot>[
          _snapshot(
            'Delete block',
            QuickInstructionToolPolicy(
              enabled: true,
              shellBlockPatterns: const ['rm *'],
            ),
          ),
        ],
      );

      expect(policy.checkShellCommand('git push origin main'), isNotNull);
      expect(policy.checkShellCommand('rm temp.txt'), isNotNull);
      expect(policy.checkShellCommand('git status'), isNull);
    });

    test('walks pipelines, chains, substitutions and shell -c bodies', () {
      final policy = QuickInstructionExecutionPolicy.fromSources(
        systemInstructions: <QuickInstruction>[
          _instruction(
            'Network block',
            QuickInstructionToolPolicy(
              enabled: true,
              shellBlockPatterns: const ['curl *'],
            ),
          ),
          _instruction(
            'Delete block',
            QuickInstructionToolPolicy(
              enabled: true,
              shellBlockPatterns: const ['rm *'],
            ),
          ),
        ],
        anchorInvocations: const <QuickInstructionInvocationSnapshot>[],
      );

      expect(
        policy.checkShellCommand('printf x | curl https://example.com'),
        isNotNull,
      );
      expect(policy.checkShellCommand('echo ok && rm temp.txt'), isNotNull);
      expect(
        policy.checkShellCommand(r'echo $(curl https://example.com)'),
        isNotNull,
      );
      expect(
        policy.checkShellCommand('sh -c "curl https://example.com"'),
        isNotNull,
      );
    });

    test('allows commands when every command block-list is empty', () {
      final policy = QuickInstructionExecutionPolicy.fromSources(
        systemInstructions: <QuickInstruction>[
          _instruction(
            'Other tool rules',
            QuickInstructionToolPolicy(
              enabled: true,
              disabledLocalToolIds: const ['calendar_query'],
            ),
          ),
        ],
        anchorInvocations: const <QuickInstructionInvocationSnapshot>[],
      );

      expect(policy.checkShellCommand(''), isNull);
      expect(policy.checkShellCommand('echo "unterminated'), isNull);
    });

    test('rejects empty or incomplete Bash analysis when rules exist', () {
      final policy = QuickInstructionExecutionPolicy.fromSources(
        systemInstructions: <QuickInstruction>[
          _instruction(
            'Command rules',
            QuickInstructionToolPolicy(
              enabled: true,
              shellBlockPatterns: const ['dangerous *'],
            ),
          ),
        ],
        anchorInvocations: const <QuickInstructionInvocationSnapshot>[],
      );

      expect(
        policy.checkShellCommand('')?.reason,
        'shell_command_incomplete_analysis',
      );
      expect(policy.checkShellCommand('echo "unterminated'), isNotNull);
    });
  });
}
