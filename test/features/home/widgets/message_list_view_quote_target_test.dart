import "../../../support/business_test_harness.dart";
import 'package:Cuplivo/core/models/chat_message.dart';
import 'package:Cuplivo/core/models/message_quote.dart';
import 'package:Cuplivo/core/providers/assistant_provider.dart';
import 'package:Cuplivo/core/providers/settings_provider.dart';
import 'package:Cuplivo/core/providers/tts_provider.dart';
import 'package:Cuplivo/core/providers/user_provider.dart';
import 'package:Cuplivo/features/home/controllers/stream_controller.dart'
    as stream_ctrl;
import 'package:Cuplivo/features/home/services/ask_user_interaction_service.dart';
import 'package:Cuplivo/features/home/services/tool_approval_service.dart';
import 'package:Cuplivo/features/home/widgets/message_list_view.dart';
import 'package:Cuplivo/l10n/app_localizations.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:super_sliver_list/super_sliver_list.dart';

/// How a reply citation's chip resolves once the quoted message's group selects
/// another revision (docs/adr/0012).
///
/// The citation names the revision it was made against; a version switch moves
/// which revision the group shows, so that id is no longer a row on screen. The
/// chip must still show the message — by message **slot**, the revision the
/// group shows now — and still jump to it, instead of claiming the original
/// message is unavailable while the turn keeps citing and sending it.
void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  testWidgets('a citation of a switched-away revision resolves to its slot', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    try {
      const groupId = 'assistant-group';
      final citedRevision = ChatMessage(
        id: 'assistant-v0',
        role: 'assistant',
        // A version header carries the picker, never a body.
        content: '',
        conversationId: 'conversation-1',
        groupId: groupId,
      );
      final shownRevision = ChatMessage(
        id: 'assistant-v1',
        role: 'assistant',
        content: 'REGENERATED ANSWER',
        conversationId: 'conversation-1',
        groupId: groupId,
        version: 1,
      );
      final reply = ChatMessage(
        id: 'user-reply',
        role: 'user',
        content: 'about that?',
        conversationId: 'conversation-1',
        quote: const MessageQuote(id: 'assistant-v0'),
      );
      // What `ChatController.collapsedMessages` hands the timeline: one row per
      // group, the selected revision.
      final messages = <ChatMessage>[shownRevision, reply];
      // …and what `groupedMessages` hands it: the group's version headers, so the
      // cited id is still known.
      final byGroup = <String, List<ChatMessage>>{
        groupId: [citedRevision, shownRevision],
      };

      // The premise this test is about: the cited revision is not on screen.
      expect(messages.map((m) => m.id), isNot(contains('assistant-v0')));
      expect(byGroup[groupId]!.map((m) => m.id), contains('assistant-v0'));

      final jumpedTo = <String>[];
      await tester.pumpWidget(
        _MessageListHarness(
          messages: messages,
          byGroup: byGroup,
          onQuoteTap: jumpedTo.add,
        ),
      );
      await tester.pumpAndSettle();

      final chip = find.byKey(const ValueKey('user-message-quote:user-reply'));
      expect(chip, findsOneWidget);
      expect(
        find.descendant(of: chip, matching: find.text('REGENERATED ANSWER')),
        findsOneWidget,
      );
      // Not the stub: the message is right there, and it is tappable.
      expect(find.text('Original message unavailable'), findsNothing);

      await tester.tap(chip);
      await tester.pump();
      expect(jumpedTo, <String>['assistant-v1']);
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });

  testWidgets('a citation of a revision the group no longer holds is a stub', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    try {
      const groupId = 'assistant-group';
      final shownRevision = ChatMessage(
        id: 'assistant-v1',
        role: 'assistant',
        content: 'REGENERATED ANSWER',
        conversationId: 'conversation-1',
        groupId: groupId,
        version: 1,
      );
      final reply = ChatMessage(
        id: 'user-reply',
        role: 'user',
        content: 'about that?',
        conversationId: 'conversation-1',
        quote: const MessageQuote(id: 'assistant-deleted'),
      );
      // The slot has never held the cited id: the group's own revisions are the
      // only ones that answer for it.
      final byGroup = <String, List<ChatMessage>>{
        groupId: [shownRevision],
      };

      final jumpedTo = <String>[];
      await tester.pumpWidget(
        _MessageListHarness(
          messages: <ChatMessage>[shownRevision, reply],
          byGroup: byGroup,
          onQuoteTap: jumpedTo.add,
        ),
      );
      await tester.pumpAndSettle();

      final chip = find.byKey(const ValueKey('user-message-quote:user-reply'));
      expect(chip, findsOneWidget);
      expect(find.text('Original message unavailable'), findsOneWidget);

      await tester.tap(chip);
      await tester.pump();
      expect(jumpedTo, isEmpty);
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });
}

class _MessageListHarness extends StatefulWidget {
  const _MessageListHarness({
    required this.messages,
    required this.byGroup,
    required this.onQuoteTap,
  });

  final List<ChatMessage> messages;
  final Map<String, List<ChatMessage>> byGroup;
  final ValueChanged<String> onQuoteTap;

  @override
  State<_MessageListHarness> createState() => _MessageListHarnessState();
}

class _MessageListHarnessState extends State<_MessageListHarness> {
  late final ScrollController scrollController;
  late final ListController listController;
  late final ValueNotifier<String?> processingFilesMessageId;

  @override
  void initState() {
    super.initState();
    scrollController = ScrollController();
    listController = ListController();
    processingFilesMessageId = ValueNotifier<String?>(null);
  }

  @override
  void dispose() {
    scrollController.dispose();
    listController.dispose();
    processingFilesMessageId.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      providers: [
        ChangeNotifierProvider(
          create: (_) => SettingsProvider(createBusinessTestPreferences()),
        ),
        ChangeNotifierProvider(
          create: (_) =>
              AssistantProvider(preferences: createBusinessTestPreferences()),
        ),
        ChangeNotifierProvider(
          create: (_) =>
              UserProvider(preferences: createBusinessTestPreferences()),
        ),
        ChangeNotifierProvider(
          create: (_) =>
              TtsProvider(preferences: createBusinessTestPreferences()),
        ),
        ChangeNotifierProvider(create: (_) => AskUserInteractionService()),
        ChangeNotifierProvider(create: (_) => ToolApprovalService()),
      ],
      child: MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: MessageListView(
            scrollController: scrollController,
            listController: listController,
            messages: widget.messages,
            byGroup: widget.byGroup,
            versionSelections: const {},
            reasoning: const <String, stream_ctrl.ReasoningData>{},
            reasoningSegments:
                const <String, List<stream_ctrl.ReasoningSegmentData>>{},
            contentSplits: const <String, stream_ctrl.ContentSplitData>{},
            toolParts: const {},
            translations: const {},
            selecting: false,
            selectedItems: const {},
            dividerPadding: EdgeInsets.zero,
            processingFilesMessageId: processingFilesMessageId,
            onQuoteTap: widget.onQuoteTap,
          ),
        ),
      ),
    );
  }
}
