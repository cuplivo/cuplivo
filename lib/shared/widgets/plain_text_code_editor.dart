import 'package:flutter/material.dart';
import 'package:re_editor/re_editor.dart';

TextLineBreak detectPlainTextLineBreak(String text) {
  final match = RegExp(r'\r\n|\r|\n').firstMatch(text)?.group(0);
  return switch (match) {
    '\r\n' => TextLineBreak.crlf,
    '\r' => TextLineBreak.cr,
    _ => TextLineBreak.lf,
  };
}

CodeLineEditingController createPlainTextCodeController(String text) {
  return CodeLineEditingController.fromText(
    text,
    CodeLineOptions(lineBreak: detectPlainTextLineBreak(text)),
  );
}

/// A plain multi-line editor for text that may be substantially larger than a
/// normal form field. Re-Editor avoids rebuilding Flutter's TextField render
/// tree for the whole document on every edit.
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
    this.minHeight,
    this.maxHeight,
    this.backgroundColor,
    this.textColor,
    this.selectionColor,
    this.cursorColor,
    this.border,
    this.borderRadius,
  });

  final CodeLineEditingController controller;
  final FocusNode? focusNode;
  final ValueChanged<CodeLineEditingValue>? onChanged;
  final String? hint;
  final bool autofocus;
  final bool readOnly;
  final EdgeInsetsGeometry padding;
  final double? minHeight;
  final double? maxHeight;
  final Color? backgroundColor;
  final Color? textColor;
  final Color? selectionColor;
  final Color? cursorColor;
  final Border? border;
  final BorderRadius? borderRadius;

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
      border: border,
      borderRadius: borderRadius,
      chunkAnalyzer: const NonCodeChunkAnalyzer(),
      style: CodeEditorStyle(
        backgroundColor: backgroundColor ?? Colors.transparent,
        textColor: textColor ?? cs.onSurface,
        hintTextColor: cs.onSurfaceVariant,
        selectionColor: selectionColor ?? cs.primary.withValues(alpha: 0.18),
        cursorColor: cursorColor ?? cs.primary,
      ),
    );

    return ConstrainedBox(
      constraints: BoxConstraints(
        minHeight: minHeight ?? 0,
        maxHeight: maxHeight ?? double.infinity,
      ),
      child: editor,
    );
  }
}
