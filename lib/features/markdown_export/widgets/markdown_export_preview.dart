import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../../shared/widgets/app_selection_area.dart';
import '../../chat/models/selection_session.dart';
import 'markdown_export_document.dart';

/// The sheet the export will produce, reflowed at the pane's width so the text
/// stays at its real size. [maxDocumentWidth] is the widest the sheet may get:
/// the export follows the same width, so preview and file break their lines in
/// the same places.
class MarkdownExportPreview extends StatefulWidget {
  const MarkdownExportPreview({
    super.key,
    required this.source,
    required this.maxDocumentWidth,
    required this.emptyHint,
    this.textScale = 1,
    this.onDocumentWidthChanged,
  });

  final String source;
  final double maxDocumentWidth;
  final String emptyHint;
  final double textScale;

  /// Reports the width the sheet was laid out at, so the export can rasterise
  /// the same one. Called from a post-frame callback, only when it changed.
  final ValueChanged<double>? onDocumentWidthChanged;

  /// How many times the sheet itself was built. The page debounces the source
  /// and ignores caret-only changes, so a burst of typing must move this once,
  /// and moving the caret must not move it at all. Counted in debug builds
  /// only: the hook exists for a test, not for a release.
  @visibleForTesting
  static int debugSheetBuilds = 0;

  @override
  State<MarkdownExportPreview> createState() => _MarkdownExportPreviewState();
}

class _MarkdownExportPreviewState extends State<MarkdownExportPreview> {
  double? _reportedWidth;

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
    final textScale = widget.textScale;
    final shadow = Theme.of(context).colorScheme.shadow;
    return LayoutBuilder(
      builder: (context, constraints) {
        final available =
            constraints.maxWidth.isFinite && constraints.maxWidth > 0
            ? constraints.maxWidth
            : widget.maxDocumentWidth;
        final width = math.min(available, widget.maxDocumentWidth);
        _reportWidth(width);
        return SingleChildScrollView(
          child: Align(
            alignment: Alignment.topCenter,
            child: AppSelectionArea(
              session: SelectionSession.document(source: source),
              child: SizedBox(
                width: width,
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
                    child: _buildSheet(source, width, textScale),
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  void _reportWidth(double width) {
    if (_reportedWidth == width) return;
    _reportedWidth = width;
    final report = widget.onDocumentWidthChanged;
    if (report == null) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) report(width);
    });
  }

  Widget _buildSheet(String source, double width, double textScale) {
    assert(() {
      MarkdownExportPreview.debugSheetBuilds++;
      return true;
    }());
    return MarkdownExportDocument(
      source: source,
      width: width,
      textScale: textScale,
      capture: false,
    );
  }
}
