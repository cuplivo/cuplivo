import 'package:flutter/material.dart';

import '../../../desktop/macos_window_drag_area.dart';
import '../../../icons/lucide_adapter.dart';
import '../../../l10n/app_localizations.dart';
import 'markdown_export_actions.dart';
import 'markdown_export_editor.dart';
import 'markdown_export_preview.dart';

/// The same tool with room to show both halves at once: source on the left,
/// the sheet it becomes on the right. Narrow windows stack them instead, and
/// either can give up its half so the sheet gets the whole window.
class MarkdownExportDesktopLayout extends StatelessWidget {
  const MarkdownExportDesktopLayout({
    super.key,
    required this.controller,
    required this.onImport,
    required this.onPaste,
    required this.onTextSize,
    required this.textSizeAnchor,
    required this.sourceCollapsed,
    required this.onToggleSource,
    required this.onExport,
    required this.busy,
    required this.documentWidth,
    required this.textScale,
  });

  final TextEditingController controller;
  final VoidCallback onImport;
  final VoidCallback onPaste;
  final VoidCallback onTextSize;

  /// Anchors the type-size menu to the button that opens it.
  final GlobalKey textSizeAnchor;

  /// Whether the source pane is out of the way, leaving the sheet alone.
  final bool sourceCollapsed;
  final VoidCallback onToggleSource;
  final VoidCallback? onExport;
  final bool busy;
  final double documentWidth;
  final double textScale;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;

    return Material(
      color: Theme.of(context).scaffoldBackgroundColor,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          MacosWindowDragArea(
            // Actions wrap instead of clipping, and the bar grows to fit them.
            // The title lives in the rail's tooltip: the two panes already say
            // what this screen is.
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 10, 12, 4),
              child: Align(
                alignment: Alignment.centerRight,
                child: Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  alignment: WrapAlignment.end,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    MarkdownExportActionChip(
                      icon: Lucide.FileUp,
                      label: l10n.markdownExportImport,
                      onTap: onImport,
                    ),
                    MarkdownExportActionChip(
                      icon: Lucide.Clipboard,
                      label: l10n.markdownExportPaste,
                      onTap: onPaste,
                    ),
                    MarkdownExportActionChip(
                      key: textSizeAnchor,
                      icon: Lucide.CaseSensitive,
                      label: l10n.markdownExportTextSize,
                      onTap: onTextSize,
                    ),
                    MarkdownExportActionChip(
                      icon: sourceCollapsed
                          ? Lucide.PanelLeftOpen
                          : Lucide.PanelLeftClose,
                      label: sourceCollapsed
                          ? l10n.markdownExportShowSource
                          : l10n.markdownExportHideSource,
                      onTap: onToggleSource,
                    ),
                    MarkdownExportButton(
                      label: l10n.markdownExportExportImage,
                      onTap: onExport,
                      busy: busy,
                    ),
                  ],
                ),
              ),
            ),
          ),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 20),
              child: Align(
                alignment: Alignment.topCenter,
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 1200),
                  child: LayoutBuilder(
                    builder: (context, constraints) {
                      final preview = MarkdownExportPreview(
                        source: controller.text,
                        documentWidth: documentWidth,
                        emptyHint: l10n.markdownExportPreviewEmpty,
                        textScale: textScale,
                      );
                      if (sourceCollapsed) return preview;
                      final editor = MarkdownExportEditor(
                        controller: controller,
                        hint: l10n.markdownExportHint,
                      );
                      if (constraints.maxWidth < 760) {
                        return Column(
                          children: [
                            Expanded(child: editor),
                            const SizedBox(height: 12),
                            Expanded(child: preview),
                          ],
                        );
                      }
                      return Row(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Expanded(child: editor),
                          const SizedBox(width: 16),
                          Expanded(child: preview),
                        ],
                      );
                    },
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
