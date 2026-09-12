import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:Cuplivo/core/database/business_preferences.dart';
import 'package:Cuplivo/core/models/chat_input_data.dart';
import 'package:Cuplivo/core/models/chat_message.dart';
import 'package:Cuplivo/core/models/conversation.dart';
import 'package:Cuplivo/core/models/quick_instruction.dart';
import 'package:Cuplivo/core/models/reasoning_payload.dart';
import 'package:Cuplivo/core/providers/assistant_provider.dart';
import 'package:Cuplivo/core/providers/mcp_provider.dart';
import 'package:Cuplivo/core/providers/quick_instruction_provider.dart';
import 'package:Cuplivo/core/providers/settings_provider.dart';
import 'package:Cuplivo/core/services/api/chat_api_service.dart';
import 'package:Cuplivo/core/services/chat/chat_service.dart';
import 'package:Cuplivo/core/services/generation_engine.dart';
import 'package:Cuplivo/features/home/controllers/home_page_controller.dart';
import 'package:Cuplivo/features/home/widgets/chat_input_bar.dart';
import 'package:Cuplivo/features/home/widgets/quick_instruction_editing_controller.dart';
import 'package:Cuplivo/l10n/app_localizations.dart';

class _FakeChatService extends ChatService {
  Conversation? _conversation;
  final List<ChatMessage> _messages = <ChatMessage>[];
  int _nextMessageId = 1;

  int createdConversationCount = 0;

  @override
  bool get initialized => true;

  @override
  String? get currentConversationId => _conversation?.id;

  @override
  List<Conversation> getAllConversations({bool includeGroup = false}) =>
      _conversation == null
      ? const <Conversation>[]
      : <Conversation>[_conversation!];

  @override
  Future<Conversation> createDraftConversation({
    String? title,
    String? assistantId,
    bool temporary = false,
  }) async {
    createdConversationCount++;
    _conversation = Conversation(
      id: 'conversation-$createdConversationCount',
      // Keep title generation out of this send-path regression harness.
      title: '${title ?? 'New Chat'} (pre-titled)',
      assistantId: assistantId,
    );
    notifyListeners();
    return _conversation!;
  }

  @override
  Conversation? getConversation(String id) =>
      _conversation?.id == id ? _conversation : null;

  @override
  Conversation? getCompleteConversation(String id) => getConversation(id);

  @override
  int getMessageCount(String conversationId) => _messages
      .where((message) => message.conversationId == conversationId)
      .length;

  @override
  List<ChatMessage> getMessages(String conversationId) => _messages
      .where((message) => message.conversationId == conversationId)
      .toList(growable: false);

  @override
  List<ChatMessage> getMessagesRange(
    String conversationId, {
    required int start,
    required int limit,
  }) {
    if (limit <= 0) return const <ChatMessage>[];
    final messages = getMessages(conversationId);
    final safeStart = start.clamp(0, messages.length).toInt();
    final end = (safeStart + limit).clamp(safeStart, messages.length).toInt();
    return messages.sublist(safeStart, end);
  }

  @override
  List<ChatMessage> getRecentMessages(
    String conversationId, {
    int minMessages = ChatService.defaultInitialMessageMin,
    int textBudget = ChatService.defaultInitialTextBudget,
    int maxMessages = ChatService.defaultInitialMessageMax,
  }) {
    final messages = getMessages(conversationId);
    if (messages.length <= maxMessages) return messages;
    return messages.sublist(messages.length - maxMessages);
  }

  @override
  Map<String, int> getVersionSelections(String conversationId) =>
      Map<String, int>.from(_conversation?.versionSelections ?? const {});

  @override
  Future<void> clearConversationSuggestions(String conversationId) async {}

  @override
  Future<ChatMessage> addMessage({
    required String conversationId,
    required String role,
    required String content,
    String? modelId,
    String? providerId,
    int? totalTokens,
    bool isStreaming = false,
    String? reasoningText,
    DateTime? reasoningStartAt,
    DateTime? reasoningFinishedAt,
    String? groupId,
    String? subgroupId,
    int? version,
    bool isPreset = false,
    String? speakerAssistantId,
    String? quoteJson,
    String? quickInstructionInvocationsJson,
  }) async {
    final message = ChatMessage(
      id: 'message-${_nextMessageId++}',
      role: role,
      content: content,
      conversationId: conversationId,
      modelId: modelId,
      providerId: providerId,
      totalTokens: totalTokens,
      isStreaming: isStreaming,
      reasoningText: reasoningText,
      reasoningStartAt: reasoningStartAt,
      reasoningFinishedAt: reasoningFinishedAt,
      groupId: groupId,
      subgroupId: subgroupId,
      version: version,
      isPreset: isPreset,
      speakerAssistantId: speakerAssistantId,
      quoteJson: quoteJson,
      quickInstructionInvocationsJson: quickInstructionInvocationsJson,
    );
    _messages.add(message);
    _conversation?.messageIds.add(message.id);
    return message;
  }

  @override
  Future<void> updateMessage(
    String messageId, {
    String? content,
    int? totalTokens,
    int? contextTokens,
    bool? isStreaming,
    String? reasoningText,
    DateTime? reasoningStartAt,
    DateTime? reasoningFinishedAt,
    Object? translation = ChatMessage.sentinel,
    String? reasoningSegmentsJson,
    int? promptTokens,
    int? completionTokens,
    int? cachedTokens,
    int? durationMs,
    Object? groupId = ChatMessage.sentinel,
    Object? subgroupId = ChatMessage.sentinel,
    Object? version = ChatMessage.sentinel,
    Object? requestAllowImagesApiRouting = ChatMessage.sentinel,
    Object? requestExtraBody = ChatMessage.sentinel,
    Object? quickInstructionInvocationsJson = ChatMessage.sentinel,
  }) async {
    final index = _messages.indexWhere((message) => message.id == messageId);
    if (index < 0) return;
    var updated = _messages[index];
    if (content != null) updated = updated.copyWith(content: content);
    if (totalTokens != null) {
      updated = updated.copyWith(totalTokens: totalTokens);
    }
    if (contextTokens != null) {
      updated = updated.copyWith(contextTokens: contextTokens);
    }
    if (isStreaming != null) {
      updated = updated.copyWith(isStreaming: isStreaming);
    }
    if (reasoningText != null) {
      updated = updated.copyWith(reasoningText: reasoningText);
    }
    if (reasoningStartAt != null) {
      updated = updated.copyWith(reasoningStartAt: reasoningStartAt);
    }
    if (reasoningFinishedAt != null) {
      updated = updated.copyWith(reasoningFinishedAt: reasoningFinishedAt);
    }
    if (!identical(translation, ChatMessage.sentinel)) {
      updated = updated.copyWith(translation: translation);
    }
    if (reasoningSegmentsJson != null) {
      updated = updated.copyWith(reasoningSegmentsJson: reasoningSegmentsJson);
    }
    if (promptTokens != null) {
      updated = updated.copyWith(promptTokens: promptTokens);
    }
    if (completionTokens != null) {
      updated = updated.copyWith(completionTokens: completionTokens);
    }
    if (cachedTokens != null) {
      updated = updated.copyWith(cachedTokens: cachedTokens);
    }
    if (durationMs != null) {
      updated = updated.copyWith(durationMs: durationMs);
    }
    if (!identical(groupId, ChatMessage.sentinel)) {
      updated = updated.copyWith(groupId: groupId);
    }
    if (!identical(subgroupId, ChatMessage.sentinel)) {
      updated = updated.copyWith(subgroupId: subgroupId);
    }
    if (!identical(version, ChatMessage.sentinel)) {
      updated = updated.copyWith(version: version);
    }
    if (!identical(requestAllowImagesApiRouting, ChatMessage.sentinel)) {
      updated = updated.copyWith(
        requestAllowImagesApiRouting: requestAllowImagesApiRouting,
      );
    }
    if (!identical(requestExtraBody, ChatMessage.sentinel)) {
      final extraBody = requestExtraBody as Map<String, dynamic>?;
      updated = updated.copyWith(
        requestExtraBodyJson: extraBody == null || extraBody.isEmpty
            ? null
            : jsonEncode(extraBody),
      );
    }
    if (!identical(quickInstructionInvocationsJson, ChatMessage.sentinel)) {
      updated = updated.copyWith(
        quickInstructionInvocationsJson: quickInstructionInvocationsJson,
      );
    }
    _messages[index] = updated;
  }

  @override
  Future<void> updateMessageSilent(
    String messageId, {
    String? content,
    int? totalTokens,
    int? contextTokens,
    bool? isStreaming,
    String? reasoningText,
    DateTime? reasoningStartAt,
    DateTime? reasoningFinishedAt,
    Object? translation = ChatMessage.sentinel,
    String? reasoningSegmentsJson,
    int? promptTokens,
    int? completionTokens,
    int? cachedTokens,
    int? durationMs,
  }) {
    return updateMessage(
      messageId,
      content: content,
      totalTokens: totalTokens,
      contextTokens: contextTokens,
      isStreaming: isStreaming,
      reasoningText: reasoningText,
      reasoningStartAt: reasoningStartAt,
      reasoningFinishedAt: reasoningFinishedAt,
      translation: translation,
      reasoningSegmentsJson: reasoningSegmentsJson,
      promptTokens: promptTokens,
      completionTokens: completionTokens,
      cachedTokens: cachedTokens,
      durationMs: durationMs,
    );
  }
}

class _ControllerHost extends StatefulWidget {
  const _ControllerHost({required this.onReady});

  final ValueChanged<HomePageController> onReady;

  @override
  State<_ControllerHost> createState() => _ControllerHostState();
}

class _ControllerHostState extends State<_ControllerHost>
    with SingleTickerProviderStateMixin {
  final GlobalKey<ScaffoldState> _scaffoldKey = GlobalKey<ScaffoldState>();
  final GlobalKey _inputBarKey = GlobalKey();
  final FocusNode _inputFocus = FocusNode();
  final QuickInstructionEditingController _inputController =
      QuickInstructionEditingController();
  final ChatInputBarController _mediaController = ChatInputBarController();
  final ScrollController _scrollController = ScrollController();
  late final HomePageController _controller;

  @override
  void initState() {
    super.initState();
    _controller = HomePageController(
      context: context,
      vsync: this,
      scaffoldKey: _scaffoldKey,
      inputBarKey: _inputBarKey,
      inputFocus: _inputFocus,
      inputController: _inputController,
      mediaController: _mediaController,
      scrollController: _scrollController,
    );
    widget.onReady(_controller);
  }

  @override
  Widget build(BuildContext context) => Scaffold(key: _scaffoldKey);

  @override
  void dispose() {
    _controller.dispose();
    _inputFocus.dispose();
    _inputController.dispose();
    _scrollController.dispose();
    super.dispose();
  }
}

class _Harness {
  _Harness({
    required this.controller,
    required this.chatService,
    required this.settings,
    required this.assistants,
    required this.quickInstructions,
    required this.mcp,
    required this.engine,
  });

  final HomePageController controller;
  final _FakeChatService chatService;
  final SettingsProvider settings;
  final AssistantProvider assistants;
  final QuickInstructionProvider quickInstructions;
  final McpProvider mcp;
  final GenerationEngine engine;

  Future<void> dispose(WidgetTester tester) async {
    final conversationId = controller.currentConversation?.id;
    if (conversationId != null) {
      engine.cancelConversation(conversationId);
    }
    await tester.pump(const Duration(milliseconds: 150));
    await tester.pumpWidget(const SizedBox.shrink());
    engine.dispose();
    mcp.dispose();
    quickInstructions.dispose();
    assistants.dispose();
    settings.dispose();
    chatService.dispose();
  }
}

Future<_Harness> _pumpHarness(WidgetTester tester) async {
  final providerConfig = ProviderConfig(
    id: 'TestProvider',
    enabled: true,
    name: 'Test Provider',
    apiKey: 'test-key',
    baseUrl: 'https://example.com/v1',
    providerType: ProviderKind.openai,
    models: const <String>['plain-model'],
    modelOverrides: const <String, dynamic>{
      'plain-model': <String, dynamic>{'abilities': <String>[]},
    },
  );
  final preferences = BusinessPreferences.memoryForTests(<String, Object>{
    'provider_configs_v1': jsonEncode(<String, dynamic>{
      'TestProvider': providerConfig.toJson(),
    }),
    'selected_model_v1': 'TestProvider::plain-model',
    'default_model_seeded_v1': true,
    'migrations_version_v1': 4,
    'instruction_injections_v1': '[]',
  });
  final chatService = _FakeChatService();
  SharedPreferences.setMockInitialValues(const <String, Object>{});
  late final SettingsProvider settings;
  late final QuickInstructionProvider quickInstructions;
  await tester.runAsync(() async {
    settings = SettingsProvider(preferences: preferences);
    await settings.loaded;
    quickInstructions = QuickInstructionProvider(preferences: preferences);
    await quickInstructions.initialize();
  });

  final assistants = AssistantProvider(preferences: preferences);

  late BuildContext providerContext;
  final mcp = McpProvider(
    preferences: preferences,
    contextProvider: () => providerContext,
  );
  final engine = GenerationEngine(
    chatService: chatService,
    streamProvider:
        ({
          required config,
          required modelId,
          required messages,
          userMediaPaths,
          thinkingBudget,
          temperature,
          topP,
          maxTokens,
          tools,
          onToolCall,
          extraHeaders,
          extraBody,
          required stream,
          requestId,
          conversationId,
          required allowImagesApiRouting,
          required ocrActive,
          partialImageNotice,
        }) => Stream<ChatStreamChunk>.value(
          ChatStreamChunk(content: 'ok', isDone: true, totalTokens: 1),
        ),
  );

  HomePageController? controller;
  await tester.pumpWidget(
    MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: MultiProvider(
        providers: [
          Provider<BusinessPreferences>.value(value: preferences),
          ChangeNotifierProvider<ChatService>.value(value: chatService),
          ChangeNotifierProvider<SettingsProvider>.value(value: settings),
          ChangeNotifierProvider<AssistantProvider>.value(value: assistants),
          ChangeNotifierProvider<QuickInstructionProvider>.value(
            value: quickInstructions,
          ),
          ChangeNotifierProvider<McpProvider>.value(value: mcp),
          ChangeNotifierProvider<GenerationEngine>.value(value: engine),
        ],
        child: Builder(
          builder: (context) {
            providerContext = context;
            return _ControllerHost(onReady: (value) => controller = value);
          },
        ),
      ),
    ),
  );
  await tester.pump();

  return _Harness(
    controller: controller!,
    chatService: chatService,
    settings: settings,
    assistants: assistants,
    quickInstructions: quickInstructions,
    mcp: mcp,
    engine: engine,
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('first plain-text send creates and uses a conversation', (
    tester,
  ) async {
    final harness = await _pumpHarness(tester);
    try {
      expect(harness.controller.currentConversation, isNull);

      final result = await harness.controller.sendMessage(
        const ChatInputData(text: 'hello'),
      );

      expect(result, ChatInputSubmissionResult.sent);
      expect(harness.chatService.createdConversationCount, 1);
      expect(harness.controller.currentConversation?.id, 'conversation-1');
      final userMessages = harness.chatService
          .getMessages('conversation-1')
          .where((message) => message.role == 'user')
          .toList(growable: false);
      expect(userMessages, hasLength(1));
      expect(userMessages.single.content, 'hello');
    } finally {
      await harness.dispose(tester);
    }
  }, timeout: const Timeout(Duration(seconds: 45)));

  testWidgets('first quick-instruction-only send uses the new conversation', (
    tester,
  ) async {
    final harness = await _pumpHarness(tester);
    try {
      final invocation = QuickInstructionInvocationSnapshot.fromInstruction(
        QuickInstruction(
          id: 'quick-before',
          title: 'Answer briefly',
          prompt: 'Use one sentence.',
        ),
        order: 0,
      );

      expect(harness.controller.currentConversation, isNull);

      final result = await harness.controller.sendMessage(
        ChatInputData(
          text: '',
          quickInstructions: <QuickInstructionInvocationSnapshot>[invocation],
        ),
      );

      expect(result, ChatInputSubmissionResult.sent);
      expect(harness.chatService.createdConversationCount, 1);
      expect(harness.controller.currentConversation?.id, 'conversation-1');
      final userMessage = harness.chatService
          .getMessages('conversation-1')
          .singleWhere((message) => message.role == 'user');
      expect(userMessage.content, isEmpty);
      expect(userMessage.quickInstructionInvocations, hasLength(1));
      expect(
        userMessage.quickInstructionInvocations.single.instructionId,
        'quick-before',
      );
    } finally {
      await harness.dispose(tester);
    }
  }, timeout: const Timeout(Duration(seconds: 45)));

  group('thinking expansion persistence (issue #737)', () {
    Future<String> seedAssistantWithSegment(
      WidgetTester tester,
      _Harness harness, {
      required bool streaming,
    }) async {
      await harness.controller.sendMessage(const ChatInputData(text: 'hi'));
      for (var i = 0; i < 50; i++) {
        await tester.pump(const Duration(milliseconds: 10));
      }
      final index = harness.controller.messages.indexWhere(
        (message) => message.role == 'assistant',
      );
      expect(
        index,
        isNot(-1),
        reason: 'assistant placeholder must be visible in the controller list',
      );
      final assistantId = harness.controller.messages[index].id;
      // Force the guarded state deterministically instead of racing the
      // generation lifecycle.
      harness.controller.messages[index] = harness.controller.messages[index]
          .copyWith(isStreaming: streaming);
      harness.controller.reasoningSegments[assistantId] = [
        ReasoningSegmentData()
          ..text = 'deep thinking'
          ..expanded = true
          ..startAt = DateTime(2024, 1, 1)
          ..finishedAt = DateTime(2024, 1, 1),
      ];
      harness.controller.contentSplits[assistantId] = const ContentSplitData(
        offsets: [0],
        reasoningCounts: [1],
        toolCounts: [0],
      );
      return assistantId;
    }

    testWidgets('a settled toggle persists the flipped flag in a full v2 '
        'payload', (tester) async {
      final harness = await _pumpHarness(tester);
      try {
        final assistantId = await seedAssistantWithSegment(
          tester,
          harness,
          streaming: false,
        );

        final ok = harness.controller.setReasoningSegmentExpanded(
          assistantId,
          0,
          false,
        );
        expect(ok, isTrue);

        final stored = harness.chatService
            .getMessages('conversation-1')
            .singleWhere((message) => message.id == assistantId);
        expect(stored.reasoningSegmentsJson, isNotNull);
        final decoded =
            jsonDecode(stored.reasoningSegmentsJson!) as Map<String, dynamic>;
        expect(decoded['v'], 2);
        final segments = (decoded['segments'] as List).cast<Map>();
        expect(segments.single['expanded'], isFalse);
        expect(decoded['contentSplits'], isNotNull);
      } finally {
        await harness.dispose(tester);
      }
    }, timeout: const Timeout(Duration(seconds: 45)));

    testWidgets('a streaming toggle is not persisted', (tester) async {
      final harness = await _pumpHarness(tester);
      try {
        final assistantId = await seedAssistantWithSegment(
          tester,
          harness,
          streaming: true,
        );

        final ok = harness.controller.setReasoningSegmentExpanded(
          assistantId,
          0,
          false,
        );
        expect(ok, isTrue);

        final stored = harness.chatService
            .getMessages('conversation-1')
            .singleWhere((message) => message.id == assistantId);
        expect(stored.reasoningSegmentsJson, isNull);
      } finally {
        await harness.dispose(tester);
      }
    }, timeout: const Timeout(Duration(seconds: 45)));
  });
}
