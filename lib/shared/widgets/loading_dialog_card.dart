import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../core/services/backup/data_sync.dart';
import '../../l10n/app_localizations.dart';
import '../../utils/format.dart';
import '../animations/widgets.dart';

/// Localized label for a backup [stage] (生成文件 / 整合压缩 / 上传).
String backupStageLabel(AppLocalizations l10n, BackupStage stage) =>
    switch (stage) {
      BackupStage.generating => l10n.backupStageGenerating,
      BackupStage.packing => l10n.backupStagePacking,
      BackupStage.uploading => l10n.backupStageUploading,
    };

/// Shared restore-progress content for the import/restore modal mask: stage
/// text + determinate bar (indeterminate stages render a busy bar).
///
/// Single source of truth for every restore-progress surface (LAN sync dialog
/// and the backup-page import overlay). Moved here from the LAN sync section
/// so the backup import overlay can reuse it without importing LAN sync.
Widget buildRestoreProgress(
  RestoreProgress progress,
  AppLocalizations l10n,
  ColorScheme cs,
) {
  final stageText = switch (progress.stage) {
    RestoreStage.extracting => l10n.lanSyncRestoreExtracting,
    RestoreStage.mergingChats => l10n.lanSyncRestoreMergingChats,
    RestoreStage.copyingFiles => l10n.lanSyncRestoreCopyingFiles,
    RestoreStage.restoringSkills => l10n.lanSyncRestoreRestoringSkills,
  };
  return Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
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
          // gen-l10n orders Object params alphabetically: count, size, total.
          l10n.lanSyncRestoreFilesProgress(
            progress.filesCopied,
            formatBytes(progress.bytesTotal),
            progress.filesTotal,
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

/// Runs [task] behind a modal, un-dismissible [LoadingDialogCard] overlay and
/// pops it when the task completes or throws.
///
/// [labelListenable], when non-null, replaces the static [label] with a live
/// value (e.g. a backup stage that changes mid-flight). [progressListenable],
/// when non-null, replaces the label with live restore progress (stage text +
/// determinate bar + counts via [buildRestoreProgress]). [elapsedTextBuilder],
/// when non-null, shows a "已耗时 Xs" line that ticks every second.
Future<T> runWithLoadingDialog<T>(
  BuildContext context,
  Future<T> Function() task, {
  String? label,
  String Function(int seconds)? elapsedTextBuilder,
  ValueListenable<String>? labelListenable,
  ValueListenable<RestoreProgress>? progressListenable,
}) async {
  showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (_) => LoadingDialogCard(
      label: label,
      elapsedTextBuilder: elapsedTextBuilder,
      labelListenable: labelListenable,
      progressListenable: progressListenable,
    ),
  );
  try {
    return await task();
  } finally {
    if (context.mounted) {
      Navigator.of(context, rootNavigator: true).pop();
    }
  }
}

/// Runs a restore-family task behind the modal overlay with live
/// [RestoreProgress] (stage → determinate bar → counts) and an elapsed ticker.
///
/// [label], when set (third-party importers without a progress pipeline),
/// swaps the progress body for a fixed importing label. Single source shared
/// by the mobile backup page and the desktop backup pane.
Future<T> runRestoreWithProgressOverlay<T>(
  BuildContext context,
  Future<T> Function(RestoreProgressCallback onProgress) task, {
  String? label,
}) async {
  final l10n = AppLocalizations.of(context)!;
  final progress = ValueNotifier<RestoreProgress>(
    const RestoreProgress(stage: RestoreStage.extracting),
  );
  try {
    return await runWithLoadingDialog(
      context,
      () => task((p) => progress.value = p),
      label: label,
      elapsedTextBuilder: l10n.backupPageImportElapsed,
      progressListenable: label == null ? progress : null,
    );
  } finally {
    progress.dispose();
  }
}

class LoadingDialogCard extends StatefulWidget {
  const LoadingDialogCard({
    super.key,
    this.label,
    this.elapsedTextBuilder,
    this.labelListenable,
    this.progressListenable,
  });

  final String? label;

  /// When non-null, the card shows a live "elapsed seconds" line that ticks
  /// every second. Null keeps the card static (no timer).
  final String Function(int seconds)? elapsedTextBuilder;

  /// When non-null, the rendered label follows this notifier (wins over
  /// [label]).
  final ValueListenable<String>? labelListenable;

  /// When non-null, the rendered body follows this notifier and shows live
  /// restore progress (stage text + determinate bar + counts) instead of the
  /// label.
  final ValueListenable<RestoreProgress>? progressListenable;

  @override
  State<LoadingDialogCard> createState() => _LoadingDialogCardState();
}

class _LoadingDialogCardState extends State<LoadingDialogCard> {
  Timer? _timer;
  int _seconds = 0;

  @override
  void initState() {
    super.initState();
    if (widget.elapsedTextBuilder != null) {
      _timer = Timer.periodic(const Duration(seconds: 1), (_) {
        if (mounted) setState(() => _seconds++);
      });
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final progressListenable = widget.progressListenable;
    final labelListenable = widget.labelListenable;
    final label = labelListenable?.value ?? widget.label;
    final hasLabel = label != null && label.trim().isNotEmpty;
    final hasProgress = progressListenable != null;
    final l10n = AppLocalizations.of(context)!;

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
            constraints: const BoxConstraints(minWidth: 96, maxWidth: 280),
            child: Container(
              decoration: BoxDecoration(
                color: cs.surface,
                borderRadius: BorderRadius.circular(14),
                border: Border.all(
                  color: cs.outlineVariant.withValues(alpha: 0.2),
                ),
              ),
              child: Padding(
                padding: EdgeInsets.fromLTRB(
                  20,
                  (hasProgress || hasLabel) ? 16 : 18,
                  20,
                  (hasProgress || hasLabel) ? 16 : 18,
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Center(child: const CupertinoActivityIndicator(radius: 16)),
                    if (hasProgress) ...[
                      const SizedBox(height: 12),
                      ValueListenableBuilder<RestoreProgress>(
                        valueListenable: progressListenable,
                        builder: (context, progress, _) =>
                            buildRestoreProgress(progress, l10n, cs),
                      ),
                    ] else ...[
                      if (labelListenable != null && hasLabel) ...[
                        const SizedBox(height: 12),
                        ValueListenableBuilder<String>(
                          valueListenable: labelListenable,
                          builder: (context, value, _) => Text(
                            value,
                            textAlign: TextAlign.center,
                            style: TextStyle(
                              fontSize: 14,
                              color: cs.onSurface.withValues(alpha: 0.8),
                            ),
                          ),
                        ),
                      ] else if (hasLabel) ...[
                        const SizedBox(height: 12),
                        Text(
                          label,
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            fontSize: 14,
                            color: cs.onSurface.withValues(alpha: 0.8),
                          ),
                        ),
                      ],
                    ],
                    if (widget.elapsedTextBuilder != null) ...[
                      SizedBox(height: (hasProgress || hasLabel) ? 4 : 12),
                      Text(
                        widget.elapsedTextBuilder!(_seconds),
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          fontSize: 12,
                          color: cs.onSurface.withValues(alpha: 0.5),
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
