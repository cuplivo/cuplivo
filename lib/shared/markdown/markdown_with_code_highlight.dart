import 'package:Cuplivo/features/intelligent_ui/host/ui_host_scope.dart';
import 'package:flutter/material.dart';
import 'package:markstream/markstream.dart';
import 'package:provider/provider.dart';
import 'package:Cuplivo/core/providers/settings_provider.dart';
import 'package:Cuplivo/shared/widgets/export_capture_scope.dart';

import 'citation_syntax.dart';
import 'highlight_adapter.dart';
import 'kelivo_markdown_extensions.dart';
import 'link_image_handlers.dart';
import 'markdown_theme_mapper.dart';
import 'math_adapter.dart';
import '../../utils/unicode_sanitizer.dart';

/// App fonts, settings and platform actions around the native Markdown renderer.
class MarkdownWithCodeHighlight extends StatefulWidget {
  const MarkdownWithCodeHighlight({
    super.key,
    required this.text,
    this.onCitationTap,
    this.citationIndexResolver,
    this.baseStyle,
    this.streaming = false,
    this.useBlockRendering = false,
    this.conversationId,
    this.highlightRanges = const [],
    this.highlightColor,
    this.uiHost,
    this.detailsStateKey,
    this.jobImageBuilder,
    this.documentStart = -1,
  });
  final String text;
  final UiHostBinding? uiHost;

  /// Stable message/text-block identity for folding across viewport recycling.
  final Object? detailsStateKey;
  final void Function(String id)? onCitationTap;
  final String? Function(String id)? citationIndexResolver;
  final TextStyle? baseStyle;
  final bool streaming;

  /// Retained as the app's static-document intent. Markstream always renders
  /// source blocks and keeps their identity through streaming completion.
  final bool useBlockRendering;
  final String? conversationId;
  final List<SourceSpan> highlightRanges;
  final Color? highlightColor;

  /// Draws this application's own block in place of an image the model only
  /// promised: a generated picture renders where its Markdown placeholder is,
  /// not at the end of the reply. Return null for an ordinary image.
  ///
  /// The last argument is the document this image belongs to, and the offset is
  /// the node's position in it. Both matter: a reply is rendered as several
  /// documents (one per block, or one per paragraph when the split option is on),
  /// and a node's offset only means something inside the document that produced
  /// it.
  final Widget? Function(
    BuildContext context,
    String destination,
    int offset,
    String document,
    int documentStart,
  )?
  jobImageBuilder;

  /// Where this document starts in the reply, in reply coordinates.
  final int documentStart;

  @override
  State<MarkdownWithCodeHighlight> createState() =>
      _MarkdownWithCodeHighlightState();
}

class _MarkdownWithCodeHighlightState extends State<MarkdownWithCodeHighlight> {
  late String _source;

  /// One builder for the life of this document.
  ///
  /// A fresh builder on every build made the markdown view rebuild its whole
  /// tree on each token, which threw away the identity streaming relies on
  /// (completed citation chips stay put because their subtrees stay identical).
  /// The callback is a method tear-off, so it compares equal across builds.
  late KelivoImageBuilder _imageBuilder;

  @override
  void initState() {
    super.initState();
    _source = UnicodeSanitizer.sanitize(widget.text);
    _imageBuilder = KelivoImageBuilder(
      jobImageBuilder: widget.jobImageBuilder,
      document: () => _source,
      documentStart: widget.documentStart,
    );
  }

  @override
  void didUpdateWidget(MarkdownWithCodeHighlight oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.text != widget.text) {
      _source = UnicodeSanitizer.sanitize(widget.text);
    }
    if (oldWidget.jobImageBuilder != widget.jobImageBuilder ||
        oldWidget.documentStart != widget.documentStart) {
      _imageBuilder = KelivoImageBuilder(
        jobImageBuilder: widget.jobImageBuilder,
        document: () => _source,
        documentStart: widget.documentStart,
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final settings = context.watch<SettingsProvider>();
    final exporting = ExportCaptureScope.of(context);
    final theme = mapMarkdownTheme(context, settings, widget.baseStyle);
    final view = MarkstreamView(
      source: _source,
      highlightRanges: widget.highlightRanges,
      highlightColor: widget.highlightColor,
      streaming: widget.streaming,
      options: markdownParserOptions(settings),
      theme: theme,
      extensions: markdownExtensionsFor(context),
      codeHighlighter: KelivoCodeHighlighter.forTheme(theme),
      mathRenderer: const KelivoMathRenderer(),
      imageBuilder: _imageBuilder,
      linkHandler: const KelivoLinkHandler(),
      codeOptions: markdownCodeOptions(settings),
      detailsExpansionState: markdownDetailsExpansionState,
      detailsStateKey: widget.detailsStateKey,
      labels: markdownLabels(context),
      exporting: exporting,
      cullToViewport: !exporting,
    );
    return MarkdownLinkScope(
      source: _source,
      conversationId: widget.conversationId,
      imageStorage: PageStorage.maybeOf(context),
      child: CitationScope(
        onTap: widget.onCitationTap,
        resolve: widget.citationIndexResolver,
        child: widget.uiHost == null
            ? view
            : UiHostScope(
                binding: widget.uiHost!,
                renderOwner: view,
                exporting: exporting,
                child: view,
              ),
      ),
    );
  }
}
