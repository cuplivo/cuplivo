import 'package:Cuplivo/features/chat/utils/export_document.dart';
import 'package:Cuplivo/features/chat/utils/markdown_pdf_emitter.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../../support/pdf_content_stream.dart';

/// The layout's nesting, its formulas, and what it says about what it could not
/// draw.
///
/// Nesting is the tree's depth rather than a measurement of a line's leading
/// spaces: the parser decides what is inside what, and the layout spends one step
/// of indent per level. What is worth pinning is the *page* — where each line was
/// actually drawn — because a depth the layout forgot to spend and a depth the
/// tree does not have look the same in the source.
void main() {
  group('the indentation nesting claims', () {
    test('one step per level, a tab is a level, and the cap holds', () async {
      // Three levels, one step each.
      final three = await _drawnText('- alpha\n  - bravo\n    - charlie\n');
      expect(
        pdfWordX(three, 'bravo') - pdfWordX(three, 'alpha'),
        closeTo(14, 0.01),
      );
      expect(
        pdfWordX(three, 'charlie') - pdfWordX(three, 'bravo'),
        closeTo(14, 0.01),
      );

      // A tab is a level just as two spaces are: the tree does not record which
      // one the source spelled.
      final tabbed = await _drawnText('- alpha\n\t- bravo\n');
      expect(
        pdfWordX(tabbed, 'bravo') - pdfWordX(tabbed, 'alpha'),
        closeTo(14, 0.01),
      );

      // Deeper than any real document is a formatting accident rather than a
      // structure, so the indent stops at the cap instead of running off the page.
      final deep = await _drawnText(
        '- alpha\n  - bravo\n    - charlie\n      - delta\n        - echo\n'
        '          - foxtrot\n            - golf\n              - hotel\n',
      );
      expect(
        pdfWordX(deep, 'hotel') - pdfWordX(deep, 'alpha'),
        closeTo(84, 0.01),
      );
    });

    test('a raster shrinks for width, for height, and never grows', () {
      // A drawing the column has room for keeps the size it was drawn at.
      expect(pdfRasterScale(width: 100, height: 20, availableWidth: 503), 1.0);
      // Nesting narrows the column, and the drawing follows it.
      expect(pdfRasterScale(width: 400, height: 20, availableWidth: 200), 0.5);
      // The height bound is the stricter one for a tall drawing, and it is what
      // keeps an unbreakable widget from being taller than the page.
      final tall = pdfRasterScale(width: 10, height: 2000, availableWidth: 503);
      expect(tall, lessThan(1));
      expect(2000 * tall, lessThanOrEqualTo(646));
      // A drawing that fits both ways is never enlarged.
      expect(pdfRasterScale(width: 10, height: 10, availableWidth: 503), 1.0);
    });
  });

  test(
    'a nested list is indented by its own line, and a flat one is not',
    () async {
      final flat = await _drawnText('- alpha\n- bravo\n- charlie\n');
      final nested = await _drawnText('- alpha\n  - bravo\n    - charlie\n');

      // The control, and the reason this test is not vacuous: a flat list draws all
      // three items in one column.
      expect(pdfWordX(flat, 'alpha'), pdfWordX(flat, 'bravo'));
      expect(pdfWordX(flat, 'bravo'), pdfWordX(flat, 'charlie'));

      expect(
        pdfWordX(nested, 'bravo') - pdfWordX(nested, 'alpha'),
        closeTo(14, 0.01),
      );
      expect(
        pdfWordX(nested, 'charlie') - pdfWordX(nested, 'bravo'),
        closeTo(14, 0.01),
      );
    },
  );

  test('a marker rides the line of the text that follows it', () async {
    // An item whose first node is a formula used to take the "opens with a block"
    // path, which put the marker on a line of its own.
    final inline = await _drawnText(
      r'- $x^2$ is the area'
      '\n',
    );
    expect(leftmostOnPdfLine(pdfWordY(inline, 'area'), inline), '-');

    // A link's node is a group, which is the same trap by another route.
    final link = await _drawnText('- [docs](https://example.com) and more\n');
    expect(leftmostOnPdfLine(pdfWordY(link, 'more'), link), '-');
  });

  test(
    'a block that cannot share the marker line goes to the next one',
    () async {
      final block = await _drawnText(
        r'- $$\frac{a}{b}$$'
        '\n',
      );
      // The other half of the rule: a display formula is a block, so the marker is
      // a line of its own rather than a prefix.
      expect(
        pdfExactWordY(block, '-'),
        isNot(closeTo(pdfWordY(block, 'frac'), 0.5)),
      );
      expect(leftmostOnPdfLine(pdfWordY(block, 'frac'), block), isNot('-'));
    },
  );

  test('a wrapped item hangs under its text, not under its marker', () async {
    // The marker rides the item's first line, and every line after it belongs one
    // step in — the hanging indent the writer has no way to draw itself, which is
    // why the emitter cuts the first line out and sets the rest at the item's own
    // indent. A review of the first export found the second line level with the
    // marker, which is what this holds down.
    final drawn = await _drawnText(
      '- alpha bravo charlie delta echo foxtrot golf hotel india juliett '
      'kilo lima mike november oscar papa quebec romeo sierra tango uniform '
      'victor whiskey xray yankee zulu\n',
    );
    final marker = drawn.firstWhere((word) => word.text == '-');
    final label = pdfWordY(drawn, 'Assistant');
    final lines = <double>{
      for (final word in drawn)
        // Above the footer, below the speaker line: the body, and nothing else.
        if (word.y > 100 && word.y < label - 1) word.y,
    }.toList()..sort((a, b) => b.compareTo(a));
    // The lines of the item are the ones under its marker's own line.
    final below = lines.where((y) => y < marker.y - 0.5).toList();
    expect(below, isNotEmpty, reason: 'the item did not wrap');

    final wrapped =
        drawn.where((word) => (word.y - below.first).abs() < 2.5).toList()
          ..sort((a, b) => a.x.compareTo(b.x));
    expect(
      wrapped.first.x - marker.x,
      closeTo(14, 0.01),
      reason:
          'marker at ${marker.x}; the line under it starts with '
          '"${wrapped.first.text}" at ${wrapped.first.x}',
    );
    // And the marker's own line still starts at the marker.
    expect(leftmostOnPdfLine(marker.y, drawn), '-');
  });

  test('a list inside a quote is indented by both', () async {
    final quoted = await _drawnText('> - alpha\n>   - bravo\n');
    final plain = await _drawnText('- alpha\n  - bravo\n');
    expect(
      pdfWordX(quoted, 'bravo') - pdfWordX(quoted, 'alpha'),
      closeTo(14, 0.01),
    );
    // And the quote itself sets its body in from the margin.
    expect(pdfWordX(quoted, 'alpha'), greaterThan(pdfWordX(plain, 'alpha')));
  });

  test(
    'the deepest items pile up at the cap instead of running off the page',
    () async {
      final nested = StringBuffer();
      for (var level = 0; level < 8; level++) {
        nested.writeln('${'  ' * level}- level$level');
      }
      final drawn = await _drawnText(nested.toString());
      final markers = [
        for (final line in drawn)
          if (line.text == '-') line.x,
      ]..sort();
      // Eight items, but the seventh and eighth share the cap's column.
      expect(markers, hasLength(8));
      expect(markers.toSet(), hasLength(7));
      expect(markers.last - markers.first, closeTo(6 * 14, 0.01));
    },
  );

  test(
    'a formula with no drawing is reported rather than passed off',
    () async {
      final result = await _bytes(
        r'- $x^2$ is the area'
        '\n'
        r'$$\int_0^1 f$$'
        '\n',
      );
      expect(result.degradedMath, contains('x^2'));
      expect(result.degradedMath, contains(r'\int_0^1 f'));
      expect(result.degradedDiagrams, isEmpty);
      expect(result.undrawnImages, isEmpty);
      expect(result.pages, greaterThanOrEqualTo(1));
    },
  );

  test(
    'a diagram with no drawing and a picture with no bytes are reported',
    () async {
      final diagram = await _bytes('```mermaid\ngraph TD; A-->B;\n```\n');
      expect(diagram.degradedDiagrams, hasLength(1));
      expect(diagram.degradedDiagrams.single, contains('graph TD'));

      final picture = await _bytes('![a missing one](./nope/missing.png)\n');
      expect(picture.undrawnImages, ['./nope/missing.png']);
      expect(picture.degradedMath, isEmpty);
    },
  );

  test('a report names each kind once however often it happens', () async {
    final result = await _bytes(
      r'$a$ and $a$ and $a$'
      '\n',
    );
    expect(result.degradedMath, ['a']);
  });

  test(
    'a block that rounds its own corner inside a quote still exports',
    () async {
      // A quote's left rule is a *non-uniform* border, and the writer refuses a
      // radius beside one (`box_border.dart`: `borderRadius == null`). Three
      // things bring a radius into the quote's skin — a code surface, a degraded
      // display formula, and a details band — so each of them used to throw
      // instead of exporting. (The assert is compiled out of release builds,
      // where the writer draws the box and ignores the radius; this pins what
      // the debug build — and every test — does.)
      final code = await _bytes(
        '> prose\n>\n> ```dart\n> final x = 1;\n> ```\n',
      );
      expect(code.pages, greaterThanOrEqualTo(1));

      final formula = await _bytes('> prose\n>\n> \$\$x^2\$\$\n');
      expect(formula.degradedMath, contains('x^2'));
      expect(formula.pages, greaterThanOrEqualTo(1));

      final details = await _bytes(
        '> <details>\n> <summary>s</summary>\n>\n> body\n> </details>\n',
      );
      expect(details.pages, greaterThanOrEqualTo(1));
    },
  );

  test('a quote inside a reasoning card still exports', () async {
    // The card skin carries a radius of its own, and the quote inherits it: the
    // same collision reached from the other side.
    final result = await _blocks(
      const ExportReasoning('> quoted\n>\n> ```dart\n> final x = 1;\n> ```\n'),
    );
    expect(result.pages, greaterThanOrEqualTo(1));
  });
}

Future<PdfExportResult> _bytes(String markdown) =>
    _blocks(ExportText(markdown));

Future<PdfExportResult> _blocks(ExportBlock block) => buildConversationPdf(
  PdfExportRequest(
    title: 'nesting probe',
    thinkingLabel: 'Thinking',
    accent: kPdfPageAccent,
    muted: kPdfPageMuted,
    userLabel: 'User',
    messages: <ExportMessage>[
      ExportMessage(
        time: '2026-01-02 03:04:05',
        roleName: 'Assistant',
        speaker: ExportSpeaker.assistant,
        blocks: <ExportBlock>[block],
      ),
    ],
  ),
);

Future<List<({double x, double y, String text})>> _drawnText(
  String markdown,
) async => drawnPdfStrings((await _bytes(markdown)).bytes);
