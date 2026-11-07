import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';

import '../../../shared/widgets/diagram_exporter.dart';
import '../../chat/utils/export_image_processor.dart' show ExportImagePreview;
import '../../chat/widgets/export_image_capture.dart';
import '../widgets/markdown_export_document.dart';

/// The finished PNG and the downscaled copy the preview sheet can show without
/// decoding the full-size file.
typedef MarkdownExportImage = ({File file, ExportImagePreview? preview});

/// Renders [source] at the export's own width and raster ratio, writes the PNG
/// to a temporary file, and returns it. `null` means the page went away while
/// the diagrams were rendering, so there is nothing to show or save.
Future<MarkdownExportImage?> renderMarkdownExportImage(
  BuildContext context, {
  required String source,
  required bool isDesktop,
  double textScale = 1,
  ValueChanged<ExportImageProgress>? onProgress,
}) async {
  final config = exportRenderConfig(isDesktop: isDesktop);
  // A diagram is a bitmap before capture or it arrives as its own source code.
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
    // Capture still produces the picture; the diagram degrades to code.
  }
  if (!context.mounted) return null;
  // No pixel ceiling, deliberately: a long document exports as one tall picture
  // exactly as a long message does. The capture slices it at 4096 px and the
  // stitcher reassembles the slices, so the only bound is what the device can
  // allocate — a smaller type size is how a user keeps a picture within reach.
  final processed = await captureExportWidget(
    context,
    MarkdownExportDocument(
      source: source,
      width: config.width,
      textScale: textScale,
    ),
    theme: Theme.of(context),
    width: config.width,
    pixelRatio: config.pixelRatio,
    onProgress: onProgress,
  );
  onProgress?.call(const ExportImageProgress(ExportImageStage.saving));
  final directory = await getTemporaryDirectory();
  final file = File(
    '${directory.path}/markdown-export-${DateTime.now().microsecondsSinceEpoch}.png',
  );
  await file.writeAsBytes(processed.pngBytes, flush: true);
  return (file: file, preview: processed.preview);
}
