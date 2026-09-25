import 'package:flutter_test/flutter_test.dart';

import 'package:Cuplivo/core/services/memory/memory_tokenizer.dart';

void main() {
  group('MemoryTokenizer.tokenize', () {
    test('splits English words, filters stopwords including user', () {
      final tokens = MemoryTokenizer.tokenize(
        'The user prefers Flutter performance tips',
      );
      expect(tokens, isNot(contains('the')));
      expect(tokens, isNot(contains('user')));
      expect(tokens, isNot(contains('prefers')));
      expect(tokens, contains('flutter'));
      expect(tokens, contains('performance'));
      expect(tokens, contains('tips'));
    });

    test('builds CJK 2-grams and filters the 用户 stopword bigram', () {
      final tokens = MemoryTokenizer.tokenize('用户开发Flutter应用');
      expect(tokens, isNot(contains('用户')));
      expect(tokens, contains('开发'));
      expect(tokens, contains('flutter'));
      expect(tokens, contains('应用'));
    });

    test('caps at 8 tokens', () {
      final tokens = MemoryTokenizer.tokenize(
        'alpha bravo charlie delta echo foxtrot golf hotel india juliet',
      );
      expect(tokens.length, 8);
      expect(tokens.first, 'alpha');
      expect(tokens.last, 'hotel');
    });

    test('drops short latin tokens under length 2', () {
      // "I" / "a" are length 1; "am" is length 2 and kept; "ok" kept.
      expect(MemoryTokenizer.tokenize('I a OK'), ['ok']);
      expect(MemoryTokenizer.tokenize('I am OK'), ['am', 'ok']);
    });
  });

  group('MemoryTokenizer.escapeLike', () {
    test('escapes percent, underscore, and backslash', () {
      expect(MemoryTokenizer.escapeLike(r'100%_done\x'), r'100\%\_done\\x');
      expect(MemoryTokenizer.escapeLike('plain'), 'plain');
    });
  });
}
