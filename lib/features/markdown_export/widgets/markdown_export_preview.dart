import 'dart:async';

import 'package:flutter/material.dart';

import '../../../shared/widgets/diagram_exporter.dart';
import '../../../shared/widgets/mermaid_image_cache.dart';
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
  /// and moving the caret must not move it at all. Counted in debug builds
  /// only: the hook exists for a test, not for a release.
  @visibleForTesting
  static int debugSheetBuilds = 0;

  @override
  State<MarkdownExportPreview> createState() => _MarkdownExportPreviewState();
}

class _MarkdownExportPreviewState extends State<MarkdownExportPreview> {
  bool _warming = false;

  /// Bumped once the cache is usable, so the sheet is rebuilt from scratch and
  /// its diagram reads the bitmap instead of the source it drew first.
  int _sheetEpoch = 0;

  /// The diagram codes of the current text, kept beside the text they came
  /// from: a theme change rebuilds this widget without touching the text, and
  /// re-parsing it then would be work for nothing.
  String? _codesFor;
  List<DiagramCode> _codes = const [];

  @override
  Widget build(BuildContext context) {
    // Here rather than in initState: a warm that failed has to be retried by a
    // later build, and build is the only place that sees one.
    _warmDiagrams();
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

  /// The sheet is drawn in the export's own capture mode, where a diagram is
  /// painted from the bitmap cache and falls back to its source when that cache
  /// is cold. The export warms the cache before it captures, so the preview has
  /// to warm it the same way — otherwise the screen shows source for a picture
  /// the file renders as a diagram.
  ///
  /// "Already warm" is answered by the cache, not by remembering which text was
  /// warmed: the cache is keyed on the diagram *and the palette*, so a theme
  /// change makes every entry cold again without the text changing at all.
  void _warmDiagrams() {
    if (_warming || widget.source.trim().isEmpty) return;
    final codes = _diagramCodes(widget.source);
    if (codes.isEmpty || _codesCached(codes)) return;
    final source = widget.source;
    // The render inserts an overlay entry, which cannot happen while a frame is
    // being built.
    _warming = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (widget.source != source) {
        // The text moved on; the next build warms that one instead.
        _warming = false;
        return;
      }
      unawaited(_renderDiagrams(codes));
    });
  }

  List<DiagramCode> _diagramCodes(String source) {
    if (_codesFor != source) {
      _codesFor = source;
      _codes = extractDiagramCodes(source);
    }
    return _codes;
  }

  Future<void> _renderDiagrams(List<DiagramCode> codes) async {
    try {
      await preRenderDiagramCodesForExport(context, codes);
    } catch (_) {
      // Whether it worked is decided by the cache check below, which also
      // covers the ways the helper gives up without saying so.
    } finally {
      _warming = false;
    }
    // Nothing landed: no rebuild, and the next build asks the cache again, so
    // the export and the screen cannot stay disagreeing for good.
    if (!mounted || !_codesCached(codes)) return;
    setState(() => _sheetEpoch++);
  }

  bool _codesCached(List<DiagramCode> codes) {
    final scheme = Theme.of(context).colorScheme;
    final themeVars = buildThemeVarsFromColorScheme(scheme);
    final isDark = scheme.brightness == Brightness.dark;
    return codes.every(
      (code) =>
          MermaidImageCache.get(
            diagramImageCacheKey(
              code.code,
              isDark,
              themeVars,
              isSvg: code.isSvg,
            ),
          ) !=
          null,
    );
  }

  Widget _buildSheet(String source, double documentWidth, double textScale) {
    assert(() {
      MarkdownExportPreview.debugSheetBuilds++;
      return true;
    }());
    return MarkdownExportDocument(
      key: ValueKey(_sheetEpoch),
      source: source,
      width: documentWidth,
      textScale: textScale,
    );
  }
}
