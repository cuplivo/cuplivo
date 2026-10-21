import "support/business_test_harness.dart";

import 'package:flutter_test/flutter_test.dart';

import 'package:Cuplivo/core/models/assistant.dart';
import 'package:Cuplivo/core/providers/settings_provider.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('SettingsProvider chat suggestions', () {
    test('defaults suggestion model to disabled', () async {
      final harness = await createBusinessTestHarness(initial: {});
      final settings = SettingsProvider(harness.preferences);

      await settings.loaded;

      expect(settings.suggestionModelProvider, isNull);
      expect(settings.suggestionModelId, isNull);
      expect(settings.suggestionModelKey, isNull);
      expect(settings.isSuggestionGenerationEnabled, isFalse);
      expect(
        settings.suggestionPrompt,
        SettingsProvider.defaultSuggestionPrompt,
      );
    });

    test('persists selected suggestion model and prompt', () async {
      final harness = await createBusinessTestHarness(initial: {});
      final settings = SettingsProvider(harness.preferences);

      await settings.loaded;
      await settings.setSuggestionModel('OpenAI', 'gpt-test');
      await settings.setSuggestionPrompt('Custom {content} {locale}');

      expect(settings.suggestionModelProvider, 'OpenAI');
      expect(settings.suggestionModelId, 'gpt-test');
      expect(settings.suggestionModelKey, 'OpenAI::gpt-test');
      expect(settings.isSuggestionGenerationEnabled, isTrue);
      expect(settings.suggestionPrompt, 'Custom {content} {locale}');

      final prefs = harness.preferences;
      expect(prefs.getString('suggestion_model_v1'), 'OpenAI::gpt-test');
      expect(prefs.getBool('suggestion_generation_enabled_v1'), isTrue);
      expect(
        prefs.getString('suggestion_prompt_v1'),
        'Custom {content} {locale}',
      );
    });

    test('defaults suggestion tap to auto-send', () async {
      final harness = await createBusinessTestHarness(initial: {});
      final settings = SettingsProvider(harness.preferences);

      await settings.loaded;

      expect(settings.insertSuggestionOnTapOnly, isFalse);
    });

    test('loads and persists insert-only suggestion tap mode', () async {
      final harness = await createBusinessTestHarness(
        initial: {'suggestion_insert_on_tap_only_v1': true},
      );
      final settings = SettingsProvider(harness.preferences);

      await settings.loaded;

      expect(settings.insertSuggestionOnTapOnly, isTrue);

      await settings.setInsertSuggestionOnTapOnly(false);

      expect(settings.insertSuggestionOnTapOnly, isFalse);
      final prefs = harness.preferences;
      expect(prefs.getBool('suggestion_insert_on_tap_only_v1'), isFalse);
    });

    test(
      'clears suggestion model when provider selection is cleared',
      () async {
        final harness = await createBusinessTestHarness(
          initial: {'suggestion_model_v1': 'OpenAI::gpt-test'},
        );
        final settings = SettingsProvider(harness.preferences);

        await settings.loaded;
        await settings.clearSelectionsForProvider('OpenAI');

        expect(settings.suggestionModelProvider, isNull);
        expect(settings.suggestionModelId, isNull);
        expect(settings.isSuggestionGenerationEnabled, isFalse);
        final prefs = harness.preferences;
        expect(prefs.getString('suggestion_model_v1'), isNull);
        expect(prefs.getBool('suggestion_generation_enabled_v1'), isFalse);
      },
    );

    test('reset follows the current chat model until disabled', () async {
      final harness = await createBusinessTestHarness(initial: {});
      final settings = SettingsProvider(harness.preferences);

      await settings.loaded;
      await settings.resetSuggestionModel();

      expect(settings.isSuggestionGenerationEnabled, isTrue);
      expect(settings.suggestionModelKey, isNull);
      expect(
        harness.preferences.getBool('suggestion_generation_enabled_v1'),
        isTrue,
      );

      await settings.disableSuggestionGeneration();

      expect(settings.isSuggestionGenerationEnabled, isFalse);
      expect(
        harness.preferences.getBool('suggestion_generation_enabled_v1'),
        isFalse,
      );
    });
  });

  group('SettingsProvider suggestion gate', () {
    const optedIn = Assistant(id: 'assistant-on', name: 'On');
    const optedOut = Assistant(
      id: 'assistant-off',
      name: 'Off',
      suggestionsEnabled: false,
    );

    test(
      'the global switch is the master and the assistant opts out',
      () async {
        final harness = await createBusinessTestHarness(initial: {});
        final settings = SettingsProvider(harness.preferences);
        await settings.loaded;

        await settings.disableSuggestionGeneration();
        expect(settings.isSuggestionGenerationAllowedFor(optedIn), isFalse);
        expect(settings.isSuggestionGenerationAllowedFor(optedOut), isFalse);
        // No assistant (an empty list) follows the global switch alone.
        expect(settings.isSuggestionGenerationAllowedFor(null), isFalse);

        await settings.resetSuggestionModel();
        expect(settings.isSuggestionGenerationAllowedFor(optedIn), isTrue);
        expect(settings.isSuggestionGenerationAllowedFor(null), isTrue);
        expect(settings.isSuggestionGenerationAllowedFor(optedOut), isFalse);
      },
    );

    test(
      'a selected suggestion model does not override an assistant opt-out',
      () async {
        final harness = await createBusinessTestHarness(initial: {});
        final settings = SettingsProvider(harness.preferences);
        await settings.loaded;

        await settings.setSuggestionModel('OpenAI', 'gpt-test');

        expect(settings.isSuggestionGenerationAllowedFor(optedIn), isTrue);
        expect(settings.isSuggestionGenerationAllowedFor(optedOut), isFalse);
      },
    );

    test(
      'the inactive note covers exactly one cell of the two switches',
      () async {
        final harness = await createBusinessTestHarness(initial: {});
        final settings = SettingsProvider(harness.preferences);
        await settings.loaded;

        // Global off: only an assistant that still allows suggestions has
        // something to explain.
        await settings.disableSuggestionGeneration();
        expect(settings.isSuggestionOptOutInactiveFor(optedIn), isTrue);
        expect(settings.isSuggestionOptOutInactiveFor(optedOut), isFalse);
        expect(settings.isSuggestionOptOutInactiveFor(null), isFalse);

        // Global on: nothing is waiting on the master switch.
        await settings.resetSuggestionModel();
        expect(settings.isSuggestionOptOutInactiveFor(optedIn), isFalse);
        expect(settings.isSuggestionOptOutInactiveFor(optedOut), isFalse);
        expect(settings.isSuggestionOptOutInactiveFor(null), isFalse);
      },
    );
  });
}
