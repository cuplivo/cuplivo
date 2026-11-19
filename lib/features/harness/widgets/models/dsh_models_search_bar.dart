import 'package:flutter/material.dart';

import 'package:Cuplivo/icons/lucide_adapter.dart';
import 'package:Cuplivo/shared/widgets/ios_tactile.dart';
import 'package:Cuplivo/theme/app_semantic_colors.dart';

/// The search pill and add action above the 模型 tab's provider list (R9).
///
/// The field keeps Cuplivo's provider-page search geometry (filled pill,
/// leading magnifier, clear button) and the `+` sits beside it as its own
/// rounded button, exactly as the reference pairs them.
class DshModelsSearchBar extends StatelessWidget {
  const DshModelsSearchBar({
    super.key,
    required this.controller,
    required this.hintText,
    required this.onChanged,
    required this.onClear,
    required this.onAdd,
    required this.addTooltip,
    this.addSemanticLabel,
  });

  final TextEditingController controller;
  final String hintText;
  final ValueChanged<String> onChanged;
  final VoidCallback onClear;
  final VoidCallback onAdd;
  final String addTooltip;
  final String? addSemanticLabel;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final hasText = controller.text.trim().isNotEmpty;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Expanded(
          child: TextField(
            controller: controller,
            onChanged: onChanged,
            textAlignVertical: TextAlignVertical.center,
            style: TextStyle(color: cs.onSurface, fontSize: 14),
            cursorColor: cs.primary,
            decoration: InputDecoration(
              hintText: hintText,
              hintStyle: TextStyle(
                color: cs.onSurface.withValues(alpha: 0.5),
                fontSize: 13.5,
              ),
              isDense: true,
              filled: true,
              fillColor: context.appColors.surfaceFill,
              contentPadding: const EdgeInsets.symmetric(vertical: 13),
              prefixIcon: Icon(
                Lucide.Search,
                size: 18,
                color: cs.onSurface.withValues(alpha: 0.5),
              ),
              prefixIconConstraints: const BoxConstraints(
                minWidth: 42,
                minHeight: 42,
              ),
              suffixIcon: hasText
                  ? IconButton(
                      onPressed: onClear,
                      icon: Icon(
                        Lucide.X,
                        size: 15,
                        color: cs.onSurface.withValues(alpha: 0.48),
                      ),
                      tooltip: hintText,
                      splashColor: Colors.transparent,
                      highlightColor: Colors.transparent,
                      hoverColor: Colors.transparent,
                    )
                  : null,
              suffixIconConstraints: const BoxConstraints(
                minWidth: 38,
                minHeight: 38,
              ),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(14),
                borderSide: BorderSide.none,
              ),
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(14),
                borderSide: BorderSide.none,
              ),
              focusedBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(14),
                borderSide: BorderSide.none,
              ),
            ),
          ),
        ),
        const SizedBox(width: 10),
        Container(
          width: 48,
          height: 46,
          decoration: BoxDecoration(
            color: context.appColors.surfaceFill,
            borderRadius: BorderRadius.circular(14),
          ),
          child: IosIconButton(
            key: const ValueKey('dsh-models-add-provider'),
            icon: Lucide.Plus,
            size: 22,
            padding: EdgeInsets.zero,
            borderRadius: 14,
            tooltip: addTooltip,
            semanticLabel: addSemanticLabel ?? addTooltip,
            onTap: onAdd,
          ),
        ),
      ],
    );
  }
}
