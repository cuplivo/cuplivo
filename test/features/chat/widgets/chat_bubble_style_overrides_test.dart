import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:Cuplivo/core/database/business_preferences.dart';
import 'package:Cuplivo/core/models/chat_message.dart';
import 'package:Cuplivo/core/providers/settings_provider.dart';
import 'package:Cuplivo/core/providers/tts_provider.dart';
import 'package:Cuplivo/core/providers/user_provider.dart';
import 'package:Cuplivo/features/chat/widgets/chat_message_widget.dart';
import 'package:Cuplivo/features/home/services/ask_user_interaction_service.dart';
import 'package:Cuplivo/features/home/services/tool_approval_service.dart';
import 'package:Cuplivo/l10n/app_localizations.dart';
import 'package:Cuplivo/theme/chat_bubble_style.dart';

var businessPrefs = BusinessPreferences.memoryForTests();

SettingsProvider _createSettings(ChatMessageBackgroundStyle style) {
  final rawStyle = switch (style) {
    ChatMessageBackgroundStyle.frosted => 'frosted',
    ChatMessageBackgroundStyle.solid => 'solid',
    ChatMessageBackgroundStyle.defaultStyle => 'default',
  };
  SharedPreferences.setMockInitialValues({});
  businessPrefs = BusinessPreferences.memoryForTests({
    'display_chat_message_background_style_v1': rawStyle,
  });
  return SettingsProvider(preferences: businessPrefs);
}

Widget _buildHarness({
  required SettingsProvider settings,
  required Widget child,
}) {
  return MultiProvider(
    providers: [
      Provider<BusinessPreferences>.value(value: businessPrefs),
      ChangeNotifierProvider<SettingsProvider>.value(value: settings),
      ChangeNotifierProvider(
        create: (_) => TtsProvider(preferences: businessPrefs),
      ),
      ChangeNotifierProvider(create: (_) => ToolApprovalService()),
      ChangeNotifierProvider(create: (_) => AskUserInteractionService()),
    ],
    child: MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Scaffold(body: child),
    ),
  );
}

Finder _clipAncestorOf(String text) {
  return find.ancestor(of: find.text(text), matching: find.byType(ClipRRect));
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('frosted overrides apply radius, blur and text color', (
    tester,
  ) async {
    final settings = _createSettings(ChatMessageBackgroundStyle.frosted);
    await settings.setEnableAssistantMarkdown(false);
    await settings.setChatBubbleStyleOverrides(
      const ChatBubbleStyleOverrides(
        cornerRadius: 4,
        blurSigma: 3,
        textArgbLight: 0xFF224466,
      ),
    );

    await tester.pumpWidget(
      _buildHarness(
        settings: settings,
        child: ChatMessageWidget(
          message: ChatMessage(
            role: 'assistant',
            content: 'Plain override text',
            conversationId: 'conversation-overrides',
          ),
          showModelIcon: false,
        ),
      ),
    );
    await tester.pump();

    final clip = tester.widget<ClipRRect>(
      _clipAncestorOf('Plain override text'),
    );
    expect(clip.borderRadius, BorderRadius.circular(4));
    expect(
      find.ancestor(
        of: find.text('Plain override text'),
        matching: find.byType(BackdropFilter),
      ),
      findsOneWidget,
    );
    expect(
      tester.widget<Text>(find.text('Plain override text')).style?.color,
      const Color(0xFF224466),
    );
  });

  testWidgets('plain translation text uses the override color', (tester) async {
    final settings = _createSettings(ChatMessageBackgroundStyle.solid);
    await settings.setEnableAssistantMarkdown(false);
    await settings.setChatBubbleStyleOverrides(
      const ChatBubbleStyleOverrides(textArgbLight: 0xFF224466),
    );

    await tester.pumpWidget(
      _buildHarness(
        settings: settings,
        child: ChatMessageWidget(
          message: ChatMessage(
            role: 'assistant',
            content: 'Answer',
            translation: 'Translated answer',
            conversationId: 'conversation-translation-overrides',
          ),
          showModelIcon: false,
        ),
      ),
    );
    await tester.pump();

    expect(
      tester.widget<Text>(find.text('Translated answer')).style?.color,
      const Color(0xFF224466),
    );
  });

  testWidgets('markdown headings use the override text color', (tester) async {
    final settings = _createSettings(ChatMessageBackgroundStyle.solid);
    await settings.setChatBubbleStyleOverrides(
      const ChatBubbleStyleOverrides(textArgbLight: 0xFF224466),
    );

    await tester.pumpWidget(
      _buildHarness(
        settings: settings,
        child: ChatMessageWidget(
          message: ChatMessage(
            role: 'assistant',
            content: '# Custom heading\n\nBody copy.',
            conversationId: 'conversation-heading-overrides',
          ),
          showModelIcon: false,
        ),
      ),
    );
    await tester.pump();

    final heading = find
        .byType(RichText)
        .evaluate()
        .map((element) => element.renderObject)
        .whereType<RenderParagraph>()
        .firstWhere(
          (paragraph) =>
              paragraph.text.toPlainText().contains('Custom heading'),
        );
    expect(heading.text.style?.color, const Color(0xFF224466));
  });

  testWidgets(
    'user and assistant frosted overrides can differ in radius and text color',
    (tester) async {
      final settings = _createSettings(ChatMessageBackgroundStyle.frosted);
      await settings.setEnableAssistantMarkdown(false);
      await settings.setEnableUserMarkdown(false);
      await settings.setChatBubbleStyleOverridesForRole(
        isUser: false,
        value: const ChatBubbleStyleOverrides(
          cornerRadius: 4,
          textArgbLight: 0xFF224466,
        ),
      );
      await settings.setChatBubbleStyleOverridesForRole(
        isUser: true,
        value: const ChatBubbleStyleOverrides(
          cornerRadius: 20,
          textArgbLight: 0xFFAA2200,
        ),
      );

      const userId = 'user-role-overrides';
      await tester.pumpWidget(
        MultiProvider(
          providers: [
            Provider<BusinessPreferences>.value(value: businessPrefs),
            ChangeNotifierProvider<SettingsProvider>.value(value: settings),
            ChangeNotifierProvider(
              create: (_) => TtsProvider(preferences: businessPrefs),
            ),
            ChangeNotifierProvider(
              create: (_) => UserProvider(preferences: businessPrefs),
            ),
            ChangeNotifierProvider(create: (_) => ToolApprovalService()),
            ChangeNotifierProvider(create: (_) => AskUserInteractionService()),
          ],
          child: MaterialApp(
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: Scaffold(
              body: Column(
                children: [
                  ChatMessageWidget(
                    message: ChatMessage(
                      id: userId,
                      role: 'user',
                      content: 'User override text',
                      conversationId: 'conversation-role-overrides',
                    ),
                    showUserAvatar: false,
                    showModelIcon: false,
                  ),
                  ChatMessageWidget(
                    message: ChatMessage(
                      role: 'assistant',
                      content: 'Assistant override text',
                      conversationId: 'conversation-role-overrides',
                    ),
                    showModelIcon: false,
                  ),
                ],
              ),
            ),
          ),
        ),
      );
      await tester.pump();

      final userClip = tester.widget<ClipRRect>(
        find.descendant(
          of: find.byKey(ValueKey('user-message-text-bubble:$userId')),
          matching: find.byType(ClipRRect),
        ),
      );
      final assistantClip = tester.widget<ClipRRect>(
        _clipAncestorOf('Assistant override text').first,
      );

      expect(userClip.borderRadius, BorderRadius.circular(20));
      expect(assistantClip.borderRadius, BorderRadius.circular(4));
      expect(
        tester.widget<Text>(find.text('User override text')).style?.color,
        const Color(0xFFAA2200),
      );
      expect(
        tester.widget<Text>(find.text('Assistant override text')).style?.color,
        const Color(0xFF224466),
      );
    },
  );
}
