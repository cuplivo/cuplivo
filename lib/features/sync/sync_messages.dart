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

/// The digits of a typed pairing code. The app shows the code as `123 456`, so
/// the space a user copies from the screen is not a wrong code.
String normalizePairingCode(String raw) => raw.replaceAll(RegExp(r'\s+'), '');

/// The error for the manual pairing form, or null when it can be submitted.
/// The address and port are named separately from the code: a mistyped address
/// must not send the user to re-check the other device's screen.
String? manualPairingFormError({
  required AppLocalizations l10n,
  required String host,
  required String port,
  required String pin,
}) {
  if (host.trim().isEmpty || int.tryParse(port.trim()) == null) {
    return l10n.lanSyncPairErrorInvalidAddress;
  }
  if (pin.length != 6) return l10n.lanSyncPairErrorInvalidPin;
  return null;
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
    case SyncRefusalReason.identityMismatch:
      return l10n.lanSyncRefusedIdentityMismatch;
    case SyncRefusalReason.busy:
      return l10n.lanSyncRefusedBusy;
  }
}

/// One line for a failed session that was not a refusal. The reason is
/// structured, so no raw exception text — which carries the peer's address —
/// can reach a card or a snackbar; an unrecognized (or absent) reason falls
/// back to the generic line, with the detail left in the logs.
String syncFailureMessage(AppLocalizations l10n, SyncFailureReason? reason) {
  switch (reason) {
    case SyncFailureReason.noEndpoint:
      return l10n.lanSyncReportNoEndpoint;
    case SyncFailureReason.unreachable:
      return l10n.lanSyncReportUnreachable;
    case SyncFailureReason.timeout:
      return l10n.lanSyncReportTimeout;
    case SyncFailureReason.peerError:
      return l10n.lanSyncReportPeerError;
    case SyncFailureReason.internal:
    case null:
      return l10n.lanSyncReportInternal;
  }
}

/// The label for one beat of a running session: what the card says instead of
/// a bare spinner while a first sync moves a whole history.
///
/// The dial beat names the address (and the candidate's rank), because that is
/// the one beat that can sit for seconds on an address that will never answer —
/// an unqualified "connecting…" turns a diagnosable wait into a mystery.
String syncPhaseLabel(AppLocalizations l10n, SyncSessionProgress progress) {
  switch (progress.phase) {
    case SyncSessionPhase.connecting:
      final address = progress.address;
      if (address == null) return l10n.lanSyncPhaseConnecting;
      return progress.attempts > 1
          ? l10n.lanSyncPhaseConnectingAt(
              address,
              progress.attempt,
              progress.attempts,
            )
          : l10n.lanSyncPhaseConnectingTo(address);
    case SyncSessionPhase.exchanging:
      return l10n.lanSyncPhaseExchanging;
    case SyncSessionPhase.sending:
      return l10n.lanSyncPhaseSending;
    case SyncSessionPhase.receiving:
      return l10n.lanSyncPhaseReceiving;
    case SyncSessionPhase.files:
      return progress.total > 0
          ? l10n.lanSyncPhaseFiles(progress.done, progress.total)
          : l10n.lanSyncPhaseFilesNoTotal;
    case SyncSessionPhase.applying:
      return l10n.lanSyncPhaseApplying;
  }
}

/// One-line summary of a session, for the snackbar that covers the desktop pane
/// when a card has scrolled out of view. The card itself renders the structured
/// breakdown instead; this is the line for a toast that has room for one.
String syncReportMessage(AppLocalizations l10n, SyncSessionReport report) {
  if (report.refusal != null) return syncRefusalMessage(l10n, report.refusal!);
  if (!report.success) {
    return syncFailureMessage(l10n, report.failure);
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

/// "Last synced …" for a peer card.
///
/// How long ago, not a timestamp: the question this line answers is "is this
/// current?", and a date makes the reader do the subtraction. Past a week the
/// absolute stamp is what it shows — "12 days ago" is not more useful than the
/// day it happened — and the exact time stays one hover away either way.
String syncLastSyncedLabel(
  AppLocalizations l10n,
  DateTime? at, {
  DateTime? now,
}) {
  if (at == null) return l10n.lanSyncNeverSynced;
  final elapsed = (now ?? DateTime.now()).difference(at.toLocal());
  // A stamp in the future — a peer whose clock ran ahead, or a clock that moved
  // backwards — reads as "just now" rather than as a countdown on a line about
  // the past.
  if (elapsed.isNegative || elapsed.inMinutes < 1) {
    return l10n.lanSyncJustSynced;
  }
  if (elapsed.inDays >= 7) return syncAbsoluteLastSyncedLabel(l10n, at);
  return l10n.lanSyncLastSyncedAt(_relativeSyncTime(l10n, elapsed));
}

/// The same line as a plain stamp, for the tooltip and for anything older than a
/// week.
String syncAbsoluteLastSyncedLabel(AppLocalizations l10n, DateTime at) => l10n
    .lanSyncLastSyncedAt(DateFormat('yyyy-MM-dd HH:mm').format(at.toLocal()));

/// The elapsed time in the largest unit that still says something: minutes,
/// then hours, then days.
///
/// The units are ARB strings rather than a formatter: `intl` dropped
/// `RelativeDateTimeFormatter` in 0.20, and four locales need two words each
/// rather than a dependency.
String _relativeSyncTime(AppLocalizations l10n, Duration elapsed) {
  if (elapsed.inHours < 1) return l10n.lanSyncMinutesAgo(elapsed.inMinutes);
  if (elapsed.inDays < 1) return l10n.lanSyncHoursAgo(elapsed.inHours);
  return l10n.lanSyncDaysAgo(elapsed.inDays);
}
