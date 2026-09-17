import 'package:Cuplivo/utils/markdown_subsequence_match.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('subsequenceRange', () {
    test('returns half-open span of a plain subsequence', () {
      final span = subsequenceRange('hello world', 'world');
      expect(span, isNotNull);
      expect(span!.start, 6);
      expect(span.end, 11);
      expect('hello world'.substring(span.start, span.end), 'world');
    });

    test('tolerates markdown markers between query chars', () {
      // `**bold** text` matched from plain selection "bold text": the span
      // starts at the first character of the query and ends after its last —
      // markdown markers before the first matching char are not part of it.
      final source = '**bold** text';
      final span = subsequenceRange(source, 'bold text');
      expect(span, isNotNull);
      expect(source.substring(span!.start, span.end), 'bold** text');
    });

    test('normalizes whitespace like subsequenceMatch', () {
      final span = subsequenceRange('line1\n\nline2', 'line1\nline2');
      expect(span, isNotNull);
    });

    test('handles CJK', () {
      final span = subsequenceRange('你好世界', '世界');
      expect(span, isNotNull);
      expect(span!.start, 2);
      expect(span.end, 4);
    });

    test('bullet normalization', () {
      final span = subsequenceRange('- item text', '• item text');
      expect(span, isNotNull);
      // The stripped bullet leaves a leading space in the normalized query;
      // the match starts at the source space after `-`.
      expect(span!.start, 1);
    });

    test('null for unmatched / empty', () {
      expect(subsequenceRange('hello', ''), isNull);
      expect(subsequenceRange('', 'hello'), isNull);
      expect(subsequenceRange('abc', 'd'), isNull);
      expect(subsequenceRange('abc', 'abcd'), isNull);
    });

    test('smallest span wins', () {
      final span = subsequenceRange('the cat and the dog', 'the');
      expect(span, isNotNull);
      expect(span!.start, 0);
      expect(span.end, 3);
    });
  });
}
