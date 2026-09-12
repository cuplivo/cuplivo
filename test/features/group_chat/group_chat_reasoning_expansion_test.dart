import 'dart:convert';

import 'package:Cuplivo/core/database/app_database.dart';
import 'package:Cuplivo/core/database/business_preferences.dart';
import 'package:Cuplivo/core/database/chat_database_repository.dart';
import 'package:Cuplivo/core/models/chat_message.dart';
import 'package:Cuplivo/core/models/conversation.dart';
import 'package:Cuplivo/core/models/reasoning_payload.dart';
import 'package:Cuplivo/core/providers/asr_provider.dart';
import 'package:Cuplivo/core/providers/assistant_provider.dart';
import 'package:Cuplivo/core/providers/group_chat_provider.dart';
import 'package:Cuplivo/core/providers/input_status_provider.dart';
import 'package:Cuplivo/core/providers/settings_provider.dart';
import 'package:Cuplivo/core/providers/tts_provider.dart';
import 'package:Cuplivo/core/providers/user_provider.dart';
import 'package:Cuplivo/core/services/chat/chat_service.dart';
import 'package:Cuplivo/core/services/generation_engine.dart';
import 'package:Cuplivo/features/group_chat/widgets/group_chat_view.dart';
import 'package:Cuplivo/features/home/services/ask_user_interaction_service.dart';
import 'package:Cuplivo/features/home/services/input_draft_persistence.dart';
import 'package:Cuplivo/features/home/services/tool_approval_service.dart';
import 'package:Cuplivo/l10n/app_localizations.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

Future<void> waitForSettingsLoad() async {
  await Future<void>.delayed(const Duration(milliseconds: 50));
}

/// In-memory [ChatService] that serves seeded messages and records the
/// reasoning payload written by a manual thinking-step toggle.
class _SeededChatService extends ChatService {
  late final AppDatabase db = AppDatabase(NativeDatabase.memory());
  late final ChatDatabaseRepository _testRepo = ChatDatabaseRepository(db);
  final Map<String, Conversation> _conversations = <String, Conversation>{};
  final Map<String, List<ChatMessage>> _messages =
      <String, List<ChatMessage>>{};
  final List<({String messageId, String? segmentsJson})> reasoningUpdates = [];

  void seedMessage(ChatMessage message) {
    (_messages[message.conversationId] ??= <ChatMessage>[]).add(message);
  }

  @override
  bool get initialized => true;

  @override
  ChatDatabaseRepository get repo => _testRepo;

  @override
  Future<Conversation> createConversation({
    String? title,
    String? assistantId,
    List<String>? mcpServerIds,
    String? parentConversationId,
    String conversationKind = Conversation.kindNormal,
    bool setAsCurrent = true,
    List<String>? persistentQuickInstructionIds,
  }) async {
    final conversation = Conversation(
      title: title ?? 'New Chat',
      assistantId: assistantId,
      mcpServerIds: mcpServerIds,
      parentConversationId: parentConversationId,
      conversationKind: conversationKind,
      persistentQuickInstructionIds: persistentQuickInstructionIds,
    );
    await _testRepo.putConversation(conversation);
    _conversations[conversation.id] = conversation;
    return conversation;
  }

  @override
  Conversation? getConversation(String id) => _conversations[id];

  @override
  Conversation? getCompleteConversation(String id) => _conversations[id];

  @override
  int getMessageCount(String conversationId) =>
      _messages[conversationId]?.length ?? 0;

  @override
  List<ChatMessage> getMessagesRange(
    String conversationId, {
    required int start,
    required int limit,
  }) {
    final all = _messages[conversationId] ?? const <ChatMessage>[];
    if (limit <= 0) return const <ChatMessage>[];
    final safeStart = start.clamp(0, all.length).toInt();
    final end = (safeStart + limit).clamp(safeStart, all.length).toInt();
    return all.sublist(safeStart, end);
  }

  @override
  List<ChatMessage> getRecentMessages(
    String conversationId, {
    int minMessages = ChatService.defaultInitialMessageMin,
    int textBudget = ChatService.defaultInitialTextBudget,
    int maxMessages = ChatService.defaultInitialMessageMax,
  }) =>
      List<ChatMessage>.of(_messages[conversationId] ?? const <ChatMessage>[]);

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
    Object? translation,
    String? reasoningSegmentsJson,
    int? promptTokens,
    int? completionTokens,
    int? cachedTokens,
    int? durationMs,
  }) async {
    if (reasoningSegmentsJson != null) {
      reasoningUpdates.add((
        messageId: messageId,
        segmentsJson: reasoningSegmentsJson,
      ));
    }
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
  }) async {}

  @override
  Future<void> bumpConversationUpdatedAt(String conversationId) async {}

  Future<void> closeDb() async {
    await _testRepo.close();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'group-chat thinking toggle persists the flipped expanded flag (issue #737)',
    (tester) async {
      final chatService = _SeededChatService();
      addTearDown(chatService.closeDb);
      final provider = GroupChatProvider(chatService: chatService);
      await provider.load();
      final group = await provider.createGroup(name: 'G');

      final now = DateTime(2024, 1, 1);
      final payload = serializeReasoningSegmentsWithSplits(
        [
          ReasoningSegmentData()
            ..text = 'deep thinking'
            ..expanded = true
            ..startAt = now
            ..finishedAt = now,
        ],
        contentSplitOffsets: const [0],
        reasoningCountAtSplit: const [1],
        toolCountAtSplit: const [0],
      );
      chatService.seedMessage(
        ChatMessage(
          id: 'assistant-1',
          role: 'assistant',
          content: 'answer',
          conversationId: group.conversationId,
          isStreaming: false,
          reasoningText: 'deep thinking',
          reasoningStartAt: now,
          reasoningFinishedAt: now,
          reasoningSegmentsJson: payload,
        ),
      );

      final businessPrefs = BusinessPreferences.memoryForTests();
      final settings = SettingsProvider(preferences: businessPrefs);
      await tester.runAsync(waitForSettingsLoad);
      addTearDown(settings.dispose);

      await tester.pumpWidget(
        MultiProvider(
          providers: [
            Provider<BusinessPreferences>.value(value: businessPrefs),
            ChangeNotifierProvider<SettingsProvider>.value(value: settings),
            ChangeNotifierProvider<AssistantProvider>(
              create: (_) => AssistantProvider(preferences: businessPrefs),
            ),
            ChangeNotifierProvider<UserProvider>(
              create: (_) => UserProvider(preferences: businessPrefs),
            ),
            ChangeNotifierProvider<GroupChatProvider>.value(value: provider),
            ChangeNotifierProvider<ChatService>.value(value: chatService),
            ChangeNotifierProvider<GenerationEngine>(
              create: (_) => GenerationEngine(chatService: chatService),
            ),
            ChangeNotifierProvider<ToolApprovalService>(
              create: (_) => ToolApprovalService(),
            ),
            ChangeNotifierProvider<AskUserInteractionService>(
              create: (_) => AskUserInteractionService(),
            ),
            ChangeNotifierProvider<AsrProvider>(
              create: (_) => AsrProvider(settingsProvider: settings),
            ),
            ChangeNotifierProvider<TtsProvider>(
              create: (_) => TtsProvider(preferences: businessPrefs),
            ),
            ChangeNotifierProvider<InputStatusProvider>(
              create: (_) => InputStatusProvider(),
            ),
            Provider<InputDraftPersistence>(
              create: (_) => InputDraftPersistence(null),
            ),
          ],
          child: MaterialApp(
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: Scaffold(body: GroupChatView(groupChatId: group.id)),
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      final thinkingLabel = find.text('Deep Thinking');
      expect(thinkingLabel, findsWidgets);

      await tester.tap(thinkingLabel.first);
      await tester.pump();

      expect(chatService.reasoningUpdates, hasLength(1));
      final decoded =
          jsonDecode(chatService.reasoningUpdates.single.segmentsJson!)
              as Map<String, dynamic>;
      expect(decoded['v'], 2);
      final segments = (decoded['segments'] as List).cast<Map>();
      expect(segments.single['expanded'], isFalse);
    },
    timeout: const Timeout(Duration(seconds: 45)),
  );
}
