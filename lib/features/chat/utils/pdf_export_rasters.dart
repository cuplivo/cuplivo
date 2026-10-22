import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_math_fork/flutter_math.dart';

import '../../../shared/markdown/math_adapter.dart';
import '../../../shared/widgets/diagram_exporter.dart';
import '../../../shared/widgets/mermaid_image_cache.dart';
import '../../../utils/svg_preview_html.dart';
import 'markdown_pdf_emitter.dart';

/// Draws the formulas and diagrams a PDF export embeds.
///
/// This is the one stage that cannot run in the layout isolate: a formula is a
/// widget and a diagram is a WebView, so both need the UI isolate and a frame.
/// It runs first, answers a map keyed by the source each drawing stands in for,
/// and the layout then embeds only what it is handed — a key with no entry is a
/// documented degrade, never a hole: the formula prints as its own TeX and the
/// diagram as its code.
Future<Map<String, PdfRaster>> rasterizePdfExportKeys(
  BuildContext context,
  List<PdfRasterKey> keys, {
  ColorScheme? pagePalette,
}) async {
  final rasters = <String, PdfRaster>{};
  if (keys.isEmpty) return rasters;

  // A diagram key names every fence the app draws as a picture, but only two of
  // them have a bitmap the export can capture: mermaid and SVG. PlantUML keeps
  // its code, which the layout reports as a degrade rather than passing off.
  final diagrams = <DiagramCode>[
    for (final key in keys)
      if (key.kind == PdfRasterKind.diagram &&
          (key.language.toLowerCase() == 'mermaid' ||
              isSvgCodeBlock(key.language, key.source)))
        (code: key.source, isSvg: isSvgCodeBlock(key.language, key.source)),
  ];
  if (diagrams.isNotEmpty) {
    await _addDiagramRasters(context, diagrams, rasters, pagePalette);
  }
  if (!context.mounted) return rasters;

  final overlay = Overlay.maybeOf(context);
  if (overlay == null) return rasters;
  for (final key in keys) {
    if (!context.mounted) break;
    if (key.kind != PdfRasterKind.math) continue;
    final name = pdfRasterLookupKey(key);
    if (rasters.containsKey(name)) continue;
    final raster = await _captureFormula(
      overlay,
      key.source,
      display: key.display,
    );
    if (raster != null) rasters[name] = raster;
  }
  return rasters;
}

/// Fills [rasters] from the app's own diagram bitmaps.
///
/// A diagram is drawn by the WebView pipeline the image export already drives,
/// so this primes that cache and reads it back rather than growing a second
/// renderer. PlantUML is deliberately not here: the offscreen renderer draws
/// mermaid and SVG only, so a PlantUML fence keeps its code-text fallback
/// instead of being drawn as mermaid.
///
/// [palette] is the light page's scheme: a diagram carries its own background,
/// and the cache entry has to be the one drawn for *this* page rather than the
/// one the app is showing.
Future<void> _addDiagramRasters(
  BuildContext context,
  List<DiagramCode> diagrams,
  Map<String, PdfRaster> rasters,
  ColorScheme? palette,
) async {
  await preRenderDiagramCodesForExport(context, diagrams, palette: palette);
  if (!context.mounted) return;
  final colorScheme = palette ?? Theme.of(context).colorScheme;
  final isDark = colorScheme.brightness == Brightness.dark;
  final themeVars = buildThemeVarsFromColorScheme(colorScheme);
  // The exporter's canvas draws at the device ratio times two, so the picture
  // holds that many times the diagram's own pixels.
  final ratio = MediaQuery.devicePixelRatioOf(context) * 2;
  for (final diagram in diagrams) {
    final bytes = MermaidImageCache.get(
      diagramImageCacheKey(
        diagram.code,
        isDark,
        themeVars,
        isSvg: diagram.isSvg,
      ),
    );
    if (bytes == null) continue;
    final pixels = _pngPixelSize(bytes);
    if (pixels == null) continue;
    rasters[pdfRasterLookupKey(
      PdfRasterKey(source: diagram.code, kind: PdfRasterKind.diagram),
    )] = PdfRaster(
      bytes: bytes,
      width: pixels.width / ratio,
      height: pixels.height / ratio,
    );
  }
}

/// The formula as a picture, at the size it occupies when drawn.
///
/// It is drawn the way the chat draws it, with one deliberate difference: the ink
/// is the page's, not the theme's. The page is always light, so a formula drawn
/// in a dark theme's ink would arrive invisible.
Future<PdfRaster?> _captureFormula(
  OverlayState overlay,
  String source, {
  required bool display,
}) async {
  final boundaryKey = GlobalKey();
  final painted = Completer<void>();
  late OverlayEntry entry;
  entry = OverlayEntry(
    builder: (context) {
      // Three frames, the same guard the app's whole-image capture waits on: the
      // first lays the formula out and the rest let its math paint.
      var frames = 0;
      void settle() {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          frames++;
          if (frames < 3) {
            settle();
          } else if (!painted.isCompleted) {
            painted.complete();
          }
        });
      }

      settle();

      // Off the visible area, which is where this app draws anything it does not
      // want the user to watch: the boundary still paints into its own layer, and
      // `toImage` reads that layer rather than the screen.
      return Positioned(
        left: -10000,
        top: -10000,
        child: RepaintBoundary(
          key: boundaryKey,
          child: Material(
            color: Colors.transparent,
            child: _formula(source, display: display),
          ),
        ),
      );
    },
  );
  overlay.insert(entry);
  try {
    await painted.future;
    await WidgetsBinding.instance.endOfFrame;
    final boundary = boundaryKey.currentContext?.findRenderObject();
    if (boundary is! RenderRepaintBoundary) return null;
    final size = boundary.size;
    if (size.isEmpty) return null;
    final image = await boundary.toImage(pixelRatio: _formulaPixelRatio);
    try {
      final data = await image.toByteData(format: ui.ImageByteFormat.png);
      if (data == null) return null;
      return PdfRaster(
        bytes: data.buffer.asUint8List(),
        width: size.width,
        height: size.height,
      );
    } finally {
      image.dispose();
    }
  } catch (_) {
    // An undrawable formula keeps its TeX fallback; the export goes on.
    return null;
  } finally {
    entry.remove();
  }
}

/// How many pixels per point a formula is captured at.
///
/// A captured formula is the one thing on the page that is not vector text, so
/// it is the one thing that can look soft beside it: the layout draws a line of
/// prose at [kPdfBodyFontSize], and a picture drawn at that size has to carry
/// enough pixels to survive both a printer and a reader's zoom. 5× is 360 DPI —
/// above the 300 a print expects — and a formula is small enough that the extra
/// pixels cost nothing worth measuring.
const double _formulaPixelRatio = 5;

/// The ink of the page this raster is drawn for, which is the light page the
/// layout always writes.
const Color _pageInk = Color(0xFF1F2328);

/// One formula, laid out at the size the page will draw it.
///
/// A display formula is set as a block of its own; an inline one is set in the
/// page's own body size, which is what lets the layout embed it without rescaling
/// it out of proportion with the line it sits in.
Widget _formula(String source, {required bool display}) {
  final tex = normalizeMathTex(source);
  // The screen sets an *inline* formula at 1.2 of its prose (`_inlineMathTextStyle`
  // in the renderer) and a display one at the prose size itself, so the page does
  // the same at its own scale: a formula drawn at the body size and printed beside
  // a line of it would otherwise read as a footnote.
  final fontSize = display
      ? kPdfBodyFontSize
      : kPdfBodyFontSize * _inlineFormulaScale;
  return Container(
    constraints: const BoxConstraints(maxWidth: 1600),
    // Transparent on purpose: the page behind a formula may be paper or a
    // message's own tint, and an opaque capture would print as a white box on the
    // second. The writer carries the picture's alpha through as an `/SMask`.
    child: Math.tex(
      tex,
      mathStyle: display ? MathStyle.display : MathStyle.text,
      textScaleFactor: 1,
      textStyle: TextStyle(fontSize: fontSize, color: _pageInk),
      onErrorFallback: (error) => Text(
        tex,
        style: TextStyle(fontSize: fontSize, color: _pageInk),
      ),
    ),
  );
}

/// How much larger than the prose an inline formula is drawn.
///
/// The renderer's own ratio, in one place: the capture draws the formula at this
/// size and the layout embeds it at the size it was drawn.
const double _inlineFormulaScale = 1.2;

/// The pixel size of a PNG, read out of its own header.
///
/// The diagrams come back as PNGs from a canvas and only their size is wanted
/// here: decoding the picture to measure it would spend megabytes on two ints.
({int width, int height})? _pngPixelSize(Uint8List bytes) {
  if (bytes.length < 24) return null;
  const signature = <int>[0x89, 0x50, 0x4E, 0x47];
  for (var index = 0; index < signature.length; index++) {
    if (bytes[index] != signature[index]) return null;
  }
  final header = ByteData.sublistView(bytes, 16, 24);
  return (width: header.getUint32(0), height: header.getUint32(4));
}
