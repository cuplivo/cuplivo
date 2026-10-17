/// Reading a PDF the layout produced, for tests that assert what a reader sees.
///
/// These fixtures embed no face, so the writer's built-in font writes text as
/// literal `(…)` strings rather than as glyph indices and it comes back readable.
/// Positions are not the `Td` operand on its own: the layout indents with a canvas
/// translate, so the operator's x is widget-local and the one that moved is the
/// `1 0 0 1 tx ty cm` before it. The translations are tracked as a stack, which is
/// all the arithmetic needs — every one of them is a plain translation.
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

/// Every string a page draws, with the point it starts at.
List<({double x, double y, String text})> drawnPdfStrings(Uint8List bytes) {
  final tokens = RegExp(
    r'q|Q|cm|Td|TJ|\[(?:\s*-?\d+(?:\.\d+)?\s*|\((?:[^()\\]|\\.)*\))*\]|-?\d+(?:\.\d+)?',
    multiLine: true,
  ).allMatches(pdfStreams(bytes)).map((match) => match.group(0)!).toList();

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
        out.add((x: penX, y: penY, text: literalPdfTextOf(array)));
    }
  }
  return out;
}

/// The literal strings one `[…]TJ` array holds, concatenated.
///
/// A numeric element is a kerning adjustment rather than a character, which is
/// why the writer draws one *word* at a time and why a needle here is a word.
String literalPdfTextOf(String array) {
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
///
/// Public because a test may want the operators rather than the text: what a
/// drawing is can only be asked of the graphics calls, since a drawn tick and a
/// written `✓` leave different operators behind.
String pdfStreams(Uint8List bytes) {
  final raw = String.fromCharCodes(bytes);
  final out = StringBuffer();
  for (final match in RegExp(r'stream\r?\n').allMatches(raw)) {
    final end = raw.indexOf('endstream', match.end);
    if (end < 0) continue;
    out.write(_inflate(Uint8List.sublistView(bytes, match.end, end)));
  }
  return out.toString();
}

/// How often the graphics operators that draw rather than write appear.
///
/// `m`/`l`/`c` build a path and `S`/`f` paint one; `re` is a rectangle. A test
/// that says "a box with a tick was drawn" reads this, because no string in the
/// content stream can say it.
Map<String, int> pdfDrawingOperators(Uint8List bytes) =>
    RegExp(r'\b(re|m|l|c|S|f)\b').allMatches(pdfStreams(bytes)).fold(
      <String, int>{},
      (map, match) {
        final op = match.group(0)!;
        map[op] = (map[op] ?? 0) + 1;
        return map;
      },
    );

/// How often each text rendering mode is set, by the mode it sets.
///
/// A bold run is *stroked* as well as filled — the writer's way of drawing weight
/// for a face that has none — and `N Tr` is the operator that says so: mode 0 is
/// fill and mode 2 is fill-and-stroke. What a page sets and how often is the only
/// reading of "this run is bold and that one is not", because the face behind both
/// is the same file.
Map<int, int> pdfTextRenderingModes(Uint8List bytes) => RegExp(r'(\d+) Tr')
    .allMatches(pdfStreams(bytes))
    .fold(<int, int>{}, (map, match) {
      final mode = int.parse(match.group(1)!);
      map[mode] = (map[mode] ?? 0) + 1;
      return map;
    });

/// The size every text run is set in, in the order the pages set them.
///
/// A layout that draws a table cell or any other text through a widget of its own
/// hands the writer no style for it, and the writer answers with
/// `ThemeData.defaultTextStyle` — a size that appears nowhere in the layout's own
/// constants. `Tf` is the only reading of what a run was *actually* set in, so a
/// test that says "this cell is 9.15 points" has to come through here rather than
/// through the style the code meant to pass.
List<double> pdfFontSizes(Uint8List bytes) => RegExp(r'/\w+ ([\d.]+) Tf')
    .allMatches(pdfStreams(bytes))
    .map((match) => double.parse(match.group(1)!))
    .toList();

/// The line width in effect for each run that is *stroked*, in the order the page
/// strokes them.
///
/// A stroked run's weight is graphics state, not a text property, so the operator
/// that says "this run is bold" says nothing about how heavy it is: the width has
/// to be read from the `w` that was in effect when the `N Tr` was set. This is what
/// distinguishes a fake bold drawn at its own size from one that inherited whatever
/// drew last — a table's grid, an avatar's disc.
List<double> pdfBoldStrokeWidths(Uint8List bytes) {
  final out = <double>[];
  var width = 0.0;
  for (final token in RegExp(
    r'(-?[\d.]+) w\b|(\d+) Tr',
  ).allMatches(pdfStreams(bytes))) {
    final written = token.group(1);
    if (written != null) {
      width = double.parse(written);
      continue;
    }
    if (int.parse(token.group(2)!) != 0) out.add(width);
  }
  return out;
}

/// The rectangles the writer fills, with the colour each is filled in.
///
/// A filled panel — a message's tint, a card — is a rectangle and a fill, and its
/// *size* is what says whether the panels of two blocks touch: a block that stood
/// apart would leave its fill the same height and the page's flow further down.
List<({double width, double height, List<double> colour})> pdfFilledRects(
  Uint8List bytes,
) {
  final tokens = RegExp(
    r'(-?[\d.]+) (-?[\d.]+) (-?[\d.]+) (-?[\d.]+) re'
    r'|(-?[\d.]+) (-?[\d.]+) (-?[\d.]+) rg'
    r'|\b(?:m|l|c)\b|\bS\b|\bf\b',
  ).allMatches(pdfStreams(bytes)).map((match) => match.group(0)!).toList();

  final out = <({double width, double height, List<double> colour})>[];
  ({double width, double height})? rect;
  var colour = <double>[0, 0, 0];

  for (final token in tokens) {
    if (token.endsWith(' re')) {
      final parts = token.split(' ');
      rect = (width: double.parse(parts[2]), height: double.parse(parts[3]));
      continue;
    }
    if (token.endsWith(' rg')) {
      colour = token
          .split(' ')
          .take(3)
          .map(double.parse)
          .toList(growable: false);
      continue;
    }
    if (token == 'f') {
      if (rect != null) {
        out.add((width: rect.width, height: rect.height, colour: colour));
      }
      rect = null;
      continue;
    }
    // Any other path operator belongs to a shape that is not a rectangle.
    rect = null;
  }
  return out;
}

/// The size each picture is placed at, in the order the pages place them.
///
/// A picture is not a string: it is a transformation matrix — `<w> 0 0 <h> x y cm`
/// — followed by `Do`. Which is also why a test that asks "did this picture keep
/// the size its author gave" has to read the matrix rather than the text.
List<({double width, double height})> placedPdfImages(Uint8List bytes) =>
    RegExp(
      r'(-?[\d.]+) 0 0 (-?[\d.]+) -?[\d.]+ -?[\d.]+ cm\s*/\w+ Do',
    ).allMatches(pdfStreams(bytes)).map((match) {
      return (
        width: double.parse(match.group(1)!),
        height: double.parse(match.group(2)!),
      );
    }).toList();

/// The x of the one drawn word holding [word].
double pdfWordX(List<({double x, double y, String text})> drawn, String word) =>
    oneDrawnWord(drawn, word).x;

/// The y of the one drawn word holding [word].
double pdfWordY(List<({double x, double y, String text})> drawn, String word) =>
    oneDrawnWord(drawn, word).y;

/// The y of the one drawn word that *is* [text].
double pdfExactWordY(
  List<({double x, double y, String text})> drawn,
  String text,
) {
  final matches = drawn.where((line) => line.text == text).toList();
  expect(matches, hasLength(1), reason: 'expected one drawn "$text"');
  return matches.single.y;
}

/// What the leftmost thing on the line at [y] says.
///
/// The writer draws one *word* per text block, so "is the text on this line" is a
/// question about the line, not about a single drawn string.
String leftmostOnPdfLine(
  double y,
  List<({double x, double y, String text})> drawn,
) {
  final line = [
    for (final entry in drawn)
      if ((entry.y - y).abs() < 0.5) entry,
  ];
  expect(line, isNotEmpty);
  line.sort((a, b) => a.x.compareTo(b.x));
  return line.first.text;
}

/// Every drawn word on the line at [y], left to right.
List<({double x, double y, String text})> pdfLineAt(
  double y,
  List<({double x, double y, String text})> drawn,
) {
  final line = [
    for (final entry in drawn)
      if ((entry.y - y).abs() < 2.5) entry,
  ]..sort((a, b) => a.x.compareTo(b.x));
  return line;
}

({double x, double y, String text}) oneDrawnWord(
  List<({double x, double y, String text})> drawn,
  String word,
) {
  final matches = drawn.where((line) => line.text.contains(word)).toList();
  expect(matches, hasLength(1), reason: 'expected one drawn word "$word"');
  return matches.single;
}

String _unescape(String piece) {
  final body = piece.substring(1, piece.length - 1);
  final buffer = StringBuffer();
  for (var i = 0; i < body.length; i++) {
    if (body[i] != r'\') {
      buffer.write(body[i]);
      continue;
    }
    i++;
    if (i >= body.length) break;
    final next = body[i];
    switch (next) {
      case 'n':
        buffer.write('\n');
      case 'r':
        buffer.write('\r');
      case 't':
        buffer.write('\t');
      case '(':
        buffer.write('(');
      case ')':
        buffer.write(')');
      case r'\':
        buffer.write(r'\');
      default:
        buffer.write(next);
    }
  }
  return buffer.toString();
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
