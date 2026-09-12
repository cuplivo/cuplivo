import 'package:flutter/material.dart';

import '../../../core/services/knowledge/knowledge_import_service.dart';
import '../../../l10n/app_localizations.dart';
import '../../../shared/widgets/snackbar.dart';
import '../../../theme/app_font_weights.dart';

/// Shows the outcome of a knowledge import batch: a success snackbar when
/// everything imported, otherwise a dialog that lists skipped duplicates and
/// failures by file name. Shared by the document list and the desktop drop
/// target.
void showKnowledgeImportResult(
  BuildContext context,
  List<KnowledgeImportResult> results,
) {
  final l10n = AppLocalizations.of(context)!;
  final imported = results.where((r) => r.isImported).toList();
  final skipped = results
      .where((r) => r.status == KnowledgeImportStatus.duplicate)
      .toList();
  final failed = results
      .where(
        (r) =>
            r.status == KnowledgeImportStatus.failed ||
            r.status == KnowledgeImportStatus.unsupported,
      )
      .toList();

  if (skipped.isEmpty && failed.isEmpty) {
    showAppSnackBar(
      context,
      message: l10n.knowledgeImportSuccess(imported.length),
      type: NotificationType.success,
    );
    return;
  }

  showDialog<void>(
    context: context,
    builder: (ctx) {
      final cs = Theme.of(ctx).colorScheme;
      return AlertDialog(
        title: Text(l10n.knowledgeImportResultTitle),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(l10n.knowledgeImportResultImported(imported.length)),
              if (skipped.isNotEmpty) ...[
                const SizedBox(height: 10),
                Text(
                  l10n.knowledgeImportResultSkipped(skipped.length),
                  style: TextStyle(
                    fontWeight: AppFontWeights.semibold,
                    color: cs.onSurface,
                  ),
                ),
                for (final item in skipped)
                  _ImportIssueRow(name: item.fileName),
              ],
              if (failed.isNotEmpty) ...[
                const SizedBox(height: 10),
                Text(
                  l10n.knowledgeImportResultFailed(failed.length),
                  style: TextStyle(
                    fontWeight: AppFontWeights.semibold,
                    color: cs.error,
                  ),
                ),
                for (final item in failed)
                  _ImportIssueRow(
                    name: item.fileName,
                    detail: _failureLabel(item.status, l10n),
                  ),
              ],
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: Text(l10n.knowledgeImportOk),
          ),
        ],
      );
    },
  );
}

String _failureLabel(KnowledgeImportStatus status, AppLocalizations l10n) {
  switch (status) {
    case KnowledgeImportStatus.unsupported:
      return l10n.knowledgeImportFailedUnsupported;
    case KnowledgeImportStatus.failed:
      return l10n.knowledgeImportFailedExtract;
    case KnowledgeImportStatus.imported:
    case KnowledgeImportStatus.duplicate:
      return '';
  }
}

class _ImportIssueRow extends StatelessWidget {
  const _ImportIssueRow({required this.name, this.detail});

  final String name;
  final String? detail;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(top: 4),
      child: Text(
        detail == null || detail!.isEmpty ? '• $name' : '• $name — $detail',
        style: TextStyle(
          fontSize: 13,
          color: cs.onSurface.withValues(alpha: 0.75),
        ),
      ),
    );
  }
}
