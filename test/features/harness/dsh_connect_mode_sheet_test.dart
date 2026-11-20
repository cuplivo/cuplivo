import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:Cuplivo/features/harness/pages/connect/dsh_connect_mode_sheet.dart';
import 'package:Cuplivo/l10n/app_localizations.dart';

/// The third create-menu row opens the engine sheet; phase 1 offers exactly
/// the direct row and returns [DshConnectMode.direct] for the create flow.
void main() {
  testWidgets('the engine sheet offers direct connection and returns it', (
    tester,
  ) async {
    DshConnectMode? result;
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: TextButton(
                onPressed: () async {
                  result = await showDshConnectModeSheet(context);
                },
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    expect(find.text('Connect to a new DeepSeek Harness'), findsOneWidget);
    expect(find.byKey(const Key('dsh-engine-mode')), findsOneWidget);
    expect(find.text('Direct connection'), findsOneWidget);

    await tester.tap(find.byKey(const Key('dsh-engine-mode')));
    await tester.pumpAndSettle();
    expect(result, DshConnectMode.direct);
  });
}
