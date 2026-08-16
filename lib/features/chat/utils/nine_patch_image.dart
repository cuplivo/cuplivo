import 'dart:async';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';

/// Nine-patch parsed metadata extracted from a .9.png image.
class NinePatchData {
  /// Horizontal stretchable regions (list of [start, end] pairs, in pixels).
  final List<_Range> xStretch;

  /// Vertical stretchable regions (list of [start, end] pairs, in pixels).
  final List<_Range> yStretch;

  /// Content padding extracted from bottom/right guide pixels.
  final EdgeInsets? contentPadding;

  /// Source image width (excluding the 1px guide borders).
  final int width;

  /// Source image height (excluding the 1px guide borders).
  final int height;

  const NinePatchData({
    required this.xStretch,
    required this.yStretch,
    required this.width,
    required this.height,
    this.contentPadding,
  });
}

class _Range {
  final int start;
  final int end;
  const _Range(this.start, this.end);
  int get length => end - start;
}

/// Parse a .9.png image's guide pixels into stretch regions.
///
/// Nine-patch format:
/// - Top edge: black pixels mark horizontal stretchable regions
/// - Left edge: black pixels mark vertical stretchable regions
/// - Bottom edge (optional): black pixels mark horizontal content area
/// - Right edge (optional): black pixels mark vertical content area
///
/// Returns null if the image is not a valid nine-patch.
Future<NinePatchData?> parseNinePatchAsync(ui.Image image) async {
  if (image.width < 3 || image.height < 3) return null;

  final bytes = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
  if (bytes == null) return null;

  final w = image.width;
  final h = image.height;
  final data = bytes.buffer.asUint8List();

  bool isBlack(int x, int y) {
    final offset = (y * w + x) * 4;
    if (offset + 3 >= data.length) return false;
    final r = data[offset];
    final g = data[offset + 1];
    final b = data[offset + 2];
    final a = data[offset + 3];
    return a > 128 && r < 32 && g < 32 && b < 32;
  }

  // Parse top edge (x stretch regions)
  final xStretch = <_Range>[];
  int? rangeStart;
  for (int x = 1; x < w - 1; x++) {
    if (isBlack(x, 0)) {
      rangeStart ??= x - 1;
    } else if (rangeStart != null) {
      xStretch.add(_Range(rangeStart, x - 1));
      rangeStart = null;
    }
  }
  if (rangeStart != null) {
    xStretch.add(_Range(rangeStart, w - 2));
  }

  // Parse left edge (y stretch regions)
  final yStretch = <_Range>[];
  rangeStart = null;
  for (int y = 1; y < h - 1; y++) {
    if (isBlack(0, y)) {
      rangeStart ??= y - 1;
    } else if (rangeStart != null) {
      yStretch.add(_Range(rangeStart, y - 1));
      rangeStart = null;
    }
  }
  if (rangeStart != null) {
    yStretch.add(_Range(rangeStart, h - 2));
  }

  if (xStretch.isEmpty || yStretch.isEmpty) {
    return null;
  }

  // Parse content padding (bottom and right edges)
  int? contentLeft;
  int? contentRight;
  for (int x = 1; x < w - 1; x++) {
    if (isBlack(x, h - 1)) {
      contentLeft ??= x - 1;
      contentRight = x - 1;
    }
  }

  int? contentTop;
  int? contentBottom;
  for (int y = 1; y < h - 1; y++) {
    if (isBlack(w - 1, y)) {
      contentTop ??= y - 1;
      contentBottom = y - 1;
    }
  }

  EdgeInsets? padding;
  if (contentLeft != null &&
      contentRight != null &&
      contentTop != null &&
      contentBottom != null) {
    final contentWidth = w - 2;
    final contentHeight = h - 2;
    padding = EdgeInsets.only(
      left: contentLeft.toDouble(),
      top: contentTop.toDouble(),
      right: (contentWidth - contentRight - 1).toDouble(),
      bottom: (contentHeight - contentBottom - 1).toDouble(),
    );
  }

  return NinePatchData(
    xStretch: xStretch,
    yStretch: yStretch,
    width: w - 2,
    height: h - 2,
    contentPadding: padding,
  );
}

/// A CustomPainter that draws a nine-patch image.
class NinePatchPainter extends CustomPainter {
  final ui.Image image;
  final NinePatchData ninePatch;

  const NinePatchPainter({
    required this.image,
    required this.ninePatch,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()..filterQuality = FilterQuality.low;

    final xSegments =
        _buildSegments(ninePatch.xStretch, ninePatch.width, size.width);
    final ySegments =
        _buildSegments(ninePatch.yStretch, ninePatch.height, size.height);

    double dstY = 0;
    for (final ySegment in ySegments) {
      double dstX = 0;
      for (final xSegment in xSegments) {
        final srcRect = Rect.fromLTWH(
          xSegment.srcStart.toDouble(),
          ySegment.srcStart.toDouble(),
          xSegment.srcLength.toDouble(),
          ySegment.srcLength.toDouble(),
        );
        final dstRect =
            Rect.fromLTWH(dstX, dstY, xSegment.dstLength, ySegment.dstLength);
        canvas.drawImageRect(image, srcRect, dstRect, paint);
        dstX += xSegment.dstLength;
      }
      dstY += ySegment.dstLength;
    }
  }

  @override
  bool shouldRepaint(NinePatchPainter oldDelegate) {
    return oldDelegate.image != image || oldDelegate.ninePatch != ninePatch;
  }

  List<_Segment> _buildSegments(
    List<_Range> stretch,
    int srcTotal,
    double dstTotal,
  ) {
    final segments = <_Segment>[];

    int fixedSize = srcTotal;
    for (final r in stretch) {
      fixedSize -= r.length;
    }

    final availableStretch = dstTotal - fixedSize;
    final totalStretchSrc =
        stretch.fold<int>(0, (sum, r) => sum + r.length);
    final double stretchRatio =
        totalStretchSrc > 0 ? availableStretch / totalStretchSrc : 0.0;

    int srcPos = 0;

    for (int i = 0; i <= stretch.length; i++) {
      final nextStretchStart =
          i < stretch.length ? stretch[i].start : srcTotal;
      if (srcPos < nextStretchStart) {
        final len = nextStretchStart - srcPos;
        segments.add(_Segment(srcPos, len, len.toDouble()));
        srcPos += len;
      }

      if (i < stretch.length) {
        final r = stretch[i];
        final srcLen = r.length;
        final dstLen = srcLen * stretchRatio;
        segments.add(_Segment(r.start, srcLen, dstLen));
        srcPos += srcLen;
      }
    }

    return segments;
  }
}

class _Segment {
  final int srcStart;
  final int srcLength;
  final double dstLength;
  const _Segment(this.srcStart, this.srcLength, this.dstLength);
}

/// A widget that displays a nine-patch image as background.
class NinePatchImage extends StatefulWidget {
  final ImageProvider imageProvider;
  final Widget? child;
  final EdgeInsetsGeometry? padding;

  const NinePatchImage({
    super.key,
    required this.imageProvider,
    this.child,
    this.padding,
  });

  @override
  State<NinePatchImage> createState() => _NinePatchImageState();
}

class _NinePatchImageState extends State<NinePatchImage> {
  ui.Image? _image;
  NinePatchData? _ninePatch;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _loadImage();
  }

  @override
  void didUpdateWidget(NinePatchImage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.imageProvider != widget.imageProvider) {
      _loadImage();
    }
  }

  Future<void> _loadImage() async {
    setState(() => _loading = true);
    final completer = Completer<ui.Image>();
    final stream = widget.imageProvider.resolve(const ImageConfiguration());
    stream.addListener(ImageStreamListener(
      (info, _) => completer.complete(info.image),
      onError: (e, st) => completer.completeError(e, st),
    ));
    try {
      final image = await completer.future;
      final ninePatch = await parseNinePatchAsync(image);
      if (mounted) {
        setState(() {
          _image = image;
          _ninePatch = ninePatch;
          _loading = false;
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() => _loading = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loading || _image == null || _ninePatch == null) {
      return widget.child ?? const SizedBox.shrink();
    }

    return CustomPaint(
      painter: NinePatchPainter(image: _image!, ninePatch: _ninePatch!),
      child: widget.padding != null
          ? Padding(padding: widget.padding!, child: widget.child)
          : widget.child,
    );
  }

  @override
  void dispose() {
    _image?.dispose();
    super.dispose();
  }
}
