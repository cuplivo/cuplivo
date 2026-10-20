import 'package:flutter/material.dart';
import 'package:markstream/markstream.dart';
import 'package:provider/provider.dart';
import 'package:Cuplivo/core/providers/settings_provider.dart';
import 'package:Cuplivo/l10n/app_localizations.dart';
import 'package:Cuplivo/utils/svg_preview_html.dart';
import 'package:Cuplivo/shared/widgets/plantuml_block.dart';
import 'package:Cuplivo/shared/widgets/export_capture_scope.dart';

import 'citation_syntax.dart';
import 'diagram_code_blocks.dart';
import 'highlight_adapter.dart';
import 'link_image_handlers.dart';
import 'markdown_actions.dart';

/// The syntaxes the parser needs to read Cuplivo's markdown.
///
/// Exported on their own because a consumer with no widget tree — the PDF export
/// parses inside a background isolate — still has to read the same grammar the
/// message does: a `[cite:id]` marker and a local picture path are syntax, not
/// rendering.
const kelivoInlineSyntaxes = <InlineSyntax>[
  CitationSyntax(),
  LocalImagePathSyntax(),
];

// Stable registration identity preserves the parser and completed prefix trees.
final kelivoMarkdownExtensions = MarkstreamExtensions(
  inlineSyntaxes: kelivoInlineSyntaxes,
  namedInlineBuilders: {'kelivo-citation': buildCitation},
  codeBlockBuilders: {
    'mermaid': _diagram,
    'svg': _diagram,
    'xml': _diagram,
    'html': _diagram,
    'htm': _diagram,
    'rawhtml': _diagram,
    'raw_html': _diagram,
    'plantuml': _plantUml,
  },
  actionButtonBuilder: markdownActionButton,
  codeExtraActions: markdownCodeActions,
  tableExtraActions: markdownTableActions,
  mobileTableToolbarBuilder: markdownMobileTableToolbar,
);

Widget _diagram(
  BuildContext context,
  CodeBlockNode node,
  MarkstreamRenderContext rendering,
) {
  final language = node.info.trim().split(RegExp(r'\s+')).first.toLowerCase();
  if (language == 'mermaid' || isSvgCodeBlock(language, node.code)) {
    return KelivoDiagramBlock(
      node: node,
      theme: rendering.theme,
      streaming: rendering.streaming && !node.closed,
      isSvg: language != 'mermaid',
    );
  }
  // HTML snippets and complete HTML documents use the same code chrome and
  // explicit preview action. Calling the built-in widget avoids redispatch.
  return MarkstreamCodeBlock(
    node: node,
    theme: rendering.theme,
    extensions: kelivoMarkdownExtensions,
    options: markdownCodeOptions(context.watch<SettingsProvider>()),
    labels: markdownLabels(context),
    highlighter: const KelivoCodeHighlighter(),
    streaming: rendering.streaming,
    exporting: ExportCaptureScope.of(context),
  );
}

final _expansionState = CodeExpansionState();
CodeBlockOptions markdownCodeOptions(SettingsProvider settings) =>
    CodeBlockOptions(
      autoCollapse: settings.autoCollapseCodeBlock,
      collapsedLines: settings.autoCollapseCodeBlockLines.clamp(1, 999999),
      mobileWrap: settings.mobileCodeBlockWrap,
      expansionState: _expansionState,
    );

// Keep the localized row-label callback stable for the same localization object.
final _labels = Expando<MarkstreamLabels>();
MarkstreamLabels markdownLabels(BuildContext context) {
  final l10n = AppLocalizations.of(context)!;
  return _labels[l10n] ??= MarkstreamLabels(
    copyCode: l10n.shareProviderSheetCopyButton,
    copyMarkdown: l10n.markdownCopyMarkdownAction,
    copyCsv: l10n.markdownCopyCsvAction,
    expand: l10n.codeBlockExpandButton,
    collapse: l10n.codeBlockCollapseButton,
    unnamedCode: l10n.markdownCodeLabel,
    details: l10n.markdownDetailsLabel,
    note: l10n.markdownNoteLabel,
    tip: l10n.markdownTipLabel,
    important: l10n.markdownImportantLabel,
    warning: l10n.markdownWarningLabel,
    caution: l10n.markdownCautionLabel,
    danger: l10n.markdownDangerLabel,
    moreRows: l10n.markdownMoreRows,
  );
}

Widget _plantUml(
  BuildContext context,
  CodeBlockNode node,
  MarkstreamRenderContext rendering,
) {
  final theme = rendering.theme;
  final streaming = rendering.streaming;
  return PlantUMLBlock(
    code: node.code,
    codeBuilder: (_) => MarkstreamCodeContent(
      node: node,
      theme: theme,
      streaming: streaming,
      highlighter: const KelivoCodeHighlighter(),
      wrap: false,
    ),
  );
}

/// The title each kind of callout is drawn with, by the name the grammar gives it.
///
/// One map for both readings of a callout — the card the message draws and the
/// band the PDF page draws — because the kind of a callout is content: a reader
/// who sees `> [!WARNING]` set as plain prose cannot tell it from a remark.
Map<String, String> markdownAlertLabels(AppLocalizations l10n) =>
    <String, String>{
      'note': l10n.markdownNoteLabel,
      'tip': l10n.markdownTipLabel,
      'important': l10n.markdownImportantLabel,
      'warning': l10n.markdownWarningLabel,
      'caution': l10n.markdownCautionLabel,
      'danger': l10n.markdownDangerLabel,
    };

ParserOptions markdownParserOptions(SettingsProvider settings) =>
    markdownParserOptionsFor(
      enableMathRendering: settings.enableMathRendering,
      enableDollarLatex: settings.enableDollarLatex,
    );

/// What the two settings mean to the grammar.
///
/// A consumer that has no settings provider — the export runs in an isolate and
/// carries the two answers as booleans — still has to parse the same grammar the
/// screen does, so the translation lives here once rather than being restated at
/// the second call site.
ParserOptions markdownParserOptionsFor({
  required bool enableMathRendering,
  required bool enableDollarLatex,
}) => switch ((enableMathRendering, enableDollarLatex)) {
  (true, true) => const ParserOptions(),
  (true, false) => const ParserOptions(dollarInlineMath: false),
  (false, _) => const ParserOptions(inlineMath: false, mathBlocks: false),
};
