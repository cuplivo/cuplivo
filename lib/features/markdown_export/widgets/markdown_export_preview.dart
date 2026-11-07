import 'dart:async';

import 'package:flutter/material.dart';

import '../../../shared/widgets/diagram_exporter.dart';
import 'markdown_export_document.dart';

/// The sheet the export will produce, drawn at the export's own width. A
/// narrower screen scales the whole sheet down instead of reflowing it, so the
/// preview never promises a layout the file will not have.
class MarkdownExportPreview extends StatefulWidget {
  const MarkdownExportPreview({
    super.key,
    required this.source,
    required this.documentWidth,
    required this.emptyHint,
    this.textScale = 1,
  });

  final String source;
  final double documentWidth;
  final String emptyHint;
  final double textScale;

  /// How many times the sheet itself was built. The page debounces the source
  /// and ignores caret-only changes, so a burst of typing must move this once,
  /// and moving the caret must not move it at all.
  @visibleForTesting
  static int debugSheetBuilds = 0;

  @override
  State<MarkdownExportPreview> createState() => _MarkdownExportPreviewState();
}

class _MarkdownExportPreviewState extends State<MarkdownExportPreview> {
  /// The source whose diagrams were last warmed, so a rebuild that brought no
  /// new text does not render them a second time.
  String? _warmedSource;

  @override
  void initState() {
    super.initState();
    // Warming reads the theme and needs an Overlay, so it cannot run while the
    // first frame is being built.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _warmDiagrams();
    });
  }

  @override
  void didUpdateWidget(covariant MarkdownExportPreview oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.source != widget.source) _warmDiagrams();
  }

  /// The sheet is drawn in the export's own capture mode, where a diagram is
  /// painted from the bitmap cache and falls back to its source when that cache
  /// is cold. The export warms the cache before it captures, so the preview has
  /// to warm it the same way — otherwise the screen shows source for a picture
  /// the file renders as a diagram.
  void _warmDiagrams() {
    final source = widget.source;
    if (_warmedSource == source) return;
    _warmedSource = source;
    final codes = extractDiagramCodes(source);
    if (codes.isEmpty) return;
    unawaited(_renderDiagrams(codes));
  }

  Future<void> _renderDiagrams(List<DiagramCode> codes) async {
    try {
      await preRenderDiagramCodesForExport(context, codes);
    } catch (_) {
      // The export degrades the same way; leaving the source on screen keeps
      // the two agreeing.
      return;
    }
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    if (widget.source.trim().isEmpty) {
      return Center(
        child: Text(
          widget.emptyHint,
          textAlign: TextAlign.center,
          style: TextStyle(
            fontSize: 13.5,
            color: Theme.of(
              context,
            ).colorScheme.onSurface.withValues(alpha: .55),
          ),
        ),
      );
    }
    final source = widget.source;
    final documentWidth = widget.documentWidth;
    final textScale = widget.textScale;
    final shadow = Theme.of(context).colorScheme.shadow;
    return LayoutBuilder(
      builder: (context, constraints) {
        final available =
            constraints.maxWidth.isFinite && constraints.maxWidth > 0
            ? constraints.maxWidth
            : documentWidth;
        final scale = (available / documentWidth).clamp(0.2, 1.0);
        return SingleChildScrollView(
          child: Align(
            alignment: Alignment.topCenter,
            child: SizedBox(
              width: documentWidth * scale,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(12),
                  boxShadow: [
                    BoxShadow(
                      color: shadow.withValues(alpha: .12),
                      blurRadius: 18,
                      offset: const Offset(0, 8),
                    ),
                  ],
                ),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(12),
                  child: FittedBox(
                    fit: BoxFit.fitWidth,
                    alignment: Alignment.topCenter,
                    child: _buildSheet(source, documentWidth, textScale),
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _buildSheet(String source, double documentWidth, double textScale) {
    MarkdownExportPreview.debugSheetBuilds++;
    return MarkdownExportDocument(
      source: source,
      width: documentWidth,
      textScale: textScale,
    );
  }
}
