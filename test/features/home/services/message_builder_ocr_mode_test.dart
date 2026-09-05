import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:Cuplivo/core/database/business_preferences.dart';

import 'package:Cuplivo/core/models/assistant.dart';
import 'package:Cuplivo/core/providers/settings_provider.dart';
import 'package:Cuplivo/core/services/chat/chat_service.dart';
import 'package:Cuplivo/features/home/services/message_builder_service.dart';

var businessPrefs = BusinessPreferences.memoryForTests();

class _FakeBuildContext implements BuildContext {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeChatService extends ChatService {
  @override
  List<Map<String, dynamic>> getToolEvents(String assistantMessageId) =>
      const <Map<String, dynamic>>[];
}

ProviderConfig _configWithOcrCandidates() {
  return ProviderConfig(
    id: 'OcrProvider',
    enabled: true,
    name: 'OCR Provider',
    apiKey: 'test-key',
    baseUrl: 'https://example.test',
    models: const ['vision-model', 'text-model'],
    modelOverrides: const {
      'vision-model': {
        'name': 'Vision Model',
        'input': ['text', 'image'],
      },
      'text-model': {
        'name': 'Text Model',
        'input': ['text'],
      },
    },
  );
}

Future<void> _waitForSettingsLoad() async {
  for (var i = 0; i < 25; i++) {
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

Future<SettingsProvider> _settingsWithOcrModel() async {
  businessPrefs = BusinessPreferences.memoryForTests({});
  final settings = SettingsProvider(preferences: businessPrefs);
  await _waitForSettingsLoad();
  await settings.setProviderConfig('OcrProvider', _configWithOcrCandidates());
  await settings.setOcrModel('OcrProvider', 'vision-model');
  return settings;
}

const _imageMarker = '[image:C:/tmp/photo.png]';
const _ocrText = 'OCR EXTRACTED TEXT';

/// Runs [MessageBuilderService.processUserMessagesForApi] over a single user
/// message containing one image marker and returns the final content.
Future<String> _processContent({
  required SettingsProvider settings,
  required Assistant? assistant,
  required String modelId,
}) async {
  final builder = MessageBuilderService(
    preferences: businessPrefs,
    chatService: _FakeChatService(),
    contextProvider: _FakeBuildContext(),
    ocrHandler: (_, {requestId}) async => _ocrText,
  );
  final apiMessages = <Map<String, dynamic>>[
    {'role': 'user', 'content': 'hello $_imageMarker'},
  ];
  await builder.processUserMessagesForApi(
    apiMessages,
    settings,
    assistant,
    providerKey: 'OcrProvider',
    modelId: modelId,
  );
  return apiMessages.last['content'] as String;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('processUserMessagesForApi — OCR mode', () {
    test(
      'auto + vision model sends images raw (markers kept, no OCR)',
      () async {
        final settings = await _settingsWithOcrModel();
        final content = await _processContent(
          settings: settings,
          assistant: Assistant(id: 'a1', name: 'A', ocrMode: 'auto'),
          modelId: 'vision-model',
        );
        expect(content, contains(_imageMarker));
        expect(content, isNot(contains('<image_file_ocr>')));
      },
    );

    test('auto + text model OCRs when an OCR model is configured', () async {
      final settings = await _settingsWithOcrModel();
      final content = await _processContent(
        settings: settings,
        assistant: Assistant(id: 'a1', name: 'A', ocrMode: 'auto'),
        modelId: 'text-model',
      );
      expect(content, isNot(contains(_imageMarker)));
      expect(content, contains('<image_file_ocr>'));
      expect(content, contains(_ocrText));
    });

    test('always OCRs even for vision models', () async {
      final settings = await _settingsWithOcrModel();
      final content = await _processContent(
        settings: settings,
        assistant: Assistant(id: 'a1', name: 'A', ocrMode: 'always'),
        modelId: 'vision-model',
      );
      expect(content, isNot(contains(_imageMarker)));
      expect(content, contains('<image_file_ocr>'));
      expect(content, contains(_ocrText));
    });

    test('never keeps markers for vision models and skips OCR', () async {
      final settings = await _settingsWithOcrModel();
      final content = await _processContent(
        settings: settings,
        assistant: Assistant(id: 'a1', name: 'A', ocrMode: 'never'),
        modelId: 'vision-model',
      );
      expect(content, contains(_imageMarker));
      expect(content, isNot(contains('<image_file_ocr>')));
    });

    test('auto without an OCR model falls back to raw markers', () async {
      businessPrefs = BusinessPreferences.memoryForTests({});
      final settings = SettingsProvider(preferences: businessPrefs);
      await _waitForSettingsLoad();
      await settings.setProviderConfig(
        'OcrProvider',
        _configWithOcrCandidates(),
      );

      final content = await _processContent(
        settings: settings,
        assistant: Assistant(id: 'a1', name: 'A', ocrMode: 'auto'),
        modelId: 'text-model',
      );
      expect(content, contains(_imageMarker));
      expect(content, isNot(contains('<image_file_ocr>')));
    });
  });
}
