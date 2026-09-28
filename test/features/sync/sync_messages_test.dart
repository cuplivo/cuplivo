import 'package:Cuplivo/core/services/sync/sync_engine.dart';
import 'package:Cuplivo/core/services/sync/sync_models.dart';
import 'package:Cuplivo/features/sync/sync_messages.dart';
import 'package:Cuplivo/l10n/app_localizations_en.dart';
import 'package:flutter_test/flutter_test.dart';

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
    expect(
      syncPeerReportMessage(l10n, persisted),
      l10n.lanSyncReportUnreachable,
    );
    expect(syncPeerReportMessage(l10n, persisted), isNot(contains('192.168')));
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
