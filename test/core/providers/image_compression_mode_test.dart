import 'package:Cuplivo/core/providers/settings_provider.dart';
import 'package:Cuplivo/utils/image_compressor.dart';
import 'package:downsize/downsize.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/business_test_harness.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('defaults to manual, which stores attachments unchanged', () async {
    final harness = await createBusinessTestHarness();
    final settings = SettingsProvider(harness.preferences);
    await settings.loaded;

    expect(settings.imageCompressionMode, ImageCompressionMode.manual);
    expect(settings.resolveImageCompressConfig().enabled, isFalse);
  });

  test(
    'off stores attachments unchanged and auto re-encodes with the preset',
    () async {
      final harness = await createBusinessTestHarness();
      final settings = SettingsProvider(harness.preferences);
      await settings.loaded;

      await settings.setImageCompressionMode(ImageCompressionMode.auto);
      final auto = settings.resolveImageCompressConfig();
      expect(auto.enabled, isTrue);
      // The balanced preset stays auto's default.
      expect(auto.quality, 85);
      expect(auto.maxLongEdge, 1568);
      expect(auto.includeTransparent, isFalse);

      await settings.setImageCompressionMode(ImageCompressionMode.off);
      expect(settings.resolveImageCompressConfig().enabled, isFalse);

      await settings.setImageCompressionMode(ImageCompressionMode.manual);
      expect(settings.resolveImageCompressConfig().enabled, isFalse);
    },
  );

  test('manual editor parameters persist across providers', () async {
    final harness = await createBusinessTestHarness();
    final settings = SettingsProvider(harness.preferences);
    await settings.loaded;

    // First run defaults to JPEG at 80 with a 1536 long edge.
    expect(settings.manualCompressParams.format, DownsizeFormat.jpeg);
    expect(settings.manualCompressParams.quality, 80);
    expect(settings.manualCompressParams.maxLongEdge, 1536);

    await settings.setManualCompressParams(
      const ManualCompressParams(
        format: DownsizeFormat.png,
        quality: 60,
        maxLongEdge: 800,
      ),
    );

    final reloaded = SettingsProvider(harness.preferences);
    await reloaded.loaded;
    expect(reloaded.manualCompressParams.format, DownsizeFormat.png);
    expect(reloaded.manualCompressParams.quality, 60);
    expect(reloaded.manualCompressParams.maxLongEdge, 800);

    // 原图 is a first-class remembered value, not a missing one.
    await reloaded.setManualCompressParams(const ManualCompressParams());
    final third = SettingsProvider(harness.preferences);
    await third.loaded;
    expect(third.manualCompressParams.format, isNull);
    expect(third.manualCompressParams.isNoOp, isTrue);
    expect(third.manualCompressParams.maxLongEdge, isNull);
  });
}
