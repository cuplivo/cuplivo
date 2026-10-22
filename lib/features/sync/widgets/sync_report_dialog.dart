import 'package:flutter/material.dart';

import '../../../core/services/sync/sync_engine.dart';
import 'sync_report_breakdown.dart';

/// The details behind an arrival toast: the same breakdown the peer card
/// renders, in a dialog of its own. The toast has room for one line, and the
/// session it names usually has more to say (messages, files, warnings).
void showSyncReportDialog(
  BuildContext context, {
  required String title,
  required SyncSessionReport report,
}) {
  showDialog<void>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: Text(title),
      // The breakdown is chips that wrap plus one row per warning; scrolling
      // keeps a long first sync from overflowing a small phone dialog.
      content: SingleChildScrollView(
        child: SyncReportBreakdown(report: report.toPeerReport()),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(dialogContext).pop(),
          child: Text(MaterialLocalizations.of(dialogContext).okButtonLabel),
        ),
      ],
    ),
  );
}
