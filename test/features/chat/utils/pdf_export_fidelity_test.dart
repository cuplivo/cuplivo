import 'dart:typed_data';

import 'package:Cuplivo/features/chat/utils/export_document.dart';
import 'package:Cuplivo/features/chat/utils/markdown_pdf_emitter.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:markstream/markstream_core.dart';

import '../../../support/pdf_content_stream.dart';
import '../../../support/test_png.dart';

/// What a reader of the exported page gets, for the constructs where an export
/// used to hand them the *source* instead of the document.
///
/// Every case here is one of those: a citation that printed the word "citation",
/// a task list that printed `[x]`, an HTML anchor whose label vanished, a link
/// that printed its own markdown, a picture that printed its alt text. So the
/// assertions read the page rather than the layout's own report — the words that
/// were drawn, and where, and the operators that drew what no word can say.
void main() {
  group('a citation', () {
    test('is drawn as its number in a capsule, never as the word', () async {
      final drawn = await _drawn(
        'See [cite:abc123] and [citation](7) here.\n',
        citationIndex: const <String, String>{'abc123': '1'},
      );
      final texts = _texts(drawn);

      // The marker a model wrote and the marker the rewrite produces, neither of
      // which a reader should ever see.
      expect(texts, isNot(contains('[cite:abc123]')));
      expect(texts, isNot(contains('citation')));
      expect(texts, contains('1'));
      expect(texts, contains('7'));

      // A capsule rides the line of the sentence it cites: the label is lifted a
      // little above the baseline, which is why the line is taken with slack.
      final line = _lineOf(drawn, 'See').map((entry) => entry.text).toList();
      expect(line, containsAll(<String>['1', '7']));
    });

    test('shows ? when nothing can resolve its id', () async {
      final drawn = await _drawn('See [citation](nope) here.\n');
      expect(_texts(drawn), contains('?'));
    });

    test('keeps the index a legacy marker carried', () async {
      final drawn = await _drawn('See [citation](3:abc) here.\n');
      expect(_texts(drawn), contains('3'));
    });
  });

  group('a task list', () {
    test('draws a box per item instead of the brackets', () async {
      final drawn = await _drawn('- [x] done task\n- [ ] open task\n');
      final texts = _texts(drawn);

      expect(texts, isNot(contains('[x]')));
      expect(texts, isNot(contains('[')));
      expect(texts, isNot(contains(']')));
      // The bullet the box replaced: an item's marker is the box, not a list one
      // level outside it, so nothing draws a stray dash on a line of its own.
      expect(texts.where((text) => text == '-'), isEmpty);

      // Both labels start in one column: the box and its gap, then the text.
      expect(pdfWordX(drawn, 'done'), pdfWordX(drawn, 'open'));
      expect(pdfWordX(drawn, 'done'), greaterThan(46.0));
    });

    test('fills and ticks a checked one, and only a checked one', () async {
      final checked = await _export('- [x] a task\n');
      final unchecked = await _export('- [ ] a task\n');
      final checkedOps = pdfDrawingOperators(checked.bytes);
      final uncheckedOps = pdfDrawingOperators(unchecked.bytes);

      // Both draw their box…
      expect(checkedOps['S'] ?? 0, greaterThan(0));
      expect(uncheckedOps['S'] ?? 0, greaterThan(0));
      // …and the checked one draws more: the tick is two strokes and the box is
      // filled, neither of which the unchecked box has. Counting operators
      // rather than pinning numbers is what makes this independent of the box's
      // geometry.
      expect(checkedOps['S']!, greaterThan(uncheckedOps['S']!));
      expect(checkedOps['f']!, greaterThan(uncheckedOps['f'] ?? 0));
    });

    test('draws a radio for a parenthesised marker', () async {
      final drawn = await _drawn('(x) selected radio\n');
      final texts = _texts(drawn);
      expect(texts, isNot(contains('(x)')));
      expect(texts, contains('selected'));
      // One curve and one stroke: a circle. Its dot is the fill, and the box it
      // sits in is filled too. Counted against the same page without a marker,
      // because the page draws a speaker's disc whether or not there is a task
      // list under it.
      final withRadio = pdfDrawingOperators((await _export('(x) a\n')).bytes);
      final without = pdfDrawingOperators((await _export('a\n')).bytes);
      expect((withRadio['S'] ?? 0) - (without['S'] ?? 0), 1);
      expect((withRadio['f'] ?? 0) - (without['f'] ?? 0), 2);
    });
  });

  group('a link', () {
    test('an HTML anchor keeps its label and its target', () async {
      final result = await _export(
        'An <a href="https://example.com">anchor</a> here.\n',
      );
      expect(_texts(drawnPdfStrings(result.bytes)), contains('anchor'));
      // The target survives as the annotation the page carries.
      expect(String.fromCharCodes(result.bytes), contains('example.com'));
    });

    test('a link carrying a title is a link, not its markdown', () async {
      final drawn = await _drawn(
        '[title link](https://example.com "the title") and more.\n',
      );
      final texts = _texts(drawn);
      expect(texts, contains('title'));
      expect(texts, contains('link'));
      expect(texts.any((text) => text.contains('](http')), isFalse);
      expect(texts.any((text) => text.contains('"the')), isFalse);
    });
  });

  group('display math written inside a line', () {
    test('becomes a block of its own when it is a formula', () async {
      final result = await _export(
        r'Inline $$\frac{a}{b} + \frac{c}{d}$$ in prose.'
        '\n',
      );
      // No drawing was handed in, so the block degrades to its TeX — which is
      // still the proof that it *is* a block: an inline pair would have been
      // drawn as the sentence's own text.
      expect(result.degradedMath, hasLength(1));
      expect(result.degradedMath.single, contains(r'\frac{a}{b}'));
      expect(
        _texts(
          drawnPdfStrings(result.bytes),
        ).any((text) => text.contains(r'$$')),
        isFalse,
      );
    });

    test('is a picture in the line when it is a single dollar pair', () async {
      // The grammar claims `$x^2$` as *inline* math — a picture inside the
      // sentence — while a `$$…$$` pair is a block wherever it stands. That
      // difference is the one a reader sees, so it is the one pinned here.
      final result = await _export(
        r'Inline $x^2$ in prose.'
        '\n',
      );
      expect(result.degradedMath, <String>['x^2']);
      final texts = _texts(drawnPdfStrings(result.bytes));
      expect(texts, containsAll(<String>['Inline', 'in', 'prose.']));
      expect(texts.any((text) => text.contains(r'$x^2$')), isFalse);
    });
  });

  group('a picture', () {
    test('keeps the size its author wrote', () async {
      final result = await _export(
        '![300x200](shot://sized)\n',
        images: <String, Uint8List>{
          'shot://sized': pngForTest(width: 30, height: 20),
        },
      );
      final placed = placedPdfImages(result.bytes);
      expect(placed, hasLength(1));
      // The author's size is written beside the screen's 15.5-point prose and the
      // page sets 10.5, so the picture arrives at 300 × 10.5 / 15.5.
      expect(placed.single.width, closeTo(300 * 10.5 / 15.5, 0.1));
      expect(placed.single.height, closeTo(200 * 10.5 / 15.5, 0.1));
      expect(result.undrawnImages, isEmpty);
    });

    test('is bounded by the column when its author asked for too much', () async {
      final result = await _export(
        '![2000x100](shot://wide)\n',
        images: <String, Uint8List>{
          'shot://wide': pngForTest(width: 200, height: 10),
        },
      );
      final placed = placedPdfImages(result.bytes).single;
      // A4 minus the two 46-point margins: a picture wider than the column would
      // be painted past the margin, and the writer draws what it is given.
      expect(placed.width, closeTo(595.28 - 92, 0.1));
      // Capped by width, the picture keeps the shape its author asked for.
      expect(placed.height / placed.width, closeTo(100 / 2000, 0.0001));
    });

    test('a picture with no size keeps its own pixels, scaled down', () async {
      final result = await _export(
        '![](shot://plain)\n',
        images: <String, Uint8List>{
          'shot://plain': pngForTest(width: 30, height: 20),
        },
      );
      final placed = placedPdfImages(result.bytes).single;
      expect(placed.width, 30);
      expect(placed.height, 20);
    });
  });

  group('the task marker', () {
    test('the grammar reads both shapes and both states, and nothing else', () {
      // The page reads the marker off the node, so what has to be pinned is the
      // reading it is handed: the two shapes, the two states, and the lines the
      // grammar leaves as ordinary list items or as text.
      ({bool checked, bool radio})? taskIn(String source) {
        final pending = <MarkdownNode>[MarkdownParser().parse(source)];
        while (pending.isNotEmpty) {
          final node = pending.removeLast();
          // A `- [ ]` line inside a list is a list item that carries the state;
          // one outside it is a task block. Both are the same reading.
          if (node is ListItemNode && node.checked != null) {
            return (checked: node.checked!, radio: node.radio);
          }
          if (node is TaskItemNode) {
            return (checked: node.checked, radio: node.radio);
          }
          pending.addAll(node.children);
        }
        return null;
      }

      expect(taskIn('- [x] done\n')?.checked, isTrue);
      expect(taskIn('- [x] done\n')?.radio, isFalse);
      expect(taskIn('- [ ] todo\n')?.checked, isFalse);
      expect(taskIn('- [X] done\n')?.checked, isTrue);
      expect(taskIn('- (x) chosen\n')?.radio, isTrue);
      expect(taskIn('- ( ) not chosen\n')?.checked, isFalse);
      // A bullet or a number is a list item rather than a task.
      expect(taskIn('- plain\n'), isNull);
      expect(taskIn('1. numbered\n'), isNull);
      // A shape the grammar does not claim stays text.
      expect(taskIn('- [y] nope\n'), isNull);
      expect(taskIn('- [x ] nope\n'), isNull);
    });
  });

  group('the picture size rule', () {
    test('scales the author back to the page, then bounds both ways', () {
      final sized = pdfImageSize(
        width: 300,
        height: 200,
        availableWidth: 503.28,
      );
      expect(sized.sized, isTrue);
      expect(sized.width, closeTo(203.2, 0.1));
      expect(sized.height, closeTo(135.5, 0.1));

      // A width the column cannot hold is capped, and the height follows it, so
      // the picture keeps its shape.
      final wide = pdfImageSize(
        width: 2000,
        height: 100,
        availableWidth: 503.28,
      );
      expect(wide.width, closeTo(503.28, 0.01));
      expect(wide.height, closeTo(503.28 * (100 / 2000), 0.01));

      // A picture taller than a page is what makes the writer loop rather than
      // throw, so the height bound is the one that matters most.
      final tall = pdfImageSize(
        width: 100,
        height: 10000,
        availableWidth: 503.28,
      );
      expect(tall.height, lessThanOrEqualTo(759.8898 * 0.85));
      expect(tall.width, lessThan(100 * 10.5 / 15.5));

      // No size at all is "the pixels it has", which is not a size to invent.
      final none = pdfImageSize(
        width: null,
        height: null,
        availableWidth: 503.28,
      );
      expect(none.sized, isFalse);
      expect(none.width, isNull);
      expect(none.height, isNull);

      // A width alone keeps its ratio, bounded only by the column.
      final widthOnly = pdfImageSize(
        width: 100,
        height: null,
        availableWidth: 503.28,
      );
      expect(widthOnly.width, closeTo(67.7, 0.1));
      expect(widthOnly.height, isNull);
    });
  });
}

Future<PdfExportResult> _export(
  String markdown, {
  Map<String, String> citationIndex = const <String, String>{},
  Map<String, Uint8List> images = const <String, Uint8List>{},
}) => buildConversationPdf(
  PdfExportRequest(
    title: 'fidelity probe',
    thinkingLabel: 'Thinking',
    accent: kPdfPageAccent,
    muted: kPdfPageMuted,
    userLabel: 'User',
    images: images,
    messages: <ExportMessage>[
      ExportMessage(
        time: '2026-01-02 03:04:05',
        roleName: 'Assistant',
        speaker: ExportSpeaker.assistant,
        citationIndex: citationIndex,
        blocks: <ExportBlock>[ExportText(markdown)],
      ),
    ],
  ),
);

Future<List<({double x, double y, String text})>> _drawn(
  String markdown, {
  Map<String, String> citationIndex = const <String, String>{},
  Map<String, Uint8List> images = const <String, Uint8List>{},
}) async => drawnPdfStrings(
  (await _export(markdown, citationIndex: citationIndex, images: images)).bytes,
);

List<String> _texts(List<({double x, double y, String text})> drawn) => [
  for (final entry in drawn) entry.text,
];

List<({double x, double y, String text})> _lineOf(
  List<({double x, double y, String text})> drawn,
  String word,
) => pdfLineAt(pdfWordY(drawn, word), drawn);
