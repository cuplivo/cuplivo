import 'package:Cuplivo/core/providers/settings_provider.dart';
import 'package:Cuplivo/features/settings/pages/new/font_settings_page.dart';
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
      locale: const Locale('en'),
      home: home,
    ),
  );
}

AppLocalizations _l10nOf(WidgetTester tester) =>
    AppLocalizations.of(tester.element(find.byType(FontSettingsPage)))!;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues(const {});
  });

  testWidgets('app font source sheet offers System Fonts on desktop', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    try {
      await tester.pumpWidget(_buildHarness(const FontSettingsPage()));
      await tester.pumpAndSettle();

      final l10n = _l10nOf(tester);
      await tester.tap(find.text(l10n.displaySettingsPageAppFontTitle));
      await tester.pumpAndSettle();

      expect(find.text(l10n.fontPickerChooseLocalFile), findsOneWidget);
      expect(find.text(l10n.fontPickerGetFromGoogleFonts), findsOneWidget);
      expect(find.text(l10n.newSettingsSystemFontOption), findsOneWidget);
      expect(find.text(l10n.displaySettingsPageFontResetLabel), findsOneWidget);
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });

  testWidgets('app font source sheet hides System Fonts on mobile', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    try {
      await tester.pumpWidget(_buildHarness(const FontSettingsPage()));
      await tester.pumpAndSettle();

      final l10n = _l10nOf(tester);
      await tester.tap(find.text(l10n.displaySettingsPageAppFontTitle));
      await tester.pumpAndSettle();

      expect(find.text(l10n.fontPickerChooseLocalFile), findsOneWidget);
      expect(find.text(l10n.fontPickerGetFromGoogleFonts), findsOneWidget);
      expect(find.text(l10n.newSettingsSystemFontOption), findsNothing);
      expect(find.text(l10n.displaySettingsPageFontResetLabel), findsOneWidget);
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });

  testWidgets('app font System Fonts option opens the chooser dialog on '
      'desktop', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    try {
      await tester.pumpWidget(_buildHarness(const FontSettingsPage()));
      await tester.pumpAndSettle();

      final l10n = _l10nOf(tester);
      await tester.tap(find.text(l10n.displaySettingsPageAppFontTitle));
      await tester.pumpAndSettle();

      await tester.tap(find.text(l10n.newSettingsSystemFontOption));
      await tester.pumpAndSettle();

      // SystemFonts() plugin is unavailable in tests, so the chooser falls
      // back to the hardcoded family list; the dialog itself must appear.
      expect(find.byType(Dialog), findsOneWidget);
      expect(find.text(l10n.desktopFontFilterHint), findsOneWidget);
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });
}
