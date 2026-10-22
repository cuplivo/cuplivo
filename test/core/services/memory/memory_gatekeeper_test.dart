import 'package:flutter_test/flutter_test.dart';

import 'package:Cuplivo/core/services/memory/memory_gatekeeper.dart';
import 'package:Cuplivo/core/services/memory/memory_prompts.dart';

void main() {
  group('MemoryGatekeeper.parse (§18.1 item 13)', () {
    test('parses true / false case-insensitively', () {
      expect(
        MemoryGatekeeper.parse('<gate><user_memory>true</user_memory></gate>'),
        MemoryGateParseResult.worthRemembering,
      );
      expect(
        MemoryGatekeeper.parse('<gate><user_memory>FALSE</user_memory></gate>'),
        MemoryGateParseResult.skip,
      );
      expect(
        MemoryGatekeeper.parse(
          'Sure.\n<gate>\n  <user_memory>True</user_memory>\n</gate>\n',
        ),
        MemoryGateParseResult.worthRemembering,
      );
    });

    test('malformed / missing tag → malformed (not skip)', () {
      expect(
        MemoryGatekeeper.parse('no xml here'),
        MemoryGateParseResult.malformed,
      );
      expect(
        MemoryGatekeeper.parse('<user_memory>maybe</user_memory>'),
        MemoryGateParseResult.malformed,
      );
      expect(
        MemoryGatekeeper.parse('<gate></gate>'),
        MemoryGateParseResult.malformed,
      );
    });
  });

  group('MemoryGatekeeper.buildPrompt', () {
    test('uses override instead of default constant', () {
      const override = 'CUSTOM GATE {{conversation}}';
      final prompt = MemoryGatekeeper.buildPrompt(
        lang: MemoryPromptLang.zh,
        conversation: 'hello',
        overrideZh: override,
        overrideEn: 'EN',
      );
      expect(prompt, 'CUSTOM GATE hello');
      expect(prompt, isNot(contains('分析以下对话')));
    });

    test('falls back to built-in when override empty', () {
      final prompt = MemoryGatekeeper.buildPrompt(
        lang: MemoryPromptLang.en,
        conversation: 'c',
        overrideZh: '',
        overrideEn: '   ',
      );
      expect(prompt, startsWith('Analyse the conversation'));
      expect(prompt, endsWith('c'));
    });
  });
}
