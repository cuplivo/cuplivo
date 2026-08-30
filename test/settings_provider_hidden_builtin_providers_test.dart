import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:Cuplivo/core/database/business_preferences.dart';

import 'package:Cuplivo/core/providers/settings_provider.dart';

Future<void> _waitForSettingsLoad() async {
  for (var i = 0; i < 25; i++) {
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

ProviderConfig _deepSeekConfig() {
  return ProviderConfig(
    id: 'DeepSeek',
    enabled: true,
    name: 'DeepSeek',
    apiKey: 'sk-test-secret',
    baseUrl: 'https://api.deepseek.com',
    providerType: ProviderKind.openai,
    models: const ['deepseek-chat'],
  );
}

void main() {
  var businessPrefs = BusinessPreferences.memoryForTests();
  TestWidgetsFlutterBinding.ensureInitialized();

  group('SettingsProvider hidden built-in providers', () {
    test('hide persists, keeps config, clears selections', () async {
      businessPrefs = BusinessPreferences.memoryForTests({});
      final settings = SettingsProvider(preferences: businessPrefs);
      await _waitForSettingsLoad();

      await settings.setProviderConfig('DeepSeek', _deepSeekConfig());
      await settings.setCurrentModel('DeepSeek', 'deepseek-chat');
      await settings.setTitleModel('DeepSeek', 'deepseek-chat');
      await settings.togglePinModel('DeepSeek', 'deepseek-chat');

      await settings.hideBuiltinProvider('DeepSeek');

      expect(settings.isProviderHidden('DeepSeek'), isTrue);
      expect(settings.currentModelProvider, isNull);
      expect(settings.currentModelId, isNull);
      expect(settings.titleModelProvider, isNull);
      expect(settings.isModelPinned('DeepSeek', 'deepseek-chat'), isFalse);
      // Config is preserved (never wipe apiKey/models on hide)
      expect(settings.providerConfigs['DeepSeek'], isNotNull);
      expect(settings.providerConfigs['DeepSeek']!.apiKey, 'sk-test-secret');
      expect(settings.providerConfigs['DeepSeek']!.models, ['deepseek-chat']);

      // Restart: hidden state and config both survive
      final restarted = SettingsProvider(preferences: businessPrefs);
      await _waitForSettingsLoad();
      expect(restarted.isProviderHidden('DeepSeek'), isTrue);
      expect(restarted.providerConfigs['DeepSeek'], isNotNull);
    });

    test('hide ignores non-built-in (custom) keys', () async {
      businessPrefs = BusinessPreferences.memoryForTests({});
      final settings = SettingsProvider(preferences: businessPrefs);
      await _waitForSettingsLoad();

      await settings.setProviderConfig(
        'MyCustom',
        _deepSeekConfig().copyWith(id: 'MyCustom', name: 'MyCustom'),
      );
      await settings.hideBuiltinProvider('MyCustom');

      expect(settings.isProviderHidden('MyCustom'), isFalse);
      expect(settings.hiddenBuiltinProviderKeys, isEmpty);
      expect(settings.providerConfigs['MyCustom'], isNotNull);
    });

    test('restore all unhides everything and persists', () async {
      businessPrefs = BusinessPreferences.memoryForTests({});
      final settings = SettingsProvider(preferences: businessPrefs);
      await _waitForSettingsLoad();

      await settings.hideBuiltinProvider('DeepSeek');
      await settings.hideBuiltinProvider('Grok');
      expect(settings.hiddenBuiltinProviderKeys, {'DeepSeek', 'Grok'});

      await settings.restoreAllBuiltinProviders();

      expect(settings.hiddenBuiltinProviderKeys, isEmpty);
      final restarted = SettingsProvider(preferences: businessPrefs);
      await _waitForSettingsLoad();
      expect(restarted.hiddenBuiltinProviderKeys, isEmpty);
    });

    test('decode only accepts real built-in keys', () async {
      businessPrefs = BusinessPreferences.memoryForTests({
        'hidden_builtin_providers_v1': jsonEncode([
          'DeepSeek',
          'NotARealProvider',
          'Grok',
          'Open Router',
          '',
        ]),
      });
      final settings = SettingsProvider(preferences: businessPrefs);
      await _waitForSettingsLoad();

      expect(settings.hiddenBuiltinProviderKeys, {'DeepSeek', 'Grok'});
    });

    test('load reconciles selections referencing hidden providers', () async {
      businessPrefs = BusinessPreferences.memoryForTests({
        'hidden_builtin_providers_v1': jsonEncode(['DeepSeek', 'Grok']),
        'selected_model_v1': 'DeepSeek::deepseek-chat',
        'title_model_v1': 'DeepSeek::deepseek-chat',
        'translate_model_v1': 'Grok::grok-1',
        'pinned_models_v1': ['DeepSeek::deepseek-chat'],
      });
      final settings = SettingsProvider(preferences: businessPrefs);
      await _waitForSettingsLoad();

      expect(settings.isProviderHidden('DeepSeek'), isTrue);
      expect(settings.currentModelProvider, isNull);
      expect(settings.currentModelId, isNull);
      expect(settings.titleModelProvider, isNull);
      expect(settings.translateModelProvider, isNull);
      expect(settings.isModelPinned('DeepSeek', 'deepseek-chat'), isFalse);
      expect(settings.hiddenBuiltinProviderKeys, {'DeepSeek', 'Grok'});
    });

    test('hide is idempotent and unknown built-in case is tolerant', () async {
      businessPrefs = BusinessPreferences.memoryForTests({});
      final settings = SettingsProvider(preferences: businessPrefs);
      await _waitForSettingsLoad();

      await settings.hideBuiltinProvider('DeepSeek');
      await settings.hideBuiltinProvider('DeepSeek');
      expect(settings.hiddenBuiltinProviderKeys, {'DeepSeek'});

      await settings.hideBuiltinProvider('openai'); // case-sensitive: ignored
      expect(settings.hiddenBuiltinProviderKeys, {'DeepSeek'});
    });
  });
}
