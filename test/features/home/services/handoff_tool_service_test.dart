import 'dart:async';
import 'dart:convert';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:Cuplivo/core/models/assistant.dart';
import 'package:Cuplivo/core/models/chat_message.dart';
import 'package:Cuplivo/core/models/conversation.dart';
import 'package:Cuplivo/core/providers/assistant_provider.dart';
import 'package:Cuplivo/core/providers/instruction_injection_provider.dart';
import 'package:Cuplivo/core/providers/mcp_provider.dart';
import 'package:Cuplivo/core/providers/settings_provider.dart';
import 'package:Cuplivo/core/providers/world_book_provider.dart';
import 'package:Cuplivo/core/services/api/chat_api_service.dart';
import 'package:Cuplivo/core/services/chat/chat_service.dart';
import 'package:Cuplivo/core/services/generation_engine.dart';
import 'package:Cuplivo/core/services/mcp/mcp_tool_service.dart';
import 'package:Cuplivo/features/home/services/ask_user_interaction_service.dart';
import 'package:Cuplivo/features/home/services/handoff_tool_service.dart';
import 'package:Cuplivo/features/home/services/local_tools_service.dart';
import 'package:Cuplivo/features/home/services/tool_approval_service.dart';

class _FakeBuildContext implements BuildContext {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeAssistantProvider extends AssistantProvider {
  _FakeAssistantProvider(this._assistants) : super();

  final List<Assistant> _assistants;

  @override
  List<Assistant> get assistants => List.unmodifiable(_assistants);
}

class _FakeChatService extends ChatService {
  _FakeChatService();

  final messagesByConversation = <String, List<ChatMessage>>{};
  final toolEventsByMessage = <String, List<Map<String, dynamic>>>{};
  int _createdCount = 0;
  int _nextMessageId = 1;

  /// Id of the most recently created conversation (via [createConversation]).
  String? lastCreatedId;

  @override
  List<ChatMessage> getMessages(String conversationId) =>
      List.unmodifiable(messagesByConversation[conversationId] ?? const []);

  @override
  Future<Conversation> createConversation({
    String? title,
    String? assistantId,
    List<String>? mcpServerIds,
    String? parentConversationId,
    String conversationKind = Conversation.kindNormal,
    bool setAsCurrent = true,
  }) async {
    _createdCount++;
    lastCreatedId = 'conv-$_createdCount';
    return Conversation(
      id: lastCreatedId!,
      title: title ?? 'Untitled',
      assistantId: assistantId,
      mcpServerIds: mcpServerIds,
      parentConversationId: parentConversationId,
      conversationKind: conversationKind,
    );
  }

  @override
  String? get currentConversationId => 'parent-conv';

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
  }) async {
    final message = ChatMessage(
      id: 'msg-${_nextMessageId++}',
      role: role,
      content: content,
      conversationId: conversationId,
      totalTokens: totalTokens,
      isStreaming: isStreaming,
    );
    (messagesByConversation[conversationId] ??= []).add(message);
    return message;
  }

  @override
  Future<void> setToolEvents(
    String assistantMessageId,
    List<Map<String, dynamic>> events,
  ) async {
    toolEventsByMessage[assistantMessageId] = List<Map<String, dynamic>>.of(
      events,
    );
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
    Object? translation,
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
  }) async {
    for (final list in messagesByConversation.values) {
      for (int i = 0; i < list.length; i++) {
        if (list[i].id == messageId) {
          list[i] = list[i].copyWith(
            content: content,
            totalTokens: totalTokens,
            contextTokens: contextTokens,
            isStreaming: isStreaming,
            reasoningText: reasoningText,
            reasoningStartAt: reasoningStartAt,
            reasoningFinishedAt: reasoningFinishedAt,
            reasoningSegmentsJson: reasoningSegmentsJson,
          );
        }
      }
    }
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late _FakeChatService chatService;
  late _FakeAssistantProvider assistants;
  late GenerationEngine engine;

  Assistant discoverable(String handoffId, {String? description}) {
    return Assistant(
      id: 'assistant-$handoffId',
      name: 'Assistant $handoffId',
      discoverable: true,
      handoffId: handoffId,
      handoffDescription: description,
    );
  }

  setUp(() {
    chatService = _FakeChatService();
    assistants = _FakeAssistantProvider([
      discoverable('research-bot', description: 'researches topics'),
      discoverable('code-helper'),
    ]);
    engine = GenerationEngine(chatService: chatService);
  });

  Future<String> callTool(
    String name,
    Map<String, dynamic> args, {
    Assistant? delegatingAssistant,
  }) {
    return HandoffToolService.execute(
      toolName: name,
      args: args,
      assistants: assistants,
      chatService: chatService,
      engine: engine,
      delegatingAssistant: delegatingAssistant,
      context: _FakeBuildContext(),
    );
  }

  Map<String, dynamic> decoded(String result) =>
      jsonDecode(result) as Map<String, dynamic>;

  group('HandoffToolService', () {
    test('rejects an empty task', () async {
      final result = await callTool(LocalToolNames.handoffSync, {
        'assistant': 'research-bot',
        'task': '  ',
      });
      final err = decoded(result);
      expect(err['type'], 'tool_error');
      expect(err['error'], 'handoff_empty_task');
      expect((err['message'] as String), contains('task must not be empty'));
    });

    test('rejects an empty assistant target', () async {
      final result = await callTool(LocalToolNames.handoffSync, {
        'assistant': '  ',
        'task': 'do the thing',
      });
      final err = decoded(result);
      expect(err['error'], 'handoff_empty_target');
    });

    test('rejects an unknown target and lists available ones', () async {
      final result = await callTool(LocalToolNames.handoffSync, {
        'assistant': 'nope',
        'task': 'do the thing',
      });
      final err = decoded(result);
      expect(err['type'], 'tool_error');
      expect(err['error'], 'handoff_target_not_found');
      expect((err['message'] as String), contains('research-bot'));
      expect((err['message'] as String), contains('code-helper'));
    });

    test('rejects self-delegation and lists the remaining targets', () async {
      final self = discoverable('self-bot');
      assistants = _FakeAssistantProvider([self, discoverable('research-bot')]);

      final result = await callTool(LocalToolNames.handoffSync, {
        'assistant': 'self-bot',
        'task': 'do the thing',
      }, delegatingAssistant: self);
      final err = decoded(result);
      expect(err['error'], 'handoff_target_not_found');
      final message = err['message'] as String;
      // The requested id appears in the error text itself; the *available*
      // list must not contain the delegating assistant.
      expect(message, contains('Available: [research-bot].'));
    });

    test(
      'wait-mode handoff creates the child with the task as first message',
      () async {
        final result = await callTool(LocalToolNames.handoffSync, {
          'assistant': 'research-bot',
          'task': 'research flutter drift',
        });

        // In this test env the generation pipeline fails synchronously (the
        // fake BuildContext throws on the first provider read); failRound
        // resolves the waiter, so execute returns a subagent_error marker
        // instead of hanging.
        final err = decoded(result);
        expect(err['type'], 'tool_error');
        expect(err['error'], 'subagent_error');

        // The child conversation got the task as its first user message.
        final childId = chatService.lastCreatedId;
        expect(childId, isNotNull);
        expect(chatService.getMessages(childId!), isNotEmpty);
        final messages = chatService.getMessages(childId);
        expect(messages.first.role, 'user');
        expect(messages.first.content, 'research flutter drift');
      },
    );

    test('v1 handoff keeps its prose result shape', () async {
      final result = await callTool(LocalToolNames.handoff, {
        'assistant': 'research-bot',
        'task': 'quick task',
      });
      expect(result, contains('Handoff dispatched. Conversation:'));
      final childId = chatService.lastCreatedId;
      expect(childId, isNotNull);
      expect(
        chatService.messagesByConversation[childId]!.first.content,
        'quick task',
      );
    });

    test('wait-mode waiter resolves with an error when generation fails before '
        'starting — never hangs', () async {
      final result = await callTool(LocalToolNames.handoffSync, {
        'assistant': 'research-bot',
        'task': 'research flutter drift',
      });
      final err = decoded(result);
      expect(err['error'], 'subagent_error');
    });

    testWidgets('wait-mode handoff returns the child full output on success', (
      tester,
    ) async {
      SharedPreferences.setMockInitialValues({});
      final streamControllers = <String, StreamController<ChatStreamChunk>>{};
      final gen = GenerationEngine(
        chatService: chatService,
        streamProvider:
            ({
              required config,
              required modelId,
              required messages,
              userMediaPaths,
              tools,
              onToolCall,
              thinkingBudget,
              temperature,
              topP,
              maxTokens,
              extraHeaders,
              extraBody,
              required stream,
              String? requestId,
              required allowImagesApiRouting,
              required ocrActive,
              partialImageNotice,
            }) {
              return (streamControllers[requestId ?? ''] ??=
                      StreamController<ChatStreamChunk>())
                  .stream;
            },
      );

      await tester.pumpWidget(
        MultiProvider(
          providers: [
            ChangeNotifierProvider(create: (_) => SettingsProvider()),
            ChangeNotifierProvider(create: (_) => AssistantProvider()),
            ChangeNotifierProvider(
              create: (_) => McpProvider(
                contextProvider: () => throw UnimplementedError(),
              ),
            ),
            ChangeNotifierProvider(create: (_) => McpToolService()),
            ChangeNotifierProvider(create: (_) => ToolApprovalService()),
            ChangeNotifierProvider(create: (_) => AskUserInteractionService()),
            // The message pipeline falls back to disk stores when these
            // providers are absent; they must exist so the fake-async test
            // does not suspend on real file I/O.
            ChangeNotifierProvider(
              create: (_) => InstructionInjectionProvider(),
            ),
            ChangeNotifierProvider(
              create: (_) => WorldBookProvider(chatService: chatService),
            ),
          ],
          child: Builder(builder: (context) => const SizedBox.shrink()),
        ),
      );
      final context = tester.element(find.byType(SizedBox));

      final future = HandoffToolService.execute(
        toolName: LocalToolNames.handoffSync,
        args: {'assistant': 'research-bot', 'task': 'research flutter drift'},
        assistants: assistants,
        chatService: chatService,
        engine: gen,
        context: context,
      );

      // Let the pipeline reach the child generation's stream listen.
      // Pump with time deltas: some pipeline hops (provider/store
      // initialization) fire zero-duration timers that only run when fake
      // time advances.
      for (var i = 0; i < 20; i++) {
        await tester.pump(const Duration(milliseconds: 10));
      }

      // The engine streams into the pre-created assistant placeholder and
      // keys its stream provider by the placeholder's message id (not the
      // conversation id).
      final childId = chatService.lastCreatedId!;
      final placeholderId =
          chatService.messagesByConversation[childId]!.last.id;
      streamControllers[placeholderId]!.add(
        ChatStreamChunk(content: 'final answer', isDone: false, totalTokens: 0),
      );
      await streamControllers[placeholderId]!.close();

      final result = await future;
      expect(result, 'final answer');
      await tester.pump();
    });

    test('handoff tools are gated per assistant localToolIds', () async {
      // A disabled tool must never be routed here; the handler gate lives in
      // ToolHandlerService, but the definition builder must not emit the
      // tool when the id is absent.
      final defs = LocalToolsService.buildToolDefinitions(
        assistant: Assistant(id: 'a1', name: 'Assistant'),
        supportsTools: true,
        discoverableAssistants: assistants.assistants,
      );
      expect(defs, isEmpty);
    });
  });
}
