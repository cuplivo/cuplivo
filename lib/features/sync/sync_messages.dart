import 'package:intl/intl.dart';

import '../../core/providers/sync_provider.dart';
import '../../core/services/sync/sync_engine.dart';
import '../../core/services/sync/sync_models.dart';
import '../../core/services/sync/sync_pair_qr.dart';
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
    case 'fingerprint_mismatch':
      return l10n.lanSyncPairErrorFingerprintMismatch;
    case 'no_endpoint_in_qr':
      return l10n.lanSyncPairErrorNoEndpointInQr;
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

/// Message for a scanned string that is not a usable pairing QR.
String syncQrErrorMessage(AppLocalizations l10n, SyncPairQrException error) {
  switch (error.code) {
    case 'bad_version':
      return l10n.lanSyncPairErrorQrBadVersion;
    case 'malformed':
      return l10n.lanSyncPairErrorInvalidQr;
    case 'not_pairing_qr':
    default:
      return l10n.lanSyncPairErrorNotPairingQr;
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
    entityRows: report.entityRows,
    preferenceRows: report.preferenceRows,
    blobsMoved: report.blobsMoved,
    skillsUpdated: report.skillsUpdated,
    skillConflicts: report.skillConflicts,
    blobsMissing: report.blobsMissing,
    entityRowsLost: report.entityRowsLost,
    preferencesLost: report.preferencesLost,
    clockSkewMs: report.clockSkewMs,
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
    entityRows: report.entityRows,
    preferenceRows: report.preferenceRows,
    blobsMoved: report.blobsMoved,
    skillsUpdated: report.skillsUpdated,
    skillConflicts: report.skillConflicts,
    blobsMissing: report.blobsMissing,
    entityRowsLost: report.entityRowsLost,
    preferencesLost: report.preferencesLost,
    clockSkewMs: report.clockSkewMs,
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
  required int entityRows,
  required int preferenceRows,
  int blobsMoved = 0,
  int skillsUpdated = 0,
  int skillConflicts = 0,
  int blobsMissing = 0,
  int entityRowsLost = 0,
  int preferencesLost = 0,
  int? clockSkewMs,
}) {
  final parts = <String>[
    l10n.lanSyncReportSent(sent),
    l10n.lanSyncReportReceived(received),
    if (upserted > 0) l10n.lanSyncReportMessagesUpserted(upserted),
    if (deleted > 0) l10n.lanSyncReportMessagesDeleted(deleted),
    if (deletedConversations > 0)
      l10n.lanSyncReportConversationsDeleted(deletedConversations),
    if (entityRows > 0) l10n.lanSyncReportEntities(entityRows),
    if (preferenceRows > 0) l10n.lanSyncReportPreferences(preferenceRows),
    if (blobsMoved > 0) l10n.lanSyncReportBlobs(blobsMoved),
    if (skillsUpdated > 0) l10n.lanSyncReportSkills(skillsUpdated),
    // "Nothing silent": both the discarded local edit and the blob that never
    // arrived are named in the summary rather than left to a log.
    if (skillConflicts > 0) l10n.lanSyncReportSkillConflicts(skillConflicts),
    if (entityRowsLost + preferencesLost > 0)
      l10n.lanSyncReportRowsLost(entityRowsLost + preferencesLost),
    if (blobsMissing > 0) l10n.lanSyncReportBlobsMissing(blobsMissing),
    if (deferred > 0) l10n.lanSyncReportDeferred(deferred),
    if (clockSkewMs != null)
      l10n.lanSyncReportClockSkew((clockSkewMs.abs() / 60000).round()),
  ];
  return parts.join(' · ');
}

String syncLastSyncedLabel(AppLocalizations l10n, DateTime? at) {
  if (at == null) return l10n.lanSyncNeverSynced;
  return l10n.lanSyncLastSyncedAt(
    DateFormat('yyyy-MM-dd HH:mm').format(at.toLocal()),
  );
}
