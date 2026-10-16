import "../../../support/business_test_harness.dart";

import 'package:Cuplivo/core/models/chat_message.dart';
import 'package:Cuplivo/core/providers/settings_provider.dart';
import 'package:Cuplivo/core/providers/tts_provider.dart';
import 'package:Cuplivo/features/chat/utils/selection_markdown_memory.dart';
import 'package:Cuplivo/features/chat/widgets/chat_message_widget.dart';
import 'package:Cuplivo/features/home/services/ask_user_interaction_service.dart';
import 'package:Cuplivo/features/home/services/tool_approval_service.dart';
import 'package:Cuplivo/l10n/app_localizations.dart';
import 'package:Cuplivo/shared/widgets/markdown_with_highlight.dart';
import 'package:Cuplivo/shared/widgets/sanitizing_selection_area.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

const String _content = '**bold** text';

/// The assistant bubble's selection surface, keyed `assistant_<id>` by
/// [ChatMessageWidget].
Finder _assistantArea() => find.byWidgetPredicate((widget) {
  if (widget is! SanitizingSelectionArea) return false;
  final key = widget.key;
  return key is ValueKey<String> && key.value.startsWith('assistant_');
});

ChatMessage _message(String id, String content, {bool streaming = false}) =>
    ChatMessage(
      role: 'assistant',
      content: content,
      conversationId: 'conversation-selection-markdown',
      id: id,
      isStreaming: streaming,
    );

Future<void> _pumpMessages(
  WidgetTester tester,
  List<ChatMessage> messages, {
  bool splitParagraphs = false,
}) async {
  final harness = await createBusinessTestHarness();
  addTearDown(harness.close);
  final settings = SettingsProvider(harness.preferences);
  await settings.loaded;
  if (splitParagraphs) {
    await settings.setAssistantBubbleSplitParagraphs(true);
  }
  await tester.pumpWidget(
    MultiProvider(
      providers: [
        ChangeNotifierProvider<SettingsProvider>.value(value: settings),
        ChangeNotifierProvider(
          create: (_) =>
              TtsProvider(preferences: createBusinessTestPreferences()),
        ),
        ChangeNotifierProvider<ToolApprovalService>.value(
          value: ToolApprovalService(),
        ),
        ChangeNotifierProvider<AskUserInteractionService>.value(
          value: AskUserInteractionService(),
        ),
      ],
      child: MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: ListView(
            children: [
              for (final message in messages)
                ChatMessageWidget(message: message, showModelIcon: false),
            ],
          ),
        ),
      ),
    ),
  );
  if (messages.any((message) => message.isStreaming)) {
    // A streaming bubble animates forever, so pumpAndSettle would time out.
    for (var i = 0; i < 3; i++) {
      await tester.pump(const Duration(milliseconds: 16));
    }
  } else {
    await tester.pumpAndSettle();
  }
}

Future<void> _pumpAssistant(
  WidgetTester tester, {
  bool streaming = false,
  String content = _content,
}) async {
  await _pumpMessages(tester, [
    _message('assistant-1', content, streaming: streaming),
  ]);
}

/// The selection region the assistant surface at [bubble] owns.
SelectableRegionState _regionOf(WidgetTester tester, int bubble) =>
    tester.state<SelectableRegionState>(
      find
          .descendant(
            of: _assistantArea().at(bubble),
            matching: find.byType(SelectableRegion),
          )
          .first,
    );

/// Selects everything the assistant surface at [bubble] owns.
Future<void> _selectAllIn(WidgetTester tester, int bubble) async {
  _regionOf(tester, bubble).selectAll(SelectionChangedCause.keyboard);
  await tester.pump();
}

/// The toolbar item of the assistant surface at [bubble] that [pick] selects.
Future<ContextMenuButtonItem> _menuItemOf(
  WidgetTester tester,
  int bubble,
  bool Function(ContextMenuButtonItem item) pick,
) async {
  final areaFinder = _assistantArea().at(bubble);
  final region = _regionOf(tester, bubble);
  final areaElement = tester.element(areaFinder);
  final area = tester.widget<SelectionArea>(
    find.descendant(of: areaFinder, matching: find.byType(SelectionArea)).first,
  );
  final menu =
      area.contextMenuBuilder!(areaElement, region)
          as AdaptiveTextSelectionToolbar;
  return menu.buttonItems!.firstWhere(pick);
}

/// Selects the whole assistant bubble and returns the toolbar item that
/// copies the selection as markdown.
Future<ContextMenuButtonItem> _markdownMenuItem(WidgetTester tester) async {
  final areaFinder = _assistantArea();
  final region = tester.state<SelectableRegionState>(
    find
        .descendant(of: areaFinder, matching: find.byType(SelectableRegion))
        .first,
  );
  region.selectAll(SelectionChangedCause.keyboard);
  await tester.pump();

  final areaElement = tester.element(areaFinder);
  final area = tester.widget<SelectionArea>(
    find.descendant(of: areaFinder, matching: find.byType(SelectionArea)).first,
  );
  final menu =
      area.contextMenuBuilder!(areaElement, region)
          as AdaptiveTextSelectionToolbar;
  final label = AppLocalizations.of(
    areaElement,
  )!.chatMessageWidgetCopyAsMarkdown;
  return menu.buttonItems!.firstWhere((item) => item.label == label);
}

class _ClipboardRecorder {
  String? text;

  void install(WidgetTester tester) {
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') {
        text = (call.arguments as Map<Object?, Object?>)['text'] as String?;
      }
      return null;
    });
    addTearDown(() {
      messenger.setMockMethodCallHandler(SystemChannels.platform, null);
    });
  }
}

void main() {
  testWidgets('the selection menu offers one short Markdown item', (
    tester,
  ) async {
    await _pumpAssistant(tester);
    final item = await _markdownMenuItem(tester);
    // Deliberately a single short label next to the platform Copy — the v3
    // pair of "Copy as Markdown"/"Copy as Plain Text" was too long to scan.
    expect(item.label, 'Markdown');
  });

  testWidgets('the Markdown item restores the underlying source syntax', (
    tester,
  ) async {
    final recorder = _ClipboardRecorder()..install(tester);
    await _pumpAssistant(tester);

    final item = await _markdownMenuItem(tester);
    item.onPressed!();
    await tester.pump();

    // The rendered selection is "bold text"; the markdown source keeps the
    // delimiters that produced the rendering, completed around the cut.
    expect(recorder.text, '**bold** text');
  });

  testWidgets('a streaming reply offers the Markdown item too', (tester) async {
    final recorder = _ClipboardRecorder()..install(tester);
    await _pumpAssistant(tester, streaming: true);

    final item = await _markdownMenuItem(tester);
    item.onPressed!();
    await tester.pump();

    expect(recorder.text, '**bold** text');
  });

  testWidgets('the Markdown item of a bubble copies that bubble', (
    tester,
  ) async {
    // Review of this PR: two replies with a live selection in each, then bubble
    // A's own toolbar. The item read one app-wide memory, so it wrote bubble B's
    // markdown. It maps its own surface's selection now.
    final recorder = _ClipboardRecorder()..install(tester);
    await _pumpMessages(tester, [
      _message('bubble-a', '**Alpha** text'),
      _message('bubble-b', '**Beta** text'),
    ]);
    await _selectAllIn(tester, 0);
    await _selectAllIn(tester, 1);

    final item = await _menuItemOf(
      tester,
      0,
      (item) => item.label == 'Markdown',
    );
    item.onPressed!();
    await tester.pump();

    expect(recorder.text, '**Alpha** text');
  });

  testWidgets('a split part copies its own selection', (tester) async {
    // Review of this PR: with split paragraphs each part is its own surface,
    // while the selection text lived in one field per message — so part 0's
    // Copy wrote part 1's text.
    final recorder = _ClipboardRecorder()..install(tester);
    await _pumpMessages(tester, [
      _message('split-1', 'First part text.\n\nSecond part text.'),
    ], splitParagraphs: true);
    expect(_assistantArea(), findsNWidgets(2));
    await _selectAllIn(tester, 0);
    await _selectAllIn(tester, 1);

    final copy = await _menuItemOf(
      tester,
      0,
      (item) => item.type == ContextMenuButtonType.copy,
    );
    copy.onPressed!();
    await tester.pumpAndSettle();

    expect(recorder.text, 'First part text.');
  });

  testWidgets('the Markdown item finishes the way the platform Copy does', (
    tester,
  ) async {
    // Desktop (like iOS) keeps a selection after Copy and only Android clears
    // it; the Markdown item used to clear it everywhere, which the review could
    // not tell from intent. It finishes through the same helper now, so the
    // selection is still there and pressing the item again still answers.
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    final recorder = _ClipboardRecorder()..install(tester);
    await _pumpAssistant(tester);
    final region = _regionOf(tester, 0);

    final item = await _markdownMenuItem(tester);
    item.onPressed!();
    await tester.pumpAndSettle();
    expect(recorder.text, '**bold** text');

    // The selection survived: the framework anchors a menu only while there is
    // one, so this is what "pressing the item again still answers" rests on.
    expect(() => region.contextMenuAnchors, returnsNormally);

    recorder.text = null;
    // No new selection: this menu is built for whatever survived.
    final again = await _menuItemOf(
      tester,
      0,
      (item) => item.label == 'Markdown',
    );
    again.onPressed!();
    await tester.pumpAndSettle();
    expect(recorder.text, '**bold** text');

    // Reset inside the body: the framework's invariant check runs before
    // tear-downs.
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('a bubble that goes away retires what it recorded', (
    tester,
  ) async {
    // The hotkey acts on the remembered selection, so a reply scrolled out of
    // the viewport (or a conversation switched away from) must not leave it
    // copyable: the memory is filed under the surface that recorded it.
    await _pumpAssistant(tester);
    await _selectAllIn(tester, 0);
    expect(SelectionMarkdownMemory.instance.markdownForSelection(), isNotNull);

    await tester.pumpWidget(const SizedBox.shrink());
    expect(SelectionMarkdownMemory.instance.markdownForSelection(), isNull);
  });

  testWidgets('the Markdown item keeps a table the selection spans', (
    tester,
  ) async {
    // The cells are paragraphs of the bubble's own selection owner, so the
    // selection reports their text. The Markdown mapping has to declare that
    // same display text — a table that contributed none left the mapping
    // unmatched, and the item silently handed back the plain selection.
    final recorder = _ClipboardRecorder()..install(tester);
    markdownTableTargetPlatformOverride = TargetPlatform.windows;
    addTearDown(() => markdownTableTargetPlatformOverride = null);
    await _pumpAssistant(
      tester,
      content:
          'before\n\n| head | second |\n| --- | --- |\n'
          '| alpha | bravo |\n\nafter',
    );

    final item = await _markdownMenuItem(tester);
    item.onPressed!();
    await tester.pump();

    expect(recorder.text, contains('before'));
    expect(recorder.text, contains('after'));
    expect(recorder.text, contains('| alpha | bravo |'));
  });

  testWidgets('the Markdown item keeps the fence of a code block', (
    tester,
  ) async {
    // The block's body is part of the display space a selection reports, so the
    // walk has to declare it — otherwise a selection over the block matched
    // nothing and the item handed back the plain selection.
    final recorder = _ClipboardRecorder()..install(tester);
    await _pumpAssistant(
      tester,
      content: 'before\n\n```dart\nvoid main() {}\n```\n\nafter',
    );

    final item = await _markdownMenuItem(tester);
    item.onPressed!();
    await tester.pump();

    expect(recorder.text, contains('```dart'));
    expect(recorder.text, contains('void main() {}'));
    expect(recorder.text, contains('after'));
  });
}
