import 'package:flutter_test/flutter_test.dart';
import 'package:markstream/markstream_core.dart';

/// Regression cover for Cuplivo #1019, dropped with the Markdown IR and carried
/// by markstream's parser. CommonMark applies no backslash escapes inside a code
/// span, so a backslash before the closing backtick must not hide that closer.
/// The CommonMark conformance fixture has no such example, which is why this
/// test exists separately from the spec run.
void main() {
  const parser = InlineParser();

  CodeSpanNode alone(String source, {bool optimistic = false}) {
    final spans = parser
        .parse(source, optimistic: optimistic)
        .whereType<CodeSpanNode>()
        .toList();
    expect(spans, hasLength(1), reason: source);
    return spans.single;
  }

  test('a backslash before the closer does not hide it', () {
    final span = alone(r'`a\`');
    expect(span.closed, isTrue);
    expect(span.code, r'a\');
  });

  test('a backslash before a two-backtick closer does not hide it', () {
    final span = alone(r'``x\``');
    expect(span.closed, isTrue);
    expect(span.code, r'x\');
  });

  test('backslashes inside a code span stay literal', () {
    final span = alone(r'`a\*b`');
    expect(span.closed, isTrue);
    expect(span.code, r'a\*b');
  });

  test('an unmatched opener stays literal text when not streaming', () {
    const source = r'`a\';
    final nodes = parser.parse(source);
    expect(nodes.whereType<CodeSpanNode>(), isEmpty);
    expect(nodes.map((node) => node is TextNode ? node.text : '').join(), source);
  });

  test('an unmatched opener is an open span while streaming', () {
    final span = alone(r'`a\', optimistic: true);
    expect(span.closed, isFalse);
  });
}
