import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:Cuplivo/theme/app_semantic_colors.dart';

import '../animations/widgets.dart';
import '../../core/services/sync/restore_progress.dart';
import '../../l10n/app_localizations.dart';
import '../utils/format_bytes.dart';

class LoadingDialogCard extends StatelessWidget {
  const LoadingDialogCard({super.key, this.label});

  final String? label;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final hasLabel = label != null && label!.trim().isNotEmpty;

    return Center(
      child: TweenAnimationBuilder<double>(
        tween: Tween(begin: 0.96, end: 1),
        duration: kAnimSlow,
        curve: Curves.easeOutCubic,
        builder: (context, value, child) {
          final opacity = ((value - 0.96) / 0.04).clamp(0.0, 1.0).toDouble();
          return Opacity(
            opacity: opacity,
            child: Transform.scale(scale: value, child: child),
          );
        },
        child: Material(
          color: Colors.transparent,
          child: ConstrainedBox(
            constraints: const BoxConstraints(minWidth: 96, maxWidth: 240),
            child: Container(
              decoration: BoxDecoration(
                color: context.overlaySurface,
                borderRadius: BorderRadius.circular(14),
                border: Border.all(color: context.appColors.hairline),
              ),
              child: Padding(
                padding: EdgeInsets.fromLTRB(
                  20,
                  hasLabel ? 16 : 18,
                  20,
                  hasLabel ? 16 : 18,
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const CupertinoActivityIndicator(radius: 16),
                    if (hasLabel) ...[
                      const SizedBox(height: 12),
                      Text(
                        label!,
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          fontSize: 14,
                          color: cs.onSurface.withValues(alpha: 0.8),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Mask content for an in-progress LAN-sync / incremental restore: stage
/// label, determinate bar when known, and per-stage counters.
Widget buildRestoreProgress(
  RestoreProgress progress,
  AppLocalizations l10n,
  ColorScheme cs,
) {
  final stageText = switch (progress.stage) {
    RestoreStage.extracting => l10n.lanSyncRestoreExtracting,
    RestoreStage.mergingChats => l10n.lanSyncRestoreMergingChats,
    RestoreStage.copyingFiles => l10n.lanSyncRestoreCopyingFiles,
    RestoreStage.restoringSettings => l10n.lanSyncRestoreRestoringSkills,
    _ => l10n.lanSyncRestoreCopyingFiles,
  };
  return Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    mainAxisSize: MainAxisSize.min,
    children: [
      Text(
        stageText,
        style: TextStyle(
          fontSize: 13,
          color: cs.onSurface.withValues(alpha: 0.6),
        ),
      ),
      const SizedBox(height: 8),
      LinearProgressIndicator(
        value: progress.fraction,
        minHeight: 4,
        borderRadius: BorderRadius.circular(2),
      ),
      if (progress.stage == RestoreStage.copyingFiles &&
          progress.filesTotal > 0) ...[
        const SizedBox(height: 6),
        Text(
          l10n.lanSyncRestoreFilesProgress(
            progress.filesCopied,
            progress.filesTotal,
            formatBytes(progress.bytesCopied),
          ),
          style: TextStyle(
            fontSize: 12,
            color: cs.onSurface.withValues(alpha: 0.5),
          ),
        ),
      ],
      if (progress.stage == RestoreStage.mergingChats &&
          progress.conversationsTotal > 0) ...[
        const SizedBox(height: 6),
        Text(
          l10n.lanSyncRestoreChatsProgress(
            progress.conversationsMerged,
            progress.conversationsTotal,
          ),
          style: TextStyle(
            fontSize: 12,
            color: cs.onSurface.withValues(alpha: 0.5),
          ),
        ),
      ],
    ],
  );
}
