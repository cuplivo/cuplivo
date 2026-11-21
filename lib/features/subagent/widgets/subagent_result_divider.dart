import 'package:flutter/material.dart';

import '../../../core/models/message_part.dart';
import '../../../icons/lucide_adapter.dart';
import '../../../l10n/app_localizations.dart';

/// The one line a finished subagent leaves in its parent's timeline.
///
/// A result is stored as a `user` message so the parent model reads an ordinary
/// turn; a reader must not see it as something they typed, so it draws as the
/// same 28px divider the timeline already uses for context operations instead of
/// as a bubble. The wording is a state plus the job's name — the conclusion
/// itself stays in the child conversation, one tap away, because the user does
/// not read a subagent's essay in the parent.
class SubagentResultDivider extends StatelessWidget {
  const SubagentResultDivider({super.key, required this.part, this.onTap});

  final SubagentResultPart part;

  /// Opens the child conversation. Null draws no chevron: a control that looks
  /// tappable and is not is worse than a plain line.
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final cs = Theme.of(context).colorScheme;
    final outcome = part.outcome;
    final label = (part.label ?? '').trim();
    final word = _word(l10n, outcome);
    final text = label.isEmpty ? word : '$word · $label';
    final failed = outcome == 'failed';
    final interactive = onTap != null;

    final row = SizedBox(
      height: 28,
      child: Row(
        children: [
          Expanded(
            child: Divider(
              height: 1,
              thickness: 1,
              color: cs.outlineVariant.withValues(alpha: .6),
            ),
          ),
          Flexible(
            child: Container(
              constraints: const BoxConstraints(maxWidth: 320),
              padding: const EdgeInsets.symmetric(horizontal: 6),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    _icon(outcome),
                    size: 14,
                    color: failed
                        ? cs.error
                        : cs.onSurface.withValues(alpha: .55),
                  ),
                  const SizedBox(width: 6),
                  Flexible(
                    child: Text(
                      text,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 12.5,
                        color: cs.onSurface.withValues(alpha: .6),
                      ),
                    ),
                  ),
                  if (interactive) ...[
                    const SizedBox(width: 4),
                    Icon(
                      Lucide.ChevronRight,
                      size: 13,
                      color: cs.onSurface.withValues(alpha: .45),
                    ),
                  ],
                ],
              ),
            ),
          ),
          Expanded(
            child: Divider(
              height: 1,
              thickness: 1,
              color: cs.outlineVariant.withValues(alpha: .6),
            ),
          ),
        ],
      ),
    );
    if (onTap == null) return row;
    return InkWell(
      borderRadius: BorderRadius.circular(6),
      onTap: onTap,
      child: row,
    );
  }

  static String _word(
    AppLocalizations l10n,
    String? outcome,
  ) => switch (outcome) {
    'failed' => l10n.subagentResultFailed,
    'cancelled' => l10n.subagentResultCancelled,
    'interrupted' => l10n.subagentResultInterrupted,
    // `completed`, and anything a future version wrote: a stale value must read
    // as "it is over", never as an error.
    _ => l10n.subagentResultCompleted,
  };

  static IconData _icon(String? outcome) => switch (outcome) {
    'failed' => Lucide.CircleAlert,
    'cancelled' => Lucide.CircleX,
    'interrupted' => Lucide.Power,
    _ => Lucide.Check,
  };
}
