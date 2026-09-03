import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../theme/app_font_weights.dart';
import '../../theme/app_semantic_colors.dart';

/// Compact numeric settings field shared by the mobile auto-retry page and
/// the desktop auto-retry pane.
///
/// Value commits when the field loses focus (typed values are re-clamped and
/// shown back), on editing-complete and on submit.
class IosNumberField extends StatelessWidget {
  const IosNumberField({
    super.key,
    required this.controller,
    required this.focusNode,
    this.decimal = false,
    this.labelWidth = 120,
    this.onCommit,
  });

  final TextEditingController controller;
  final FocusNode focusNode;
  final bool decimal;
  final double labelWidth;
  final void Function()? onCommit;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      constraints: const BoxConstraints(minWidth: 140, maxWidth: 220),
      decoration: BoxDecoration(
        color: context.appColors.surfaceFill,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(
          color: cs.outlineVariant.withValues(alpha: 0.12),
          width: 0.6,
        ),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      child: TextField(
        controller: controller,
        focusNode: focusNode,
        keyboardType: decimal
            ? const TextInputType.numberWithOptions(decimal: true)
            : TextInputType.number,
        inputFormatters: [if (!decimal) FilteringTextInputFormatter.digitsOnly],
        textInputAction: TextInputAction.done,
        onEditingComplete: onCommit,
        onSubmitted: (_) => onCommit?.call(),
        style: TextStyle(
          fontSize: 14,
          fontWeight: AppFontWeights.medium,
          color: cs.onSurface.withValues(alpha: 0.92),
        ),
      ),
    );
  }
}
