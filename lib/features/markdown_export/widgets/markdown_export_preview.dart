import 'package:flutter/material.dart';

import 'markdown_export_document.dart';

/// The sheet the export will produce, drawn at the export's own width. A
/// narrower screen scales the whole sheet down instead of reflowing it, so the
/// preview never promises a layout the file will not have.
class MarkdownExportPreview extends StatelessWidget {
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

  @override
  Widget build(BuildContext context) {
    if (source.trim().isEmpty) {
      return Center(
        child: Text(
          emptyHint,
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
                    child: MarkdownExportDocument(
                      source: source,
                      width: documentWidth,
                      textScale: textScale,
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}
