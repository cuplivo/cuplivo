import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';

import '../../../shared/widgets/diagram_exporter.dart';
import '../../chat/utils/export_image_processor.dart' show ExportImagePreview;
import '../../chat/widgets/export_image_capture.dart';
import '../widgets/markdown_export_document.dart';

/// The finished PNG and the downscaled copy the preview sheet can show without
/// decoding the full-size file. [reducedResolution] is true when the sheet was
/// too tall for the requested ratio and was drawn smaller to fit one picture.
typedef MarkdownExportImage = ({
  File file,
  ExportImagePreview? preview,
  bool reducedResolution,
});

/// The most one export of a pasted document may allocate. A 24 MP RGBA
/// composite is about 96 MB, plus one decoded 4096-px slice while stitching;
/// past that a phone, not the export, is what fails.
const int markdownExportMaxPixels = 24 * 1000 * 1000;

/// The width the export rasterises.
///
/// [previewWidth] is what the preview last laid out at. Before a preview has
/// laid out — the phone editor's first export — the sheet gets the column the
/// preview will occupy: the window, minus the SafeArea's horizontal insets and
/// the layout's own 16 px side padding.
double markdownExportWidthFor({
  required double? previewWidth,
  required double maxWidth,
  required Size window,
  required EdgeInsets safeAreaPadding,
}) {
  final preview = previewWidth;
  if (preview != null && preview > 0) return preview;
  final contentWidth = window.width - safeAreaPadding.horizontal - 32;
  return math.min(math.max(contentWidth, 1), maxWidth);
}

/// Renders [source] at [width] — the width the preview reported — and raster
/// ratio, writes the PNG to a temporary file, and returns it. `null` means the
/// page went away while the diagrams were rendering, so there is nothing to
/// show or save.
Future<MarkdownExportImage?> renderMarkdownExportImage(
  BuildContext context, {
  required String source,
  required double width,
  required double pixelRatio,
  double textScale = 1,
  ValueChanged<ExportImageProgress>? onProgress,
}) async {
  // A diagram is a bitmap before capture, or the picture carries its failure
  // card. It never carries the diagram's source instead.
  try {
    await preRenderDiagramCodesForExport(
      context,
      extractDiagramCodes(source),
      onProgress: (completed, total) => onProgress?.call(
        ExportImageProgress(
          ExportImageStage.diagrams,
          completed: completed,
          total: total,
        ),
      ),
    );
  } catch (_) {
    // Capture still produces the picture; the diagram shows its failure card.
  }
  if (!context.mounted) return null;
  // The input here is a file of any length, so this path states a ceiling where
  // the message path does not: past [markdownExportMaxPixels] the sheet is
  // drawn at the largest whole ratio that fits rather than refused, because a
  // long document still has to become a picture.
  final processed = await captureExportWidget(
    context,
    MarkdownExportDocument(
      source: source,
      width: width,
      textScale: textScale,
      capture: true,
    ),
    theme: Theme.of(context),
    width: width,
    pixelRatio: pixelRatio,
    maxPixels: markdownExportMaxPixels,
    shrinkToPixels: true,
    onProgress: onProgress,
  );
  onProgress?.call(const ExportImageProgress(ExportImageStage.saving));
  final directory = await getTemporaryDirectory();
  final file = File(
    '${directory.path}/markdown-export-${DateTime.now().microsecondsSinceEpoch}.png',
  );
  await file.writeAsBytes(processed.pngBytes, flush: true);
  return (
    file: file,
    preview: processed.preview,
    reducedResolution: processed.appliedRatio < pixelRatio,
  );
}
