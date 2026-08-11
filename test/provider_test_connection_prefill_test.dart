import 'package:flutter_test/flutter_test.dart';

import 'package:Cuplivo/core/models/assistant.dart';
import 'package:Cuplivo/core/providers/model_provider.dart';
import 'package:Cuplivo/core/providers/settings_provider.dart';

ProviderConfig _cfg(List<String> models) => ProviderConfig(
  id: 'MyProvider',
  enabled: true,
  name: 'MyProvider',
  apiKey: 'sk-test',
  baseUrl: 'https://example.com/v1',
  providerType: ProviderKind.openai,
  models: models,
);

void main() {
  group('ProviderManager.resolvePreferredTestModel', () {
    test('uses the global current model when it belongs to the provider', () {
      final cfg = _cfg(['m1', 'm2', 'm3']);
      final result = ProviderManager.resolvePreferredTestModel(
        cfg: cfg,
        currentAssistant: null,
        currentModelProvider: 'MyProvider',
        currentModelId: 'm2',
      );
      expect(result, 'm2');
    });

    test('assistant binding wins over the global current model', () {
      final cfg = _cfg(['m1', 'm2', 'm3']);
      final result = ProviderManager.resolvePreferredTestModel(
        cfg: cfg,
        currentAssistant: Assistant(
          id: 'a1',
          name: 'A',
          chatModelProvider: 'MyProvider',
          chatModelId: 'm3',
        ),
        currentModelProvider: 'MyProvider',
        currentModelId: 'm2',
      );
      expect(result, 'm3');
    });

    test('skips a candidate that is not in the model list', () {
      final cfg = _cfg(['m1', 'm2']);
      final result = ProviderManager.resolvePreferredTestModel(
        cfg: cfg,
        currentAssistant: null,
        currentModelProvider: 'MyProvider',
        currentModelId: 'deleted-model',
      );
      expect(result, 'm2');
    });

    test(
      'falls through when the current model belongs to another provider',
      () {
        final cfg = _cfg(['m1', 'm2']);
        final result = ProviderManager.resolvePreferredTestModel(
          cfg: cfg,
          currentAssistant: null,
          currentModelProvider: 'OtherProvider',
          currentModelId: 'x',
        );
        expect(result, 'm2');
      },
    );

    test('assistant bound to another provider never falls back to the global '
        'current model', () {
      final cfg = _cfg(['m1', 'm2']);
      final result = ProviderManager.resolvePreferredTestModel(
        cfg: cfg,
        currentAssistant: Assistant(
          id: 'a1',
          name: 'A',
          chatModelProvider: 'OtherProvider',
          chatModelId: 'x',
        ),
        currentModelProvider: 'MyProvider',
        currentModelId: 'm1',
      );
      expect(result, 'm2');
    });

    test('falls back to the most recently added model (last element)', () {
      final cfg = _cfg(['m1', 'm2', 'm3']);
      final result = ProviderManager.resolvePreferredTestModel(
        cfg: cfg,
        currentAssistant: null,
        currentModelProvider: null,
        currentModelId: null,
      );
      expect(result, 'm3');
    });

    test('a single model is chosen without any current selection', () {
      final cfg = _cfg(['only']);
      final result = ProviderManager.resolvePreferredTestModel(
        cfg: cfg,
        currentAssistant: null,
        currentModelProvider: null,
        currentModelId: null,
      );
      expect(result, 'only');
    });

    test('returns null when the provider has no models', () {
      final cfg = _cfg(const []);
      final result = ProviderManager.resolvePreferredTestModel(
        cfg: cfg,
        currentAssistant: null,
        currentModelProvider: 'MyProvider',
        currentModelId: 'm1',
      );
      expect(result, isNull);
    });
  });
}
