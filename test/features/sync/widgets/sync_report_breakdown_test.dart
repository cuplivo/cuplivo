import 'package:Cuplivo/core/services/sync/sync_models.dart';
import 'package:Cuplivo/features/sync/widgets/sync_report_breakdown.dart';
import 'package:Cuplivo/l10n/app_localizations.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('the up-to-date chip never covers a withheld item', (
    tester,
  ) async {
    final l10n = await AppLocalizations.delegate.load(const Locale('en'));

    Future<void> pump(SyncPeerReport report) async {
      await tester.pumpWidget(
        MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(body: SyncReportBreakdown(report: report)),
        ),
      );
      await tester.pump();
    }

    // Nothing moved and nothing is owed: the chip is the whole story.
    await pump(const SyncPeerReport(success: true));
    expect(find.text(l10n.lanSyncUpToDate), findsOneWidget);

    // A blob that never arrived is data this card does not hold. The sentence
    // row names it, and the chip must not claim currency over that row.
    await pump(const SyncPeerReport(success: true, blobsMissing: 1));
    expect(find.text(l10n.lanSyncUpToDate), findsNothing);
    expect(find.text(l10n.lanSyncReportBlobsMissing(1)), findsOneWidget);

    // Same for a conversation this device deferred rather than applied.
    await pump(const SyncPeerReport(success: true, deferred: 1));
    expect(find.text(l10n.lanSyncUpToDate), findsNothing);
    expect(find.text(l10n.lanSyncReportDeferred(1)), findsOneWidget);

    // Withheld or not, a session that moved something reports its counters.
    await pump(const SyncPeerReport(success: true, sent: 2, received: 1));
    expect(find.text(l10n.lanSyncUpToDate), findsNothing);
    expect(find.text(l10n.lanSyncReportSent(2)), findsOneWidget);
  });
}
