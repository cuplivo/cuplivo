import 'package:flutter/material.dart';

import '../../../core/services/sync/sync_models.dart';
import '../../../icons/lucide_adapter.dart';
import '../../../l10n/app_localizations.dart';
import '../../../shared/utils/format_bytes.dart';
import '../../../theme/app_semantic_colors.dart';
import '../sync_messages.dart';

/// The last session's outcome as a card of its own: counters become chips,
/// sentence-shaped warnings get their own rows, and a session that failed gets
/// a tinted banner whose color says whether anything is wrong (offline and
/// refusals are routine; only real failures are red).
///
/// Replaces the single " · "-joined line: that line could not say *which*
/// number mattered, and at more than three parts it stopped being readable at
/// all.
class SyncReportBreakdown extends StatelessWidget {
  const SyncReportBreakdown({
    super.key,
    required this.report,
    this.onPairAgain,
  });

  final SyncPeerReport report;

  /// Reopens the pairing dialog for the peer this report belongs to. The card
  /// supplies it, because only the card knows the peer and its remembered
  /// address: a refusal that says "pair again" should come with the gesture.
  final VoidCallback? onPairAgain;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final cs = Theme.of(context).colorScheme;
    if (report.refusal != null) {
      // The pairing is gone on the other side — unpaired there, reset there, or
      // a re-pairing only one device finished. Nothing this device can do on its
      // own repairs it, so the banner carries the one action that does.
      final needsPairing = report.refusal == SyncRefusalReason.notPaired;
      return _OutcomeBanner(
        icon: Lucide.TriangleAlert,
        text: syncRefusalMessage(l10n, report.refusal!),
        color: context.appColors.warning,
        action: needsPairing && onPairAgain != null
            ? TextButton(
                onPressed: onPairAgain,
                style: TextButton.styleFrom(
                  visualDensity: VisualDensity.compact,
                  foregroundColor: cs.primary,
                ),
                child: Text(l10n.lanSyncPairAgain),
              )
            : null,
      );
    }
    if (!report.success) {
      // A peer that did not answer is the common case on a LAN — asleep, on
      // another network — so it is a soft note, not a failure. The manual sync
      // press still gets the actionable "rescan or edit the address" line in
      // its snackbar.
      if (report.failure == SyncFailureReason.unreachable) {
        return _OutcomeBanner(
          icon: Lucide.CloudOff,
          text: l10n.lanSyncReportPeerOffline,
          color: context.appColors.warning,
        );
      }
      return _OutcomeBanner(
        icon: Lucide.TriangleAlert,
        text: syncFailureMessage(l10n, report.failure),
        color: cs.error,
      );
    }
    return _SuccessBreakdown(report: report);
  }
}

/// The success face: a wrap of counter chips, then one row per warning.
class _SuccessBreakdown extends StatelessWidget {
  const _SuccessBreakdown({required this.report});

  final SyncPeerReport report;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final cs = Theme.of(context).colorScheme;

    final movedAnything =
        report.sent > 0 ||
        report.received > 0 ||
        report.upsertedMessages > 0 ||
        report.deletedMessages > 0 ||
        report.deletedConversations > 0 ||
        report.entityRows > 0 ||
        report.preferenceRows > 0 ||
        report.blobsMoved > 0 ||
        report.skillsUpdated > 0;

    // A withheld item is not "up to date": the blob that never arrived and the
    // conversation this device deferred are data this card does not hold, and
    // the sentence rows below name them. The chip must not claim currency over
    // those rows, so it appears only when nothing moved *and* nothing is owed.
    final withheld = report.deferred > 0 || report.blobsMissing > 0;

    final chips = <Widget>[
      if (!movedAnything && !withheld)
        _ReportChip(
          icon: Lucide.CheckCircle,
          text: l10n.lanSyncUpToDate,
          iconColor: context.appColors.success,
          background: context.appColors.success.withValues(alpha: 0.1),
        )
      else ...[
        if (report.sent > 0)
          _ReportChip(
            icon: Lucide.ArrowUp,
            text: l10n.lanSyncReportSent(report.sent),
            iconColor: cs.primary,
          ),
        if (report.received > 0)
          _ReportChip(
            icon: Lucide.ArrowDown,
            text: l10n.lanSyncReportReceived(report.received),
            iconColor: cs.primary,
          ),
        if (report.upsertedMessages > 0)
          _ReportChip(
            icon: Lucide.MessageSquare,
            text: l10n.lanSyncReportMessagesUpserted(report.upsertedMessages),
          ),
        if (report.deletedMessages > 0)
          _ReportChip(
            icon: Lucide.Minus,
            text: l10n.lanSyncReportMessagesDeleted(report.deletedMessages),
          ),
        if (report.deletedConversations > 0)
          _ReportChip(
            icon: Lucide.Trash,
            text: l10n.lanSyncReportConversationsDeleted(
              report.deletedConversations,
            ),
          ),
        if (report.entityRows > 0)
          _ReportChip(
            icon: Lucide.Database,
            text: l10n.lanSyncReportEntities(report.entityRows),
          ),
        if (report.preferenceRows > 0)
          _ReportChip(
            icon: Lucide.SlidersHorizontal,
            text: l10n.lanSyncReportPreferences(report.preferenceRows),
          ),
        if (report.blobsMoved > 0)
          _ReportChip(
            icon: Lucide.Download,
            text: report.blobBytes > 0
                ? l10n.lanSyncReportBlobsWithSize(
                    report.blobsMoved,
                    formatBytes(report.blobBytes),
                  )
                : l10n.lanSyncReportBlobs(report.blobsMoved),
          ),
        if (report.skillsUpdated > 0)
          _ReportChip(
            icon: Lucide.Wrench,
            text: l10n.lanSyncReportSkills(report.skillsUpdated),
          ),
      ],
    ];

    // "Nothing silent": the discarded local edit, the blob that never arrived
    // and the divergent clock are sentences, so they get rows of their own
    // rather than drowning in a chip.
    final warnings = <(IconData, String)>[
      if (report.skillConflicts > 0)
        (
          Lucide.TriangleAlert,
          l10n.lanSyncReportSkillConflicts(report.skillConflicts),
        ),
      if (report.entityRowsLost + report.preferencesLost > 0)
        (
          Lucide.TriangleAlert,
          l10n.lanSyncReportRowsLost(
            report.entityRowsLost + report.preferencesLost,
          ),
        ),
      if (report.blobsMissing > 0)
        (
          Lucide.FileQuestion,
          l10n.lanSyncReportBlobsMissing(report.blobsMissing),
        ),
      if (report.deferred > 0)
        (Lucide.Hourglass, l10n.lanSyncReportDeferred(report.deferred)),
      if (report.clockSkewMs != null)
        (
          Lucide.Timer,
          l10n.lanSyncReportClockSkew(
            (report.clockSkewMs!.abs() / 60000).round(),
          ),
        ),
    ];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Wrap(spacing: 6, runSpacing: 6, children: chips),
        for (final (icon, text) in warnings)
          Padding(
            padding: const EdgeInsets.only(top: 5),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(icon, size: 13, color: context.appColors.warning),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    text,
                    style: TextStyle(
                      fontSize: 12,
                      color: cs.onSurface.withValues(alpha: 0.7),
                    ),
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }
}

class _ReportChip extends StatelessWidget {
  const _ReportChip({
    required this.icon,
    required this.text,
    this.iconColor,
    this.background,
  });

  final IconData icon;
  final String text;
  final Color? iconColor;
  final Color? background;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: background ?? cs.onSurface.withValues(alpha: 0.05),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            icon,
            size: 13,
            color: iconColor ?? cs.onSurface.withValues(alpha: 0.6),
          ),
          const SizedBox(width: 5),
          Text(
            text,
            style: TextStyle(
              fontSize: 12,
              color: cs.onSurface.withValues(alpha: 0.8),
            ),
          ),
        ],
      ),
    );
  }
}

/// One tinted row for an outcome that is not a success: the icon and the tint
/// carry the severity, the text stays a full localized sentence, and [action]
/// is the repair when one exists.
class _OutcomeBanner extends StatelessWidget {
  const _OutcomeBanner({
    required this.icon,
    required this.text,
    required this.color,
    this.action,
  });

  final IconData icon;
  final String text;
  final Color color;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    // A trailing button gives the row a taller visual line than its text, so
    // the icon and the sentence drop by the same amount to stay optically
    // centred against it.
    final inset = action == null ? 0.0 : 3.0;
    return Container(
      padding: EdgeInsets.fromLTRB(10, 8, action == null ? 10 : 4, 8),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: EdgeInsets.only(top: inset),
            child: Icon(icon, size: 15, color: color),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Padding(
              padding: EdgeInsets.only(top: inset),
              child: Text(
                text,
                style: TextStyle(
                  fontSize: 12,
                  color: cs.onSurface.withValues(alpha: 0.8),
                ),
              ),
            ),
          ),
          if (action != null) ...[const SizedBox(width: 4), action!],
        ],
      ),
    );
  }
}
