import 'package:flutter/material.dart';

import '../../../l10n/app_localizations.dart';
import '../../../theme/app_font_weights.dart';

/// Warning badge shown on a knowledge base that no assistant binds: such a base
/// can never be retrieved, which is otherwise a silent failure.
class KnowledgeUnboundChip extends StatelessWidget {
  const KnowledgeUnboundChip({super.key});

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final cs = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: cs.error.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(
        l10n.knowledgeUnboundChip,
        style: TextStyle(
          fontSize: 12,
          fontWeight: AppFontWeights.medium,
          color: cs.error,
        ),
      ),
    );
  }
}
