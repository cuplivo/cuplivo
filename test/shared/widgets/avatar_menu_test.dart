import 'package:Cuplivo/core/providers/settings_provider.dart';
import 'package:Cuplivo/l10n/app_localizations.dart';
import 'package:Cuplivo/shared/widgets/avatar_menu.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import '../../support/business_test_harness.dart';

/// One menu for every avatar in the app: the five rows, in a fixed order, and
/// the two outcomes a caller has to handle — a new value, or back to default.
void main() {
  Future<void> pumpHost(
    WidgetTester tester, {
    required String? value,
    required ValueChanged<String?> onSelected,
  }) async {
    await tester.pumpWidget(
      ChangeNotifierProvider(
        // The action tiles read the haptics preference on tap.
        create: (_) => SettingsProvider(createBusinessTestPreferences()),
        child: MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          locale: const Locale('en'),
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () => showAvatarMenu(
                  context,
                  value: value,
                  onSelected: onSelected,
                ),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
  }

  testWidgets('offers the five ways to set an avatar', (tester) async {
    await pumpHost(tester, value: '🙂', onSelected: (_) {});

    expect(find.text('Choose Image'), findsOneWidget);
    expect(find.text('Choose Emoji'), findsOneWidget);
    expect(find.text('Enter Link'), findsOneWidget);
    expect(find.text('Import from QQ'), findsOneWidget);
    expect(find.text('Reset'), findsOneWidget);
  });

  testWidgets('reset reports a cleared avatar', (tester) async {
    String? selected = 'keep';
    await pumpHost(
      tester,
      value: '🙂',
      onSelected: (value) => selected = value,
    );

    await tester.tap(find.text('Reset'));
    await tester.pumpAndSettle();

    expect(selected, isNull);
  });

  testWidgets('a link is validated and handed back trimmed', (tester) async {
    String? selected;
    await pumpHost(
      tester,
      value: null,
      onSelected: (value) => selected = value,
    );

    await tester.tap(find.text('Enter Link'));
    await tester.pumpAndSettle();

    TextButton saveButton() =>
        tester.widget<TextButton>(find.widgetWithText(TextButton, 'Save'));
    expect(saveButton().onPressed, isNull);

    await tester.enterText(
      find.byType(TextField),
      '  https://example.com/a.png  ',
    );
    await tester.pump();
    expect(saveButton().onPressed, isNotNull);

    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();

    expect(selected, 'https://example.com/a.png');
  });
}
