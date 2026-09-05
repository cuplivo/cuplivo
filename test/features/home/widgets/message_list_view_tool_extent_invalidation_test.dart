import 'package:Cuplivo/core/database/business_preferences.dart';
import 'package:Cuplivo/core/models/chat_message.dart';
import 'package:Cuplivo/core/providers/assistant_provider.dart';
import 'package:Cuplivo/core/providers/settings_provider.dart';
import 'package:Cuplivo/core/providers/tts_provider.dart';
import 'package:Cuplivo/core/providers/user_provider.dart';
import 'package:Cuplivo/core/services/streaming_content_notifier.dart';
import 'package:Cuplivo/features/chat/models/tool_ui_part.dart';
import 'package:Cuplivo/features/home/controllers/stream_controller.dart'
    as stream_ctrl;
import 'package:Cuplivo/features/home/services/ask_user_interaction_service.dart';
import 'package:Cuplivo/features/home/services/tool_approval_service.dart';
import 'package:Cuplivo/features/home/widgets/message_list_view.dart';
import 'package:Cuplivo/l10n/app_localizations.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:super_sliver_list/super_sliver_list.dart';

var businessPrefs = BusinessPreferences.memoryForTests();

void main() {
  setUp(() {
    businessPrefs = BusinessPreferences.memoryForTests();
    businessPrefs = BusinessPreferences.memoryForTests({});
  });

  test('tool height events coalesce by messageId and bump version', () async {
    final notifier = StreamingContentNotifier();
    addTearDown(notifier.dispose);

    final seen = <ToolHeightEvent>[];
    notifier.toolHeightEvents.addListener(() {
      final event = notifier.toolHeightEvents.value;
      if (event != null) seen.add(event);
    });

    notifier.notifyToolHeightChanged('m1');
    notifier.notifyToolHeightChanged('m1');
    notifier.notifyToolHeightChanged('m2');
    await Future<void>.delayed(Duration.zero);

    expect(seen, hasLength(2));
    expect(seen.map((e) => e.messageId), ['m1', 'm2']);
    expect(seen[1].version, greaterThan(seen[0].version));
  });

  test('height events stop silently after dispose', () async {
    final notifier = StreamingContentNotifier();
    var events = 0;
    notifier.toolHeightEvents.addListener(() => events++);

    notifier.notifyToolHeightChanged('m0');
    await Future<void>.delayed(Duration.zero);
    expect(events, 1);

    notifier.dispose();
    notifier.notifyToolHeightChanged('m1');
    notifier.notifyToolPartsUpdated('m1');
    await Future<void>.delayed(Duration.zero);

    expect(events, 1);
  });

  test(
    'structure split growth emits a height event, stable text does not',
    () async {
      final notifier = StreamingContentNotifier();
      addTearDown(notifier.dispose);
      notifier.getNotifier('m1');

      final seen = <String>[];
      notifier.toolHeightEvents.addListener(() {
        final event = notifier.toolHeightEvents.value;
        if (event != null) seen.add(event.messageId);
      });

      // Pure text growth: no new block starts.
      notifier.updateContent('m1', 'some content', 10);
      await Future<void>.delayed(Duration.zero);
      expect(seen, isEmpty);

      // A new thinking block start changes the structure.
      notifier.updateContent(
        'm1',
        'some content<thinking>x</thinking>',
        12,
        contentSplitOffsets: const <int>[18],
      );
      await Future<void>.delayed(Duration.zero);
      expect(seen, ['m1']);
    },
  );

  testWidgets('streaming tool event invalidates the cached extent', (
    tester,
  ) async {
    final notifier = StreamingContentNotifier();
    addTearDown(notifier.dispose);
    notifier.getNotifier('stream-1');

    final message = ChatMessage(
      id: 'stream-1',
      role: 'assistant',
      content: '',
      conversationId: 'conversation-1',
      isStreaming: true,
    );
    final toolParts = <String, List<ToolUIPart>>{
      'stream-1': const <ToolUIPart>[],
    };

    await tester.pumpWidget(
      _Harness(notifier: notifier, messages: [message], toolParts: toolParts),
    );
    await tester.pump();

    // _estimateChrome: a tools-only turn must not collapse to the chrome
    // floor — the timeline has to budget for the cards that will stack here.
    final list = tester.widget<SuperListView>(find.byType(SuperListView));
    expect(list.extentEstimation!(0, 400), 96);

    // The map is replaced in place, exactly like the streaming path does;
    // MessageListView never sees didUpdateWidget, so the height event is the
    // only signal that the height of this slot changed.
    toolParts['stream-1'] = [
      for (var i = 0; i < 8; i++)
        ToolUIPart(
          id: 't$i',
          toolName: 'read_file',
          arguments: {'path': '$i.dart'},
          content: 'ok',
        ),
    ];
    notifier.notifyToolPartsUpdated('stream-1');
    await tester.pump();

    final after = tester
        .widget<SuperListView>(find.byType(SuperListView))
        .extentEstimation!(0, 400);
    expect(after, closeTo(96 + 8 * 44.0, 0.1));
    expect(after, isNot(96));
  });

  testWidgets(
    'streaming height change invalidates an already measured extent',
    (tester) async {
      final notifier = StreamingContentNotifier();
      addTearDown(notifier.dispose);
      notifier.getNotifier('tool-1');

      final key = GlobalKey<_HarnessState>();
      final messages = <ChatMessage>[
        ChatMessage(
          id: 'tool-1',
          role: 'assistant',
          content: '',
          conversationId: 'conversation-1',
          isStreaming: true,
        ),
        ChatMessage(
          id: 'text-1',
          role: 'assistant',
          content: 'A' * 1800,
          conversationId: 'conversation-1',
        ),
        ChatMessage(
          id: 'text-2',
          role: 'assistant',
          content: 'B' * 1800,
          conversationId: 'conversation-1',
        ),
        ChatMessage(
          id: 'text-3',
          role: 'assistant',
          content: 'C' * 1800,
          conversationId: 'conversation-1',
        ),
      ];
      final toolParts = <String, List<ToolUIPart>>{
        'tool-1': const [
          ToolUIPart(
            id: 'ask',
            toolName: 'ask_user_input_v0',
            arguments: {},
            loading: true,
          ),
        ],
      };

      await tester.pumpWidget(
        _Harness(
          key: key,
          notifier: notifier,
          messages: messages,
          toolParts: toolParts,
        ),
      );
      await tester.pump();

      // Row 0 is laid out at the top: the controller holds its measured extent.
      final listController = tester
          .widget<SuperListView>(find.byType(SuperListView))
          .listController!;
      expect(listController.extentForIndex(0).$2, isFalse);

      // Scroll the tail into view: row 0 leaves the cache area and is no longer
      // built, but its measured extent stays stored in the controller.
      key.currentState!.jumpToBottom();
      await tester.pump();
      final visible = listController.visibleRange;
      expect(visible, isNotNull);
      expect(visible!.$1, greaterThanOrEqualTo(1));
      expect(listController.extentForIndex(0).$2, isFalse);

      // Streaming answer arrives: the visible tool count stays 1, only the
      // rendered height of the card changes. No rebuild reaches row 0, so the
      // height event is the only signal that its stored extent is stale.
      toolParts['tool-1'] = [
        ToolUIPart(
          id: 'ask',
          toolName: 'ask_user_input_v0',
          arguments: const {},
          content: '{"answers":{}}',
        ),
      ];
      notifier.notifyToolPartsUpdated('tool-1');
      await tester.pump();
      await tester.pump();

      // The stale measured extent must have been replaced by a fresh estimate.
      // Without the event subscription and the invalidateExtent call this
      // assertion stays false — the stored extent survives untouched.
      final updated = listController.extentForIndex(0);
      expect(
        updated.$2,
        isTrue,
        reason: 'stale measured extent was not dropped',
      );

      // Functional consequence: bottom rendering still lands on the tail.
      key.currentState!.jumpToBottom();
      await tester.pump();
      final tail = listController.visibleRange!;
      expect(tail.$2, greaterThanOrEqualTo(messages.length - 1));
    },
  );

  testWidgets('controller swap mid-stream drains the queue and stays usable', (
    tester,
  ) async {
    final notifier = StreamingContentNotifier();
    addTearDown(notifier.dispose);
    notifier.getNotifier('tool-1');

    final key = GlobalKey<_HarnessState>();
    final messages = <ChatMessage>[
      ChatMessage(
        id: 'tool-1',
        role: 'assistant',
        content: '',
        conversationId: 'conversation-1',
        isStreaming: true,
      ),
      ChatMessage(
        id: 'text-1',
        role: 'assistant',
        content: 'A' * 1800,
        conversationId: 'conversation-1',
      ),
      ChatMessage(
        id: 'text-2',
        role: 'assistant',
        content: 'B' * 1800,
        conversationId: 'conversation-1',
      ),
      ChatMessage(
        id: 'text-3',
        role: 'assistant',
        content: 'C' * 1800,
        conversationId: 'conversation-1',
      ),
    ];
    final toolParts = <String, List<ToolUIPart>>{
      'tool-1': const [
        ToolUIPart(
          id: 'ask',
          toolName: 'ask_user_input_v0',
          arguments: {},
          loading: true,
        ),
      ],
    };

    await tester.pumpWidget(
      _Harness(
        key: key,
        notifier: notifier,
        messages: messages,
        toolParts: toolParts,
      ),
    );
    await tester.pump();

    // A fresh controller replaces the current one while a tool height change
    // is in flight. The swap runs through MessageListView.didUpdateWidget and
    // the attach-aware scheduler; a regression that strands the queue or spins
    // the retry loop would deadlock the post-frame callbacks here.
    final fresh = ListController();
    key.currentState!.replaceListController(fresh);
    toolParts['tool-1'] = [
      ToolUIPart(
        id: 'ask',
        toolName: 'ask_user_input_v0',
        arguments: const {},
        content: '{"answers":{}}',
      ),
    ];
    notifier.notifyToolPartsUpdated('tool-1');
    await tester.pump();
    await tester.pump();
    await tester.pump();

    final attached = tester
        .widget<SuperListView>(find.byType(SuperListView))
        .listController!;
    expect(identical(attached, fresh), isTrue);

    // Queue semantics themselves (detached/locked hold, drain on attach) are
    // unit-covered in test/features/home/controllers/
    // tool_extent_invalidation_queue_test.dart; this guard only verifies the
    // widget-level integration remains functional: jumping to the bottom still
    // renders the tail through the last row.
    key.currentState!.jumpToBottom();
    await tester.pump();
    final tail = fresh.visibleRange!;
    expect(tail.$2, greaterThanOrEqualTo(messages.length - 1));
  });

  testWidgets('recovered tool signature change invalidates extent on rebuild', (
    tester,
  ) async {
    final key = GlobalKey<_HarnessState>();
    final message = ChatMessage(
      id: 'hist-1',
      role: 'assistant',
      content: '',
      conversationId: 'conversation-1',
    );

    await tester.pumpWidget(
      _Harness(
        key: key,
        messages: [message],
        toolParts: {
          'hist-1': const [
            ToolUIPart(id: 'ask', toolName: 'ask_user_input_v0', arguments: {}),
          ],
        },
      ),
    );
    await tester.pump();

    final list = tester.widget<SuperListView>(find.byType(SuperListView));
    final before = list.extentEstimation!(0, 400);

    // The recovered answer replaces the tool list with new instances while
    // also adding a second tool; only the signature snapshot can detect this.
    key.currentState!.replaceTools({
      'hist-1': [
        ToolUIPart(
          id: 'ask',
          toolName: 'ask_user_input_v0',
          arguments: const {},
          content: '{"answers":{}}',
        ),
        const ToolUIPart(
          id: 't1',
          toolName: 'read_file',
          arguments: {'path': 'a.txt'},
          content: 'data',
        ),
      ],
    });
    await tester.pump();

    final after = tester
        .widget<SuperListView>(find.byType(SuperListView))
        .extentEstimation!(0, 400);
    expect(after, isNot(before));
  });

  testWidgets('tool estimate counts only timeline-visible tools', (
    tester,
  ) async {
    final message = ChatMessage(
      id: 'm1',
      role: 'assistant',
      content: '',
      conversationId: 'conversation-1',
    );

    await tester.pumpWidget(
      _Harness(
        messages: [message],
        toolParts: {
          'm1': const [
            ToolUIPart(
              id: 'search',
              toolName: 'builtin_search',
              arguments: {'query': 'x'},
            ),
            ToolUIPart(
              id: 'read',
              toolName: 'read_file',
              arguments: {'path': 'a.txt'},
            ),
          ],
        },
      ),
    );
    await tester.pump();

    // builtin_search is hidden from the timeline; only read_file contributes.
    final list = tester.widget<SuperListView>(find.byType(SuperListView));
    expect(list.extentEstimation!(0, 400), closeTo(96 + 44.0, 0.1));
  });
}

class _Harness extends StatefulWidget {
  const _Harness({
    super.key,
    required this.messages,
    required this.toolParts,
    this.notifier,
  });

  final List<ChatMessage> messages;
  final Map<String, List<ToolUIPart>> toolParts;
  final StreamingContentNotifier? notifier;

  @override
  State<_Harness> createState() => _HarnessState();
}

class _HarnessState extends State<_Harness> {
  late final ScrollController scrollController;
  late ListController listController;
  late final ValueNotifier<bool> isProcessingFiles;
  late Map<String, List<ToolUIPart>> toolParts;

  @override
  void initState() {
    super.initState();
    scrollController = ScrollController();
    listController = ListController();
    isProcessingFiles = ValueNotifier<bool>(false);
    // Share the same mutable map as production: stream updates replace the
    // list in place instead of rebuilding MessageListView.
    toolParts = widget.toolParts;
  }

  void replaceTools(Map<String, List<ToolUIPart>> next) {
    setState(() => toolParts = next);
  }

  void replaceListController(ListController next) {
    setState(() => listController = next);
  }

  void jumpToBottom() {
    if (!scrollController.hasClients) return;
    scrollController.jumpTo(scrollController.position.maxScrollExtent);
  }

  @override
  void dispose() {
    scrollController.dispose();
    listController.dispose();
    isProcessingFiles.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      providers: [
        Provider<BusinessPreferences>.value(value: businessPrefs),
        ChangeNotifierProvider(
          create: (_) => SettingsProvider(preferences: businessPrefs),
        ),
        ChangeNotifierProvider(
          create: (_) => AssistantProvider(preferences: businessPrefs),
        ),
        ChangeNotifierProvider(
          create: (_) => UserProvider(preferences: businessPrefs),
        ),
        ChangeNotifierProvider(
          create: (_) => TtsProvider(preferences: businessPrefs),
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
            byGroup: const {},
            versionSelections: const {},
            reasoning: const <String, stream_ctrl.ReasoningData>{},
            reasoningSegments:
                const <String, List<stream_ctrl.ReasoningSegmentData>>{},
            contentSplits: const <String, stream_ctrl.ContentSplitData>{},
            toolParts: toolParts,
            translations: const {},
            selecting: false,
            selectedItems: const {},
            dividerPadding: EdgeInsets.zero,
            isProcessingFiles: isProcessingFiles,
            streamingContentNotifier: widget.notifier,
          ),
        ),
      ),
    );
  }
}
