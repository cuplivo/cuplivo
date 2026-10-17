import 'dart:io';
import 'dart:typed_data';

import 'package:Cuplivo/features/chat/utils/export_document.dart';
import 'package:Cuplivo/features/chat/utils/markdown_pdf_emitter.dart';
import 'package:flutter_test/flutter_test.dart';

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
      expect(_xOf(flat, 'alpha'), _xOf(flat, 'bravo'));
      expect(_xOf(flat, 'bravo'), _xOf(flat, 'charlie'));

      expect(_xOf(nested, 'bravo') - _xOf(nested, 'alpha'), closeTo(14, 0.01));
      expect(
        _xOf(nested, 'charlie') - _xOf(nested, 'bravo'),
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
    expect(_leftmostOn(_yOf(inline, 'area'), inline), '-');

    // A link's node is a group, which is the same trap by another route.
    final link = await _drawnText('- [docs](https://example.com) and more\n');
    expect(_leftmostOn(_yOf(link, 'more'), link), '-');
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
      expect(_yOfExact(block, '-'), isNot(closeTo(_yOf(block, 'frac'), 0.5)));
      expect(_leftmostOn(_yOf(block, 'frac'), block), isNot('-'));
    },
  );

  test('a list inside a quote is indented by both', () async {
    final quoted = await _drawnText('> - alpha\n>   - bravo\n');
    final plain = await _drawnText('- alpha\n  - bravo\n');
    expect(_xOf(quoted, 'bravo') - _xOf(quoted, 'alpha'), closeTo(14, 0.01));
    // And the quote itself sets its body in from the margin.
    expect(_xOf(quoted, 'alpha'), greaterThan(_xOf(plain, 'alpha')));
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
    messages: <ExportMessage>[
      ExportMessage(
        time: '2026-01-02 03:04:05',
        roleName: 'Assistant',
        blocks: <ExportBlock>[ExportText(markdown)],
      ),
    ],
  ),
);

Future<List<({double x, double y, String text})>> _drawnText(
  String markdown,
) async => _drawnStrings((await _bytes(markdown)).bytes);

/// The x of the one drawn word holding [word].
double _xOf(List<({double x, double y, String text})> drawn, String word) =>
    _one(drawn, word).x;

/// The y of the one drawn word holding [word].
double _yOf(List<({double x, double y, String text})> drawn, String word) =>
    _one(drawn, word).y;

double _yOfExact(List<({double x, double y, String text})> drawn, String text) {
  final matches = drawn.where((line) => line.text == text).toList();
  expect(matches, hasLength(1), reason: 'expected one drawn "$text"');
  return matches.single.y;
}

/// What the leftmost thing on the line at [y] says.
///
/// The writer draws one *word* per text block, so "is the text on this line" is a
/// question about the line, not about a single drawn string.
String _leftmostOn(double y, List<({double x, double y, String text})> drawn) {
  final line = [
    for (final entry in drawn)
      if ((entry.y - y).abs() < 0.5) entry,
  ];
  expect(line, isNotEmpty);
  line.sort((a, b) => a.x.compareTo(b.x));
  return line.first.text;
}

({double x, double y, String text}) _one(
  List<({double x, double y, String text})> drawn,
  String word,
) {
  final matches = drawn.where((line) => line.text.contains(word)).toList();
  expect(matches, hasLength(1), reason: 'expected one drawn word "$word"');
  return matches.single;
}

/// Every string a page draws, with the point it starts at.
///
/// These fixtures embed no face, so the writer's built-in font writes text as
/// literal `(…)` strings rather than as glyph indices and it comes back readable.
/// A position is not the `Td` operand on its own: the layout indents with a canvas
/// translate, so the operator's x is widget-local and the one that moved is the
/// `1 0 0 1 tx ty cm` before it. The translations are tracked as a stack, which is
/// all the arithmetic needs — every one of them is a plain translation.
List<({double x, double y, String text})> _drawnStrings(Uint8List bytes) {
  final tokens = RegExp(
    r'q|Q|cm|Td|TJ|\[[^\]]*\]|-?\d+(?:\.\d+)?',
    multiLine: true,
  ).allMatches(_streams(bytes)).map((match) => match.group(0)!).toList();

  final out = <({double x, double y, String text})>[];
  final stack = <({double x, double y})>[(x: 0.0, y: 0.0)];
  var tx = 0.0;
  var ty = 0.0;
  var penX = 0.0;
  var penY = 0.0;

  for (var index = 0; index < tokens.length; index++) {
    switch (tokens[index]) {
      case 'q':
        stack.add((x: tx, y: ty));
      case 'Q':
        if (stack.length > 1) {
          final top = stack.removeLast();
          tx = top.x;
          ty = top.y;
        }
      case 'cm':
        if (index >= 6) {
          // The last two operands of the matrix are the translation, and
          // translations compose by adding.
          tx = stack.last.x + double.parse(tokens[index - 2]);
          ty = stack.last.y + double.parse(tokens[index - 1]);
        }
      case 'Td':
        if (index >= 2) {
          penX = tx + double.parse(tokens[index - 2]);
          penY = ty + double.parse(tokens[index - 1]);
        }
      case 'TJ':
        final array = index >= 1 ? tokens[index - 1] : '';
        if (!array.startsWith('[')) break;
        out.add((x: penX, y: penY, text: _literalTextOf(array)));
    }
  }
  return out;
}

/// The literal strings one `[…]TJ` array holds, concatenated.
///
/// A numeric element is a kerning adjustment rather than a character, which is
/// why the writer draws one *word* at a time and why a needle here is a word.
String _literalTextOf(String array) {
  final buffer = StringBuffer();
  for (final piece in RegExp(
    r'\((?:[^()\\]|\\.)*\)',
    dotAll: true,
  ).allMatches(array)) {
    buffer.write(_unescape(piece.group(0)!));
  }
  return buffer.toString();
}

/// Everything the file's streams hold, inflated.
///
/// The writer deflates a page's content, so its operators are not in the file's
/// own bytes. A stream that will not inflate is one that was not deflated.
String _streams(Uint8List bytes) {
  final raw = String.fromCharCodes(bytes);
  final out = StringBuffer();
  for (final match in RegExp(r'stream\r?\n').allMatches(raw)) {
    final end = raw.indexOf('endstream', match.end);
    if (end < 0) continue;
    out.write(_inflate(Uint8List.sublistView(bytes, match.end, end)));
  }
  return out.toString();
}

String _inflate(Uint8List slice) {
  final candidates = <Uint8List>[
    slice,
    Uint8List.sublistView(slice, 0, _trimmedEnd(slice)),
  ];
  for (final candidate in candidates) {
    if (candidate.isEmpty) continue;
    try {
      return String.fromCharCodes(ZLibDecoder().convert(candidate));
    } catch (_) {
      // Not deflated, or not deflated with its trailing newline included.
    }
  }
  return String.fromCharCodes(slice);
}

int _trimmedEnd(Uint8List slice) {
  var end = slice.length;
  while (end > 0 &&
      (slice[end - 1] == 0x0A ||
          slice[end - 1] == 0x0D ||
          slice[end - 1] == 0x20)) {
    end--;
  }
  return end;
}

String _unescape(String literal) {
  final inner = literal.substring(1, literal.length - 1);
  final out = StringBuffer();
  for (var index = 0; index < inner.length; index++) {
    final char = inner[index];
    if (char != r'\') {
      out.write(char);
      continue;
    }
    index++;
    if (index >= inner.length) break;
    out.write(switch (inner[index]) {
      'n' => '\n',
      'r' => '\r',
      't' => '\t',
      'b' => '\b',
      'f' => '\f',
      final other => other,
    });
  }
  return out.toString();
}
