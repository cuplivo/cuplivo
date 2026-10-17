import 'package:Cuplivo/features/chat/utils/export_document.dart';
import 'package:Cuplivo/features/chat/utils/markdown_pdf_emitter.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../../support/pdf_content_stream.dart';

/// The layout's nesting, its formulas, and what it says about what it could not
/// draw.
///
/// The IR carries no list container: a list component matches one line, so a
/// nested item arrives as a *sibling* node whose line happens to be indented, and
/// that indentation exists only in the source a node addresses. That makes the
/// arithmetic ([pdfIndentForSourceLine]) worth pinning on its own — and it makes
/// it worth pinning that the layout *uses* it, which is what the position
/// assertions here do: they read where each line was actually drawn.
void main() {
  group('the indentation a line claims', () {
    test('two spaces are one level, a tab is four, and six levels is the cap', () {
      const source = '- a\n  - b\n    - c\n\td\n';
      expect(pdfIndentForSourceLine(source, source.indexOf('- a')), 0);
      expect(pdfIndentForSourceLine(source, source.indexOf('- b')), 14);
      expect(pdfIndentForSourceLine(source, source.indexOf('- c')), 28);
      // A tab counts as four columns, which is two levels.
      expect(pdfIndentForSourceLine(source, source.indexOf('\td')), 28);
      // A node that begins on the newline that ended the line above belongs to
      // the line it opens — that is exactly what the whitespace between two
      // blocks looks like — so the indentation of *that* line is what it reports.
      final firstBreak = source.indexOf('\n');
      expect(pdfIndentForSourceLine(source, firstBreak), 14);
      expect(
        pdfIndentForSourceLine(source, source.indexOf('\n', firstBreak + 1)),
        28,
      );
      // Deeper than the cap is a formatting accident rather than a structure.
      final deep = '${' ' * 40}- x';
      expect(pdfIndentForSourceLine(deep, deep.indexOf('- x')), 84);
      // An offset at the very end of a source has no line to measure.
      expect(pdfIndentForSourceLine(source, source.length), 0);
      expect(pdfIndentForSourceLine('', 0), 0);
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
}

Future<PdfExportResult> _bytes(String markdown) => buildConversationPdf(
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
        blocks: <ExportBlock>[ExportText(markdown)],
      ),
    ],
  ),
);

Future<List<({double x, double y, String text})>> _drawnText(
  String markdown,
) async => drawnPdfStrings((await _bytes(markdown)).bytes);
