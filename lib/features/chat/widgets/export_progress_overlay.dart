import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import '../../../l10n/app_localizations.dart';
import '../../../theme/app_semantic_colors.dart';

/// Runs [task] behind the export overlay.
///
/// Every export that can take a moment — an image to render, a PDF to lay out —
/// runs through this: the work is invisible otherwise, and a save dialog appearing
/// out of nowhere reads as a freeze. The overlay is dismissible by nothing, and it
/// is popped in a `finally`, so a thrown export still gives the app back.
Future<void> runWithExportingOverlay(
  BuildContext context,
  Future<void> Function() task,
) async {
  final cs = Theme.of(context).colorScheme;
  final l10n = AppLocalizations.of(context)!;
  final navigator = Navigator.of(context, rootNavigator: true);
  // Show overlay first
  showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (ctx) => Center(
      child: Material(
        color: context.appColors.surfaceCard,
        elevation: 6,
        shadowColor: cs.shadow.withValues(alpha: 0.2),
        borderRadius: BorderRadius.circular(14),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const CupertinoActivityIndicator(radius: 16),
              const SizedBox(height: 12),
              Text(
                l10n.messageExportSheetExporting,
                style: TextStyle(
                  fontSize: 14,
                  color: cs.onSurface.withValues(alpha: 0.8),
                ),
              ),
            ],
          ),
        ),
      ),
    ),
  );
  try {
    await WidgetsBinding.instance.endOfFrame;
    await task();
  } finally {
    await Future<void>.delayed(Duration.zero);
    if (navigator.mounted) {
      await navigator.maybePop();
      await Future<void>.delayed(Duration.zero);
    }
  }
}
