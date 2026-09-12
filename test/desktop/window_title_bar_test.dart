import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:Cuplivo/core/database/business_preferences.dart';
import 'package:Cuplivo/core/providers/settings_provider.dart';
import 'package:Cuplivo/desktop/window_title_bar.dart';
import 'package:Cuplivo/theme/palettes.dart';
import 'package:Cuplivo/theme/theme_factory.dart';

const String _pureBackgroundKey = 'display_use_pure_background_v1';

Future<SettingsProvider> _pumpTitleBar(
  WidgetTester tester,
  ThemeData theme,
  bool pureBackground,
) async {
  final prefs = BusinessPreferences.memoryForTests({
    _pureBackgroundKey: pureBackground,
  });
  final settings = SettingsProvider(preferences: prefs);
  await settings.loaded;
  await tester.pumpWidget(
    ChangeNotifierProvider<SettingsProvider>.value(
      value: settings,
      child: MaterialApp(
        theme: theme,
        home: const Scaffold(body: WindowTitleBar()),
      ),
    ),
  );
  return settings;
}

Color _titleBarBackground(WidgetTester tester) {
  final container = tester.widget<Container>(
    find
        .descendant(
          of: find.byType(WindowTitleBar),
          matching: find.byType(Container),
        )
        .first,
  );
  return (container.decoration as BoxDecoration).color!;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues(const <String, Object>{});
  });

  testWidgets('non-pure light title bar matches the scaffold background', (
    tester,
  ) async {
    final theme = buildLightThemeForScheme(ThemePalettes.defaultPalette.light);
    await _pumpTitleBar(tester, theme, false);

    expect(
      theme.scaffoldBackgroundColor,
      isNot(theme.colorScheme.surfaceContainerHighest),
    );
    expect(_titleBarBackground(tester), theme.scaffoldBackgroundColor);
  });

  testWidgets('non-pure dark title bar matches the scaffold background', (
    tester,
  ) async {
    final theme = buildDarkThemeForScheme(ThemePalettes.defaultPalette.dark);
    await _pumpTitleBar(tester, theme, false);

    expect(
      theme.scaffoldBackgroundColor,
      isNot(theme.colorScheme.surfaceContainerHighest),
    );
    expect(_titleBarBackground(tester), theme.scaffoldBackgroundColor);
  });

  testWidgets('pure background keeps the light title bar white', (
    tester,
  ) async {
    final theme = buildLightThemeForScheme(
      ThemePalettes.defaultPalette.light,
      pureBackground: true,
    );
    await _pumpTitleBar(tester, theme, true);

    expect(theme.scaffoldBackgroundColor, Colors.white);
    expect(_titleBarBackground(tester), Colors.white);
  });

  testWidgets('pure background keeps the dark title bar black', (tester) async {
    final theme = buildDarkThemeForScheme(
      ThemePalettes.defaultPalette.dark,
      pureBackground: true,
    );
    await _pumpTitleBar(tester, theme, true);

    expect(theme.scaffoldBackgroundColor, Colors.black);
    expect(_titleBarBackground(tester), Colors.black);
  });

  testWidgets('toggling pure background updates the title bar immediately', (
    tester,
  ) async {
    final theme = buildLightThemeForScheme(ThemePalettes.defaultPalette.light);
    final settings = await _pumpTitleBar(tester, theme, false);
    expect(_titleBarBackground(tester), theme.scaffoldBackgroundColor);

    await settings.setUsePureBackground(true);
    await tester.pump();
    expect(_titleBarBackground(tester), Colors.white);
  });
}
