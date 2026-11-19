import 'package:flutter/material.dart';

import 'package:Cuplivo/features/harness/pages/assistant/models/dsh_provider_settings.dart';
import 'package:Cuplivo/icons/lucide_adapter.dart';
import 'package:Cuplivo/l10n/app_localizations.dart';
import 'package:Cuplivo/shared/widgets/ios_form_text_field.dart';
import 'package:Cuplivo/shared/widgets/ios_tactile.dart';
import 'package:Cuplivo/theme/app_font_weights.dart';
import 'package:Cuplivo/theme/app_semantic_colors.dart';

/// The per-model reasoning-effort list of a custom provider (R11).
///
/// DSH sends one of these values as `reasoningEffort`; a custom pi-ai route is
/// the only place the provider author declares them. The editor keeps the
/// remote's order, so the chip order reads like the reference's effort list.
class DshReasoningEffortsEditor extends StatelessWidget {
  const DshReasoningEffortsEditor({
    super.key,
    required this.choices,
    required this.onChanged,
    this.enabled = true,
  });

  final List<DshReasoningChoice> choices;
  final ValueChanged<List<DshReasoningChoice>> onChanged;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final cs = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Text(
              l10n.dshProviderDetailReasoningEfforts,
              style: TextStyle(
                fontSize: 13,
                fontWeight: AppFontWeights.semibold,
                color: cs.onSurface.withValues(alpha: 0.85),
              ),
            ),
            const SizedBox(width: 6),
            Expanded(
              child: Text(
                l10n.dshProviderDetailReasoningEffortsHint,
                style: TextStyle(
                  fontSize: 11,
                  color: cs.onSurface.withValues(alpha: 0.5),
                ),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        if (choices.isEmpty)
          Text(
            '—',
            style: TextStyle(
              fontSize: 13,
              color: cs.onSurface.withValues(alpha: 0.45),
            ),
          )
        else
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final choice in choices)
                _DshEffortChip(
                  choice: choice,
                  enabled: enabled,
                  onRemove: () {
                    final next = [
                      for (final current in choices)
                        if (current != choice) current,
                    ];
                    onChanged(next);
                  },
                ),
            ],
          ),
        const SizedBox(height: 8),
        IosIconButton(
          icon: Lucide.Plus,
          size: 15,
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
          borderRadius: 10,
          minSize: 32,
          color: cs.primary,
          enabled: enabled,
          semanticLabel: l10n.dshProviderDetailAddReasoningEffort,
          onTap: enabled
              ? () async {
                  final choice = await _showAddEffortDialog(context);
                  if (choice == null) return;
                  if (choices.contains(choice)) return;
                  onChanged([...choices, choice]);
                }
              : null,
        ),
      ],
    );
  }

  Future<DshReasoningChoice?> _showAddEffortDialog(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final idController = TextEditingController();
    final nameController = TextEditingController();
    return showDialog<DshReasoningChoice>(
      context: context,
      builder: (dialogContext) {
        return AlertDialog(
          title: Text(l10n.dshProviderDetailAddReasoningEffort),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              IosFormTextField(
                label: l10n.dshProviderDetailEffortId,
                controller: idController,
                autofocus: true,
                inlineLabel: false,
                outerPadding: EdgeInsets.zero,
              ),
              const SizedBox(height: 12),
              IosFormTextField(
                label: l10n.dshProviderDetailEffortName,
                controller: nameController,
                inlineLabel: false,
                outerPadding: EdgeInsets.zero,
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: Text(l10n.modelDetailSheetCancelButton),
            ),
            TextButton(
              onPressed: () {
                final id = idController.text.trim();
                if (id.isEmpty) return;
                final name = nameController.text.trim();
                Navigator.of(dialogContext).pop(
                  DshReasoningChoice(id: id, name: name.isEmpty ? null : name),
                );
              },
              child: Text(l10n.modelDetailSheetAddButton),
            ),
          ],
        );
      },
    );
  }
}

class _DshEffortChip extends StatelessWidget {
  const _DshEffortChip({
    required this.choice,
    required this.enabled,
    required this.onRemove,
  });

  final DshReasoningChoice choice;
  final bool enabled;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final colors = context.appColors;
    return Container(
      padding: const EdgeInsets.only(left: 10, right: 4, top: 4, bottom: 4),
      decoration: BoxDecoration(
        color: colors.surfaceCardFill,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(
          color: cs.outlineVariant.withValues(alpha: 0.28),
          width: 0.5,
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            choice.title,
            style: TextStyle(
              fontSize: 12,
              fontWeight: AppFontWeights.medium,
              color: cs.onSurface.withValues(alpha: 0.85),
            ),
          ),
          const SizedBox(width: 2),
          IosIconButton(
            icon: Lucide.X,
            size: 12,
            padding: const EdgeInsets.all(3),
            borderRadius: 7,
            enabled: enabled,
            onTap: enabled ? onRemove : null,
          ),
        ],
      ),
    );
  }
}
