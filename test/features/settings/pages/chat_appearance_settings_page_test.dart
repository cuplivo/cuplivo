import 'package:Cuplivo/core/providers/settings_provider.dart';
import 'package:Cuplivo/features/settings/pages/new/chat_appearance_settings_page.dart';
import 'package:Cuplivo/l10n/app_localizations.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

Widget _buildHarness(Widget home) {
  final settings = SettingsProvider();
  addTearDown(settings.dispose);
  return ChangeNotifierProvider<SettingsProvider>.value(
    value: settings,
    child: MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: home,
    ),
  );
}

AppLocalizations _l10nOf(WidgetTester tester) => AppLocalizations.of(
  tester.element(find.byType(ChatAppearanceSettingsPage)),
)!;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues(const {});
  });

  testWidgets(
    'desktop-only section renders and topic position persists on desktop',
    (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
      try {
        final settings = SettingsProvider();
        addTearDown(settings.dispose);
        await tester.pumpWidget(
          ChangeNotifierProvider<SettingsProvider>.value(
            value: settings,
            child: MaterialApp(
              localizationsDelegates: AppLocalizations.localizationsDelegates,
              supportedLocales: AppLocalizations.supportedLocales,
              home: const ChatAppearanceSettingsPage(),
            ),
          ),
        );
        await tester.pumpAndSettle();

        final l10n = _l10nOf(tester);
        expect(
          find.text(l10n.desktopDisplaySettingsTopicPositionTitle),
          findsOneWidget,
        );
        expect(
          find.text(l10n.desktopShowProviderInModelCapsule),
          findsOneWidget,
        );

        await tester.scrollUntilVisible(
          find.text(l10n.desktopDisplaySettingsTopicPositionTitle),
          200,
        );
        await tester.tap(
          find.text(l10n.desktopDisplaySettingsTopicPositionTitle),
        );
        await tester.pumpAndSettle();

        // Both position options are offered in the sheet.
        expect(
          find.text(l10n.desktopDisplaySettingsTopicPositionLeft),
          findsWidgets,
        );
        expect(
          find.text(l10n.desktopDisplaySettingsTopicPositionRight),
          findsOneWidget,
        );

        await tester.tap(
          find.text(l10n.desktopDisplaySettingsTopicPositionRight),
        );
        await tester.pumpAndSettle();

        expect(settings.desktopTopicPosition, DesktopTopicPosition.right);
        final prefs = await SharedPreferences.getInstance();
        expect(prefs.getString('desktop_topic_position_v1'), 'right');
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    },
  );

  testWidgets('desktop-only section is not rendered on mobile platforms', (
    tester,
  ) async {
    await tester.pumpWidget(_buildHarness(const ChatAppearanceSettingsPage()));
    await tester.pumpAndSettle();

    final l10n = _l10nOf(tester);
    expect(
      find.text(l10n.desktopDisplaySettingsTopicPositionTitle),
      findsNothing,
    );
    expect(find.text(l10n.desktopShowProviderInModelCapsule), findsNothing);
  });

  testWidgets('desktop message nav buttons sheet offers all five modes', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    try {
      final settings = SettingsProvider();
      addTearDown(settings.dispose);
      await tester.pumpWidget(
        ChangeNotifierProvider<SettingsProvider>.value(
          value: settings,
          child: MaterialApp(
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: const ChatAppearanceSettingsPage(),
          ),
        ),
      );
      await tester.pumpAndSettle();

      final l10n = _l10nOf(tester);
      await tester.scrollUntilVisible(
        find.text(l10n.displaySettingsPageMessageNavButtonsTitle),
        200,
      );
      await tester.tap(
        find.text(l10n.displaySettingsPageMessageNavButtonsTitle),
      );
      await tester.pumpAndSettle();

      final sheet = find.byType(BottomSheet);
      expect(
        find.descendant(
          of: sheet,
          matching: find.text(
            l10n.displaySettingsPageMessageNavButtonsModeAlways,
          ),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: sheet,
          matching: find.text(
            l10n.displaySettingsPageMessageNavButtonsModeScroll,
          ),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: sheet,
          matching: find.text(
            l10n.displaySettingsPageMessageNavButtonsModeHover,
          ),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: sheet,
          matching: find.text(
            l10n.displaySettingsPageMessageNavButtonsModeScrollAndHover,
          ),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: sheet,
          matching: find.text(
            l10n.displaySettingsPageMessageNavButtonsModeNever,
          ),
        ),
        findsOneWidget,
      );

      await tester.tap(
        find.text(l10n.displaySettingsPageMessageNavButtonsModeHover),
      );
      await tester.pumpAndSettle();

      expect(
        settings.desktopMessageNavButtonsMode,
        DesktopMessageNavButtonsMode.hover,
      );
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });
}
