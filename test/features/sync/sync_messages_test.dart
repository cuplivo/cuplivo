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

  test('the dial beat names the address, and which candidate it is', () {
    // The dial is the one beat that can hang on an address that will never
    // answer, so the label has to say which one and how many are left — an
    // unqualified "connecting…" turns a diagnosable wait into a mystery.
    expect(
      syncPhaseLabel(
        l10n,
        const SyncSessionProgress(
          SyncSessionPhase.connecting,
          address: '192.168.1.5:9527',
          attempt: 2,
          attempts: 3,
        ),
      ),
      l10n.lanSyncPhaseConnectingAt('192.168.1.5:9527', 2, 3),
    );
    expect(
      syncPhaseLabel(
        l10n,
        const SyncSessionProgress(
          SyncSessionPhase.connecting,
          address: '192.168.1.5:9527',
          attempt: 1,
          attempts: 1,
        ),
      ),
      l10n.lanSyncPhaseConnectingTo('192.168.1.5:9527'),
    );
    // No address yet (the candidate ordering, or a session whose progress has
    // not landed): the plain label, never the address form with empty parts.
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

  test('a recent session reads as how long ago, not as a timestamp', () {
    final now = DateTime(2026, 3, 4, 12);
    String ago(Duration elapsed) =>
        syncLastSyncedLabel(l10n, now.subtract(elapsed), now: now);

    expect(ago(const Duration(seconds: 20)), l10n.lanSyncJustSynced);
    expect(
      ago(const Duration(minutes: 3)),
      l10n.lanSyncLastSyncedAt('3 min ago'),
    );
    expect(ago(const Duration(hours: 5)), l10n.lanSyncLastSyncedAt('5 h ago'));
    expect(ago(const Duration(days: 3)), l10n.lanSyncLastSyncedAt('3 d ago'));

    // Past a week the date is the more useful fact, and the line falls back to
    // the stamp this label used to be.
    expect(
      ago(const Duration(days: 9)),
      l10n.lanSyncLastSyncedAt(
        DateFormat(
          'yyyy-MM-dd HH:mm',
        ).format(now.subtract(const Duration(days: 9))),
      ),
    );

    // A stamp in the future is a clock that disagreed, not a countdown: the card
    // is about the past and must not read "in 4 minutes".
    expect(ago(const Duration(minutes: -4)), l10n.lanSyncJustSynced);
    expect(syncLastSyncedLabel(l10n, null), l10n.lanSyncNeverSynced);
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
