import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/painting.dart' show FontStyle, FontWeight, TextAlign;
import 'package:flutter_highlight/themes/github.dart';
import 'package:gpt_markdown/gpt_markdown.dart';
import 'package:highlight/highlight.dart' show Node, highlight;
import 'package:image/image.dart' as image_lib;
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

import '../../../shared/widgets/markdown_with_highlight.dart';
import '../../../shared/widgets/markdown_line_lexer.dart';
import 'export_document.dart';

// The page is always light. A PDF is a thing that gets printed and archived, and
// a dark page is the wrong artefact for both; the block fills are the light ones
// the chat draws with.
const PdfColor _ink = PdfColor.fromInt(0xFF1F2328);
const PdfColor _mutedInk = PdfColor.fromInt(0xFF59636E);
const PdfColor _linkInk = PdfColor.fromInt(0xFF0969DA);
const PdfColor _ruleInk = PdfColor.fromInt(0xFFD8DEE4);
const PdfColor _blockFill = PdfColor.fromInt(0xFFF6F8FA);
const PdfColor _quoteRuleInk = PdfColor.fromInt(0xFFC4CCD4);
const PdfColor _quoteInk = PdfColor.fromInt(0xFF454F59);

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
    this.subtitle,
    this.bodyFont,
    this.monoFont,
    this.emojiFont,
    this.images = const <String, Uint8List>{},
    this.rasters = const <String, PdfRaster>{},
    this.enableMathRendering = true,
    this.enableDollarLatex = true,
  });

  final String title;

  /// The line under the title, already formatted by the caller (it knows the
  /// locale and the message count).
  final String? subtitle;

  final List<ExportMessage> messages;

  /// What a reasoning section is titled with, from the surface's locale.
  final String thinkingLabel;

  /// The faces to embed. Null leaves the writer's built-in font in place, which
  /// covers Latin-1 only.
  final Uint8List? bodyFont;
  final Uint8List? monoFont;

  /// The face an emoji is drawn from, which only works as a *fallback*: the
  /// writer looks for an emoji's bitmap on the fallback chain of the style that
  /// could not draw the rune, and never on the style's own font.
  final Uint8List? emojiFont;

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
  final layout = _PdfLayout(request, body: body, mono: mono);
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
                style: pw.TextStyle(fontSize: 8, color: _mutedInk),
              ),
            ),
      footer: (context) => pw.Container(
        alignment: pw.Alignment.center,
        margin: const pw.EdgeInsets.only(top: 10),
        child: pw.Text(
          '${context.pageNumber} / ${context.pagesCount}',
          style: pw.TextStyle(fontSize: 8, color: _mutedInk),
        ),
      ),
      build: (context) => layout.build(),
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
List<PdfRasterKey> pdfRasterKeysIn(
  String markdown, {
  required bool enableMathRendering,
  required bool enableDollarLatex,
}) {
  final document = _walkDocument(
    markdown,
    enableMathRendering: enableMathRendering,
    enableDollarLatex: enableDollarLatex,
  );
  final keys = <PdfRasterKey>[];
  void visit(MdNode node) {
    switch (node.kind) {
      case MdNodeKind.math:
        final source = _mathSource(node);
        if (source.isNotEmpty) {
          keys.add(
            PdfRasterKey(
              source: source,
              kind: PdfRasterKind.math,
              display: _isDisplayMath(node),
            ),
          );
        }
      case MdNodeKind.codeBlock:
        final fence = markdownFenceSource(
          unmaskBlockquoteFenceMarkers(node.range?.text ?? ''),
        );
        if (fence != null && isDiagramFence(fence.language, fence.code)) {
          keys.add(
            PdfRasterKey(
              source: fence.code,
              kind: PdfRasterKind.diagram,
              language: fence.language.toLowerCase(),
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

  for (final block in document.blocks) {
    visit(block);
  }
  return keys;
}

MdDocument _walkDocument(
  String source, {
  required bool enableMathRendering,
  required bool enableDollarLatex,
}) => MarkdownWithCodeHighlight.markdownDocumentFor(
  source,
  enableMathRendering: enableMathRendering,
  enableDollarLatex: enableDollarLatex,
  streaming: false,
);

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

/// Whether a node kind is part of a paragraph rather than a block of its own.
bool _isInlineKind(MdNodeKind kind) => switch (kind) {
  MdNodeKind.text ||
  MdNodeKind.bold ||
  MdNodeKind.italic ||
  MdNodeKind.strike ||
  MdNodeKind.underline ||
  MdNodeKind.inlineCode ||
  MdNodeKind.link ||
  MdNodeKind.image ||
  MdNodeKind.decoration => true,
  _ => false,
};

/// Whether a node can open a paragraph, so a list marker may ride in front of it.
///
/// This is wider than [_isInlineKind] on purpose. A list item is walked from its
/// own text, and what a walk hands back for `$x^2$ rest` is a *math* node, for
/// `[label](url) rest` a *group* — neither of which is an inline kind, and both
/// of which belong on the item's first line. A block that starts an item (a
/// display formula, a fence, a table, a nested quote) cannot share that line.
bool _opensParagraph(MdNode node) {
  if (_isInlineKind(node.kind)) return true;
  if (node.kind == MdNodeKind.group) {
    return node.children.isNotEmpty || (node.display ?? '').isNotEmpty;
  }
  if (node.kind == MdNodeKind.math) return !_isDisplayMath(node);
  return false;
}

/// How far the line a node starts on is indented, in points.
///
/// The IR has no list container: the list components match one line each
/// (`UnOrderedList.expString` is `(?:\-|\*)\ ([^\n]+)$`), so a nested item is a
/// *sibling* node whose line happens to be indented, and the one place that
/// indentation survives is the source the node addresses. Two spaces are one
/// level, which is how markdown lists are written; a tab counts as four.
///
/// The line measured is the one the node's first non-blank character is on, not
/// the one [offset] falls in: the whitespace between two blocks is a node of its
/// own that begins at the previous line's newline, so measuring from [offset]
/// would report the line that just ended.
///
/// Public because the rule is arithmetic rather than layout, and the tests pin it
/// directly: the alternative is inferring an indent from where a glyph landed in
/// a content stream.
double pdfIndentForSourceLine(String source, int offset) {
  var first = offset < 0 ? 0 : offset;
  if (first > source.length) first = source.length;
  while (first < source.length && _isBlankChar(source.codeUnitAt(first))) {
    first++;
  }
  if (first >= source.length) return 0;
  var lineStart = first;
  while (lineStart > 0 && !_isLineBreakChar(source.codeUnitAt(lineStart - 1))) {
    lineStart--;
  }
  var width = 0;
  for (var index = lineStart; index < first; index++) {
    width += source.codeUnitAt(index) == 0x09 ? 4 : 1;
  }
  return (width ~/ 2).clamp(0, _maxIndentLevels) * _indentStep;
}

bool _isBlankChar(int char) =>
    char == 0x20 || char == 0x09 || char == 0x0A || char == 0x0D;

bool _isLineBreakChar(int char) => char == 0x0A || char == 0x0D;

/// The indentation [node]'s own line claims, which is its nesting.
double _sourceIndentOf(MdNode? node) {
  final range = node?.range;
  if (range == null) return 0;
  return pdfIndentForSourceLine(range.source, range.start);
}

/// Whether a run of inline nodes draws nothing at all.
///
/// The walk hands back the whitespace between two blocks as a text node — and for
/// a nested list that text node *is* the indentation — so a run of blank nodes is
/// the gap between blocks, which the block spacing already draws. Emitting it
/// would put a blank line between every pair of list items.
bool _isBlankRun(List<MdNode> run) => run.every(_isBlankNode);

bool _isBlankNode(MdNode node) =>
    (node.range?.text ?? node.display ?? '').trim().isEmpty;

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
        borderRadius: radius == 0
            ? null
            : pw.BorderRadius.all(pw.Radius.circular(radius)),
      ),
      child: child,
    );
  }
}

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
  _PdfLayout(this.request, {required this.body, required this.mono});

  final PdfExportRequest request;
  final pw.Font? body;
  final pw.Font? mono;

  /// The walked bodies, one per markdown block, keyed by the block itself: a
  /// prepare pass resolves pictures from them and the layout then reuses them
  /// rather than walking every body twice.
  final Map<ExportBlock, MdDocument> _documents = <ExportBlock, MdDocument>{};
  final Map<String, Uint8List> _pictures = <String, Uint8List>{};

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
  static const _BlockSkin _plainSkin = _BlockSkin(bottom: 5);

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
  static const _BlockSkin _asideSkin = _BlockSkin(top: 4, bottom: 4);

  pw.TextStyle get _bodyStyle =>
      pw.TextStyle(fontSize: kPdfBodyFontSize, color: _ink, lineSpacing: 2.6);
  pw.TextStyle get _bodyBold =>
      _bodyStyle.copyWith(fontWeight: pw.FontWeight.bold);
  pw.TextStyle get _monoStyle => pw.TextStyle(
    fontSize: 9,
    color: _ink,
    lineSpacing: 2.2,
    font: mono,
    fontFallback: _monoFallback,
  );
  pw.TextStyle get _captionStyle =>
      pw.TextStyle(fontSize: 9, color: _mutedInk, font: body);
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
        for (final block in document.blocks) {
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

  void _collectPictureUrls(MdNode node, Set<String> urls) {
    if (node.kind == MdNodeKind.image) {
      final url = _imageParts(node.range?.text ?? '').url;
      if (url.isNotEmpty) urls.add(url);
    }
    for (final child in node.children) {
      _collectPictureUrls(child, urls);
    }
  }

  List<pw.Widget> build() {
    final widgets = <pw.Widget>[
      pw.Text(
        request.title,
        style: pw.TextStyle(
          fontSize: 19,
          fontWeight: pw.FontWeight.bold,
          color: _ink,
        ),
      ),
      if (request.subtitle != null)
        pw.Padding(
          padding: const pw.EdgeInsets.only(top: 2, bottom: 12),
          child: pw.Text(
            request.subtitle!,
            style: pw.TextStyle(fontSize: 9, color: _mutedInk),
          ),
        ),
    ];
    for (var index = 0; index < request.messages.length; index++) {
      final message = request.messages[index];
      if (index > 0) {
        widgets.add(pw.Divider(color: _ruleInk, height: 18, thickness: 0.6));
      }
      widgets.add(_messageHeader(message));
      for (final block in message.blocks) {
        widgets.addAll(_block(block));
      }
    }
    return widgets;
  }

  pw.Widget _messageHeader(ExportMessage message) => pw.Container(
    margin: const pw.EdgeInsets.only(bottom: 5),
    child: pw.Row(
      crossAxisAlignment: pw.CrossAxisAlignment.end,
      children: [
        pw.Expanded(
          child: pw.Text(
            message.roleName,
            style: pw.TextStyle(
              fontSize: 11,
              fontWeight: pw.FontWeight.bold,
              color: _ink,
            ),
          ),
        ),
        pw.Text(
          message.time,
          style: pw.TextStyle(fontSize: 8, color: _mutedInk),
        ),
      ],
    ),
  );

  List<pw.Widget> _block(ExportBlock block) {
    switch (block) {
      case ExportText(:final text):
        return _blocksOf(_documentFor(block, text).blocks);
      case ExportReasoning(:final text):
        // The card is drawn per block rather than around a column of them, so
        // its body stays paginatable (see [_BlockSkin]).
        return <pw.Widget>[
          _leaf(
            request.thinkingLabel,
            _captionStyle.copyWith(fontWeight: pw.FontWeight.bold),
            _cardSkin.copyWith(bottom: 0),
          ),
          ..._blocksOf(
            _documentFor(block, text).blocks,
            skin: _cardSkin.copyWith(padTop: 0),
          ),
        ];
      case ExportToolCall(:final name, :final content):
        return <pw.Widget>[_toolCall(name, content)];
      case ExportImage(:final uri, :final bytes):
        return _pictureBlock(uri, bytes);
      case ExportFile(:final name, :final mime):
        return <pw.Widget>[
          _leaf('- $name ($mime)', _captionStyle, const _BlockSkin(bottom: 2)),
        ];
    }
  }

  /// A tool call: its name, then whatever it answered, in one monospace body.
  ///
  /// One leaf rather than a name and a body stacked in a column, because tool
  /// output is exactly the text that grows past a page.
  pw.Widget _toolCall(String name, String content) {
    final label = name.isEmpty ? '[tool]' : '[$name]';
    final body = content.trim();
    return _richText(<pw.InlineSpan>[
      pw.TextSpan(
        text: label,
        style: _monoStyle.copyWith(fontWeight: pw.FontWeight.bold),
      ),
      if (body.isNotEmpty) pw.TextSpan(text: '\n$body', style: _monoStyle),
    ], _cardSkin);
  }

  List<pw.Widget> _pictureBlock(
    String uri,
    Uint8List? bytes, {
    _BlockSkin skin = _asideSkin,
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
          // A picture is one widget and cannot break across a page, so it is
          // bounded by height as well as by width: a phone screenshot is
          // taller than a page and would otherwise fail the whole export.
          child: pw.ConstrainedBox(
            constraints: pw.BoxConstraints(
              maxWidth: double.infinity,
              maxHeight: _maxUnbreakableHeight,
            ),
            child: pw.Image(provider, fit: pw.BoxFit.scaleDown),
          ),
        ),
      ),
    ];
  }

  /// The blocks of one walked markdown body.
  ///
  /// The walk is flat: a paragraph is a run of consecutive inline nodes, and a
  /// block node ends the run. Building the runs here is what turns the IR back
  /// into the layout the renderer draws — and it is the only place that has to
  /// know which kinds are blocks.
  ///
  /// Every widget it returns is meant to sit directly in the page flow, so a
  /// caller may append them to the document's child list but must not stack
  /// them in a `Column` (see [_BlockSkin]).
  List<pw.Widget> _blocksOf(
    List<MdNode> nodes, {
    _BlockSkin skin = _plainSkin,
    String? marker,
    _BlockSkin? firstSkin,
  }) {
    final widgets = <pw.Widget>[];
    final inline = <MdNode>[];
    var pendingMarker = marker;
    var pendingFirst = firstSkin;

    // The indentation a block's own line claims is its nesting: the IR keeps no
    // list container, so a nested item is a sibling whose line is indented. A
    // body walked from a component's own content is a source of its own, where
    // that indentation is relative to the content — which is why this composes
    // with the step a list item or a quote already added.
    _BlockSkin skinFor(MdNode? node) =>
        skin.copyWith(indent: skin.indent + _sourceIndentOf(node));

    void flush() {
      if (inline.isEmpty) return;
      final run = List<MdNode>.of(inline);
      inline.clear();
      // A marker is the one thing a blank run still has to draw, because a list
      // item can hold nothing else.
      if (pendingMarker == null && _isBlankRun(run)) return;
      // The run that carries a marker sits where the item's own line is; the ones
      // after it are one step in, under the item's text. So that one run has its
      // own skin.
      final blockSkin = pendingFirst ?? skinFor(run.first);
      pendingFirst = null;
      final pictures = run
          .where((node) => node.kind == MdNodeKind.image)
          .length;
      final blanks = run.where(_isBlankNode).length;
      // The line break after a picture is a node of its own, so a paragraph that
      // is nothing but a picture is a picture run plus whitespace — and treating
      // that as prose is what would print an illustration as its alt text.
      if (pictures > 0 && pictures + blanks == run.length) {
        if (pendingMarker != null) {
          widgets.add(
            _paragraph(const <MdNode>[], blockSkin, marker: pendingMarker),
          );
          pendingMarker = null;
        }
        // A run of nothing but pictures is a picture paragraph, which is how a
        // model writes an illustration: it gets the picture, not its alt text.
        for (final node in run) {
          if (node.kind != MdNodeKind.image) continue;
          final parts = _imageParts(node.range?.text ?? '');
          widgets.addAll(_pictureBlock(parts.url, null, skin: blockSkin));
        }
        return;
      }
      widgets.add(_paragraph(run, blockSkin, marker: pendingMarker));
      pendingMarker = null;
    }

    for (final node in nodes) {
      if (_isInlineKind(node.kind)) {
        inline.add(node);
        continue;
      }
      switch (node.kind) {
        case MdNodeKind.math:
          if (_isDisplayMath(node)) {
            flush();
            widgets.add(_displayMath(node, skinFor(node)));
          } else {
            inline.add(node);
          }
        case MdNodeKind.heading:
          flush();
          widgets.add(_heading(node, skinFor(node)));
        case MdNodeKind.listItem:
          flush();
          widgets.addAll(_listItem(node, skin));
        case MdNodeKind.quote:
          flush();
          widgets.addAll(_quote(node, skin));
        case MdNodeKind.codeBlock:
          flush();
          widgets.addAll(_codeBlock(node, skinFor(node)));
        case MdNodeKind.table:
          flush();
          widgets.add(_table(node, skinFor(node)));
        case MdNodeKind.details:
          flush();
          widgets.addAll(_details(node, skin));
        case MdNodeKind.group:
          if (node.children.isNotEmpty) {
            inline.add(node);
          } else if ((node.display ?? '').isNotEmpty) {
            inline.add(node);
          } else if ((node.range?.text ?? '').trim().isEmpty) {
            // A run of newlines is the gap between two blocks, which the
            // paragraph spacing already draws.
            flush();
          } else {
            flush();
            widgets.add(
              pw.Divider(color: _ruleInk, height: 12, thickness: 0.6),
            );
          }
        default:
          inline.add(node);
      }
    }
    flush();
    return widgets;
  }

  /// One paragraph: a run of inline nodes, optionally opening with a marker.
  pw.Widget _paragraph(List<MdNode> run, _BlockSkin skin, {String? marker}) {
    final children = <pw.InlineSpan>[
      if (marker != null && marker.isNotEmpty)
        pw.TextSpan(text: '$marker ', style: _bodyStyle),
      ..._spans(run, availableWidth: skin.availableWidth),
    ];
    return _richText(children, skin, style: _bodyStyle);
  }

  /// A text leaf: the smallest thing the writer can carry across a page.
  pw.Widget _richText(
    List<pw.InlineSpan> children,
    _BlockSkin skin, {
    pw.TextStyle? style,
    pw.TextAlign? textAlign,
  }) => skin.wrap(
    pw.RichText(
      textAlign: textAlign,
      // Without this the writer refuses to break the text at all and throws
      // once one paragraph is taller than a page (see [_BlockSkin]).
      overflow: pw.TextOverflow.span,
      text: pw.TextSpan(style: style, children: children),
    ),
  );

  pw.Widget _leaf(String text, pw.TextStyle style, _BlockSkin skin) =>
      _richText(<pw.InlineSpan>[pw.TextSpan(text: text)], skin, style: style);

  pw.Widget _heading(MdNode node, _BlockSkin skin) {
    final level = node.open.trim().length.clamp(1, 6);
    final size = switch (level) {
      1 => 16.0,
      2 => 14.0,
      3 => 12.5,
      _ => 11.5,
    };
    final style = pw.TextStyle(
      fontSize: size,
      fontWeight: pw.FontWeight.bold,
      color: _ink,
      lineSpacing: 2.6,
    );
    final children = node.children.isEmpty
        ? <pw.InlineSpan>[pw.TextSpan(text: node.range?.text ?? '')]
        : _spans(
            node.children,
            style: style,
            availableWidth: skin.availableWidth,
          );
    return _richText(children, skin.copyWith(top: 8, bottom: 3), style: style);
  }

  List<pw.Widget> _listItem(MdNode node, _BlockSkin skin) {
    final marker = node.open.trim();
    // The marker rides in front of the item's first paragraph, in the same leaf.
    // A separate marker box would have to be a row, and a row cannot break
    // across a page; the price is that a wrapped item has no hanging indent. The
    // marker sits where the item's own line is indented and what the item holds
    // is one step further in.
    final base = skin.copyWith(indent: skin.indent + _sourceIndentOf(node));
    final inner = base.copyWith(indent: base.indent + _indentStep);
    final children = node.children;
    final opensWithText =
        children.isNotEmpty && _opensParagraph(children.first);
    if (marker.isEmpty) {
      return _blocksOf(children, skin: inner);
    }
    if (opensWithText) {
      return _blocksOf(children, skin: inner, marker: marker, firstSkin: base);
    }
    // An item that opens with a block — a display formula, a fence, a table —
    // cannot share its line, so the marker is a line of its own, tight against
    // what it labels.
    return <pw.Widget>[
      _paragraph(const <MdNode>[], base.copyWith(bottom: 0), marker: marker),
      ..._blocksOf(children, skin: inner),
    ];
  }

  List<pw.Widget> _quote(MdNode node, _BlockSkin skin) {
    // A quote's own structure is not in the tree — its node declares the whole
    // block — so the body is walked again, with the `>` markers the renderer
    // strips put back out of the way. The walk is the same one, so the two
    // cannot disagree about what the quote holds.
    final body = unmaskBlockquoteFenceMarkers(
      markdownQuoteText(node.range?.text ?? ''),
    );
    final base = skin.copyWith(
      indent: skin.indent + _sourceIndentOf(node),
      top: 4,
      bottom: 4,
      rule: _quoteRuleInk,
    );
    return _blocksOf(
      _walk(body).blocks,
      skin: base.copyWith(indent: base.indent + _quoteInset),
    );
  }

  List<pw.Widget> _codeBlock(MdNode node, _BlockSkin skin) {
    final fence = markdownFenceSource(
      unmaskBlockquoteFenceMarkers(node.range?.text ?? ''),
    );
    if (fence == null) {
      return <pw.Widget>[
        _richText(<pw.InlineSpan>[
          pw.TextSpan(text: node.range?.text ?? '', style: _monoStyle),
        ], _codeSurface(skin)),
      ];
    }
    if (isDiagramFence(fence.language, fence.code)) {
      final raster = _diagramRaster(fence.code, fence.language);
      // A diagram with no bitmap falls back to its source, which is the only
      // faithful thing left and what a reader can reproduce from.
      if (raster != null) return _diagramBlocks(raster, skin);
      _degradedDiagrams.add(fence.code);
      return <pw.Widget>[
        _richText(<pw.InlineSpan>[
          pw.TextSpan(text: fence.code, style: _monoStyle),
        ], _codeSurface(skin)),
      ];
    }
    return <pw.Widget>[
      _richText(_codeSpans(fence.code, fence.language), _codeSurface(skin)),
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

  pw.Widget _table(MdNode node, _BlockSkin skin) {
    final table = markdownTableData(node.range?.text ?? '');
    if (table.isEmpty) return pw.SizedBox();
    final rows = <List<String>>[
      for (final row in table.rows)
        <String>[for (final cell in row) unmaskCodeSpanDollars(cell)],
    ];
    return skin.wrap(
      pw.TableHelper.fromTextArray(
        headers: table.hasHeader ? rows.first : null,
        data: table.hasHeader ? rows.sublist(1) : rows,
        border: pw.TableBorder.all(color: _ruleInk, width: 0.5),
        headerDecoration: const pw.BoxDecoration(color: _blockFill),
        headerAlignment: pw.Alignment.centerLeft,
        cellAlignment: pw.Alignment.centerLeft,
        cellPadding: const pw.EdgeInsets.symmetric(horizontal: 5, vertical: 3),
        headerStyle: pw.TextStyle(
          fontSize: 9,
          fontWeight: pw.FontWeight.bold,
          color: _ink,
        ),
        cellStyle: pw.TextStyle(fontSize: 9, color: _ink),
        cellAlignments: <int, pw.AlignmentGeometry>{
          for (var index = 0; index < table.columnCount; index++)
            index: _alignmentFor(table.alignments[index]),
        },
        // A cell is its own markdown surface in the renderer too, so it is
        // walked as one: the cell's inline code, links and emphasis survive.
        // Unlike a paragraph it is clipped rather than paged — see [_CappedCell].
        cellBuilder: (index, data, rowNum) {
          final cell = data is String ? data : '';
          if (cell.isEmpty) return pw.SizedBox();
          return _CappedCell(
            maxHeight: _maxUnbreakableHeight,
            child: pw.RichText(
              overflow: pw.TextOverflow.clip,
              text: pw.TextSpan(children: _spans(_walk(cell).blocks)),
            ),
          );
        },
      ),
    );
  }

  List<pw.Widget> _details(MdNode node, _BlockSkin skin) {
    final parsed = markdownParseDetails(
      unmaskBlockquoteFenceMarkers(node.range?.text ?? ''),
    );
    if (parsed == null) return <pw.Widget>[pw.SizedBox()];
    final base = skin.copyWith(indent: skin.indent + _sourceIndentOf(node));
    final widgets = <pw.Widget>[
      _leaf(
        markdownDetailsSummaryText(parsed.summary),
        _bodyBold,
        base.copyWith(bottom: 2),
      ),
    ];
    // An export is an archive: a block the reader had collapsed is written out
    // with its body, because the alternative is losing it.
    final body = parsed.body.trim();
    if (body.isNotEmpty) {
      widgets.addAll(
        _blocksOf(
          _walk(body).blocks,
          skin: base.copyWith(indent: base.indent + _indentStep),
        ),
      );
    }
    return widgets;
  }

  pw.Widget _displayMath(MdNode node, _BlockSkin skin) {
    final source = _mathSource(node);
    final raster = _mathRaster(source, display: true);
    if (raster != null) {
      return skin.wrap(
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

  List<pw.InlineSpan> _spans(
    List<MdNode> nodes, {
    pw.TextStyle? style,
    double? availableWidth,
  }) {
    // The page's own column when a caller does not know better (a table cell,
    // whose width belongs to the table), and the block's narrowed column
    // otherwise. Nullable rather than defaulted because the page width is a
    // computed value, and a default argument has to be constant.
    final width = availableWidth ?? _contentWidth;
    final base = style ?? _bodyStyle;
    final out = <pw.InlineSpan>[];
    for (final node in nodes) {
      switch (node.kind) {
        case MdNodeKind.text:
          out.add(pw.TextSpan(text: node.range?.text ?? '', style: style));
        case MdNodeKind.bold:
          out.addAll(
            _spans(
              node.children,
              style: base.copyWith(fontWeight: pw.FontWeight.bold),
              availableWidth: width,
            ),
          );
        case MdNodeKind.italic:
          out.addAll(
            _spans(
              node.children,
              style: base.copyWith(fontStyle: pw.FontStyle.italic),
              availableWidth: width,
            ),
          );
        case MdNodeKind.strike:
          out.addAll(
            _spans(
              node.children,
              style: base.copyWith(decoration: pw.TextDecoration.lineThrough),
              availableWidth: width,
            ),
          );
        case MdNodeKind.underline:
          out.addAll(
            _spans(
              node.children,
              style: base.copyWith(decoration: pw.TextDecoration.underline),
              availableWidth: width,
            ),
          );
        case MdNodeKind.inlineCode:
          out.add(
            pw.TextSpan(
              text: unmaskCodeSpanDollars(_plainTextOf(node)),
              style: _monoStyle.copyWith(
                background: const pw.BoxDecoration(color: _blockFill),
              ),
            ),
          );
        case MdNodeKind.link:
          final url = _linkUrl(node);
          final linkStyle = base.copyWith(
            color: _linkInk,
            decoration: pw.TextDecoration.underline,
          );
          out.add(
            pw.TextSpan(
              style: linkStyle,
              annotation: url.isEmpty ? null : pw.AnnotationUrl(url),
              children: _spans(
                node.children,
                style: linkStyle,
                availableWidth: width,
              ),
            ),
          );
        case MdNodeKind.math:
          out.add(_inlineMath(node, width));
        case MdNodeKind.image:
          // A picture inside a line of prose is its reference rather than its
          // pixels, and the export says so: the reader gets a document that does
          // not claim to hold a picture it does not.
          final parts = _imageParts(node.range?.text ?? '');
          _undrawnImages.add(parts.url);
          out.add(
            pw.TextSpan(
              text: parts.alt.isEmpty ? parts.url : parts.alt,
              style: base.copyWith(color: _mutedInk),
            ),
          );
        case MdNodeKind.decoration:
          // The marker a list item declares already carries this.
          break;
        case MdNodeKind.group:
          if (node.children.isNotEmpty) {
            out.addAll(
              _spans(node.children, style: style, availableWidth: width),
            );
          } else {
            out.add(pw.TextSpan(text: node.display ?? '', style: style));
          }
        default:
          out.add(
            pw.TextSpan(
              text: node.display ?? node.range?.text ?? '',
              style: style,
            ),
          );
      }
    }
    return out;
  }

  /// A formula inside a line of prose.
  ///
  /// The writer cannot typeset TeX, so the formula is a picture the caller drew
  /// beforehand. It is embedded at the size it was drawn — the rasterizer sets an
  /// inline formula in [kPdfBodyFontSize], the size this page sets prose in — and
  /// hung on the text's baseline, which is what keeps a paragraph with a formula
  /// in it looking like one paragraph rather than like a paragraph with a gap.
  ///
  /// A display formula that arrives here — inside a table cell, or any other body
  /// that was flattened into spans — is looked up as the display drawing it is:
  /// the same TeX set in a line and set as a block are two pictures.
  ///
  /// The height bound matters more here than anywhere else. A `WidgetSpan` is one
  /// widget to the writer and cannot be broken, so a formula taller than a page is
  /// not a formula that pages badly — it is an export that never returns.
  pw.InlineSpan _inlineMath(MdNode node, double availableWidth) {
    final source = _mathSource(node);
    final raster = _mathRaster(source, display: _isDisplayMath(node));
    if (raster == null) {
      _degradedMath.add(source);
      return pw.TextSpan(text: source, style: _mathInlineStyle);
    }
    final scale = pdfRasterScale(
      width: raster.width,
      height: raster.height,
      availableWidth: availableWidth,
    );
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

  MdDocument _documentFor(ExportBlock block, String source) =>
      _documents[block] ?? _walk(source);

  MdDocument _walk(String source) => _walkDocument(
    source,
    enableMathRendering: request.enableMathRendering,
    enableDollarLatex: request.enableDollarLatex,
  );

  String _plainTextOf(MdNode node) {
    if (node.display != null && node.display!.isNotEmpty) return node.display!;
    if (node.children.isEmpty) return node.range?.text ?? '';
    final buffer = StringBuffer();
    for (final child in node.children) {
      buffer.write(_plainTextOf(child));
    }
    return buffer.toString();
  }

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

/// Whether a math node is a display formula rather than an inline one.
///
/// Both are one kind, and the difference is the delimiter the component
/// claimed: a block formula is written `$$…$$` or `\[…\]`, and the components
/// that claim it are the block ones.
bool _isDisplayMath(MdNode node) {
  final source = (node.range?.text ?? '').trimLeft();
  return source.startsWith(r'$$') || source.startsWith(r'\[');
}

/// The TeX a math node stands for, with its delimiters removed.
String _mathSource(MdNode node) {
  final text = (node.range?.text ?? node.display ?? '').trim();
  const pairs = <(String, String)>[
    (r'$$', r'$$'),
    (r'\[', r'\]'),
    (r'\(', r'\)'),
    (r'$', r'$'),
  ];
  for (final (open, close) in pairs) {
    if (text.length < open.length + close.length) continue;
    if (!text.startsWith(open) || !text.endsWith(close)) continue;
    return text.substring(open.length, text.length - close.length).trim();
  }
  return text;
}

/// The alt text and the target an image node's source holds.
({String alt, String url}) _imageParts(String source) {
  final trimmed = source.trim();
  final open = trimmed.indexOf('](');
  if (!trimmed.startsWith('![') || open < 0) {
    return (alt: '', url: trimmed);
  }
  final alt = trimmed.substring(2, open);
  final close = trimmed.lastIndexOf(')');
  final url = close > open + 2 ? trimmed.substring(open + 2, close).trim() : '';
  // The renderer reads a `WxH` alt as a size rather than as text, so a size is
  // not what a reader should see in its place.
  final isSize = RegExp(r'^\d+(x\d+)?$').hasMatch(alt.trim());
  return (alt: isSize ? '' : alt.trim(), url: url);
}

/// The URL a link node re-emits after its label.
String _linkUrl(MdNode node) {
  final close = node.close;
  if (close.startsWith('](') && close.endsWith(')')) {
    return close.substring(2, close.length - 1).trim();
  }
  return '';
}
