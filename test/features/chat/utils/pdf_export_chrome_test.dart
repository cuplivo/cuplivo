import 'dart:typed_data';

import 'package:Cuplivo/features/chat/utils/export_document.dart';
import 'package:Cuplivo/features/chat/utils/markdown_pdf_emitter.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../../support/pdf_content_stream.dart';
import '../../../support/test_png.dart';

/// The page's message chrome, and the rhythm it sets prose in.
///
/// The screen heads a message with a disc, a name and a timestamp, sets a
/// reader's own messages on a tinted bubble, draws emphasis in a heavier weight
/// and separates blocks with the app's own spacing. A page has to reach the same
/// reading with the tools it has: one face, no bitmaps, and a flow that cannot put
/// a decorated box around content it must be able to break. What it does instead
/// is pinned here, because every one of those substitutions is a decision a later
/// change could quietly undo.
void main() {
  group('a speaker line', () {
    test(
      'names a reader\'s message with the label, and gives it no time',
      () async {
        final drawn = await _drawn(
          speaker: ExportSpeaker.user,
          roleName: 'cup11',
          blocks: <ExportBlock>[const ExportText('hello there')],
        );
        final texts = _texts(drawn);

        expect(texts, contains('User'));
        // Neither the profile's own name nor the message's time is this page's
        // business: an archive says who spoke, not who the reader is.
        expect(texts, isNot(contains('cup11')));
        expect(texts.where((text) => text.startsWith('2026')), isEmpty);
      },
    );

    test('keeps an assistant\'s name and puts its time underneath', () async {
      final drawn = await _drawn(
        blocks: <ExportBlock>[const ExportText('hello there')],
      );
      final texts = _texts(drawn);

      expect(texts, contains('Assistant'));
      expect(texts, contains('03:04:05'));
      // The time sits on the line below the name rather than beside it: 8.8
      // points of name over 7.4 of time, and the pair's own 2-point gap.
      final name = pdfWordY(drawn, 'Assistant');
      final time = pdfWordY(drawn, '03:04:05');
      expect(name - time, closeTo(10.9, 0.6));
    });

    test('draws the avatar disc for an assistant and not for a reader', () async {
      final assistant = await _export(
        blocks: <ExportBlock>[const ExportText('hello there')],
      );
      final user = await _export(
        speaker: ExportSpeaker.user,
        blocks: <ExportBlock>[const ExportText('hello there')],
      );

      // The disc is an ellipse: curves where the same page without it has none,
      // filled in the accent's own 10% tint.
      expect(
        pdfDrawingOperators(assistant.bytes)['c'] ?? 0,
        greaterThan(pdfDrawingOperators(user.bytes)['c'] ?? 0),
      );
      expect(_hasColour(assistant.bytes, 0.93020, 0.93608, 0.95725), isTrue);
      expect(_hasColour(user.bytes, 0.93020, 0.93608, 0.95725), isFalse);
    });
  });

  group('a reader\'s message', () {
    test('is one tinted panel, entered at the label\'s own left edge', () async {
      final result = await _export(
        speaker: ExportSpeaker.user,
        blocks: <ExportBlock>[
          const ExportText('first paragraph'),
          const ExportText('second paragraph'),
        ],
      );
      final drawn = drawnPdfStrings(result.bytes);

      // The tint is the accent over paper at 7%, which is the app's own bubble.
      expect(_hasColour(result.bytes, 0.95114, 0.95525, 0.97008), isTrue);
      // The label and the text under it start in one column — the band's inset.
      expect(pdfWordX(drawn, 'User'), pdfWordX(drawn, 'first'));

      // One panel, not two: each block's fill is exactly as tall as the step from
      // one block's text to the next, so the fills touch. A gap between the blocks
      // would leave the fills the same size and the page further down.
      final fills = pdfFilledRects(
        result.bytes,
      ).where((fill) => fill.width > 400).toList();
      expect(fills, hasLength(2));
      final step = pdfWordY(drawn, 'first') - pdfWordY(drawn, 'second');
      expect(fills.first.height, closeTo(step, 0.1));
    });
  });

  group('emphasis', () {
    test('is stroked, and only the run that asked for it', () async {
      final plain = await _export(
        blocks: <ExportBlock>[const ExportText('plain bold tail')],
      );
      final bold = await _export(
        blocks: <ExportBlock>[const ExportText('plain **bold** tail')],
      );
      final modes = pdfTextRenderingModes(plain.bytes);
      final boldModes = pdfTextRenderingModes(bold.bytes);

      // Fill alone is the page's default; the one stroke the plain page has is
      // the document's title. The bold run is the only addition — the face behind
      // both is the same file, so this operator is all that tells them apart.
      expect(modes[0], isNotNull);
      expect(boldModes[2]! - modes[2]!, 1);
      // The stroke is 3% of the run's size, which is what makes it read as weight
      // rather than as an outline: a stroke widens every contour it follows, so the
      // fraction that reads as the screen's semibold is well under the one a real
      // bold face's stem difference would suggest.
      expect(_lineWidths(bold.bytes), contains(closeTo(0.315, 0.001)));
    });
  });

  group('a table', () {
    const header = '| Head | Other |\n| --- | --- |\n';
    // The screen sets a header at 13 logical pixels and a cell at 13.5 beside
    // 15.5-point prose, so the page takes the same ratios of its own size.
    const headerSize = 13.0 * (10.5 / 15.5);
    const cellSize = 13.5 * (10.5 / 15.5);

    test('sets its cells at the screen\'s own sizes, not the writer\'s', () async {
      final result = await _export(
        blocks: <ExportBlock>[const ExportText('$header| cell | plain |\n')],
      );
      final sizes = pdfFontSizes(result.bytes);

      expect(sizes, contains(closeTo(headerSize, 0.01)));
      expect(sizes, contains(closeTo(cellSize, 0.01)));
      // And nothing is set at the writer's own cell default: a cell whose text
      // crosses as a plain string is drawn with `ThemeData.defaultTextStyle` — 12
      // points, larger than this page's prose and larger than its own header.
      expect(sizes, isNot(contains(closeTo(12.0, 0.01))));
    });

    test(
      'gives an emphasised cell the cell\'s size and the cell\'s stroke',
      () async {
        final plain = await _export(
          blocks: <ExportBlock>[const ExportText('$header| cell | plain |\n')],
        );
        final bold = await _export(
          blocks: <ExportBlock>[
            const ExportText('$header| **cell** | plain |\n'),
          ],
        );

        // Emphasis inside a cell changes nothing about the type: it used to come out
        // at the body's 10.5, a quarter smaller than the text beside it.
        expect(
          pdfFontSizes(bold.bytes).toSet(),
          pdfFontSizes(plain.bytes).toSet(),
        );
        expect(
          pdfTextRenderingModes(bold.bytes)[2]! -
              pdfTextRenderingModes(plain.bytes)[2]!,
          1,
        );
        // The stroke is the cell's own width, set by the cell's wrapper — not the
        // 0.5 the table's grid leaves in the graphics state, and not the header's
        // own width either.
        expect(
          pdfBoldStrokeWidths(bold.bytes),
          contains(closeTo(cellSize * 0.03, 0.001)),
        );
        expect(
          pdfBoldStrokeWidths(plain.bytes),
          isNot(contains(closeTo(cellSize * 0.03, 0.001))),
        );
      },
    );
  });

  group('the page\'s rhythm', () {
    test('stands the document\'s title off the time under it', () async {
      final drawn = await _drawn(
        // The message's own time is the same string, so the export time is what
        // this asks about and it has to be one of its own.
        subtitle: '2026-03-04 09:09:09',
        blocks: <ExportBlock>[const ExportText('body line')],
      );

      expect(
        pdfWordY(drawn, 'Title') - pdfWordY(drawn, '09:09:09'),
        closeTo(18.7, 0.6),
      );
    });

    test(
      'gives a heading, a list and a paragraph each their own gap',
      () async {
        final heading = await _drawn(
          blocks: <ExportBlock>[const ExportText('## Head\nbody line\n')],
        );
        expect(
          pdfWordY(heading, 'Head') - pdfWordY(heading, 'body'),
          closeTo(31.7, 0.6),
        );

        final list = await _drawn(
          blocks: <ExportBlock>[const ExportText('- one\n- two\n')],
        );
        expect(
          pdfWordY(list, 'one') - pdfWordY(list, 'two'),
          closeTo(20.1, 0.5),
        );

        final paragraphs = await _drawn(
          blocks: <ExportBlock>[
            const ExportText('para one'),
            const ExportText('para two'),
          ],
        );
        expect(
          pdfWordY(paragraphs, 'one') - pdfWordY(paragraphs, 'two'),
          closeTo(20.1, 0.5),
        );
      },
    );

    test('draws a blank line the source wrote as a paragraph gap', () async {
      // One block, two paragraphs: the walk has no paragraph component, so a run
      // of prose arrives as one text node with the blank line still inside it —
      // and drawing that literally costs two line pitches for one gap.
      final drawn = await _drawn(
        blocks: <ExportBlock>[const ExportText('para one\n\npara two')],
      );
      final texts = _texts(drawn);
      expect(texts, contains('one'));
      expect(texts, contains('two'));
      expect(
        pdfWordY(drawn, 'one') - pdfWordY(drawn, 'two'),
        closeTo(20.1, 0.5),
      );
    });

    test('separates two paragraphs by more than a line break', () async {
      // The review of a first page found the block rhythm cramped: a paragraph
      // break was five points over a 15.8-point line pitch, which reads as one
      // more line rather than as a new paragraph. What is pinned here is the
      // difference rather than the figure: a break has to stand out from the
      // page's own leading, or a page of prose is a wall.
      final wrapped = List<String>.generate(
        60,
        (index) => 'word${index % 7}',
      ).join(' ');
      final lines = await _bodyLines(wrapped);
      expect(lines.length, greaterThan(2));
      final pitch = lines.first - lines[1];

      final paragraphs = await _drawn(
        blocks: <ExportBlock>[
          const ExportText('para one'),
          const ExportText('para two'),
        ],
      );
      final block = pdfWordY(paragraphs, 'one') - pdfWordY(paragraphs, 'two');
      expect(block, greaterThan(pitch + 2));
      expect(pitch, closeTo(16.8, 0.4));
    });
  });

  group('a formula in a line of prose', () {
    test('is shrunk into the line rather than allowed to move the next one', () async {
      final body = List<String>.generate(
        30,
        (index) => 'word${index % 5}',
      ).join(' ');
      final withFormula =
          '${body.substring(0, 70)} \$x^2\$ ${body.substring(70)}';
      final rasters = <String, PdfRaster>{
        for (final key in pdfRasterKeysIn(
          withFormula,
          enableMathRendering: true,
          enableDollarLatex: true,
        ))
          pdfRasterLookupKey(key): PdfRaster(
            bytes: pngForTest(width: 80, height: 40),
            // Twice the height a line of prose has: the writer would advance the
            // line after it by the overhang, which is how a paragraph of formulas
            // turns into a paragraph of gaps.
            width: 80,
            height: 40,
          ),
      };

      final plain = await _bodyLines(body);
      final formulaLines = await _bodyLines(withFormula, rasters: rasters);
      final result = await _export(
        speaker: ExportSpeaker.user,
        blocks: <ExportBlock>[ExportText(withFormula)],
        rasters: rasters,
      );
      final placed = placedPdfImages(result.bytes);
      expect(placed, hasLength(1));
      expect(placed.single.height, closeTo(13.125, 0.01));
      // Its shape survives the clamp: a wide formula stays wide.
      expect(placed.single.width / placed.single.height, closeTo(2.0, 0.01));

      // And the paragraph keeps its own rhythm: no line is pushed further than a
      // point and a half below the pitch the same paragraph has without a formula.
      final pitch = plain.first - plain[1];
      expect(pitch, closeTo(16.8, 0.5));
      expect(formulaLines.length, greaterThanOrEqualTo(plain.length - 1));
      for (var index = 0; index + 1 < formulaLines.length; index++) {
        expect(
          formulaLines[index] - formulaLines[index + 1],
          lessThan(pitch + 1.5),
          reason: 'line $index is pushed down by the formula above it',
        );
      }
    });
  });
}

/// The baselines of one reader's message's body, top to bottom.
Future<List<double>> _bodyLines(
  String markdown, {
  Map<String, PdfRaster> rasters = const <String, PdfRaster>{},
}) async {
  final drawn = (await _drawn(
    speaker: ExportSpeaker.user,
    blocks: <ExportBlock>[ExportText(markdown)],
    rasters: rasters,
  ));
  final label = pdfWordY(drawn, 'User');
  final lines = <double>{
    for (final line in drawn)
      // Above the footer, below the label: the body, and nothing else.
      if (line.y > 100 && line.y < label - 1) line.y,
  }.toList()..sort((a, b) => b.compareTo(a));
  return lines;
}

PdfExportRequest _request({
  ExportSpeaker speaker = ExportSpeaker.assistant,
  String roleName = 'Assistant',
  String? subtitle,
  List<ExportBlock>? blocks,
  Map<String, PdfRaster> rasters = const <String, PdfRaster>{},
}) => PdfExportRequest(
  title: 'Title',
  subtitle: subtitle,
  thinkingLabel: 'Thinking',
  accent: kPdfPageAccent,
  muted: kPdfPageMuted,
  userLabel: 'User',
  messages: <ExportMessage>[
    ExportMessage(
      time: '2026-01-02 03:04:05',
      roleName: roleName,
      speaker: speaker,
      blocks: blocks ?? <ExportBlock>[const ExportText('body line')],
    ),
  ],
  rasters: rasters,
);

Future<PdfExportResult> _export({
  ExportSpeaker speaker = ExportSpeaker.assistant,
  String roleName = 'Assistant',
  String? subtitle,
  List<ExportBlock>? blocks,
  Map<String, PdfRaster> rasters = const <String, PdfRaster>{},
}) => buildConversationPdf(
  _request(
    speaker: speaker,
    roleName: roleName,
    subtitle: subtitle,
    blocks: blocks,
    rasters: rasters,
  ),
);

Future<List<({double x, double y, String text})>> _drawn({
  ExportSpeaker speaker = ExportSpeaker.assistant,
  String roleName = 'Assistant',
  String? subtitle,
  List<ExportBlock>? blocks,
  Map<String, PdfRaster> rasters = const <String, PdfRaster>{},
}) async => drawnPdfStrings(
  (await _export(
    speaker: speaker,
    roleName: roleName,
    subtitle: subtitle,
    blocks: blocks,
    rasters: rasters,
  )).bytes,
);

List<String> _texts(List<({double x, double y, String text})> drawn) =>
    drawn.map((line) => line.text).toList();

/// Whether any fill in [bytes] is the colour [r], [g], [b] as the writer spells
/// it. The writer trims trailing zeros, so the comparison is numeric.
bool _hasColour(Uint8List bytes, double r, double g, double b) =>
    RegExp(r'(-?[\d.]+) (-?[\d.]+) (-?[\d.]+) rg')
        .allMatches(pdfStreams(bytes))
        .any(
          (match) =>
              (double.parse(match.group(1)!) - r).abs() < 0.0001 &&
              (double.parse(match.group(2)!) - g).abs() < 0.0001 &&
              (double.parse(match.group(3)!) - b).abs() < 0.0001,
        );

Set<double> _lineWidths(Uint8List bytes) => RegExp(r'(-?[\d.]+) w\b')
    .allMatches(pdfStreams(bytes))
    .map((match) => double.parse(match.group(1)!))
    .toSet();
