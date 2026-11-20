import 'package:flutter/material.dart';

import 'package:Cuplivo/features/home/services/context_usage_service.dart';
import 'package:Cuplivo/features/settings/widgets/custom_theme_widgets.dart';
import 'package:Cuplivo/l10n/app_localizations.dart';
import 'package:Cuplivo/shared/widgets/context_usage_details.dart';
import 'package:Cuplivo/theme/app_font_weights.dart';

/// Shows the DSH context-pressure sheet.
///
/// The sheet reuses the local chat's summary header and stacked bar; its bar has
/// exactly two truthful segments (used / free window) because the Host exposes
/// one pressure number, not a bucket breakdown.
Future<void> showDshContextUsageSheet(
  BuildContext context, {
  required ContextUsageSnapshot snapshot,
}) {
  return showAppDialog<void>(
    context,
    child: DshContextUsageSheet(snapshot: snapshot),
  );
}

class DshContextUsageSheet extends StatelessWidget {
  const DshContextUsageSheet({super.key, required this.snapshot});

  final ContextUsageSnapshot snapshot;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final cs = Theme.of(context).colorScheme;
    return Column(
      key: const ValueKey<String>('dsh-context-usage-sheet'),
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        AppDialogHeader(title: l10n.contextUsageTitle),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                contextUsageSummaryText(l10n, snapshot),
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: AppFontWeights.medium,
                  color: cs.onSurface.withValues(alpha: 0.78),
                ),
              ),
              const SizedBox(height: 2),
              Text(
                contextUsageStateLabel(l10n, snapshot),
                style: TextStyle(
                  fontSize: 11,
                  color: cs.onSurface.withValues(alpha: 0.45),
                ),
              ),
              const SizedBox(height: 10),
              ContextUsageStackedBar(snapshot: snapshot),
              const SizedBox(height: 10),
              Row(
                children: [
                  _DshUsageLegendDot(
                    color: cs.primary,
                    label: l10n.contextUsageBucketUsed,
                  ),
                  const SizedBox(width: 14),
                  _DshUsageLegendDot(
                    color: ContextUsagePalette.track(cs),
                    label: l10n.contextUsageFreeSpace,
                  ),
                ],
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _DshUsageLegendDot extends StatelessWidget {
  const _DshUsageLegendDot({required this.color, required this.label});

  final Color color;
  final String label;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 8,
          height: 8,
          decoration: BoxDecoration(color: color, shape: BoxShape.circle),
        ),
        const SizedBox(width: 6),
        Text(
          label,
          style: TextStyle(
            fontSize: 11.5,
            fontWeight: AppFontWeights.regular,
            color: cs.onSurface.withValues(alpha: 0.65),
          ),
        ),
      ],
    );
  }
}
