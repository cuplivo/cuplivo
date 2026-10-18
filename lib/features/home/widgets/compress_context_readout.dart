import 'package:flutter/material.dart';

import '../../../core/models/compress_context_options.dart';
import '../../../core/utils/token_format.dart';
import '../../../icons/lucide_adapter.dart';
import '../../../l10n/app_localizations.dart';
import '../../../theme/app_font_weights.dart';
import '../../../theme/app_semantic_colors.dart';

/// What a compression costs now and after, in the shape the image editor uses
/// for a re-encode: both sides stacked (rounds above tokens) and the reduction
/// over the arrow between them.
///
/// The percentage is the midpoint of the summary band — one readable number —
/// while the right-hand side keeps the band itself, which is the part that is
/// genuinely uncertain.
class CompressContextReadout extends StatelessWidget {
  const CompressContextReadout({
    super.key,
    required this.split,
    required this.rounds,
    required this.keptRounds,
  });

  final CompressContextSplit split;

  /// Rounds (user messages) in the conversation being compressed.
  final int rounds;

  /// Rounds that stay verbatim.
  final int keptRounds;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final cs = Theme.of(context).colorScheme;
    if (split.totalTokens <= 0) return const SizedBox.shrink();
    final muted = cs.onSurfaceVariant;
    return Padding(
      padding: const EdgeInsets.only(top: 12),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Flexible(
            child: _ReadoutSide(
              headline: l10n.compressContextReadoutRounds(rounds),
              value: l10n.compressContextReadoutTokens(
                formatTokenCount(split.totalTokens),
              ),
              alignEnd: true,
              color: muted,
            ),
          ),
          const SizedBox(width: 12),
          _ReadoutArrow(
            label: l10n.compressContextReadoutReduction(split.reductionPercent),
          ),
          const SizedBox(width: 12),
          Flexible(
            child: _ReadoutSide(
              headline: l10n.compressContextReadoutKeptRounds(keptRounds),
              value: l10n.compressContextReadoutTokensBand(
                formatTokenCount(split.minResultTokens),
                formatTokenCount(split.maxResultTokens),
              ),
              alignEnd: false,
              color: cs.onSurface,
            ),
          ),
        ],
      ),
    );
  }
}

class _ReadoutSide extends StatelessWidget {
  const _ReadoutSide({
    required this.headline,
    required this.value,
    required this.alignEnd,
    required this.color,
  });

  final String headline;
  final String value;
  final bool alignEnd;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final align = alignEnd ? TextAlign.end : TextAlign.start;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: alignEnd
          ? CrossAxisAlignment.end
          : CrossAxisAlignment.start,
      children: [
        Text(
          headline,
          textAlign: align,
          style: TextStyle(
            fontSize: 12,
            fontWeight: AppFontWeights.medium,
            color: color,
          ),
        ),
        const SizedBox(height: 2),
        Text(
          value,
          textAlign: align,
          style: TextStyle(fontSize: 12, color: color.withValues(alpha: 0.75)),
        ),
      ],
    );
  }
}

/// The arrow between the two sides, with the reduction above it.
class _ReadoutArrow extends StatelessWidget {
  const _ReadoutArrow({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          label,
          style: TextStyle(
            fontSize: 11,
            fontWeight: AppFontWeights.semibold,
            color: context.appColors.success,
          ),
        ),
        Icon(
          Directionality.of(context) == TextDirection.rtl
              ? Lucide.ArrowLeft
              : Lucide.ArrowRight,
          size: 16,
          color: cs.onSurfaceVariant,
        ),
      ],
    );
  }
}
