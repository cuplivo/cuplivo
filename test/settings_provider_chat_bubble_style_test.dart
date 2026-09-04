import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:Cuplivo/core/database/business_key_registry.dart';
import 'package:Cuplivo/core/database/business_preferences.dart';
import 'package:Cuplivo/core/providers/settings_provider.dart';
import 'package:Cuplivo/theme/chat_bubble_style.dart';

Future<SettingsProvider> _settings({
  Map<String, Object> initial = const {},
}) async {
  final prefs = BusinessPreferences.memoryForTests(initial);
  final settings = SettingsProvider(preferences: prefs);
  await settings.loaded;
  return settings;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  test('bubble style overrides default to empty', () async {
    final settings = await _settings();

    expect(settings.chatBubbleStyleOverrides, const ChatBubbleStyleOverrides());
    expect(settings.chatBubbleStyleOverrides.isDefault, isTrue);
    expect(
      settings.userChatBubbleStyleOverrides,
      settings.assistantChatBubbleStyleOverrides,
    );
    expect(
      settings.chatBubbleStyleOverridesFor(isUser: true),
      settings.chatBubbleStyleOverridesFor(isUser: false),
    );
    expect(settings.assistantBubbleSplitParagraphs, isFalse);
  });

  test('assistant paragraph splitting persists, reloads, and copies', () async {
    final prefs = BusinessPreferences.memoryForTests();
    final settings = SettingsProvider(preferences: prefs);
    await settings.loaded;

    await settings.setAssistantBubbleSplitParagraphs(true);

    expect(settings.assistantBubbleSplitParagraphs, isTrue);
    expect(
      prefs.getBool('display_assistant_bubble_split_paragraphs_v1'),
      isTrue,
    );
    expect(settings.copyWith().assistantBubbleSplitParagraphs, isTrue);

    final reloaded = SettingsProvider(preferences: prefs);
    await reloaded.loaded;
    expect(reloaded.assistantBubbleSplitParagraphs, isTrue);
  });

  test(
    'user-only overrides leave assistant unchanged and survive reload',
    () async {
      final prefs = BusinessPreferences.memoryForTests();
      final settings = SettingsProvider(preferences: prefs);
      await settings.loaded;

      const user = ChatBubbleStyleOverrides(
        textArgbLight: 0xFFAA2200,
        cornerRadius: 20,
      );
      await settings.setChatBubbleStyleOverridesForRole(
        isUser: true,
        value: user,
      );

      expect(
        settings.assistantChatBubbleStyleOverrides,
        const ChatBubbleStyleOverrides(),
      );
      expect(settings.userChatBubbleStyleOverrides, user);
      expect(settings.chatBubbleStyleOverridesFor(isUser: true), user);
      expect(
        settings.chatBubbleStyleOverridesFor(isUser: false),
        const ChatBubbleStyleOverrides(),
      );
      expect(
        prefs.getString('chat_bubble_style_overrides_user_v1'),
        jsonEncode(user.toJson()),
      );

      final reloaded = SettingsProvider(preferences: prefs);
      await reloaded.loaded;
      expect(
        reloaded.assistantChatBubbleStyleOverrides,
        const ChatBubbleStyleOverrides(),
      );
      expect(reloaded.userChatBubbleStyleOverrides, user);
    },
  );

  test(
    'first assistant role write snapshots the previous assistant value onto user',
    () async {
      final prefs = BusinessPreferences.memoryForTests();
      final settings = SettingsProvider(preferences: prefs);
      await settings.loaded;

      const shared = ChatBubbleStyleOverrides(
        backgroundArgbLight: 0xFF112233,
        cornerRadius: 8,
      );
      await settings.setChatBubbleStyleOverrides(shared);
      expect(settings.userChatBubbleStyleOverrides, shared);
      expect(prefs.getString('chat_bubble_style_overrides_user_v1'), isNull);

      const assistantNext = ChatBubbleStyleOverrides(cornerRadius: 2);
      await settings.setChatBubbleStyleOverridesForRole(
        isUser: false,
        value: assistantNext,
      );

      expect(settings.assistantChatBubbleStyleOverrides, assistantNext);
      expect(settings.userChatBubbleStyleOverrides, shared);
      expect(
        prefs.getString('chat_bubble_style_overrides_user_v1'),
        jsonEncode(shared.toJson()),
      );

      final reloaded = SettingsProvider(preferences: prefs);
      await reloaded.loaded;
      expect(reloaded.assistantChatBubbleStyleOverrides, assistantNext);
      expect(reloaded.userChatBubbleStyleOverrides, shared);
    },
  );

  test(
    'overlapping first assistant role writes persist the latest value',
    () async {
      final prefs = BusinessPreferences.memoryForTests();
      final settings = SettingsProvider(preferences: prefs);
      await settings.loaded;

      const shared = ChatBubbleStyleOverrides(
        backgroundArgbLight: 0xFF112233,
        cornerRadius: 8,
      );
      await settings.setChatBubbleStyleOverrides(shared);
      expect(prefs.getString('chat_bubble_style_overrides_user_v1'), isNull);

      const assistantA = ChatBubbleStyleOverrides(cornerRadius: 2);
      const assistantB = ChatBubbleStyleOverrides(cornerRadius: 4);
      final first = settings.setChatBubbleStyleOverridesForRole(
        isUser: false,
        value: assistantA,
      );
      final second = settings.setChatBubbleStyleOverridesForRole(
        isUser: false,
        value: assistantB,
      );
      await first;
      await second;

      expect(settings.assistantChatBubbleStyleOverrides, assistantB);
      expect(settings.userChatBubbleStyleOverrides, shared);
      expect(
        prefs.getString('chat_bubble_style_overrides_v1'),
        jsonEncode(assistantB.toJson()),
      );
      expect(
        prefs.getString('chat_bubble_style_overrides_user_v1'),
        jsonEncode(shared.toJson()),
      );

      final reloaded = SettingsProvider(preferences: prefs);
      await reloaded.loaded;
      expect(reloaded.assistantChatBubbleStyleOverrides, assistantB);
      expect(reloaded.userChatBubbleStyleOverrides, shared);
    },
  );

  test(
    'reset clears a user-only split even when assistant is already default',
    () async {
      final prefs = BusinessPreferences.memoryForTests();
      final settings = SettingsProvider(preferences: prefs);
      await settings.loaded;
      await settings.setChatBubbleStyleOverridesForRole(
        isUser: true,
        value: const ChatBubbleStyleOverrides(cornerRadius: 20),
      );

      await settings.setChatBubbleStyleOverrides(
        const ChatBubbleStyleOverrides(),
      );

      expect(settings.assistantChatBubbleStyleOverrides.isDefault, isTrue);
      expect(settings.userChatBubbleStyleOverrides.isDefault, isTrue);
      expect(prefs.getString('chat_bubble_style_overrides_user_v1'), isNull);
    },
  );

  test('persists and reloads bubble style overrides', () async {
    final prefs = BusinessPreferences.memoryForTests();
    final settings = SettingsProvider(preferences: prefs);
    await settings.loaded;

    const next = ChatBubbleStyleOverrides(
      backgroundArgbLight: 0xFF112233,
      frostedOpacity: 0.4,
      blurSigma: 22,
      cornerRadius: 8,
    );
    await settings.setChatBubbleStyleOverrides(next);

    expect(settings.chatBubbleStyleOverrides, next);
    expect(
      prefs.getString('chat_bubble_style_overrides_v1'),
      jsonEncode(next.toJson()),
    );

    final reloaded = SettingsProvider(preferences: prefs);
    await reloaded.loaded;
    expect(reloaded.chatBubbleStyleOverrides, next);
  });

  test('reset persists an empty override object', () async {
    final prefs = BusinessPreferences.memoryForTests();
    final settings = SettingsProvider(preferences: prefs);
    await settings.loaded;
    await settings.setChatBubbleStyleOverrides(
      const ChatBubbleStyleOverrides(blurSigma: 9),
    );
    await settings.setChatBubbleStyleOverrides(
      const ChatBubbleStyleOverrides(),
    );

    expect(settings.chatBubbleStyleOverrides.isDefault, isTrue);
    expect(prefs.getString('chat_bubble_style_overrides_v1'), '{}');
  });

  test('corrupt or out-of-range overrides JSON loads safely', () async {
    // 1e999 is valid JSON but parses to Infinity — non-finite entry vector
    // for imports/hand-edited backups.
    const raw =
        '{"cornerRadius":-9,"blurSigma":1e999,"frostedOpacity":4,'
        '"backgroundArgbLight":-1}';
    final prefs = BusinessPreferences.memoryForTests();
    await prefs.setString('chat_bubble_style_overrides_v1', raw);
    final settings = SettingsProvider(preferences: prefs);
    await settings.loaded;

    final loaded = settings.chatBubbleStyleOverrides;
    expect(loaded.cornerRadius, 0);
    expect(loaded.blurSigma, isNull);
    expect(loaded.frostedOpacity, 1.0);
    expect(loaded.backgroundArgbLight, isNull);
  });

  test('backup registry classifies the overrides keys as business', () {
    final dispositions = <String, BusinessKeyDisposition>{
      'chat_bubble_style_overrides_v1': BusinessKeyRegistry.classify(
        'chat_bubble_style_overrides_v1',
      ),
      'chat_bubble_style_overrides_user_v1': BusinessKeyRegistry.classify(
        'chat_bubble_style_overrides_user_v1',
      ),
      'display_assistant_bubble_fit_content_v1': BusinessKeyRegistry.classify(
        'display_assistant_bubble_fit_content_v1',
      ),
      'display_assistant_bubble_split_paragraphs_v1':
          BusinessKeyRegistry.classify(
            'display_assistant_bubble_split_paragraphs_v1',
          ),
    };
    for (final entry in dispositions.entries) {
      expect(
        entry.value,
        BusinessKeyDisposition.unknownPreference,
        reason:
            '${entry.key} must stay business (migrated and backed up), not '
            'localOnly/discarded/entity',
      );
    }
  });
}
