import 'package:Cuplivo/core/providers/settings_provider.dart';
import 'package:Cuplivo/features/settings/pages/new/color_theme_settings_page.dart';
import 'package:Cuplivo/features/settings/pages/theme_settings_page.dart';
import 'package:Cuplivo/l10n/app_localizations.dart';
import 'package:Cuplivo/shared/widgets/snackbar.dart';
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
      home: AppSnackBarOverlay(child: home),
    ),
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues(const {});
  });

  testWidgets('renders color mode, theme palette and import-app-theme rows', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(800, 1400));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(_buildHarness(const ColorThemeSettingsPage()));
    await tester.pumpAndSettle();

    final l10n = AppLocalizations.of(
      tester.element(find.byType(ColorThemeSettingsPage)),
    )!;
    expect(find.text(l10n.settingsPageColorMode), findsOneWidget);
    expect(
      find.text(l10n.displaySettingsPageThemeSettingsTitle),
      findsOneWidget,
    );
    expect(find.text(l10n.newSettingsImportAppThemeTitle), findsOneWidget);
    expect(find.text(l10n.newSettingsComingSoon), findsOneWidget);
  });

  testWidgets('tapping the theme palette row pushes ThemeSettingsPage', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(800, 1400));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(_buildHarness(const ColorThemeSettingsPage()));
    await tester.pumpAndSettle();

    final l10n = AppLocalizations.of(
      tester.element(find.byType(ColorThemeSettingsPage)),
    )!;
    await tester.tap(find.text(l10n.displaySettingsPageThemeSettingsTitle));
    await tester.pumpAndSettle();

    expect(find.byType(ThemeSettingsPage), findsOneWidget);
  });

  testWidgets('tapping the coming-soon row shows the coming-soon snackbar', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(800, 1400));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(_buildHarness(const ColorThemeSettingsPage()));
    await tester.pumpAndSettle();

    final l10n = AppLocalizations.of(
      tester.element(find.byType(ColorThemeSettingsPage)),
    )!;
    await tester.tap(find.text(l10n.newSettingsImportAppThemeTitle));
    await tester.pump();
    await tester.pump();

    expect(find.text(l10n.newSettingsComingSoonMessage), findsOneWidget);

    // Let the auto-dismiss timer fire and the exit animation finish.
    await tester.pump(const Duration(seconds: 4));
    await tester.pumpAndSettle();
  });
}
