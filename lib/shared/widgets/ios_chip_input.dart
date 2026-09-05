import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../icons/lucide_adapter.dart';
import '../../theme/app_font_weights.dart';
import '../../theme/app_semantic_colors.dart';
import 'ios_tactile.dart';

/// Editable chip list used by the auto-retry settings (status codes, retry
/// keywords, stop keywords) on both mobile and desktop settings surfaces.
///
/// A title row with an optional restore button, a [Wrap] of removable chips,
/// and an add row (text field + plus button, submit on Enter).
class IosChipInput extends StatefulWidget {
  const IosChipInput({
    super.key,
    required this.title,
    required this.values,
    this.addHint,
    this.restoreLabel,
    this.keyboardType,
    this.onAdd,
    this.onRemove,
    this.onRestore,
  });

  final String title;
  final List<String> values;
  final String? addHint;
  final String? restoreLabel;
  final TextInputType? keyboardType;
  final void Function(String raw)? onAdd;
  final void Function(String raw)? onRemove;
  final VoidCallback? onRestore;

  @override
  State<IosChipInput> createState() => _IosChipInputState();
}

class _IosChipInputState extends State<IosChipInput> {
  final TextEditingController _controller = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _submit() {
    final raw = _controller.text.trim();
    if (raw.isEmpty) return;
    widget.onAdd?.call(raw);
    _controller.clear();
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 10, 12, 0),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  widget.title,
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: AppFontWeights.semibold,
                    color: cs.onSurface.withValues(alpha: 0.9),
                  ),
                ),
              ),
              if (widget.restoreLabel != null && widget.onRestore != null)
                IosCardPress(
                  onTap: widget.onRestore,
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 6,
                    ),
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(8),
                      color: cs.primary.withValues(alpha: 0.10),
                    ),
                    child: Text(
                      widget.restoreLabel!,
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: AppFontWeights.semibold,
                        color: cs.primary,
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
        const SizedBox(height: 10),
        if (widget.values.isNotEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final value in widget.values)
                  _Chip(
                    label: value,
                    onRemove: widget.onRemove == null
                        ? null
                        : () => widget.onRemove!(value),
                  ),
              ],
            ),
          ),
        const SizedBox(height: 10),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _controller,
                  keyboardType: widget.keyboardType,
                  inputFormatters: widget.keyboardType == TextInputType.number
                      ? [FilteringTextInputFormatter.digitsOnly]
                      : null,
                  textInputAction: TextInputAction.done,
                  onSubmitted: (_) => _submit(),
                  style: const TextStyle(fontSize: 14),
                  decoration: InputDecoration(
                    isDense: true,
                    hintText: widget.addHint,
                    hintStyle: TextStyle(
                      fontSize: 14,
                      color: cs.onSurface.withValues(alpha: 0.5),
                    ),
                    filled: true,
                    fillColor: context.appColors.surfaceFill,
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(10),
                      borderSide: BorderSide(
                        color: cs.outlineVariant.withValues(alpha: 0.12),
                        width: 0.6,
                      ),
                    ),
                    enabledBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(10),
                      borderSide: BorderSide(
                        color: cs.outlineVariant.withValues(alpha: 0.12),
                        width: 0.6,
                      ),
                    ),
                    focusedBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(10),
                      borderSide: BorderSide(
                        color: cs.primary.withValues(alpha: 0.45),
                        width: 0.8,
                      ),
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              IosIconButton(
                icon: Lucide.Plus,
                size: 18,
                color: cs.primary,
                onTap: _submit,
              ),
            ],
          ),
        ),
        const SizedBox(height: 10),
      ],
    );
  }
}

class _Chip extends StatelessWidget {
  const _Chip({required this.label, this.onRemove});

  final String label;
  final VoidCallback? onRemove;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Container(
      padding: const EdgeInsets.only(left: 10, right: 4),
      decoration: BoxDecoration(
        color: cs.primary.withValues(alpha: isDark ? 0.22 : 0.12),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(
          color: cs.primary.withValues(alpha: isDark ? 0.36 : 0.26),
          width: 0.6,
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            label,
            style: TextStyle(
              fontSize: 13,
              fontWeight: AppFontWeights.semibold,
              color: cs.onSurface.withValues(alpha: 0.9),
            ),
          ),
          if (onRemove != null)
            IosIconButton(
              icon: Lucide.X,
              size: 14,
              padding: EdgeInsets.zero,
              color: cs.onSurface.withValues(alpha: 0.65),
              onTap: onRemove,
            ),
        ],
      ),
    );
  }
}
