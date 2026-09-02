import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:Cuplivo/core/database/business_preferences.dart';
import 'package:Cuplivo/core/providers/assistant_provider.dart';
import 'package:Cuplivo/core/providers/settings_provider.dart';
import 'package:Cuplivo/features/settings/pages/message_style_settings_page.dart';
import 'package:Cuplivo/l10n/app_localizations.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('desktop dialog opens the shared message style body', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    final businessPrefs = BusinessPreferences.memoryForTests();
    final settings = SettingsProvider(preferences: businessPrefs);
    await settings.loaded;

    tester.view.physicalSize = const Size(1200, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      MultiProvider(
        providers: [
          Provider<BusinessPreferences>.value(value: businessPrefs),
          ChangeNotifierProvider<SettingsProvider>.value(value: settings),
          ChangeNotifierProvider(
            create: (_) => AssistantProvider(preferences: businessPrefs),
          ),
        ],
        child: MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () => showMessageStyleSettingsDialog(context),
                child: const Text('open-message-style'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    await tester.tap(find.text('open-message-style'));
    await tester.pumpAndSettle();

    expect(find.byType(MessageStyleSettingsBody), findsOneWidget);
    expect(find.text('Message Style'), findsWidgets);
    expect(find.text('Frosted Glass'), findsOneWidget);
  });
}
