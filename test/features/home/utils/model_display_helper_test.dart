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
