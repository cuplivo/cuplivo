import 'package:flutter/material.dart' show TextDirection;
import 'package:flutter_test/flutter_test.dart';
import 'package:gpt_markdown/custom_widgets/markdown_config.dart';
import 'package:gpt_markdown/gpt_markdown.dart';

/// The IR a package renderer would build for [source], with the package's own
/// default component set.
MdDocument _document(String source) => MarkdownComponent.walkDocument(
  source,
  config: const GptMarkdownConfig(textDirection: TextDirection.ltr),
);

void main() {
  test('bold survives a selection that crosses its boundary', () {
    const source = '**Hello**, world';
    final doc = _document(source);
    expect(doc.displayText, 'Hello, world');
    // The naive subsequence matcher returned `Hello**, world` here.
    expect(doc.emitSelectionMarkdown('Hello, world'), '**Hello**, world');
    expect(doc.emitSelectionMarkdown('lo, wor'), '**lo**, wor');
  });

  test('emphasis variants complete their own markers', () {
    expect(
      _document('*italic* plain').emitSelectionMarkdown('italic plain'),
      '*italic* plain',
    );
    expect(
      _document('~~gone~~ now').emitSelectionMarkdown('gone now'),
      '~~gone~~ now',
    );
    expect(
      _document('<u>under</u> here').emitSelectionMarkdown('under here'),
      '<u>under</u> here',
    );
    expect(
      _document('use `x = 1` here').emitSelectionMarkdown('use x = 1 here'),
      'use `x = 1` here',
    );
    // A selection that starts inside the code re-wraps only what it covers.
    expect(
      _document('use `x = 1` here').emitSelectionMarkdown('x = 1 here'),
      '`x = 1` here',
    );
  });

  test('nested emphasis keeps both levels', () {
    final doc = _document('**bold *inner* tail**');
    expect(doc.displayText, 'bold inner tail');
    expect(
      doc.emitSelectionMarkdown('bold inner tail'),
      '**bold *inner* tail**',
    );
    expect(doc.emitSelectionMarkdown('inner'), '***inner***');
  });

  test('a link re-emits its target', () {
    final doc = _document('[label](url) after');
    expect(doc.displayText, 'label after');
    expect(doc.emitSelectionMarkdown('label after'), '[label](url) after');
    expect(doc.emitSelectionMarkdown('abel after'), '[abel](url) after');
  });

  test('an image contributes no display text but rides along', () {
    final doc = _document('before![alt](image.png)after');
    expect(doc.displayText, 'beforeafter');
    expect(
      doc.emitSelectionMarkdown('beforeafter'),
      'before![alt](image.png)after',
    );
  });

  test('a heading keeps its marker', () {
    final doc = _document('## Title\nbody');
    expect(doc.displayText, 'Title\nbody');
    expect(doc.emitSelectionMarkdown('Title\nbody'), '## Title\nbody');
    expect(doc.emitSelectionMarkdown('itle\nbody'), '## itle\nbody');
  });

  test('list items stay items', () {
    final doc = _document('- first\n- second');
    expect(doc.displayText, 'first\nsecond');
    expect(doc.emitSelectionMarkdown('first\nsecond'), '- first\n- second');
  });

  test('an ordered list keeps its numbers', () {
    final doc = _document('1. one\n2. two');
    // The renderer draws each number as its own text, so it occupies display
    // space; the node's marker re-emits it in the markdown.
    expect(doc.displayText, '1.one\n2.two');
    expect(doc.emitSelectionMarkdown('1.one\n2.two'), '1. one\n2. two');
  });

  test('a paragraph break survives folding', () {
    final doc = _document('a\n\nb');
    expect(doc.displayText, 'a\nb');
    expect(doc.emitSelectionMarkdown('a\nb'), 'a\n\nb');
  });

  test('a quote re-emits whole', () {
    final doc = _document('> quoted\n> lines');
    expect(doc.displayText, 'quoted\nlines');
    expect(doc.emitSelectionMarkdown('quoted\nlines'), '> quoted\n> lines');
    expect(doc.emitSelectionMarkdown('quoted'), '> quoted\n> lines');
  });

  test('a task list keeps its checkbox', () {
    final doc = _document('- [x] done\n- [ ] todo');
    expect(doc.displayText, 'done\ntodo');
    expect(doc.emitSelectionMarkdown('done\ntodo'), '- [x] done\n- [ ] todo');
  });

  test('an inline formula re-emits whole', () {
    final doc = _document(r'the \(x^2\) value');
    expect(doc.displayText, 'the x^2 value');
    expect(doc.emitSelectionMarkdown('the x^2 value'), r'the \(x^2\) value');
  });

  test('reports null when the selection is not in the document', () {
    expect(_document('**Hello**').emitSelectionMarkdown('absent'), isNull);
  });
}
