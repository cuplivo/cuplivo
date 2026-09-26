import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../../../../icons/lucide_adapter.dart';
import '../../../../l10n/app_localizations.dart';
import '../../../../theme/app_font_weights.dart';
import 'compress_editor_controller.dart';

/// The editor body: one image, one draggable divider. The left side shows the
/// original pixels, the right side the current parameters' result for the
/// region on screen, so the two halves can be compared at 1:1.
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
  Offset _gestureSourcePoint = Offset.zero;

  CompressEditorController get _controller => widget.controller;

  Size get _previewSize => Size(
    _controller.previewWidth.toDouble(),
    _controller.previewHeight.toDouble(),
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
                      tile: _controller.tile,
                      tileSource: _controller.tileSource,
                      source: _controller.visibleSource,
                      divider: _controller.divider,
                    ),
                  ),
                Positioned(
                  left: 10,
                  top: 10,
                  child: _PreviewTag(
                    text: AppLocalizations.of(
                      context,
                    )!.compressEditorOriginalSide,
                  ),
                ),
                if (widget.formatLabel != null)
                  Positioned(
                    right: 10,
                    top: 10,
                    child: _PreviewTag(
                      text: widget.formatLabel!,
                      busy: _controller.tileBusy,
                    ),
                  ),
                _dividerHandle(),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _dividerHandle() {
    if (_layout.isEmpty) return const SizedBox.shrink();
    final x = _controller.divider * _layout.width;
    return Positioned(
      left: x - 14,
      top: 0,
      bottom: 0,
      width: 28,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onHorizontalDragUpdate: (details) => _controller.setDivider(
          _controller.divider + details.delta.dx / _layout.width,
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
    _gestureSourcePoint = _sourcePointAt(details.localFocalPoint);
  }

  void _onScaleUpdate(ScaleUpdateDetails details) {
    final start = _gestureStartVisible;
    if (start.isEmpty || _layout.isEmpty) return;
    final factor = details.scale <= 0 ? 1.0 : details.scale;
    final width = start.width / factor;
    final height = start.height / factor;
    final rel = Offset(
      details.localFocalPoint.dx / _layout.width,
      details.localFocalPoint.dy / _layout.height,
    );
    final next = Rect.fromLTWH(
      _gestureSourcePoint.dx - rel.dx * width,
      _gestureSourcePoint.dy - rel.dy * height,
      width,
      height,
    );
    _syncViewport(visible: _clamp(next));
  }

  void _toggleZoom(Offset viewPoint) {
    if (_layout.isEmpty || _previewSize.isEmpty) return;
    final current = _controller.visibleSource;
    final isOneToOne = current.width <= _layout.width * 1.01;
    if (isOneToOne) {
      _syncViewport(visible: _fitRect());
      return;
    }
    final point = _sourcePointAt(viewPoint);
    final next = Rect.fromLTWH(
      point.dx - _layout.width / 2,
      point.dy - _layout.height / 2,
      _layout.width,
      _layout.height,
    );
    _syncViewport(visible: _clamp(next));
  }

  Rect _fitRect() {
    final preview = _previewSize;
    if (preview.isEmpty || _layout.isEmpty) return Rect.zero;
    final scale = math.min(
      _layout.width / preview.width,
      _layout.height / preview.height,
    );
    final width = preview.width * scale;
    final height = preview.height * scale;
    return Rect.fromLTWH(
      (preview.width - width) / 2,
      (preview.height - height) / 2,
      width,
      height,
    );
  }

  Rect _clamp(Rect rect) {
    final preview = _previewSize;
    if (preview.isEmpty) return rect;
    final width = rect.width.clamp(1.0, preview.width);
    final height = rect.height.clamp(1.0, preview.height);
    final maxLeft = math.max(0.0, preview.width - width);
    final maxTop = math.max(0.0, preview.height - height);
    return Rect.fromLTWH(
      rect.left.clamp(0.0, maxLeft),
      rect.top.clamp(0.0, maxTop),
      width,
      height,
    );
  }

  Offset _sourcePointAt(Offset viewPoint) {
    final visible = _controller.visibleSource;
    if (_layout.isEmpty) return visible.topLeft;
    return Offset(
      visible.left + viewPoint.dx / _layout.width * visible.width,
      visible.top + viewPoint.dy / _layout.height * visible.height,
    );
  }

  void _syncViewport({Rect? visible, bool fit = false}) {
    if (_layout.isEmpty || _previewSize.isEmpty) return;
    final next = visible ?? (fit ? _fitRect() : _controller.visibleSource);
    if (next.isEmpty) return;
    _controller.updateViewport(visible: next, viewport: _layout);
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
    required this.tile,
    required this.tileSource,
    required this.source,
    required this.divider,
  });

  final ui.Image original;
  final ui.Image? tile;
  final Rect? tileSource;
  final Rect source;
  final double divider;

  @override
  void paint(Canvas canvas, Size size) {
    if (source.isEmpty) return;
    final paint = Paint()..filterQuality = FilterQuality.medium;
    final destination = Offset.zero & size;
    final split = (size.width * divider).clamp(0.0, size.width);

    canvas.save();
    canvas.clipRect(Rect.fromLTRB(0, 0, split, size.height));
    canvas.drawImageRect(original, source, destination, paint);
    canvas.restore();

    canvas.save();
    canvas.clipRect(Rect.fromLTRB(split, 0, size.width, size.height));
    final usableTile = tile;
    // Only paint a tile that belongs to the region currently on screen: a
    // stale region would silently misrepresent the result.
    if (usableTile != null && tileSource == source) {
      canvas.drawImageRect(
        usableTile,
        Offset.zero &
            Size(usableTile.width.toDouble(), usableTile.height.toDouble()),
        destination,
        paint,
      );
    } else {
      canvas.drawImageRect(original, source, destination, paint);
    }
    canvas.restore();

    canvas.drawRect(
      Rect.fromLTRB(split - 0.75, 0, split + 0.75, size.height),
      Paint()
        ..color = Colors
            .white // color-gate: ignore (divider over photo preview)
            .withValues(alpha: 0.9),
    );
  }

  @override
  bool shouldRepaint(_SplitPreviewPainter old) {
    return old.original != original ||
        old.tile != tile ||
        old.tileSource != tileSource ||
        old.source != source ||
        old.divider != divider;
  }
}
