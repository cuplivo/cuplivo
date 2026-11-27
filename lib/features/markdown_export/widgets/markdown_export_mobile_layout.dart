import 'package:flutter/material.dart';

import '../../../icons/lucide_adapter.dart';
import '../../../l10n/app_localizations.dart';
import '../../../shared/widgets/segmented_tabs.dart';
import '../models/markdown_export_mode.dart';
import 'markdown_export_actions.dart';
import 'markdown_export_editor.dart';
import 'markdown_export_preview.dart';

/// One screen, two states: the Markdown being written and the sheet it becomes.
/// A phone cannot show both at once without halving each, so the tabs are the
/// switch instead of a split.
class MarkdownExportMobileLayout extends StatelessWidget {
  const MarkdownExportMobileLayout({
    super.key,
    required this.controller,
    required this.previewSource,
    required this.mode,
    required this.onModeChanged,
    required this.onImport,
    required this.onPaste,
    required this.onExport,
    required this.busy,
    required this.documentWidth,
    required this.textScale,
  });

  final TextEditingController controller;

  /// What the preview draws. It trails [controller] by the page's settle delay,
  /// so typing does not re-render the sheet on every keystroke.
  final String previewSource;
  final MarkdownExportMode mode;
  final ValueChanged<MarkdownExportMode> onModeChanged;
  final VoidCallback onImport;
  final VoidCallback onPaste;
  final VoidCallback onExport;
  final bool busy;
  final double documentWidth;
  final double textScale;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Padding(
      padding: const EdgeInsets.only(top: 4),
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 10),
            child: SegmentedTabs(
              tabs: [
                SegmentedTab(
                  label: l10n.markdownExportEditTab,
                  icon: Lucide.SquarePen,
                ),
                SegmentedTab(
                  label: l10n.markdownExportPreviewTab,
                  icon: Lucide.Eye,
                ),
              ],
              index: mode.index,
              onChanged: (index) =>
                  onModeChanged(MarkdownExportMode.values[index]),
            ),
          ),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 10),
              child: mode == MarkdownExportMode.edit
                  ? MarkdownExportEditor(
                      controller: controller,
                      hint: l10n.markdownExportHint,
                    )
                  : MarkdownExportPreview(
                      source: previewSource,
                      documentWidth: documentWidth,
                      emptyHint: l10n.markdownExportPreviewEmpty,
                      textScale: textScale,
                    ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
            child: Row(
              children: [
                MarkdownExportActionChip(
                  icon: Lucide.FileUp,
                  label: l10n.markdownExportImport,
                  onTap: onImport,
                ),
                const SizedBox(width: 8),
                MarkdownExportActionChip(
                  icon: Lucide.Clipboard,
                  label: l10n.markdownExportPaste,
                  onTap: onPaste,
                ),
                const Spacer(),
                MarkdownExportSubmitButton(
                  controller: controller,
                  onTap: onExport,
                  busy: busy,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
