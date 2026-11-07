import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

import '../utils/export_image_processor.dart';

enum ExportImageStage { preparing, diagrams, capturing, processing, saving }

@immutable
class ExportImageProgress {
  const ExportImageProgress(this.stage, {this.completed = 0, this.total = 0});
  final ExportImageStage stage;
  final int completed;
  final int total;
  double? get fraction =>
      total > 0 ? (completed / total).clamp(0.0, 1.0) : null;
}

final class ExportImageTooLarge implements Exception {
  const ExportImageTooLarge(this.pixels, this.limit);
  final int pixels, limit;
  @override
  String toString() => 'Image export exceeds $limit pixels ($pixels)';
}

/// Check the complete requested bitmap before allocating any image or slice.
void checkExportPixelBudget(Size size, double ratio, int? maxPixels) {
  if (maxPixels == null) return;
  final pixels = (size.width * ratio).ceil() * (size.height * ratio).ceil();
  if (pixels > maxPixels) throw ExportImageTooLarge(pixels, maxPixels);
}

/// The largest whole raster ratio that keeps [size] inside [maxPixels], or
/// `null` when even 1× does not fit.
///
/// Whole ratios only: a fractional one resamples every glyph for no gain in
/// legibility, and the caller can name the ratio it ended up with. This is the
/// opposite trade from [checkExportPixelBudget] — a document too tall for the
/// requested ratio still becomes a picture, just a smaller one.
double? exportRatioWithinBudget(Size size, double ratio, int? maxPixels) {
  if (maxPixels == null || size.isEmpty || ratio <= 0) return ratio;
  final logical = size.width * size.height;
  if (logical * ratio * ratio <= maxPixels) return ratio;
  final fitted = math.sqrt(maxPixels / logical).floorToDouble();
  return fitted >= 1 ? math.min(ratio, fitted) : null;
}

const double maxExportFullCaptureDimension = 15360;
const double maxExportSliceHeight = 4096;

/// Every full-surface export uses the same logical width and raster ratio, so a
/// picture of a message and a picture of a pasted document agree about type size
/// and stroke weight. Two callers depend on the agreement, so it lives here
/// rather than beside either of them.
const double desktopExportLogicalWidth = 720;
const double mobileExportLogicalWidth = 480;
const double exportImagePixelRatio = 3;

({double width, double pixelRatio}) exportRenderConfig({
  required bool isDesktop,
}) => (
  width: isDesktop ? desktopExportLogicalWidth : mobileExportLogicalWidth,
  pixelRatio: exportImagePixelRatio,
);

double exportSliceLogicalHeight(double ratio) =>
    math.max(1, (maxExportSliceHeight / ratio).floor()).toDouble();

double? exportFullCaptureRatio(Size size, double ratio) =>
    size.isEmpty ||
        ratio <= 0 ||
        math.max(size.width, size.height) * ratio >
            maxExportFullCaptureDimension
    ? null
    : ratio;

Future<Uint8List?> captureExportBoundary(
  RenderRepaintBoundary boundary,
  double ratio,
) async {
  ui.Image? image;
  try {
    image = await boundary.toImage(pixelRatio: ratio);
    if (image.width < (boundary.size.width * ratio).ceil() ||
        image.height < (boundary.size.height * ratio).ceil()) {
      return null;
    }
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    return data?.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
  } catch (error) {
    debugPrint('Export capture failed: $error');
    return null;
  } finally {
    image?.dispose();
  }
}

/// One mounted content tree and one fixed-width layout for all viewport slices.
/// No resampling: native PNG precision and the requested pixel ratio survive.
///
/// [maxPixels] is enforced before anything is allocated. By default it refuses
/// an oversized picture; with [shrinkToPixels] it lowers the ratio instead.
Future<ProcessedExportImage> captureExportWidget(
  BuildContext context,
  Widget child, {
  required ThemeData theme,
  double width = 480,
  double pixelRatio = 3,
  int? maxPixels,
  bool shrinkToPixels = false,
  ValueChanged<ExportImageProgress>? onProgress,
}) async {
  onProgress?.call(const ExportImageProgress(ExportImageStage.preparing));
  final boundaryKey = GlobalKey();
  final contentKey = GlobalKey();
  // The slice window is re-derived below once the content is measured and the
  // budget has settled the ratio; this is only what the first frames paint.
  final initialSliceHeight = exportSliceLogicalHeight(pixelRatio);
  final viewport = ValueNotifier<(double, double)>((0, initialSliceHeight));
  final entry = OverlayEntry(
    builder: (_) => Positioned(
      left: -10000,
      top: -10000,
      child: Theme(
        data: theme,
        child: ValueListenableBuilder<(double, double)>(
          valueListenable: viewport,
          child: SizedBox(key: contentKey, width: width, child: child),
          builder: (context, geometry, content) => RepaintBoundary(
            key: boundaryKey,
            child: Container(
              width: width,
              height: geometry.$2,
              color: theme.colorScheme.surface,
              child: Material(
                type: MaterialType.transparency,
                child: ClipRect(
                  child: OverflowBox(
                    alignment: Alignment.topCenter,
                    minWidth: width,
                    maxWidth: width,
                    minHeight: 0,
                    maxHeight: double.infinity,
                    child: Transform.translate(
                      offset: Offset(0, -geometry.$1),
                      child: content,
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    ),
  );
  Overlay.of(context).insert(entry);
  try {
    // Retain the existing initial asset settling window; subsequent slices use
    // the same mounted images and only wait for their updated viewport to paint.
    for (var i = 0; i < 3; i++) {
      await WidgetsBinding.instance.endOfFrame;
    }
    await Future<void>.delayed(const Duration(milliseconds: 500));
    final content = contentKey.currentContext!.findRenderObject()! as RenderBox;
    final size = content.size;
    if (size.isEmpty) throw StateError('Empty export content');
    // Settle the ratio before anything is allocated: a caller that would rather
    // have a smaller picture than an error gets the largest whole ratio its
    // budget allows.
    final ratio = shrinkToPixels
        ? exportRatioWithinBudget(size, pixelRatio, maxPixels)
        : pixelRatio;
    if (ratio == null) {
      throw ExportImageTooLarge(
        (size.width * size.height * pixelRatio * pixelRatio).ceil(),
        maxPixels!,
      );
    }
    if (!shrinkToPixels) checkExportPixelBudget(size, pixelRatio, maxPixels);
    final sliceHeight = exportSliceLogicalHeight(ratio);
    final slices = <({Uint8List bytes, int y})>[];
    Future<Uint8List?> capture(double top, double height) async {
      viewport.value = (top, height);
      await WidgetsBinding.instance.endOfFrame;
      final boundary =
          boundaryKey.currentContext!.findRenderObject()!
              as RenderRepaintBoundary;
      return captureExportBoundary(boundary, ratio);
    }

    Uint8List? single;
    if (exportFullCaptureRatio(size, ratio) != null) {
      onProgress?.call(
        const ExportImageProgress(ExportImageStage.capturing, total: 1),
      );
      single = await capture(0, size.height);
      if (single != null) {
        onProgress?.call(
          const ExportImageProgress(
            ExportImageStage.capturing,
            completed: 1,
            total: 1,
          ),
        );
      }
    }
    if (single == null) {
      final count = (size.height / sliceHeight).ceil();
      onProgress?.call(
        ExportImageProgress(ExportImageStage.capturing, total: count),
      );
      for (var i = 0; i < count; i++) {
        final top = i * sliceHeight;
        final bytes = await capture(
          top,
          math.min(sliceHeight, size.height - top),
        );
        if (bytes == null) {
          throw StateError('Could not capture export slice ${i + 1}/$count');
        }
        slices.add((bytes: bytes, y: (top * ratio).round()));
        onProgress?.call(
          ExportImageProgress(
            ExportImageStage.capturing,
            completed: i + 1,
            total: count,
          ),
        );
      }
    }
    onProgress?.call(const ExportImageProgress(ExportImageStage.processing));
    final processed = await compute(
      processExportImage,
      ExportImageProcessingRequest(
        singlePngBytes: single,
        outputWidth: (size.width * ratio).ceil(),
        outputHeight: (size.height * ratio).ceil(),
        slices: slices,
        preparePreview: true,
      ),
      debugLabel: 'export-image-png-processing',
    );
    // Report the ratio that was actually used: the caller asked for one and may
    // have been given a smaller one to stay inside its budget.
    return ProcessedExportImage(
      processed.pngBytes,
      processed.preview,
      appliedRatio: ratio,
    );
  } finally {
    entry.remove();
    entry.dispose();
    viewport.dispose();
  }
}
