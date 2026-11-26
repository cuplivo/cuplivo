import 'package:flutter_test/flutter_test.dart';

import 'package:Cuplivo/core/models/assistant.dart';
import 'package:Cuplivo/core/models/conversation.dart';
import 'package:Cuplivo/core/providers/settings_provider.dart';
import 'package:Cuplivo/features/home/utils/model_display_helper.dart';

import '../../../support/business_test_harness.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late SettingsProvider settings;

  setUp(() async {
    settings = SettingsProvider(createBusinessTestPreferences());
    await settings.loaded;
    await settings.setCurrentModel('GlobalProvider', 'global-model');
  });

  Assistant assistantWithModel({String? providerKey, String? modelId}) =>
      Assistant(
        id: 'assistant',
        name: 'Assistant',
        chatModelProvider: providerKey,
        chatModelId: modelId,
      );

  Conversation conversationWithModel({String? providerKey, String? modelId}) =>
      Conversation(
        title: 'Chat',
        chatModelProvider: providerKey,
        chatModelId: modelId,
      );

  test('per-chat models default to off', () {
    expect(settings.perChatModelEnabled, isFalse);
  });

  test('falls back to the global default when nothing overrides it', () {
    final resolved = resolveChatModel(
      settings,
      conversation: conversationWithModel(),
      assistant: assistantWithModel(),
    );

    expect(resolved.providerKey, 'GlobalProvider');
    expect(resolved.modelId, 'global-model');
  });

  test('the assistant outranks the global default', () {
    final resolved = resolveChatModel(
      settings,
      conversation: conversationWithModel(),
      assistant: assistantWithModel(
        providerKey: 'AssistantProvider',
        modelId: 'assistant-model',
      ),
    );

    expect(resolved.providerKey, 'AssistantProvider');
    expect(resolved.modelId, 'assistant-model');
  });

  test('the conversation outranks the assistant when enabled', () async {
    await settings.setPerChatModelEnabled(true);

    final resolved = resolveChatModel(
      settings,
      conversation: conversationWithModel(
        providerKey: 'ConversationProvider',
        modelId: 'conversation-model',
      ),
      assistant: assistantWithModel(
        providerKey: 'AssistantProvider',
        modelId: 'assistant-model',
      ),
    );

    expect(resolved.providerKey, 'ConversationProvider');
    expect(resolved.modelId, 'conversation-model');
  });

  test('a conversation without an override follows the assistant', () {
    final resolved = resolveChatModel(
      settings,
      conversation: conversationWithModel(),
      assistant: assistantWithModel(
        providerKey: 'AssistantProvider',
        modelId: 'assistant-model',
      ),
    );

    expect(resolved.providerKey, 'AssistantProvider');
  });

  test('a null conversation resolves as before this feature', () {
    final resolved = resolveChatModel(
      settings,
      assistant: assistantWithModel(
        providerKey: 'AssistantProvider',
        modelId: 'assistant-model',
      ),
    );

    expect(resolved.providerKey, 'AssistantProvider');
    expect(resolved.modelId, 'assistant-model');
  });

  test(
    'the conversation layer is skipped when per-chat models are off',
    () async {
      await settings.setPerChatModelEnabled(false);

      final resolved = resolveChatModel(
        settings,
        conversation: conversationWithModel(
          providerKey: 'ConversationProvider',
          modelId: 'conversation-model',
        ),
        assistant: assistantWithModel(
          providerKey: 'AssistantProvider',
          modelId: 'assistant-model',
        ),
      );

      expect(resolved.providerKey, 'AssistantProvider');
      expect(resolved.modelId, 'assistant-model');
    },
  );

  test('turning per-chat models back on restores the pin', () async {
    final conversation = conversationWithModel(
      providerKey: 'ConversationProvider',
      modelId: 'conversation-model',
    );
    final assistant = assistantWithModel(
      providerKey: 'AssistantProvider',
      modelId: 'assistant-model',
    );

    await settings.setPerChatModelEnabled(false);
    await settings.setPerChatModelEnabled(true);

    final resolved = resolveChatModel(
      settings,
      conversation: conversation,
      assistant: assistant,
    );

    expect(resolved.providerKey, 'ConversationProvider');
    expect(resolved.modelId, 'conversation-model');
  });

  test('a group topic ignores a pinned conversation model', () async {
    await settings.setPerChatModelEnabled(true);

    // A group writes every reply with its speaker's own model, so a pin on the
    // topic cannot mean anything — including one left over from before the
    // conversation became a topic.
    final resolved = resolveChatModel(
      settings,
      conversation: conversationWithModel(
        providerKey: 'ConversationProvider',
        modelId: 'conversation-model',
      ).withGroupChatId('g1'),
      assistant: assistantWithModel(
        providerKey: 'AssistantProvider',
        modelId: 'assistant-model',
      ),
    );

    expect(resolved.providerKey, 'AssistantProvider');
    expect(resolved.modelId, 'assistant-model');
  });

  test('getActiveModelIds and getModelDisplayInfo agree with it', () async {
    await settings.setPerChatModelEnabled(true);

    final conversation = conversationWithModel(
      providerKey: 'ConversationProvider',
      modelId: 'conversation-model',
    );
    final assistant = assistantWithModel(
      providerKey: 'AssistantProvider',
      modelId: 'assistant-model',
    );

    final ids = getActiveModelIds(
      settings,
      conversation: conversation,
      assistant: assistant,
    );
    final display = getModelDisplayInfo(
      settings,
      conversation: conversation,
      assistant: assistant,
    );

    expect(ids.providerKey, 'ConversationProvider');
    expect(ids.modelId, 'conversation-model');
    expect(display.providerKey, 'ConversationProvider');
    expect(display.modelId, 'conversation-model');
    expect(display.isConfigured, isTrue);
  });

  group('modelDisplayName', () {
    setUp(() async {
      await settings.setProviderConfig(
        'Named',
        ProviderConfig(
          id: 'Named',
          enabled: true,
          name: 'Named',
          apiKey: 'k',
          baseUrl: 'https://example.test/v1',
          providerType: ProviderKind.openai,
          modelOverrides: {
            'aliased': {'name': '  Friendly  '},
            'remapped': {'apiModelId': 'upstream-remapped'},
            'blank-name': {'name': ' ', 'api_model_id': 'upstream-blank'},
            'broken': 'not a map',
          },
        ),
      );
    });

    test("the provider's name for a model outranks every other source", () {
      expect(modelDisplayName(settings, 'Named', 'aliased'), 'Friendly');
    });

    test('a remapped model is called by the id it is sent upstream as', () {
      expect(
        modelDisplayName(settings, 'Named', 'remapped'),
        'upstream-remapped',
      );
      expect(
        modelDisplayName(settings, 'Named', 'blank-name'),
        'upstream-blank',
      );
    });

    test('nothing to go on keeps the raw id', () {
      expect(modelDisplayName(settings, 'Named', 'plain'), 'plain');
      expect(modelDisplayName(settings, 'gone', 'plain'), 'plain');
      expect(modelDisplayName(settings, 'Named', 'broken'), 'broken');
    });

    test('getModelDisplayInfo reads the same name', () {
      final display = getModelDisplayInfo(
        settings,
        assistant: assistantWithModel(providerKey: 'Named', modelId: 'aliased'),
      );
      expect(display.modelDisplay, 'Friendly');
    });
  });

  group('resolveTitleModel', () {
    Conversation groupConversation() =>
        Conversation(title: 'Topic', extras: const {}).withGroupChatId('g1');

    test('the title model outranks every chat model', () async {
      await settings.setTitleModel('TitleProvider', 'title-model');
      await settings.setPerChatModelEnabled(true);

      final resolved = resolveTitleModel(
        settings,
        conversation: conversationWithModel(
          providerKey: 'ConversationProvider',
          modelId: 'conversation-model',
        ),
        assistant: assistantWithModel(
          providerKey: 'AssistantProvider',
          modelId: 'assistant-model',
        ),
      );

      expect(resolved.providerKey, 'TitleProvider');
      expect(resolved.modelId, 'title-model');
    });

    test(
      'a 1:1 chat without a title model resolves as its chat does',
      () async {
        final conversation = conversationWithModel(
          providerKey: 'ConversationProvider',
          modelId: 'conversation-model',
        );
        final assistant = assistantWithModel(
          providerKey: 'AssistantProvider',
          modelId: 'assistant-model',
        );

        final resolved = resolveTitleModel(
          settings,
          conversation: conversation,
          assistant: assistant,
        );
        final chat = resolveChatModel(
          settings,
          conversation: conversation,
          assistant: assistant,
        );

        expect(resolved.providerKey, chat.providerKey);
        expect(resolved.modelId, chat.modelId);
        expect(resolved.providerKey, 'AssistantProvider');
      },
    );

    test('a group topic falls back to the director model', () async {
      await settings.setDirectorModel('DirectorProvider', 'director-model');

      final resolved = resolveTitleModel(
        settings,
        conversation: groupConversation(),
      );

      expect(resolved.providerKey, 'DirectorProvider');
      expect(resolved.modelId, 'director-model');
    });

    test('a decision director never writes a group title', () async {
      await settings.setProviderConfig(
        'Dir',
        ProviderConfig(
          id: 'Dir',
          enabled: true,
          name: 'Dir',
          apiKey: 'k',
          baseUrl: 'https://example.test/v1',
          providerType: ProviderKind.openai,
          modelOverrides: {
            'judge': {'type': 'decision'},
          },
        ),
      );
      await settings.setDirectorModel('Dir', 'judge');

      final resolved = resolveTitleModel(
        settings,
        conversation: groupConversation(),
      );

      // A decision model answers typed questions and produces no text: asking
      // it for a title is a request that can only fail, leaving the topic on
      // its placeholder name. The chain skips it and lands on the default chat
      // model instead.
      expect(resolved.providerKey, 'GlobalProvider');
      expect(resolved.modelId, 'global-model');
    });

    test('a group topic falls back to the global default last', () async {
      final resolved = resolveTitleModel(
        settings,
        conversation: groupConversation(),
      );

      expect(resolved.providerKey, 'GlobalProvider');
      expect(resolved.modelId, 'global-model');
    });

    test('the title model still outranks the director model', () async {
      await settings.setDirectorModel('DirectorProvider', 'director-model');
      await settings.setTitleModel('TitleProvider', 'title-model');

      final resolved = resolveTitleModel(
        settings,
        conversation: groupConversation(),
      );

      expect(resolved.providerKey, 'TitleProvider');
      expect(resolved.modelId, 'title-model');
    });

    test('a group topic ignores a pinned conversation model', () async {
      await settings.setPerChatModelEnabled(true);
      await settings.setDirectorModel('DirectorProvider', 'director-model');

      final resolved = resolveTitleModel(
        settings,
        conversation: groupConversation().copyWith(
          chatModelProvider: 'ConversationProvider',
          chatModelId: 'conversation-model',
        ),
      );

      expect(resolved.providerKey, 'DirectorProvider');
    });
  });
}
