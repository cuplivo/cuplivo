import 'package:flutter_test/flutter_test.dart';

import 'package:Cuplivo/core/database/business_preferences.dart';
import 'package:Cuplivo/core/database/business_settings_router.dart';
import 'package:Cuplivo/core/providers/settings_provider.dart';
import 'package:Cuplivo/features/settings/widgets/language_select_sheet.dart';
import 'package:Cuplivo/l10n/app_localizations.dart';
import 'package:Cuplivo/l10n/app_localizations_en.dart';
import 'package:Cuplivo/l10n/app_localizations_zh.dart';

import '../../support/business_test_harness.dart';

/// The translate-target catalog is code, the visible subset is user data
/// (ADR-0014). These tests pin the two apart: a catalog entry with no label, a
/// visible set that can be emptied, or a target that survives being hidden are
/// exactly the defects the separation exists to prevent.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('translate language catalog', () {
    test('codes are unique and include the issue-requested bn', () {
      final codes = supportedLanguages.map((l) => l.code).toList();
      expect(codes.toSet().length, codes.length);
      expect(codes, contains('bn'));
      expect(codes, containsAll(const ['pt', 'ru', 'ar', 'hi', 'th', 'vi']));
      expect(codes.length, 16);
    });

    test('default visible set is the historical nine and a catalog subset', () {
      final catalog = supportedLanguages.map((l) => l.code).toSet();
      for (final code in SettingsProvider.defaultTranslateVisibleLanguages) {
        expect(catalog, contains(code), reason: code);
      }
      expect(SettingsProvider.defaultTranslateVisibleLanguages.length, 9);
    });

    test(
      'every catalog entry resolves to a localized label in all locales',
      () {
        final locales = <String, AppLocalizations>{
          'en': AppLocalizationsEn(),
          'zh': AppLocalizationsZh(),
          'zh-Hans': AppLocalizationsZhHans(),
          'zh-Hant': AppLocalizationsZhHant(),
        };
        for (final lang in supportedLanguages) {
          for (final entry in locales.entries) {
            final label = translateLanguageDisplayName(entry.value, lang.code);
            expect(
              label,
              isNot(lang.code),
              reason: '${entry.key} label missing for ${lang.code}',
            );
            expect(label, isNotEmpty, reason: '${entry.key} ${lang.code}');
          }
        }
        expect(
          translateLanguageDisplayName(AppLocalizationsEn(), 'bn'),
          'Bengali',
        );
        expect(
          translateLanguageDisplayName(AppLocalizationsZh(), 'bn'),
          'বাংলা',
        );
      },
    );
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

  group('effectiveTranslateLanguage', () {
    test('a visible persisted target wins over the locale', () {
      final target = effectiveTranslateLanguage(
        visible: visibleTranslateLanguages({'en', 'ja'}),
        persistedCode: 'ja',
        localeLanguageCode: 'en',
      );
      expect(target.code, 'ja');
    });

    test('a hidden persisted target falls back to the locale', () {
      final target = effectiveTranslateLanguage(
        visible: visibleTranslateLanguages({'en', 'zh-CN', 'ja'}),
        persistedCode: 'bn',
        localeLanguageCode: 'zh-Hans',
      );
      expect(target.code, 'zh-CN');
    });

    test('an invisible locale falls back to the first visible', () {
      final target = effectiveTranslateLanguage(
        visible: visibleTranslateLanguages({'bn', 'th'}),
        persistedCode: null,
        localeLanguageCode: 'en',
      );
      expect(target.code, 'th');
    });
  });

  group('SettingsProvider translate visible languages', () {
    test('empty set is ignored (default list stays)', () async {
      final storage = await createBusinessTestHarness();
      final settings = SettingsProvider(storage.preferences);
      addTearDown(settings.dispose);
      await settings.loaded;

      await settings.setTranslateVisibleLanguages(<String>{});

      expect(
        settings.translateVisibleLanguages,
        unorderedEquals(SettingsProvider.defaultTranslateVisibleLanguages),
      );
    });

    test('non-empty set persists across a restart', () async {
      final storage = await createBusinessTestHarness();
      final settings = SettingsProvider(storage.preferences);
      addTearDown(settings.dispose);
      await settings.loaded;

      await settings.setTranslateVisibleLanguages({'en', 'bn'});

      final restarted = SettingsProvider(
        BusinessPreferences(storage.repository),
      );
      addTearDown(restarted.dispose);
      await restarted.loaded;
      expect(
        restarted.translateVisibleLanguages,
        unorderedEquals(<String>['en', 'bn']),
      );
    });

    test(
      'load keeps a hidden target verbatim and the resolver owns the fallback',
      () async {
        final storage = await createBusinessTestHarness(
          initial: {
            'translate_target_lang_v1': 'bn',
            'translate_visible_languages_v1': <String>['en', 'ja'],
          },
        );
        final settings = SettingsProvider(storage.preferences);
        addTearDown(settings.dispose);
        await settings.loaded;

        // The persisted choice survives a visible set that excludes it: only
        // the resolver decides what is in effect.
        expect(settings.translateTargetLang, 'bn');
        expect(storage.preferences.getString('translate_target_lang_v1'), 'bn');
        expect(
          effectiveTranslateLanguage(
            visible: visibleTranslateLanguages(
              settings.translateVisibleLanguages,
            ),
            persistedCode: settings.translateTargetLang,
            localeLanguageCode: 'en',
          ).code,
          'en',
        );

        // Re-enabling the language restores the user's original choice, in this
        // session and after a restart.
        await settings.setTranslateVisibleLanguages({'en', 'ja', 'bn'});
        expect(
          effectiveTranslateLanguage(
            visible: visibleTranslateLanguages(
              settings.translateVisibleLanguages,
            ),
            persistedCode: settings.translateTargetLang,
            localeLanguageCode: 'en',
          ).code,
          'bn',
        );
        final restarted = SettingsProvider(
          BusinessPreferences(storage.repository),
        );
        addTearDown(restarted.dispose);
        await restarted.loaded;
        expect(restarted.translateTargetLang, 'bn');
      },
    );

    test('load keeps a target inside the visible set', () async {
      final storage = await createBusinessTestHarness(
        initial: {
          'translate_target_lang_v1': 'ja',
          'translate_visible_languages_v1': <String>['en', 'ja'],
        },
      );
      final settings = SettingsProvider(storage.preferences);
      addTearDown(settings.dispose);
      await settings.loaded;

      expect(settings.translateTargetLang, 'ja');
      expect(storage.preferences.getString('translate_target_lang_v1'), 'ja');
    });

    test(
      'visible set instance is stable across unrelated notifications',
      () async {
        final storage = await createBusinessTestHarness();
        final settings = SettingsProvider(storage.preferences);
        addTearDown(settings.dispose);
        await settings.loaded;

        final initial = settings.translateVisibleLanguages;
        await settings.setTranslatePrompt('unrelated notification');
        expect(identical(initial, settings.translateVisibleLanguages), isTrue);

        await settings.setTranslateVisibleLanguages({'en', 'bn'});
        expect(identical(initial, settings.translateVisibleLanguages), isFalse);
        expect(
          settings.translateVisibleLanguages,
          unorderedEquals(<String>['en', 'bn']),
        );
      },
    );

    test('an unchanged selection does not notify', () async {
      final storage = await createBusinessTestHarness();
      final settings = SettingsProvider(storage.preferences);
      addTearDown(settings.dispose);
      await settings.loaded;

      var notifications = 0;
      settings.addListener(() => notifications++);

      await settings.setTranslateVisibleLanguages(
        SettingsProvider.defaultTranslateVisibleLanguages.toSet(),
      );
      expect(notifications, 0);

      await settings.setTranslateVisibleLanguages({'en', 'bn'});
      expect(notifications, 1);
    });

    test('the key is a synced business preference', () {
      // LAN sync and backup both read the registry rather than the writer, so
      // an unregistered key would be written and then silently never travel.
      expect(
        BusinessKeyRegistry.classify('translate_visible_languages_v1'),
        BusinessKeyDisposition.syncedPreference,
      );
      expect(
        BusinessKeyRegistry.preferenceKeys,
        contains('translate_visible_languages_v1'),
      );
    });
  });
}
