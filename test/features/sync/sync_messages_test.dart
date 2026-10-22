import 'package:Cuplivo/core/providers/sync_provider.dart';
import 'package:Cuplivo/core/services/sync/sync_engine.dart';
import 'package:Cuplivo/core/services/sync/sync_models.dart';
import 'package:Cuplivo/features/sync/sync_messages.dart';
import 'package:Cuplivo/l10n/app_localizations_en.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/intl.dart';

/// The LAN sync surface's wording is a pure mapping, so it is tested as text.
/// What these cases pin is that the panel renders a localized reason and never
/// engine or exception text — which carries the peer's address and port.
void main() {
  final l10n = AppLocalizationsEn();

  test('every failure reason has its own localized line', () {
    final texts = {
      for (final reason in SyncFailureReason.values)
        reason: syncFailureMessage(l10n, reason),
    };
    expect(texts.values.toSet().length, SyncFailureReason.values.length);
    for (final text in texts.values) {
      expect(text, isNot(contains('Exception')));
      expect(text, isNot(contains('192.168')));
      expect(text, isNot(contains('error:')));
    }
  });

  test('an absent reason falls back to the generic line', () {
    expect(syncFailureMessage(l10n, null), l10n.lanSyncReportInternal);
    expect(
      syncReportMessage(
        l10n,
        const SyncSessionReport(success: false, summary: 'error:boom'),
      ),
      l10n.lanSyncReportInternal,
    );
  });

  test('a failed session renders its reason, never the machine summary', () {
    const report = SyncSessionReport(
      success: false,
      summary:
          'error:SocketException: Connection refused (OS Error: Connection '
          'refused, errno = 111), address = 192.168.1.5, port = 9527',
      failure: SyncFailureReason.unreachable,
    );
    expect(syncReportMessage(l10n, report), l10n.lanSyncReportUnreachable);

    // The persisted record is what the card shows after a restart.
    final persisted = SyncPeerReport.fromJson(report.toPeerReport().toJson());
    expect(persisted.failure, SyncFailureReason.unreachable);
    expect(
      syncFailureMessage(l10n, persisted.failure),
      isNot(contains('192.168')),
    );
  });

  test('a bad address is named as such, not as a bad code', () {
    expect(
      manualPairingFormError(l10n: l10n, host: '', port: '9527', pin: '123456'),
      l10n.lanSyncPairErrorInvalidAddress,
    );
    expect(
      manualPairingFormError(
        l10n: l10n,
        host: '192.168.1.5',
        port: '',
        pin: '123456',
      ),
      l10n.lanSyncPairErrorInvalidAddress,
    );
    expect(
      manualPairingFormError(
        l10n: l10n,
        host: '192.168.1.5',
        port: 'not a port',
        pin: '123456',
      ),
      l10n.lanSyncPairErrorInvalidAddress,
    );
    expect(
      manualPairingFormError(
        l10n: l10n,
        host: '192.168.1.5',
        port: '9527',
        pin: '12345',
      ),
      l10n.lanSyncPairErrorInvalidPin,
    );
    expect(
      manualPairingFormError(
        l10n: l10n,
        host: '192.168.1.5',
        port: '9527',
        pin: '123456',
      ),
      isNull,
    );
  });

  test('a code typed as it is shown is still the code', () {
    // The dialog renders the code as "123 456".
    expect(normalizePairingCode('123 456'), '123456');
    expect(normalizePairingCode(' 123456 '), '123456');
    expect(
      manualPairingFormError(
        l10n: l10n,
        host: '192.168.1.5',
        port: '9527',
        pin: normalizePairingCode('123 456'),
      ),
      isNull,
    );
  });

  test('workspace files are counted, sized, and never silent', () {
    final moved = syncReportMessage(
      l10n,
      const SyncSessionReport(
        success: true,
        summary: 'ignored',
        workspaceFiles: 3,
        workspaceBytes: 2048,
      ),
    );
    expect(
      moved,
      contains(l10n.lanSyncReportWorkspaceFilesWithSize(3, '2.0 KB')),
      reason: 'the chip says how many and how much',
    );

    // Everything the user has to be able to notice is named: an edit the peer
    // replaced, a file that could not be applied, and a workspace that is not
    // syncing at all.
    final warned = syncReportMessage(
      l10n,
      const SyncSessionReport(
        success: true,
        summary: 'ignored',
        workspaceFilesRemoved: 2,
        workspaceConflicts: 1,
        workspaceFilesMissing: 4,
        workspacesOmitted: 1,
      ),
    );
    for (final part in [
      l10n.lanSyncReportWorkspaceRemoved(2),
      l10n.lanSyncReportWorkspaceConflicts(1),
      l10n.lanSyncReportWorkspaceMissing(4),
      l10n.lanSyncReportWorkspacesOmitted(1),
    ]) {
      expect(warned, contains(part));
    }

    // A session that only moved workspace files is still an arrival: the files
    // are on this device now, in a file manager the user can open.
    expect(
      syncBroughtDataHere(
        const SyncSessionReport(
          success: true,
          summary: 'ignored',
          workspaceFiles: 1,
        ),
      ),
      isTrue,
    );
    expect(
      syncBroughtDataHere(
        const SyncSessionReport(
          success: true,
          summary: 'ignored',
          workspaceFilesRemoved: 1,
        ),
      ),
      isTrue,
      reason: 'a deletion that landed here is news too',
    );
  });

  test('a peer with no address asks for one, not for a retry', () {
    const report = SyncSessionReport(
      success: false,
      summary: 'no_endpoint',
      failure: SyncFailureReason.noEndpoint,
    );
    expect(syncReportMessage(l10n, report), l10n.lanSyncReportNoEndpoint);
    // The two "nothing answered" shapes must not read as one thing: one is fixed
    // by an address, the other by turning the other device on.
    expect(
      syncReportMessage(l10n, report),
      isNot(syncFailureMessage(l10n, SyncFailureReason.unreachable)),
    );

    // The card shows the persisted record after a restart, so the wire value has
    // to survive the round trip — and it must not come back as `unreachable`,
    // which is what a record of this shape used to say.
    final persisted = SyncPeerReport.fromJson(report.toPeerReport().toJson());
    expect(persisted.failure, SyncFailureReason.noEndpoint);
  });

  test('the dial beat names the address, and never a rank', () {
    // The dial is the one beat that can hang on an address that will never
    // answer, so the label has to say which one — an unqualified "connecting…"
    // turns a diagnosable wait into a mystery. Which *number* candidate it is is
    // not part of that: the probe already ranked every address in parallel
    // before the dial spent its answer, so a rank would describe an
    // implementation detail the user cannot act on.
    expect(
      syncPhaseLabel(
        l10n,
        const SyncSessionProgress(
          SyncSessionPhase.connecting,
          address: '192.168.1.5:9527',
        ),
      ),
      l10n.lanSyncPhaseConnectingTo('192.168.1.5:9527'),
    );
    // No address yet (the probe is still running, or a beat has not landed):
    // the plain label, never the address form with empty parts.
    expect(
      syncPhaseLabel(
        l10n,
        const SyncSessionProgress(SyncSessionPhase.connecting),
      ),
      l10n.lanSyncPhaseConnecting,
    );
    expect(
      syncPhaseLabel(
        l10n,
        const SyncSessionProgress(SyncSessionPhase.files, done: 2, total: 7),
      ),
      l10n.lanSyncPhaseFiles(2, 7),
    );
  });

  test('a report row is drawn for anything but a routine absence', () {
    // The card asks this before it renders its report area at all, so a false
    // answer also means no empty gap above it. An unreachable peer is the state
    // the subtitle already names — one fact, said once — while every outcome a
    // user can act on keeps its row.
    expect(syncReportHasRow(const SyncPeerReport(success: true)), isTrue);
    expect(
      syncReportHasRow(
        const SyncPeerReport(
          success: false,
          refusal: SyncRefusalReason.notPaired,
        ),
      ),
      isTrue,
      reason: 'a refusal carries the re-pair gesture',
    );
    expect(
      syncReportHasRow(
        const SyncPeerReport(
          success: false,
          failure: SyncFailureReason.timeout,
        ),
      ),
      isTrue,
    );
    expect(
      syncReportHasRow(
        const SyncPeerReport(
          success: false,
          failure: SyncFailureReason.unreachable,
        ),
      ),
      isFalse,
      reason: 'the subtitle already says the peer is away',
    );
    expect(
      syncReportHasRow(
        const SyncPeerReport(
          success: false,
          failure: SyncFailureReason.noEndpoint,
        ),
      ),
      isTrue,
      reason: 'a peer with no address needs one, and this row is where it asks',
    );
  });

  test('a recent session reads as how long ago, not as a timestamp', () {
    final now = DateTime(2026, 3, 4, 12);
    String ago(Duration elapsed) =>
        syncLastSyncedLabel(l10n, now.subtract(elapsed), now: now);

    expect(ago(const Duration(seconds: 20)), l10n.lanSyncJustSynced);
    // A bare phrase: this label shares the card's subtitle with the platform
    // ("Android · 3 min ago"), so "Last synced" would be said twice.
    expect(ago(const Duration(minutes: 3)), l10n.lanSyncMinutesAgo(3));
    expect(ago(const Duration(hours: 5)), l10n.lanSyncHoursAgo(5));
    expect(ago(const Duration(days: 3)), l10n.lanSyncDaysAgo(3));

    // Past a week the date is the more useful fact.
    expect(
      ago(const Duration(days: 9)),
      DateFormat('yyyy-MM-dd').format(now.subtract(const Duration(days: 9))),
    );

    // A stamp in the future is a clock that disagreed, not a countdown: the card
    // is about the past and must not read "in 4 minutes".
    expect(ago(const Duration(minutes: -4)), l10n.lanSyncJustSynced);
    expect(syncLastSyncedLabel(l10n, null), l10n.lanSyncNeverSynced);
  });

  test('an endpoint detail row reads as a standalone phrase', () {
    final now = DateTime(2026, 3, 4, 12);
    String ago(Duration elapsed) =>
        syncElapsedLabel(l10n, now.subtract(elapsed), now: now);

    expect(ago(const Duration(seconds: 20)), l10n.lanSyncJustNow);
    expect(ago(const Duration(minutes: 8)), l10n.lanSyncMinutesAgo(8));
    expect(ago(const Duration(days: 3)), l10n.lanSyncDaysAgo(3));
    // "12 d ago" is not more useful than the day it happened.
    expect(
      ago(const Duration(days: 12)),
      DateFormat('yyyy-MM-dd').format(now.subtract(const Duration(days: 12))),
    );
    // The two "nothing ever happened" rows: a detail row cannot lean on a
    // sentence around it, so the value itself has to say it.
    expect(syncElapsedLabel(l10n, null), l10n.lanSyncNever);
    expect(syncAddedAtLabel(l10n, now), DateFormat('yyyy-MM-dd').format(now));
  });

  test('a refusal is the message even beside a failure reason', () {
    const report = SyncSessionReport(
      success: false,
      summary: 'refused:not_paired',
      refusal: SyncRefusalReason.notPaired,
      failure: SyncFailureReason.internal,
    );
    expect(
      syncReportMessage(l10n, report),
      syncRefusalMessage(l10n, SyncRefusalReason.notPaired),
    );
    expect(report.toPeerReport().failure, isNull);
  });
}
