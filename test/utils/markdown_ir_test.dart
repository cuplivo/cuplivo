import 'package:flutter_test/flutter_test.dart';
import 'package:gpt_markdown/markdown_ir.dart';

/// A range covering the first occurrence of [sub] in [source].
MdRange _r(String source, String sub) {
  final at = source.indexOf(sub);
  if (at < 0) throw StateError('fixture: "$sub" is not in "$source"');
  return MdRange(source, at, at + sub.length);
}

/// `**Hello**, world` — the selection that the naive subsequence matcher got
/// wrong by returning `Hello**, world`.
MdDocument _boldThenText() {
  const source = '**Hello**, world';
  return MdDocument([
    MdNode(
      kind: MdNodeKind.bold,
      range: _r(source, '**Hello**'),
      open: '**',
      close: '**',
      children: [MdNode.text(_r(source, 'Hello'))],
    ),
    MdNode.text(_r(source, ', world')),
  ]);
}

void main() {
  group('display space', () {
    test('is the concatenation a selection copies', () {
      final doc = _boldThenText();
      expect(doc.displayText, 'Hello, world');
    });

    test('ignores characters the renderer inserts', () {
      const source = 'foobar';
      final doc = MdDocument([
        // The renderer soft-breaks a long token with a zero-width space.
        MdNode.opaque(MdNodeKind.text, MdRange.all(source), 'foo\u200bbar'),
      ]);
      expect(doc.displayText, 'foobar');
      expect(doc.emitSelectionMarkdown('foobar'), 'foobar');
    });
  });

  group('boundary completion', () {
    test('completes emphasis the selection cut', () {
      final doc = _boldThenText();
      expect(doc.emitSelectionMarkdown('Hello, world'), '**Hello**, world');
      expect(doc.emitSelectionMarkdown('lo, wor'), '**lo**, wor');
    });

    test('keeps a fully covered node verbatim', () {
      final doc = _boldThenText();
      expect(doc.emitSelectionMarkdown('Hello'), '**Hello**');
    });

    test('reports a miss as null so the caller can fall back', () {
      final doc = _boldThenText();
      expect(doc.emitSelectionMarkdown('absent'), isNull);
      expect(doc.emitSelectionMarkdown(''), isNull);
    });

    test('completes a link around a partial label', () {
      const source = '[label](url) after';
      final doc = MdDocument([
        MdNode(
          kind: MdNodeKind.link,
          range: _r(source, '[label](url)'),
          open: '[',
          close: '](url)',
          children: [MdNode.text(_r(source, 'label'))],
        ),
        MdNode.text(_r(source, ' after')),
      ]);
      expect(doc.displayText, 'label after');
      expect(doc.emitSelectionMarkdown('label after'), '[label](url) after');
      // `label` is l-a-b-e-l, so `abel` is the longest partial label that is
      // still contiguous in the display space.
      expect(doc.emitSelectionMarkdown('abel after'), '[abel](url) after');
    });

    test('completes inline code around a partial body', () {
      const source = 'use `x = 1` here';
      final doc = MdDocument([
        MdNode.text(_r(source, 'use ')),
        MdNode(
          kind: MdNodeKind.inlineCode,
          range: _r(source, '`x = 1`'),
          open: '`',
          close: '`',
          children: [MdNode.text(_r(source, 'x = 1'))],
        ),
        MdNode.text(_r(source, ' here')),
      ]);
      expect(doc.displayText, 'use x = 1 here');
      expect(doc.emitSelectionMarkdown('x = 1'), '`x = 1`');
      expect(doc.emitSelectionMarkdown('= 1 here'), '`= 1` here');
    });

    test('re-emits a block marker for a partial block', () {
      const source = '## Title\nbody';
      final doc = MdDocument([
        MdNode(
          kind: MdNodeKind.heading,
          range: _r(source, '## Title'),
          open: '## ',
          children: [MdNode.text(_r(source, 'Title'))],
        ),
        MdNode.text(_r(source, '\nbody')),
      ]);
      expect(doc.displayText, 'Title\nbody');
      expect(doc.emitSelectionMarkdown('Title\nbody'), '## Title\nbody');
      expect(doc.emitSelectionMarkdown('itle\nbody'), '## itle\nbody');
    });

    test('drops display-only decoration from the markdown', () {
      const source = '## Title';
      final doc = MdDocument([
        MdNode(
          kind: MdNodeKind.heading,
          range: MdRange.all(source),
          open: '## ',
          children: [
            // The app enumerates headings on screen; the source has no number.
            const MdNode.decoration('1. '),
            MdNode.text(_r(source, 'Title')),
          ],
        ),
      ]);
      expect(doc.displayText, '1. Title');
      expect(doc.emitSelectionMarkdown('1. Title'), '## Title');
      expect(doc.emitSelectionMarkdown('1. Ti'), '## Ti');
    });
  });

  group('nodes that occupy no display space', () {
    test('ride along when the selection spans them', () {
      const source = 'before![alt](url)after';
      final doc = MdDocument([
        MdNode.text(_r(source, 'before')),
        MdNode.gap(MdNodeKind.image, _r(source, '![alt](url)')),
        MdNode.text(_r(source, 'after')),
      ]);
      expect(doc.displayText, 'beforeafter');
      expect(
        doc.emitSelectionMarkdown('beforeafter'),
        'before![alt](url)after',
      );
      expect(doc.emitSelectionMarkdown('oreafter'), 'ore![alt](url)after');
    });

    test('stay out of a selection that does not reach them', () {
      const source = 'before---after';
      final doc = MdDocument([
        MdNode.text(_r(source, 'before')),
        MdNode.gap(MdNodeKind.group, _r(source, '---')),
        MdNode.text(_r(source, 'after')),
      ]);
      expect(doc.emitSelectionMarkdown('before'), 'before');
      expect(doc.emitSelectionMarkdown('after'), 'after');
    });
  });

  group('atomic leaves', () {
    test('emit whole when the selection cuts them', () {
      const source = r'the $x^2$ value';
      final doc = MdDocument([
        MdNode.text(_r(source, 'the ')),
        MdNode.opaque(MdNodeKind.math, _r(source, r'$x^2$'), 'x^2'),
        MdNode.text(_r(source, ' value')),
      ]);
      expect(doc.displayText, 'the x^2 value');
      expect(doc.emitSelectionMarkdown('x^2'), r'$x^2$');
      expect(doc.emitSelectionMarkdown('x'), r'$x^2$');
      expect(doc.emitSelectionMarkdown('the x^2 value'), r'the $x^2$ value');
    });
  });

  group('blocks', () {
    test('fence a partially covered code block', () {
      const source = '```dart\nfinal a = 1;\n```';
      final doc = MdDocument([
        MdNode(
          kind: MdNodeKind.codeBlock,
          range: MdRange.all(source),
          open: '```dart\n',
          close: '\n```',
          children: [MdNode.text(_r(source, 'final a = 1;'))],
        ),
      ]);
      expect(doc.displayText, 'final a = 1;');
      expect(
        doc.emitSelectionMarkdown('final a = 1;'),
        '```dart\nfinal a = 1;\n```',
      );
      expect(doc.emitSelectionMarkdown('a = 1'), '```dart\na = 1\n```');
    });

    test('keeps list items as items', () {
      const source = '- first\n- second';
      final doc = MdDocument([
        MdNode(
          kind: MdNodeKind.listItem,
          range: _r(source, '- first'),
          open: '- ',
          children: [MdNode.text(_r(source, 'first'))],
        ),
        MdNode.text(_r(source, '\n')),
        MdNode(
          kind: MdNodeKind.listItem,
          range: _r(source, '- second'),
          open: '- ',
          children: [MdNode.text(_r(source, 'second'))],
        ),
      ]);
      expect(doc.displayText, 'first\nsecond');
      expect(doc.emitSelectionMarkdown('first\nsecond'), '- first\n- second');
      expect(doc.emitSelectionMarkdown('irst\nsec'), '- irst\n- sec');
    });

    test('keep paragraph breaks from the source', () {
      const source = 'a\n\nb';
      final doc = MdDocument([
        MdNode.text(_r(source, 'a')),
        MdNode.text(_r(source, '\n\n')),
        MdNode.text(_r(source, 'b')),
      ]);
      expect(doc.displayText, 'a\nb');
      expect(doc.emitSelectionMarkdown('a\nb'), 'a\n\nb');
    });
  });

  group('normalization', () {
    test('folds newlines, CRLF and invisibles', () {
      expect(normalizeDisplayText('a\r\nb'), 'a\nb');
      expect(normalizeDisplayText('a\n\n\nb'), 'a\nb');
      expect(normalizeDisplayText('a\u200bb\u200cc'), 'abc');
      expect(normalizeDisplayText('• item'), ' item');
      expect(normalizeDisplayText('a\u2060b'), 'ab');
    });

    test('strips only what the renderer inserts', () {
      expect(stripRendererInsertedCharacters('a\u200bb\u200cc'), 'abc');
      // A zero-width joiner holds an emoji sequence together; it is content.
      expect(stripRendererInsertedCharacters('👩\u200d💻'), '👩\u200d💻');
      expect(stripRendererInsertedCharacters('\u2060'), '\u2060');
    });
  });
}
