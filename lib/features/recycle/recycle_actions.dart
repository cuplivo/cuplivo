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
/// This is the single-entry action: it refreshes what came back and says what
/// happened. [restoreRecycleGroup] is the batch form, which is why this one is
/// not what a loop should call — it would tell the user the same thing once per
/// entry.
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
/// Every entry keeps its own outcome — a damaged copy is *not* "already back" —
/// but the user hears about the act *once*. A per-entry toast is what a loop over
/// [restoreRecycleEntry] produces, and it buries the summary it then shows under
/// N copies of itself. The three counts keep the summary honest: an entry that
/// could not be restored stays in the bin and is reported as such, rather than
/// folded into the "already back" bucket where it would look like a success.
Future<({int restored, int skipped, int failed})> restoreRecycleGroup(
  BuildContext context, {
  required RecycleService service,
  required List<RecycleEntry> entries,
}) async {
  var restored = 0;
  var skipped = 0;
  var failed = 0;
  final targets = _RefreshTargets();
  // The row the conversations name comes back first. An assistant's cascade is
  // one entity plus its conversations, and restoring a conversation while its
  // assistant is still missing is the state the detail view warns about; the
  // batch should never pass through it, whatever order staging left them in.
  final ordered = [...entries]
    ..sort((x, y) {
      final xIsRow = x.type != RecycleEntryType.conversation;
      final yIsRow = y.type != RecycleEntryType.conversation;
      if (xIsRow != yIsRow) return xIsRow ? -1 : 1;
      return y.deletedAt.compareTo(x.deletedAt);
    });
  for (final entry in ordered) {
    final outcome = await _restoreOne(service, entry);
    if (outcome == RecycleRestoreOutcome.restored) {
      restored++;
      targets.add(entry);
    } else if (outcome == RecycleRestoreOutcome.skippedExisting) {
      skipped++;
    } else {
      // `unreadable`, `unsupported`, `workspaceGone`, `failed`: the entry is
      // still there because it could not be brought back, which is not "already
      // back" and must not be reported as such.
      failed++;
    }
  }
  if (context.mounted) await _refreshAfterRestore(context, targets);
  if (!context.mounted) {
    return (restored: restored, skipped: skipped, failed: failed);
  }
  final l10n = AppLocalizations.of(context);
  if (l10n == null) {
    return (restored: restored, skipped: skipped, failed: failed);
  }
  // One report for the act: the rows are already the proof of what came back.
  showAppSnackBar(
    context,
    message: failed > 0
        // gen-l10n orders a key's placeholders by name, not by their position in
        // the message: this one is (failed, restored).
        ? l10n.recycleBinGroupRestoreFailed(failed, restored)
        : skipped > 0
        ? l10n.recycleBinGroupRestored(restored, skipped)
        : l10n.recycleBinRestored,
    type: failed > 0 || skipped > 0
        ? NotificationType.warning
        : NotificationType.success,
  );
  return (restored: restored, skipped: skipped, failed: failed);
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
