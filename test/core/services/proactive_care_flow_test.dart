import 'dart:io';

import 'package:Cuplivo/core/database/app_database.dart';
import 'package:Cuplivo/core/database/business_preferences.dart';
import 'package:Cuplivo/core/database/business_repository.dart';
import 'package:Cuplivo/core/database/chat_database_repository.dart';
import 'package:Cuplivo/core/models/assistant.dart';
import 'package:Cuplivo/core/models/chat_message.dart';
import 'package:Cuplivo/core/models/conversation.dart';
import 'package:Cuplivo/core/models/reasoning_request.dart';
import 'package:Cuplivo/core/providers/settings_provider.dart';
import 'package:Cuplivo/core/services/chat/chat_service.dart';
import 'package:Cuplivo/core/services/proactive_care_decision_tools.dart';
import 'package:Cuplivo/core/services/proactive_care_message_flow.dart';
import 'package:Cuplivo/core/services/proactive_care_service.dart';
import 'package:Cuplivo/utils/sandbox_path_resolver.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
// ignore: depend_on_referenced_packages
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _FakePathProvider extends PathProviderPlatform {
  _FakePathProvider(this.root);
  final String root;
  @override
  Future<String?> getApplicationDocumentsPath() async => root;
  @override
  Future<String?> getApplicationSupportPath() async => root;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;
  late AppDatabase database;
  late ChatService chatService;
  late SettingsProvider settings;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('kelivo_care_flow_');
    PathProviderPlatform.instance = _FakePathProvider(tempDir.path);
    SandboxPathResolver.debugSetDirs(
      docsDir: tempDir.path,
      supportDir: tempDir.path,
    );
    SharedPreferences.setMockInitialValues({});
    database = AppDatabase(NativeDatabase.memory());
    addTearDown(database.close);
    final repository = ChatDatabaseRepository(database);
    chatService = ChatService(existingRepository: repository);
    addTearDown(chatService.close);
    await chatService.init();
    final preferences = BusinessPreferences(BusinessRepository(database));
    settings = SettingsProvider(preferences);
    addTearDown(settings.dispose);
    await settings.loaded;
  });

  tearDown(() async {
    try {
      await tempDir.delete(recursive: true);
    } catch (_) {}
  });

  Future<Conversation> seededConversation(
    Assistant assistant,
    DateTime dueAt,
  ) async {
    final conversation = await chatService.createConversation(
      title: 'Care',
      assistantId: assistant.id,
    );
    await chatService.addMessage(
      conversationId: conversation.id,
      role: 'user',
      content: '最近还好吗',
    );
    await chatService.updateConversationExtras(conversation.id, (extras) {
      extras[Conversation.proactiveCareEnabledOverrideKey] = true;
      extras[Conversation.proactiveCareNextMessageAtKey] = dueAt
          .toIso8601String();
      return extras;
    });
    return chatService.getConversation(conversation.id)!;
  }

  test('decideNextCareTime returns the tool-provided future time', () async {
    final flow = ProactiveCareMessageFlow(
      chatService: chatService,
      settings: settings,
      decisionSender:
          ({
            required config,
            required modelId,
            required messages,
            required tools,
            onToolCall,
            reasoning = ReasoningRequest.auto,
            topP,
            maxTokens,
            requestId,
            conversationId,
          }) async {
            await onToolCall?.call(ProactiveCareDecisionTools.updateTime, {
              'next_care_time': DateTime.now()
                  .add(const Duration(hours: 6))
                  .toIso8601String(),
            });
            return null;
          },
      careSender:
          ({
            required config,
            required modelId,
            required messages,
            reasoning = ReasoningRequest.auto,
            topP,
            maxTokens,
            conversationId,
          }) async => 'letter',
    );
    final assistant = Assistant(id: 'a', name: 'A', enableProactiveCare: true);
    final next = await flow.decideNextCareTime(
      config: settings.getProviderConfig('openai'),
      modelId: 'gpt-x',
      assistant: assistant,
      userNickname: 'User',
      history: [
        {'role': 'user', 'content': 'hi'},
      ],
      decisionPrompt: '',
      currentNextCareTime: null,
    );
    expect(next, isNotNull);
    expect(next!.isAfter(DateTime.now()), isTrue);
  });

  test('decideNextCareTime keeps time on keep_care_time', () async {
    final flow = ProactiveCareMessageFlow(
      chatService: chatService,
      settings: settings,
      decisionSender:
          ({
            required config,
            required modelId,
            required messages,
            required tools,
            onToolCall,
            reasoning = ReasoningRequest.auto,
            topP,
            maxTokens,
            requestId,
            conversationId,
          }) async {
            await onToolCall?.call(
              ProactiveCareDecisionTools.keepTime,
              const <String, dynamic>{},
            );
            return null;
          },
      careSender:
          ({
            required config,
            required modelId,
            required messages,
            reasoning = ReasoningRequest.auto,
            topP,
            maxTokens,
            conversationId,
          }) async => 'letter',
    );
    final next = await flow.decideNextCareTime(
      config: settings.getProviderConfig('openai'),
      modelId: 'gpt-x',
      assistant: Assistant(id: 'a', name: 'A'),
      userNickname: 'User',
      history: [
        {'role': 'user', 'content': 'hi'},
      ],
      decisionPrompt: '',
      currentNextCareTime: DateTime.now().add(const Duration(days: 1)),
    );
    expect(next, isNull);
  });

  test('decideNextCareTime rejects past times', () async {
    final flow = ProactiveCareMessageFlow(
      chatService: chatService,
      settings: settings,
      decisionSender:
          ({
            required config,
            required modelId,
            required messages,
            required tools,
            onToolCall,
            reasoning = ReasoningRequest.auto,
            topP,
            maxTokens,
            requestId,
            conversationId,
          }) async {
            await onToolCall?.call(ProactiveCareDecisionTools.updateTime, {
              'next_care_time': DateTime.now()
                  .subtract(const Duration(hours: 1))
                  .toIso8601String(),
            });
            return null;
          },
      careSender:
          ({
            required config,
            required modelId,
            required messages,
            reasoning = ReasoningRequest.auto,
            topP,
            maxTokens,
            conversationId,
          }) async => 'letter',
    );
    final next = await flow.decideNextCareTime(
      config: settings.getProviderConfig('openai'),
      modelId: 'gpt-x',
      assistant: Assistant(id: 'a', name: 'A'),
      userNickname: 'User',
      history: [
        {'role': 'user', 'content': 'hi'},
      ],
      decisionPrompt: '',
      currentNextCareTime: null,
    );
    expect(next, isNull);
  });

  test(
    'runDueSchedules consumes the schedule, persists a letter and reschedules',
    () async {
      final dueAt = DateTime.now().subtract(const Duration(minutes: 5));
      final assistant = Assistant(
        id: 'a',
        name: 'A',
        chatModelProvider: 'openai',
        chatModelId: 'gpt-test',
        enableProactiveCare: true,
        proactiveCarePrompt: '问候我',
        proactiveCareDecisionPrompt: '决定下次时间',
      );
      await seededConversation(assistant, dueAt);

      var carePromptSeen = '';
      final flow = ProactiveCareMessageFlow(
        chatService: chatService,
        settings: settings,
        careSender:
            ({
              required config,
              required modelId,
              required messages,
              reasoning = ReasoningRequest.auto,
              topP,
              maxTokens,
              conversationId,
            }) async {
              carePromptSeen = messages.last['content'].toString();
              return '来自 Ta 的问候';
            },
        decisionSender:
            ({
              required config,
              required modelId,
              required messages,
              required tools,
              onToolCall,
              reasoning = ReasoningRequest.auto,
              topP,
              maxTokens,
              requestId,
              conversationId,
            }) async {
              await onToolCall?.call(ProactiveCareDecisionTools.updateTime, {
                'next_care_time': DateTime.now()
                    .add(const Duration(days: 1))
                    .toIso8601String(),
              });
              return null;
            },
      );

      final delivered = await flow.runDueSchedules(
        assistants: [assistant],
        userNickname: 'User',
      );

      expect(delivered, hasLength(1));
      expect(delivered.single.successful, isTrue);
      expect(delivered.single.content, '来自 Ta 的问候');
      // Care prompt (with the time footer) is the final user turn.
      expect(carePromptSeen, contains('问候我'));
      expect(carePromptSeen, contains('当前系统时间'));

      // The assistant letter landed in the conversation.
      final conversationId = delivered.single.conversationId;
      final messages = await chatService.loadMessages(conversationId);
      expect(
        messages.any((m) => m.role == 'assistant' && m.content == '来自 Ta 的问候'),
        isTrue,
      );

      // The schedule was consumed and the decision model rescheduled it.
      final fresh = chatService.getConversation(conversationId)!;
      final nextAt = fresh.proactiveCareNextMessageAt;
      expect(nextAt, isNotNull);
      expect(nextAt!.isAfter(DateTime.now()), isTrue);
    },
  );

  test('runDueSchedules skips schedules that are not due yet', () async {
    final future = DateTime.now().add(const Duration(hours: 2));
    final assistant = Assistant(id: 'a', name: 'A', enableProactiveCare: true);
    final conversation = await seededConversation(assistant, future);

    var careCalls = 0;
    final flow = ProactiveCareMessageFlow(
      chatService: chatService,
      settings: settings,
      careSender:
          ({
            required config,
            required modelId,
            required messages,
            reasoning = ReasoningRequest.auto,
            topP,
            maxTokens,
            conversationId,
          }) async {
            careCalls++;
            return 'x';
          },
      decisionSender:
          ({
            required config,
            required modelId,
            required messages,
            required tools,
            onToolCall,
            reasoning = ReasoningRequest.auto,
            topP,
            maxTokens,
            requestId,
            conversationId,
          }) async => null,
    );

    final delivered = await flow.runDueSchedules(
      assistants: [assistant],
      userNickname: 'User',
    );
    expect(delivered, isEmpty);
    expect(careCalls, 0);
    // The future schedule survives untouched.
    expect(
      chatService.getConversation(conversation.id)!.proactiveCareNextMessageAt,
      isNotNull,
    );
  });

  test('runSchedule claims atomically: a second run finds nothing', () async {
    final dueAt = DateTime.now().subtract(const Duration(minutes: 5));
    final assistant = Assistant(
      id: 'a',
      name: 'A',
      chatModelProvider: 'openai',
      chatModelId: 'gpt-test',
      enableProactiveCare: true,
      proactiveCarePrompt: '问候我',
    );
    final conversation = await seededConversation(assistant, dueAt);
    final flow = ProactiveCareMessageFlow(
      chatService: chatService,
      settings: settings,
      careSender:
          ({
            required config,
            required modelId,
            required messages,
            reasoning = ReasoningRequest.auto,
            topP,
            maxTokens,
            conversationId,
          }) async => 'letter',
      decisionSender:
          ({
            required config,
            required modelId,
            required messages,
            required tools,
            onToolCall,
            reasoning = ReasoningRequest.auto,
            topP,
            maxTokens,
            requestId,
            conversationId,
          }) async => null,
    );

    final first = await flow.runSchedule(
      conversationId: conversation.id,
      expectedAt: dueAt,
      assistants: [assistant],
      userNickname: 'User',
    );
    final second = await flow.runSchedule(
      conversationId: conversation.id,
      expectedAt: dueAt,
      assistants: [assistant],
      userNickname: 'User',
    );

    expect(first, isNotNull);
    expect(first!.successful, isTrue);
    // The claim consumed the persisted schedule: no double delivery.
    expect(second, isNull);
    final messages = await chatService.loadMessages(conversation.id);
    expect(messages.where((m) => m.role == 'assistant').length, 1);
  });

  test(
    'runSchedule claims successfully across UTC and local time representation',
    () async {
      final dueAtLocal = DateTime.now().subtract(const Duration(minutes: 5));
      final dueAtUtc = dueAtLocal.toUtc();
      final assistant = Assistant(
        id: 'a2',
        name: 'A2',
        chatModelProvider: 'openai',
        chatModelId: 'gpt-test',
        enableProactiveCare: true,
        proactiveCarePrompt: '问候我',
      );
      final conversation = await chatService.createConversation(
        title: 'Care UTC',
        assistantId: assistant.id,
      );
      await chatService.addMessage(
        conversationId: conversation.id,
        role: 'user',
        content: 'Hello',
      );
      await chatService.updateConversationExtras(conversation.id, (extras) {
        extras[Conversation.proactiveCareEnabledOverrideKey] = true;
        extras[Conversation.proactiveCareNextMessageAtKey] = dueAtUtc
            .toIso8601String();
        return extras;
      });

      final flow = ProactiveCareMessageFlow(
        chatService: chatService,
        settings: settings,
        careSender:
            ({
              required config,
              required modelId,
              required messages,
              reasoning = ReasoningRequest.auto,
              topP,
              maxTokens,
              conversationId,
            }) async => 'letter',
        decisionSender:
            ({
              required config,
              required modelId,
              required messages,
              required tools,
              onToolCall,
              reasoning = ReasoningRequest.auto,
              topP,
              maxTokens,
              requestId,
              conversationId,
            }) async => null,
      );

      final delivery = await flow.runSchedule(
        conversationId: conversation.id,
        expectedAt: dueAtLocal,
        assistants: [assistant],
        userNickname: 'User',
      );

      expect(delivery, isNotNull);
      expect(delivery!.successful, isTrue);
    },
  );

  test('care user message embeds the system time', () {
    final now = DateTime(2026, 8, 4, 9, 30);
    final msg = ProactiveCareService.buildCareUserMessage(
      carePrompt: '写一封信',
      now: now,
    );
    expect(msg, startsWith('写一封信'));
    expect(msg, contains(now.toIso8601String()));
  });

  test('historyFromMessages keeps completed user and assistant turns only', () {
    ChatMessage message(
      String role,
      String content, {
      bool streaming = false,
    }) => ChatMessage(
      id: '$role-$content-$streaming',
      role: role,
      content: content,
      conversationId: 'c1',
      isStreaming: streaming,
    );
    final history = ProactiveCareMessageFlow.historyFromMessages([
      message('user', '你好'),
      message('assistant', '  '),
      message('system', 'ignored'),
      message('assistant', '在的', streaming: true),
      message('assistant', '在的'),
    ]);
    expect(history, [
      {'role': 'user', 'content': '你好'},
      {'role': 'assistant', 'content': '在的'},
    ]);
  });
}
