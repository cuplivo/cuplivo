import "../../../support/business_test_harness.dart";
import 'package:Cuplivo/core/models/chat_message.dart';
import 'package:Cuplivo/core/providers/settings_provider.dart';
import 'package:Cuplivo/core/providers/tts_provider.dart';
import 'package:Cuplivo/features/chat/widgets/chat_message_widget.dart';
import 'package:Cuplivo/features/home/services/ask_user_interaction_service.dart';
import 'package:Cuplivo/features/home/services/tool_approval_service.dart';
import 'package:Cuplivo/l10n/app_localizations.dart';
import 'package:Cuplivo/shared/widgets/mermaid_image_cache.dart';
import 'package:Cuplivo/shared/widgets/markdown_with_highlight.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

Widget _buildHarness({required Widget child}) {
  SharedPreferences.setMockInitialValues(const {});
  return MultiProvider(
    providers: [
      ChangeNotifierProvider(
        create: (_) => SettingsProvider(createBusinessTestPreferences()),
      ),
      ChangeNotifierProvider(
        create: (_) =>
            TtsProvider(preferences: createBusinessTestPreferences()),
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

String _allRichTextPlainText(WidgetTester tester) {
  return tester
      .widgetList<RichText>(find.byType(RichText))
      .map((widget) => widget.text.toPlainText())
      .join('\n');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('reasoning overflow retains the Markdown renderer', (
    tester,
  ) async {
    await tester.pumpWidget(
      _buildHarness(
        child: SizedBox(
          width: 360,
          child: ChatMessageWidget(
            message: ChatMessage(
              id: 'reasoning-overflow',
              role: 'assistant',
              content: '',
              conversationId: 'conversation-1',
              isStreaming: true,
            ),
            reasoningText: List.generate(
              80,
              (i) => 'Paragraph $i **bold** 中文。',
            ).join('\n\n'),
            reasoningLoading: true,
            showModelIcon: false,
          ),
        ),
      ),
    );
    final markdown = find.byType(MarkdownWithCodeHighlight);
    expect(markdown, findsOneWidget);
    final first = tester.state(markdown);
    final position = tester
        .state<ScrollableState>(find.byType(Scrollable))
        .position;
    // The first layout detects overflow and enables its edge fade next frame.
    await tester.pump();
    expect(tester.state(markdown), same(first));
    expect(
      tester.state<ScrollableState>(find.byType(Scrollable)).position,
      same(position),
    );
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('ChatMessageWidget preserves table scroll when streaming ends', (
    tester,
  ) async {
    markdownTableTargetPlatformOverride = TargetPlatform.iOS;
    addTearDown(() => markdownTableTargetPlatformOverride = null);
    final streaming = ValueNotifier(true);
    addTearDown(streaming.dispose);
    await tester.pumpWidget(
      _buildHarness(
        child: Align(
          alignment: Alignment.topLeft,
          child: SizedBox(
            width: 360,
            child: ValueListenableBuilder<bool>(
              valueListenable: streaming,
              builder: (context, value, _) => ChatMessageWidget(
                message: ChatMessage(
                  id: 'table-scroll',
                  role: 'assistant',
                  content:
                      '| A | B | C | D | E |\n'
                      '| --- | --- | --- | --- | --- |\n'
                      '| apple | banana | cherry | date | elderberry |',
                  conversationId: 'conversation-1',
                  isStreaming: value,
                ),
                enableStreamingTextMotion: true,
                showModelIcon: false,
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    final viewport = find.byKey(
      const ValueKey('markdown-table-horizontal-scroll'),
    );
    final scroll = find.descendant(
      of: viewport,
      matching: find.byType(Scrollable),
    );
    final state = tester.state<ScrollableState>(scroll);
    await tester.drag(viewport, const Offset(-100, 0));
    await tester.pump(const Duration(milliseconds: 300));
    final offset = state.position.pixels;
    expect(offset, greaterThan(50));

    final gesture = await tester.startGesture(tester.getCenter(viewport));
    await gesture.moveBy(const Offset(-40, 0));
    await tester.pump();
    final beforeComplete = state.position.pixels;
    streaming.value = false;
    await tester.pumpAndSettle();
    expect(tester.state<ScrollableState>(scroll), same(state));
    expect(state.position.pixels, beforeComplete);
    await gesture.moveBy(const Offset(-40, 0));
    await tester.pump();
    expect(state.position.pixels, greaterThan(beforeComplete));
    await gesture.up();
    await tester.pumpAndSettle();
  });

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

  testWidgets('streaming status keeps its State when the first text arrives', (
    tester,
  ) async {
    final content = ValueNotifier('');
    addTearDown(content.dispose);
    const messageId = 'streaming-shell';

    await tester.pumpWidget(
      _buildHarness(
        child: SizedBox(
          width: 360,
          child: ValueListenableBuilder<String>(
            valueListenable: content,
            builder: (context, value, _) => ChatMessageWidget(
              message: ChatMessage(
                id: messageId,
                role: 'assistant',
                content: value,
                conversationId: 'conversation-1',
                isStreaming: true,
              ),
              showModelIcon: false,
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    final status = find.byKey(
      const ValueKey('assistant-streaming-status:streaming-shell'),
    );
    final indicator = find.descendant(
      of: status,
      matching: find.byType(LoadingIndicator),
    );
    expect(indicator, findsOneWidget);
    final initialIndicatorState = tester.state(indicator);

    content.value = 'First visible token';
    await tester.pump();

    expect(_allRichTextPlainText(tester), contains('First visible token'));
    expect(tester.state(indicator), same(initialIndicatorState));
  });

  testWidgets(
    'completion actions keep their AnimatedSwitcher State after streaming',
    (tester) async {
      final streaming = ValueNotifier(true);
      addTearDown(streaming.dispose);
      const switcher = ValueKey('assistant-actions-switcher');

      await tester.pumpWidget(
        _buildHarness(
          child: SizedBox(
            width: 360,
            child: ValueListenableBuilder<bool>(
              valueListenable: streaming,
              builder: (context, value, _) => ChatMessageWidget(
                message: ChatMessage(
                  id: 'completion-actions',
                  role: 'assistant',
                  content: 'Reply',
                  conversationId: 'conversation-1',
                  isStreaming: value,
                ),
                showModelIcon: false,
              ),
            ),
          ),
        ),
      );
      await tester.pump();

      final finder = find.byKey(switcher);
      expect(finder, findsOneWidget);
      final initialSwitcherState = tester.state(finder);

      streaming.value = false;
      await tester.pump();

      expect(tester.state(finder), same(initialSwitcherState));
      expect(find.byKey(const ValueKey('assistant-actions')), findsOneWidget);
    },
  );
}
