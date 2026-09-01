import 'package:flutter/material.dart';

import '../../../icons/lucide_adapter.dart';
import '../../../l10n/app_localizations.dart';
import '../../../theme/app_font_weights.dart';
import 'backup_action_row.dart';

/// Centered chooser for all "migrate house" operations — exporting out to
/// other apps (one entry: Kelivo / older Cuplivo) and importing in from other
/// apps (new Kelivo / RikkaHub / Cherry Studio / ChatBox) — as a flat list:
/// no group headers, no tinted sub-groups; every row's label carries its own
/// direction semantics (导出… / 从…导入). Rare operations: one entry row on
/// the page, options appear only after the user asks.
Future<void> showBackupMigrationChooser(
  BuildContext context, {
  required VoidCallback onExportKelivo,
  required VoidCallback onImportKelivo,
  required VoidCallback onImportRikkaHub,
  required VoidCallback onImportCherryStudio,
  required VoidCallback onImportChatbox,
}) {
  final l10n = AppLocalizations.of(context)!;
  final cs = Theme.of(context).colorScheme;
  return showDialog<void>(
    context: context,
    builder: (ctx) => Dialog(
      backgroundColor: cs.surface,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: ConstrainedBox(
        constraints: const BoxConstraints(minWidth: 320, maxWidth: 420),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 14, 16, 12),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                l10n.backupMigrateTitle,
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 15,
                  fontWeight: AppFontWeights.emphasis,
                ),
              ),
              const SizedBox(height: 10),
              BackupActionRow(
                icon: Lucide.Export,
                label: l10n.backupMigrateExportLabel,
                subtitle: l10n.backupPageExportKelivoCompatibleSubtitle,
                labelMaxLines: 2,
                subtitleMaxLines: 2,
                onTap: () {
                  Navigator.of(ctx).pop();
                  onExportKelivo();
                },
              ),
              _groupDivider(context),
              BackupActionRow(
                icon: Lucide.Import,
                label: l10n.backupPageImportFromKelivo,
                labelMaxLines: 2,
                subtitleMaxLines: 2,
                onTap: () {
                  Navigator.of(ctx).pop();
                  onImportKelivo();
                },
              ),
              _groupDivider(context),
              BackupActionRow(
                icon: Lucide.Import,
                label: l10n.backupPageImportFromRikkaHub,
                labelMaxLines: 2,
                subtitleMaxLines: 2,
                onTap: () {
                  Navigator.of(ctx).pop();
                  onImportRikkaHub();
                },
              ),
              _groupDivider(context),
              BackupActionRow(
                icon: Lucide.Import,
                label: l10n.backupPageImportFromCherryStudio,
                labelMaxLines: 2,
                subtitleMaxLines: 2,
                onTap: () {
                  Navigator.of(ctx).pop();
                  onImportCherryStudio();
                },
              ),
              _groupDivider(context),
              BackupActionRow(
                icon: Lucide.Import,
                label: l10n.backupPageImportFromChatbox,
                labelMaxLines: 2,
                subtitleMaxLines: 2,
                onTap: () {
                  Navigator.of(ctx).pop();
                  onImportChatbox();
                },
              ),
              const SizedBox(height: 6),
              Align(
                alignment: Alignment.centerRight,
                child: TextButton(
                  onPressed: () => Navigator.of(ctx).pop(),
                  child: Text(l10n.backupPageCancel),
                ),
              ),
            ],
          ),
        ),
      ),
    ),
  );
}

Widget _groupDivider(BuildContext context) {
  final cs = Theme.of(context).colorScheme;
  return Container(
    height: 0.5,
    margin: const EdgeInsets.only(left: 48),
    color: cs.outlineVariant.withValues(alpha: 0.25),
  );
}
