import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../../../../icons/lucide_adapter.dart';
import '../../../../l10n/app_localizations.dart';
import '../../../../theme/app_font_weights.dart';
import 'compress_editor_controller.dart';

/// The editor body: one image, one draggable divider.
///
/// Both halves are drawn over the *same* region of the same framing — the left
/// from the reference image (the source at the largest resolution the working
/// budget reaches), the right from the artifact itself — so 1:1 means one
/// artifact pixel per logical pixel and the comparison shows what the encoder
/// and the chosen resolution did to the original. Nothing is stretched: the
/// region is letterboxed inside the preview area at its own aspect ratio.
class CompressPreview extends StatefulWidget {
  const CompressPreview({
    super.key,
    required this.controller,
    this.formatLabel,
  });

  final CompressEditorController controller;

  /// Label drawn over the compressed half, e.g. "JPEG 80".
  final String? formatLabel;

  @override
  State<CompressPreview> createState() => _CompressPreviewState();
}

class _CompressPreviewState extends State<CompressPreview> {
  Size _layout = Size.zero;
  Rect _gestureStartVisible = Rect.zero;
  Rect _gestureStartDest = Rect.zero;
  Offset _gestureSourcePoint = Offset.zero;

  CompressEditorController get _controller => widget.controller;

  Size get _workingSize => Size(
    _controller.workingWidth.toDouble(),
    _controller.workingHeight.toDouble(),
  );

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final layout = Size(constraints.maxWidth, constraints.maxHeight);
        if (layout != _layout) {
          _layout = layout;
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (!mounted) return;
            _syncViewport(fit: _controller.visibleSource.isEmpty);
          });
        }
        final dest = _fitDest();
        // Tags sit inside the drawn image area, not in the letterbox bars.
        final tagArea = dest.isEmpty ? Offset.zero & _layout : dest;
        return ClipRect(
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onDoubleTapDown: (details) => _toggleZoom(details.localPosition),
            onScaleStart: _onScaleStart,
            onScaleUpdate: _onScaleUpdate,
            child: Stack(
              fit: StackFit.expand,
              children: [
                if (_controller.original != null)
                  CustomPaint(
                    painter: _SplitPreviewPainter(
                      original: _controller.original!,
                      originalScale: _controller.originalScale,
                      result: _controller.result,
                      source: _controller.visibleSource,
                      destination: dest,
                      divider: _controller.divider,
                    ),
                  ),
                Positioned(
                  left: tagArea.left + 10,
                  top: tagArea.top + 10,
                  child: _PreviewTag(
                    text: AppLocalizations.of(
                      context,
                    )!.compressEditorOriginalSide,
                  ),
                ),
                if (widget.formatLabel != null)
                  Positioned(
                    right: (_layout.width - tagArea.right) + 10,
                    top: tagArea.top + 10,
                    child: _PreviewTag(
                      text: widget.formatLabel!,
                      busy: _controller.encoding,
                    ),
                  ),
                _dividerHandle(dest),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _dividerHandle(Rect dest) {
    if (dest.isEmpty) return const SizedBox.shrink();
    final x = dest.left + _controller.divider * dest.width;
    return Positioned(
      left: x - 14,
      top: dest.top,
      height: dest.height,
      width: 28,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onHorizontalDragUpdate: (details) => _controller.setDivider(
          _controller.divider + details.delta.dx / dest.width,
        ),
        child: Center(
          child: Container(
            width: 2,
            color:
                Colors.white, // color-gate: ignore (divider over photo preview)
            child: Center(
              child: Container(
                width: 22,
                height: 34,
                decoration: BoxDecoration(
                  color: Colors
                      .white, // color-gate: ignore (divider over photo preview)
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Icon(
                  Lucide.GripVertical,
                  size: 15,
                  color: Colors
                      .black, // color-gate: ignore (divider over photo preview)
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  void _onScaleStart(ScaleStartDetails details) {
    _gestureStartVisible = _controller.visibleSource;
    _gestureStartDest = _fitDest();
    _gestureSourcePoint = _sourcePointAt(details.localFocalPoint);
  }

  void _onScaleUpdate(ScaleUpdateDetails details) {
    final start = _gestureStartVisible;
    final dest = _gestureStartDest;
    if (start.isEmpty || dest.isEmpty) return;
    final aspect = _framingAspect();
    if (aspect <= 0) return;
    final factor = details.scale <= 0 ? 1.0 : details.scale;
    final width = start.width / factor;
    // The height follows the framing's aspect rather than the gesture's own: a
    // region whose aspect drifts from the framing's is letterboxed into a
    // narrower strip, and a zoom keeps the aspect it started with, so one drift
    // would be permanent. See [_framingAspect].
    final height = width / aspect;
    final rel = Offset(
      (details.localFocalPoint.dx - dest.left) / dest.width,
      (details.localFocalPoint.dy - dest.top) / dest.height,
    );
    final next = Rect.fromLTWH(
      _gestureSourcePoint.dx - rel.dx * width,
      _gestureSourcePoint.dy - rel.dy * height,
      width,
      height,
    );
    _syncViewport(visible: _clamp(next));
  }

  /// Double tap toggles between the framing and true 1:1.
  ///
  /// The working image is decoded at the artifact's size, so 1:1 here is
  /// genuinely one artifact pixel per logical pixel — not one cached pixel.
  void _toggleZoom(Offset viewPoint) {
    final dest = _fitDest();
    if (dest.isEmpty || _workingSize.isEmpty) return;
    final current = _controller.visibleSource;
    final isOneToOne = current.width <= dest.width * 1.01;
    if (isOneToOne) {
      _syncViewport(visible: _defaultView());
      return;
    }
    final point = _sourcePointAt(viewPoint);
    final next = Rect.fromLTWH(
      point.dx - dest.width / 2,
      point.dy - dest.height / 2,
      dest.width,
      dest.height,
    );
    _syncViewport(visible: _clamp(next));
  }

  /// The default framing: fit to the viewport's width, never magnified.
  ///
  /// Contain-fit is always ≤ this, and the two only differ for a tall image —
  /// where contain-fit is exactly the case that fails: a 1000×8000 screenshot in
  /// a 390 px wide viewport would be drawn 75 px wide. Fitting the width keeps
  /// it legible and lets the vertical overflow pan.
  Rect _defaultView() {
    final working = _workingSize;
    if (working.isEmpty || _layout.isEmpty) return Rect.zero;
    // At most one working pixel per logical pixel, never magnified.
    final scale = math.min(1.0, _layout.width / working.width);
    return Rect.fromLTWH(
      0,
      0,
      working.width,
      math.min(working.height, _layout.height / scale),
    );
  }

  /// Where the visible source is drawn: contain-fit inside the layout so the
  /// image keeps its aspect ratio and the leftover area stays backdrop black.
  Rect _fitDest() {
    final visible = _controller.visibleSource;
    if (visible.isEmpty || _layout.isEmpty) return Rect.zero;
    final scale = math.min(
      _layout.width / visible.width,
      _layout.height / visible.height,
    );
    final width = visible.width * scale;
    final height = visible.height * scale;
    return Rect.fromLTWH(
      (_layout.width - width) / 2,
      (_layout.height - height) / 2,
      width,
      height,
    );
  }

  /// The aspect ratio every framing keeps: the default view's own.
  ///
  /// The window is a contain-fit of the region on screen, so a region whose
  /// aspect drifts from the framing's is letterboxed into a narrower strip. A
  /// zoom preserves the aspect it started with, which makes one drift permanent:
  /// the window could never widen again. Keeping every framing at this ratio is
  /// what lets a zoom widen the window back to the preview area's edges.
  double _framingAspect() {
    final framing = _defaultView();
    if (framing.isEmpty || framing.height <= 0) return 0;
    return framing.width / framing.height;
  }

  Rect _clamp(Rect rect) {
    final working = _workingSize;
    final framing = _defaultView();
    if (working.isEmpty || framing.isEmpty) return rect;
    // The framing is the zoom-out floor: a region wider or taller than it would
    // be drawn as a strip the gestures could never widen again, because they
    // preserve the aspect they start with. Bounding the width by the framing's
    // and deriving the height from the same aspect keeps every framing inside
    // the preview area's edges.
    final maxWidth = math.min(framing.width, working.width);
    final width = rect.width.clamp(1.0, maxWidth).toDouble();
    final height = width / (framing.width / framing.height);
    final maxLeft = math.max(0.0, working.width - width);
    final maxTop = math.max(0.0, working.height - height);
    return Rect.fromLTWH(
      rect.left.clamp(0.0, maxLeft),
      rect.top.clamp(0.0, maxTop),
      width,
      height,
    );
  }

  Offset _sourcePointAt(Offset viewPoint) {
    final visible = _controller.visibleSource;
    final dest = _fitDest();
    if (dest.isEmpty) return visible.topLeft;
    return Offset(
      visible.left + (viewPoint.dx - dest.left) / dest.width * visible.width,
      visible.top + (viewPoint.dy - dest.top) / dest.height * visible.height,
    );
  }

  void _syncViewport({Rect? visible, bool fit = false}) {
    if (_layout.isEmpty || _workingSize.isEmpty) return;
    final next = visible ?? (fit ? _defaultView() : _controller.visibleSource);
    if (next.isEmpty) return;
    _controller.updateViewport(visible: next);
  }
}

class _PreviewTag extends StatelessWidget {
  const _PreviewTag({required this.text, this.busy = false});

  final String text;
  final bool busy;

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        decoration: BoxDecoration(
          color: Colors
              .black // color-gate: ignore (tag over photo preview)
              .withValues(alpha: 0.55),
          borderRadius: BorderRadius.circular(7),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (busy) ...[
              const SizedBox(
                width: 9,
                height: 9,
                child: CircularProgressIndicator(strokeWidth: 1.4),
              ),
              const SizedBox(width: 6),
            ],
            Text(
              text,
              style: TextStyle(
                fontSize: 11,
                fontWeight: AppFontWeights.medium,
                color: Colors.white, // color-gate: ignore (tag over photo)
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _SplitPreviewPainter extends CustomPainter {
  _SplitPreviewPainter({
    required this.original,
    required this.originalScale,
    required this.result,
    required this.source,
    required this.destination,
    required this.divider,
  });

  final ui.Image original;

  /// [original]'s size over the working image's. [source] is in working pixels —
  /// the artifact's own space — and the reference is a different size, so the
  /// left half rescales the region before drawing it.
  final Size originalScale;

  /// The artifact, decoded at its own size. Null while 原图 is selected or the
  /// artifact for the current parameters is not ready: the compressed side then
  /// shows the original, which is exactly what an unencoded result is.
  final ui.Image? result;

  final Rect source;

  /// Aspect-correct contain-fit of [source] inside the canvas: the whole
  /// drawing, the split and the handle live inside this rect.
  final Rect destination;
  final double divider;

  /// The same region as [source], in the reference image's own pixels.
  Rect get _originalSource => Rect.fromLTRB(
    source.left * originalScale.width,
    source.top * originalScale.height,
    source.right * originalScale.width,
    source.bottom * originalScale.height,
  );

  @override
  void paint(Canvas canvas, Size size) {
    if (source.isEmpty || destination.isEmpty) return;
    final paint = Paint()..filterQuality = FilterQuality.medium;
    final split =
        (destination.width * divider).clamp(0.0, destination.width).toDouble() +
        destination.left;

    canvas.save();
    canvas.clipRect(destination);
    canvas.drawImageRect(original, _originalSource, destination, paint);
    canvas.restore();

    canvas.save();
    canvas.clipRect(
      Rect.fromLTRB(
        split,
        destination.top,
        destination.right,
        destination.bottom,
      ),
    );
    final artifact = result;
    if (artifact != null) {
      // The artifact covers the same region of the same image, so one `source`
      // rect describes both sides; its own pixels are the encoding's result.
      canvas.drawImageRect(artifact, source, destination, paint);
    } else {
      canvas.drawImageRect(original, _originalSource, destination, paint);
    }
    canvas.restore();

    canvas.drawRect(
      Rect.fromLTRB(
        split - 0.75,
        destination.top,
        split + 0.75,
        destination.bottom,
      ),
      Paint()
        ..color = Colors
            .white // color-gate: ignore (divider over photo preview)
            .withValues(alpha: 0.9),
    );
  }

  @override
  bool shouldRepaint(_SplitPreviewPainter old) {
    return old.original != original ||
        old.originalScale != originalScale ||
        old.result != result ||
        old.source != source ||
        old.destination != destination ||
        old.divider != divider;
  }
}
