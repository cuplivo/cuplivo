import 'dart:typed_data';

import 'package:Cuplivo/features/chat/utils/export_document.dart';
import 'package:Cuplivo/features/chat/utils/markdown_pdf_emitter.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as image_lib;
import 'package:syncfusion_flutter_pdf/pdf.dart' as syncfusion;

/// How a formula reaches the page.
///
/// The writer cannot typeset TeX. A formula is therefore a picture the caller
/// draws beforehand and files under the key the walk names — and the *only*
/// difference between a formula set in a line of prose and one set as a block of
/// its own is which of those two keys it was filed under. Both halves of that
/// contract are pinned here, with the bitmap handed in rather than captured: a
/// capture needs a frame, and a frame is exactly what a widget test cannot drive.
void main() {
  test('an inline formula is a picture, and its TeX is gone', () async {
    const markdown = 'before \$x^2\$ after';
    final withRaster = await _export(markdown, rasters: _rastersFor(markdown));

    expect(_imagesIn(withRaster.bytes), greaterThan(0));
    // The picture stands in for the TeX, so the TeX is not also printed.
    expect(withRaster.text, isNot(contains('x^2')));
    expect(withRaster.text, contains('before'));
    expect(withRaster.text, contains('after'));
  });

  test('an inline formula with no picture degrades to its own TeX', () async {
    final exported = await _export('before \$x^2\$ after');

    expect(_imagesIn(exported.bytes), 0);
    expect(exported.text, contains('x^2'));
  });

  test('a block formula is a picture too, and keeps its own key', () async {
    const markdown = 'text\n\n\$\$\\int_0^1 x^2\\,dx\$\$\n';
    final exported = await _export(markdown, rasters: _rastersFor(markdown));

    expect(_imagesIn(exported.bytes), greaterThan(0));
    expect(exported.text, isNot(contains('int_0')));
  });

  test('a picture filed for a line of prose is not used for a block', () async {
    // The same TeX, drawn inline: a block formula must not pick that entry up,
    // because the two are drawn at different sizes and styles.
    final exported = await _export(
      'text\n\n\$\$x^2\$\$\n',
      rasters: _rastersFor('so \$x^2\$ holds'),
    );

    expect(_imagesIn(exported.bytes), 0);
    expect(exported.text, contains('x^2'));
  });

  test('a formula nested in a quote, a cell or a details body is drawn', () async {
    // The layout re-walks those bodies, so the key it asks for is the key this
    // walk has to name. Before the walk re-entered them the caller was handed no
    // key for the nested TeX, laid out no picture for it, and the page printed
    // the formula's own source instead of the drawing the screen shows.
    const quoted = '> quoted prose\n>\n> \$\$x^2\$\$\n';
    final inQuote = await _export(quoted, rasters: _rastersFor(quoted));
    expect(_imagesIn(inQuote.bytes), greaterThan(0));
    expect(inQuote.text, contains('quoted prose'));
    expect(inQuote.text, isNot(contains('x^2')));

    const cell = '| a | b |\n| --- | --- |\n| \$x^2\$ | c |\n';
    final inCell = await _export(cell, rasters: _rastersFor(cell));
    expect(_imagesIn(inCell.bytes), greaterThan(0));
    expect(inCell.text, isNot(contains('x^2')));

    const details =
        '<details>\n<summary>s</summary>\n\n\$\$x^2\$\$\n\n</details>\n';
    final inDetails = await _export(details, rasters: _rastersFor(details));
    expect(_imagesIn(inDetails.bytes), greaterThan(0));
    expect(inDetails.text, isNot(contains('x^2')));
  });

  test('a diagram fence inside a quote is drawn as its picture', () async {
    const markdown = '> ```mermaid\n> graph TD;\n>   A-->B;\n> ```\n';
    final exported = await _export(markdown, rasters: _rastersFor(markdown));

    expect(_imagesIn(exported.bytes), greaterThan(0));
    // The picture stands in for the fence's code, so the code is not printed.
    expect(exported.text, isNot(contains('A-->B')));
  });

  test('a diagram fence is a picture, and its code is gone', () async {
    const markdown = '```mermaid\ngraph TD;\n  A-->B;\n```\n';
    final exported = await _export(markdown, rasters: _rastersFor(markdown));

    expect(_imagesIn(exported.bytes), greaterThan(0));
    expect(exported.text, isNot(contains('A-->B')));
  });

  test('a diagram with no picture falls back to its code', () async {
    final exported = await _export('```mermaid\ngraph TD;\n  A-->B;\n```\n');

    expect(_imagesIn(exported.bytes), 0);
    expect(exported.text, contains('A-->B'));
  });
}

/// A stand-in for everything the walk asks to have drawn in [markdown].
///
/// The keys come from the walk rather than from a literal, which is the contract
/// under test: the bridge files what it draws under the names the keys give, and
/// a key spelled out by hand here could agree with the test and disagree with the
/// layout.
Map<String, PdfRaster> _rastersFor(String markdown) => <String, PdfRaster>{
  for (final key in pdfRasterKeysIn(
    markdown,
    enableMathRendering: true,
    enableDollarLatex: true,
  ))
    pdfRasterLookupKey(key): _raster(),
};

class _Exported {
  _Exported(this.bytes, this.text);

  final Uint8List bytes;
  final String text;
}

Future<_Exported> _export(
  String markdown, {
  Map<String, PdfRaster> rasters = const <String, PdfRaster>{},
}) async {
  final bytes = (await buildConversationPdf(
    PdfExportRequest(
      title: 'math probe',
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
      rasters: rasters,
    ),
  )).bytes;

  final readBack = syncfusion.PdfDocument(inputBytes: bytes);
  addTearDown(readBack.dispose);
  return _Exported(
    bytes,
    syncfusion.PdfTextExtractor(
      readBack,
    ).extractText().replaceAll(RegExp(r'\s+'), ' ').trim(),
  );
}

/// How many pictures a document draws.
///
/// The writer's object syntax is plain text in the file, so counting image
/// XObjects is a direct reading of what was embedded rather than an inference
/// from the picture's bytes surviving.
int _imagesIn(Uint8List bytes) =>
    RegExp(r'/Subtype\s*/Image').allMatches(String.fromCharCodes(bytes)).length;

/// A stand-in for a captured formula: a small opaque picture.
PdfRaster _raster() =>
    PdfRaster(bytes: _png(width: 60, height: 24), width: 60, height: 24);

Uint8List _png({required int width, required int height}) {
  final image = image_lib.Image(width: width, height: height);
  for (var y = 0; y < height; y++) {
    for (var x = 0; x < width; x++) {
      image.setPixelRgb(x, y, 31, 35, 40);
    }
  }
  return Uint8List.fromList(image_lib.encodePng(image));
}
