import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/services/chat/chat_service.dart';
import '../../core/services/recycle/recycle_service.dart';
import '../../core/services/sync/business_state_reloader.dart';
import '../../l10n/app_localizations.dart';
import '../../shared/widgets/snackbar.dart';

/// The two things a bin entry can do, in one place.
///
/// Both the list and the detail page offer restore and permanent delete, and
/// both have to leave the app consistent afterwards: a restored conversation
/// must appear in the chat list and a restored assistant in the business view,
/// without a restart. The refresh that does it, the confirmation a permanent
/// delete asks for, and the message each outcome produces live here so the two
/// pages cannot drift into saying different things about the same result.
///
/// Nothing here holds state: a page that wants a per-entry spinner owns it.

/// Restores [entry], makes the rows visible, and reports what happened.
///
/// Returns the outcome so a caller that batches several restores can summarise
/// them; a single call has already told the user by then.
Future<RecycleRestoreOutcome> restoreRecycleEntry(
  BuildContext context, {
  required RecycleService service,
  required RecycleEntry entry,
}) async {
  final outcome = await _restoreOne(service, entry);
  if (outcome == RecycleRestoreOutcome.restored && context.mounted) {
    await _refreshAfterRestore(context, _RefreshTargets()..add(entry));
  }
  if (!context.mounted) return outcome;
  final l10n = AppLocalizations.of(context);
  if (l10n == null) return outcome;
  showAppSnackBar(
    context,
    message: _outcomeMessage(outcome, l10n),
    type: outcome == RecycleRestoreOutcome.restored
        ? NotificationType.success
        : NotificationType.warning,
  );
  return outcome;
}

/// Restores a whole deletion event as one act: one refresh, one report.
///
/// Every entry keeps its own outcome — a damaged copy, or an identity that is
/// back already, is skipped rather than folded into a batch that can only say
/// "some of it worked" — but the user hears about the act *once*. A per-entry
/// toast is what a loop over [restoreRecycleEntry] produces, and it buries the
/// summary it then shows under N copies of itself.
Future<({int restored, int skipped})> restoreRecycleGroup(
  BuildContext context, {
  required RecycleService service,
  required List<RecycleEntry> entries,
}) async {
  var restored = 0;
  var skipped = 0;
  final targets = _RefreshTargets();
  for (final entry in entries) {
    final outcome = await _restoreOne(service, entry);
    if (outcome == RecycleRestoreOutcome.restored) {
      restored++;
      targets.add(entry);
    } else {
      skipped++;
    }
  }
  if (context.mounted) await _refreshAfterRestore(context, targets);
  if (!context.mounted) return (restored: restored, skipped: skipped);
  final l10n = AppLocalizations.of(context);
  if (l10n == null) return (restored: restored, skipped: skipped);
  // One report for the act: the rows are already the proof of what came back.
  showAppSnackBar(
    context,
    message: skipped == 0
        ? l10n.recycleBinRestored
        : l10n.recycleBinGroupRestored(restored, skipped),
    type: skipped == 0 ? NotificationType.success : NotificationType.warning,
  );
  return (restored: restored, skipped: skipped);
}

/// One restore, with no UI at all: a throw is `failed`, and the entry is
/// untouched so the user can retry it.
Future<RecycleRestoreOutcome> _restoreOne(
  RecycleService service,
  RecycleEntry entry,
) async {
  try {
    return await service.restore(entry);
  } catch (error) {
    debugPrint('recycle: restoring ${entry.id} failed: $error');
    return RecycleRestoreOutcome.failed;
  }
}

/// Asks, then deletes [entry] for good. Returns true when it went.
Future<bool> purgeRecycleEntry(
  BuildContext context, {
  required RecycleService service,
  required RecycleEntry entry,
}) async {
  final l10n = AppLocalizations.of(context);
  if (l10n == null) return false;
  final confirmed = await confirmRecycleAction(
    context,
    title: l10n.recycleBinDeleteForever,
    body: l10n.recycleBinDeleteForeverBody,
    confirmLabel: l10n.recycleBinDeleteForever,
    cancelLabel: l10n.recycleBinCancel,
  );
  if (!confirmed || !context.mounted) return false;
  await service.purge(entry);
  return true;
}

/// Asks, then empties the bin. Returns true when it was cleared.
Future<bool> clearRecycleBin(
  BuildContext context, {
  required RecycleService service,
}) async {
  final l10n = AppLocalizations.of(context);
  if (l10n == null) return false;
  final confirmed = await confirmRecycleAction(
    context,
    title: l10n.recycleBinClearAll,
    body: l10n.recycleBinClearAllBody,
    confirmLabel: l10n.recycleBinClearAll,
    cancelLabel: l10n.recycleBinCancel,
  );
  if (!confirmed || !context.mounted) return false;
  await service.clear();
  return true;
}

/// The confirmation every destructive bin action asks for: the confirm button
/// carries the error colour, because there is no undo on the other side.
Future<bool> confirmRecycleAction(
  BuildContext context, {
  required String title,
  required String body,
  required String confirmLabel,
  required String cancelLabel,
}) async {
  final cs = Theme.of(context).colorScheme;
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: Text(title),
      content: Text(body),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(dialogContext).pop(false),
          child: Text(cancelLabel),
        ),
        TextButton(
          onPressed: () => Navigator.of(dialogContext).pop(true),
          child: Text(confirmLabel, style: TextStyle(color: cs.error)),
        ),
      ],
    ),
  );
  return confirmed ?? false;
}

/// The long explanation behind the bin's info button, used by the storage page
/// and the bin itself so the two describe one set of rules.
Future<void> showRecycleBinInfoDialog(BuildContext context) async {
  final l10n = AppLocalizations.of(context);
  if (l10n == null) return;
  await showDialog<void>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: Text(l10n.recycleBinInfoTitle),
      content: Text(l10n.recycleBinInfoBody),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(dialogContext).pop(),
          child: Text(l10n.recycleBinInfoClose),
        ),
      ],
    ),
  );
}

String _outcomeMessage(RecycleRestoreOutcome outcome, AppLocalizations l10n) =>
    switch (outcome) {
      RecycleRestoreOutcome.restored => l10n.recycleBinRestored,
      RecycleRestoreOutcome.skippedExisting => l10n.recycleBinRestoreSkipped,
      RecycleRestoreOutcome.unreadable => l10n.recycleBinRestoreUnreadable,
      RecycleRestoreOutcome.workspaceGone => l10n.recycleBinRestoreNoWorkspace,
      RecycleRestoreOutcome.unsupported => l10n.recycleBinRestoreUnsupported,
      RecycleRestoreOutcome.failed => l10n.recycleBinRestoreFailed,
    };

/// What a restore has to make visible again, accumulated so a batch can do it
/// once instead of once per entry.
class _RefreshTargets {
  /// Conversations whose rows came back: the chat cache and the draft store.
  final Set<String> conversations = <String>{};

  /// Whether any business row or synced preference came back.
  bool business = false;

  void add(RecycleEntry entry) {
    switch (entry.type) {
      case RecycleEntryType.conversation:
        conversations.add(entry.key);
      case RecycleEntryType.businessEntity:
      case RecycleEntryType.preference:
        business = true;
      case RecycleEntryType.workspaceFile:
        break;
    }
  }
}

/// Makes the restored rows visible without a restart: chat state for a
/// conversation, the business view for a row or a preference. Both seams already
/// exist for the sync apply, which has the same problem.
Future<void> _refreshAfterRestore(
  BuildContext context,
  _RefreshTargets targets,
) async {
  // Every provider is resolved before the first await: they are lookups on this
  // context, and asking for one afterwards would be a use across an async gap.
  final chat = targets.conversations.isEmpty
      ? null
      : _maybe<ChatService>(context);
  final drafts = chat?.composerDrafts;
  final reloader = targets.business
      ? _maybe<BusinessStateReloader>(context)
      : null;
  try {
    // A restored conversation comes back with the draft its delete took, and the
    // delete fenced that id against the store for good: without taking it back
    // the composer cannot open the conversation it just recovered.
    if (drafts != null) {
      for (final id in targets.conversations) {
        await drafts.reloadRestored(id);
      }
    }
    if (chat != null) {
      await chat.reloadAfterExternalChange(
        touchedConversations: targets.conversations,
      );
    }
    if (reloader != null) await reloader.reloadAll();
  } catch (error) {
    // A provider that cannot reload must not make a completed restore look like
    // a failure; the rows are back and the next load picks them up.
    debugPrint('recycle: refreshing after a restore failed: $error');
  }
}

/// The provider of [T], or null when this page is shown outside the tree that
/// supplies it — a missing refresh seam is not an error worth reporting.
T? _maybe<T extends Object>(BuildContext context) {
  try {
    return context.read<T>();
  } catch (_) {
    return null;
  }
}
