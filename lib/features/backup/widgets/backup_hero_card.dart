import 'package:flutter/material.dart';

import '../../../icons/lucide_adapter.dart';
import '../../../l10n/app_localizations.dart';
import '../../../core/services/haptics.dart';
import '../../../shared/widgets/segmented_toggle.dart';
import '../../../theme/app_font_weights.dart';
import '../../../theme/app_semantic_colors.dart';
import 'backup_reminder_helpers.dart';

/// Where the next backup should go. Used by the hero card on both shells.
enum BackupDestination { local, webdav, s3 }

/// Status + primary action card shown at the top of the backup page / pane.
///
/// Answers "did I back up, where do I back up" in one look: a status headline
/// with the last-backup detail, a destination segmented control (with
/// readiness dots: green = configured, grey = unconfigured), and ONE row with
/// the full lifecycle on the selected destination — 立即备份 (filled) /
/// 增量备份 (outlined) / 从备份恢复 (outlined).
///
/// The reminder-due state deliberately does NOT swap this card — it only
/// adds a row on the reminder card (and the side drawer entry grows a second
/// line).
class BackupHeroCard extends StatelessWidget {
  const BackupHeroCard({
    super.key,
    required this.destination,
    required this.onDestinationChanged,
    required this.onBackupNow,
    required this.onIncremental,
    required this.onRestore,
    required this.onConfigureWebDav,
    required this.onConfigureS3,
    this.busy = false,
    this.webdavEnabled = false,
    this.s3Enabled = false,
    this.lastBackupAt,
  });

  final BackupDestination destination;
  final ValueChanged<BackupDestination> onDestinationChanged;
  final VoidCallback onBackupNow;
  final VoidCallback onIncremental;
  final VoidCallback onRestore;
  final VoidCallback onConfigureWebDav;
  final VoidCallback onConfigureS3;
  final bool busy;
  final bool webdavEnabled;
  final bool s3Enabled;
  final DateTime? lastBackupAt;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final cs = Theme.of(context).colorScheme;

    final statusIcon = Icon(
      Lucide.Shield,
      size: 22,
      color: cs.onSurface.withValues(alpha: 0.55),
    );
    final statusTint = cs.onSurface.withValues(alpha: 0.45);
    final String title;
    final String detail;
    if (lastBackupAt == null) {
      title = l10n.backupHeroNoTitle;
      detail = l10n.backupHeroNoDetail;
    } else {
      title = l10n.backupHeroHealthyTitle;
      final time = backupReminderDateTimeLabel(context, lastBackupAt);
      // Deliberately no channel here: the hero only knows the last back-up
      // TIME, not WHICH channel last succeeded. Showing the currently
      // selected destination (or any persisted channel) would claim a success
      // that never happened.
      detail = l10n.backupHeroLastBackup(time);
    }

    // Channel readiness dots: green = configured, grey = unconfigured —
    // the same dot language as the restore/channel rows (local is always on).
    final dotGrey = cs.onSurface.withValues(alpha: 0.25);
    final dots = <Color?>[
      context.appColors.success,
      webdavEnabled ? context.appColors.success : dotGrey,
      s3Enabled ? context.appColors.success : dotGrey,
    ];

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: cs.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: cs.outlineVariant.withValues(alpha: 0.10)),
        boxShadow: [
          BoxShadow(
            color: cs.shadow.withValues(alpha: 0.04),
            blurRadius: 12,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: 44,
                height: 44,
                decoration: BoxDecoration(
                  color: statusTint.withValues(alpha: 0.10),
                  borderRadius: BorderRadius.circular(12),
                ),
                alignment: Alignment.center,
                child: statusIcon,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: AppFontWeights.semibold,
                        color: cs.onSurface.withValues(alpha: 0.92),
                      ),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      detail,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 12.5,
                        height: 1.3,
                        color: cs.onSurface.withValues(alpha: 0.55),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          SegmentedToggle(
            options: [l10n.backupDestLocal, 'WebDAV', 'S3'],
            value: destination.index,
            dots: dots,
            onChanged: busy
                ? (_) {}
                : (i) {
                    final d = BackupDestination.values[i];
                    switch (d) {
                      case BackupDestination.local:
                        onDestinationChanged(d);
                      case BackupDestination.webdav:
                        if (!webdavEnabled) {
                          onConfigureWebDav();
                        } else {
                          onDestinationChanged(d);
                        }
                      case BackupDestination.s3:
                        if (!s3Enabled) {
                          onConfigureS3();
                        } else {
                          onDestinationChanged(d);
                        }
                    }
                  },
          ),
          const SizedBox(height: 10),
          // One row, three actions: the full lifecycle — write (full),
          // write (delta), read (restore) — all on the selected destination.
          Row(
            children: [
              Expanded(
                child: _HeroActionButton(
                  label: l10n.backupPageBackupNow,
                  filled: true,
                  busy: busy,
                  onTap: onBackupNow,
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: _HeroActionButton(
                  label: l10n.backupPageIncrementalTitle,
                  filled: false,
                  busy: busy,
                  onTap: onIncremental,
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: _HeroActionButton(
                  label: l10n.backupPageRestoreFromBackup,
                  filled: false,
                  busy: busy,
                  onTap: onRestore,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _HeroActionButton extends StatefulWidget {
  const _HeroActionButton({
    required this.label,
    required this.filled,
    required this.busy,
    required this.onTap,
  });
  final String label;
  final bool filled;
  final bool busy;
  final VoidCallback onTap;
  @override
  State<_HeroActionButton> createState() => _HeroActionButtonState();
}

class _HeroActionButtonState extends State<_HeroActionButton> {
  bool _pressed = false;
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final disabled = widget.busy;
    final fill = widget.filled;
    final Color bg;
    final Color border;
    final Color text;
    if (fill) {
      bg = disabled
          ? cs.primary.withValues(alpha: 0.45)
          : (_hovered ? cs.primary.withValues(alpha: 0.92) : cs.primary);
      border = Colors.transparent;
      text = cs.onPrimary;
    } else {
      bg = _hovered ? cs.primary.withValues(alpha: 0.08) : Colors.transparent;
      border = cs.primary.withValues(alpha: 0.5);
      text = disabled ? cs.primary.withValues(alpha: 0.4) : cs.primary;
    }
    return MouseRegion(
      cursor: disabled ? MouseCursor.defer : SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTapDown: disabled ? null : (_) => setState(() => _pressed = true),
        onTapUp: disabled ? null : (_) => setState(() => _pressed = false),
        onTapCancel: disabled ? null : () => setState(() => _pressed = false),
        onTap: disabled
            ? null
            : () {
                Haptics.soft();
                widget.onTap();
              },
        child: AnimatedScale(
          scale: _pressed ? 0.97 : 1.0,
          duration: const Duration(milliseconds: 110),
          curve: Curves.easeOutCubic,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 160),
            curve: Curves.easeOutCubic,
            padding: const EdgeInsets.symmetric(vertical: 12),
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: bg,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: border, width: 1),
            ),
            child: Text(
              widget.label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 14,
                color: text,
                fontWeight: AppFontWeights.semibold,
              ),
            ),
          ),
        ),
      ),
    );
  }
}
