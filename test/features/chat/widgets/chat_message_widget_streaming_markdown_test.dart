import 'package:Cuplivo/core/models/chat_message.dart';
import 'package:Cuplivo/core/providers/settings_provider.dart';
import 'package:Cuplivo/core/providers/tts_provider.dart';
import 'package:Cuplivo/features/chat/widgets/chat_message_widget.dart';
import 'package:Cuplivo/features/home/services/ask_user_interaction_service.dart';
import 'package:Cuplivo/features/home/services/tool_approval_service.dart';
import 'package:Cuplivo/l10n/app_localizations.dart';
import 'package:Cuplivo/shared/widgets/markdown_with_highlight.dart';
import 'package:Cuplivo/shared/widgets/mermaid_image_cache.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

Widget _buildHarness({
  required Widget child,
  Map<String, Object> initialPrefs = const {},
}) {
  SharedPreferences.setMockInitialValues(initialPrefs);
  return MultiProvider(
    providers: [
      ChangeNotifierProvider(create: (_) => SettingsProvider()),
      ChangeNotifierProvider(create: (_) => TtsProvider()),
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

String _allRichTextPlainText(WidgetTester tester) {
  return tester
      .widgetList<RichText>(find.byType(RichText))
      .map((widget) => widget.text.toPlainText())
      .join('\n');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'ChatMessageWidget keeps a partial streaming table row in table layout',
    (tester) async {
      await tester.pumpWidget(
        _buildHarness(
          child: ChatMessageWidget(
            message: ChatMessage(
              id: 'streaming-table',
              role: 'assistant',
              content: '''
| 水果 | 颜色 | 价格 |
| - | - | - |
| 葡萄 🍇''',
              conversationId: 'conversation-1',
              isStreaming: true,
            ),
            showModelIcon: false,
          ),
        ),
      );
      await tester.pump();

      expect(find.byType(Table), findsOneWidget);
      expect(find.textContaining('葡萄 🍇'), findsOneWidget);
      expect(_allRichTextPlainText(tester), isNot(contains('| 葡萄 🍇')));
    },
  );

  testWidgets(
    'ChatMessageWidget keeps unfinished streaming Mermaid in the Mermaid block',
    (tester) async {
      addTearDown(MermaidImageCache.clear);
      MermaidImageCache.clear();

      await tester.pumpWidget(
        _buildHarness(
          child: ChatMessageWidget(
            message: ChatMessage(
              id: 'streaming-mermaid',
              role: 'assistant',
              content: '''
```mermaid
graph TD
A-->B''',
              conversationId: 'conversation-1',
              isStreaming: true,
            ),
            showModelIcon: false,
          ),
        ),
      );
      await tester.pump();

      expect(find.text('Image'), findsOneWidget);
      expect(find.text('Code'), findsOneWidget);
      expect(find.text('Generating image'), findsOneWidget);
      expect(_allRichTextPlainText(tester), isNot(contains('graph TD')));
    },
  );

  testWidgets('streaming thinking preview is truncated to the tail by default '
      '(issue #232)', (tester) async {
    const tailMarker = 'TAIL-MARKER-9876';
    final longThinking = '${'x' * 5000}$tailMarker';
    await tester.pumpWidget(
      _buildHarness(
        child: ChatMessageWidget(
          message: ChatMessage(
            id: 'streaming-thinking',
            role: 'assistant',
            content: '',
            conversationId: 'conversation-1',
            isStreaming: true,
          ),
          reasoningText: longThinking,
          reasoningExpanded: false,
          reasoningFinishedAt: null,
          showModelIcon: false,
        ),
      ),
    );
    await tester.pump();

    final previewMd = tester
        .widgetList<MarkdownWithCodeHighlight>(
          find.byType(MarkdownWithCodeHighlight),
        )
        .where((md) => md.text.length > 1)
        .single;
    expect(previewMd.text.length, lessThanOrEqualTo(2002));
    expect(previewMd.text, startsWith('…'));
    expect(previewMd.text, contains(tailMarker));
  });

  testWidgets(
    'streaming thinking preview renders full text when the truncation '
    'setting is off',
    (tester) async {
      final longThinking = '${'x' * 5000}TAIL-MARKER-9876';
      await tester.pumpWidget(
        _buildHarness(
          initialPrefs: {
            'display_streaming_thinking_preview_truncate_v1': false,
          },
          child: ChatMessageWidget(
            message: ChatMessage(
              id: 'streaming-thinking-full',
              role: 'assistant',
              content: '',
              conversationId: 'conversation-1',
              isStreaming: true,
            ),
            reasoningText: longThinking,
            reasoningExpanded: false,
            reasoningFinishedAt: null,
            showModelIcon: false,
          ),
        ),
      );
      await tester.pump();
      await tester.pump();
      await tester.pump();

      final previewMd = tester
          .widgetList<MarkdownWithCodeHighlight>(
            find.byType(MarkdownWithCodeHighlight),
          )
          .where((md) => md.text.length > 1)
          .single;
      expect(previewMd.text, longThinking);
    },
  );
}
