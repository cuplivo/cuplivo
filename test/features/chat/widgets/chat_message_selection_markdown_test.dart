import "../../../support/business_test_harness.dart";

import 'package:Cuplivo/core/models/chat_message.dart';
import 'package:Cuplivo/core/providers/settings_provider.dart';
import 'package:Cuplivo/core/providers/tts_provider.dart';
import 'package:Cuplivo/features/chat/widgets/chat_message_widget.dart';
import 'package:Cuplivo/features/home/services/ask_user_interaction_service.dart';
import 'package:Cuplivo/features/home/services/tool_approval_service.dart';
import 'package:Cuplivo/l10n/app_localizations.dart';
import 'package:Cuplivo/shared/widgets/sanitizing_selection_area.dart';
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

Future<void> _pumpAssistant(
  WidgetTester tester, {
  bool streaming = false,
}) async {
  final harness = await createBusinessTestHarness();
  addTearDown(harness.close);
  final settings = SettingsProvider(harness.preferences);
  await settings.loaded;
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
          body: ChatMessageWidget(
            message: ChatMessage(
              role: 'assistant',
              content: _content,
              conversationId: 'conversation-selection-markdown',
              isStreaming: streaming,
            ),
            showModelIcon: false,
          ),
        ),
      ),
    ),
  );
  if (streaming) {
    // A streaming bubble animates forever, so pumpAndSettle would time out.
    for (var i = 0; i < 3; i++) {
      await tester.pump(const Duration(milliseconds: 16));
    }
  } else {
    await tester.pumpAndSettle();
  }
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
}
