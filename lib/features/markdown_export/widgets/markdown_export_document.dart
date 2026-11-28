import 'package:flutter/material.dart';

import '../../../shared/markdown/markdown_with_code_highlight.dart';
import '../../../shared/widgets/export_capture_scope.dart';

/// The picture itself: rendered Markdown at the width it will be rasterised
/// at, with the export's own rules already switched on.
///
/// The preview builds this same tree at the width of its pane, so what the
/// screen shows reflows exactly as the file does — code stays expanded, tables
/// keep every row, nothing is virtualised. [capture] only separates the two
/// roles: the sheet being rasterised may not start work, while the preview
/// must render its diagrams or it would show their source instead.
class MarkdownExportDocument extends StatelessWidget {
  const MarkdownExportDocument({
    super.key,
    required this.source,
    required this.width,
    required this.capture,
    this.textScale = 1,
  });

  /// The sheet's padding, in logical pixels at [width].
  static const EdgeInsets sheetPadding = EdgeInsets.all(28);

  final String source;
  final double width;

  /// Whether this tree is the one being rasterised. The export warms diagrams
  /// before it captures; the preview renders them itself and shows the same
  /// loading and failure states a chat message does.
  final bool capture;

  /// Multiplies the type size of every block, fenced code included. It rides
  /// the text scaler so headings, prose and monospace keep their proportions
  /// instead of only the body style moving.
  final double textScale;

  @override
  Widget build(BuildContext context) {
    final ambient = MediaQuery.textScalerOf(context).scale(1);
    return ExportCaptureScope(
      enabled: true,
      renderDiagrams: !capture,
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
