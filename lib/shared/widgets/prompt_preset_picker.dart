import 'package:flutter/material.dart';
import 'package:Cuplivo/theme/app_font_weights.dart';

import '../../core/prompts/prompt_preset.dart';
import '../../core/services/haptics.dart';
import '../../icons/lucide_adapter.dart';
import 'ios_tactile.dart';

/// iOS-style pill that shows the currently matched prompt preset and opens a
/// bottom sheet of presets on tap. Picking a preset fills [controller] — it
/// takes effect only after the caller saves. Mirrors the title-preset picker
/// in `DefaultModelPage` for prompts that gained presets (compress, OCR).
class PromptPresetPicker extends StatelessWidget {
  const PromptPresetPicker({
    super.key,
    required this.controller,
    required this.presets,
    required this.detect,
    required this.labels,
    required this.customLabel,
  });

  final TextEditingController controller;
  final List<PromptPreset> presets;
  final String? Function(String text) detect;
  final Map<String, String> labels;
  final String customLabel;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        final activeId = detect(controller.text);
        final label = labels[activeId] ?? customLabel;
        return GestureDetector(
          onTap: () => _showPresetSheet(context),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 6),
            decoration: BoxDecoration(
              border: Border.all(
                color: cs.outlineVariant.withValues(alpha: 0.18),
              ),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(label, style: const TextStyle(fontSize: 13)),
                const SizedBox(width: 4),
                Icon(Lucide.chevronDown, size: 16),
              ],
            ),
          ),
        );
      },
    );
  }

  Future<void> _showPresetSheet(BuildContext context) async {
    final cs = Theme.of(context).colorScheme;
    final activeId = detect(controller.text);
    final result = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: cs.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (ctx) {
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 4, 12, 12),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Center(
                  child: Container(
                    width: 40,
                    height: 4,
                    decoration: BoxDecoration(
                      color: cs.onSurface.withValues(alpha: 0.2),
                      borderRadius: BorderRadius.circular(999),
                    ),
                  ),
                ),
                const SizedBox(height: 8),
                for (final preset in presets) ...[
                  _PresetOption(
                    label: labels[preset.id] ?? preset.id,
                    selected: activeId == preset.id,
                    onTap: () => Navigator.of(ctx).pop(preset.id),
                  ),
                  const SizedBox(height: 4),
                ],
                const SizedBox(height: 8),
              ],
            ),
          ),
        );
      },
    );
    if (result != null) {
      final p = presets.where((p) => p.id == result).firstOrNull;
      if (p != null) controller.text = p.prompt;
    }
  }
}

class _PresetOption extends StatelessWidget {
  const _PresetOption({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return SizedBox(
      height: 48,
      child: IosCardPress(
        borderRadius: BorderRadius.circular(14),
        baseColor: cs.surface,
        duration: const Duration(milliseconds: 260),
        onTap: () {
          Haptics.light();
          onTap();
        },
        padding: const EdgeInsets.symmetric(horizontal: 12),
        child: Row(
          children: [
            Expanded(
              child: Text(
                label,
                style: TextStyle(
                  fontSize: 15,
                  fontWeight: AppFontWeights.medium,
                ),
              ),
            ),
            if (selected) Icon(Lucide.Check, size: 18, color: cs.primary),
          ],
        ),
      ),
    );
  }
}
