import 'package:intl/intl.dart';

import '../../core/providers/sync_provider.dart';
import '../../core/services/sync/sync_engine.dart';
import '../../core/services/sync/sync_models.dart';
import '../../l10n/app_localizations.dart';

/// Localized text for the LAN sync surface. Pure mapping — no widget state,
/// so both the mobile page and the desktop pane render identical wording.

String syncPlatformLabel(AppLocalizations l10n, String platform) {
  switch (platform) {
    case 'android':
      return l10n.lanSyncPlatformAndroid;
    case 'ios':
      return l10n.lanSyncPlatformIos;
    case 'windows':
      return l10n.lanSyncPlatformWindows;
    case 'macos':
      return l10n.lanSyncPlatformMacos;
    case 'linux':
      return l10n.lanSyncPlatformLinux;
    default:
      return l10n.lanSyncPlatformUnknown;
  }
}

String syncPairErrorMessage(AppLocalizations l10n, SyncPairOutcome outcome) {
  switch (outcome.errorCode) {
    case 'invalid_pin':
      return l10n.lanSyncPairErrorInvalidPin;
    case 'no_certificate':
      return l10n.lanSyncPairErrorNoCertificate;
    case 'id_mismatch':
      return l10n.lanSyncPairErrorIdMismatch;
    case 'no_listener':
      return l10n.lanSyncPairErrorNoListener;
    case 'unreachable':
      return l10n.lanSyncPairErrorUnreachable;
    default:
      return l10n.lanSyncPairErrorUnknown(
        outcome.errorDetail ?? outcome.errorCode ?? 'unknown',
      );
  }
}

String syncRefusalMessage(AppLocalizations l10n, SyncRefusalReason reason) {
  switch (reason) {
    case SyncRefusalReason.peerSchemaNewer:
      return l10n.lanSyncRefusedPeerSchemaNewer;
    case SyncRefusalReason.protocolUnknown:
      return l10n.lanSyncRefusedProtocolUnknown;
    case SyncRefusalReason.notPaired:
      return l10n.lanSyncRefusedNotPaired;
    case SyncRefusalReason.busy:
      return l10n.lanSyncRefusedBusy;
  }
}

/// One-line summary of a session for a peer card or a snackbar. A refusal is
/// the most actionable message, so it wins over the raw error text.
String syncReportMessage(AppLocalizations l10n, SyncSessionReport report) {
  if (report.refusal != null) return syncRefusalMessage(l10n, report.refusal!);
  if (!report.success) {
    return l10n.lanSyncReportFailed(report.summary);
  }
  return _syncCountsMessage(
    l10n,
    sent: report.conversationsSent,
    received: report.conversationsReceived,
    upserted: report.messagesUpserted,
    deleted: report.messagesDeleted,
    deletedConversations: report.conversationsDeletedLocally,
    deferred: report.deferred,
  );
}

/// The same line, rebuilt from the counters persisted on a peer record.
String syncPeerReportMessage(AppLocalizations l10n, SyncPeerReport report) {
  if (report.refusal != null) return syncRefusalMessage(l10n, report.refusal!);
  if (!report.success) {
    return l10n.lanSyncReportFailed(report.error ?? '');
  }
  return _syncCountsMessage(
    l10n,
    sent: report.sent,
    received: report.received,
    upserted: report.upsertedMessages,
    deleted: report.deletedMessages,
    deletedConversations: report.deletedConversations,
    deferred: report.deferred,
  );
}

String _syncCountsMessage(
  AppLocalizations l10n, {
  required int sent,
  required int received,
  required int upserted,
  required int deleted,
  required int deletedConversations,
  required int deferred,
}) {
  final parts = <String>[
    l10n.lanSyncReportSent(sent),
    l10n.lanSyncReportReceived(received),
    if (upserted > 0) l10n.lanSyncReportMessagesUpserted(upserted),
    if (deleted > 0) l10n.lanSyncReportMessagesDeleted(deleted),
    if (deletedConversations > 0)
      l10n.lanSyncReportConversationsDeleted(deletedConversations),
    if (deferred > 0) l10n.lanSyncReportDeferred(deferred),
  ];
  return parts.join(' · ');
}

String syncLastSyncedLabel(AppLocalizations l10n, DateTime? at) {
  if (at == null) return l10n.lanSyncNeverSynced;
  return l10n.lanSyncLastSyncedAt(
    DateFormat('yyyy-MM-dd HH:mm').format(at.toLocal()),
  );
}
