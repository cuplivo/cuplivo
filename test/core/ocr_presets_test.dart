import 'package:flutter_test/flutter_test.dart';
import 'package:Cuplivo/core/prompts/ocr_presets.dart';
import 'package:Cuplivo/core/prompts/constants/ocr_prompts.dart';
import 'package:Cuplivo/core/providers/settings_provider.dart';

void main() {
  group('OcrPresets.detect', () {
    test('returns "standard" for exact defaultOcrPrompt', () {
      expect(OcrPresets.detect(defaultOcrPrompt), 'standard');
    });

    test(
      'returns "standard" for defaultOcrPrompt with trailing whitespace',
      () {
        expect(OcrPresets.detect('$defaultOcrPrompt\n'), 'standard');
        expect(OcrPresets.detect('  $defaultOcrPrompt  '), 'standard');
      },
    );

    test('returns "coordinate" for exact coordinateOcrPrompt', () {
      expect(OcrPresets.detect(coordinateOcrPrompt), 'coordinate');
    });

    test('returns "coordinate" for coordinateOcrPrompt with whitespace', () {
      expect(OcrPresets.detect('$coordinateOcrPrompt\n'), 'coordinate');
    });

    test('returns null for custom text that does not match any preset', () {
      expect(OcrPresets.detect('this is a custom prompt'), isNull);
    });

    test('returns null for empty string', () {
      expect(OcrPresets.detect(''), isNull);
    });

    test('returns null for text that almost matches but differs', () {
      final modified = defaultOcrPrompt.replaceFirst(
        'OCR assistant',
        'OCR helper',
      );
      expect(OcrPresets.detect(modified), isNull);
    });

    test('matching is trim-only, not whitespace-collapsed', () {
      final extraSpaces = defaultOcrPrompt.replaceAll('\n\n', '\n\n\n');
      expect(OcrPresets.detect(extraSpaces), isNull);
    });
  });

  group('OcrPresets.byId', () {
    test('returns the standard preset', () {
      final p = OcrPresets.byId('standard');
      expect(p, isNotNull);
      expect(p!.id, 'standard');
      expect(p.prompt, defaultOcrPrompt);
    });

    test('returns the coordinate preset', () {
      final p = OcrPresets.byId('coordinate');
      expect(p, isNotNull);
      expect(p!.id, 'coordinate');
      expect(p.prompt, coordinateOcrPrompt);
    });

    test('returns null for unknown id', () {
      expect(OcrPresets.byId('nonexistent'), isNull);
      expect(OcrPresets.byId(''), isNull);
    });
  });

  group('OcrPresets.all', () {
    test('contains exactly two presets', () {
      expect(OcrPresets.all.length, 2);
    });

    test('contains standard and coordinate', () {
      final ids = OcrPresets.all.map((p) => p.id).toSet();
      expect(ids, contains('standard'));
      expect(ids, contains('coordinate'));
    });
  });

  group('Default preset parity', () {
    test('standard preset is byte-identical to the reset default', () {
      final standard = OcrPresets.byId('standard')!;
      expect(standard.prompt, SettingsProvider.defaultOcrPrompt);
    });
  });
}
