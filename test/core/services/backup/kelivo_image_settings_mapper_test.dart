import 'package:Cuplivo/core/services/backup/kelivo_image_settings_mapper.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('KelivoImageSettingsMapper.translateFromUpstream', () {
    test('returns null when no upstream quality key is present', () {
      expect(KelivoImageSettingsMapper.translateFromUpstream(const {}), isNull);
    });

    test('returns null when the upstream quality key is not a String', () {
      expect(
        KelivoImageSettingsMapper.translateFromUpstream(const {
          KelivoImageSettingsMapper.upstreamQualityKey: 5,
        }),
        isNull,
      );
      expect(
        KelivoImageSettingsMapper.translateFromUpstream(const {
          KelivoImageSettingsMapper.upstreamQualityKey: true,
        }),
        isNull,
      );
    });

    test('returns null when Cuplivo native keys are already present', () {
      // A Cuplivo export carries BOTH key sets; it must restore its own
      // one_click_compress_* values verbatim instead of being re-translated
      // (re-translation would overwrite the file's own maxLongEdge with 1568).
      expect(
        KelivoImageSettingsMapper.translateFromUpstream(const {
          KelivoImageSettingsMapper.upstreamQualityKey: 'custom',
          'one_click_compress_enabled_v1': true,
        }),
        isNull,
      );
      expect(
        KelivoImageSettingsMapper.translateFromUpstream(const {
          KelivoImageSettingsMapper.upstreamQualityKey: 'saver',
          'one_click_compress_max_long_edge_v1': 2048,
        }),
        isNull,
      );
    });

    test('maps original to disabled with defaults', () {
      final result = KelivoImageSettingsMapper.translateFromUpstream(const {
        KelivoImageSettingsMapper.upstreamQualityKey: 'original',
      });
      expect(result, {
        'one_click_compress_enabled_v1': false,
        'one_click_compress_max_long_edge_v1': 1536,
        'one_click_compress_quality_v1': 75,
        'one_click_compress_always_jpg_v1': false,
      });
    });

    test('maps high/balanced/saver presets to their fixed params', () {
      final high = KelivoImageSettingsMapper.translateFromUpstream(const {
        KelivoImageSettingsMapper.upstreamQualityKey: 'high',
      })!;
      expect(high['one_click_compress_enabled_v1'], isTrue);
      expect(high['one_click_compress_max_long_edge_v1'], 2048);
      expect(high['one_click_compress_quality_v1'], 90);

      final balanced = KelivoImageSettingsMapper.translateFromUpstream(const {
        KelivoImageSettingsMapper.upstreamQualityKey: 'balanced',
      })!;
      expect(balanced['one_click_compress_enabled_v1'], isTrue);
      expect(balanced['one_click_compress_max_long_edge_v1'], 1568);
      expect(balanced['one_click_compress_quality_v1'], 85);

      final saver = KelivoImageSettingsMapper.translateFromUpstream(const {
        KelivoImageSettingsMapper.upstreamQualityKey: 'saver',
      })!;
      expect(saver['one_click_compress_enabled_v1'], isTrue);
      expect(saver['one_click_compress_max_long_edge_v1'], 1024);
      expect(saver['one_click_compress_quality_v1'], 70);
    });

    test('maps custom with explicit custom quality', () {
      final result = KelivoImageSettingsMapper.translateFromUpstream(const {
        KelivoImageSettingsMapper.upstreamQualityKey: 'custom',
        KelivoImageSettingsMapper.upstreamCustomQualityKey: 95,
      })!;
      expect(result['one_click_compress_enabled_v1'], isTrue);
      expect(result['one_click_compress_max_long_edge_v1'], 1568);
      expect(result['one_click_compress_quality_v1'], 95);
    });

    test('maps custom without a custom quality key to the default 85', () {
      final result = KelivoImageSettingsMapper.translateFromUpstream(const {
        KelivoImageSettingsMapper.upstreamQualityKey: 'custom',
      })!;
      expect(result['one_click_compress_enabled_v1'], isTrue);
      expect(result['one_click_compress_max_long_edge_v1'], 1568);
      expect(result['one_click_compress_quality_v1'], 85);
    });

    test('maps custom with a non-int custom quality to the default 85', () {
      final result = KelivoImageSettingsMapper.translateFromUpstream(const {
        KelivoImageSettingsMapper.upstreamQualityKey: 'custom',
        KelivoImageSettingsMapper.upstreamCustomQualityKey: '95',
      })!;
      expect(result['one_click_compress_quality_v1'], 85);
    });

    test('clamps out-of-range custom quality to Cuplivo bounds', () {
      final below = KelivoImageSettingsMapper.translateFromUpstream(const {
        KelivoImageSettingsMapper.upstreamQualityKey: 'custom',
        KelivoImageSettingsMapper.upstreamCustomQualityKey: 30,
      })!;
      expect(below['one_click_compress_quality_v1'], 50);

      final above = KelivoImageSettingsMapper.translateFromUpstream(const {
        KelivoImageSettingsMapper.upstreamQualityKey: 'custom',
        KelivoImageSettingsMapper.upstreamCustomQualityKey: 100,
      })!;
      expect(above['one_click_compress_quality_v1'], 95);
    });

    test('maps the transparent toggle onto alwaysJpg', () {
      final enabled = KelivoImageSettingsMapper.translateFromUpstream(const {
        KelivoImageSettingsMapper.upstreamQualityKey: 'high',
        KelivoImageSettingsMapper.upstreamTransparentKey: true,
      })!;
      expect(enabled['one_click_compress_always_jpg_v1'], isTrue);

      final disabled = KelivoImageSettingsMapper.translateFromUpstream(const {
        KelivoImageSettingsMapper.upstreamQualityKey: 'high',
        KelivoImageSettingsMapper.upstreamTransparentKey: false,
      })!;
      expect(disabled['one_click_compress_always_jpg_v1'], isFalse);

      final missing = KelivoImageSettingsMapper.translateFromUpstream(const {
        KelivoImageSettingsMapper.upstreamQualityKey: 'high',
      })!;
      expect(missing['one_click_compress_always_jpg_v1'], isFalse);
    });

    test('falls back to balanced for unknown enum values', () {
      final result = KelivoImageSettingsMapper.translateFromUpstream(const {
        KelivoImageSettingsMapper.upstreamQualityKey: 'ultra',
      })!;
      expect(result['one_click_compress_enabled_v1'], isTrue);
      expect(result['one_click_compress_max_long_edge_v1'], 1568);
      expect(result['one_click_compress_quality_v1'], 85);
    });

    test('always emits all four Cuplivo keys', () {
      for (final quality in [
        'original',
        'high',
        'balanced',
        'saver',
        'custom',
        'unknown-future-value',
      ]) {
        final result = KelivoImageSettingsMapper.translateFromUpstream({
          KelivoImageSettingsMapper.upstreamQualityKey: quality,
        });
        expect(result, isNotNull);
        expect(result!.keys.toSet(), {
          'one_click_compress_enabled_v1',
          'one_click_compress_max_long_edge_v1',
          'one_click_compress_quality_v1',
          'one_click_compress_always_jpg_v1',
        });
      }
    });

    test('does not mutate the input settings map', () {
      final input = <String, dynamic>{
        KelivoImageSettingsMapper.upstreamQualityKey: 'saver',
        KelivoImageSettingsMapper.upstreamTransparentKey: true,
        'some_other_key': 'value',
      };
      final snapshot = Map<String, dynamic>.from(input);
      KelivoImageSettingsMapper.translateFromUpstream(input);
      expect(input, snapshot);
    });

    test('upstreamKeys covers all three consumed upstream keys', () {
      expect(KelivoImageSettingsMapper.upstreamKeys, {
        'image_upload_quality_v1',
        'image_compress_custom_quality_v1',
        'image_compress_transparent_enabled_v1',
      });
    });
  });

  group('KelivoImageSettingsMapper.translateToUpstream', () {
    test('returns empty map when the enabled key is missing', () {
      expect(KelivoImageSettingsMapper.translateToUpstream(const {}), isEmpty);
      expect(
        KelivoImageSettingsMapper.translateToUpstream(const {
          'one_click_compress_quality_v1': 75,
        }),
        isEmpty,
      );
    });

    test('maps enabled=false to original', () {
      final result = KelivoImageSettingsMapper.translateToUpstream(const {
        'one_click_compress_enabled_v1': false,
      });
      expect(result, {
        KelivoImageSettingsMapper.upstreamQualityKey: 'original',
        KelivoImageSettingsMapper.upstreamCustomQualityKey: 75,
        KelivoImageSettingsMapper.upstreamTransparentKey: false,
      });
    });

    test('maps enabled=true to custom with quality passthrough', () {
      final result = KelivoImageSettingsMapper.translateToUpstream(const {
        'one_click_compress_enabled_v1': true,
        'one_click_compress_quality_v1': 90,
        'one_click_compress_always_jpg_v1': true,
      });
      expect(result, {
        KelivoImageSettingsMapper.upstreamQualityKey: 'custom',
        KelivoImageSettingsMapper.upstreamCustomQualityKey: 90,
        KelivoImageSettingsMapper.upstreamTransparentKey: true,
      });
    });

    test('uses the default quality when the quality key is missing', () {
      final result = KelivoImageSettingsMapper.translateToUpstream(const {
        'one_click_compress_enabled_v1': true,
      });
      expect(result[KelivoImageSettingsMapper.upstreamCustomQualityKey], 75);
    });

    test('does not emit a long-edge key (upstream has no such field)', () {
      final result = KelivoImageSettingsMapper.translateToUpstream(const {
        'one_click_compress_enabled_v1': true,
        'one_click_compress_max_long_edge_v1': 4096,
      });
      expect(result, isNot(contains('one_click_compress_max_long_edge_v1')));
      expect(result[KelivoImageSettingsMapper.upstreamQualityKey], 'custom');
    });

    test('does not mutate the input prefs map', () {
      final input = <String, dynamic>{
        'one_click_compress_enabled_v1': true,
        'one_click_compress_quality_v1': 90,
        'other_key': 'value',
      };
      final snapshot = Map<String, dynamic>.from(input);
      KelivoImageSettingsMapper.translateToUpstream(input);
      expect(input, snapshot);
    });
  });
}
