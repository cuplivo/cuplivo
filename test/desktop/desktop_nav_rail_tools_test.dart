import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:Cuplivo/core/providers/settings_provider.dart';
import 'package:Cuplivo/core/providers/user_provider.dart';
import 'package:Cuplivo/desktop/desktop_nav_rail.dart';
import 'package:Cuplivo/l10n/app_localizations.dart';

import '../support/business_test_harness.dart';

void main() {
  testWidgets('every tool keeps its own button on the desktop rail', (
    tester,
  ) async {
    final preferences = createBusinessTestPreferences();
    final settings = SettingsProvider(preferences);
    final user = UserProvider(preferences: preferences);
    addTearDown(settings.dispose);
    addTearDown(user.dispose);
    await settings.loaded;

    final selected = <int>[];
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<SettingsProvider>.value(value: settings),
          ChangeNotifierProvider<UserProvider>.value(value: user),
        ],
        child: MaterialApp(
          locale: const Locale('en'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(
            body: Row(
              children: [
                DesktopNavRail(
                  activeIndex: 0,
                  globalSearchActive: false,
                  onTapChat: () {},
                  onTapGlobalSearch: () {},
                  onSelectTab: selected.add,
                  onTapSettings: () {},
                ),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // The rail has the room, so tools are not folded behind a menu: each one is
    // one tap away, in the shared order.
    expect(find.byTooltip('Translate'), findsOneWidget);
    expect(find.byTooltip('Storage'), findsOneWidget);
    expect(find.byTooltip('Markdown image'), findsOneWidget);

    await tester.tap(find.byTooltip('Markdown image'));
    await tester.pumpAndSettle();
    expect(selected, [4]);
  });
}
