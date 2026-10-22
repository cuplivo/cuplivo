import "support/business_test_harness.dart";
import 'package:flutter_test/flutter_test.dart';

import 'package:Cuplivo/core/providers/settings_provider.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('SettingsProvider long paste as file', () {
    test('defaults to enabled with a 5000-character threshold', () async {
      final harness = await createBusinessTestHarness(initial: {});
      final settings = SettingsProvider(harness.preferences);

      await settings.loaded;

      expect(settings.longPasteAsFile, isTrue);
      expect(
        settings.longPasteAsFileThreshold,
        SettingsProvider.defaultLongPasteAsFileThreshold,
      );
    });

    test('loads persisted values', () async {
      final harness = await createBusinessTestHarness(
        initial: {
          'display_long_paste_as_file_v1': false,
          'display_long_paste_as_file_threshold_v1': 800,
        },
      );
      final settings = SettingsProvider(harness.preferences);

      await settings.loaded;

      expect(settings.longPasteAsFile, isFalse);
      expect(settings.longPasteAsFileThreshold, 800);
    });

    test('clamps an out-of-range persisted threshold', () async {
      final harness = await createBusinessTestHarness(
        initial: {'display_long_paste_as_file_threshold_v1': 0},
      );
      final settings = SettingsProvider(harness.preferences);

      await settings.loaded;

      expect(
        settings.longPasteAsFileThreshold,
        SettingsProvider.minLongPasteAsFileThreshold,
      );
    });

    test('resolve keeps the current value for empty or invalid input', () {
      expect(
        SettingsProvider.resolveLongPasteAsFileThreshold('', fallback: 5000),
        5000,
      );
      expect(
        SettingsProvider.resolveLongPasteAsFileThreshold('   ', fallback: 800),
        800,
      );
    });

    test('resolve clamps a numeric threshold', () {
      expect(
        SettingsProvider.resolveLongPasteAsFileThreshold(
          '1200',
          fallback: 5000,
        ),
        1200,
      );
      expect(
        SettingsProvider.resolveLongPasteAsFileThreshold('0', fallback: 5000),
        SettingsProvider.minLongPasteAsFileThreshold,
      );
      expect(
        SettingsProvider.resolveLongPasteAsFileThreshold(
          '2000000',
          fallback: 5000,
        ),
        SettingsProvider.maxLongPasteAsFileThreshold,
      );
    });

    test('persists toggle and threshold changes', () async {
      final harness = await createBusinessTestHarness(initial: {});
      final settings = SettingsProvider(harness.preferences);

      await settings.loaded;
      await settings.setLongPasteAsFile(false);
      await settings.setLongPasteAsFileThreshold(1200);

      expect(settings.longPasteAsFile, isFalse);
      expect(settings.longPasteAsFileThreshold, 1200);
      expect(
        harness.preferences.getBool('display_long_paste_as_file_v1'),
        isFalse,
      );
      expect(
        harness.preferences.getInt('display_long_paste_as_file_threshold_v1'),
        1200,
      );
    });
  });
}
