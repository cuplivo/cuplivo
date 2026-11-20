import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:Cuplivo/features/harness/widgets/dsh_remote_file_card.dart';
import 'package:Cuplivo/l10n/app_localizations.dart';

void main() {
  Widget host(Widget child) => MaterialApp(
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    home: Scaffold(body: child),
  );

  testWidgets('a missing file gets its own reason, not a generic error', (
    tester,
  ) async {
    await tester.pumpWidget(
      host(
        const DshRemoteFileCard(
          name: 'report.pdf',
          path: 'docs/report.pdf',
          reason: DshRemoteFileCardReason.notFound,
        ),
      ),
    );

    expect(find.byKey(DshRemoteFileCard.rootKey), findsOneWidget);
    expect(find.text('report.pdf'), findsOneWidget);
    expect(find.text('File not available'), findsOneWidget);
    expect(find.text('docs/report.pdf'), findsOneWidget);
    expect(find.byKey(DshRemoteFileCard.retryKey), findsNothing);
  });

  testWidgets('oversize and load failures read differently', (tester) async {
    await tester.pumpWidget(
      host(
        const DshRemoteFileCard(
          name: 'big.log',
          reason: DshRemoteFileCardReason.tooLarge,
        ),
      ),
    );
    expect(
      find.text(
        'This file is too large to preview. Open it externally instead.',
      ),
      findsOneWidget,
    );

    await tester.pumpWidget(
      host(
        const DshRemoteFileCard(
          name: 'big.log',
          reason: DshRemoteFileCardReason.loadFailed,
        ),
      ),
    );
    expect(find.text('Couldn’t load this file.'), findsOneWidget);
  });

  testWidgets('unsupported and unavailable-WebView share the honest message', (
    tester,
  ) async {
    for (final reason in <DshRemoteFileCardReason>[
      DshRemoteFileCardReason.unsupported,
      DshRemoteFileCardReason.webPreviewUnavailable,
    ]) {
      await tester.pumpWidget(
        host(DshRemoteFileCard(name: 'blob.bin', reason: reason)),
      );
      expect(
        find.text('This file can’t be previewed'),
        findsOneWidget,
        reason: 'reason $reason',
      );
    }
  });

  testWidgets('no connection shows the hint, no session its own sentence', (
    tester,
  ) async {
    await tester.pumpWidget(
      host(
        const DshRemoteFileCard(
          name: 'file.txt',
          reason: DshRemoteFileCardReason.noConnection,
        ),
      ),
    );
    expect(
      find.text('Remote file browsing isn’t available in this build'),
      findsOneWidget,
    );
    expect(
      find.text(
        'Connect the DeepSeek Harness client to browse workspace files here.',
      ),
      findsOneWidget,
    );

    await tester.pumpWidget(
      host(
        const DshRemoteFileCard(
          name: 'file.txt',
          reason: DshRemoteFileCardReason.noSession,
        ),
      ),
    );
    expect(find.text('Open a session first'), findsOneWidget);
  });

  testWidgets('size is formatted and retry invokes its callback', (
    tester,
  ) async {
    var retries = 0;
    await tester.pumpWidget(
      host(
        DshRemoteFileCard(
          name: 'notes.md',
          path: 'notes.md',
          reason: DshRemoteFileCardReason.loadFailed,
          size: 2048,
          onRetry: () => retries++,
        ),
      ),
    );

    expect(find.textContaining('2.0 KB'), findsOneWidget);
    await tester.tap(find.byKey(DshRemoteFileCard.retryKey));
    await tester.pump();
    expect(retries, 1);
  });
}
