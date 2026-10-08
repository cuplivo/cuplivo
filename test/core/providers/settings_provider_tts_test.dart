import 'dart:convert';

import '../../support/business_test_harness.dart';
import 'package:Cuplivo/core/providers/settings_provider.dart';
import 'package:Cuplivo/core/services/tts/network_tts.dart';
import 'package:Cuplivo/core/services/tts/tts_text_selection.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('loads and persists TTS playback settings', () async {
    final harness = await createBusinessTestHarness(
      initial: const {
        'tts_auto_play_assistant_replies_v1': true,
        'tts_text_selection_mode_v1': 'quotedOnly',
      },
    );

    final settings = SettingsProvider(harness.preferences);
    await settings.loaded;

    expect(settings.ttsAutoPlayAssistantReplies, isTrue);
    expect(settings.ttsTextSelectionMode, TtsTextSelectionMode.quotedOnly);

    await settings.setTtsTextSelectionMode(TtsTextSelectionMode.nonItalic);
    await settings.setTtsAutoPlayAssistantReplies(false);

    expect(
      harness.preferences.getString('tts_text_selection_mode_v1'),
      'nonItalic',
    );
    expect(
      harness.preferences.getBool('tts_auto_play_assistant_replies_v1'),
      isFalse,
    );
  });

  test('falls back to full text when persisted TTS mode is invalid', () async {
    final harness = await createBusinessTestHarness(
      initial: const {
        'tts_auto_play_assistant_replies_v1': true,
        'tts_text_selection_mode_v1': 'unknown-mode',
      },
    );

    final settings = SettingsProvider(harness.preferences);
    await settings.loaded;

    expect(settings.ttsTextSelectionMode, TtsTextSelectionMode.fullText);
  });

  test(
    'migrates legacy TTS index to UUID and survives earlier deletion',
    () async {
      final services = <Map<String, dynamic>>[
        {
          'id': 'first-service',
          'kind': 'openai',
          'enabled': true,
          'name': 'First',
          'apiKey': 'key',
        },
        {
          'id': 'second-service',
          'kind': 'groq',
          'enabled': true,
          'name': 'Second',
          'apiKey': 'key',
        },
      ];
      final harness = await createBusinessTestHarness(
        initial: {
          'tts_services_v1': jsonEncode(services),
          'tts_selected_v1': 1,
        },
      );
      final settings = SettingsProvider(harness.preferences);
      await settings.loaded;

      expect(settings.selectedTtsServiceId, 'second-service');
      expect(
        harness.preferences.getString('tts_selected_service_id_v1'),
        'second-service',
      );
      expect(harness.preferences.getInt('tts_selected_v1'), isNull);

      final selected = settings.ttsServices.singleWhere(
        (service) => service.id == 'second-service',
      );
      await settings.setTtsServices(<TtsServiceOptions>[selected]);

      expect(settings.selectedTtsServiceId, 'second-service');
      expect(settings.selectedTtsService?.name, 'Second');
    },
  );

  test('persists generated UUIDs for legacy TTS rows across reloads', () async {
    final harness = await createBusinessTestHarness(
      initial: {
        'tts_services_v1': jsonEncode(<Map<String, dynamic>>[
          {'kind': 'openai', 'enabled': true, 'name': 'First', 'apiKey': 'key'},
          {'kind': 'groq', 'enabled': true, 'name': 'Second', 'apiKey': 'key'},
        ]),
        'tts_selected_v1': 1,
      },
    );
    final firstLoad = SettingsProvider(harness.preferences);
    await firstLoad.loaded;
    final selectedId = firstLoad.selectedTtsServiceId;

    expect(selectedId, isNotNull);
    expect(firstLoad.selectedTtsService?.name, 'Second');
    final persistedRows =
        jsonDecode(harness.preferences.getString('tts_services_v1')!)
            as List<dynamic>;
    expect(
      persistedRows.every(
        (row) => ((row as Map<String, dynamic>)['id'] as String).isNotEmpty,
      ),
      isTrue,
    );

    final secondLoad = SettingsProvider(harness.preferences);
    await secondLoad.loaded;
    expect(secondLoad.selectedTtsServiceId, selectedId);
    expect(secondLoad.selectedTtsService?.name, 'Second');
  });
}
