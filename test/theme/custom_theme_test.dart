import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:Cuplivo/core/database/business_preferences.dart';

import 'package:Cuplivo/core/providers/settings_provider.dart';
import 'package:Cuplivo/theme/custom_theme.dart';
import 'package:Cuplivo/theme/palettes.dart';

Future<void> _waitForSettingsLoad(SettingsProvider settings) async {
  await settings.loaded;
  // Flush the fire-and-forget prefs writes scheduled during _load().
  await Future<void>.delayed(Duration.zero);
}

void main() {
  var businessPrefs = BusinessPreferences.memoryForTests();
  TestWidgetsFlutterBinding.ensureInitialized();

  group('CustomTheme model', () {
    test('export/parse round-trips all fields', () {
      const theme = CustomTheme(
        id: 'ct_1',
        name: 'Ocean',
        primaryArgb: 0xFF3E5E98,
        secondaryArgb: 0xFF575E71,
        tertiaryArgb: 0xFF77517D,
      );
      final parsed = CustomTheme.parse(theme.export());
      expect(parsed, theme);
      expect(parsed.primary, const Color(0xFF3E5E98));
      expect(parsed.secondary, const Color(0xFF575E71));
      expect(parsed.tertiary, const Color(0xFF77517D));
    });

    test('parse accepts RikkaHub format with optional id', () {
      final t = CustomTheme.parse(
        '{"primaryColorArgb": 4280198808, "name": "My Theme"}',
      );
      expect(t.id, isEmpty);
      expect(t.name, 'My Theme');
      expect(t.primaryArgb, 4280198808);
      expect(t.secondaryArgb, isNull);
      expect(t.tertiaryArgb, isNull);
    });

    test('parse rejects missing primaryColorArgb', () {
      expect(
        () => CustomTheme.parse('{"name": "No color"}'),
        throwsFormatException,
      );
    });

    test('copyWith clears optional colors via closures', () {
      const theme = CustomTheme(
        id: 'ct_1',
        name: 'Ocean',
        primaryArgb: 0xFF3E5E98,
        secondaryArgb: 0xFF575E71,
        tertiaryArgb: 0xFF77517D,
      );
      final cleared = theme.copyWith(secondaryArgb: () => null);
      expect(cleared.secondaryArgb, isNull);
      expect(cleared.tertiaryArgb, 0xFF77517D);
    });

    test('customThemeColorScheme honors dark flag and primary color', () {
      const theme = CustomTheme(id: 'ct_1', name: '', primaryArgb: 0xFF166C47);
      final light = customThemeColorScheme(theme, dark: false);
      final dark = customThemeColorScheme(theme, dark: true);
      expect(light.brightness, Brightness.light);
      expect(dark.brightness, Brightness.dark);
      expect(light.primary, isNot(dark.primary));
    });

    test(
      'buildCustomThemePalette produces a runtime palette with custom id',
      () {
        const theme = CustomTheme(
          id: 'ct_1',
          name: 'Forest',
          primaryArgb: 0xFF166C47,
        );
        final palette = buildCustomThemePalette(theme);
        expect(palette.id, ThemePalettes.customPaletteId);
        expect(palette.enName, 'Forest');
        expect(palette.light.brightness, Brightness.light);
        expect(palette.dark.brightness, Brightness.dark);
      },
    );
  });

  group('SettingsProvider custom theme persistence', () {
    test(
      'migrates the legacy seed into a CustomTheme and selects it',
      () async {
        businessPrefs = BusinessPreferences.memoryForTests({
          'theme_palette_v1': 'custom_dynamic',
          'dynamic_color_seed_v1': 0xFF3E5E98,
        });
        final settings = SettingsProvider(preferences: businessPrefs);

        await _waitForSettingsLoad(settings);

        expect(settings.themePaletteId, ThemePalettes.customPaletteId);
        final migrated = settings.selectedCustomTheme;
        expect(migrated, isNotNull);
        expect(migrated!.primaryArgb, 0xFF3E5E98);
        expect(migrated.secondaryArgb, isNull);
        expect(migrated.tertiaryArgb, isNull);

        // The legacy key is removed after migration.
        final prefs = businessPrefs;
        expect(prefs.getInt('dynamic_color_seed_v1'), isNull);
      },
    );

    test(
      'migrates the seed into the list even when it was not active',
      () async {
        businessPrefs = BusinessPreferences.memoryForTests({
          'theme_palette_v1': 'default',
          'dynamic_color_seed_v1': 0xFF166C47,
        });
        final settings = SettingsProvider(preferences: businessPrefs);

        await _waitForSettingsLoad(settings);

        // The palette stays default, but the seed survives as a saved theme.
        expect(settings.themePaletteId, ThemePalettes.defaultId);
        expect(settings.customThemes, hasLength(1));
        expect(settings.customThemes.single.primaryArgb, 0xFF166C47);
        // The migrated theme is NOT selected when the seed was not active.
        expect(settings.selectedCustomThemeId, isNull);
        expect(settings.selectedCustomTheme, isNull);

        final prefs = businessPrefs;
        expect(prefs.getString('custom_theme_selected_v1'), isNull);
        expect(prefs.getInt('dynamic_color_seed_v1'), isNull);
      },
    );

    test(
      'resets a stale custom_dynamic palette id when no seed exists',
      () async {
        businessPrefs = BusinessPreferences.memoryForTests({
          'theme_palette_v1': 'custom_dynamic',
        });
        final settings = SettingsProvider(preferences: businessPrefs);

        await _waitForSettingsLoad(settings);

        expect(settings.themePaletteId, ThemePalettes.defaultId);
        expect(settings.customThemes, isEmpty);

        final prefs = businessPrefs;
        expect(prefs.getString('theme_palette_v1'), ThemePalettes.defaultId);
      },
    );

    test('saveCustomTheme assigns an id and persists', () async {
      businessPrefs = BusinessPreferences.memoryForTests({});
      final settings = SettingsProvider(preferences: businessPrefs);

      await _waitForSettingsLoad(settings);

      const theme = CustomTheme(id: '', name: 'Ocean', primaryArgb: 0xFF3E5E98);
      final saved = await settings.saveCustomTheme(theme);
      expect(saved.id, isNotEmpty);
      expect(settings.customThemes.single.id, saved.id);

      // Persisted as JSON string list.
      final prefs = businessPrefs;
      final raw = prefs.getStringList('custom_themes_v1');
      expect(raw, isNotNull);
      expect(raw, hasLength(1));
      expect(CustomTheme.parse(raw!.single).primaryArgb, 0xFF3E5E98);
    });

    test('selectCustomTheme activates the custom palette', () async {
      businessPrefs = BusinessPreferences.memoryForTests({});
      final settings = SettingsProvider(preferences: businessPrefs);

      await _waitForSettingsLoad(settings);

      final saved = await settings.saveCustomTheme(
        const CustomTheme(id: '', name: 'Ocean', primaryArgb: 0xFF3E5E98),
      );
      await settings.selectCustomTheme(saved.id);

      expect(settings.selectedCustomThemeId, saved.id);
      expect(settings.themePaletteId, ThemePalettes.customPaletteId);

      final prefs = businessPrefs;
      expect(prefs.getString('custom_theme_selected_v1'), saved.id);
      expect(
        prefs.getString('theme_palette_v1'),
        ThemePalettes.customPaletteId,
      );
    });

    test('deleting the active theme falls back to the default palette even '
        'when other themes remain', () async {
      businessPrefs = BusinessPreferences.memoryForTests({});
      final settings = SettingsProvider(preferences: businessPrefs);

      await _waitForSettingsLoad(settings);

      final first = await settings.saveCustomTheme(
        const CustomTheme(id: 'a', name: 'A', primaryArgb: 0xFF3E5E98),
      );
      await settings.saveCustomTheme(
        const CustomTheme(id: 'b', name: 'B', primaryArgb: 0xFF166C47),
      );
      await settings.selectCustomTheme(first.id);
      await settings.deleteCustomTheme(first.id);

      // One theme remains, but the palette falls back to default.
      expect(settings.customThemes, hasLength(1));
      expect(settings.customThemes.single.id, 'b');
      expect(settings.selectedCustomThemeId, isNull);
      expect(settings.themePaletteId, ThemePalettes.defaultId);

      final prefs = businessPrefs;
      expect(prefs.getString('custom_theme_selected_v1'), isNull);
      expect(prefs.getString('theme_palette_v1'), ThemePalettes.defaultId);
    });

    test('deleting an inactive theme keeps the active selection', () async {
      businessPrefs = BusinessPreferences.memoryForTests({});
      final settings = SettingsProvider(preferences: businessPrefs);

      await _waitForSettingsLoad(settings);

      final first = await settings.saveCustomTheme(
        const CustomTheme(id: 'a', name: 'A', primaryArgb: 0xFF3E5E98),
      );
      final second = await settings.saveCustomTheme(
        const CustomTheme(id: 'b', name: 'B', primaryArgb: 0xFF166C47),
      );
      await settings.selectCustomTheme(first.id);
      await settings.deleteCustomTheme(second.id);

      expect(settings.selectedCustomThemeId, first.id);
      expect(settings.themePaletteId, ThemePalettes.customPaletteId);
    });

    test('importCustomTheme reassigns a taken id and activates it', () async {
      businessPrefs = BusinessPreferences.memoryForTests({});
      final settings = SettingsProvider(preferences: businessPrefs);

      await _waitForSettingsLoad(settings);

      final first = await settings.saveCustomTheme(
        const CustomTheme(id: 'shared', name: 'A', primaryArgb: 0xFF3E5E98),
      );
      final imported = await settings.importCustomTheme(
        '{"id": "shared", "name": "B", "primaryColorArgb": 4278245080}',
      );

      expect(first.id, 'shared');
      expect(imported.id, isNot('shared'));
      expect(settings.customThemes, hasLength(2));
      // Import activates the theme (ADR-0038).
      expect(settings.selectedCustomThemeId, imported.id);
      expect(settings.themePaletteId, ThemePalettes.customPaletteId);
    });

    test('selectCustomTheme ignores unknown ids', () async {
      businessPrefs = BusinessPreferences.memoryForTests({});
      final settings = SettingsProvider(preferences: businessPrefs);

      await _waitForSettingsLoad(settings);

      await settings.selectCustomTheme('does-not-exist');
      expect(settings.selectedCustomThemeId, isNull);
      expect(settings.themePaletteId, ThemePalettes.defaultId);
    });
  });
}
