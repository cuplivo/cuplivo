import 'package:flutter/material.dart';

import 'package:Cuplivo/features/harness/controllers/dsh_chat_session.dart';
import 'package:Cuplivo/features/harness/widgets/chat/dsh_picker_scaffold.dart';
import 'package:Cuplivo/icons/lucide_adapter.dart';
import 'package:Cuplivo/l10n/app_localizations.dart';
import 'package:Cuplivo/shared/widgets/ios_tactile.dart';
import 'package:Cuplivo/shared/widgets/section_card.dart';
import 'package:Cuplivo/theme/app_font_weights.dart';

/// Display name for one roster row: the preset's published name always wins,
/// the shipped four fall back to Cuplivo's localized copy.
String dshAgentPresetDisplayName(
  BuildContext context,
  DshAgentPresetOption option,
) {
  final name = (option.name ?? '').trim();
  if (name.isNotEmpty) return name;
  final l10n = AppLocalizations.of(context)!;
  return switch (option.id) {
    'standard' => l10n.dshPresetStandardName,
    'ptc' => l10n.dshPresetPtcName,
    'minimal' => l10n.dshPresetMinimalName,
    'cordis' => l10n.dshPresetCordisName,
    _ => option.id,
  };
}

/// One-sentence copy for one roster row, following the same rule as the name.
String? dshAgentPresetDescription(
  BuildContext context,
  DshAgentPresetOption option,
) {
  final description = (option.description ?? '').trim();
  if (description.isNotEmpty) return description;
  final l10n = AppLocalizations.of(context)!;
  return switch (option.id) {
    'standard' => l10n.dshPresetStandardDescription,
    'ptc' => l10n.dshPresetPtcDescription,
    'minimal' => l10n.dshPresetMinimalDescription,
    'cordis' => l10n.dshPresetCordisDescription,
    _ => null,
  };
}

/// Opens the Agent-preset picker and returns the chosen preset id, or null when
/// the user dismissed it (or picked the row the session already runs).
Future<String?> showDshAgentPresetPicker(
  BuildContext context, {
  required DshAgentPresetState state,
  Key? panelKey,
}) {
  return showDshPicker<String>(
    context: context,
    title: AppLocalizations.of(context)!.dshPresetPickerTitle,
    panelKey: panelKey,
    bodyBuilder: (context, scrollController) =>
        DshAgentPresetPicker(state: state, scrollController: scrollController),
  );
}

/// Picker body: one row per roster entry, with its description and the
/// Host-reported reason a broken declaration cannot start a session.
class DshAgentPresetPicker extends StatelessWidget {
  const DshAgentPresetPicker({
    super.key,
    required this.state,
    required this.scrollController,
  });

  final DshAgentPresetState state;
  final ScrollController scrollController;

  static Key rowKey(String id) => ValueKey<String>('dsh-preset-$id');

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    if (state.options.isEmpty) {
      return DshPickerEmptyState(
        icon: Lucide.Bot,
        message: l10n.dshPresetPickerEmpty,
      );
    }
    final cs = Theme.of(context).colorScheme;
    return ListView(
      controller: scrollController,
      padding: const EdgeInsets.fromLTRB(12, 6, 12, 16),
      children: [
        for (final option in state.options)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: _DshAgentPresetRow(
              key: rowKey(option.id),
              option: option,
              selected: option.id == state.currentId,
              enabled: !state.isChanging && !option.isBroken,
              onTap: () {
                if (option.id == state.currentId) return;
                Navigator.of(context).pop(option.id);
              },
            ),
          ),
        if (state.isChanging)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                SizedBox(
                  width: 14,
                  height: 14,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: cs.onSurface.withValues(alpha: 0.5),
                  ),
                ),
                const SizedBox(width: 8),
                Text(
                  l10n.dshPresetChanging,
                  style: TextStyle(
                    fontSize: 12,
                    color: cs.onSurface.withValues(alpha: 0.6),
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }
}

class _DshAgentPresetRow extends StatelessWidget {
  const _DshAgentPresetRow({
    super.key,
    required this.option,
    required this.selected,
    required this.enabled,
    required this.onTap,
  });

  final DshAgentPresetOption option;
  final bool selected;
  final bool enabled;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final cs = Theme.of(context).colorScheme;
    final accent = cs.primary;
    final description = dshAgentPresetDescription(context, option);
    return Opacity(
      opacity: enabled ? 1 : 0.6,
      child: IosCardPress(
        baseColor: selected
            ? accent.withValues(alpha: 0.10)
            : sheetTileColor(context),
        borderRadius: BorderRadius.circular(14),
        pressedBlendStrength: 0.10,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
        onTap: enabled ? onTap : null,
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.only(top: 1),
              child: Icon(
                Lucide.Bot,
                size: 20,
                color: selected ? accent : cs.onSurface.withValues(alpha: 0.7),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Flexible(
                        child: Text(
                          dshAgentPresetDisplayName(context, option),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 15,
                            fontWeight: AppFontWeights.medium,
                            color: selected ? accent : cs.onSurface,
                          ),
                        ),
                      ),
                      if (option.isDefault) ...[
                        const SizedBox(width: 6),
                        Text(
                          l10n.dshAgentPresetsDefault,
                          style: TextStyle(
                            fontSize: 10.5,
                            fontWeight: AppFontWeights.semibold,
                            color: accent.withValues(alpha: 0.9),
                          ),
                        ),
                      ],
                      if (option.isBroken) ...[
                        const SizedBox(width: 6),
                        Text(
                          l10n.dshPresetBrokenTag,
                          style: TextStyle(
                            fontSize: 10.5,
                            fontWeight: AppFontWeights.semibold,
                            color: cs.error.withValues(alpha: 0.9),
                          ),
                        ),
                      ],
                    ],
                  ),
                  if (option.isBroken && option.broken!.trim().isNotEmpty) ...[
                    const SizedBox(height: 3),
                    Text(
                      option.broken!.trim(),
                      style: TextStyle(
                        fontSize: 12.5,
                        height: 1.3,
                        color: cs.error.withValues(alpha: 0.8),
                      ),
                    ),
                  ] else if (description != null) ...[
                    const SizedBox(height: 3),
                    Text(
                      description,
                      style: TextStyle(
                        fontSize: 12.5,
                        height: 1.3,
                        color: cs.onSurface.withValues(alpha: 0.6),
                      ),
                    ),
                  ],
                ],
              ),
            ),
            const SizedBox(width: 8),
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: selected
                  ? Icon(Lucide.Check, size: 18, color: accent)
                  : const SizedBox(width: 18),
            ),
          ],
        ),
      ),
    );
  }
}

/// The compact composer control: the Session's preset name above the input,
/// tap to open the picker. Read-only once the Session started, because the
/// Host only accepts a switch before the first turn.
class DshAgentPresetChip extends StatelessWidget {
  const DshAgentPresetChip({
    super.key,
    required this.agentPresets,
    required this.onTap,
  });

  final DshAgentPresetState agentPresets;
  final VoidCallback onTap;

  static const chipKey = ValueKey<String>('dsh-preset-chip');

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final cs = Theme.of(context).colorScheme;
    final current = agentPresets.currentOption;
    final label = current == null
        ? l10n.dshPresetPickerTitle
        : dshAgentPresetDisplayName(context, current);
    final enabled =
        agentPresets.canSelect &&
        !agentPresets.isChanging &&
        current != null &&
        !current.isBroken;
    final color = enabled
        ? cs.onSurface.withValues(alpha: 0.7)
        : cs.onSurface.withValues(alpha: 0.45);
    return Tooltip(
      message: enabled ? l10n.dshPresetChipHint : l10n.dshPresetLocked,
      waitDuration: const Duration(milliseconds: 400),
      child: IosCardPress(
        key: chipKey,
        baseColor: sheetTileColor(context),
        borderRadius: BorderRadius.circular(12),
        pressedBlendStrength: 0.08,
        padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
        onTap: enabled ? onTap : null,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Lucide.Bot, size: 14, color: color),
            const SizedBox(width: 5),
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 120),
              child: Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: AppFontWeights.medium,
                  color: color,
                ),
              ),
            ),
            if (agentPresets.isChanging) ...[
              const SizedBox(width: 6),
              SizedBox(
                width: 11,
                height: 11,
                child: CircularProgressIndicator(
                  strokeWidth: 1.8,
                  color: color,
                ),
              ),
            ] else ...[
              const SizedBox(width: 3),
              Icon(Lucide.ChevronDown, size: 12, color: color),
            ],
          ],
        ),
      ),
    );
  }
}
