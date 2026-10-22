import "support/business_test_harness.dart";
import 'package:flutter_test/flutter_test.dart';

import 'package:Cuplivo/core/providers/settings_provider.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('SettingsProvider OCR prompt', () {
    test('defaults to the built-in OCR prompt when unset', () async {
      final harness = await createBusinessTestHarness(initial: {});
      final settings = SettingsProvider(harness.preferences);

      await settings.loaded;

      expect(settings.ocrPrompt, SettingsProvider.defaultOcrPrompt);
    });

    test('persists an explicitly empty OCR prompt', () async {
      final harness = await createBusinessTestHarness(initial: {});
      final settings = SettingsProvider(harness.preferences);

      await settings.loaded;
      await settings.setOcrPrompt('   ');

      expect(settings.ocrPrompt, isEmpty);
      expect(harness.preferences.getString('ocr_prompt_v1'), isEmpty);
    });

    test(
      'reloads an explicitly empty OCR prompt instead of the default',
      () async {
        final harness = await createBusinessTestHarness(
          initial: {'ocr_prompt_v1': ''},
        );
        final settings = SettingsProvider(harness.preferences);

        await settings.loaded;

        expect(settings.ocrPrompt, isEmpty);
      },
    );

    test('reset restores the built-in OCR prompt', () async {
      final harness = await createBusinessTestHarness(
        initial: {'ocr_prompt_v1': ''},
      );
      final settings = SettingsProvider(harness.preferences);

      await settings.loaded;
      await settings.resetOcrPrompt();

      expect(settings.ocrPrompt, SettingsProvider.defaultOcrPrompt);
      expect(
        harness.preferences.getString('ocr_prompt_v1'),
        SettingsProvider.defaultOcrPrompt,
      );
    });
  });
}
