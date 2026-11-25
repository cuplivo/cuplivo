import 'dart:async';
import 'dart:io';

import 'package:Cuplivo/core/database/app_database.dart';
import 'package:Cuplivo/core/database/business_preferences.dart';
import 'package:Cuplivo/core/database/business_repository.dart';
import 'package:Cuplivo/core/database/chat_database_repository.dart';
import 'package:Cuplivo/core/models/assistant.dart';
import 'package:Cuplivo/core/models/chat_message.dart';
import 'package:Cuplivo/core/models/conversation.dart';
import 'package:Cuplivo/core/models/conversation_prompt_settings.dart';
import 'package:Cuplivo/core/models/reasoning_request.dart';
import 'package:Cuplivo/core/models/world_book.dart';
import 'package:Cuplivo/core/providers/settings_provider.dart';
import 'package:Cuplivo/core/services/chat/chat_service.dart';
import 'package:Cuplivo/core/services/proactive_care_decision_tools.dart';
import 'package:Cuplivo/core/services/proactive_care_message_flow.dart';
import 'package:Cuplivo/core/services/proactive_care_service.dart';
import 'package:Cuplivo/core/services/world_book_store.dart';
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

  test('a stalled letter fails at the deadline', () async {
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
    final stalled = Completer<String>();
    var decisionCalls = 0;
    final flow = ProactiveCareMessageFlow(
      chatService: chatService,
      settings: settings,
      letterTimeout: const Duration(milliseconds: 20),
      careSender:
          ({
            required config,
            required modelId,
            required messages,
            reasoning = ReasoningRequest.auto,
            topP,
            maxTokens,
            conversationId,
          }) => stalled.future,
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
            decisionCalls++;
            return null;
          },
    );

    final delivery = await flow.runSchedule(
      conversationId: conversation.id,
      expectedAt: dueAt,
      assistants: [assistant],
      userNickname: 'User',
    );

    expect(delivery, isNotNull);
    expect(delivery!.successful, isFalse);
    // The claim was consumed, so the stalled letter is not silently retried.
    final remaining = chatService.getConversation(conversation.id);
    expect(remaining!.proactiveCareNextMessageAt, isNull);
    // Nothing was written and the trailing decision never ran.
    final letters = await chatService.loadMessages(conversation.id);
    expect(letters.where((m) => m.role == 'assistant'), isEmpty);
    expect(decisionCalls, 0);

    // A request that answers after the deadline must not resurrect the letter:
    // `Future.timeout` ignores its result.
    stalled.complete('late letter');
    await Future<void>.delayed(Duration.zero);
    final lettersLater = await chatService.loadMessages(conversation.id);
    expect(lettersLater.where((m) => m.role == 'assistant'), isEmpty);
  });

  test(
    'runSchedule hands the persisted letter to the UI before the decision call',
    () async {
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
      final events = <String>[];
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
              events.add('care');
              return 'letter';
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
              events.add('decision');
              return null;
            },
        onLetterPersisted: (conversationId) async {
          final messages = await chatService.loadMessages(conversationId);
          events.add(
            'persisted:${messages.where((m) => m.role == 'assistant').length}',
          );
        },
      );

      final delivery = await flow.runSchedule(
        conversationId: conversation.id,
        expectedAt: dueAt,
        assistants: [assistant],
        userNickname: 'User',
      );

      expect(delivery, isNotNull);
      expect(delivery!.successful, isTrue);
      // The letter is durable when the refresh runs, and the refresh runs
      // before the trailing decision round trip can delay the on-screen letter
      // (the decision call itself may retry once with the tool-only directive).
      expect(events.take(2), ['care', 'persisted:1']);
      expect(events.skip(2), everyElement('decision'));
    },
  );

  test('a throwing refresh callback never costs the letter', () async {
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
      onLetterPersisted: (_) async => throw StateError('refresh exploded'),
    );

    final delivery = await flow.runSchedule(
      conversationId: conversation.id,
      expectedAt: dueAt,
      assistants: [assistant],
      userNickname: 'User',
    );

    expect(delivery, isNotNull);
    expect(delivery!.successful, isTrue);
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

  test(
    'care injects only the world book entries the context activates',
    () async {
      final store = WorldBookStore(
        BusinessPreferences(BusinessRepository(database)),
      );
      await store.save([
        WorldBook(
          id: 'enabled-book',
          name: 'enabled',
          entries: const [
            WorldBookEntry(
              id: 'always',
              content: 'CONST-LORE',
              constantActive: true,
            ),
            WorldBookEntry(
              id: 'hit',
              content: 'KEYWORD-LORE',
              keywords: ['晚饭'],
            ),
            WorldBookEntry(
              id: 'miss',
              content: 'UNMATCHED-LORE',
              keywords: ['午饭'],
            ),
            WorldBookEntry(
              id: 'off',
              content: 'DISABLED-ENTRY',
              enabled: false,
              constantActive: true,
            ),
          ],
        ),
        WorldBook(
          id: 'disabled-book',
          name: 'old',
          enabled: false,
          entries: const [
            WorldBookEntry(
              id: 'old-entry',
              content: 'OLD-DISABLED-BOOK-LORE',
              constantActive: true,
            ),
          ],
        ),
      ]);
      await store.setActiveIds([
        'enabled-book',
        'disabled-book',
      ], assistantId: 'a');

      final flow = ProactiveCareMessageFlow(
        chatService: chatService,
        settings: settings,
        worldBookStore: store,
      );
      final messages = await flow.buildCareApiMessages(
        assistant: Assistant(id: 'a', name: 'A'),
        modelId: 'gpt-test',
        userNickname: 'User',
        history: [
          {'role': 'user', 'content': '今天晚饭吃什么'},
          {'role': 'assistant', 'content': '还没想好'},
        ],
        carePrompt: '主动找我聊天',
        now: DateTime.now(),
      );

      final system = (messages.first['content'] ?? '').toString();
      expect(system, contains('CONST-LORE'));
      expect(system, contains('KEYWORD-LORE'));
      expect(system, isNot(contains('UNMATCHED-LORE')));
      expect(system, isNot(contains('DISABLED-ENTRY')));
      expect(
        system,
        isNot(contains('OLD-DISABLED-BOOK-LORE')),
        reason:
            'a disabled book never participates, even while bound as active',
      );
    },
  );

  test(
    'a delayed world book entry counts the conversation, not the window',
    () async {
      final store = WorldBookStore(
        BusinessPreferences(BusinessRepository(database)),
      );
      await store.save([
        WorldBook(
          id: 'paced',
          name: 'paced',
          entries: const [
            WorldBookEntry(
              id: 'late',
              content: 'DELAYED-LORE',
              constantActive: true,
              delay: 5,
            ),
          ],
        ),
      ]);
      await store.setActiveIds(['paced'], assistantId: 'a');

      final flow = ProactiveCareMessageFlow(
        chatService: chatService,
        settings: settings,
        worldBookStore: store,
      );
      final messages = await flow.buildCareApiMessages(
        assistant: Assistant(id: 'a', name: 'A', contextMessageSize: 2),
        modelId: 'gpt-test',
        userNickname: 'User',
        history: const [
          {'role': 'user', 'content': 'm1'},
          {'role': 'assistant', 'content': 'm2'},
          {'role': 'user', 'content': 'm3'},
          {'role': 'assistant', 'content': 'm4'},
          {'role': 'user', 'content': 'm5'},
          {'role': 'assistant', 'content': 'm6'},
        ],
        carePrompt: '主动找我聊天',
        now: DateTime.now(),
      );

      // The conversation is six messages old, so the delay has elapsed; counting
      // the two-message window instead would suppress the entry for every letter.
      final system = (messages.first['content'] ?? '').toString();
      expect(system, contains('DELAYED-LORE'));
    },
  );

  test(
    'a conversation-scoped world book list replaces the assistant one',
    () async {
      final store = WorldBookStore(
        BusinessPreferences(BusinessRepository(database)),
      );
      await store.save([
        WorldBook(
          id: 'assistant-book',
          name: 'assistant',
          entries: const [
            WorldBookEntry(
              id: 'assistant-entry',
              content: 'ASSISTANT-LORE',
              constantActive: true,
            ),
          ],
        ),
        WorldBook(
          id: 'scoped-book',
          name: 'scoped',
          entries: const [
            WorldBookEntry(
              id: 'scoped-entry',
              content: 'SCOPED-LORE',
              constantActive: true,
            ),
          ],
        ),
      ]);
      await store.setActiveIds(['assistant-book'], assistantId: 'a');

      final flow = ProactiveCareMessageFlow(
        chatService: chatService,
        settings: settings,
        worldBookStore: store,
      );
      Future<String> system(List<String>? bookIds) async {
        final messages = await flow.buildCareApiMessages(
          assistant: Assistant(id: 'a', name: 'A'),
          modelId: 'gpt-test',
          userNickname: 'User',
          history: const [
            {'role': 'user', 'content': 'm1'},
            {'role': 'assistant', 'content': 'm2'},
          ],
          carePrompt: '主动找我聊天',
          now: DateTime.now(),
          bookIds: bookIds,
        );
        return (messages.first['content'] ?? '').toString();
      }

      expect(await system(null), contains('ASSISTANT-LORE'));
      expect(await system(const ['scoped-book']), contains('SCOPED-LORE'));
      expect(
        await system(const ['scoped-book']),
        isNot(contains('ASSISTANT-LORE')),
      );
      // An empty override is "no books", the way the chat path reads it.
      expect(await system(const []), isNot(contains('ASSISTANT-LORE')));
    },
  );

  test(
    'the letter follows the assistant unless the conversation scopes books',
    () {
      final conversation = Conversation(
        id: 'c',
        title: 't',
        extras: {
          ConversationPromptSettings.worldBookIdsKey: ['scoped-book'],
        },
      );
      expect(
        ProactiveCareMessageFlow.scopedWorldBookIds(
          Assistant(id: 'a', name: 'A', allowConversationPromptInjection: true),
          conversation,
        ),
        ['scoped-book'],
      );
      expect(
        ProactiveCareMessageFlow.scopedWorldBookIds(
          Assistant(id: 'a', name: 'A'),
          conversation,
        ),
        isNull,
      );
    },
  );

  test('the care prompt is never part of the trimmed history window', () async {
    final flow = ProactiveCareMessageFlow(
      chatService: chatService,
      settings: settings,
    );
    Future<List<Map<String, dynamic>>> care(int limit) =>
        flow.buildCareApiMessages(
          assistant: Assistant(id: 'a', name: 'A', contextMessageSize: limit),
          modelId: 'gpt-test',
          userNickname: 'User',
          history: const [
            {'role': 'user', 'content': 'm1'},
            {'role': 'assistant', 'content': 'm2'},
            {'role': 'user', 'content': 'm3'},
            {'role': 'assistant', 'content': 'm4'},
            {'role': 'user', 'content': 'm5'},
            {'role': 'assistant', 'content': 'm6'},
          ],
          carePrompt: '主动找我聊天',
          now: DateTime.now(),
        );

    // A window of one used to consume the care prompt itself, leaving an empty
    // request (or a system-only one); either way the letter had no instruction.
    final smallest = await care(1);
    expect(smallest.length, greaterThanOrEqualTo(2));
    expect(smallest.last['role'], 'user');
    expect((smallest.last['content'] ?? '').toString(), contains('主动找我聊天'));

    // The window starts on a user turn instead of opening on a model turn.
    final three = await care(3);
    expect(three.first['role'], 'user');
    expect(three.first['content'], 'm3');
    expect(three.last['content'], contains('主动找我聊天'));
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
