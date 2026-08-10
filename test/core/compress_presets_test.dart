import 'package:flutter_test/flutter_test.dart';
import 'package:Cuplivo/core/prompts/compress_presets.dart';
import 'package:Cuplivo/core/prompts/constants/compress_prompts.dart';
import 'package:Cuplivo/core/providers/settings_provider.dart';

void main() {
  group('CompressPresets.detect', () {
    test('returns "standard" for exact defaultCompressPrompt', () {
      expect(CompressPresets.detect(defaultCompressPrompt), 'standard');
    });

    test(
      'returns "standard" for defaultCompressPrompt with trailing whitespace',
      () {
        expect(CompressPresets.detect('$defaultCompressPrompt\n'), 'standard');
        expect(
          CompressPresets.detect('  $defaultCompressPrompt  '),
          'standard',
        );
      },
    );

    test('returns "detailed" for exact detailedCompressPrompt', () {
      expect(CompressPresets.detect(detailedCompressPrompt), 'detailed');
    });

    test('returns "detailed" for detailedCompressPrompt with whitespace', () {
      expect(CompressPresets.detect('$detailedCompressPrompt\n'), 'detailed');
    });

    test('returns null for custom text that does not match any preset', () {
      expect(CompressPresets.detect('this is a custom prompt'), isNull);
    });

    test('returns null for empty string', () {
      expect(CompressPresets.detect(''), isNull);
    });

    test('returns null for text that almost matches but differs', () {
      final modified = defaultCompressPrompt.replaceFirst(
        'concise but complete',
        'short but complete',
      );
      expect(CompressPresets.detect(modified), isNull);
    });

    test('matching is trim-only, not whitespace-collapsed', () {
      final extraSpaces = defaultCompressPrompt.replaceAll('\n\n', '\n\n\n');
      expect(CompressPresets.detect(extraSpaces), isNull);
    });
  });

  group('CompressPresets.byId', () {
    test('returns the standard preset', () {
      final p = CompressPresets.byId('standard');
      expect(p, isNotNull);
      expect(p!.id, 'standard');
      expect(p.prompt, defaultCompressPrompt);
    });

    test('returns the detailed preset', () {
      final p = CompressPresets.byId('detailed');
      expect(p, isNotNull);
      expect(p!.id, 'detailed');
      expect(p.prompt, detailedCompressPrompt);
    });

    test('returns null for unknown id', () {
      expect(CompressPresets.byId('nonexistent'), isNull);
      expect(CompressPresets.byId(''), isNull);
    });
  });

  group('CompressPresets.all', () {
    test('contains exactly two presets', () {
      expect(CompressPresets.all.length, 2);
    });

    test('contains standard and detailed', () {
      final ids = CompressPresets.all.map((p) => p.id).toSet();
      expect(ids, contains('standard'));
      expect(ids, contains('detailed'));
    });
  });

  group('Default preset parity', () {
    test('standard preset is byte-identical to the reset default', () {
      final standard = CompressPresets.byId('standard')!;
      expect(standard.prompt, SettingsProvider.defaultCompressPrompt);
    });
  });
}
