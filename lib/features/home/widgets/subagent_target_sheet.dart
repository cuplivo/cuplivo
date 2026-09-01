import 'package:flutter/material.dart';

import '../../../core/models/assistant.dart';
import '../../../icons/lucide_adapter.dart';
import '../../../l10n/app_localizations.dart';
import '../../../shared/widgets/ios_tactile.dart';
import '../../../theme/app_font_weights.dart';
import '../../../utils/platform_utils.dart';

bool _sheetOpen = false;

/// Target list sheet (mobile bottom sheet / desktop centered dialog) for
/// sub-agent delegation: names + delegation IDs + purposes of all assistants
/// currently delegatable as sub-agents. Re-entrant calls while a
/// sheet/dialog is open are ignored (mirrors the workspace bind sheet).
Future<void> showSubagentTargetSheet(
  BuildContext context,
  List<Assistant> targets,
) async {
  if (_sheetOpen) return;
  _sheetOpen = true;
  try {
    final title = AppLocalizations.of(context)!.subagentTargetListTitle;
    if (PlatformUtils.isDesktop) {
      await showDialog<void>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: Text(title),
          content: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 420, maxHeight: 480),
            child: _SubagentTargetList(targets: targets),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: Text(AppLocalizations.of(ctx)!.mcpPageCancel),
            ),
          ],
        ),
      );
    } else {
      await showModalBottomSheet<void>(
        context: context,
        isScrollControlled: true,
        backgroundColor: Theme.of(context).colorScheme.surface,
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
        ),
        builder: (ctx) => SafeArea(
          top: false,
          child: SingleChildScrollView(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 10, 16, 20),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Center(
                    child: Container(
                      width: 40,
                      height: 4,
                      decoration: BoxDecoration(
                        color: Theme.of(
                          ctx,
                        ).colorScheme.outlineVariant.withValues(alpha: 0.6),
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                  ),
                  const SizedBox(height: 14),
                  Text(
                    title,
                    style: TextStyle(
                      fontSize: 16,
                      fontWeight: AppFontWeights.semibold,
                    ),
                  ),
                  const SizedBox(height: 12),
                  _SubagentTargetList(targets: targets),
                ],
              ),
            ),
          ),
        ),
      );
    }
  } finally {
    _sheetOpen = false;
  }
}

class _SubagentTargetList extends StatelessWidget {
  const _SubagentTargetList({required this.targets});

  final List<Assistant> targets;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final cs = Theme.of(context).colorScheme;
    if (targets.isEmpty) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 16),
        child: Center(
          child: Text(
            l10n.subagentTargetListEmpty,
            style: TextStyle(
              fontSize: 13,
              color: cs.onSurface.withValues(alpha: 0.6),
            ),
          ),
        ),
      );
    }
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (final target in targets) ...[
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(Lucide.Bot, size: 18, color: cs.primary),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Flexible(
                            child: Text(
                              target.name,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontSize: 14,
                                fontWeight: FontWeight.w600,
                                color: cs.onSurface,
                              ),
                            ),
                          ),
                          const SizedBox(width: 8),
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 8,
                              vertical: 2,
                            ),
                            decoration: BoxDecoration(
                              color: cs.primary.withValues(alpha: 0.10),
                              borderRadius: BorderRadius.circular(999),
                              border: Border.all(
                                color: cs.primary.withValues(alpha: 0.35),
                              ),
                            ),
                            child: Text(
                              target.handoffId ?? '',
                              style: TextStyle(
                                fontSize: 11,
                                color: cs.primary,
                                fontWeight: AppFontWeights.semibold,
                              ),
                            ),
                          ),
                        ],
                      ),
                      if ((target.handoffDescription ?? '').isNotEmpty) ...[
                        const SizedBox(height: 3),
                        Text(
                          target.handoffDescription!,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 12,
                            height: 1.25,
                            color: cs.onSurface.withValues(alpha: 0.62),
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ],
            ),
          ),
        ],
      ],
    );
  }
}

/// Mobile / settings-page hint shown when the user enables Sub-agent
/// Delegation with no delegatable targets: explains the missing piece and
/// offers a 「去设置」 jump to the assistant list.
void showSubagentNoTargetSnackbar(
  BuildContext context, {
  required VoidCallback onGoSetup,
}) {
  final messenger = ScaffoldMessenger.of(context);
  final l10n = AppLocalizations.of(context)!;
  messenger.hideCurrentSnackBar();
  messenger.showSnackBar(
    SnackBar(
      content: Text(l10n.subagentNoTargetHint),
      duration: const Duration(seconds: 6),
      behavior: SnackBarBehavior.floating,
      showCloseIcon: true,
      action: SnackBarAction(label: l10n.subagentGoSetup, onPressed: onGoSetup),
    ),
  );
}

/// Desktop inline hint row (Tools Hub popover): compact, dismissible,
/// shown under the Sub-agent Delegation row when enabled with zero targets.
class SubagentNoTargetHintRow extends StatelessWidget {
  const SubagentNoTargetHintRow({
    super.key,
    required this.onGoSetup,
    required this.onDismiss,
  });

  final VoidCallback onGoSetup;
  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final cs = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Expanded(
            child: Text(
              l10n.subagentNoTargetHint,
              style: TextStyle(
                fontSize: 11.5,
                height: 1.25,
                color: cs.error.withValues(alpha: 0.85),
              ),
            ),
          ),
          const SizedBox(width: 8),
          GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: onGoSetup,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              child: Text(
                l10n.subagentGoSetup,
                style: TextStyle(
                  fontSize: 11.5,
                  fontWeight: AppFontWeights.semibold,
                  color: cs.primary,
                ),
              ),
            ),
          ),
          const SizedBox(width: 4),
          IosIconButton(
            icon: Lucide.X,
            size: 13,
            minSize: 26,
            padding: const EdgeInsets.all(4),
            color: cs.onSurface.withValues(alpha: 0.5),
            semanticLabel: l10n.mcpPageCancel,
            onTap: onDismiss,
          ),
        ],
      ),
    );
  }
}
