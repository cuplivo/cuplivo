import 'package:flutter/widgets.dart';
import 'package:intl/intl.dart';

import '../../core/providers/sync_provider.dart';
import '../../core/services/sync/sync_engine.dart';
import '../../core/services/sync/sync_models.dart';
import '../../core/services/sync/sync_pair_qr.dart';
import '../../icons/lucide_adapter.dart';
import '../../l10n/app_localizations.dart';
import '../../shared/utils/format_bytes.dart';

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

/// The icon a device of [platform] is drawn with — the same shape on both sides
/// of the panel, so this device's row and a peer's card agree about what an
/// Android phone looks like.
IconData syncPlatformIcon(String platform) {
  switch (platform) {
    case 'android':
    case 'ios':
      return Lucide.Smartphone;
    default:
      return Lucide.Monitor;
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
    case SyncRefusalReason.superseded:
      // Nothing to repair and nothing to retry: the peer's own session with
      // this device took the round, and that session reports for the pair. The
      // line exists because the refusal is a value the card can be handed.
      return l10n.lanSyncSupersededByPeer;
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
/// The dial beat names the address, because that is the one beat that can sit
/// for seconds on an address that will never answer — an unqualified
/// "connecting…" turns a diagnosable wait into a mystery. It never names a rank
/// among candidates: the probe ranked them all at once and the dial only walks
/// the addresses the probe reached, so "the second of three" would describe an
/// implementation detail the user cannot act on.
String syncPhaseLabel(AppLocalizations l10n, SyncSessionProgress progress) {
  switch (progress.phase) {
    case SyncSessionPhase.connecting:
      final address = progress.address;
      return address == null
          ? l10n.lanSyncPhaseConnecting
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

/// Whether the card's report area has anything to draw for [report]: a success
/// (its counter chips), a refusal (with the repair gesture that comes with it),
/// or a failure that is not the routine absence.
///
/// A peer that did not answer is the common case on a LAN — asleep, off the
/// Wi-Fi — and the card's subtitle already says so. A report row repeating it
/// would make a routine state look like an incident, and would be the third
/// place the same fact is written.
bool syncReportHasRow(SyncPeerReport report) =>
    report.success ||
    report.refusal != null ||
    report.failure != SyncFailureReason.unreachable;

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
    workspaceFiles: report.workspaceFiles,
    workspaceBytes: report.workspaceBytes,
    workspaceFilesRemoved: report.workspaceFilesRemoved,
    workspaceConflicts: report.workspaceConflicts,
    workspaceFilesMissing: report.workspaceFilesMissing,
    workspaceFoldersKept: report.workspaceFoldersKept,
    workspacesOmitted: report.workspacesOmitted,
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
  int workspaceFiles = 0,
  int workspaceBytes = 0,
  int workspaceFilesRemoved = 0,
  int workspaceConflicts = 0,
  int workspaceFilesMissing = 0,
  int workspaceFoldersKept = 0,
  int workspacesOmitted = 0,
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
    if (workspaceFiles > 0)
      workspaceBytes > 0
          ? l10n.lanSyncReportWorkspaceFilesWithSize(
              workspaceFiles,
              formatBytes(workspaceBytes),
            )
          : l10n.lanSyncReportWorkspaceFiles(workspaceFiles),
    // "Nothing silent": both the discarded local edit and the blob that never
    // arrived are named in the summary rather than left to a log.
    if (skillConflicts > 0) l10n.lanSyncReportSkillConflicts(skillConflicts),
    if (entityRowsLost + preferencesLost > 0)
      l10n.lanSyncReportRowsLost(entityRowsLost + preferencesLost),
    if (blobsMissing > 0) l10n.lanSyncReportBlobsMissing(blobsMissing),
    if (workspaceFilesRemoved > 0)
      l10n.lanSyncReportWorkspaceRemoved(workspaceFilesRemoved),
    if (workspaceConflicts > 0)
      l10n.lanSyncReportWorkspaceConflicts(workspaceConflicts),
    if (workspaceFilesMissing > 0)
      l10n.lanSyncReportWorkspaceMissing(workspaceFilesMissing),
    if (workspacesOmitted > 0)
      l10n.lanSyncReportWorkspacesOmitted(workspacesOmitted),
    // The switch's one visible consequence after a peer-driven deletion: the row
    // is gone here too, and the folder stayed.
    if (workspaceFoldersKept > 0)
      l10n.lanSyncReportWorkspacesKept(workspaceFoldersKept),
    if (deferred > 0) l10n.lanSyncReportDeferred(deferred),
    if (clockSkewMs != null)
      l10n.lanSyncReportClockSkew((clockSkewMs.abs() / 60000).round()),
  ];
  return parts.join(' · ');
}

/// The freshness phrase a peer card's subtitle carries: how long ago this device
/// last had a session with the peer — "2 min ago", "Just synced", "Never
/// synced".
///
/// A bare phrase and not a sentence, because it shares the line with the
/// device's platform ("Android · 2 min ago") and "Last synced" is the same word
/// on every card. How long ago, not a timestamp: the question the line answers
/// is "is this current?", and a date makes the reader do the subtraction. Past a
/// week the absolute day is what it shows — "12 d ago" is not more useful than
/// the day it happened — and the exact time stays one hover away either way.
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
  if (elapsed.inDays >= 7) return _syncAbsoluteStamp(at);
  return _relativeSyncTime(l10n, elapsed);
}

/// The same freshness as a plain stamp, for the card's tooltip.
String syncAbsoluteLastSyncedLabel(AppLocalizations l10n, DateTime at) =>
    l10n.lanSyncLastSyncedAt(_syncAbsoluteStamp(at, withTime: true));

String _syncAbsoluteStamp(DateTime at, {bool withTime = false}) => DateFormat(
  withTime ? 'yyyy-MM-dd HH:mm' : 'yyyy-MM-dd',
).format(at.toLocal());

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

/// A bare elapsed-time phrase for an endpoint detail row — "8 min ago", "3 d
/// ago", or "never" when [at] is null. What it does *not* carry is the
/// sentence around it: these rows are label/value pairs, so the value has to
/// stand alone.
String syncElapsedLabel(AppLocalizations l10n, DateTime? at, {DateTime? now}) {
  if (at == null) return l10n.lanSyncNever;
  final elapsed = (now ?? DateTime.now()).difference(at.toLocal());
  // A stamp in the future — a peer whose clock ran ahead — reads as "just now"
  // rather than as a countdown on a row about the past.
  if (elapsed.isNegative || elapsed.inMinutes < 1) {
    return l10n.lanSyncJustNow;
  }
  if (elapsed.inDays >= 7) return _syncAbsoluteStamp(at);
  return _relativeSyncTime(l10n, elapsed);
}

/// The absolute date an endpoint was added, for the detail's "added" row: which
/// day it joined is the question ("was this the address the office gave me in
/// March?"), and the minute it joined never is.
String syncAddedAtLabel(AppLocalizations l10n, DateTime at) =>
    DateFormat('yyyy-MM-dd').format(at.toLocal());
