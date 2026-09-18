import 'package:flutter_test/flutter_test.dart';

import 'package:Cuplivo/core/providers/settings_provider.dart';
import 'package:Cuplivo/features/settings/widgets/language_select_sheet.dart';

void main() {
  group('visibleTranslateLanguages', () {
    test('filters the catalog by visible codes in catalog order', () {
      final visible = visibleTranslateLanguages(const {'ko', 'en'});
      expect(visible.map((l) => l.code), ['en', 'ko']);
    });

    test('unknown codes drop silently', () {
      final visible = visibleTranslateLanguages(const {'en', 'xx'});
      expect(visible.map((l) => l.code), ['en']);
    });

    test('empty set falls back to the default visible set', () {
      final visible = visibleTranslateLanguages(const <String>{});
      expect(
        visible.map((l) => l.code).toList(),
        containsAll(['zh-CN', 'en', 'ja']),
      );
      expect(visible.length, 9);
    });

    test('defaults match the historical fixed list', () {
      expect(SettingsProvider.defaultTranslateVisibleLanguages, {
        'zh-CN',
        'en',
        'zh-TW',
        'ja',
        'ko',
        'fr',
        'de',
        'it',
        'es',
      });
    });
  });

  group('effectiveTranslateTarget', () {
    test('keeps a still-visible current target', () {
      expect(effectiveTranslateTarget(const {'en'}, 'en'), 'en');
    });

    test('a hidden target falls back to the first visible (catalog order)', () {
      expect(effectiveTranslateTarget(const {'ko', 'ja'}, 'en'), 'ja');
    });

    test('null stays null', () {
      expect(effectiveTranslateTarget(const {'en'}, null), isNull);
    });
  });
}
