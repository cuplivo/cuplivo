import 'package:Cuplivo/core/providers/settings_provider.dart';
import 'package:Cuplivo/features/settings/pages/auto_retry_page.dart';
import 'package:Cuplivo/l10n/app_localizations.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import '../../../support/business_test_harness.dart';

void main() {
  testWidgets('AutoRetryPage commits typed numbers on dispose', (tester) async {
    final settings = await createBusinessTestPreferences();
    addTearDown(settings.dispose);

    await tester.pumpWidget(
      ChangeNotifierProvider<SettingsProvider>.value(
        value: settings,
        child: const MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: AutoRetryPage(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // First TextField is "Max retries".
    final field = find.byType(TextField).first;
    expect(field, findsOneWidget);
    await tester.enterText(field, '7');
    await tester.pump();

    // Replace the page: dispose without unfocus must still commit.
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();

    expect(settings.autoRetryOptions.maxRetries, 7);
  });

  testWidgets('AutoRetryPage renders the enabled switch and footer', (
    tester,
  ) async {
    final settings = await createBusinessTestPreferences();
    addTearDown(settings.dispose);

    await tester.pumpWidget(
      ChangeNotifierProvider<SettingsProvider>.value(
        value: settings,
        child: const MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: AutoRetryPage(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Enable auto-retry'), findsOneWidget);
    final footer = find.textContaining('only runs if this request');
    await tester.scrollUntilVisible(
      footer,
      240,
      scrollable: find.byType(Scrollable).first,
    );
    expect(footer, findsOneWidget);
  });
}
