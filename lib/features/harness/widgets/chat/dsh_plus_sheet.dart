import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'package:Cuplivo/features/chat/widgets/tools_sheet_row.dart';
import 'package:Cuplivo/icons/lucide_adapter.dart';
import 'package:Cuplivo/l10n/app_localizations.dart';
import 'package:Cuplivo/shared/widgets/action_sheet.dart';
import 'package:Cuplivo/theme/app_font_weights.dart';
import 'package:Cuplivo/theme/app_semantic_colors.dart';

/// What the DSH plus menu shows about the open session.
///
/// The menu mirrors the remote composer's `+` menu but only with the entries
/// the brief names; each entry's [detail] is live remote state, never Cuplivo's
/// local model/workspace.
@immutable
class DshPlusMenuState {
  const DshPlusMenuState({
    this.workspaceLabel,
    this.permissionLabel,
    this.modelLabel,
    this.connectionProblem,
  });

  /// Current session workspace/cwd, shown under 工作区.
  final String? workspaceLabel;

  /// Current permission preset display name, shown on the 权限 row.
  final String? permissionLabel;

  /// Current model + provider display, shown on the 模型详情 row.
  final String? modelLabel;

  /// A connection failure sentence, when the link is currently broken.
  final String? connectionProblem;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is DshPlusMenuState &&
          other.workspaceLabel == workspaceLabel &&
          other.permissionLabel == permissionLabel &&
          other.modelLabel == modelLabel &&
          other.connectionProblem == connectionProblem;

  @override
  int get hashCode => Object.hash(
    workspaceLabel,
    permissionLabel,
    modelLabel,
    connectionProblem,
  );
}

/// Opens the DSH composer's plus menu.
///
/// Mobile is a bottom sheet with `ToolsSheetRow` tiles; desktop is the app's
/// adaptive menu (`showAdaptiveActionMenu` → anchored context menu), matching
/// how Cuplivo's own tools popover behaves. Entries whose capability is absent
/// are not rendered (capability parity: no button DSH cannot serve).
Future<void> showDshPlusSheet(
  BuildContext context, {
  required DshPlusMenuState state,
  required VoidCallback onOpenPermission,
  VoidCallback? onOpenWorkspace,
  VoidCallback? onOpenModelDetails,
  VoidCallback? onTogglePluginPanel,
  VoidCallback? onOpenSettings,
  GlobalKey? anchorKey,
  Offset? anchor,
}) {
  final isDesktop =
      defaultTargetPlatform == TargetPlatform.macOS ||
      defaultTargetPlatform == TargetPlatform.windows ||
      defaultTargetPlatform == TargetPlatform.linux;
  if (isDesktop) {
    return showAdaptiveActionMenu(
      context,
      anchor: anchor,
      anchorKey: anchorKey,
      title: AppLocalizations.of(context)!.dshPlusSheetTitle,
      items: [
        if (onOpenWorkspace != null)
          ActionSheetItem(
            icon: Lucide.FolderCode,
            label: AppLocalizations.of(context)!.dshPlusWorkspace,
            onTap: onOpenWorkspace,
          ),
        ActionSheetItem(
          icon: Lucide.Shield,
          label: AppLocalizations.of(context)!.dshPlusPermission,
          onTap: onOpenPermission,
        ),
        if (onOpenModelDetails != null)
          ActionSheetItem(
            icon: Lucide.Boxes,
            label: AppLocalizations.of(context)!.dshPlusModelDetails,
            onTap: onOpenModelDetails,
          ),
        if (onTogglePluginPanel != null)
          ActionSheetItem(
            icon: Lucide.SlidersHorizontal,
            label: AppLocalizations.of(context)!.dshPlusPluginPanel,
            onTap: onTogglePluginPanel,
          ),
        if (onOpenSettings != null)
          ActionSheetItem(
            icon: Lucide.Settings,
            label: AppLocalizations.of(context)!.dshPlusSettings,
            onTap: onOpenSettings,
          ),
      ],
    );
  }
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: context.overlaySurface,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
    ),
    builder: (sheetContext) => _DshPlusSheet(
      state: state,
      onOpenPermission: onOpenPermission,
      onOpenWorkspace: onOpenWorkspace,
      onOpenModelDetails: onOpenModelDetails,
      onTogglePluginPanel: onTogglePluginPanel,
      onOpenSettings: onOpenSettings,
      onClose: () => Navigator.of(sheetContext).maybePop(),
    ),
  );
}

class _DshPlusSheet extends StatelessWidget {
  const _DshPlusSheet({
    required this.state,
    required this.onOpenPermission,
    required this.onClose,
    this.onOpenWorkspace,
    this.onOpenModelDetails,
    this.onTogglePluginPanel,
    this.onOpenSettings,
  });

  final DshPlusMenuState state;
  final VoidCallback onOpenPermission;
  final VoidCallback? onOpenWorkspace;
  final VoidCallback? onOpenModelDetails;
  final VoidCallback? onTogglePluginPanel;
  final VoidCallback? onOpenSettings;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final cs = Theme.of(context).colorScheme;
    final workspace = (state.workspaceLabel ?? '').trim();
    final permission = (state.permissionLabel ?? '').trim();
    final model = (state.modelLabel ?? '').trim();
    final connectionProblem = (state.connectionProblem ?? '').trim();
    return SafeArea(
      top: false,
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.sizeOf(context).height * 0.75,
        ),
        child: Column(
          key: const ValueKey<String>('dsh-plus-sheet'),
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(height: 8),
            Container(
              width: 40,
              height: 4,
              decoration: BoxDecoration(
                color: cs.onSurface.withValues(alpha: 0.2),
                borderRadius: BorderRadius.circular(999),
              ),
            ),
            const SizedBox(height: 10),
            SizedBox(
              height: 34,
              child: Center(
                child: Text(
                  l10n.dshPlusSheetTitle,
                  style: TextStyle(
                    fontSize: 18,
                    fontWeight: AppFontWeights.emphasis,
                  ),
                ),
              ),
            ),
            const SizedBox(height: 4),
            Flexible(
              child: ListView(
                shrinkWrap: true,
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                children: [
                  if (connectionProblem.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 10),
                      child: Row(
                        children: [
                          Icon(
                            Lucide.TriangleAlert,
                            size: 16,
                            color: context.appColors.warning,
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              connectionProblem,
                              style: TextStyle(
                                fontSize: 12.5,
                                color: context.appColors.warning,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ToolsSheetRow(
                    key: const ValueKey<String>('dsh-plus-workspace'),
                    icon: Lucide.FolderCode,
                    label: l10n.dshPlusWorkspace,
                    subtitle: workspace.isEmpty
                        ? l10n.dshPlusWorkspaceUnknown
                        : workspace,
                    subtitleMaxLines: 2,
                    trailing: onOpenWorkspace == null
                        ? const SizedBox(width: 18)
                        : ToolsSheetRow.chevron(context),
                    onTap: onOpenWorkspace,
                  ),
                  const SizedBox(height: 8),
                  ToolsSheetRow(
                    key: const ValueKey<String>('dsh-plus-permission'),
                    icon: Lucide.Shield,
                    label: l10n.dshPlusPermission,
                    detail: permission.isEmpty ? null : permission,
                    trailing: ToolsSheetRow.chevron(context),
                    onTap: () {
                      onClose();
                      onOpenPermission();
                    },
                  ),
                  if (onOpenModelDetails != null) ...[
                    const SizedBox(height: 8),
                    ToolsSheetRow(
                      key: const ValueKey<String>('dsh-plus-model-details'),
                      icon: Lucide.Boxes,
                      label: l10n.dshPlusModelDetails,
                      subtitle: model.isEmpty ? null : model,
                      trailing: ToolsSheetRow.chevron(context),
                      onTap: onOpenModelDetails,
                    ),
                  ],
                  if (onTogglePluginPanel != null) ...[
                    const SizedBox(height: 8),
                    ToolsSheetRow(
                      key: const ValueKey<String>('dsh-plus-plugin-panel'),
                      icon: Lucide.SlidersHorizontal,
                      label: l10n.dshPlusPluginPanel,
                      subtitle: l10n.dshPlusPluginPanelSubtitle,
                      trailing: ToolsSheetRow.chevron(context),
                      onTap: () {
                        onClose();
                        onTogglePluginPanel!();
                      },
                    ),
                  ],
                  if (onOpenSettings != null) ...[
                    const SizedBox(height: 8),
                    ToolsSheetRow(
                      key: const ValueKey<String>('dsh-plus-settings'),
                      icon: Lucide.Settings,
                      label: l10n.dshPlusSettings,
                      trailing: ToolsSheetRow.chevron(context),
                      onTap: () {
                        onClose();
                        onOpenSettings!();
                      },
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
