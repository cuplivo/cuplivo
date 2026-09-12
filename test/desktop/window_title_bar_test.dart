import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:Cuplivo/desktop/window_title_bar.dart';
import 'package:Cuplivo/theme/palettes.dart';
import 'package:Cuplivo/theme/theme_factory.dart';

Future<void> _pumpTitleBar(WidgetTester tester, ThemeData theme) async {
  await tester.pumpWidget(
    MaterialApp(
      theme: theme,
      home: const Scaffold(body: WindowTitleBar()),
    ),
  );
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
  testWidgets('non-pure light title bar matches the scaffold background', (
    tester,
  ) async {
    final theme = buildLightThemeForScheme(ThemePalettes.defaultPalette.light);
    await _pumpTitleBar(tester, theme);

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
    await _pumpTitleBar(tester, theme);

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
    await _pumpTitleBar(tester, theme);

    expect(theme.scaffoldBackgroundColor, Colors.white);
    expect(_titleBarBackground(tester), Colors.white);
  });

  testWidgets('pure background keeps the dark title bar black', (tester) async {
    final theme = buildDarkThemeForScheme(
      ThemePalettes.defaultPalette.dark,
      pureBackground: true,
    );
    await _pumpTitleBar(tester, theme);

    expect(theme.scaffoldBackgroundColor, Colors.black);
    expect(_titleBarBackground(tester), Colors.black);
  });

  testWidgets('switching to a pure theme updates the title bar immediately', (
    tester,
  ) async {
    final light = buildLightThemeForScheme(ThemePalettes.defaultPalette.light);
    await _pumpTitleBar(tester, light);
    expect(_titleBarBackground(tester), light.scaffoldBackgroundColor);

    final pureLight = buildLightThemeForScheme(
      ThemePalettes.defaultPalette.light,
      pureBackground: true,
    );
    await _pumpTitleBar(tester, pureLight);
    await tester.pumpAndSettle();
    expect(_titleBarBackground(tester), Colors.white);
  });
}
