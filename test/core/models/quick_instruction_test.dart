import 'package:Cuplivo/core/models/quick_instruction.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('QuickInstruction', () {
    test('new items use the user-before one-shot defaults', () {
      final instruction = QuickInstruction(
        id: 'instruction-1',
        title: 'Focus',
        prompt: 'Answer only the current question.',
      );

      expect(
        instruction.placement,
        QuickInstructionPlacement.beforeUserMessage,
      );
      expect(instruction.triggerMode, QuickInstructionTriggerMode.oneShot);
      expect(instruction.retainInHistory, isTrue);
      expect(instruction.toolPolicy.enabled, isFalse);
    });

    test('legacy JSON without advanced fields remains a system injection', () {
      final instruction = QuickInstruction.fromJson({
        'id': 'legacy-injection',
        'title': 'Legacy',
        'prompt': 'Legacy system prompt',
        'group': 'Original group',
      });

      expect(instruction.placement, QuickInstructionPlacement.systemPrompt);
      expect(instruction.triggerMode, QuickInstructionTriggerMode.oneShot);
      expect(instruction.retainInHistory, isTrue);
      expect(instruction.toolPolicy.enabled, isFalse);
    });

    test('snapshot round-trip preserves the complete frozen invocation', () {
      final mutableLocalIds = <String>['calendar_query'];
      final instruction = QuickInstruction(
        id: 'instruction-2',
        title: 'Restricted',
        prompt: 'Use only safe commands.',
        group: 'Safety',
        placement: QuickInstructionPlacement.afterUserMessage,
        triggerMode: QuickInstructionTriggerMode.persistent,
        retainInHistory: false,
        toolPolicy: QuickInstructionToolPolicy(
          enabled: true,
          disabledLocalToolIds: mutableLocalIds,
          disabledMcpServerIds: const <String>['mcp-1'],
          disabledFilesystemToolNames: const <String>['write_file'],
          shellBlockPatterns: const <String>['git push *'],
        ),
      );
      final snapshot = QuickInstructionInvocationSnapshot.fromInstruction(
        instruction,
        order: 7,
      );
      mutableLocalIds.add('calendar_create');

      final decoded = QuickInstructionInvocationSnapshot.decodeList(
        QuickInstructionInvocationSnapshot.encodeList(
          <QuickInstructionInvocationSnapshot>[snapshot],
        ),
      ).single;

      expect(decoded.instructionId, 'instruction-2');
      expect(decoded.title, 'Restricted');
      expect(decoded.prompt, 'Use only safe commands.');
      expect(decoded.placement, QuickInstructionPlacement.afterUserMessage);
      expect(decoded.triggerMode, QuickInstructionTriggerMode.persistent);
      expect(decoded.retainInHistory, isFalse);
      expect(decoded.order, 7);
      expect(decoded.toolPolicy.disabledLocalToolIds, ['calendar_query']);
      expect(decoded.toolPolicy.disabledMcpServerIds, ['mcp-1']);
      expect(decoded.toolPolicy.disabledFilesystemToolNames, ['write_file']);
      expect(decoded.toolPolicy.shellBlockPatterns, ['git push *']);
      expect(
        () => decoded.toolPolicy.disabledLocalToolIds.add('another'),
        throwsUnsupportedError,
      );
    });

    test('malformed snapshot JSON is ignored instead of breaking history', () {
      expect(
        QuickInstructionInvocationSnapshot.decodeList('{not json'),
        isEmpty,
      );
      expect(
        QuickInstructionInvocationSnapshot.decodeList({'wrong': 'shape'}),
        isEmpty,
      );
    });
  });
}
