import 'package:flutter_test/flutter_test.dart';

import 'package:Cuplivo/core/utils/openai_model_compat.dart';

void main() {
  group('reasoningEffortsOverride', () {
    test('null override follows the registry', () {
      expect(reasoningEffortsOverride(null), isNull);
      expect(reasoningEffortsOverride(const {}), isNull);
    });

    test('parses both key spellings, trims and lowercases', () {
      expect(
        reasoningEffortsOverride(const {
          'reasoningEfforts': [' High ', 'LOW'],
        }),
        ['low', 'high'],
      );
      expect(
        reasoningEffortsOverride(const {
          'reasoning_efforts': ['medium'],
        }),
        ['medium'],
      );
    });

    test('explicit empty list is the user vocabulary (no effort param)', () {
      expect(reasoningEffortsOverride(const {'reasoningEfforts': []}), isEmpty);
    });

    test('unknown values dropped, remainder in canonical order', () {
      expect(
        reasoningEffortsOverride(const {
          'reasoningEfforts': ['xhigh', 'turbo', 'low'],
        }),
        ['low', 'xhigh'],
      );
    });
  });

  group('reasoningSupportFromOverride', () {
    test('null efforts yield null (registry fallback)', () {
      expect(reasoningSupportFromOverride(null), isNull);
    });

    test('empty vocabulary disables the effort parameter', () {
      final support = reasoningSupportFromOverride(const [])!;
      expect(support.effortParameterSupported, isFalse);
      expect(support.supportedEfforts, isEmpty);
    });

    test('vocabulary becomes supportedEfforts', () {
      final support = reasoningSupportFromOverride(const ['low', 'high'])!;
      expect(support.effortParameterSupported, isTrue);
      expect(support.supportedEfforts, ['low', 'high']);
      expect(support.supportsXhigh, isFalse);
      expect(support.supportsMax, isFalse);
    });
  });

  group('normalize with override', () {
    test('override replaces the registry for membership', () {
      final lowOnly = reasoningSupportFromOverride(const ['low'])!;
      expect(
        openAINormalizeReasoningEffort(
          'high',
          'gpt-5',
          overrideSupport: lowOnly,
        ),
        'low',
      );
    });

    test('empty override vocabulary normalizes to auto', () {
      final none = reasoningSupportFromOverride(const [])!;
      expect(
        openAINormalizeReasoningEffort('high', 'gpt-5', overrideSupport: none),
        'auto',
      );
    });

    test('registry still applies without an override', () {
      expect(openAINormalizeReasoningEffort('high', 'gpt-5'), 'high');
    });
  });
}
