import 'package:Cuplivo/theme/app_semantic_colors.dart';
import 'package:flutter/material.dart';
import 'package:re_editor/re_editor.dart';

// Re-exported so that the `part` files of `assistant_settings_edit_page.dart`
// depend on this shared widget instead of importing `re_editor` directly.
export 'package:re_editor/re_editor.dart'
    show CodeLineEditingController, CodeLineSelection;

final RegExp _lineBreakPattern = RegExp(r'\r\n|\r|\n');

TextLineBreak _detectPlainTextLineBreak(String text) {
  final match = _lineBreakPattern.firstMatch(text)?.group(0);
  return switch (match) {
    '\r\n' => TextLineBreak.crlf,
    '\r' => TextLineBreak.cr,
    _ => TextLineBreak.lf,
  };
}

/// Creates a [CodeLineEditingController] whose line break matches the text's
/// first line break, so `controller.text` round-trips byte-exact for CRLF and
/// CR documents.
///
/// [text] is assumed to have homogeneous line endings. For mixed documents the
/// first line break found wins, matching the behaviour of the fallback split.
CodeLineEditingController createPlainTextCodeController(String text) {
  return CodeLineEditingController.fromText(
    text,
    CodeLineOptions(lineBreak: _detectPlainTextLineBreak(text)),
  );
}

/// A plain multi-line editor for text that may be substantially larger than a
/// normal form field. Re-Editor keeps only visible chunks in the render tree,
/// so editing large prompts and world-book content stays cheap.
class PlainTextCodeEditor extends StatelessWidget {
  const PlainTextCodeEditor({
    super.key,
    required this.controller,
    this.focusNode,
    this.onChanged,
    this.hint,
    this.autofocus = false,
    this.readOnly = false,
    this.padding = const EdgeInsets.all(12),
    this.maxHeight,
    this.backgroundColor,
    this.borderRadius,
  });

  final CodeLineEditingController controller;
  final FocusNode? focusNode;
  final ValueChanged<CodeLineEditingValue>? onChanged;
  final String? hint;
  final bool autofocus;
  final bool readOnly;
  final EdgeInsetsGeometry padding;
  final double? maxHeight;
  final Color? backgroundColor;
  final BorderRadius? borderRadius;

  static const NonCodeChunkAnalyzer _chunkAnalyzer = NonCodeChunkAnalyzer();

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final editor = CodeEditor(
      controller: controller,
      focusNode: focusNode,
      autofocus: autofocus,
      readOnly: readOnly,
      wordWrap: true,
      hint: hint,
      padding: padding,
      onChanged: onChanged,
      borderRadius: borderRadius,
      chunkAnalyzer: _chunkAnalyzer,
      style: CodeEditorStyle(
        backgroundColor: backgroundColor ?? context.appColors.surfaceFill,
        textColor: cs.onSurface,
        hintTextColor: cs.onSurfaceVariant,
        selectionColor: cs.primary.withValues(alpha: 0.18),
        cursorColor: cs.primary,
      ),
    );

    return ConstrainedBox(
      constraints: BoxConstraints(maxHeight: maxHeight ?? double.infinity),
      child: editor,
    );
  }
}
