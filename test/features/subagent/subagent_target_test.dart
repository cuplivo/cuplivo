import 'package:Cuplivo/features/subagent/services/subagent_target.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('the target vocabulary', () {
    test('general round-trips', () {
      final target = SubagentTarget.general();
      expect(target.encode(), 'general');
      expect(parseSubagentTarget('general'), target);
      expect(target.assistantId, isNull);
    });

    test('an assistant round-trips, and the id is what travels', () {
      final target = SubagentTarget.assistant('a-1');
      expect(target.encode(), 'assistant:a-1');
      expect(
        parseSubagentTarget('assistant:a-1'),
        isA<AssistantSubagentTarget>(),
      );
      expect(parseSubagentTarget('assistant:a-1')!.assistantId, 'a-1');
      // Whitespace around either half is not part of the value.
      expect(parseSubagentTarget('  assistant: a-1  ')!.assistantId, 'a-1');
    });

    test('anything else is a refusal, not a fallback', () {
      for (final raw in <Object?>[
        null,
        '',
        '  ',
        'assistant',
        'assistant:',
        'assistant:   ',
        'other:a-1',
        'general:a-1',
        1,
      ]) {
        expect(parseSubagentTarget(raw), isNull, reason: '$raw');
      }
    });
  });
}
