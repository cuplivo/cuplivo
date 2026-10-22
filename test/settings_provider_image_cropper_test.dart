import "support/business_test_harness.dart";
import 'package:flutter_test/flutter_test.dart';

import 'package:Cuplivo/core/providers/settings_provider.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('SettingsProvider image settings', () {
    test('defaults to disabled', () async {
      final harness = await createBusinessTestHarness(initial: {});
      final settings = SettingsProvider(harness.preferences);

      await settings.loaded;

      expect(settings.imageCropperEnabled, isFalse);
    });

    test('loads persisted enabled value', () async {
      final harness = await createBusinessTestHarness(
        initial: {'image_cropper_enabled_v1': true},
      );
      final settings = SettingsProvider(harness.preferences);

      await settings.loaded;

      expect(settings.imageCropperEnabled, isTrue);
    });

    test('persists mode changes to preferences', () async {
      final harness = await createBusinessTestHarness(initial: {});
      final settings = SettingsProvider(harness.preferences);

      await settings.loaded;
      await settings.setImageCropperEnabled(true);

      expect(settings.imageCropperEnabled, isTrue);
      final prefs = harness.preferences;
      expect(prefs.getBool('image_cropper_enabled_v1'), isTrue);
    });

    test('resolves and persists image compression settings', () async {
      final harness = await createBusinessTestHarness(initial: {});
      final settings = SettingsProvider(harness.preferences);

      await settings.loaded;

      expect(settings.imageUploadQuality, ImageUploadQuality.balanced);
      expect(settings.imageCompressCustomQuality, 85);
      expect(settings.imageCompressTransparentEnabled, isFalse);

      final qualityCases = [
        (ImageUploadQuality.original, false, 100, 1568),
        (ImageUploadQuality.high, true, 90, 2048),
        (ImageUploadQuality.balanced, true, 85, 1568),
        (ImageUploadQuality.saver, true, 70, 1024),
        (ImageUploadQuality.custom, true, 85, 1568),
      ];
      for (final (quality, enabled, jpegQuality, maxLongEdge) in qualityCases) {
        await settings.setImageUploadQuality(quality);
        final config = settings.resolveImageCompressConfig();
        expect(config.enabled, enabled);
        expect(config.quality, jpegQuality);
        expect(config.maxLongEdge, maxLongEdge);
      }

      await settings.setImageCompressCustomQuality(95);
      await settings.setImageCompressTransparentEnabled(true);

      final config = settings.resolveImageCompressConfig();
      expect(config.enabled, isTrue);
      expect(config.quality, 95);
      expect(config.maxLongEdge, 1568);
      expect(config.includeTransparent, isTrue);
      expect(
        harness.preferences.getString('image_upload_quality_v1'),
        'custom',
      );
      expect(
        harness.preferences.getInt('image_compress_custom_quality_v1'),
        95,
      );
      expect(
        harness.preferences.getBool('image_compress_transparent_enabled_v1'),
        isTrue,
      );
    });
  });
}
