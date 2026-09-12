import 'package:flutter_test/flutter_test.dart';

import 'package:Cuplivo/core/database/business_preferences.dart';
import 'package:Cuplivo/core/providers/settings_provider.dart';
import 'package:Cuplivo/features/settings/widgets/language_select_sheet.dart';
import 'package:Cuplivo/l10n/app_localizations_en.dart';
import 'package:Cuplivo/l10n/app_localizations_zh.dart';

Future<void> _waitForSettingsLoad() async {
  for (var i = 0; i < 25; i++) {
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('translate language catalog', () {
    test('codes are unique and include the issue-requested bn', () {
      final codes = supportedLanguages.map((l) => l.code).toList();
      expect(codes.toSet().length, codes.length);
      expect(codes, contains('bn'));
      expect(codes, containsAll(const ['pt', 'ru', 'ar', 'hi', 'th', 'vi']));
    });

    test('default visible set is a subset of the catalog', () {
      final catalog = supportedLanguages.map((l) => l.code).toSet();
      for (final code in SettingsProvider.defaultTranslateVisibleLanguages) {
        expect(catalog, contains(code));
      }
      expect(SettingsProvider.defaultTranslateVisibleLanguages.length, 9);
    });

    test('every catalog entry resolves to a localized label (en + zh)', () {
      final en = AppLocalizationsEn();
      final zh = AppLocalizationsZh();
      for (final lang in supportedLanguages) {
        expect(
          translateLanguageDisplayName(en, lang.code),
          isNot(lang.code),
          reason: 'en label missing for ${lang.code}',
        );
        expect(
          translateLanguageDisplayName(zh, lang.code),
          isNot(lang.code),
          reason: 'zh label missing for ${lang.code}',
        );
      }
      expect(translateLanguageDisplayName(en, 'bn'), 'Bengali');
      expect(translateLanguageDisplayName(zh, 'bn'), 'বাংলা');
    });
  });

  group('visibleTranslateLanguages', () {
    test('filters to the visible set in catalog order', () {
      final visible = visibleTranslateLanguages({'bn', 'en'});
      expect(visible.map((l) => l.code).toList(), ['en', 'bn']);
    });

    test('default set yields the historical nine, in order', () {
      final visible = visibleTranslateLanguages(
        SettingsProvider.defaultTranslateVisibleLanguages.toSet(),
      );
      expect(visible.map((l) => l.code).toList(), [
        'zh-CN',
        'en',
        'zh-TW',
        'ja',
        'ko',
        'fr',
        'de',
        'it',
        'es',
      ]);
    });

    test('never returns empty when the set is empty or unknown', () {
      final fromEmpty = visibleTranslateLanguages(<String>{});
      expect(fromEmpty, isNotEmpty);
      expect(
        fromEmpty.map((l) => l.code).toList(),
        SettingsProvider.defaultTranslateVisibleLanguages.toList(),
      );

      final fromUnknown = visibleTranslateLanguages({'xx', 'yy'});
      expect(fromUnknown, isNotEmpty);
    });
  });

  group('effectiveTranslateTarget', () {
    test('keeps a still-visible target', () {
      expect(effectiveTranslateTarget({'bn', 'en'}, 'bn'), 'bn');
    });

    test('falls back to the first visible when the target was hidden', () {
      expect(effectiveTranslateTarget({'ja', 'fr'}, 'bn'), 'ja');
    });

    test('null target stays null', () {
      expect(effectiveTranslateTarget({'en'}, null), isNull);
    });
  });

  group('SettingsProvider translate visible languages', () {
    test('empty set is ignored (default list stays)', () async {
      final prefs = BusinessPreferences.memoryForTests();
      final settings = SettingsProvider(preferences: prefs);
      await _waitForSettingsLoad();

      await settings.setTranslateVisibleLanguages(<String>{});

      expect(
        settings.translateVisibleLanguages,
        unorderedEquals(SettingsProvider.defaultTranslateVisibleLanguages),
      );
    });

    test('non-empty set persists across a restart', () async {
      final prefs = BusinessPreferences.memoryForTests();
      final settings = SettingsProvider(preferences: prefs);
      await _waitForSettingsLoad();

      await settings.setTranslateVisibleLanguages({'en', 'bn'});

      final restarted = SettingsProvider(preferences: prefs);
      await _waitForSettingsLoad();
      expect(
        restarted.translateVisibleLanguages,
        unorderedEquals(['en', 'bn']),
      );
    });

    test(
      'load drops a target outside the visible set and clears the key',
      () async {
        final prefs = BusinessPreferences.memoryForTests({
          'translate_target_lang_v1': 'bn',
          'translate_visible_languages_v1': ['en', 'ja'],
        });
        final settings = SettingsProvider(preferences: prefs);
        await _waitForSettingsLoad();

        expect(settings.translateTargetLang, isNull);
        expect(prefs.getString('translate_target_lang_v1'), isNull);

        // Re-enabling the language later must not resurrect the dropped target.
        await settings.setTranslateVisibleLanguages({'en', 'ja', 'bn'});
        final restarted = SettingsProvider(preferences: prefs);
        await _waitForSettingsLoad();
        expect(restarted.translateTargetLang, isNull);
      },
    );

    test('load keeps a target inside the visible set', () async {
      final prefs = BusinessPreferences.memoryForTests({
        'translate_target_lang_v1': 'ja',
        'translate_visible_languages_v1': ['en', 'ja'],
      });
      final settings = SettingsProvider(preferences: prefs);
      await _waitForSettingsLoad();

      expect(settings.translateTargetLang, 'ja');
      expect(prefs.getString('translate_target_lang_v1'), 'ja');
    });

    test(
      'visible set instance is stable across unrelated notifications',
      () async {
        final prefs = BusinessPreferences.memoryForTests();
        final settings = SettingsProvider(preferences: prefs);
        await _waitForSettingsLoad();

        final initial = settings.translateVisibleLanguages;
        await settings.setTranslatePrompt('unrelated notification');
        expect(identical(initial, settings.translateVisibleLanguages), isTrue);

        await settings.setTranslateVisibleLanguages({'en', 'bn'});
        expect(identical(initial, settings.translateVisibleLanguages), isFalse);
        expect(
          settings.translateVisibleLanguages,
          unorderedEquals(['en', 'bn']),
        );
      },
    );
  });
}
