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

  testWidgets('workspace files are a chip, and their failures are rows', (
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

    await pump(
      const SyncPeerReport(
        success: true,
        workspaceFiles: 3,
        workspaceBytes: 2048,
      ),
    );
    expect(
      find.text(l10n.lanSyncReportWorkspaceFilesWithSize(3, '2.0 KB')),
      findsOneWidget,
      reason: 'how many and how much, like the blob face',
    );
    expect(find.text(l10n.lanSyncUpToDate), findsNothing);

    await pump(const SyncPeerReport(success: true, workspaceFilesRemoved: 2));
    expect(find.text(l10n.lanSyncReportWorkspaceRemoved(2)), findsOneWidget);

    // A file that could not be applied is data this device does not hold: it is
    // a sentence row and it suppresses the up-to-date chip.
    await pump(const SyncPeerReport(success: true, workspaceFilesMissing: 1));
    expect(find.text(l10n.lanSyncUpToDate), findsNothing);
    expect(find.text(l10n.lanSyncReportWorkspaceMissing(1)), findsOneWidget);

    // A local edit the peer's version replaced, and a workspace that is not
    // syncing at all, are each their own sentence.
    await pump(const SyncPeerReport(success: true, workspaceConflicts: 1));
    expect(find.text(l10n.lanSyncReportWorkspaceConflicts(1)), findsOneWidget);
    await pump(const SyncPeerReport(success: true, workspacesOmitted: 1));
    expect(find.text(l10n.lanSyncReportWorkspacesOmitted(1)), findsOneWidget);
  });

  testWidgets('an unreachable session leaves the report area empty', (
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

    // A peer that did not answer is routine on a LAN — asleep, off the Wi-Fi —
    // and the card's subtitle already says so. This area draws *nothing* for it:
    // not even the soft note it used to carry, which repeated the subtitle one
    // line lower.
    await pump(
      const SyncPeerReport(
        success: false,
        failure: SyncFailureReason.unreachable,
      ),
    );
    expect(
      find.byType(Text),
      findsNothing,
      reason: 'a routine absence is a state, not a row',
    );

    // Deleting that row must not delete the failures that do need saying, so the
    // neighbour is asserted from the same pump helper.
    await pump(
      const SyncPeerReport(success: false, failure: SyncFailureReason.timeout),
    );
    expect(
      find.text(l10n.lanSyncReportTimeout),
      findsOneWidget,
      reason: 'a failure the user can act on keeps its row',
    );
  });
}
