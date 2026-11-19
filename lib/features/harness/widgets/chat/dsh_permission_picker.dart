import 'package:flutter/material.dart';

import 'package:Cuplivo/features/harness/controllers/dsh_chat_session.dart';
import 'package:Cuplivo/features/harness/widgets/chat/dsh_picker_scaffold.dart';
import 'package:Cuplivo/features/settings/widgets/custom_theme_widgets.dart'
    show AppDialogHeader, showAppDialog;
import 'package:Cuplivo/icons/lucide_adapter.dart';
import 'package:Cuplivo/l10n/app_localizations.dart';
import 'package:Cuplivo/shared/widgets/ios_checkbox.dart';
import 'package:Cuplivo/shared/widgets/ios_tactile.dart';
import 'package:Cuplivo/shared/widgets/section_card.dart';
import 'package:Cuplivo/theme/app_font_weights.dart';
import 'package:Cuplivo/theme/app_semantic_colors.dart';

/// Values DSH treats as "this can do damage", independent of how the catalog
/// labels them: full access, and the experimental auto-review preset.
const Set<String> _dshDestructivePermissionValues = <String>{
  'danger-full-access',
  'auto',
};

/// Whether changing to [option] must be confirmed explicitly first.
///
/// The official UI keeps this friction for full access; the rule is applied by
/// value here so a catalog that omits the flag cannot switch the control
/// silently.
bool dshPermissionRequiresConfirmation(DshPermissionOption option) {
  return option.requiresRiskConfirmation ||
      _dshDestructivePermissionValues.contains(option.value);
}

IconData dshPermissionIcon(String value) {
  return switch (value) {
    'read-only' => Lucide.Eye,
    'workspace-write' => Lucide.FolderCode,
    'danger-full-access' => Lucide.ShieldAlert,
    'auto' => Lucide.RefreshCw,
    _ => Lucide.Shield,
  };
}

/// The Host's display name, with Cuplivo's localized fallback for the shipped
/// three levels. Permission names are the Host's to define (`Host`-configured
/// presets), so a catalog name always wins.
String dshPermissionDisplayName(
  BuildContext context,
  DshPermissionOption option,
) {
  final name = option.name.trim();
  if (name.isNotEmpty) return name;
  final l10n = AppLocalizations.of(context)!;
  return switch (option.value) {
    'read-only' => l10n.dshPermissionReadOnly,
    'workspace-write' => l10n.dshPermissionWorkspaceWrite,
    'danger-full-access' => l10n.dshPermissionFullAccess,
    _ => option.value,
  };
}

String? dshPermissionDescription(
  BuildContext context,
  DshPermissionOption option,
) {
  final description = (option.description ?? '').trim();
  if (description.isNotEmpty) return description;
  final l10n = AppLocalizations.of(context)!;
  return switch (option.value) {
    'read-only' => l10n.dshPermissionReadOnlyDesc,
    'workspace-write' => l10n.dshPermissionWorkspaceWriteDesc,
    'danger-full-access' => l10n.dshPermissionFullAccessDesc,
    _ => null,
  };
}

/// Opens the permission picker and returns the chosen value, or null when the
/// user dismissed it (or declined the risk confirmation).
Future<String?> showDshPermissionPicker(
  BuildContext context, {
  required DshPermissionState state,
  Key? panelKey,
}) {
  return showDshPicker<String>(
    context: context,
    title: AppLocalizations.of(context)!.dshPermissionTitle,
    panelKey: panelKey,
    bodyBuilder: (context, scrollController) =>
        DshPermissionPicker(state: state, scrollController: scrollController),
  );
}

/// Picker body: one row per catalog preset, with its description and the
/// blocking confirmation for destructive presets.
class DshPermissionPicker extends StatelessWidget {
  const DshPermissionPicker({
    super.key,
    required this.state,
    required this.scrollController,
  });

  final DshPermissionState state;
  final ScrollController scrollController;

  static Key rowKey(String value) => ValueKey<String>('dsh-permission-$value');

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    if (state.options.isEmpty) {
      return DshPickerEmptyState(
        icon: Lucide.Shield,
        message: l10n.dshPermissionNoPresets,
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
            child: _DshPermissionRow(
              key: rowKey(option.value),
              option: option,
              selected: option.value == state.currentValue,
              enabled: !state.isChanging,
              onTap: () async {
                if (option.value == state.currentValue) return;
                if (dshPermissionRequiresConfirmation(option)) {
                  final confirmed = await confirmDshPermissionRisk(
                    context,
                    option,
                  );
                  if (!confirmed || !context.mounted) return;
                }
                if (context.mounted) Navigator.of(context).pop(option.value);
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
                  l10n.dshPermissionChanging,
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

class _DshPermissionRow extends StatelessWidget {
  const _DshPermissionRow({
    super.key,
    required this.option,
    required this.selected,
    required this.enabled,
    required this.onTap,
  });

  final DshPermissionOption option;
  final bool selected;
  final bool enabled;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final cs = Theme.of(context).colorScheme;
    final destructive = dshPermissionRequiresConfirmation(option);
    final accent = destructive ? context.appColors.warning : cs.primary;
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
                dshPermissionIcon(option.value),
                size: 20,
                color: destructive
                    ? accent
                    : (selected ? accent : cs.onSurface.withValues(alpha: 0.7)),
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
                          dshPermissionDisplayName(context, option),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 15,
                            fontWeight: AppFontWeights.medium,
                            color: selected ? accent : cs.onSurface,
                          ),
                        ),
                      ),
                      if (destructive && !selected) ...[
                        const SizedBox(width: 6),
                        Text(
                          l10n.dshPermissionRiskTag,
                          style: TextStyle(
                            fontSize: 10.5,
                            fontWeight: AppFontWeights.semibold,
                            color: accent.withValues(alpha: 0.9),
                          ),
                        ),
                      ],
                    ],
                  ),
                  if (dshPermissionDescription(context, option) != null) ...[
                    const SizedBox(height: 3),
                    Text(
                      dshPermissionDescription(context, option)!,
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

/// The compact composer control: current preset name + icon, tap to open the
/// picker. Rendered above the composer because the shared `ChatInputBar` has no
/// permission slot (its action row is Cuplivo's, and the remote needs one extra
/// control the brief names explicitly).
class DshPermissionChip extends StatelessWidget {
  const DshPermissionChip({
    super.key,
    required this.permissions,
    required this.onTap,
    this.enabled = true,
  });

  final DshPermissionState permissions;
  final VoidCallback onTap;
  final bool enabled;

  static const chipKey = ValueKey<String>('dsh-permission-chip');

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final current = permissions.currentOption;
    final value = permissions.currentValue.trim();
    final destructive = current != null
        ? dshPermissionRequiresConfirmation(current)
        : _dshDestructivePermissionValues.contains(value);
    final color = destructive
        ? context.appColors.warning
        : cs.onSurface.withValues(alpha: 0.7);
    final label = current != null
        ? dshPermissionDisplayName(context, current)
        : (value.isEmpty
              ? AppLocalizations.of(context)!.dshPermissionTitle
              : value);
    return Tooltip(
      message: current == null
          ? label
          : (dshPermissionDescription(context, current) ?? label),
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
            Icon(dshPermissionIcon(value), size: 14, color: color),
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
            if (permissions.isChanging) ...[
              const SizedBox(width: 6),
              SizedBox(
                width: 11,
                height: 11,
                child: CircularProgressIndicator(
                  strokeWidth: 1.8,
                  color: color,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// Blocking confirmation for a destructive permission change.
///
/// The same friction the official UI keeps: an acknowledgement checkbox, a
/// non-destructive default, and no way to switch the control by merely tapping
/// the row.
Future<bool> confirmDshPermissionRisk(
  BuildContext context,
  DshPermissionOption option,
) async {
  final l10n = AppLocalizations.of(context)!;
  final result = await showAppDialog<bool>(
    context,
    maxWidth: 420,
    child: _DshPermissionRiskDialog(option: option, l10n: l10n),
  );
  return result == true;
}

class _DshPermissionRiskDialog extends StatefulWidget {
  const _DshPermissionRiskDialog({required this.option, required this.l10n});

  final DshPermissionOption option;
  final AppLocalizations l10n;

  @override
  State<_DshPermissionRiskDialog> createState() =>
      _DshPermissionRiskDialogState();
}

class _DshPermissionRiskDialogState extends State<_DshPermissionRiskDialog> {
  bool _acknowledged = false;

  @override
  Widget build(BuildContext context) {
    final l10n = widget.l10n;
    final cs = Theme.of(context).colorScheme;
    final warning = context.appColors.warning;
    final description =
        dshPermissionDescription(context, widget.option) ??
        l10n.dshPermissionFullAccessDesc;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        AppDialogHeader(title: l10n.dshPermissionRiskTitle),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Padding(
                    padding: const EdgeInsets.only(top: 1),
                    child: Icon(Lucide.TriangleAlert, size: 18, color: warning),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      l10n.dshPermissionRiskBody,
                      style: TextStyle(
                        fontSize: 13,
                        height: 1.35,
                        color: cs.onSurface.withValues(alpha: 0.85),
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: warning.withValues(alpha: 0.08),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Text(
                  description,
                  style: TextStyle(
                    fontSize: 12.5,
                    height: 1.35,
                    color: cs.onSurface.withValues(alpha: 0.75),
                  ),
                ),
              ),
              const SizedBox(height: 10),
              IosCardPress(
                baseColor: Colors.transparent,
                borderRadius: BorderRadius.circular(10),
                padding: const EdgeInsets.symmetric(vertical: 6),
                onTap: () => setState(() => _acknowledged = !_acknowledged),
                child: Row(
                  children: [
                    IosCheckbox(
                      value: _acknowledged,
                      onChanged: (value) =>
                          setState(() => _acknowledged = value),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        l10n.dshPermissionRiskAcknowledge,
                        style: TextStyle(
                          fontSize: 13,
                          color: cs.onSurface.withValues(alpha: 0.85),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
          child: Row(
            children: [
              Expanded(
                child: TextButton(
                  onPressed: () => Navigator.of(context).pop(false),
                  child: Text(l10n.dshCancel),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: FilledButton(
                  style: FilledButton.styleFrom(backgroundColor: warning),
                  onPressed: _acknowledged
                      ? () => Navigator.of(context).pop(true)
                      : null,
                  child: Text(l10n.dshPermissionRiskConfirm),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}
