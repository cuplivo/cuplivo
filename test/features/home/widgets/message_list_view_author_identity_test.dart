// A group reply is shown as *its own* author. The two per-assistant switches
// that decide whether that means a name and a face ("use assistant
// name/avatar") were read from the selected 1:1 assistant instead, so a member
// who opted in was rendered as a bare model icon and a member who never opted
// in was labelled with a name — and the panel disagreed with an export of the
// same conversation, which resolves the author first.

import '../../../support/business_test_harness.dart';
import 'package:Cuplivo/core/models/assistant.dart';
import 'package:Cuplivo/core/models/chat_message.dart';
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
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:super_sliver_list/super_sliver_list.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  /// Two members: one who asked to be shown by name and face, one who did not.
  Future<({AssistantProvider provider, Assistant optedIn, Assistant optedOut})>
  roster() async {
    final provider = AssistantProvider(
      preferences: createBusinessTestPreferences(),
    );
    await provider.loaded;
    final namedId = await provider.addAssistant(name: 'Aria');
    final quietId = await provider.addAssistant(name: 'Quinn');
    final named = provider.getById(namedId)!;
    await provider.updateAssistant(
      named.copyWith(useAssistantName: true, useAssistantAvatar: true),
    );
    return (
      provider: provider,
      optedIn: provider.getById(namedId)!,
      optedOut: provider.getById(quietId)!,
    );
  }

  Future<void> pumpReply(
    WidgetTester tester, {
    required AssistantProvider assistants,
    required Assistant selected,
    required Assistant author,
  }) async {
    final message = ChatMessage(
      id: 'reply-1',
      conversationId: 'group-topic',
      role: 'assistant',
      content: 'A letter from one member of the group.',
      senderId: author.id,
      modelId: 'glm-5.3-flash',
    );
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider(
            create: (_) => SettingsProvider(createBusinessTestPreferences()),
          ),
          ChangeNotifierProvider<AssistantProvider>.value(value: assistants),
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
          locale: const Locale('en'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(
            body: _ListHarness(
              messages: [message],
              byGroup: {
                'reply-1': [message],
              },
              assistant: selected,
              assistants: assistants,
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('a member who opted in is shown by name, whatever is selected', (
    tester,
  ) async {
    final members = await roster();
    await pumpReply(
      tester,
      assistants: members.provider,
      // The 1:1 assistant the user happens to be on never opted in.
      selected: members.optedOut,
      author: members.optedIn,
    );

    expect(find.text('Aria'), findsOneWidget);
    // The roster reached the list, so the author resolves and is not read as a
    // deleted assistant — the label #1052 shipped for every group reply.
    final l10n = AppLocalizations.of(tester.element(find.byType(Scaffold)))!;
    expect(find.text(l10n.groupChatRemovedMember), findsNothing);
  });

  testWidgets('an author outside the roster keeps the deleted label', (
    tester,
  ) async {
    final members = await roster();
    await pumpReply(
      tester,
      assistants: members.provider,
      selected: members.optedIn,
      // Never added to the provider: exactly what a deleted member looks like.
      author: const Assistant(id: 'gone', name: 'Gone'),
    );

    final l10n = AppLocalizations.of(tester.element(find.byType(Scaffold)))!;
    expect(find.text(l10n.groupChatRemovedMember), findsOneWidget);
    expect(find.text('Gone'), findsNothing);
  });

  testWidgets('a member who never opted in is not given a name', (
    tester,
  ) async {
    final members = await roster();
    await pumpReply(
      tester,
      assistants: members.provider,
      // The selected assistant did opt in; that says nothing about this reply.
      selected: members.optedIn,
      author: members.optedOut,
    );

    expect(find.text('Quinn'), findsNothing);
  });
}

class _ListHarness extends StatefulWidget {
  const _ListHarness({
    required this.messages,
    required this.byGroup,
    required this.assistant,
    required this.assistants,
  });

  final List<ChatMessage> messages;
  final Map<String, List<ChatMessage>> byGroup;
  final Assistant assistant;
  final AssistantProvider assistants;

  @override
  State<_ListHarness> createState() => _ListHarnessState();
}

class _ListHarnessState extends State<_ListHarness> {
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
    return MessageListView(
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
      assistant: widget.assistant,
      assistants: widget.assistants,
    );
  }
}
