import 'package:Cuplivo/core/providers/settings_provider.dart';
import 'package:Cuplivo/features/settings/pages/new/cuplivo_settings_page.dart';
import 'package:Cuplivo/l10n/app_localizations.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

Widget _buildHarness(SettingsProvider settings, Widget home) {
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

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues(const {});
  });

  testWidgets('Logs row is absent when both log flags are off', (tester) async {
    await tester.binding.setSurfaceSize(const Size(800, 1400));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final settings = SettingsProvider();
    addTearDown(settings.dispose);
    await tester.pumpWidget(
      _buildHarness(settings, const CuplivoSettingsPage()),
    );
    await tester.pumpAndSettle();

    final l10n = AppLocalizations.of(
      tester.element(find.byType(CuplivoSettingsPage)),
    )!;
    expect(find.text(l10n.settingsPageLogs), findsNothing);
  });

  testWidgets('Logs row is present when request logging is enabled', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(800, 1400));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final settings = SettingsProvider();
    addTearDown(settings.dispose);
    await settings.setRequestLogEnabled(true);
    await tester.pumpWidget(
      _buildHarness(settings, const CuplivoSettingsPage()),
    );
    await tester.pumpAndSettle();

    final l10n = AppLocalizations.of(
      tester.element(find.byType(CuplivoSettingsPage)),
    )!;
    expect(find.text(l10n.settingsPageLogs), findsOneWidget);
  });

  testWidgets('Log Settings row shows on desktop platforms', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    try {
      await tester.binding.setSurfaceSize(const Size(800, 1400));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      final settings = SettingsProvider();
      addTearDown(settings.dispose);
      await tester.pumpWidget(
        _buildHarness(settings, const CuplivoSettingsPage()),
      );
      await tester.pumpAndSettle();

      final l10n = AppLocalizations.of(
        tester.element(find.byType(CuplivoSettingsPage)),
      )!;
      expect(find.text(l10n.newSettingsLogSettingsTitle), findsOneWidget);
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });

  testWidgets('Log Settings row is hidden on mobile platforms', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    try {
      await tester.binding.setSurfaceSize(const Size(800, 1400));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      final settings = SettingsProvider();
      addTearDown(settings.dispose);
      await tester.pumpWidget(
        _buildHarness(settings, const CuplivoSettingsPage()),
      );
      await tester.pumpAndSettle();

      final l10n = AppLocalizations.of(
        tester.element(find.byType(CuplivoSettingsPage)),
      )!;
      expect(find.text(l10n.newSettingsLogSettingsTitle), findsNothing);
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });
}
