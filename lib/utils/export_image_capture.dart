import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:image/image.dart' as image_lib;

/// Keep whole-image captures below the common 16384px GPU texture edge while
/// avoiding the slice compositor for exports that can still fit at >=2x.
const double maxExportFullCapturePhysicalDimension = 15360.0;
const double maxExportCaptureSlicePhysicalHeight = 4096.0;
const double minExportFullCapturePixelRatio = 2.0;

/// Blank padding preserved around content when trimming exported images.
const int exportImageBlankTrimPreservePaddingPhysical = 48;

const int _exportImageBlankAlphaTolerance = 8;
const int _exportImageBlankColorTolerance = 3;

/// Whether a captured image is smaller than the requested render size, which
/// means the GPU clamped the capture to its max texture size.
bool exportCaptureIsClipped({
  required int capturedWidth,
  required int capturedHeight,
  required int expectedWidth,
  required int expectedHeight,
}) {
  return capturedWidth < expectedWidth || capturedHeight < expectedHeight;
}

/// The pixel ratio for a whole-image capture that stays within
/// [maxExportFullCapturePhysicalDimension], or null when the capped ratio
/// would drop below [minExportFullCapturePixelRatio] (slice mode instead).
@visibleForTesting
double? exportFullCapturePixelRatio(
  Size logicalSize, {
  required double requestedPixelRatio,
}) {
  if (logicalSize.isEmpty || requestedPixelRatio <= 0) return null;
  final maxLogicalDimension = math.max(logicalSize.width, logicalSize.height);
  if (maxLogicalDimension <= 0) return null;
  final requestedPhysicalDimension = maxLogicalDimension * requestedPixelRatio;
  if (requestedPhysicalDimension <= maxExportFullCapturePhysicalDimension) {
    return requestedPixelRatio;
  }
  final cappedPixelRatio =
      maxExportFullCapturePhysicalDimension / maxLogicalDimension;
  if (cappedPixelRatio < minExportFullCapturePixelRatio) return null;
  return math.min(requestedPixelRatio, cappedPixelRatio);
}

@visibleForTesting
bool shouldUseFullExportCapture(
  Size logicalSize, {
  required double pixelRatio,
}) {
  return exportFullCapturePixelRatio(
        logicalSize,
        requestedPixelRatio: pixelRatio,
      ) !=
      null;
}

@visibleForTesting
double exportCaptureSliceLogicalHeight({required double pixelRatio}) {
  final height = (maxExportCaptureSlicePhysicalHeight / pixelRatio).floor();
  return math.max(height, 1).toDouble();
}

Future<void> _waitForExportCaptureFrames({
  required int frameCount,
  Duration settleDelay = Duration.zero,
}) async {
  for (var i = 0; i < frameCount; i += 1) {
    await WidgetsBinding.instance.endOfFrame;
  }
  if (settleDelay > Duration.zero) {
    await Future<void>.delayed(settleDelay);
  }
}

/// Captures a laid-out boundary in one image, with pixel-ratio capping and
/// clip detection. Returns null when the capture would be clipped by the GPU
/// texture edge (callers should fall back to
/// [captureWidgetViewportSlicesPngBytes]).
///
/// [preservePadding] controls blank-trim: pass null to keep the image exactly
/// as rendered (the bytes are returned as-is, without isolate processing).
Future<Uint8List?> captureBoundaryPngBytes(
  RenderRepaintBoundary boundary, {
  required double pixelRatio,
  int? preservePadding,
}) async {
  if (boundary.size.isEmpty) return null;
  final fullCapturePixelRatio = exportFullCapturePixelRatio(
    boundary.size,
    requestedPixelRatio: pixelRatio,
  );
  if (fullCapturePixelRatio == null) return null;
  final fullCapture = await _captureFullBoundaryPngBytes(
    boundary,
    pixelRatio: fullCapturePixelRatio,
  );
  if (fullCapture == null) return null;
  if (preservePadding == null) return fullCapture;
  return _processCapturedExportPng(
    _CapturedExportPngProcessingRequest.single(
      singlePngBytes: fullCapture,
      preservePadding: preservePadding,
    ),
  );
}

/// Captures content taller than a GPU texture can hold by re-rendering it in
/// an offscreen overlay viewport, one [maxExportCaptureSlicePhysicalHeight]
/// window at a time, then stitching the windows into a single PNG. The
/// [buildContent] closure must rebuild the content with the exact layout it
/// has when captured whole (same theme, width and layout decisions).
Future<Uint8List?> captureWidgetViewportSlicesPngBytes(
  OverlayState overlay,
  Widget Function() buildContent, {
  required ThemeData theme,
  required double width,
  required double pixelRatio,
  required Size contentSize,
  int? preservePadding,
}) async {
  final sliceLogicalHeight = exportCaptureSliceLogicalHeight(
    pixelRatio: pixelRatio,
  );
  final outputWidth = (contentSize.width * pixelRatio).ceil();
  final outputHeight = (contentSize.height * pixelRatio).ceil();
  final slices = <({Uint8List bytes, int y})>[];

  double top = 0;
  while (top < contentSize.height) {
    final height = (contentSize.height - top).clamp(0.0, sliceLogicalHeight);
    final boundaryKey = GlobalKey();
    late OverlayEntry entry;
    entry = OverlayEntry(
      builder: (ctx) {
        return Positioned(
          left: -10000,
          top: -10000,
          child: ExportCaptureViewportRoot(
            theme: theme,
            boundaryKey: boundaryKey,
            width: width,
            viewportHeight: height,
            contentHeight: contentSize.height,
            offsetY: top,
            child: buildContent(),
          ),
        );
      },
    );

    overlay.insert(entry);
    try {
      await _waitForExportCaptureFrames(
        frameCount: 2,
        settleDelay: const Duration(milliseconds: 80),
      );
      final boundary =
          boundaryKey.currentContext?.findRenderObject()
              as RenderRepaintBoundary?;
      if (boundary == null) return null;
      // Raw full-boundary capture at the exact slice ratio (no re-capping:
      // a cap would desync slice heights from the stitch y positions). A
      // clipped slice aborts the whole export.
      final slice = await _captureFullBoundaryPngBytes(
        boundary,
        pixelRatio: pixelRatio,
      );
      if (slice == null) return null;
      slices.add((bytes: slice, y: (top * pixelRatio).round()));
    } finally {
      entry.remove();
    }

    top += height;
    await WidgetsBinding.instance.endOfFrame;
  }

  return _processCapturedExportPng(
    _CapturedExportPngProcessingRequest.slices(
      outputWidth: outputWidth,
      outputHeight: outputHeight,
      slices: slices
          .map(
            (slice) => _ExportPngSlicePayload(bytes: slice.bytes, y: slice.y),
          )
          .toList(growable: false),
      preservePadding: preservePadding,
    ),
  );
}

/// Renders a widget offscreen at its natural width, to be captured whole.
class ExportCaptureRoot extends StatelessWidget {
  const ExportCaptureRoot({
    super.key,
    required this.theme,
    required this.boundaryKey,
    required this.width,
    required this.child,
  });

  final ThemeData theme;
  final GlobalKey boundaryKey;
  final double width;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Theme(
      data: theme,
      child: RepaintBoundary(
        key: boundaryKey,
        child: Container(
          width: width,
          color: theme.colorScheme.surface,
          child: Material(type: MaterialType.transparency, child: child),
        ),
      ),
    );
  }
}

/// Renders [child] at full [contentHeight] and pans a [viewportHeight] window
/// over it via [offsetY], clipped to that window. Used by the slice capture.
class ExportCaptureViewportRoot extends StatelessWidget {
  const ExportCaptureViewportRoot({
    super.key,
    required this.theme,
    required this.boundaryKey,
    required this.width,
    required this.viewportHeight,
    required this.contentHeight,
    required this.offsetY,
    required this.child,
  });

  final ThemeData theme;
  final GlobalKey boundaryKey;
  final double width;
  final double viewportHeight;
  final double contentHeight;
  final double offsetY;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Theme(
      data: theme,
      child: RepaintBoundary(
        key: boundaryKey,
        child: Container(
          width: width,
          height: viewportHeight,
          color: theme.colorScheme.surface,
          child: Material(
            type: MaterialType.transparency,
            child: ClipRect(
              child: OverflowBox(
                alignment: Alignment.topCenter,
                minWidth: width,
                maxWidth: width,
                minHeight: contentHeight,
                maxHeight: contentHeight,
                child: Transform.translate(
                  offset: Offset(0, -offsetY),
                  child: child,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

Future<Uint8List> _processCapturedExportPng(
  _CapturedExportPngProcessingRequest request,
) {
  return compute(
    _processCapturedExportPngSync,
    request,
    debugLabel: 'export-image-png-processing',
  );
}

Uint8List _processCapturedExportPngSync(
  _CapturedExportPngProcessingRequest request,
) {
  final singlePngBytes = request.singlePngBytes;
  if (singlePngBytes != null) {
    final preservePadding = request.preservePadding;
    if (preservePadding == null) return singlePngBytes;
    return _trimExportPngBlankPadding(
      singlePngBytes,
      preservePadding: preservePadding,
    );
  }

  final stitched = _stitchExportPngSlicesImage(
    outputWidth: request.outputWidth,
    outputHeight: request.outputHeight,
    slices: request.slices
        .map((slice) => (bytes: slice.bytes, y: slice.y))
        .toList(growable: false),
  );
  final preservePadding = request.preservePadding;
  if (preservePadding == null) return image_lib.encodePng(stitched);
  return _encodeTrimmedExportImage(stitched, preservePadding: preservePadding);
}

class _CapturedExportPngProcessingRequest {
  const _CapturedExportPngProcessingRequest.single({
    required this.singlePngBytes,
    required this.preservePadding,
  }) : outputWidth = 0,
       outputHeight = 0,
       slices = const <_ExportPngSlicePayload>[];

  const _CapturedExportPngProcessingRequest.slices({
    required this.outputWidth,
    required this.outputHeight,
    required this.slices,
    required this.preservePadding,
  }) : singlePngBytes = null;

  final Uint8List? singlePngBytes;
  final int outputWidth;
  final int outputHeight;
  final List<_ExportPngSlicePayload> slices;
  final int? preservePadding;
}

class _ExportPngSlicePayload {
  const _ExportPngSlicePayload({required this.bytes, required this.y});

  final Uint8List bytes;
  final int y;
}

Future<Uint8List?> _captureFullBoundaryPngBytes(
  RenderRepaintBoundary boundary, {
  required double pixelRatio,
}) async {
  ui.Image? image;
  try {
    image = await boundary.toImage(pixelRatio: pixelRatio);
    final expectedWidth = (boundary.size.width * pixelRatio).ceil();
    final expectedHeight = (boundary.size.height * pixelRatio).ceil();
    if (exportCaptureIsClipped(
      capturedWidth: image.width,
      capturedHeight: image.height,
      expectedWidth: expectedWidth,
      expectedHeight: expectedHeight,
    )) {
      debugPrint(
        'Full export image capture was clipped '
        '(${image.width}x${image.height}, expected '
        '${expectedWidth}x$expectedHeight); falling back to slices.',
      );
      return null;
    }
    final data = await image.toByteData(
      format: ui.ImageByteFormat.rawStraightRgba,
    );
    if (data == null) return null;
    // 8-bit straight-alpha readback: ImageByteFormat.png on wide-gamut
    // backends (iOS Impeller) embeds 10/16-bit wide-gamut bytes that
    // downstream consumers misinterpret as sRGB. Encode to a plain
    // 8-bit PNG here instead.
    return image_lib.encodePng(
      image_lib.Image.fromBytes(
        width: image.width,
        height: image.height,
        bytes: data.buffer,
        numChannels: 4,
      ),
    );
  } catch (e) {
    debugPrint('Full export image capture failed, falling back to slices: $e');
    return null;
  } finally {
    image?.dispose();
  }
}

Uint8List _stitchExportPngSlices({
  required int outputWidth,
  required int outputHeight,
  required List<({Uint8List bytes, int y})> slices,
}) {
  return image_lib.encodePng(
    _stitchExportPngSlicesImage(
      outputWidth: outputWidth,
      outputHeight: outputHeight,
      slices: slices,
    ),
  );
}

image_lib.Image _stitchExportPngSlicesImage({
  required int outputWidth,
  required int outputHeight,
  required List<({Uint8List bytes, int y})> slices,
}) {
  final stitched = image_lib.Image(
    width: outputWidth,
    height: outputHeight,
    numChannels: 4,
  )..clear(image_lib.ColorRgba8(0, 0, 0, 0));

  for (final slice in slices) {
    final decoded = image_lib.decodePng(slice.bytes);
    if (decoded == null) continue;
    final dstY = math.max(slice.y, 0);
    final srcY = math.max(-slice.y, 0);
    final copyHeight = math.min(decoded.height - srcY, outputHeight - dstY);
    final copyWidth = math.min(decoded.width, outputWidth);
    if (copyWidth <= 0 || copyHeight <= 0) continue;

    for (var y = 0; y < copyHeight; y += 1) {
      for (var x = 0; x < copyWidth; x += 1) {
        stitched.setPixel(x, dstY + y, decoded.getPixel(x, srcY + y));
      }
    }
  }

  return stitched;
}

Uint8List _trimExportPngBlankPadding(
  Uint8List bytes, {
  required int preservePadding,
}) {
  final decoded = image_lib.decodePng(bytes);
  if (decoded == null || decoded.width <= 0 || decoded.height <= 0) {
    return bytes;
  }
  return _encodeTrimmedExportImage(decoded, preservePadding: preservePadding);
}

Uint8List _encodeTrimmedExportImage(
  image_lib.Image decoded, {
  required int preservePadding,
}) {
  final trimmed = _trimExportImageBlankPadding(
    decoded,
    preservePadding: preservePadding,
  );
  return image_lib.encodePng(trimmed);
}

image_lib.Image _trimExportImageBlankPadding(
  image_lib.Image decoded, {
  required int preservePadding,
}) {
  final background = _exportImageBlankReferencePixel(decoded);
  final width = decoded.width;
  final height = decoded.height;

  int? top;
  for (var y = 0; y < height; y += 1) {
    if (_exportImageRowHasContent(decoded, y, background)) {
      top = y;
      break;
    }
  }
  if (top == null) return decoded;

  var bottom = height - 1;
  for (var y = height - 1; y >= top; y -= 1) {
    if (_exportImageRowHasContent(decoded, y, background)) {
      bottom = y;
      break;
    }
  }

  var left = 0;
  for (var x = 0; x < width; x += 1) {
    if (_exportImageColumnHasContent(decoded, x, top, bottom, background)) {
      left = x;
      break;
    }
  }

  var right = width - 1;
  for (var x = width - 1; x >= left; x -= 1) {
    if (_exportImageColumnHasContent(decoded, x, top, bottom, background)) {
      right = x;
      break;
    }
  }

  final padding = math.max(preservePadding, 0);
  final cropLeft = math.max(left - padding, 0);
  final cropTop = math.max(top - padding, 0);
  final cropRight = math.min(right + padding, width - 1);
  final cropBottom = math.min(bottom + padding, height - 1);

  if (cropLeft == 0 &&
      cropTop == 0 &&
      cropRight == width - 1 &&
      cropBottom == height - 1) {
    return decoded;
  }

  return image_lib.copyCrop(
    decoded,
    x: cropLeft,
    y: cropTop,
    width: cropRight - cropLeft + 1,
    height: cropBottom - cropTop + 1,
  );
}

image_lib.Pixel _exportImageBlankReferencePixel(image_lib.Image image) {
  final corners = [
    image.getPixel(0, 0),
    image.getPixel(image.width - 1, 0),
    image.getPixel(0, image.height - 1),
    image.getPixel(image.width - 1, image.height - 1),
  ];
  for (final pixel in corners) {
    if (pixel.a <= _exportImageBlankAlphaTolerance) return pixel;
  }
  return corners.first;
}

bool _exportImageRowHasContent(
  image_lib.Image image,
  int y,
  image_lib.Pixel background,
) {
  for (var x = 0; x < image.width; x += 1) {
    if (!_exportImageIsBlankPixel(image.getPixel(x, y), background)) {
      return true;
    }
  }
  return false;
}

bool _exportImageColumnHasContent(
  image_lib.Image image,
  int x,
  int top,
  int bottom,
  image_lib.Pixel background,
) {
  for (var y = top; y <= bottom; y += 1) {
    if (!_exportImageIsBlankPixel(image.getPixel(x, y), background)) {
      return true;
    }
  }
  return false;
}

bool _exportImageIsBlankPixel(
  image_lib.Pixel pixel,
  image_lib.Pixel background,
) {
  if (pixel.a <= _exportImageBlankAlphaTolerance) return true;
  if (background.a <= _exportImageBlankAlphaTolerance) return false;
  return _exportImageChannelNear(pixel.r, background.r) &&
      _exportImageChannelNear(pixel.g, background.g) &&
      _exportImageChannelNear(pixel.b, background.b) &&
      _exportImageChannelNear(pixel.a, background.a);
}

bool _exportImageChannelNear(num a, num b) {
  return (a - b).abs() <= _exportImageBlankColorTolerance;
}

@visibleForTesting
Uint8List stitchExportPngSlicesForTesting({
  required int outputWidth,
  required int outputHeight,
  required List<({Uint8List bytes, int y})> slices,
}) {
  return _stitchExportPngSlices(
    outputWidth: outputWidth,
    outputHeight: outputHeight,
    slices: slices,
  );
}

@visibleForTesting
Uint8List trimExportPngBlankPaddingForTesting(
  Uint8List bytes, {
  required int preservePadding,
}) {
  return _trimExportPngBlankPadding(bytes, preservePadding: preservePadding);
}

@visibleForTesting
Future<Uint8List> processCapturedExportPngForTesting({
  Uint8List? singlePngBytes,
  int? outputWidth,
  int? outputHeight,
  List<({Uint8List bytes, int y})>? slices,
  int? preservePadding,
}) {
  final request = singlePngBytes != null
      ? _CapturedExportPngProcessingRequest.single(
          singlePngBytes: singlePngBytes,
          preservePadding: preservePadding,
        )
      : _CapturedExportPngProcessingRequest.slices(
          outputWidth: outputWidth ?? 0,
          outputHeight: outputHeight ?? 0,
          slices: (slices ?? const <({Uint8List bytes, int y})>[])
              .map(
                (slice) =>
                    _ExportPngSlicePayload(bytes: slice.bytes, y: slice.y),
              )
              .toList(growable: false),
          preservePadding: preservePadding,
        );
  return _processCapturedExportPng(request);
}

@visibleForTesting
Widget buildExportCaptureRootForTesting({
  required ThemeData theme,
  required Widget child,
  double width = 480,
}) {
  return ExportCaptureRoot(
    theme: theme,
    boundaryKey: GlobalKey(),
    width: width,
    child: child,
  );
}

@visibleForTesting
Widget buildExportCaptureViewportRootForTesting({
  required ThemeData theme,
  required Widget child,
  required double viewportHeight,
  required double contentHeight,
  double width = 480,
  double offsetY = 0,
}) {
  return ExportCaptureViewportRoot(
    theme: theme,
    boundaryKey: GlobalKey(),
    width: width,
    viewportHeight: viewportHeight,
    contentHeight: contentHeight,
    offsetY: offsetY,
    child: child,
  );
}
