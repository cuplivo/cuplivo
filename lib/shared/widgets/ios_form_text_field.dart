import 'package:flutter/material.dart';
import 'package:Cuplivo/theme/app_font_weights.dart';
import 'package:Cuplivo/theme/app_semantic_colors.dart';

class IosFormTextField extends StatelessWidget {
  const IosFormTextField({
    super.key,
    required this.label,
    required this.controller,
    this.hintText,
    this.maxLines = 1,
    this.minLines,
    this.inlineLabel,
    this.outerPadding,
    this.fieldWidth,
    this.keyboardType,
    this.textAlign,
    this.autofocus = false,
    this.enabled = true,
    this.onChanged,
    this.selectAllOnFocus = false,
    this.cursorToEndOnFocus = false,
    this.cursorToEndOnTap = false,
    this.textInputAction,
    this.textCapitalization = TextCapitalization.none,
    this.maxLength,
  });

  final String label;
  final TextEditingController controller;
  final String? hintText;
  final int maxLines;
  final int? minLines;
  final bool? inlineLabel;
  final EdgeInsetsGeometry? outerPadding;
  final double? fieldWidth;
  final TextInputType? keyboardType;
  final TextAlign? textAlign;
  final bool autofocus;
  final bool enabled;
  final ValueChanged<String>? onChanged;
  final bool selectAllOnFocus;
  final bool cursorToEndOnFocus;
  final bool cursorToEndOnTap;
  final TextInputAction? textInputAction;
  final TextCapitalization textCapitalization;
  final int? maxLength;

  bool get _useInlineLabel => inlineLabel ?? (maxLines == 1);

  TextAlign _defaultTextAlign() {
    final kt = keyboardType;
    if (kt == TextInputType.number || kt == TextInputType.numberWithOptions()) {
      return TextAlign.end;
    }
    return TextAlign.start;
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final fieldBg = context.appColors.surfaceFill;
    final labelColor = cs.onSurface.withValues(alpha: 0.85);
    final valueColor = cs.onSurface.withValues(alpha: enabled ? 0.92 : 0.55);
    final hintColor = cs.onSurface.withValues(alpha: isDark ? 0.42 : 0.46);
    final resolvedOuterPadding =
        outerPadding ??
        const EdgeInsets.symmetric(horizontal: 12, vertical: 10);
    final fieldHorizontalPadding = (fieldWidth != null && fieldWidth! <= 60)
        ? 10.0
        : 12.0;

    void selectAll() {
      final len = controller.text.length;
      controller.selection = TextSelection(baseOffset: 0, extentOffset: len);
    }

    void moveCursorToEnd() {
      final len = controller.text.length;
      controller.selection = TextSelection.collapsed(offset: len);
    }

    Widget field = TextField(
      controller: controller,
      maxLines: maxLines,
      minLines: minLines,
      autofocus: autofocus,
      enabled: enabled,
      keyboardType: keyboardType,
      maxLength: maxLength,
      textAlign: textAlign ?? _defaultTextAlign(),
      textAlignVertical: maxLines == 1
          ? TextAlignVertical.center
          : TextAlignVertical.top,
      textInputAction: textInputAction,
      textCapitalization: textCapitalization,
      onChanged: onChanged,
      onTap: cursorToEndOnTap
          ? () {
              WidgetsBinding.instance.addPostFrameCallback((_) {
                try {
                  moveCursorToEnd();
                } catch (_) {}
              });
            }
          : null,
      style: TextStyle(
        fontSize: 15,
        fontWeight: AppFontWeights.medium,
        color: valueColor,
        height: maxLines > 1 ? 1.25 : 1.15,
      ),
      decoration: InputDecoration(
        isDense: true,
        isCollapsed: true,
        hintText: hintText,
        counterText: '',
        hintStyle: TextStyle(
          fontSize: 15,
          fontWeight: AppFontWeights.medium,
          color: hintColor,
        ),
        border: InputBorder.none,
        contentPadding: EdgeInsets.zero,
      ),
    );

    if (selectAllOnFocus || cursorToEndOnFocus) {
      field = Focus(
        onFocusChange: (hasFocus) {
          if (!hasFocus) return;
          WidgetsBinding.instance.addPostFrameCallback((_) {
            try {
              if (selectAllOnFocus) {
                selectAll();
              } else if (cursorToEndOnFocus) {
                moveCursorToEnd();
              }
            } catch (_) {}
          });
        },
        child: field,
      );
    }

    if (_useInlineLabel) {
      final labelWidget = Text(
        label,
        style: TextStyle(
          fontSize: 15,
          fontWeight: AppFontWeights.medium,
          // Match the field text's line height (height: 1.15 below); otherwise
          // the label's taller natural line box centers its glyphs a few px
          // higher than the input text and the row looks misaligned.
          height: 1.15,
          color: labelColor,
        ),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      );
      // heightFactor 1.0 forces the Align to shrink-wrap its child instead of
      // expanding to fill bounded loose height (e.g. inside AlertDialog
      // content), which used to stretch the whole dialog to full screen height.
      final fieldWidget = ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 40),
        child: Align(
          alignment: Alignment.center,
          heightFactor: 1.0,
          child: Container(
            decoration: BoxDecoration(
              color: enabled ? fieldBg : fieldBg.withValues(alpha: 0.55),
              borderRadius: BorderRadius.circular(10),
            ),
            padding: EdgeInsets.symmetric(
              horizontal: fieldHorizontalPadding,
              vertical: 9,
            ),
            child: field,
          ),
        ),
      );
      return Padding(
        padding: resolvedOuterPadding,
        child: Row(
          children: [
            if (fieldWidth == null)
              Expanded(flex: 3, child: labelWidget)
            else
              Expanded(child: labelWidget),
            const SizedBox(width: 8),
            if (fieldWidth == null)
              Expanded(flex: 8, child: fieldWidget)
            else
              SizedBox(width: fieldWidth, child: fieldWidget),
          ],
        ),
      );
    }

    return Padding(
      padding: resolvedOuterPadding,
      child: Column(
        // Must shrink to content: a max-height Column would otherwise fill any
        // bounded loose height (e.g. inside AlertDialog content).
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: TextStyle(
              fontSize: 13,
              fontWeight: AppFontWeights.semibold,
              color: labelColor,
            ),
          ),
          const SizedBox(height: 6),
          // Same bounded-height expansion guard as the inline branch.
          ConstrainedBox(
            constraints: maxLines == 1
                ? const BoxConstraints(minHeight: 40)
                : const BoxConstraints(),
            child: Align(
              alignment: maxLines == 1
                  ? Alignment.centerLeft
                  : Alignment.topLeft,
              heightFactor: 1.0,
              child: Container(
                decoration: BoxDecoration(
                  color: enabled ? fieldBg : fieldBg.withValues(alpha: 0.55),
                  borderRadius: BorderRadius.circular(12),
                ),
                padding: EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: maxLines > 1 ? 12 : 9,
                ),
                child: field,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
