import 'package:Cuplivo/shared/widgets/markdown_streaming_split.dart';
import 'package:Cuplivo/shared/widgets/markdown_with_highlight.dart';
import 'package:flutter_test/flutter_test.dart';

/// The block shapes a split produces, so two splitters can be compared without
/// holding on to the same object identities.
String _shape(List<MarkdownStreamBlock> blocks) => blocks
    .map(
      (block) =>
          '${block.start}:${block.text}:${block.stable}:'
          '${block.swallowedBy}',
    )
    .join('|');

String _show(String text) => text
    .replaceAll('\r', '<CR>')
    .replaceAll('\n', '<LF>')
    .replaceAll('\u2028', '<LS>')
    .replaceAll('\u2029', '<PS>')
    .replaceAll('\u00a0', '<NBSP>')
    .replaceAll('\u3000', '<IDSP>');

/// Whether a blank run the splitter refused while the text after it was still
/// arriving is re-decided when that text arrives.
///
/// A decision may only be taken from text that exists. Four refusals are
/// provisional by construction — the next item of a list may still belong to
/// it, an indented line may still open a fence, an element that ends exactly at
/// the run may still be growing, and a rule or a formula may still be waiting
/// for the paragraph behind it — and each of them makes the block list a
/// function of how the reply was chunked rather than of the reply itself. These
/// tests pin the stronger property: the same text produces the same blocks,
/// however the stream delivered it.
void main() {
  group('the block list is a function of the source alone', () {
    for (final source in _corpus) {
      test('one code unit at a time: ${_show(source)}', () {
        final streamed = markdownStreamingSplit();
        for (var end = 1; end <= source.length; end++) {
          final prefix = source.substring(0, end);
          final chunked = streamed.update(prefix);
          final oneShot = markdownStreamingSplit().update(prefix);
          expect(
            _shape(chunked),
            _shape(oneShot),
            reason: 'prefix $end of ${_show(source)}',
          );
        }
      });
    }

    for (final entry in _chunks.entries) {
      test('a chunk boundary does not move a block: ${entry.key}', () {
        final streamed = markdownStreamingSplit();
        var source = '';
        for (final chunk in entry.value) {
          source += chunk;
          final chunked = streamed.update(source);
          final oneShot = markdownStreamingSplit().update(source);
          expect(
            _shape(chunked),
            _shape(oneShot),
            reason: 'chunk ${_show(chunk)} of ${_show(source)}',
          );
        }
      });
    }
  });

  test('a finished formula at the tail commits its run at once', () {
    // The display-math pattern closes with `\s*$`, so its match ends exactly
    // where the trailing run does. That claim is only provisional while the
    // fence it belongs to is still open; a closed formula is finished, so the
    // run after it is a boundary like any other, and only the separator is
    // suppressed (`swallowedBy`) because the match ate the newline.
    final document = markdownStreamingSplit();
    expect(
      document.update('before\n\n\$\$\na + b\n\nc + d\n\$\$\n\n'),
      hasLength(2),
    );
    final blocks = document.update(
      'before\n\n\$\$\na + b\n\nc + d\n\$\$\n\nafter',
    );
    expect(blocks, hasLength(3));
    expect(blocks[0].text, 'before');
    expect(blocks[1].text, '\$\$\na + b\n\nc + d\n\$\$');
    expect(blocks[1].stable, isTrue);
    expect(blocks[1].swallowedBy, isNotNull);
    expect(blocks[2].text, 'after');
    expect(blocks[2].stable, isFalse);
  });

  test('a rule at the tail commits its run at once', () {
    final document = markdownStreamingSplit();
    expect(document.update('a\n\n---\n\n'), hasLength(2));
    final blocks = document.update('a\n\n---\n\nb');
    expect(blocks, hasLength(3));
    expect(blocks[1].text, '---');
    expect(blocks[1].stable, isTrue);
    expect(blocks[1].swallowedBy, isNotNull);
    expect(blocks[2].text, 'b');
  });

  test('a list item waits for the line after it, then commits', () {
    // The item may be continued, so the run stays undecided while it is the
    // last thing in the source — but the line that arrives next has to settle
    // it, or the item would keep the paragraph behind it forever.
    final document = markdownStreamingSplit();
    final waiting = document.update('- a\n\n');
    expect(waiting, hasLength(1));
    expect(waiting.single.stable, isFalse);

    final blocks = document.update('- a\n\nnext\n');
    expect(blocks, hasLength(2));
    expect(blocks.first.text, '- a');
    expect(blocks.first.stable, isTrue);
    expect(blocks.last.text, 'next\n');
    expect(blocks.last.stable, isFalse);
  });

  test('an indented fence never swallows the block above it', () {
    // The opener arrives one code unit at a time. While it is still arriving the
    // line cannot be classified, so the tail may only be folded into the block
    // above for the view — never merged into the committed list, which would be
    // permanent. Once the line is complete the walk knows it is a fence, and the
    // paragraph keeps its own block.
    final document = markdownStreamingSplit();
    final chunks = [
      'before\n\n',
      '  ',
      '`',
      '``\ncode\n\ninside\n```\n\n',
      'after',
    ];
    var source = '';
    for (final chunk in chunks) {
      source += chunk;
      document.update(source);
    }
    final blocks = document.blocks;
    expect(blocks, hasLength(3));
    expect(blocks[0].text, 'before');
    expect(blocks[0].stable, isTrue);
    expect(blocks[1].text, '  ```\ncode\n\ninside\n```');
    expect(blocks[1].stable, isTrue);
    expect(blocks[2].text, 'after');
  });

  test('an indented details never swallows the block above it', () {
    final document = markdownStreamingSplit();
    final chunks = [
      'before\n\n',
      '  <det',
      'ails>\n<summary>s</summary>\n\nbody\n</details>\n\n',
      'after',
    ];
    var source = '';
    for (final chunk in chunks) {
      source += chunk;
      document.update(source);
    }
    final blocks = document.blocks;
    expect(blocks, hasLength(3));
    expect(blocks[0].text, 'before');
    expect(blocks[1].text, startsWith('  <details>'));
    expect(blocks[2].text, 'after');
  });

  test('a lone dollar inside a finished formula is not stabilized', () {
    // `_stabilizeStreamingDollarMath` closes the last unclosed single `$` of a
    // growing block. A closed `$$…$$` block must not be treated as growing, or
    // that pass could rewrite text the document already finished.
    final document = markdownStreamingSplit();
    final blocks = document.update(
      'before\n\n\$\$\na \$ b\n\nc\n\$\$\n\nafter',
    );
    expect(blocks, hasLength(3));
    expect(blocks[1].text, '\$\$\na \$ b\n\nc\n\$\$');
    expect(blocks[1].stable, isTrue);
  });
}

/// Sources a stream can deliver: every construct whose boundary the splitter
/// decides differently from the text, plus the shapes the review round found.
const List<String> _corpus = [
  'before\n\n  ```\ncode\n\ninside\n```\n\nafter',
  'before\n\n\t```\ncode\n\ninside\n```\n\nafter',
  'before\n\nText\u2028```dart\ncode\n\ninside\n```\n\nafter',
  'before\n\n\u00a0```\ncode\n\ninside\n```\n\nafter',
  'before\n\n```\na\n``` dart\n\nb\n```\n\nafter',
  '````dart\na\n```\n\nb\n````',
  'before\n\n\$\$\na + b\n\nc + d\n\$\$\n\nafter',
  'before\n\n\\[\na + b\n\nc + d\n\\]\n\nafter',
  '\$\$\na\n\n',
  '\$\$\n\$\$ tail\n\ninside\n\$\$\n\nafter',
  'a\n\n---\n\nb',
  '---\n\nnext',
  '\$\$ a + b \$\$\n\nnext',
  'a\n---\n\nb',
  'a\n\n***\n\nb',
  'a\n\n___\n\nb',
  'a\n\n\u2E3B\n\nb',
  'before\n\n<details>\n<summary>s</summary>\n\nbody\n\n</details>\n\nafter',
  'before\n\n<details>\n<summary>s</summary>\n\nbody',
  'before\n\n  <details>\n<summary>s</summary>\n\nbody\n</details>\n\nafter',
  'before\n\n<details\nopen>\n<summary>s</summary>\n\nbody\n</details>\n\nafter',
  'before\n\n<details>\n<summary>L1</summary>\n<details>\n<summary>L2</summary>\n'
      'inner\n</details>\n\nouter\n</details>\n\nafter',
  '- first\n\n- second\n\nnext paragraph\n',
  '- item\n\n  still the item\n\nnext\n',
  '- a\n\n\n\nnext',
  '1. one\n\n2) two\n\n+ three\n\nnext',
  '- [x] done\n\n- [ ] todo\n\nnext',
  'a\n\n \n\nb',
  'a\n\n   \n\nb',
  'a\n\n\u00a0\n\nb',
  'a\n\n\t\n\nb',
  'para\n  indented\n\nnext',
  'para\n\n  indented\n\nnext',
  'a\r\n\r\nb\r\n\r\nc',
  'a\rb',
  'text \$\$ a \$\$ \\[\nb\n\nc\n\\]\n\nafter',
  '| A | B |\n| - | - |\n| 1 | 2 |\n\nafter',
  '> quoted\n> lines\n\nafter',
  '> quoted\n\n> lines\n\nafter',
  'a\n\n\n\n\nb',
  '\n\n\n',
  '   ',
  '',
];

/// Chunk sequences that end exactly at a run, so the refusal happens while the
/// text that decides it is still missing.
const Map<String, List<String>> _chunks = {
  'formula, then prose': ['before\n\n\$\$\na + b\n\nc + d\n\$\$\n\n', 'after'],
  'bracket formula, then prose': [
    'before\n\n\\[\na + b\n\nc + d\n\\]\n\n',
    'after',
  ],
  'one-line formula, then prose': ['before\n\n\$\$ a + b \$\$\n\n', 'next'],
  'rule, then prose': ['a\n\n---\n\n', 'b'],
  'rule with a longer run, then prose': ['a\n\n---\n\n\n\n', 'b'],
  'list item, then prose': ['- a\n\n', 'next'],
  'list item, then prose and a newline': ['- a\n\n', 'next\n'],
  'list item, then a grown run, then prose': ['- a\n\n', '\n', 'next\n'],
  'two list items': ['- first\n\n', '- second\n'],
  'rule, then a grown run, then prose': ['a\n\n---\n\n', '\n', 'b'],
  'list item, then a grown run, then prose without a newline': [
    '- a\n\n',
    '\n',
    'next',
  ],
  'ordered list item, then prose': ['1. a\n\n', 'next'],
  'closed fence, then prose': ['before\n\n```\ncode\n```\n\n', 'after'],
  'indented fence grown from an indented line': [
    'before\n\n  ',
    '`',
    '``\ncode\n\ninside\n```\n\n',
    'after',
  ],
  'indented details grown from an indented line': [
    'before\n\n  <det',
    'ails>\n<summary>s</summary>\n\nbody\n</details>\n\n',
    'after',
  ],
  'paragraph, then prose': ['before\n\n', 'after'],
  'details, then prose': [
    'before\n\n<details><summary>s</summary>b</details>\n\n',
    'after',
  ],
};
