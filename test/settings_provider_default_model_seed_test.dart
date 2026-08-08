import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:Cuplivo/core/providers/settings_provider.dart';

Future<void> _waitForSettingsLoad() async {
  for (var i = 0; i < 25; i++) {
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('SettingsProvider default model seed', () {
    test('seeds DeepSeek once on a fresh install', () async {
      SharedPreferences.setMockInitialValues({});
      final settings = SettingsProvider();

      await _waitForSettingsLoad();

      expect(settings.currentModelProvider, 'DeepSeek');
      expect(settings.currentModelId, 'deepseek-v4-flash');
    });

    test('does not re-seed after the user resets the model', () async {
      SharedPreferences.setMockInitialValues({});
      final first = SettingsProvider();

      await _waitForSettingsLoad();
      expect(first.currentModelProvider, 'DeepSeek');

      await first.resetCurrentModel();
      expect(first.currentModelProvider, isNull);

      // Simulate a restart: a fresh provider instance re-reads prefs.
      final second = SettingsProvider();
      await _waitForSettingsLoad();

      expect(second.currentModelProvider, isNull);
      expect(second.currentModelId, isNull);
    });

    test('keeps a persisted model selection untouched', () async {
      SharedPreferences.setMockInitialValues({
        'selected_model_v1': 'OpenAI::gpt-4o',
      });
      final settings = SettingsProvider();

      await _waitForSettingsLoad();

      expect(settings.currentModelProvider, 'OpenAI');
      expect(settings.currentModelId, 'gpt-4o');
    });

    test(
      'does not re-seed an install that already had a model and reset it',
      () async {
        SharedPreferences.setMockInitialValues({
          'selected_model_v1': 'OpenAI::gpt-4o',
        });
        final first = SettingsProvider();

        await _waitForSettingsLoad();
        expect(first.currentModelProvider, 'OpenAI');

        await first.resetCurrentModel();

        final second = SettingsProvider();
        await _waitForSettingsLoad();

        expect(second.currentModelProvider, isNull);
      },
    );
  });
}
