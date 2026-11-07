import 'package:flutter/material.dart';

import '../../../core/models/backup.dart';
import '../../../icons/lucide_adapter.dart';
import '../../../l10n/app_localizations.dart';
import '../../../shared/widgets/form_sheet.dart';
import '../../../shared/widgets/ios_tactile.dart';
import '../../../shared/widgets/section_card.dart';
import '../../../theme/app_font_weights.dart';
import '../../../theme/app_semantic_colors.dart';

/// Which build the next backup is written for.
///
/// A backup names the entities it carries, so the reader is part of what the
/// file *is* — an export option like [BackupScope], not a transport one. It is a
/// standing choice rather than a question asked at export time because it has to
/// reach the WebDAV and S3 uploads too, and those never open a sheet.
class BackupTargetTile extends StatelessWidget {
  const BackupTargetTile({
    super.key,
    required this.target,
    required this.onChanged,
    this.desktop = false,
  });

  final BackupTarget target;
  final Future<void> Function(BackupTarget)? onChanged;
  final bool desktop;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final cs = Theme.of(context).colorScheme;
    return IosCardPress(
      key: const ValueKey('backup-target-picker'),
      onTap: onChanged == null
          ? null
          : () async {
              final selected = desktop
                  ? await showDialog<BackupTarget>(
                      context: context,
                      builder: (_) =>
                          _BackupTargetPicker(target: target, desktop: true),
                    )
                  : await showFormSheet<BackupTarget>(
                      context,
                      builder: (_) => _BackupTargetPicker(target: target),
                    );
              if (selected != null && selected != target && context.mounted) {
                await onChanged!(selected);
              }
            },
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 11),
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 26),
        child: Row(
          children: [
            SizedBox(
              width: 36,
              child: Icon(
                Lucide.Package,
                size: 20,
                color: cs.onSurface.withValues(alpha: 0.9),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                l10n.backupPageTargetTitle,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 15,
                  color: cs.onSurface.withValues(alpha: 0.9),
                ),
              ),
            ),
            const SizedBox(width: 8),
            Text(
              targetLabel(l10n, target),
              style: TextStyle(
                fontSize: 13,
                color: cs.onSurface.withValues(alpha: 0.6),
              ),
            ),
            const SizedBox(width: 6),
            Icon(Lucide.ChevronRight, size: 16, color: cs.onSurfaceVariant),
          ],
        ),
      ),
    );
  }

  static String targetLabel(AppLocalizations l10n, BackupTarget target) =>
      switch (target) {
        BackupTarget.cuplivo => l10n.backupPageTargetCuplivo,
        BackupTarget.kelivoV1_3_4 => l10n.backupPageTargetKelivo,
      };
}

/// Two options, one tap: a picker this short needs no Save button.
class _BackupTargetPicker extends StatelessWidget {
  const _BackupTargetPicker({required this.target, this.desktop = false});

  final BackupTarget target;
  final bool desktop;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final cs = Theme.of(context).colorScheme;
    final showDividers = showSheetTileDividers(context);
    final options = [
      (
        BackupTarget.cuplivo,
        l10n.backupPageTargetCuplivo,
        l10n.backupPageTargetCuplivoNote,
      ),
      (
        BackupTarget.kelivoV1_3_4,
        l10n.backupPageTargetKelivo,
        l10n.backupPageTargetKelivoNote,
      ),
    ];
    final body = SafeArea(
      top: false,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (!desktop)
            Padding(
              padding: const EdgeInsets.only(top: 10, bottom: 4),
              child: Center(
                child: Container(
                  width: 36,
                  height: 4,
                  decoration: BoxDecoration(
                    color: cs.onSurface.withValues(alpha: 0.18),
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
            ),
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 12, 20, 10),
            child: Text(
              l10n.backupPageTargetTitle,
              style: TextStyle(
                fontSize: 17,
                fontWeight: AppFontWeights.semibold,
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
            child: Container(
              decoration: BoxDecoration(
                color: sheetTileColor(context),
                borderRadius: BorderRadius.circular(14),
              ),
              clipBehavior: Clip.antiAlias,
              child: Column(
                children: [
                  for (final option in options) ...[
                    if (showDividers && option.$1 != options.first.$1)
                      Divider(
                        height: 0.5,
                        thickness: 0.5,
                        indent: 46,
                        endIndent: 12,
                        color: cs.outlineVariant.withValues(alpha: 0.18),
                      ),
                    IosCardPress(
                      key: ValueKey('backup-target-${option.$1.name}'),
                      onTap: () => Navigator.of(context).pop(option.$1),
                      padding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 11,
                      ),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          SizedBox(
                            width: 20,
                            height: 20,
                            child: option.$1 == target
                                ? Icon(
                                    Lucide.Check,
                                    size: 18,
                                    color: cs.primary,
                                  )
                                : null,
                          ),
                          const SizedBox(width: 14),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  option.$2,
                                  style: const TextStyle(fontSize: 15),
                                ),
                                const SizedBox(height: 2),
                                Text(
                                  option.$3,
                                  style: TextStyle(
                                    fontSize: 12.5,
                                    height: 1.35,
                                    color: cs.onSurfaceVariant,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ],
      ),
    );
    if (!desktop) return body;
    return Dialog(
      backgroundColor: context.overlaySurface,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      clipBehavior: Clip.antiAlias,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 420),
        child: body,
      ),
    );
  }
}
