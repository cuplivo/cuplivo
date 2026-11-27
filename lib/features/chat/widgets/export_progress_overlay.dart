import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import '../../../l10n/app_localizations.dart';
import '../../../theme/app_semantic_colors.dart';
import 'export_image_capture.dart';

/// The one progress card every image export shows: a spinner, the stage the
/// export has reached, and a bar when the stage knows its size.
class ExportProgressContent extends StatelessWidget {
  const ExportProgressContent({super.key, required this.progress});

  final ExportImageProgress progress;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final label =
        progress.label ??
        switch (progress.stage) {
          ExportImageStage.preparing => l10n.imageExportPreparing,
          ExportImageStage.diagrams => l10n.imageExportDiagrams(
            progress.completed,
            progress.total,
          ),
          ExportImageStage.capturing => l10n.imageExportCapturing(
            progress.completed,
            progress.total,
          ),
          ExportImageStage.processing => l10n.imageExportProcessing,
          ExportImageStage.saving => l10n.imageExportSaving,
        };
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 16),
      child: SizedBox(
        width: 240,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const CupertinoActivityIndicator(radius: 16),
            const SizedBox(height: 12),
            Text(
              label,
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 14,
                color: Theme.of(
                  context,
                ).colorScheme.onSurface.withValues(alpha: .8),
              ),
            ),
            const SizedBox(height: 12),
            LinearProgressIndicator(value: progress.fraction),
          ],
        ),
      ),
    );
  }
}

/// Holds a modal progress card for the duration of [task] and reports its
/// stages. The card never outlives the operation, even when the operation
/// opens another route of its own.
///
/// [task]'s answer is this call's answer, so an export that builds something
/// worth keeping (a file, a document) does not have to smuggle it out through a
/// captured variable. [initial] is the stage the card opens on, and [label]
/// there is what it opens saying.
Future<T> runWithExportProgressOverlay<T>(
  BuildContext context,
  Future<T> Function(ValueNotifier<ExportImageProgress> progress) task, {
  ExportImageProgress initial = const ExportImageProgress(
    ExportImageStage.preparing,
  ),
}) async {
  final navigator = Navigator.of(context, rootNavigator: true);
  final progress = ValueNotifier(initial);
  final route = DialogRoute<void>(
    context: context,
    barrierDismissible: false,
    builder: (context) => PopScope(
      canPop: false,
      child: Center(
        child: Material(
          color: context.appColors.surfaceCard,
          elevation: 6,
          shadowColor: Theme.of(
            context,
          ).colorScheme.shadow.withValues(alpha: .2),
          borderRadius: BorderRadius.circular(14),
          child: ValueListenableBuilder<ExportImageProgress>(
            valueListenable: progress,
            builder: (context, value, _) =>
                ExportProgressContent(progress: value),
          ),
        ),
      ),
    ),
  );
  unawaited(navigator.push(route));
  try {
    await WidgetsBinding.instance.endOfFrame;
    return await task(progress);
  } finally {
    // Remove only this operation's dialog, even when another route was opened.
    if (route.isActive) navigator.removeRoute(route);
    progress.dispose();
  }
}
