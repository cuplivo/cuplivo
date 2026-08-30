import 'package:Cuplivo/core/models/assistant.dart';
import 'package:Cuplivo/core/models/conversation.dart';
import 'package:Cuplivo/core/providers/settings_provider.dart';
import 'package:Cuplivo/features/home/utils/conversation_model_binding.dart';
import 'package:Cuplivo/features/home/utils/model_display_helper.dart';
import 'package:Cuplivo/core/database/business_preferences.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('resolveConversationModelWriteTarget (ADR-0045)', () {
    test('bound conversation writes its own binding even with toggle off', () {
      final convo = Conversation(
        title: 'C',
        chatModelProvider: 'OpenAI',
        chatModelId: 'gpt-4o',
      );
      expect(
        resolveConversationModelWriteTarget(
          conversationModelIndependent: false,
          conversation: convo,
        ),
        ConversationModelWriteTarget.conversationBinding,
      );
    });

    test('unbound conversation with toggle on writes its own binding', () {
      final convo = Conversation(title: 'C');
      expect(
        resolveConversationModelWriteTarget(
          conversationModelIndependent: true,
          conversation: convo,
        ),
        ConversationModelWriteTarget.conversationBinding,
      );
    });

    test(
      'unbound conversation with toggle off keeps writing the assistant',
      () {
        final convo = Conversation(title: 'C');
        expect(
          resolveConversationModelWriteTarget(
            conversationModelIndependent: false,
            conversation: convo,
          ),
          ConversationModelWriteTarget.assistant,
        );
      },
    );

    test('no conversation never targets the binding', () {
      expect(
        resolveConversationModelWriteTarget(
          conversationModelIndependent: true,
          conversation: null,
        ),
        ConversationModelWriteTarget.assistant,
      );
    });

    test(
      'conversationModelBindingActive is false for unbound, true for bound',
      () {
        expect(
          conversationModelBindingActive(Conversation(title: 'C')),
          isFalse,
        );
        expect(
          conversationModelBindingActive(
            Conversation(title: 'C', chatModelId: 'm1'),
          ),
          isTrue,
        );
        expect(conversationModelBindingActive(null), isFalse);
      },
    );
  });

  group('resolveChatModel chain (conversation → assistant → global)', () {
    var businessPrefs = BusinessPreferences.memoryForTests(const {
      'selected_model_v1': 'DeepSeek::deepseek-v4-flash',
    });

    test('conversation binding wins over assistant and global', () async {
      final settings = SettingsProvider(preferences: businessPrefs);
      await _waitUntil(() => settings.currentModelId != null);
      final assistant = Assistant(
        id: 'a1',
        name: 'Alpha',
        chatModelProvider: 'Claude',
        chatModelId: 'claude-4',
      );
      final convo = Conversation(
        title: 'C',
        chatModelProvider: 'Gemini',
        chatModelId: 'gemini-3',
      );
      final r = resolveChatModel(settings, assistant, convo);
      expect(r.providerKey, 'Gemini');
      expect(r.modelId, 'gemini-3');
    });

    test('unbound conversation follows the assistant binding', () async {
      final settings = SettingsProvider(preferences: businessPrefs);
      await _waitUntil(() => settings.currentModelId != null);
      final assistant = Assistant(
        id: 'a1',
        name: 'Alpha',
        chatModelProvider: 'Claude',
        chatModelId: 'claude-4',
      );
      final r = resolveChatModel(settings, assistant, Conversation(title: 'C'));
      expect(r.providerKey, 'Claude');
      expect(r.modelId, 'claude-4');
    });

    test('no assistant falls back to the global default', () async {
      final settings = SettingsProvider(preferences: businessPrefs);
      await _waitUntil(() => settings.currentModelId != null);
      final r = resolveChatModel(settings, null, Conversation(title: 'C'));
      expect(r.providerKey, 'DeepSeek');
      expect(r.modelId, 'deepseek-v4-flash');
    });

    test(
      'uses the seeded default when never persisted (one-time seed)',
      () async {
        final nonePrefs = BusinessPreferences.memoryForTests(const {});
        final settings = SettingsProvider(preferences: nonePrefs);
        await _waitUntil(() => settings.currentModelId != null);
        final r = resolveChatModel(settings, null, Conversation(title: 'C'));
        expect(r.providerKey, 'DeepSeek');
        expect(r.modelId, 'deepseek-v4-flash');
      },
    );
  });

  group('Conversation JSON round-trip', () {
    test('keeps the binding and tolerates its absence (old backups)', () {
      final convo = Conversation(
        title: 'C',
        chatModelProvider: 'OpenAI',
        chatModelId: 'gpt-4o',
      );
      final revived = Conversation.fromJson(convo.toJson());
      expect(revived.chatModelProvider, 'OpenAI');
      expect(revived.chatModelId, 'gpt-4o');

      final legacy = Conversation.fromJson({
        'id': 'x',
        'title': 'X',
        'createdAt': DateTime(2026, 1, 1).toIso8601String(),
        'updatedAt': DateTime(2026, 1, 1).toIso8601String(),
      });
      expect(legacy.chatModelProvider, isNull);
      expect(legacy.chatModelId, isNull);
    });
  });
}

Future<void> _waitUntil(bool Function() predicate) async {
  for (var i = 0; i < 200; i++) {
    if (predicate()) return;
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  fail('timed out waiting for condition');
}
