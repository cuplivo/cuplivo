import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:Cuplivo/core/database/business_preferences.dart';

import 'package:Cuplivo/core/models/assistant.dart';
import 'package:Cuplivo/core/models/chat_message.dart';
import 'package:Cuplivo/core/models/conversation.dart';
import 'package:Cuplivo/core/providers/settings_provider.dart';
import 'package:Cuplivo/core/services/chat/chat_service.dart';
import 'package:Cuplivo/features/group_chat/services/assistant_private_context_builder.dart';
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
  bool provideOcrHandler = true,
  String rawContent = 'hello $_imageMarker',
}) async {
  final builder = MessageBuilderService(
    preferences: businessPrefs,
    chatService: _FakeChatService(),
    contextProvider: _FakeBuildContext(),
    ocrHandler: provideOcrHandler ? (_, {requestId}) async => _ocrText : null,
  );
  final apiMessages = <Map<String, dynamic>>[
    {'role': 'user', 'content': rawContent},
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

  group('processUserMessagesForApi — group chat private context', () {
    // Group user messages are persisted with the raw `[image:]` marker and
    // rewritten by AssistantPrivateContextBuilder as `[User]: content`; the
    // pipeline must parse it out of that prefixed shape.
    const groupContent = '[User]: 看看这张 $_imageMarker';

    test('vision member keeps the marker through the [User]: prefix', () async {
      final settings = await _settingsWithOcrModel();
      final content = await _processContent(
        settings: settings,
        assistant: Assistant(id: 'g1', name: 'Vision', ocrMode: 'auto'),
        modelId: 'vision-model',
        rawContent: groupContent,
      );
      expect(content, contains(_imageMarker));
      expect(content, isNot(contains('<image_file_ocr>')));
    });

    test(
      'text member OCRs the image inside the [User]: prefixed message',
      () async {
        final settings = await _settingsWithOcrModel();
        final content = await _processContent(
          settings: settings,
          assistant: Assistant(id: 'g2', name: 'Text', ocrMode: 'auto'),
          modelId: 'text-model',
          rawContent: groupContent,
        );
        expect(content, isNot(contains(_imageMarker)));
        expect(content, contains('<image_file_ocr>'));
        expect(content, contains(_ocrText));
      },
    );

    test(
      'text member without an OCR handler loses the image (B4 guard)',
      () async {
        final settings = await _settingsWithOcrModel();
        final content = await _processContent(
          settings: settings,
          assistant: Assistant(id: 'g3', name: 'NoOcr', ocrMode: 'auto'),
          modelId: 'text-model',
          rawContent: groupContent,
          provideOcrHandler: false,
        );
        // ocrActive is true but no handler: markers are dropped and no OCR
        // text is injected — must at least not crash, and the request keeps
        // the role prefix with the remaining text.
        expect(content, isNot(contains(_imageMarker)));
        expect(content, startsWith('[User]:'));
      },
    );

    // Reviewer scenario: the human image survives Alice's first turn, but a
    // repeat-select of Alice after Bob (user -> Alice -> Bob -> Alice) hands
    // the pipeline a trailing member-only user bubble. The rewritten bubble
    // must re-attach the human turn's media marker, otherwise
    // processUserMessagesForApi (which only inspects the last user message)
    // returns no lastUserImagePaths and GenerationContext.userMediaPaths is
    // empty on that repeated turn.
    test('vision member repeated turn keeps the uploaded image across a '
        'member-only trailing bubble', () async {
      final settings = await _settingsWithOcrModel();
      final conv = Conversation(
        id: 'c1',
        title: 'g',
        conversationKind: Conversation.kindGroup,
      );
      final alice = Assistant(id: 'a1', name: 'Alice', ocrMode: 'auto');
      final bob = Assistant(id: 'a2', name: 'Bob');
      final public = [
        ChatMessage(
          role: 'user',
          content: '看看这张 $_imageMarker',
          conversationId: 'c1',
        ),
        ChatMessage(
          role: 'assistant',
          content: '好的',
          conversationId: 'c1',
          speakerAssistantId: 'a1',
        ),
        ChatMessage(
          role: 'assistant',
          content: '补充一点',
          conversationId: 'c1',
          speakerAssistantId: 'a2',
        ),
      ];

      final private =
          AssistantPrivateContextBuilder(chatService: _FakeChatService()).build(
            conversation: conv,
            publicMessages: public,
            speaker: alice,
            userName: 'User',
            assistantsById: {'a1': alice, 'a2': bob},
          );
      final apiMessages = <Map<String, dynamic>>[
        for (final m in private) {'role': m.role, 'content': m.content},
      ];

      final messageBuilder = MessageBuilderService(
        preferences: businessPrefs,
        chatService: _FakeChatService(),
        contextProvider: _FakeBuildContext(),
        ocrHandler: (_, {requestId}) async => 'no ocr',
      );
      final lastUserImagePaths = await messageBuilder.processUserMessagesForApi(
        apiMessages,
        settings,
        alice,
        providerKey: 'OcrProvider',
        modelId: 'vision-model',
      );

      // This return value is PreparedGeneration.lastUserImagePaths and,
      // with inputData == null, the direct source of
      // GenerationContext.userMediaPaths.
      expect(lastUserImagePaths, contains('C:/tmp/photo.png'));
    });
  });
}
