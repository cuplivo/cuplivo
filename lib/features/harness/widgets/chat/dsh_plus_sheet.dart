import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'package:Cuplivo/features/chat/widgets/tools_sheet_row.dart';
import 'package:Cuplivo/features/settings/widgets/custom_theme_widgets.dart';
import 'package:Cuplivo/icons/lucide_adapter.dart';
import 'package:Cuplivo/l10n/app_localizations.dart';
import 'package:Cuplivo/theme/app_font_weights.dart';
import 'package:Cuplivo/theme/app_semantic_colors.dart';

/// What the DSH plus menu shows about the open session.
///
/// The menu mirrors the remote composer's `+` menu structure (添加 / 指令) but
/// only enables entries whose wire path actually exists. A disabled row carries
/// the short honest reason instead of a dead tap.
@immutable
class DshPlusMenuState {
  const DshPlusMenuState({
    this.permissionLabel,
    this.modelLabel,
    this.connectionProblem,
    this.compactCommandAvailable = false,
  });

  /// Current permission preset display name, shown on the 权限 row.
  final String? permissionLabel;

  /// Current model + provider display, shown on the 模型 row.
  final String? modelLabel;

  /// A connection failure sentence, when the link is currently broken.
  final String? connectionProblem;

  /// The Host advertises a `compact` command; only then does the 压缩 row run.
  final bool compactCommandAvailable;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is DshPlusMenuState &&
          other.permissionLabel == permissionLabel &&
          other.modelLabel == modelLabel &&
          other.connectionProblem == connectionProblem &&
          other.compactCommandAvailable == compactCommandAvailable;

  @override
  int get hashCode => Object.hash(
    permissionLabel,
    modelLabel,
    connectionProblem,
    compactCommandAvailable,
  );
}

/// Opens the DSH composer's plus menu.
///
/// Mobile is a bottom sheet; desktop is the app's dialog (a bottom sheet is
/// forbidden on desktop). Rows:
///
/// 添加 — 文件 (image/document picker), 目标/计划/反馈 (disabled: the protocol
/// has no goal/plan/feedback endpoint).
/// 指令 — 压缩 (runs `/compact` only when the catalog advertises it), 权限,
/// 模型, 下载日志 (disabled: the protocol has no log download endpoint).
Future<void> showDshPlusSheet(
  BuildContext context, {
  required DshPlusMenuState state,
  required VoidCallback onOpenPermission,
  required VoidCallback onOpenModel,
  required VoidCallback onPickAttachment,
  VoidCallback? onCompress,
}) {
  final isDesktop =
      defaultTargetPlatform == TargetPlatform.macOS ||
      defaultTargetPlatform == TargetPlatform.windows ||
      defaultTargetPlatform == TargetPlatform.linux;
  final sheet = _DshPlusSheet(
    state: state,
    onOpenPermission: onOpenPermission,
    onOpenModel: onOpenModel,
    onPickAttachment: onPickAttachment,
    onCompress: onCompress,
  );
  if (isDesktop) {
    return showAppDialog<void>(
      context,
      child: Builder(
        builder: (dialogContext) => _DshPlusSheet(
          state: state,
          onOpenPermission: onOpenPermission,
          onOpenModel: onOpenModel,
          onPickAttachment: onPickAttachment,
          onCompress: onCompress,
          onClose: () => Navigator.of(dialogContext).maybePop(),
        ),
      ),
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
      onOpenModel: onOpenModel,
      onPickAttachment: onPickAttachment,
      onCompress: onCompress,
      isSheet: true,
      onClose: () => Navigator.of(sheetContext).maybePop(),
    ),
  );
}

class _DshPlusSheet extends StatelessWidget {
  const _DshPlusSheet({
    required this.state,
    required this.onOpenPermission,
    required this.onOpenModel,
    required this.onPickAttachment,
    this.onCompress,
    this.onClose,
    this.isSheet = false,
  });

  final DshPlusMenuState state;
  final VoidCallback onOpenPermission;
  final VoidCallback onOpenModel;
  final VoidCallback onPickAttachment;
  final VoidCallback? onCompress;
  final VoidCallback? onClose;

  /// Bottom-sheet chrome (drag handle) versus a dialog body.
  final bool isSheet;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final cs = Theme.of(context).colorScheme;
    final permission = (state.permissionLabel ?? '').trim();
    final model = (state.modelLabel ?? '').trim();
    final connectionProblem = (state.connectionProblem ?? '').trim();
    final body = Column(
      key: const ValueKey<String>('dsh-plus-sheet'),
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (isSheet) ...[
          const SizedBox(height: 8),
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
          const SizedBox(height: 10),
        ],
        Padding(
          padding: EdgeInsets.fromLTRB(18, isSheet ? 0 : 16, 18, 6),
          child: Text(
            l10n.dshPlusSheetTitle,
            style: TextStyle(fontSize: 17, fontWeight: AppFontWeights.emphasis),
          ),
        ),
        if (connectionProblem.isNotEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(18, 0, 18, 8),
            child: Text(
              connectionProblem,
              style: TextStyle(fontSize: 12, color: cs.error),
            ),
          ),
        Flexible(
          child: ListView(
            shrinkWrap: true,
            padding: const EdgeInsets.fromLTRB(14, 0, 14, 12),
            children: [
              _DshPlusSectionLabel(
                key: const ValueKey<String>('dsh-plus-section-add'),
                title: l10n.dshPlusSectionAdd,
              ),
              ToolsSheetRow(
                key: const ValueKey<String>('dsh-plus-attach'),
                icon: Lucide.Paperclip,
                label: l10n.dshPlusAttachFile,
                subtitle: l10n.dshPlusAttachFileSubtitle,
                onTap: () {
                  onClose?.call();
                  onPickAttachment();
                },
                trailing: ToolsSheetRow.chevron(context),
              ),
              _DshPlusDisabledRow(
                key: const ValueKey<String>('dsh-plus-goal'),
                icon: Lucide.MapPin,
                label: l10n.dshPlusTarget,
              ),
              _DshPlusDisabledRow(
                icon: Lucide.ListChecks,
                label: l10n.dshPlusPlan,
              ),
              _DshPlusDisabledRow(
                key: const ValueKey<String>('dsh-plus-feedback'),
                icon: Lucide.MessageCircleWarning,
                label: l10n.dshPlusFeedback,
              ),
              const SizedBox(height: 6),
              _DshPlusSectionLabel(
                key: const ValueKey<String>('dsh-plus-section-commands'),
                title: l10n.dshPlusSectionCommands,
              ),
              ToolsSheetRow(
                key: const ValueKey<String>('dsh-plus-compact'),
                icon: Lucide.Minimize2,
                label: l10n.dshPlusCompress,
                subtitle: state.compactCommandAvailable
                    ? null
                    : l10n.dshPlusWireMissing,
                onTap: state.compactCommandAvailable
                    ? () {
                        onClose?.call();
                        onCompress?.call();
                      }
                    : null,
              ),
              ToolsSheetRow(
                key: const ValueKey<String>('dsh-plus-permission'),
                icon: Lucide.Shield,
                label: l10n.dshPlusPermission,
                subtitle: permission.isEmpty ? null : permission,
                onTap: () {
                  onClose?.call();
                  onOpenPermission();
                },
              ),
              ToolsSheetRow(
                key: const ValueKey<String>('dsh-plus-model'),
                icon: Lucide.Boxes,
                label: l10n.dshPlusModel,
                subtitle: model.isEmpty ? null : model,
                onTap: () {
                  onClose?.call();
                  onOpenModel();
                },
              ),
              _DshPlusDisabledRow(
                key: const ValueKey<String>('dsh-plus-download-log'),
                icon: Lucide.Download,
                label: l10n.dshPlusDownloadLog,
              ),
            ],
          ),
        ),
      ],
    );
    if (!isSheet) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: body,
      );
    }
    return SafeArea(
      top: false,
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.sizeOf(context).height * 0.78,
        ),
        child: body,
      ),
    );
  }
}

class _DshPlusSectionLabel extends StatelessWidget {
  const _DshPlusSectionLabel({super.key, required this.title});

  final String title;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 6, 4, 4),
      child: Text(
        title,
        style: TextStyle(
          fontSize: 11.5,
          fontWeight: AppFontWeights.semibold,
          letterSpacing: 0.3,
          color: cs.onSurface.withValues(alpha: 0.45),
        ),
      ),
    );
  }
}

/// A row whose capability the protocol does not expose. Rendered disabled with
/// the honest reason as its subtitle — no tap handler at all.
class _DshPlusDisabledRow extends StatelessWidget {
  const _DshPlusDisabledRow({
    super.key,
    required this.icon,
    required this.label,
  });

  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return ToolsSheetRow(
      icon: icon,
      label: label,
      subtitle: l10n.dshPlusWireMissing,
      onTap: null,
    );
  }
}
