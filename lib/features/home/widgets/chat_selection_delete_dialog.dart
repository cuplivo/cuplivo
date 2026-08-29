import 'package:flutter/material.dart';

import '../../../l10n/app_localizations.dart';

/// Confirm dialog for deleting messages selected in selection mode.
///
/// Returns:
/// - `false` when the user confirms deleting the current version only
///   (single-version selections always land here);
/// - `true` when the user confirms deleting all versions;
/// - `null` when the user cancels (or the dialog is dismissed).
///
/// With [hasMultiVersionSelection] the dialog offers a radio pair
/// (删除本版本 default / 删除全部版本) and switches the warning text to the
/// all-versions wording when the second radio is chosen.
Future<bool?> showChatSelectionDeleteDialog(
  BuildContext context, {
  required int count,
  required bool hasMultiVersionSelection,
}) async {
  final l10n = AppLocalizations.of(context)!;
  final cs = Theme.of(context).colorScheme;

  if (!hasMultiVersionSelection) {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(l10n.chatSelectionDeleteSelected),
        content: Text(l10n.chatSelectionDeleteSelectedConfirm(count)),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: Text(l10n.homePageCancel),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: Text(l10n.homePageDelete, style: TextStyle(color: cs.error)),
          ),
        ],
      ),
    );
    return confirm == true ? false : null;
  }

  var deleteAllVersions = false;
  final confirm = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(l10n.chatSelectionDeleteSelected),
      content: StatefulBuilder(
        builder: (ctx, setState) {
          return Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                deleteAllVersions
                    ? l10n.chatSelectionDeleteSelectedAllVersionsConfirm(count)
                    : l10n.chatSelectionDeleteSelectedConfirm(count),
              ),
              const SizedBox(height: 12),
              RadioGroup<bool>(
                groupValue: deleteAllVersions,
                onChanged: (value) {
                  setState(() => deleteAllVersions = value ?? false);
                },
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    RadioListTile<bool>(
                      value: false,
                      dense: true,
                      contentPadding: EdgeInsets.zero,
                      title: Text(l10n.homePageDeleteMessage),
                    ),
                    RadioListTile<bool>(
                      value: true,
                      dense: true,
                      contentPadding: EdgeInsets.zero,
                      title: Text(l10n.homePageDeleteAllVersions),
                    ),
                  ],
                ),
              ),
            ],
          );
        },
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(ctx).pop(false),
          child: Text(l10n.homePageCancel),
        ),
        TextButton(
          onPressed: () => Navigator.of(ctx).pop(true),
          child: Text(l10n.homePageDelete, style: TextStyle(color: cs.error)),
        ),
      ],
    ),
  );
  return confirm == true ? deleteAllVersions : null;
}
