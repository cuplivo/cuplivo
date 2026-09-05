import 'package:flutter/material.dart';

import '../../../icons/lucide_adapter.dart';
import '../../../l10n/app_localizations.dart';
import '../../../theme/app_font_weights.dart';
import 'ios_tactile.dart';

/// Persistent inline status row for sub-agent delegation, shown while the
/// handoff tool is enabled (not dismissible): error-tinted with a
/// "Set up" action when zero targets exist, neutral count otherwise.
/// Tapping opens the dedicated delegation config page.
class SubagentDelegationStatusRow extends StatelessWidget {
  const SubagentDelegationStatusRow({
    super.key,
    required this.count,
    required this.onTap,
  });

  /// Number of valid delegation targets (`LocalToolsService.handoffTargets`).
  final int count;

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final cs = Theme.of(context).colorScheme;
    final empty = count == 0;
    return IosCardPress(
      borderRadius: BorderRadius.circular(12),
      baseColor: empty ? cs.error.withValues(alpha: 0.06) : cs.surface,
      duration: const Duration(milliseconds: 200),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      onTap: onTap,
      child: Row(
        children: [
          SizedBox(
            width: 34,
            child: Icon(
              empty ? Lucide.TriangleAlert : Lucide.ListChecks,
              size: 18,
              color: empty ? cs.error : cs.primary,
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              l10n.subagentTargetStatus(count),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 13,
                fontWeight: empty
                    ? AppFontWeights.semibold
                    : AppFontWeights.regular,
                color: empty ? cs.error : cs.onSurface.withValues(alpha: 0.62),
              ),
            ),
          ),
          if (empty) ...[
            const SizedBox(width: 8),
            Text(
              l10n.subagentGoSetup,
              style: TextStyle(
                fontSize: 12.5,
                fontWeight: AppFontWeights.semibold,
                color: cs.primary,
              ),
            ),
          ] else ...[
            const SizedBox(width: 4),
            Icon(
              Lucide.ChevronRight,
              size: 16,
              color: cs.onSurface.withValues(alpha: 0.35),
            ),
          ],
        ],
      ),
    );
  }
}
