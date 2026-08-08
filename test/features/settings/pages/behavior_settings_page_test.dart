import 'package:Cuplivo/core/providers/hotkey_provider.dart';
import 'package:Cuplivo/core/providers/settings_provider.dart';
import 'package:Cuplivo/features/settings/pages/new/behavior_settings_page.dart';
import 'package:Cuplivo/features/settings/widgets/ios_settings_widgets.dart';
import 'package:Cuplivo/l10n/app_localizations.dart';
import 'package:Cuplivo/shared/widgets/ios_switch.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

(Widget, SettingsProvider) _buildHarness(Widget home) {
  final settings = SettingsProvider();
  addTearDown(settings.dispose);
  final hotkeys = HotkeyProvider();
  addTearDown(hotkeys.dispose);
  return (
    MultiProvider(
      providers: [
        ChangeNotifierProvider<SettingsProvider>.value(value: settings),
        ChangeNotifierProvider<HotkeyProvider>.value(value: hotkeys),
      ],
      child: MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: home,
      ),
    ),
    settings,
  );
}

AppLocalizations _l10nOf(WidgetTester tester) =>
    AppLocalizations.of(tester.element(find.byType(BehaviorSettingsPage)))!;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues(const {});
  });

  testWidgets('desktop-only section renders hotkeys and tray switches', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    try {
      final (widget, _) = _buildHarness(const BehaviorSettingsPage());
      await tester.pumpWidget(widget);
      await tester.pumpAndSettle();

      final l10n = _l10nOf(tester);
      await tester.scrollUntilVisible(find.text(l10n.settingsPageHotkeys), 200);

      expect(find.text(l10n.settingsPageHotkeys), findsOneWidget);
      expect(
        find.text(l10n.displaySettingsPageTrayShowTrayTitle),
        findsOneWidget,
      );
      expect(
        find.text(l10n.displaySettingsPageTrayMinimizeOnCloseTitle),
        findsOneWidget,
      );
      expect(
        find.text(l10n.displaySettingsPageAndroidBackgroundChatTitle),
        findsNothing,
      );
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });

  testWidgets('mobile platform shows background chat row without desktop-only '
      'section', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    try {
      final (widget, _) = _buildHarness(const BehaviorSettingsPage());
      await tester.pumpWidget(widget);
      await tester.pumpAndSettle();

      final l10n = _l10nOf(tester);
      await tester.scrollUntilVisible(
        find.text(l10n.displaySettingsPageAndroidBackgroundChatTitle),
        200,
      );

      expect(
        find.text(l10n.displaySettingsPageAndroidBackgroundChatTitle),
        findsOneWidget,
      );
      expect(find.text(l10n.settingsPageHotkeys), findsNothing);
      expect(
        find.text(l10n.displaySettingsPageTrayShowTrayTitle),
        findsNothing,
      );
      expect(
        find.text(l10n.displaySettingsPageTrayMinimizeOnCloseTitle),
        findsNothing,
      );
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });

  testWidgets('desktop send shortcut sheet persists Ctrl+Enter selection', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    try {
      final (widget, settings) = _buildHarness(const BehaviorSettingsPage());
      await tester.pumpWidget(widget);
      await tester.pumpAndSettle();

      final l10n = _l10nOf(tester);
      await tester.scrollUntilVisible(
        find.text(l10n.displaySettingsPageSendShortcutTitle),
        200,
      );
      expect(
        find.text(l10n.displaySettingsPageSendShortcutTitle),
        findsOneWidget,
      );

      await tester.tap(find.text(l10n.displaySettingsPageSendShortcutTitle));
      await tester.pumpAndSettle();

      // Row detail + sheet option both show "Enter" by default.
      expect(
        find.text(l10n.displaySettingsPageSendShortcutEnter),
        findsWidgets,
      );
      expect(
        find.text(l10n.displaySettingsPageSendShortcutCtrlEnter),
        findsOneWidget,
      );

      await tester.tap(
        find.text(l10n.displaySettingsPageSendShortcutCtrlEnter),
      );
      await tester.pumpAndSettle();

      expect(settings.desktopSendShortcut, DesktopSendShortcut.ctrlEnter);
      // The sheet is dismissed and the row detail now shows the new mode.
      expect(find.byType(BottomSheet), findsNothing);
      expect(
        find.text(l10n.displaySettingsPageSendShortcutCtrlEnter),
        findsOneWidget,
      );
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });

  testWidgets('desktop auto switch topics switch persists', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    try {
      final (widget, settings) = _buildHarness(const BehaviorSettingsPage());
      await tester.pumpWidget(widget);
      await tester.pumpAndSettle();

      final l10n = _l10nOf(tester);
      await tester.scrollUntilVisible(
        find.text(l10n.displaySettingsPageAutoSwitchTopicsTitle),
        200,
      );

      expect(settings.desktopAutoSwitchTopics, isFalse);

      final row = find.ancestor(
        of: find.text(l10n.displaySettingsPageAutoSwitchTopicsTitle),
        matching: find.byType(IosSettingsSwitchRow),
      );
      await tester.tap(
        find.descendant(of: row, matching: find.byType(IosSwitch)),
      );
      await tester.pumpAndSettle();

      expect(settings.desktopAutoSwitchTopics, isTrue);
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });
}
