import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/painting.dart' show FontStyle, FontWeight, TextAlign;
import 'package:flutter_highlight/themes/github.dart';
import 'package:highlight/highlight.dart' show Node, highlight;
import 'package:image/image.dart' as image_lib;
import 'package:markstream/markstream_core.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

import '../../../shared/markdown/citation_syntax.dart';
import '../../../shared/markdown/kelivo_markdown_extensions.dart';
import '../../../shared/markdown/link_image_handlers.dart';
import '../../../shared/markdown/markdown_theme_mapper.dart';
import '../../../utils/svg_preview_html.dart';
import 'citation_index.dart';
import 'export_document.dart';

// The page is always light. A PDF is a thing that gets printed and archived, and
// a dark page is the wrong artefact for both; the block fills are the light ones
// the chat draws with.
const PdfColor _ink = PdfColor.fromInt(0xFF1F2328);
const PdfColor _ruleInk = PdfColor.fromInt(0xFFD8DEE4);
const PdfColor _blockFill = PdfColor.fromInt(0xFFF6F8FA);
const PdfColor _quoteRuleInk = PdfColor.fromInt(0xFFC4CCD4);
const PdfColor _quoteInk = PdfColor.fromInt(0xFF454F59);

/// The accent a light page falls back to when its owner has no palette to give
/// it: the fork's own indigo, dark enough to read as a link on white.
///
/// A caller that knows the app's light palette passes it as
/// [PdfExportRequest.accent] instead — a PDF is still the app's document, and a
/// link that is a different blue from every other link the app draws is a
/// difference a reader notices.
const PdfColor kPdfPageAccent = PdfColor.fromInt(0xFF4D5C92);

/// The quiet ink a light page falls back to: timestamps, captions, page
/// furniture, and the reference a picture stands in for.
const PdfColor kPdfPageMuted = PdfColor.fromInt(0xFF59636E);

/// [colour] laid over the page's white at [amount], the way the app's own
/// `alphaBlend` lays a tint over its surface.
///
/// The page is opaque paper and this layout composites nothing, so a tint has to
/// be resolved into a solid colour rather than carried as an alpha.
PdfColor _overWhite(PdfColor colour, double amount) => PdfColor(
  colour.red * amount + (1 - amount),
  colour.green * amount + (1 - amount),
  colour.blue * amount + (1 - amount),
);

const double _marginTop = 40;
const double _marginBottom = 42;
const double _marginHorizontal = 46;

/// A4 with a 46pt margin on each side.
final double _contentWidth = PdfPageFormat.a4.width - 2 * _marginHorizontal;

/// What one page offers, before the header and footer take their share.
final double _pageContentHeight =
    PdfPageFormat.a4.height - _marginTop - _marginBottom;

/// The tallest a thing that cannot break across pages may be.
///
/// A page holds [_pageContentHeight] between the margins, but never all of it for
/// something unbreakable. A running header and a page number take 17.25 and
/// 19.25 points (measured), a table repeats its header row, a table cell carries
/// its own padding, and a page that already has a title on it has less room than
/// a fresh one. A table is also the worst case on purpose: it always answers
/// `hasMoreWidgets`, so a row that cannot fit the space it lands in makes the
/// writer lay that row out again for ever — a hang in a release build, where the
/// writer's page guard is compiled out. Measured on this layout: a row of 680
/// points pages, a row of 690 does not.
///
/// So the cap is a fraction rather than a figure: it scales with the page, and it
/// leaves enough for the furniture measured above.
final double _maxUnbreakableHeight = _pageContentHeight * 0.85;

/// How far one level of nesting moves a block, in points.
const double _indentStep = 14;

/// The deepest level the source indentation is allowed to claim.
///
/// Six levels is 84 points, and a list indented further than that is a formatting
/// accident rather than a structure: the cap keeps a runaway indentation from
/// squeezing the text off the page, and it is also what makes the indentation
/// function total for any offset in any source.
const int _maxIndentLevels = 6;

/// How far a quote's body sits inside its rule, in points.
const double _quoteInset = 10;

/// The size a conversation page sets its prose in, in points.
///
/// The rasterizer needs it too: an inline formula is drawn at this size and
/// embedded at the size it was drawn, so that both halves of the export agree
/// on how tall a line of text is.
const double kPdfBodyFontSize = 10.5;

/// The factor a size the app measured in logical pixels keeps on the page.
///
/// The page sets prose at [kPdfBodyFontSize] where the markdown surface sets it
/// at [kMarkdownBodyFontSize], so everything whose size was written next to that
/// text — a citation capsule's pill, a task checkbox, an author's `WxH` image
/// size — is scaled by the ratio rather than taken as points.
const double _pageScale = kPdfBodyFontSize / kMarkdownBodyFontSize;

/// A task checkbox, and what it holds: the app's 18-point box, 14-point tick and
/// 10-point radio dot.
const double _taskBoxSize = 18 * _pageScale;
const double _taskTickSize = 14 * _pageScale;
const double _taskDotSize = 10 * _pageScale;

/// The speaker line above a message, at the screen's own proportions.
///
/// The renderer heads a message with a 32-point disc and a 13-point name over an
/// 11-point timestamp, both in a lighter ink than the prose. The page draws the
/// same structure at its own scale, and draws the disc *filled* rather than
/// painted: the picture behind it is per message, and a page has no bitmap to
/// fetch — see [PdfExportRequest.assistantIcon].
const double _avatarSize = 32 * _pageScale;
const double _avatarGlyphSize = 18 * _pageScale;
const double _avatarGap = 8 * _pageScale;
const double _speakerNameSize = 13 * _pageScale;
const double _speakerTimeSize = 11 * _pageScale;

/// How far the timestamp sits under the name it belongs to, in points.
///
/// The screen lets the two line boxes touch; on paper they read as one block, so
/// the page gives the pair a little air.
const double _speakerTimeGap = 2;

/// How far a message's body sits under its speaker line, in points.
const double _speakerBottom = 8 * _pageScale;

/// The tint a reader's own messages are set on, and the disc's own fill.
const double _speakerNameAlpha = 0.70;
const double _speakerTimeAlpha = 0.50;
const double _avatarFillAlpha = 0.10;
const double _userBandAlpha = 0.07;

/// How far a user band insets its text, and pads above and below it.
const double _userBandInset = 10;
const double _userBandPad = 4;

/// The document header's own rhythm, and a message's.
///
/// The title and the line under it are two pieces of furniture a reader looks at
/// once, so the first gap is the one place on the page that is allowed to be
/// generous. Everything below it is prose, and prose is what the page is for.
const double _titleGap = 6;
const double _messageRuleHeight = 12;

/// How far a block of prose sits from the block after it, in points.
///
/// The screen separates two blocks with a blank line — a chat convention rather
/// than a typesetting one — and a printed page that airy spends a fifth of its
/// length on nothing. This is the compromise the first export already made, and a
/// first review of a page found it too tight: at 5 points a paragraph break read as
/// nothing more than a line break, because the writer adds its leading *between*
/// lines and a paragraph's box is only the face's own height. At 8 it is half a
/// line at the page's own leading, which is what a printed paragraph break is.
///
/// A list is not spaced differently on purpose: its items carry this gap too (see
/// [_listItem]'s first run, which wears the body's own skin), so a list stands off
/// its surroundings exactly as one paragraph stands off another.
const double _paragraphGap = 8;

/// A heading's own margins, and how far a picture or a table stands apart.
///
/// The two figures are not symmetric, and the lower one is the measured answer
/// rather than a choice. A heading is one line box — the writer adds its leading
/// *between* lines, so a single-line leaf is only as tall as its face, 14.9 points
/// at the second level's 13.5 — and the stand-off a reviewed page has under a
/// heading is about 31 points between baselines. The padding is what carries the
/// difference (31 − 14.9 + the two faces' ascent difference), which is why it is
/// far larger than [_paragraphGap]: a heading that sat closer to its body than two
/// paragraphs sit to each other would read as a bold first line rather than as a
/// title over a section.
const double _headingTop = 10;
const double _headingBottom = 19;
const double _asideGap = 3;

/// How far two items of one list sit apart, in points.
const double _listItemGap = 2;

/// How thick the stroke a *fake* bold is drawn with is, as a fraction of size.
///
/// The theme maps every weight onto the one face an export can embed, so
/// `fontWeight: bold` on its own draws nothing different — a page of headings and
/// `**emphasis**` then reads as a page of plain prose, which is the loudest
/// difference between the PDF and the screen. What the writer *can* do is fill and
/// stroke a glyph in one pass (`PdfTextRenderingMode.fillAndStroke`); 3% of the
/// size is what a synthetic bold looks like. It is measured against what it has to
/// add up to: a stroke widens *every* contour it follows, the inside of a counter
/// as much as the outside of a stem, and a CJK crossbar at this size is thinner
/// than a Latin stem — so the fraction that reads as the screen's w600 is lower
/// than the one a real bold face's stem difference would suggest. At 4% a page of
/// Chinese came out heavy enough to close its own counters.
const double _fauxBoldStroke = 0.03;

/// The size a table's header and its cells are set in, in points.
///
/// The screen sets a header at 13 logical pixels and a cell at 13.5 — the header
/// smaller, and heavier for it — beside 15.5-point prose, so the page takes the
/// same ratios of its own size. The pair is also the only place in this layout
/// where a writer default can be read: a table cell's text is drawn by a widget
/// this layout builds, and the writer answers a cell's missing style with
/// `ThemeData.defaultTextStyle` — 12 points, larger than this page's prose. Every
/// cell therefore carries its own style (see [_PdfLayout._tableCell]).
const double _tableHeaderSize = 13.0 * _pageScale;
const double _tableCellSize = 13.5 * _pageScale;

/// What a raster stands in for, which is also how it has to be drawn.
enum PdfRasterKind {
  /// A formula: TeX the writer cannot typeset, so it is drawn by the math
  /// widget and embedded as a picture.
  math,

  /// A diagram fence — mermaid, an SVG document or PlantUML.
  diagram,
}

/// One drawing a caller has to produce before the layout runs.
class PdfRasterKey {
  const PdfRasterKey({
    required this.source,
    required this.kind,
    this.language = '',
    this.display = false,
  });

  /// What the drawing stands in for — a formula's TeX, or a fence's code — and
  /// the key [PdfExportRequest.rasters] is looked up with.
  final String source;

  final PdfRasterKind kind;

  /// A diagram's fence language, which decides how it is drawn.
  final String language;

  /// Whether a formula was written as a display block rather than inline, which
  /// decides how large it is drawn.
  final bool display;
}

/// A bitmap an export embeds, with the size the drawing occupies on the page.
///
/// The size is carried because a capture deliberately holds more pixels than
/// the drawing has points: a 3× capture of a 20pt formula is a 60px picture,
/// and a page that embedded it by its pixel count would print it three times
/// too large.
class PdfRaster {
  const PdfRaster({
    required this.bytes,
    required this.width,
    required this.height,
  });

  final Uint8List bytes;

  /// The size the drawing has on screen, in points.
  final double width;
  final double height;
}

/// One conversation, laid out as a PDF.
///
/// Everything it needs is plain data — fonts and pictures as bytes, message
/// bodies as the markdown the export assembled, formulas and diagrams as the
/// rasters they were drawn into — so the layout can run on a background isolate
/// with no window, no widget tree and no web engine. That is the property the
/// v3 pipeline did not have: it printed through a WebView and a second renderer,
/// while this walks the same Markdown IR the chat renders from.
class PdfExportRequest {
  const PdfExportRequest({
    required this.title,
    required this.messages,
    required this.thinkingLabel,
    required this.accent,
    required this.muted,
    required this.userLabel,
    this.alertLabels = const <String, String>{},
    this.subtitle,
    this.bodyFont,
    this.monoFont,
    this.emojiFont,
    this.iconFont,
    this.assistantIcon,
    this.images = const <String, Uint8List>{},
    this.rasters = const <String, PdfRaster>{},
    this.enableMathRendering = true,
    this.enableDollarLatex = true,
  });

  final String title;

  /// The line under the title, already formatted by the caller (it knows the
  /// locale and the message count).
  final String? subtitle;

  /// The accent the page draws its links, citations and task boxes in.
  ///
  /// The page is always light, so this is a colour that reads on white — which
  /// is why the caller resolves it from the app's *light* palette rather than
  /// from the theme in force: a dark theme's primary is a pale tint that would
  /// vanish into the paper.
  final PdfColor accent;

  /// The quiet ink for the page's second voice: timestamps, captions, the
  /// reference a picture stands in for.
  final PdfColor muted;

  /// What a reader's own messages are headed with, from the surface's locale.
  ///
  /// A conversation's export says who spoke rather than who the profile is: the
  /// name the app knows a person by is theirs, and an archive that leaves it on
  /// someone else's disk is a different document. The label is handed in because
  /// the layout has no locale of its own.
  final String userLabel;

  final List<ExportMessage> messages;

  /// What a reasoning section is titled with, from the surface's locale.
  final String thinkingLabel;

  /// The title each kind of callout is drawn with, by the name the grammar gives
  /// it (`note`, `tip`, `warning`, …), from the surface's locale.
  ///
  /// The page has no locale of its own — it runs in an isolate — so the labels
  /// arrive with the request, the way [userLabel] and [thinkingLabel] do. A name
  /// with no entry still keeps its body; only the band's title is missing.
  final Map<String, String> alertLabels;

  /// The faces to embed. Null leaves the writer's built-in font in place, which
  /// covers Latin-1 only.
  final Uint8List? bodyFont;
  final Uint8List? monoFont;

  /// The face an emoji is drawn from, which only works as a *fallback*: the
  /// writer looks for an emoji's bitmap on the fallback chain of the style that
  /// could not draw the rune, and never on the style's own font.
  final Uint8List? emojiFont;

  /// The icon face a speaker's avatar disc is drawn with, and the glyph in it.
  ///
  /// The screen shows a model's icon or an assistant's own picture here, which is
  /// a bitmap that varies per message; a page draws the *structure* instead — the
  /// same disc the app falls back to — out of the icon font the app already
  /// ships. The codepoint is a number rather than an `IconData` so that this
  /// library stays free of the widget layer it runs without.
  final Uint8List? iconFont;
  final int? assistantIcon;

  /// Picture bytes by URI, for pictures the caller already holds.
  final Map<String, Uint8List> images;

  /// Rasterized formulas and diagrams, keyed by the source they stand in for —
  /// the keys [pdfRasterKeysIn] names.
  final Map<String, PdfRaster> rasters;

  final bool enableMathRendering;
  final bool enableDollarLatex;
}

/// The name a raster is filed under in [PdfExportRequest.rasters].
///
/// The rasterizer files what it draws under this name and the layout looks it up
/// by the same one, so the two cannot disagree about what a key means. A formula
/// carries how it was written as well as its TeX, because the same `x^2` set in
/// a line of prose and set as a display block are two different pictures.
String pdfRasterLookupKey(PdfRasterKey key) =>
    key.kind == PdfRasterKind.math && key.display
    ? 'display: ${key.source}'
    : key.source;

/// What one layout produced.
///
/// The bytes are the deliverable and the rest is what a reader has to be told
/// about them. A formula or a diagram the caller could not draw is not a failure
/// — the layout falls back to the TeX and to the code, which is the only faithful
/// thing left — but an export that says nothing about it hides the difference
/// between "there was no formula" and "the formula did not render".
class PdfExportResult {
  const PdfExportResult({
    required this.bytes,
    required this.pages,
    required this.degradedMath,
    required this.degradedDiagrams,
    required this.undrawnImages,
  });

  final Uint8List bytes;

  /// How many pages the layout produced.
  final int pages;

  /// The TeX of the formulas that were set as text rather than drawn.
  final List<String> degradedMath;

  /// The source of the diagrams that were set as code rather than drawn.
  final List<String> degradedDiagrams;

  /// The pictures that were drawn as their reference rather than as a picture:
  /// bytes this device could not read, or a picture inside a line of prose.
  final List<String> undrawnImages;
}

/// Lays the conversation out, returning the document and what it could not draw.
Future<PdfExportResult> buildConversationPdf(PdfExportRequest request) async {
  final pw.Font? body = _font(request.bodyFont);
  final pw.Font? mono = _font(request.monoFont) ?? body;
  final pw.Font? emoji = _font(request.emojiFont);
  final pw.Font? icon = _font(request.iconFont);
  final layout = _PdfLayout(request, body: body, mono: mono, icon: icon);
  await layout.prepare();

  final document = pw.Document(title: request.title, author: 'Cuplivo');
  document.addPage(
    pw.MultiPage(
      pageFormat: PdfPageFormat.a4,
      // The writer counts this against the pages one *single* widget spans — it
      // is reset whenever a widget is placed — so a long code block is what the
      // default of 20 was really limiting, not a long document. It is also only
      // checked in an `assert`: a release build has no bound at all, which is why
      // nothing in this layout may be taller than a page and unbreakable.
      maxPages: 2000,
      margin: const pw.EdgeInsets.fromLTRB(
        _marginHorizontal,
        _marginTop,
        _marginHorizontal,
        _marginBottom,
      ),
      theme: pw.ThemeData.withFont(
        base: body,
        bold: body,
        italic: body,
        boldItalic: body,
        // An emoji face has to be a fallback, never the base: the writer asks a
        // style's *fallbacks* for an emoji's bitmap, and a base font is not in
        // that chain.
        fontFallback: <pw.Font>[
          if (mono != null && !identical(mono, body)) mono,
          if (emoji != null) emoji,
        ],
      ),
      header: (context) => context.pageNumber == 1
          ? pw.SizedBox()
          : pw.Container(
              alignment: pw.Alignment.centerRight,
              margin: const pw.EdgeInsets.only(bottom: 8),
              child: pw.Text(
                request.title,
                maxLines: 1,
                style: pw.TextStyle(fontSize: 8, color: request.muted),
              ),
            ),
      footer: (context) => pw.Container(
        alignment: pw.Alignment.center,
        margin: const pw.EdgeInsets.only(top: 10),
        child: pw.Text(
          '${context.pageNumber} / ${context.pagesCount}',
          style: pw.TextStyle(fontSize: 8, color: request.muted),
        ),
      ),
      build: (context) => layout.build((text, style) {
        // The writer's own metrics, asked of the face the style resolves to in the
        // context the layout is running in — the same call, on the same face, that
        // its own line wrapping makes. A style with no font of its own is drawn in
        // the theme's, which is the body face when the export embedded one and the
        // writer's built-in Helvetica when it did not.
        final face = style?.font ?? body ?? pw.Font.helvetica();
        final size = style?.fontSize ?? kPdfBodyFontSize;
        final pdf = face.getFont(context);
        for (final rune in text.runes) {
          if (!pdf.isRuneSupported(rune)) return null;
        }
        final spacing = style?.letterSpacing ?? 0;
        return pdf
                .stringMetrics(text, letterSpacing: spacing / size)
                .advanceWidth *
            size;
      }),
    ),
  );
  final bytes = await document.save();
  return PdfExportResult(
    bytes: bytes,
    // The writer's own count rather than a scan of the bytes: the pages exist as
    // objects by the time the document has been saved, and a scan would have to
    // know how the writer spells a page dictionary.
    pages: document.document.pdfPageList.pages.length,
    degradedMath: layout.degradedMath,
    degradedDiagrams: layout.degradedDiagrams,
    undrawnImages: layout.undrawnImages,
  );
}

/// The formula and diagram sources [markdown] holds.
///
/// These are the keys [PdfExportRequest.rasters] is keyed by. Drawing a formula
/// or a diagram needs a widget tree, so it cannot happen inside the layout
/// isolate: the caller asks this first, draws what it names, and hands the
/// bitmaps back. It is the same walk the layout runs, so the two cannot
/// disagree about what a key means.
///
/// The walk needs no second reading of the source: a quote, a list item, a table
/// cell and a `<details>` hold real children here, so whatever body the layout
/// draws is a body this walk reaches. The one thing it decodes is a fence's
/// language, by the same rule the renderer's diagram block claims one.
List<PdfRasterKey> pdfRasterKeysIn(
  String markdown, {
  required bool enableMathRendering,
  required bool enableDollarLatex,
}) {
  final keys = <PdfRasterKey>[];

  void visit(MarkdownNode node) {
    switch (node) {
      case MathBlockNode(:final tex):
        if (tex.isNotEmpty) {
          keys.add(
            PdfRasterKey(source: tex, kind: PdfRasterKind.math, display: true),
          );
        }
      case MathInlineNode(:final tex):
        final source = tex.trim();
        if (source.isNotEmpty) {
          keys.add(
            PdfRasterKey(
              source: source,
              kind: PdfRasterKind.math,
              display: false,
            ),
          );
        }
      case CodeBlockNode():
        final diagram = _diagramOf(node);
        if (diagram != null) {
          keys.add(
            PdfRasterKey(
              source: diagram.code,
              kind: PdfRasterKind.diagram,
              language: diagram.language,
            ),
          );
        }
      default:
        break;
    }
    for (final child in node.children) {
      visit(child);
    }
  }

  for (final block in _walkDocument(
    markdown,
    enableMathRendering: enableMathRendering,
    enableDollarLatex: enableDollarLatex,
  ).children) {
    visit(block);
  }
  return keys;
}

/// The diagram a fence holds, or null when it is ordinary code.
///
/// One rule for both readings of a fence — the raster keys this file names and
/// the page it draws — and it matches the block builders the app registers:
/// `mermaid` and an SVG are drawn as pictures, and PlantUML has a rendered view
/// of its own. A language with no renderer here keeps its code, and the report
/// says so rather than the page silently printing something the screen draws.
({String code, String language})? _diagramOf(CodeBlockNode node) {
  final code = node.code.trim();
  if (code.isEmpty) return null;
  final language = node.info.trim().split(RegExp(r'\s+')).first.toLowerCase();
  if (language != 'mermaid' &&
      language != 'plantuml' &&
      !isSvgCodeBlock(language, code)) {
    return null;
  }
  return (code: code, language: language);
}

/// The tree the page is laid out from.
///
/// It is the surface's own parse: the same parser options and the same inline
/// syntaxes the message under it uses, so a `[cite:id]` marker is a citation and a
/// local picture path is a picture on both sides. The layout has no settings
/// provider — it runs in an isolate — so the two settings it needs to translate
/// arrive as booleans, and [markdownParserOptionsFor] is what translates them.
DocumentNode _walkDocument(
  String source, {
  required bool enableMathRendering,
  required bool enableDollarLatex,
}) => MarkdownParser(
  options: markdownParserOptionsFor(
    enableMathRendering: enableMathRendering,
    enableDollarLatex: enableDollarLatex,
  ),
  inlineSyntaxes: kelivoInlineSyntaxes,
).parse(source);

pw.Font? _font(Uint8List? bytes) {
  if (bytes == null || bytes.isEmpty) return null;
  try {
    return pw.Font.ttf(
      bytes.buffer.asByteData(bytes.offsetInBytes, bytes.length),
    );
  } catch (_) {
    return null;
  }
}

/// The factor a raster is drawn at so that it fits the room it has.
///
/// Only ever shrinks — a capture's pixels are not what the page measures it by, so
/// a formula that was drawn small stays small. Both bounds matter: the width one
/// keeps a wide diagram inside the column, and the height one is load-bearing,
/// because a widget that cannot break across a page and does not fit on one makes
/// the writer lay it out again for ever, which a release build hangs on rather
/// than reports (see [_maxUnbreakableHeight]).
double pdfRasterScale({
  required double width,
  required double height,
  required double availableWidth,
}) {
  final maxWidth = availableWidth > 0 ? availableWidth : _contentWidth;
  var scale = width > maxWidth ? maxWidth / width : 1.0;
  if (height * scale > _maxUnbreakableHeight) {
    // Strictly smaller than [scale]: the branch is only taken when it is.
    scale = _maxUnbreakableHeight / height;
  }
  return scale;
}

/// The size a picture occupies on the page, from the size its author gave.
///
/// An author's `WxH` is written in the same logical pixels as the prose beside
/// it, so it is converted to the page's prose scale — and then bounded, because
/// a picture is one widget the writer cannot break: wider than the column it
/// would run past the margin, and taller than the room a page has it would make
/// the writer lay it out again for ever, which a release build hangs on rather
/// than reports (see [_maxUnbreakableHeight]).
({double? width, double? height, bool sized}) pdfImageSize({
  required double? width,
  required double? height,
  required double availableWidth,
}) {
  if (width == null && height == null) {
    return (width: null, height: null, sized: false);
  }
  final maxWidth = availableWidth > 0 ? availableWidth : _contentWidth;
  var w = width == null ? null : width * _pageScale;
  var h = height == null ? null : height * _pageScale;
  if (w != null && w > maxWidth) {
    final scale = maxWidth / w;
    w = maxWidth;
    h = h == null ? null : h * scale;
  }
  if (h != null && h > _maxUnbreakableHeight) {
    final scale = _maxUnbreakableHeight / h;
    h = _maxUnbreakableHeight;
    w = w == null ? null : w * scale;
  }
  return (width: w, height: h, sized: true);
}

/// What an image node says: where the picture is, the caption it carries and the
/// size its author asked for.
typedef PdfPicture = ({String url, String alt, double? width, double? height});

/// The picture an image node describes.
///
/// One reading for both sides of the app: the size is [markdownImageSizeOf], the
/// same rule the message's own picture applies, so a `WxH` alt cannot mean one
/// thing on screen and another on paper. A size is not a caption, which is why an
/// alt that parsed into one is not printed beside the picture.
PdfPicture pdfPictureOf(ImageNode node) {
  final alt = toPlainText(node).trim();
  final size = markdownImageSizeOf(alt);
  return (
    url: node.destination.trim(),
    alt: size == null ? alt : '',
    width: size?.width,
    height: size?.height,
  );
}

/// The indentation and the decoration one block wears.
///
/// A block wears its own group instead of sharing a `Column` with its siblings,
/// because the writer can only break a `Column` *between* its children: a single
/// child taller than a page makes the column re-lay-out the same child forever.
/// That does not fail loudly — the writer's "too many pages" guard is an
/// `assert`, so a release build would hang instead of throwing. So the layout
/// keeps every text leaf a direct child of the page flow, where the writer can
/// paginate it, and grouping is drawn per block: adjacent filled blocks read as
/// one panel because the fill never leaves a gap between them.
class _BlockSkin {
  const _BlockSkin({
    this.indent = 0,
    this.trailing = 0,
    this.top = 0,
    this.bottom = 0,
    this.padTop = 0,
    this.padBottom = 0,
    this.fill,
    this.rule,
    this.radius = 0,
  });

  /// Space to the left, and to the right, inside the decoration.
  final double indent;
  final double trailing;

  /// Space above and below, outside the decoration.
  final double top;
  final double bottom;

  /// Space above and below, inside the decoration.
  final double padTop;
  final double padBottom;

  final PdfColor? fill;

  /// A left rule, drawn when the block is quoted.
  final PdfColor? rule;

  final double radius;

  bool get _decorated => fill != null || rule != null;

  /// How much width a block inside this one may use.
  ///
  /// Nesting narrows the column, and a picture or a formula is scaled to the room
  /// it actually has rather than to the page: a diagram inside a quote would
  /// otherwise be laid out at the page's full content width and painted past the
  /// margin, because the writer draws an image at the size it is given.
  double get availableWidth {
    final width = _contentWidth - indent - trailing;
    return width > 0 ? width : _contentWidth;
  }

  _BlockSkin copyWith({
    double? indent,
    double? trailing,
    double? top,
    double? bottom,
    double? padTop,
    double? padBottom,
    PdfColor? fill,
    PdfColor? rule,
    double? radius,
  }) => _BlockSkin(
    indent: indent ?? this.indent,
    trailing: trailing ?? this.trailing,
    top: top ?? this.top,
    bottom: bottom ?? this.bottom,
    padTop: padTop ?? this.padTop,
    padBottom: padBottom ?? this.padBottom,
    fill: fill ?? this.fill,
    rule: rule ?? this.rule,
    radius: radius ?? this.radius,
  );

  /// Whether this skin changes anything at all.
  bool get _isPlain =>
      indent == 0 &&
      trailing == 0 &&
      top == 0 &&
      bottom == 0 &&
      padTop == 0 &&
      padBottom == 0 &&
      !_decorated;

  /// Puts [child] inside this block's indentation and decoration.
  pw.Widget wrap(pw.Widget child) {
    if (_isPlain) return child;
    if (!_decorated) {
      return pw.Padding(
        padding: pw.EdgeInsets.only(
          left: indent,
          right: trailing,
          top: top + padTop,
          bottom: bottom + padBottom,
        ),
        child: child,
      );
    }
    // A decorated block keeps its spacing *inside* the fill: a gap between two
    // filled blocks would stripe the panel they are meant to form, and it would
    // break a quote's left rule into dashes.
    //
    // The rule wins over the rounding, and that is not a preference: a quote's
    // rule is a *non-uniform* border, and the writer refuses a radius beside one
    // (`box_border.dart` asserts `borderRadius == null`). A code surface, a
    // degraded formula or a details band inside a quote all bring a radius of
    // their own, so without this the export throws in debug — and, since the
    // assert is compiled out of release builds, silently drops the rounding
    // there. Dropping it here is the same page with one answer for both.
    return pw.Container(
      width: double.infinity,
      margin: pw.EdgeInsets.only(top: top),
      padding: pw.EdgeInsets.only(
        left: indent,
        right: trailing,
        top: padTop,
        bottom: padBottom + bottom,
      ),
      decoration: pw.BoxDecoration(
        color: fill,
        border: rule == null
            ? null
            : pw.Border(left: pw.BorderSide(color: rule!, width: 2)),
        borderRadius: rule != null || radius == 0
            ? null
            : pw.BorderRadius.all(pw.Radius.circular(radius)),
      ),
      child: child,
    );
  }
}

/// What one string's advance is in one style, in points — the writer's own
/// measurement, or null when the layout cannot make it.
///
/// The one caller is the hanging indent of a list item (see [_Layout._hangCut]),
/// which has to cut a line where the writer would have cut it: a replica of the
/// writer's measurement is the only thing that can agree with it, so the layout
/// asks the writer rather than guessing at glyph widths.
typedef PdfAdvanceMeasure = double? Function(String text, pw.TextStyle? style);

/// The tallest an inline formula may be drawn at, in points.///
/// A picture is one `WidgetSpan` to the writer, and the writer advances a line by
/// the overhang a span has above the text's own ascent — so a formula taller than
/// the line it sits in is what pushes the *next* line down. Measured on a probe
/// document: a 24-point picture in a 10.5-point paragraph moved the following
/// line 3.65 points down, and 8.2 points when the paragraph also carried a soft
/// line break. A paragraph of formulas then reads as a paragraph of gaps, which
/// is the one thing a page of prose must not do. The cap keeps a formula a little
/// larger than the prose — enough for a nested fraction to stay legible — and
/// shrinks only what would break the rhythm.
const double _inlineMathHeightCap = kPdfBodyFontSize * 1.25;

/// One table cell, held to the tallest a row may be.
///
/// A `Table` breaks between rows and never inside one, and it hands every cell
/// an unbounded height, so a cell taller than a page makes the table re-lay-out
/// that same row for ever — and, since the writer's page guard is an `assert`,
/// a release build would hang rather than throw. The cell is therefore measured
/// first and an absurd one is cut off: the text a reader loses to a
/// thousand-line cell is worth less than an export that never returns.
class _CappedCell extends pw.SingleChildWidget {
  _CappedCell({required pw.Widget child, required this.maxHeight})
    : super(child: child);

  final double maxHeight;

  @override
  void layout(
    pw.Context context,
    pw.BoxConstraints constraints, {
    bool parentUsesSize = false,
  }) {
    final child = this.child;
    if (child == null) {
      box = PdfRect.fromPoints(PdfPoint.zero, constraints.smallest);
      return;
    }
    child.layout(context, constraints, parentUsesSize: true);
    final natural = child.box!.height;
    final cap = math.min(maxHeight, constraints.maxHeight);
    if (natural > cap) {
      child.layout(context, constraints.copyWith(maxHeight: cap));
    }
    box = child.box;
  }

  // A single-child widget in this writer paints its own child: the mixin only
  // offers [paintChild], so overriding [layout] without this leaves the cell
  // laid out and invisible.
  @override
  void paint(pw.Context context) {
    super.paint(context);
    paintChild(context);
  }
}

class _PdfLayout {
  _PdfLayout(this.request, {required this.body, required this.mono, this.icon});

  final PdfExportRequest request;
  final pw.Font? body;
  final pw.Font? mono;

  /// The face a speaker's avatar glyph is drawn from.
  final pw.Font? icon;

  /// The walked bodies, one per markdown block, keyed by the block itself: a
  /// prepare pass resolves pictures from them and the layout then reuses them
  /// rather than walking every body twice.
  final Map<ExportBlock, DocumentNode> _documents =
      <ExportBlock, DocumentNode>{};
  final Map<String, Uint8List> _pictures = <String, Uint8List>{};

  /// The message being laid out, and the number its citations show.
  ///
  /// A citation's number comes from the search results of the message it sits
  /// in, and the layout reaches a span through four layers of nesting that have
  /// no other use for it — so the message's own index is a cursor the message
  /// loop moves, the way [_pictures] is filled before the layout runs.
  Map<String, String> _citations = const <String, String>{};

  /// What the layout fell back from. Insertion-ordered sets, because the report
  /// names each kind once and the order a reader met them in is the useful one.
  final Set<String> _degradedMath = <String>{};
  final Set<String> _degradedDiagrams = <String>{};
  final Set<String> _undrawnImages = <String>{};

  List<String> get degradedMath => _degradedMath.toList(growable: false);
  List<String> get degradedDiagrams =>
      _degradedDiagrams.toList(growable: false);
  List<String> get undrawnImages => _undrawnImages.toList(growable: false);

  /// A paragraph, and the indentation a quote or a list adds around it.
  ///
  /// The gap under a paragraph is the page's own: the screen separates two
  /// blocks with a blank line of its list height (two empty lines, about 24
  /// points at page scale), which is a chat convention rather than a typesetting
  /// one, and a printed page that airy wastes a fifth of its length.
  static const _BlockSkin _plainSkin = _BlockSkin(bottom: _paragraphGap);

  /// A card: reasoning, or a tool call.
  static const _BlockSkin _cardSkin = _BlockSkin(
    indent: 8,
    trailing: 8,
    top: 2,
    bottom: 3,
    padTop: 3,
    padBottom: 0,
    fill: _blockFill,
    radius: 4,
  );

  /// A picture, a diagram or a table: set a little apart from the prose.
  static const _BlockSkin _asideSkin = _BlockSkin(
    top: _asideGap,
    bottom: _asideGap,
  );

  /// Prose at the leading this page reads at.
  ///
  /// The writer adds [pw.TextStyle.lineSpacing] to the font's own line height,
  /// so what is set here is the difference between that height and the leading
  /// wanted: 10.5 points of built-in face measure 12.1 points tall (measured), so
  /// 1.6 of the size is 16.8 and the difference is 4.7. A face with taller metrics
  /// — a CJK face is one — adds its own height on top of this, so the ratio is
  /// approximate rather than exact.
  ///
  /// It is a tenth of the size looser than the screen's 1.5, and that is a review
  /// finding rather than a preference: a page is read at arm's length, where the
  /// screen's leading reads as a wall of characters — the first export of a long
  /// Chinese conversation did.
  pw.TextStyle get _bodyStyle => pw.TextStyle(
    fontSize: kPdfBodyFontSize,
    color: _ink,
    lineSpacing: kPdfBodyFontSize * 0.6 - 1.6,
  );
  pw.TextStyle get _bodyBold =>
      _fauxBoldStyle(_bodyStyle.copyWith(fontWeight: pw.FontWeight.bold));
  pw.TextStyle get _monoStyle => pw.TextStyle(
    fontSize: 9,
    color: _ink,
    lineSpacing: 2.2,
    font: mono,
    fontFallback: _monoFallback,
  );
  pw.TextStyle get _captionStyle =>
      pw.TextStyle(fontSize: 9, color: request.muted, font: body);
  pw.TextStyle get _mathInlineStyle => pw.TextStyle(
    fontSize: 10,
    color: _quoteInk,
    font: body,
    fontFallback: _monoFallback,
  );

  List<pw.Font> get _monoFallback => <pw.Font>[
    if (mono != null && body != null && !identical(mono, body)) body!,
  ];

  Future<void> prepare() async {
    final urls = <String>{};
    for (final message in request.messages) {
      for (final block in message.blocks) {
        final source = switch (block) {
          ExportText(:final text) => text,
          ExportReasoning(:final text) => text,
          _ => null,
        };
        if (source == null) continue;
        final document = _walkDocument(
          source,
          enableMathRendering: request.enableMathRendering,
          enableDollarLatex: request.enableDollarLatex,
        );
        _documents[block] = document;
        for (final block in document.children) {
          _collectPictureUrls(block, urls);
        }
      }
    }
    // Pictures have to be in hand before layout, which cannot await.
    for (final url in urls) {
      final provided = request.images[url];
      if (provided != null) {
        _pictures[url] = provided;
        continue;
      }
      final bytes = await readExportImageBytes(url);
      if (bytes != null) _pictures[url] = bytes;
    }
  }

  void _collectPictureUrls(MarkdownNode node, Set<String> urls) {
    if (node is ImageNode && node.destination.isNotEmpty) {
      urls.add(node.destination);
    }
    for (final child in node.children) {
      _collectPictureUrls(child, urls);
    }
  }

  /// How wide a string is in the style it will be drawn in, or null when this
  /// layout cannot say — see [PdfAdvanceMeasure].
  ///
  /// The hanging indent of a list item is the one measurement this layout makes
  /// itself, and it has to be the writer's own or the cut would land somewhere the
  /// writer never breaks.
  PdfAdvanceMeasure? _measure;

  List<pw.Widget> build(PdfAdvanceMeasure measure) {
    _measure = measure;
    final widgets = <pw.Widget>[
      _fauxBold(
        pw.Text(
          request.title,
          style: _fauxBoldStyle(
            pw.TextStyle(
              fontSize: 19,
              fontWeight: pw.FontWeight.bold,
              color: _ink,
            ),
          ),
        ),
        size: 19,
        ink: _ink,
      ),
      if (request.subtitle != null)
        pw.Padding(
          padding: const pw.EdgeInsets.only(top: _titleGap, bottom: 12),
          child: pw.Text(
            request.subtitle!,
            style: pw.TextStyle(fontSize: 9, color: request.muted),
          ),
        ),
    ];
    for (var index = 0; index < request.messages.length; index++) {
      final message = request.messages[index];
      _citations = message.citationIndex;
      final band = message.speaker == ExportSpeaker.user ? _userBand : null;
      if (index > 0) {
        widgets.add(
          pw.Divider(
            color: _ruleInk,
            height: _messageRuleHeight,
            thickness: 0.6,
          ),
        );
      }
      widgets.add(_speaker(message));
      for (final block in message.blocks) {
        widgets.addAll(_block(block, band));
      }
    }
    return widgets;
  }

  /// The panel a reader's own messages are set on.
  ///
  /// The screen draws them in a bubble: a tinted, rounded box aligned to the right
  /// edge. A page draws a full-width tint instead, and the reason is
  /// [_BlockSkin]'s: a decorated container around content that can run past a page
  /// is the unbreakable box this writer loops on, so the tint is per block and the
  /// blocks carry no gap of their own — their fill touches, and the panel is
  /// continuous until the page breaks or the message ends.
  ///
  /// It is therefore square-ended: rounding belongs to a box, and there is no box.
  _BlockSkin get _userBand => _BlockSkin(
    indent: _userBandInset,
    trailing: _userBandInset,
    padTop: _userBandPad,
    padBottom: _userBandPad,
    fill: _overWhite(request.accent, _userBandAlpha),
  );

  List<pw.Widget> _block(ExportBlock block, _BlockSkin? band) {
    switch (block) {
      case ExportText(:final text):
        return _blocksOf(
          _documentFor(block, text).children,
          skin: band ?? _plainSkin,
        );
      case ExportReasoning(:final text):
        // The card is drawn per block rather than around a column of them, so
        // its body stays paginatable (see [_BlockSkin]).
        final card = _onBand(_cardSkin, band);
        return <pw.Widget>[
          _leaf(
            request.thinkingLabel,
            _fauxBoldStyle(
              _captionStyle.copyWith(fontWeight: pw.FontWeight.bold),
            ),
            card.copyWith(bottom: 0),
          ),
          ..._blocksOf(
            _documentFor(block, text).children,
            skin: card.copyWith(padTop: 0),
          ),
        ];
      case ExportToolCall(:final name, :final content):
        return <pw.Widget>[_toolCall(name, content, band)];
      case ExportImage(:final uri, :final bytes):
        return _pictureBlock(uri, bytes, skin: _onBand(_asideSkin, band));
      case ExportFile(:final name, :final mime):
        return <pw.Widget>[
          _leaf(
            '- $name ($mime)',
            _captionStyle,
            _onBand(const _BlockSkin(bottom: 2), band),
          ),
        ];
    }
  }

  /// [skin] as one block of [band]'s panel, or [skin] itself outside one.
  ///
  /// A block that brings its own fill — a code surface, a reasoning card — keeps
  /// it; a block that brings none takes the band's. What is always taken from the
  /// band is the *gap*: a filled block's spacing sits inside its fill, so a block
  /// that stood apart would cut a white stripe across the panel.
  _BlockSkin _onBand(_BlockSkin skin, _BlockSkin? band) {
    if (band == null) return skin;
    return skin.copyWith(
      indent: skin.indent + band.indent,
      trailing: skin.trailing + band.trailing,
      top: 0,
      padTop: band.padTop,
      padBottom: band.padBottom,
      fill: skin.fill ?? band.fill,
    );
  }

  /// The speaker line above a message's blocks.
  ///
  /// The screen puts a 32-point disc beside a two-line stack — the name, then the
  /// time under it — and draws both in an ink lighter than the prose, because the
  /// header is furniture rather than something anyone said. The page does the
  /// same, with two differences the page forces:
  ///
  /// * A reader's own messages carry no timestamp. The archive is a record of what
  ///   was said, and the one message whose arrival time a reader already knows is
  ///   the one they typed.
  /// * A reader's own messages are headed with the label the surface handed in
  ///   rather than with the profile's name — see [PdfExportRequest.userLabel].
  pw.Widget _speaker(ExportMessage message) {
    final isUser = message.speaker == ExportSpeaker.user;
    final stack = pw.Column(
      crossAxisAlignment: pw.CrossAxisAlignment.start,
      children: <pw.Widget>[
        pw.Text(
          isUser ? request.userLabel : message.roleName,
          maxLines: 1,
          // The writer has no ellipsis: a name too long for its line is cut
          // rather than folded, which is what a header of one line means.
          overflow: pw.TextOverflow.clip,
          style: pw.TextStyle(
            fontSize: _speakerNameSize,
            color: _overWhite(_ink, _speakerNameAlpha),
          ),
        ),
        if (!isUser && message.time.isNotEmpty)
          pw.Padding(
            padding: const pw.EdgeInsets.only(top: _speakerTimeGap),
            child: pw.Text(
              message.time,
              maxLines: 1,
              style: pw.TextStyle(
                fontSize: _speakerTimeSize,
                color: _overWhite(_ink, _speakerTimeAlpha),
              ),
            ),
          ),
      ],
    );
    // A user's message is answered by the band under it — see [_userBand] — so its
    // header needs no mark of its own; an assistant's is the page's only other
    // left edge, and the disc is what says so at a glance.
    return pw.Container(
      margin: const pw.EdgeInsets.only(bottom: _speakerBottom),
      child: isUser
          // The label lines up with the text of the band under it, so the two
          // read as one block rather than as a label beside a panel.
          ? pw.Padding(
              padding: const pw.EdgeInsets.only(left: _userBandInset),
              child: stack,
            )
          : pw.Row(
              crossAxisAlignment: pw.CrossAxisAlignment.start,
              children: <pw.Widget>[
                _avatarDisc(),
                pw.SizedBox(width: _avatarGap),
                pw.Expanded(child: stack),
              ],
            ),
    );
  }

  /// The disc beside an assistant's name, with the one glyph the page can draw.
  ///
  /// The screen fills it with the model's own icon or the assistant's picture,
  /// which is a bitmap that would have to be captured per message; a page draws
  /// the structure out of the icon face the app already ships instead. A caller
  /// that could not hand one over gets the disc alone, which still reads as the
  /// avatar slot rather than as a missing image.
  pw.Widget _avatarDisc() {
    final icon = this.icon;
    final code = request.assistantIcon;
    return pw.Container(
      width: _avatarSize,
      height: _avatarSize,
      alignment: pw.Alignment.center,
      decoration: pw.BoxDecoration(
        color: _overWhite(request.accent, _avatarFillAlpha),
        shape: pw.BoxShape.circle,
      ),
      child: icon == null || code == null
          ? null
          : pw.Text(
              String.fromCharCode(code),
              style: pw.TextStyle(
                font: icon,
                fontSize: _avatarGlyphSize,
                color: request.accent,
              ),
            ),
    );
  }

  /// A tool call: its name, then whatever it answered, in one monospace body.
  ///
  /// One leaf rather than a name and a body stacked in a column, because tool
  /// output is exactly the text that grows past a page.
  pw.Widget _toolCall(String name, String content, _BlockSkin? band) {
    final label = name.isEmpty ? '[tool]' : '[$name]';
    final body = content.trim();
    return _richText(<pw.InlineSpan>[
      pw.TextSpan(
        text: label,
        style: _monoStyle.copyWith(fontWeight: pw.FontWeight.bold),
      ),
      if (body.isNotEmpty) pw.TextSpan(text: '\n$body', style: _monoStyle),
    ], _onBand(_cardSkin, band));
  }

  List<pw.Widget> _pictureBlock(
    String uri,
    Uint8List? bytes, {
    _BlockSkin skin = _asideSkin,
    PdfPicture? picture,
  }) {
    final data = bytes ?? _pictures[uri];
    final provider = data == null ? null : _provider(data);
    if (provider == null) {
      // A picture this device cannot read is named rather than dropped: the
      // reader can still find it where the conversation said it was — and the
      // export says so, because a page of references is not the conversation.
      _undrawnImages.add(uri);
      return <pw.Widget>[_leaf(uri, _captionStyle, skin)];
    }
    return <pw.Widget>[
      skin.wrap(
        pw.Container(
          alignment: pw.Alignment.centerLeft,
          child: _pictureWidget(provider, picture, skin.availableWidth),
        ),
      ),
    ];
  }

  /// A picture as the page draws it: the size its author gave, or its own
  /// pixels scaled down to the room it has.
  ///
  /// An author's `WxH` is written next to the app's prose, so it is scaled to
  /// the page's own prose before it is used — and both bounds are applied after
  /// that, because a picture is one widget the writer cannot break: one taller
  /// than a page would make it lay that picture out for ever.
  pw.Widget _pictureWidget(
    pw.ImageProvider provider,
    PdfPicture? picture,
    double availableWidth,
  ) {
    final size = pdfImageSize(
      width: picture?.width,
      height: picture?.height,
      availableWidth: availableWidth,
    );
    return pw.ConstrainedBox(
      constraints: pw.BoxConstraints(
        maxWidth: availableWidth,
        maxHeight: _maxUnbreakableHeight,
      ),
      child: pw.Image(
        provider,
        width: size.width,
        height: size.height,
        fit: size.sized ? pw.BoxFit.contain : pw.BoxFit.scaleDown,
      ),
    );
  }

  /// The blocks of one walked markdown body.
  ///
  /// The tree is the page's structure now — a paragraph is a node rather than a
  /// run of the walk's leftovers — so this is a dispatch rather than a
  /// re-assembly: every block kind has one reading, and a kind a page cannot draw
  /// is handed to the words it holds rather than disappearing.
  ///
  /// Every widget it returns is meant to sit directly in the page flow, so a
  /// caller may append them to the document's child list but must not stack
  /// them in a `Column` (see [_BlockSkin]).
  List<pw.Widget> _blocksOf(
    List<BlockNode> nodes, {
    _BlockSkin skin = _plainSkin,
    pw.InlineSpan? marker,
    _BlockSkin? firstSkin,
    pw.TextStyle? textStyle,
  }) {
    final widgets = <pw.Widget>[];
    var pendingMarker = marker;
    var pendingFirst = firstSkin;

    // A marker is the one thing an item with no text still has to draw, because a
    // list item can hold nothing else.
    void flushMarker() {
      final mark = pendingMarker;
      if (mark == null) return;
      pendingMarker = null;
      pendingFirst = null;
      widgets.add(_paragraph(const <InlineNode>[], skin, marker: mark));
    }

    void paragraph(List<InlineNode> run) {
      final at = pendingFirst ?? skin;
      final mark = pendingMarker;
      pendingMarker = null;
      pendingFirst = null;
      if (mark == null) {
        widgets.add(_paragraph(run, at, style: textStyle));
        return;
      }
      // A marked run hangs: its first line is cut out and the rest goes one step
      // in, which is the one indentation the writer cannot draw itself.
      final hung = _hangItem(run, mark, at, skin, textStyle);
      if (hung != null) {
        widgets.addAll(hung);
        return;
      }
      widgets.add(_paragraph(run, at, marker: mark, style: textStyle));
    }

    for (final node in nodes) {
      switch (node) {
        case ParagraphNode(:final children):
          final pictures = children.whereType<ImageNode>().toList();
          final prose = children.where(
            (child) =>
                child is! ImageNode &&
                child is! LineBreakNode &&
                !(child is TextNode && child.text.trim().isEmpty),
          );
          // A paragraph of nothing but pictures is how a model writes an
          // illustration: it gets the picture, not its alt text.
          if (pictures.isNotEmpty && prose.isEmpty) {
            flushMarker();
            for (final picture in pictures) {
              final described = pdfPictureOf(picture);
              if (described.url.isEmpty) continue;
              widgets.addAll(
                _pictureBlock(
                  described.url,
                  null,
                  skin: skin,
                  picture: described,
                ),
              );
            }
            continue;
          }
          paragraph(children);
        case HeadingNode():
          flushMarker();
          widgets.add(_heading(node, skin));
        case ListNode():
          flushMarker();
          widgets.addAll(_list(node, skin));
        case TaskItemNode():
          flushMarker();
          widgets.add(_taskItem(node, skin));
        case BlockQuoteNode():
          flushMarker();
          widgets.addAll(_quote(node, skin));
        case CodeBlockNode():
          flushMarker();
          widgets.addAll(_codeBlock(node, skin));
        case TableNode():
          flushMarker();
          widgets.add(_table(node, skin));
        case DetailsNode():
          flushMarker();
          widgets.addAll(_details(node, skin));
        case MathBlockNode():
          flushMarker();
          widgets.add(_displayMath(node, skin));
        case ThematicBreakNode():
          flushMarker();
          widgets.add(pw.Divider(color: _ruleInk, height: 12, thickness: 0.6));
        case HtmlBlockNode():
          flushMarker();
          widgets.addAll(_htmlBlock(node, skin));
        case NamedBlockNode():
          flushMarker();
          widgets.addAll(_namedBlock(node, skin));
        case ReferenceDefinitionNode():
          break; // A definition draws nothing on the screen either.
        default:
          // A kind this page has no reading for keeps its words: an archive that
          // silently drops a paragraph is worse than one that sets it plainly.
          final text = toPlainText(node).trim();
          if (text.isEmpty) break;
          paragraph(<InlineNode>[TextNode(span: node.span, text: text)]);
      }
    }
    return widgets;
  }

  /// One paragraph: a run of inline nodes, optionally opening with a marker.
  ///
  /// The marker is a span rather than a string because a task item's marker is a
  /// box: a list of things to do is a document, and `[x]` in the middle of one is
  /// syntax. [style] is the paragraph's own ink, which a checked item darkens no
  /// further than the renderer does.
  pw.Widget _paragraph(
    List<InlineNode> run,
    _BlockSkin skin, {
    pw.InlineSpan? marker,
    pw.TextStyle? style,
  }) {
    final ink = style ?? _bodyStyle;
    final markWidth = marker == null ? 0.0 : _spanWidth(marker);
    final body = _spans(run, style: style, availableWidth: skin.availableWidth);
    final children = <pw.InlineSpan>[
      if (marker != null) marker,
      // A marker this layout cannot measure — a task item's box — leaves the run
      // as it was: the first line's room is the one thing the fill has to know.
      if (markWidth == null)
        ...body
      else
        ..._filled(body, width: skin.availableWidth, used: markWidth),
    ];
    return _richText(children, skin, style: ink);
  }

  /// One span's advance, in points, or null when this layout cannot say.
  double? _spanWidth(pw.InlineSpan span) {
    if (span is! pw.TextSpan) return null;
    final text = span.text;
    final measure = _measure;
    if (text == null || text.isEmpty || measure == null) return null;
    return measure(text, span.style);
  }

  /// The width of one separator in [style], which is what the writer multiplies
  /// by [pw.TextStyle.wordSpacing] — zero for the break opportunities this layout
  /// adds, one for the source's own spaces.
  double? _spaceWidth(pw.TextStyle? style) =>
      _spanWidth(pw.TextSpan(text: ' ', style: style));

  /// [span]'s text replaced, with the styling and the annotation it carried.
  pw.InlineSpan _piece(pw.TextSpan span, String text) => pw.TextSpan(
    text: text,
    style: span.style,
    baseline: span.baseline,
    annotation: span.annotation,
  );

  /// Where the writer would end a line that already holds [used] points, or null
  /// when everything left fits.
  ///
  /// This is a copy of the writer's own greedy line filling (`text.dart`,
  /// `_buildLines`): words are atomic, whitespace advances by the face's space
  /// multiplied by the span's word spacing, and a newline ends the line whatever
  /// the room is. And it is a copy on purpose — a break opportunity offered
  /// anywhere the writer would not have broken buys nothing — which is why this
  /// layout asks for the writer's own metrics rather than guessing at widths.
  ///
  /// `at` is where the next line begins: an index into the span at `span`, after a
  /// newline when the line ended because the source wrote one.
  ({int span, int at})? _lineEnd(
    List<pw.InlineSpan> spans, {
    required double used,
    required double width,
  }) {
    var x = used;
    for (var index = 0; index < spans.length; index++) {
      final span = spans[index];
      if (span is! pw.TextSpan || span.text == null || span.children != null) {
        // A widget — a formula, a picture, a pill, a task box — is as wide as its
        // child laid out, which this layout does not build here. Either the line
        // is full and ends before it, or the widget ends the line and what follows
        // starts a fresh one: both are breaks the writer could take, and neither
        // pretends to know the width.
        return x >= width ? (span: index, at: 0) : (span: index + 1, at: 0);
      }
      final text = span.text!;
      final style = span.style;
      final space = _spaceWidth(style);
      if (space == null) return null;
      final factor = style?.wordSpacing ?? 1;
      final spacing = style?.letterSpacing ?? 0;
      var at = 0;
      while (at < text.length) {
        final start = at;
        if (text.codeUnitAt(at) == 0x0a) {
          // The newline itself is the cut: a leaf that began with it would print
          // an empty line before the text it belongs to.
          return (span: index, at: start + 1);
        }
        final isSpace = _isSpaceRune(text.codeUnitAt(at));
        while (at < text.length) {
          final next = text.codeUnitAt(at);
          if (next == 0x0a || _isSpaceRune(next) != isSpace) break;
          at++;
        }
        if (isSpace) {
          x += space * factor + spacing;
          continue;
        }
        final word = _spanWidth(_piece(span, text.substring(start, at)));
        if (word == null) return null;
        if (x + word > width) {
          final room = width - x;
          final fits = room > 0
              ? _fittingPrefix(span, text.substring(start, at), room)
              : '';
          // Room is left on the line, so the word may be filled into it — this is
          // the one thing the writer will not do with a Chinese run, and without
          // it the room is wasted and the run starts a line of its own. The cut is
          // moved off a word's middle by [_legalCut] like any other.
          if (fits.isNotEmpty) {
            return _legalCut(spans, index, start + fits.length);
          }
          // A word that moves whole ends the line where it begins.
          if (x > 0) return _legalCut(spans, index, start);
          // Nothing on the line and nothing fits: the writer would split this word
          // itself, and this layout leaves it to do so.
          return null;
        }
        x += word + space * factor + spacing;
      }
    }
    return null;
  }

  /// [spans] as leaves: a span that carries children — a link's own span — is
  /// replaced by its children, each of which the writer would have merged with the
  /// parent's style and annotation anyway.
  ///
  /// The cut below measures and slices leaves, so a span holding children is
  /// flattened rather than guessed at: a link is not a widget.
  List<pw.InlineSpan> _flatten(List<pw.InlineSpan> spans) {
    final out = <pw.InlineSpan>[];
    for (final span in spans) {
      if (span is! pw.TextSpan || span.children == null) {
        out.add(span);
        continue;
      }
      for (final child in _flatten(span.children!)) {
        final style = child.style;
        final merged = span.style == null
            ? style
            : (style == null ? span.style : span.style!.merge(style));
        final annotation = child.annotation ?? span.annotation;
        out.add(
          child is pw.TextSpan
              ? pw.TextSpan(
                  text: child.text,
                  style: merged,
                  baseline: child.baseline,
                  annotation: annotation,
                )
              : child.copyWith(style: merged, annotation: annotation),
        );
      }
    }
    return out;
  }

  /// The longest prefix of [text] that fits [width] on its own, or `''` when even
  /// one rune is too wide for it.
  ///
  /// A copy of the writer's own `_splitWord`, which walks code units — this one
  /// counts runes, so it cannot cut a surrogate pair in half.
  String _fittingPrefix(pw.TextSpan span, String text, double width) {
    final runes = text.runes.toList();
    var low = 0;
    var high = runes.length;
    while (low + 1 < high) {
      final middle = (low + high) ~/ 2;
      final piece = String.fromCharCodes(runes.take(middle));
      final size = _spanWidth(_piece(span, piece));
      if (size == null || size > width) {
        high = middle;
      } else {
        low = middle;
      }
    }
    return String.fromCharCodes(runes.take(low));
  }

  /// [span]/[at] moved back off a line start or a line end this page's own
  /// typography forbids: `。` never opens a line, `「` never closes one, and a break
  /// never lands inside a Latin word.
  ({int span, int at}) _legalCut(List<pw.InlineSpan> spans, int span, int at) {
    var s = span;
    var i = at;
    while (true) {
      final opens = _unitAt(spans, s, i);
      final closes = _unitAt(spans, s, i - 1) ?? _lastUnitBefore(spans, s);
      final forbidden =
          (opens != null && _noBreakBefore.contains(opens)) ||
          (closes != null && _noBreakAfter.contains(closes)) ||
          (opens != null &&
              closes != null &&
              _isWordRune(opens) &&
              _isWordRune(closes));
      if (!forbidden) return (span: s, at: i);
      final back = _stepBack(spans, s, i);
      if (back == null) return (span: s, at: i);
      s = back.span;
      i = back.at;
    }
  }

  /// The code unit at [at] of [span], or null when that is not a text span.
  int? _unitAt(List<pw.InlineSpan> spans, int span, int at) {
    if (span < 0 || span >= spans.length) return null;
    final text = spans[span] is pw.TextSpan
        ? (spans[span] as pw.TextSpan).text
        : null;
    if (text == null || at < 0 || at >= text.length) return null;
    return text.codeUnitAt(at);
  }

  /// The last code unit of the text before [span], skipping what is not text.
  int? _lastUnitBefore(List<pw.InlineSpan> spans, int span) {
    for (var index = span - 1; index >= 0; index--) {
      final text = spans[index] is pw.TextSpan
          ? (spans[index] as pw.TextSpan).text
          : null;
      if (text == null || text.isEmpty) continue;
      return text.codeUnitAt(text.length - 1);
    }
    return null;
  }

  /// One rune earlier than [span]/[at], or null when there is no text before it.
  ({int span, int at})? _stepBack(List<pw.InlineSpan> spans, int span, int at) {
    if (at > 0) return (span: span, at: at - 1);
    for (var index = span - 1; index >= 0; index--) {
      final text = spans[index] is pw.TextSpan
          ? (spans[index] as pw.TextSpan).text
          : null;
      if (text == null || text.isEmpty) continue;
      return (span: index, at: text.length - 1);
    }
    return null;
  }

  /// [spans] with a break opportunity at every line end the writer would take.
  ///
  /// The writer breaks a line only at whitespace, and a Chinese sentence has none:
  /// it arrives as one word, and a word that does not fit the room left on a line
  /// is moved to the next one **whole** — so the line before it ends where that
  /// word began. That is the short line a review of the first export found, and it
  /// was always in the same place: after a Latin word and a space.
  ///
  /// The opportunity is inserted at the line's end, and nowhere else, so the line
  /// the writer then fills is still drawn as one string: a page of Chinese copies
  /// and searches as the Chinese it is.
  List<pw.InlineSpan> _filled(
    List<pw.InlineSpan> spans, {
    required double width,
    double used = 0,
  }) {
    final out = <pw.InlineSpan>[];
    var rest = _flatten(spans);
    var held = used;
    while (rest.isNotEmpty) {
      final end = _lineEnd(rest, used: held, width: width);
      // Everything left fits, or this layout cannot say where the line would end:
      // either way what is left is handed to the writer as it is.
      if (end == null ||
          end.span >= rest.length ||
          (end.span == 0 && end.at == 0)) {
        break;
      }
      final head = <pw.InlineSpan>[];
      final tail = <pw.InlineSpan>[];
      for (var index = 0; index < rest.length; index++) {
        final span = rest[index];
        if (index < end.span) {
          head.add(span);
          continue;
        }
        if (index > end.span) {
          tail.add(span);
          continue;
        }
        final text = (span as pw.TextSpan).text!;
        if (end.at > 0) head.add(_piece(span, text.substring(0, end.at)));
        if (end.at < text.length) {
          tail.add(_piece(span, text.substring(end.at)));
        }
      }
      out.addAll(head);
      // A newline is already a break; anything else gets the opportunity, which
      // costs nothing and draws nothing (see [_breakOpportunity]).
      if (_unitAt(rest, end.span, end.at - 1) != 0x0a) {
        out.add(_breakOpportunity);
      }
      rest = tail;
      held = 0;
    }
    out.addAll(rest);
    return out;
  }

  /// The first line of a list item, and the rest of it, or null when this layout
  /// cannot cut it.
  ///
  /// A list item's continuation lines belong one step in from its marker. The
  /// writer cannot do that: its text starts every line at the paragraph's own left
  /// edge, and the widgets that would give it the indent — a `Row`, a `Table` row
  /// — are the unbreakable boxes this whole layout is built to avoid, since a row
  /// taller than a page is what makes the writer loop. So the item's first line is
  /// cut out here, by the writer's own metrics, and reaches the page as two leaves.
  ({List<pw.InlineSpan> head, List<pw.InlineSpan> tail})? _firstLine(
    List<pw.InlineSpan> spans, {
    required pw.InlineSpan marker,
    required double width,
  }) {
    final markerWidth = _spanWidth(marker);
    if (markerWidth == null) return null;
    final flat = _flatten(spans);
    final end = _lineEnd(flat, used: markerWidth, width: width);
    // A cut at the very start would leave the marker alone on its line, which is
    // not what the writer does with a word too wide for the room it has: it splits
    // that word instead, and so will this page if the item is left as it is.
    if (end == null || (end.span == 0 && end.at == 0)) return null;

    final head = <pw.InlineSpan>[];
    final tail = <pw.InlineSpan>[];
    for (var index = 0; index < spans.length; index++) {
      final span = spans[index];
      if (index < end.span) {
        head.add(span);
        continue;
      }
      if (index > end.span) {
        tail.add(span);
        continue;
      }
      final text = (span as pw.TextSpan).text!;
      if (end.at > 0) head.add(_piece(span, text.substring(0, end.at)));
      if (end.at < text.length) tail.add(_piece(span, text.substring(end.at)));
    }
    if (head.isEmpty || tail.isEmpty) return null;
    return (head: head, tail: tail);
  }

  /// One list item's opening run, as two leaves when its first line can be cut out
  /// of it — see [_firstLine].
  ///
  /// The marker's line is the item's own; everything after it is one step in, so a
  /// wrapped item hangs under its text rather than under its marker. The second
  /// leaf keeps the first one's bottom gap, because what the item ends with is
  /// what it ended with before, one line further down.
  List<pw.Widget>? _hangItem(
    List<InlineNode> run,
    pw.InlineSpan marker,
    _BlockSkin head,
    _BlockSkin body,
    pw.TextStyle? style,
  ) {
    final spans = _spans(
      run,
      style: style,
      availableWidth: head.availableWidth,
    );
    final cut = _firstLine(spans, marker: marker, width: head.availableWidth);
    if (cut == null) return null;
    final ink = style ?? _bodyStyle;
    return <pw.Widget>[
      // No gap under the marker's line: the paragraph continues on the next one.
      _richText(
        <pw.InlineSpan>[marker, ...cut.head],
        head.copyWith(bottom: 0),
        style: ink,
      ),
      _richText(
        _filled(cut.tail, width: body.availableWidth),
        body.copyWith(bottom: head.bottom),
        style: ink,
      ),
    ];
  }

  /// A text leaf: the smallest thing the writer can carry across a page.
  ///
  /// The leaf is wrapped in a `CustomPaint` that sets the stroke a fake bold
  /// needs, rather than the stroke being set once for the page: the width is
  /// graphics state, and every drawing widget between two leaves — a rule, a
  /// table's grid — resets it. The wrapper sets the state for exactly its own text
  /// and restores it afterwards: `CustomPaint` saves the state before its painter
  /// runs and restores it once the child is painted, and it forwards the writer's
  /// spanning hooks to the child, so a paragraph wrapped this way still breaks
  /// across a page.
  pw.Widget _richText(
    List<pw.InlineSpan> children,
    _BlockSkin skin, {
    pw.TextStyle? style,
    pw.TextAlign? textAlign,
  }) {
    final size = style?.fontSize ?? kPdfBodyFontSize;
    return skin.wrap(
      _fauxBold(
        pw.RichText(
          textAlign: textAlign,
          // Without this the writer refuses to break the text at all and throws
          // once one paragraph is taller than a page (see [_BlockSkin]).
          overflow: pw.TextOverflow.span,
          text: pw.TextSpan(style: style, children: children),
        ),
        size: size,
        ink: style?.color ?? _ink,
      ),
    );
  }

  /// Sets the stroke a fake bold is drawn with, for [child]'s own text alone.
  pw.Widget _fauxBold(
    pw.Widget child, {
    required double size,
    required PdfColor ink,
  }) => pw.CustomPaint(
    painter: (canvas, _) => canvas
      ..setLineWidth(size * _fauxBoldStroke)
      ..setStrokeColor(ink),
    child: child,
  );

  /// [style] as the writer draws emphasis in: the same face, stroked.
  pw.TextStyle _fauxBoldStyle(pw.TextStyle style) =>
      style.copyWith(renderingMode: PdfTextRenderingMode.fillAndStroke);

  /// [base] as an emphasised span, stroked only where a stroke is honest.
  ///
  /// One text leaf carries one stroke colour, which is the leaf's own ink — so a
  /// bold span in a *different* colour (a link's label) would come out with an ink
  /// outline around it. Such a span keeps the weight request, which the theme
  /// answers with the same face, and so prints as plain text: losing the fake on a
  /// bold link is better than drawing it in the wrong ink.
  pw.TextStyle _emphasisOn(pw.TextStyle base) {
    final bold = base.copyWith(fontWeight: pw.FontWeight.bold);
    final ink = base.color;
    if (ink != null && ink != _ink && ink != _quoteInk) return bold;
    return _fauxBoldStyle(bold);
  }

  pw.Widget _leaf(String text, pw.TextStyle style, _BlockSkin skin) =>
      _richText(
        _filled(<pw.InlineSpan>[
          pw.TextSpan(text: text, style: style),
        ], width: skin.availableWidth),
        skin,
        style: style,
      );

  pw.Widget _heading(HeadingNode node, _BlockSkin skin) {
    final level = node.level.clamp(1, 6);
    // The screen sets a heading at a ratio of its prose (24/20/18/16/15/14
    // against 15.5), so the page takes the same ratios of its own size.
    final size = switch (level) {
      1 => 16.3,
      2 => 13.5,
      3 => 12.2,
      4 => 10.8,
      5 => 10.2,
      _ => 9.5,
    };
    // Its leading is tighter than prose — 1.25 for the first level, 1.35 for the
    // last — and again only the difference is set, because the writer adds the
    // font's own height.
    final leading = switch (level) {
      1 => 1.25,
      2 || 3 => 1.3,
      _ => 1.35,
    };
    final style = _fauxBoldStyle(
      pw.TextStyle(
        fontSize: size,
        fontWeight: pw.FontWeight.bold,
        color: _ink,
        lineSpacing: size * (leading - 1.15),
      ),
    );
    final children = _filled(
      _spans(node.children, style: style, availableWidth: skin.availableWidth),
      width: skin.availableWidth,
    );
    return _richText(
      children,
      skin.copyWith(top: _headingTop, bottom: _headingBottom),
      style: style,
    );
  }

  /// One list, its items indented by the nesting the tree carries.
  ///
  /// The nesting is a depth rather than a measurement of a line's leading spaces:
  /// the parser already decided what is inside what, so an item can never be
  /// indented by a source this layout did not read.
  List<pw.Widget> _list(ListNode node, _BlockSkin skin) {
    final widgets = <pw.Widget>[];
    for (var index = 0; index < node.children.length; index++) {
      widgets.addAll(
        _listItem(
          node.children[index],
          skin,
          depth: 0,
          marker: _listMarker(node, index),
        ),
      );
    }
    return widgets;
  }

  /// The marker an item opens with: its number, or the bullet the source wrote.
  ///
  /// The bullet is the ASCII character the markdown used rather than `•`: the
  /// writer's built-in face reaches U+00FF, and a bullet it cannot draw is a
  /// bullet that throws, which is one of the substitutions this page documents.
  String _listMarker(ListNode node, int index) {
    if (node.ordered) return '${node.start + index}${node.delimiter} ';
    final bullet = node.marker.isEmpty ? '-' : node.marker;
    return '$bullet ';
  }

  List<pw.Widget> _listItem(
    ListItemNode item,
    _BlockSkin skin, {
    required int depth,
    required String marker,
  }) {
    // The marker rides in front of the item's first paragraph, in the same leaf.
    // A separate marker box would have to be a row, and a row cannot break across
    // a page; the price is that a wrapped item has no hanging indent, which
    // [_firstLine] pays back for every marker this layout can measure.
    final level = depth.clamp(0, _maxIndentLevels);
    final outer = skin.copyWith(indent: skin.indent + _indentStep * level);
    final inner = outer.copyWith(indent: outer.indent + _indentStep);
    final mark = _itemMarker(item.checked, marker);
    final widgets = <pw.Widget>[];
    var chunk = <BlockNode>[];

    void flush() {
      if (chunk.isEmpty) return;
      final blocks = chunk;
      chunk = <BlockNode>[];
      final first = widgets.isEmpty;
      widgets.addAll(
        _blocksOf(
          blocks,
          skin: inner.copyWith(bottom: _listItemGap),
          marker: first ? mark : null,
          firstSkin: outer,
        ),
      );
    }

    for (final child in item.children) {
      if (child is ListNode) {
        // A nested list is a level deeper and starts a line of its own.
        flush();
        for (var index = 0; index < child.children.length; index++) {
          widgets.addAll(
            _listItem(
              child.children[index],
              // The caller's own skin, not [inner]: the depth already carries the
              // step, and passing both would indent a nested item twice.
              skin,
              depth: depth + 1,
              marker: _listMarker(child, index),
            ),
          );
        }
      } else {
        chunk.add(child);
      }
    }
    flush();
    if (widgets.isEmpty) {
      widgets.add(_paragraph(const <InlineNode>[], outer, marker: mark));
    }
    return widgets;
  }

  /// A `- [ ]` item: a drawn box and its line, struck through when it is done.
  ///
  /// The box is drawn rather than printed as `[x]` — the source is not the
  /// document — and a checked item's text agrees with its box the way the
  /// renderer's does.
  pw.Widget _taskItem(TaskItemNode node, _BlockSkin skin) {
    final ink = node.checked && !node.radio
        ? _bodyStyle.copyWith(
            color: _overWhite(_ink, 0.75),
            decoration: pw.TextDecoration.lineThrough,
          )
        : null;
    return _paragraph(
      node.children,
      skin.copyWith(bottom: _listItemGap),
      marker: _taskMarker(checked: node.checked, radio: node.radio),
      style: ink,
    );
  }

  /// The marker an item opens with: a box for a task, the text for the rest.
  pw.InlineSpan _itemMarker(bool? checked, String marker) => checked != null
      ? _taskMarker(checked: checked, radio: false)
      : pw.TextSpan(text: marker, style: _bodyStyle);

  /// The box a task item's marker is drawn as.
  ///
  /// A box, not the `[x]` the source spells: the renderer draws an 18-pixel
  /// rounded box with a tick, and a page that prints the syntax instead shows a
  /// reader the source rather than the document. The tick is a drawn path rather
  /// than a `✓`, because the face the writer falls back to when no font resolved
  /// reaches only U+00FF and would drop the glyph.
  pw.InlineSpan _taskMarker({required bool checked, required bool radio}) =>
      pw.WidgetSpan(
        baseline: -3,
        child: pw.Container(
          width: _taskBoxSize,
          height: _taskBoxSize,
          margin: const pw.EdgeInsets.only(right: 5),
          alignment: pw.Alignment.center,
          decoration: pw.BoxDecoration(
            shape: radio ? pw.BoxShape.circle : pw.BoxShape.rectangle,
            borderRadius: radio
                ? null
                : pw.BorderRadius.all(pw.Radius.circular(_taskBoxSize * 0.28)),
            color: checked ? _overWhite(request.accent, 0.12) : null,
            border: pw.Border.all(
              color: checked ? request.accent : _ruleInk,
              width: 0.7,
            ),
          ),
          child: !checked
              ? null
              : radio
              ? pw.Container(
                  width: _taskDotSize,
                  height: _taskDotSize,
                  decoration: pw.BoxDecoration(
                    color: request.accent,
                    shape: pw.BoxShape.circle,
                  ),
                )
              : pw.CustomPaint(
                  size: PdfPoint(_taskTickSize, _taskTickSize),
                  painter: (canvas, size) {
                    canvas
                      ..setStrokeColor(request.accent)
                      ..setLineWidth(1.05)
                      ..moveTo(size.x * 0.18, size.y * 0.52)
                      ..lineTo(size.x * 0.42, size.y * 0.78)
                      ..lineTo(size.x * 0.84, size.y * 0.24)
                      ..strokePath();
                  },
                ),
        ),
      );

  /// A quoted body: the rule down its left edge, and its own blocks inside it.
  ///
  /// The body is the node's children, so there is no second reading of the source
  /// to keep in step with the screen: whatever the quote holds, this draws.
  List<pw.Widget> _quote(BlockQuoteNode node, _BlockSkin skin) {
    final base = skin.copyWith(
      indent: skin.indent + _indentStep,
      top: 4,
      bottom: 4,
      rule: _quoteRuleInk,
    );
    return _blocksOf(
      node.children,
      skin: base.copyWith(indent: base.indent + _quoteInset),
    );
  }

  List<pw.Widget> _codeBlock(CodeBlockNode node, _BlockSkin skin) {
    final code = node.code;
    final language = node.info.trim().split(RegExp(r'\s+')).first;
    final diagram = _diagramOf(node);
    if (diagram != null) {
      final raster = _diagramRaster(diagram.code, diagram.language);
      // A diagram with no bitmap falls back to its source, which is the only
      // faithful thing left and what a reader can reproduce from.
      if (raster != null) return _diagramBlocks(raster, skin);
      _degradedDiagrams.add(diagram.code);
      return <pw.Widget>[
        _richText(<pw.InlineSpan>[
          pw.TextSpan(text: diagram.code, style: _monoStyle),
        ], _codeSurface(skin)),
      ];
    }
    // An indented (non-fenced) block has no language, and its body is the whole
    // thing: the highlighter would have nothing to add.
    return <pw.Widget>[
      _richText(
        _codeSpans(code, node.fenced ? language : ''),
        _codeSurface(skin),
      ),
    ];
  }

  /// The skin a code body wears: filled and inset, underneath whatever group it
  /// already sits in.
  _BlockSkin _codeSurface(_BlockSkin skin) => skin.copyWith(
    indent: skin.indent + 7,
    trailing: 7,
    top: 4,
    bottom: 4,
    padTop: 6,
    padBottom: 6,
    fill: skin.fill ?? _blockFill,
    radius: skin.radius == 0 ? 4 : skin.radius,
  );

  /// One drawing, scaled down when it is wider or taller than the page allows —
  /// never up: a capture's pixels are not what the page measures it by.
  List<pw.Widget> _diagramBlocks(PdfRaster raster, _BlockSkin skin) =>
      <pw.Widget>[
        skin.wrap(
          pw.Container(
            alignment: pw.Alignment.center,
            child: _rasterImage(raster, skin.availableWidth),
          ),
        ),
      ];

  /// One drawing, scaled to the room its block actually has — never up: a
  /// capture's pixels are not what the page measures it by.
  pw.Widget _rasterImage(PdfRaster raster, double availableWidth) {
    final scale = pdfRasterScale(
      width: raster.width,
      height: raster.height,
      availableWidth: availableWidth,
    );
    return pw.Image(
      pw.MemoryImage(raster.bytes),
      width: raster.width * scale,
      height: raster.height * scale,
      fit: pw.BoxFit.contain,
    );
  }

  List<pw.InlineSpan> _codeSpans(String code, String language) {
    if (language.isEmpty) return <pw.InlineSpan>[pw.TextSpan(text: code)];
    // An unknown language is not an error to the highlighter: it answers with
    // the plain text, which is exactly the fallback wanted here.
    final result = highlight.parse(code, language: language.toLowerCase());
    final nodes = result.nodes;
    if (nodes == null) return <pw.InlineSpan>[pw.TextSpan(text: code)];
    List<pw.InlineSpan> convert(List<Node> items) => <pw.InlineSpan>[
      for (final item in items)
        if (item.children != null)
          pw.TextSpan(
            style: _codeInk(item.className),
            children: convert(item.children!),
          )
        else
          pw.TextSpan(text: item.value ?? '', style: _codeInk(item.className)),
    ];
    return convert(nodes);
  }

  /// The ink the chat's own code theme gives [className], so a PDF's code is
  /// coloured by the same rules the screen uses.
  pw.TextStyle? _codeInk(String? className) {
    if (className == null) return null;
    final style = githubTheme[className];
    if (style == null) return null;
    return pw.TextStyle(
      color: style.color == null
          ? null
          : PdfColor.fromInt(style.color!.toARGB32()),
      fontWeight: style.fontWeight == FontWeight.bold
          ? pw.FontWeight.bold
          : null,
      fontStyle: style.fontStyle == FontStyle.italic
          ? pw.FontStyle.italic
          : null,
    );
  }

  pw.Widget _table(TableNode node, _BlockSkin skin) {
    final rows = node.children;
    if (rows.isEmpty) return pw.SizedBox();
    final columns = rows.fold<int>(
      0,
      (count, row) => math.max(count, row.children.length),
    );
    if (columns == 0) return pw.SizedBox();
    TableCellNode? cellAt(TableRowNode row, int index) =>
        index < row.children.length ? row.children[index] : null;
    final hasHeader = rows.first.header;
    return skin.wrap(
      pw.TableHelper.fromTextArray(
        // Every cell is a widget this layout builds, header and body alike, so the
        // one thing the writer must not supply is their type: a cell whose text
        // crosses as a plain string is drawn with `ThemeData.defaultTextStyle`,
        // which is the writer's 12-point default — larger than this page's prose,
        // and larger than its own header.
        headers: hasHeader
            ? <pw.Widget>[
                for (var index = 0; index < columns; index++)
                  _tableCell(cellAt(rows.first, index), header: true),
              ]
            : null,
        data: <List<pw.Widget>>[
          for (final row in hasHeader ? rows.skip(1) : rows)
            <pw.Widget>[
              for (var index = 0; index < columns; index++)
                _tableCell(cellAt(row, index), header: false),
            ],
        ],
        border: pw.TableBorder.all(color: _ruleInk, width: 0.5),
        // The screen tints a table with its own accent — 7% on the header row and
        // 1.5% on the body — over the surface; the page has only paper, so the
        // same tints are resolved over white. A table with no outer frame is not
        // a compromise: a decorated container around a table that can run past a
        // page is exactly the unbreakable box that makes this writer loop.
        headerDecoration: pw.BoxDecoration(
          color: _overWhite(request.accent, 0.07),
        ),
        rowDecoration: pw.BoxDecoration(
          color: _overWhite(request.accent, 0.015),
        ),
        headerAlignment: pw.Alignment.centerLeft,
        cellAlignment: pw.Alignment.centerLeft,
        // The screen pads a cell 10 by 9 pixels beside 15.5-point prose; that is
        // 6.8 by 6.1 points beside this page's 10.5-point prose.
        cellPadding: const pw.EdgeInsets.symmetric(
          horizontal: 6.8,
          vertical: 6.1,
        ),
        cellAlignments: <int, pw.AlignmentGeometry>{
          for (var index = 0; index < columns; index++)
            index: _alignmentFor(
              index < node.alignments.length
                  ? _textAlignOf(node.alignments[index])
                  : TextAlign.left,
            ),
        },
      ),
    );
  }

  /// One table cell, drawn at the size the screen gives it.
  ///
  /// A cell is its own markdown surface in the renderer too, so it is walked as
  /// one: the cell's inline code, links and emphasis survive — and the walk is
  /// given the cell's style, so an emphasised run inside a cell is the size of the
  /// plain text beside it rather than the body's. Unlike a paragraph the cell is
  /// clipped rather than paged — see [_CappedCell] — and the stroke a fake bold
  /// needs is set by the cell's own wrapper, because a run that inherited the
  /// width from whatever drew last (usually the grid, at 0.5) would be stroked by
  /// luck rather than by [_fauxBoldStroke].
  pw.Widget _tableCell(TableCellNode? cell, {required bool header}) {
    final runs = cell?.children ?? const <InlineNode>[];
    if (runs.isEmpty) return pw.SizedBox();
    final style = header
        ? _fauxBoldStyle(pw.TextStyle(fontSize: _tableHeaderSize, color: _ink))
        : pw.TextStyle(fontSize: _tableCellSize, color: _ink);
    return _CappedCell(
      maxHeight: _maxUnbreakableHeight,
      child: _fauxBold(
        pw.RichText(
          overflow: pw.TextOverflow.clip,
          text: pw.TextSpan(
            style: style,
            // No fill here: a cell's width belongs to the table, and this layout
            // does not know it until the table lays the column out. A break
            // opportunity placed for the page's own column would be *later* than
            // the cell's end, which leaves the cell's lines shorter than they were.
            children: _spans(runs, style: style),
          ),
        ),
        size: style.fontSize!,
        ink: _ink,
      ),
    );
  }

  /// A `<details>`: its summary band, then its body.
  ///
  /// An export is an archive: a block the reader had collapsed is written out
  /// with its body, because the alternative is losing it. The chevron is gone on
  /// paper, so the band is what says the body under it belongs to it.
  List<pw.Widget> _details(DetailsNode node, _BlockSkin skin) {
    final base = skin.copyWith(indent: skin.indent + _indentStep);
    DetailsSummaryNode? summary;
    for (final child in node.children) {
      if (child is DetailsSummaryNode) {
        summary = child;
        break;
      }
    }
    final body = node.children
        .where((child) => child is! DetailsSummaryNode)
        .toList(growable: false);
    final widgets = <pw.Widget>[];
    final label = summary == null
        ? ''
        : toPlainText(summary).trim().replaceAll(RegExp(r'\s+'), ' ');
    if (label.isNotEmpty) {
      widgets.add(
        _leaf(
          label,
          _bodyBold,
          base.copyWith(
            bottom: 3,
            indent: base.indent + 4,
            trailing: 4,
            padTop: 3,
            padBottom: 3,
            fill: _blockFill,
            radius: 4,
          ),
        ),
      );
    }
    if (body.isNotEmpty) {
      widgets.addAll(
        _blocksOf(body, skin: base.copyWith(indent: base.indent + _indentStep)),
      );
    }
    return widgets.isEmpty ? <pw.Widget>[pw.SizedBox()] : widgets;
  }

  /// An HTML block the renderer would not have claimed.
  ///
  /// What the parser read inside the tag is drawn; a block it could not read —
  /// a stray `<div>` — keeps its whole text in the code ink, so nothing a model
  /// wrote is silently missing from the page.
  List<pw.Widget> _htmlBlock(HtmlBlockNode node, _BlockSkin skin) {
    if (node.children.isNotEmpty) {
      return <pw.Widget>[_paragraph(node.children, skin)];
    }
    final raw = node.raw.trim();
    if (raw.isEmpty) return const <pw.Widget>[];
    return <pw.Widget>[
      _richText(<pw.InlineSpan>[
        pw.TextSpan(text: raw, style: _monoStyle),
      ], _codeSurface(skin)),
    ];
  }

  /// A callout — an alert or a directive — as a titled band with its body.
  ///
  /// The screen draws it as a card whose title comes from the surface's locale;
  /// the page has no locale, so the label is handed in with the request. A band
  /// with no label still keeps its body: the words matter more than the kind.
  List<pw.Widget> _namedBlock(NamedBlockNode node, _BlockSkin skin) {
    final label = request.alertLabels[node.name] ?? '';
    final card = _onBand(_cardSkin, skin.fill == null ? null : skin);
    final widgets = <pw.Widget>[];
    if (label.isNotEmpty) {
      widgets.add(
        _leaf(
          label,
          _fauxBoldStyle(
            _captionStyle.copyWith(fontWeight: pw.FontWeight.bold),
          ),
          card.copyWith(bottom: 0),
        ),
      );
    }
    final body = node.children.whereType<BlockNode>().toList(growable: false);
    if (body.isEmpty) return widgets;
    widgets.addAll(
      _blocksOf(body, skin: card.copyWith(padTop: label.isEmpty ? 3 : 0)),
    );
    return widgets;
  }

  pw.Widget _displayMath(MathBlockNode node, _BlockSkin skin) {
    final source = node.tex;
    final raster = _mathRaster(source, display: true);
    if (raster != null) {
      return skin
          .copyWith(top: _asideGap, bottom: _paragraphGap)
          .wrap(
            pw.Container(
              alignment: pw.Alignment.center,
              child: _rasterImage(raster, skin.availableWidth),
            ),
          );
    }
    // No raster is a degrade rather than a hole: the formula's own source is
    // what a reader pastes somewhere that can draw it.
    _degradedMath.add(source);
    return _richText(
      <pw.InlineSpan>[pw.TextSpan(text: source)],
      skin.copyWith(
        padTop: 6,
        padBottom: 6,
        indent: skin.indent + 8,
        trailing: 8,
        fill: skin.fill ?? _blockFill,
        radius: skin.radius == 0 ? 4 : skin.radius,
      ),
      style: _mathInlineStyle,
      textAlign: pw.TextAlign.center,
    );
  }

  /// One run of inline nodes as the spans of one line of text.
  ///
  /// The tree is typed, so this dispatches on the node rather than on a kind plus
  /// a re-read of its source: an emphasis carries its own children, a code span
  /// its own text — and a `$` inside one stays the `$` it is, because the grammar
  /// claimed the span before inline math could see it — and an image its own
  /// target and alt.
  List<pw.InlineSpan> _spans(
    List<InlineNode> nodes, {
    pw.TextStyle? style,
    double? availableWidth,
  }) {
    // The page's own column when a caller does not know better (a table cell,
    // whose width belongs to the table), and the block's narrowed column
    // otherwise. Nullable rather than defaulted because the page width is a
    // computed value, and a default argument has to be constant.
    final width = availableWidth ?? _contentWidth;
    final base = style ?? _bodyStyle;
    final linkStyle = base.copyWith(
      color: request.accent,
      decoration: pw.TextDecoration.underline,
    );
    final out = <pw.InlineSpan>[];
    for (final node in nodes) {
      switch (node) {
        case TextNode(:final text):
          out.add(pw.TextSpan(text: text, style: style));
        case EmphasisNode(strong: true, :final children):
          out.addAll(
            _spans(children, style: _emphasisOn(base), availableWidth: width),
          );
        case EmphasisNode(:final children):
          out.addAll(
            _spans(
              children,
              style: base.copyWith(fontStyle: pw.FontStyle.italic),
              availableWidth: width,
            ),
          );
        case StrikethroughNode(:final children):
          out.addAll(
            _spans(
              children,
              style: base.copyWith(decoration: pw.TextDecoration.lineThrough),
              availableWidth: width,
            ),
          );
        case CodeSpanNode(:final code):
          out.add(
            pw.TextSpan(
              text: code,
              style: _monoStyle.copyWith(
                background: const pw.BoxDecoration(color: _blockFill),
              ),
            ),
          );
        case LinkNode(:final children, :final destination):
          out.add(
            pw.TextSpan(
              style: linkStyle,
              annotation: destination.isEmpty
                  ? null
                  : pw.AnnotationUrl(destination),
              // A link with no children still has a label — its target — because a
              // span with neither text nor children draws nothing at all.
              text: children.isEmpty ? destination : null,
              children: children.isEmpty
                  ? null
                  : _spans(children, style: linkStyle, availableWidth: width),
            ),
          );
        case ImageNode():
          out.add(_pictureSpan(node, base, width));
        case MathInlineNode(:final tex):
          out.add(_inlineMath(tex, display: false, availableWidth: width));
        case NamedInlineNode(name: 'kelivo-citation', :final attributes):
          final refs = parseCitationRefs(attributes['refs'] ?? '');
          if (refs.isEmpty) {
            out.add(pw.TextSpan(text: toPlainText(node), style: style));
            break;
          }
          for (final ref in refs) {
            out.add(
              _citationCapsule(
                citationLabelOf(ref, resolveCitationIndex(ref.id, _citations)),
              ),
            );
          }
        case LineBreakNode(:final hard):
          out.add(pw.TextSpan(text: hard ? '\n' : ' ', style: style));
        case HtmlElementNode(tag: 'a', :final attributes, :final children):
          final url = (attributes['href'] ?? '').trim();
          out.add(
            pw.TextSpan(
              style: linkStyle,
              annotation: url.isEmpty ? null : pw.AnnotationUrl(url),
              text: children.isEmpty ? url : null,
              children: children.isEmpty
                  ? null
                  : _spans(children, style: linkStyle, availableWidth: width),
            ),
          );
        case HtmlElementNode(tag: 'img', :final attributes):
          out.add(
            _pictureSpan(
              ImageNode(
                span: node.span,
                children: const <InlineNode>[],
                destination: (attributes['src'] ?? '').trim(),
                title: attributes['alt'],
              ),
              base,
              width,
            ),
          );
        case HtmlElementNode(tag: 'br'):
          out.add(pw.TextSpan(text: '\n', style: style));
        case NamedInlineNode(:final children) ||
            HtmlElementNode(:final children):
          out.addAll(_spans(children, style: style, availableWidth: width));
        default:
          final text = toPlainText(node);
          if (text.isNotEmpty) out.add(pw.TextSpan(text: text, style: style));
      }
    }
    return out;
  }

  /// A picture inside a line of prose.
  ///
  /// It stays a picture: an inline widget is laid out under the line's own width
  /// and moved to a new line when it does not fit, which is how the renderer puts
  /// one in a sentence. Only a picture whose bytes this device cannot read is
  /// written out as its reference instead, and the export counts it.
  pw.InlineSpan _pictureSpan(ImageNode node, pw.TextStyle base, double width) {
    final described = pdfPictureOf(node);
    final bytes = _pictures[described.url];
    final provider = bytes == null ? null : _provider(bytes);
    if (provider == null) {
      _undrawnImages.add(described.url);
      return pw.TextSpan(
        text: described.alt.isEmpty ? described.url : described.alt,
        style: base.copyWith(color: request.muted),
      );
    }
    return pw.WidgetSpan(
      baseline: -4,
      child: _pictureWidget(provider, described, width),
    );
  }

  /// The pill a citation is drawn as.
  ///
  /// The app draws a 20-point capsule in the accent's own tint and hangs it on
  /// the line with a two-point lift, so the page does the same at page scale.
  ///
  /// The box carries no `alignment`: an aligned child in this writer fills the
  /// line it sits in, which would draw a capsule as wide as the column and push
  /// every following word onto a line of its own. Padding sizes it to its label
  /// instead, which is what a pill is.
  pw.InlineSpan _citationCapsule(String label) => pw.WidgetSpan(
    baseline: -2.5,
    child: pw.Container(
      padding: const pw.EdgeInsets.symmetric(horizontal: 3.5, vertical: 2),
      decoration: pw.BoxDecoration(
        color: _overWhite(request.accent, 0.20),
        borderRadius: pw.BorderRadius.all(pw.Radius.circular(6.6)),
      ),
      child: pw.Text(label, style: pw.TextStyle(fontSize: 8, color: _ink)),
    ),
  );

  /// A formula inside a line of prose.
  ///
  /// The writer cannot typeset TeX, so the formula is a picture the caller drew
  /// beforehand. It is embedded at the size it was drawn — the rasterizer sets an
  /// inline formula at 1.2 of [kPdfBodyFontSize], the ratio the renderer uses —
  /// and hung on the text's baseline, which is what keeps a paragraph with a
  /// formula in it looking like one paragraph rather than like a paragraph with a
  /// gap.
  ///
  /// A display formula that arrives here — inside a table cell, or any other body
  /// that was flattened into spans — is looked up as the display drawing it is:
  /// the same TeX set in a line and set as a block are two pictures.
  ///
  /// A formula inside a line of prose.
  ///
  /// The writer cannot typeset TeX, so the formula is a picture the caller drew
  /// beforehand. It is embedded at the size it was drawn — the rasterizer sets an
  /// inline formula at 1.2 of [kPdfBodyFontSize], the ratio the renderer uses —
  /// and hung on the text's baseline, which is what keeps a paragraph with a
  /// formula in it looking like one paragraph rather than like a paragraph with a
  /// gap.
  ///
  /// The height bound matters more here than anywhere else. A `WidgetSpan` is one
  /// widget to the writer and cannot be broken, so a formula taller than a page is
  /// not a formula that pages badly — it is an export that never returns. Below
  /// that figure sits a second, tighter one: a picture taller than the prose line
  /// moves the line after it down by its overhang, so a tall formula is shrunk to
  /// [_inlineMathHeightCap] rather than allowed to break the page's rhythm.
  pw.InlineSpan _inlineMath(
    String source, {
    required bool display,
    required double availableWidth,
  }) {
    final tex = source.trim();
    if (tex.isEmpty) return const pw.TextSpan(text: '');
    final raster = _mathRaster(tex, display: display);
    if (raster == null) {
      _degradedMath.add(tex);
      return pw.TextSpan(text: tex, style: _mathInlineStyle);
    }
    var scale = pdfRasterScale(
      width: raster.width,
      height: raster.height,
      availableWidth: availableWidth,
    );
    if (raster.height * scale > _inlineMathHeightCap) {
      // Strictly smaller than [scale]: the branch is only taken when it is.
      scale = _inlineMathHeightCap / raster.height;
    }
    final height = raster.height * scale;
    return pw.WidgetSpan(
      child: pw.Image(
        pw.MemoryImage(raster.bytes),
        width: raster.width * scale,
        height: height,
      ),
      baseline: -height * 0.25,
    );
  }

  PdfRaster? _mathRaster(String source, {required bool display}) =>
      request.rasters[pdfRasterLookupKey(
        PdfRasterKey(
          source: source,
          kind: PdfRasterKind.math,
          display: display,
        ),
      )];

  PdfRaster? _diagramRaster(String code, String language) =>
      request.rasters[pdfRasterLookupKey(
        PdfRasterKey(
          source: code,
          kind: PdfRasterKind.diagram,
          language: language.toLowerCase(),
        ),
      )];

  DocumentNode _documentFor(ExportBlock block, String source) =>
      _documents[block] ?? _walk(source);

  DocumentNode _walk(String source) => _walkDocument(
    source,
    enableMathRendering: request.enableMathRendering,
    enableDollarLatex: request.enableDollarLatex,
  );

  pw.ImageProvider? _provider(Uint8List bytes) {
    if (_looksLikePng(bytes) || _looksLikeJpeg(bytes)) {
      return pw.MemoryImage(bytes);
    }
    // The writer reads PNG and JPEG itself; anything else a phone can produce
    // (a WebP, a GIF) is decoded and re-encoded, which is also the only way to
    // learn its size.
    try {
      final decoded = image_lib.decodeImage(bytes);
      if (decoded == null) return null;
      return pw.MemoryImage(Uint8List.fromList(image_lib.encodePng(decoded)));
    } catch (_) {
      return null;
    }
  }

  pw.Alignment _alignmentFor(TextAlign align) => switch (align) {
    TextAlign.center => pw.Alignment.center,
    TextAlign.right => pw.Alignment.centerRight,
    _ => pw.Alignment.centerLeft,
  };
}

bool _looksLikePng(Uint8List bytes) =>
    bytes.length > 8 && bytes[0] == 0x89 && bytes[1] == 0x50;

bool _looksLikeJpeg(Uint8List bytes) =>
    bytes.length > 3 && bytes[0] == 0xFF && bytes[1] == 0xD8;

/// The page's alignment for a table column's own alignment.
///
/// A column may declare left, centre or right; `none` is the parser's "the
/// delimiter row said nothing", which the screen draws left.
TextAlign _textAlignOf(TableAlignment alignment) => switch (alignment) {
  TableAlignment.center => TextAlign.center,
  TableAlignment.right => TextAlign.right,
  TableAlignment.left || TableAlignment.none => TextAlign.left,
};

/// Whether [rune] is one a Latin word is spelled with.
///
/// A break belongs between words, never inside one: the writer moves a word whole
/// and so does this layout, which is why a cut that lands between two of these is
/// moved back to the start of the word.
bool _isWordRune(int rune) =>
    (rune >= 0x30 && rune <= 0x39) || // 0-9
    (rune >= 0x41 && rune <= 0x5a) || // A-Z
    (rune >= 0x61 && rune <= 0x7a); // a-z

/// Whether [rune] is a space the writer's tokenizer splits on.
bool _isSpaceRune(int rune) =>
    rune == 0x20 ||
    rune == 0x09 ||
    rune == 0xa0 ||
    rune == 0x3000 ||
    rune == 0x1680 ||
    rune == 0x202f ||
    rune == 0x205f ||
    (rune >= 0x2000 && rune <= 0x200a);

/// The runes a line may not begin with: closing punctuation and the like.
///
/// The rule every Chinese typesetter applies and the writer has none of: it breaks
/// wherever a token ends, so without this a line opens with `。` or `」`.
const Set<int> _noBreakBefore = <int>{
  0x3001, 0x3002, // 、。
  0x3005, 0x3009, 0x300b, 0x300d, 0x300f, 0x3011, 0x3015, // 々〉》」』】〕
  0xff01,
  0xff05,
  0xff09,
  0xff0c,
  0xff0e,
  0xff1a,
  0xff1b,
  0xff1e,
  0xff1f, // ！％），．：；～？
  0x2019, 0x201d, 0x2025, 0x2026, 0x00b7, // ’”‥…·
};

/// The runes a line may not end with: opening punctuation.
const Set<int> _noBreakAfter = <int>{
  0x3008, 0x300a, 0x300c, 0x300e, 0x3010, 0x3014, // 〈《「『【〔
  0xff08, 0x2018, 0x201c, // （‘“
};

/// A break opportunity the writer may take for nothing.
///
/// A space in a span of its own whose word spacing is zero: the writer advances a
/// separator by `stringMetrics(' ').advanceWidth * wordSpacing` and never draws
/// one, so this costs no width, draws nothing, and leaves the text layer alone —
/// the glyphs on either side of it stay adjacent, and a reader copying the page
/// gets one unbroken run. It is the whole mechanism behind [_Layout._filled].
const pw.InlineSpan _breakOpportunity = pw.TextSpan(
  text: ' ',
  style: pw.TextStyle(wordSpacing: 0),
);
