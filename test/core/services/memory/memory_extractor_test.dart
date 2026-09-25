import 'package:flutter_test/flutter_test.dart';

import 'package:Cuplivo/core/models/assistant.dart';
import 'package:Cuplivo/core/models/memory_entry.dart';
import 'package:Cuplivo/core/services/memory/memory_extractor.dart';
import 'package:Cuplivo/core/services/memory/memory_prompts.dart';

void main() {
  group('MemoryExtractor.parse (§18.1 item 14)', () {
    test('parses normal items', () {
      const raw = '''
Here you go:
<extracted>
<item type="identity">用户是大学生。</item>
<item type="workflow" scope="assistant">用户偏好 Flutter。</item>
</extracted>
''';
      final r = MemoryExtractor.parse(raw);
      expect(r.ok, isTrue);
      expect(r.items, hasLength(2));
      expect(r.items[0].type, MemoryType.identity);
      expect(r.items[0].content, '用户是大学生。');
      expect(r.items[1].scopeAttr, 'assistant');
    });

    test('empty extracted is ok with zero items', () {
      expect(MemoryExtractor.parse('<extracted/>').ok, isTrue);
      expect(MemoryExtractor.parse('<extracted/>').items, isEmpty);
      expect(MemoryExtractor.parse('<extracted></extracted>').items, isEmpty);
    });

    test('drops invalid type and empty content', () {
      const raw = '''
<extracted>
<item type="bogus">x</item>
<item type="voice">   </item>
<item type="instruction">Keep replies short.</item>
</extracted>
''';
      final r = MemoryExtractor.parse(raw);
      expect(r.ok, isTrue);
      expect(r.items, hasLength(1));
      expect(r.items.single.type, MemoryType.instruction);
    });

    test('caps at 10 items', () {
      final items = List.generate(
        15,
        (i) => '<item type="voice">Style tip $i</item>',
      ).join('\n');
      final r = MemoryExtractor.parse('<extracted>\n$items\n</extracted>');
      expect(r.ok, isTrue);
      expect(r.items, hasLength(10));
    });

    test('missing extracted tag is malformed', () {
      expect(MemoryExtractor.parse('just prose').ok, isFalse);
      expect(
        MemoryExtractor.parse('<item type="identity">x</item>').ok,
        isFalse,
      );
    });
  });

  group('MemoryExtractor.buildPrompt', () {
    test('appends toolDefault scope rule', () {
      final prompt = MemoryExtractor.buildPrompt(
        lang: MemoryPromptLang.zh,
        conversation: 'c',
        existingMemory: 'm',
        writeScope: MemoryWriteScope.toolDefaultGlobal,
      );
      expect(prompt, contains(MemoryPrompts.extractToolDefaultScopeRuleZh));
    });

    test('does not append scope rule for alwaysGlobal', () {
      final prompt = MemoryExtractor.buildPrompt(
        lang: MemoryPromptLang.zh,
        conversation: 'c',
        existingMemory: 'm',
        writeScope: MemoryWriteScope.alwaysGlobal,
      );
      expect(
        prompt,
        isNot(contains(MemoryPrompts.extractToolDefaultScopeRuleZh)),
      );
    });

    test('uses override template', () {
      final prompt = MemoryExtractor.buildPrompt(
        lang: MemoryPromptLang.en,
        conversation: 'CONV',
        existingMemory: 'MEM',
        writeScope: MemoryWriteScope.alwaysGlobal,
        overrideEn: 'OV {{existingMemory}} :: {{conversation}}',
      );
      expect(prompt, 'OV MEM :: CONV');
    });
  });
}
