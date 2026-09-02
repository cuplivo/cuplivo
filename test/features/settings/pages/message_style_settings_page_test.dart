import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:Cuplivo/core/database/business_preferences.dart';
import 'package:Cuplivo/core/providers/assistant_provider.dart';
import 'package:Cuplivo/core/providers/settings_provider.dart';
import 'package:Cuplivo/features/settings/pages/message_style_settings_page.dart';
import 'package:Cuplivo/l10n/app_localizations.dart';

var businessPrefs = BusinessPreferences.memoryForTests();

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<void> pumpPage(
    WidgetTester tester, {
    required SettingsProvider settings,
  }) async {
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          Provider<BusinessPreferences>.value(value: businessPrefs),
          ChangeNotifierProvider<SettingsProvider>.value(value: settings),
          ChangeNotifierProvider(
            create: (_) => AssistantProvider(preferences: businessPrefs),
          ),
        ],
        child: const MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: MessageStyleSettingsPage(),
        ),
      ),
    );
    await tester.pump();
  }

  Future<SettingsProvider> createSettings() async {
    SharedPreferences.setMockInitialValues({});
    businessPrefs = BusinessPreferences.memoryForTests();
    final settings = SettingsProvider(preferences: businessPrefs);
    await settings.loaded;
    return settings;
  }

  testWidgets(
    'default style keeps preview next to the picker and hides knobs',
    (tester) async {
      final settings = await createSettings();

      await pumpPage(tester, settings: settings);

      expect(find.text('Message Style'), findsOneWidget);
      expect(find.text('This is a user message'), findsWidgets);
      expect(
        find.text(
          'Default style follows the current theme and has no extra controls.',
        ),
        findsOneWidget,
      );
      expect(find.text('Blur'), findsNothing);
      expect(find.text('Background'), findsNothing);
      expect(find.text('Light'), findsOneWidget);
      expect(find.text('Dark'), findsOneWidget);
    },
  );

  testWidgets('frosted style reveals knobs under the preview', (tester) async {
    final settings = await createSettings();

    await pumpPage(tester, settings: settings);

    await tester.tap(find.text('Frosted Glass'));
    await tester.pumpAndSettle();

    expect(
      find.text(
        'Default style follows the current theme and has no extra controls.',
      ),
      findsNothing,
    );
    expect(find.text('Blur'), findsOneWidget);
    expect(find.text('Background'), findsOneWidget);
    expect(find.text('This is a user message'), findsWidgets);
  });

  testWidgets('light and dark preview labels stay after switching', (
    tester,
  ) async {
    final settings = await createSettings();

    await pumpPage(tester, settings: settings);

    expect(
      tester
          .widget<Theme>(find.byKey(const ValueKey<bool>(false)))
          .data
          .brightness,
      Brightness.light,
    );

    await tester.tap(find.text('Dark'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));

    expect(find.text('Light'), findsOneWidget);
    expect(find.text('Dark'), findsOneWidget);
    expect(find.text('This is a user message'), findsOneWidget);
    expect(
      tester
          .widget<Theme>(find.byKey(const ValueKey<bool>(true)))
          .data
          .brightness,
      Brightness.dark,
    );
  });
}
