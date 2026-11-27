import 'package:flutter/material.dart';

import '../../../shared/markdown/markdown_with_code_highlight.dart';
import '../../../shared/widgets/export_capture_scope.dart';

/// The picture itself: rendered Markdown at the exact width the export
/// rasterises, with the export's own rendering rules already switched on.
///
/// The preview builds this same tree, so what the screen shows and what the
/// file contains are one render rather than two that usually agree.
class MarkdownExportDocument extends StatelessWidget {
  const MarkdownExportDocument({
    super.key,
    required this.source,
    required this.width,
    this.textScale = 1,
  });

  /// The sheet's padding, in logical pixels at [width].
  static const EdgeInsets sheetPadding = EdgeInsets.all(28);

  final String source;
  final double width;

  /// Multiplies the type size of every block, fenced code included. It rides
  /// the text scaler so headings, prose and monospace keep their proportions
  /// instead of only the body style moving.
  final double textScale;

  @override
  Widget build(BuildContext context) {
    final ambient = MediaQuery.textScalerOf(context).scale(1);
    return ExportCaptureScope(
      enabled: true,
      child: MediaQuery(
        data: MediaQuery.of(
          context,
        ).copyWith(textScaler: TextScaler.linear(ambient * textScale)),
        child: Container(
          width: width,
          color: Theme.of(context).colorScheme.surface,
          padding: sheetPadding,
          child: MarkdownWithCodeHighlight(
            text: source,
            baseStyle: const TextStyle(fontSize: 15.5, height: 1.55),
          ),
        ),
      ),
    );
  }
}
