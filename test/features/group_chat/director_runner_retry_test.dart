import 'dart:async';
import 'dart:convert';

import 'package:Cuplivo/core/models/assistant.dart';
import 'package:Cuplivo/core/models/auto_retry_options.dart';
import 'package:Cuplivo/core/models/chat_message.dart';
import 'package:Cuplivo/core/models/group_chat.dart';
import 'package:Cuplivo/core/models/group_chat_director_log.dart';
import 'package:Cuplivo/core/providers/settings_provider.dart';
import 'package:Cuplivo/core/services/api/chat_api_service.dart';
import 'package:Cuplivo/core/services/chat/chat_service.dart';
import 'package:Cuplivo/features/group_chat/services/director_context_builder.dart';
import 'package:Cuplivo/features/group_chat/services/director_runner.dart';
import 'package:Cuplivo/features/group_chat/services/director_tool_protocol.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:Cuplivo/core/database/business_preferences.dart';

var businessPrefs = BusinessPreferences.memoryForTests();

/// Captures the tool-call handler and lets the test drive the stream.
class _FakeDirectorTransport {
  final StreamController<ChatStreamChunk> controller =
      StreamController<ChatStreamChunk>();
  ToolCallHandler? toolCallHandler;
  bool subscriptionCancelled = false;

  _FakeDirectorTransport() {
    controller.onCancel = () {
      subscriptionCancelled = true;
    };
  }

  Stream<ChatStreamChunk> send({
    required ProviderConfig config,
    required String modelId,
    required List<Map<String, dynamic>> messages,
    List<String>? userMediaPaths,
    int? thinkingBudget,
    double? temperature,
    double? topP,
    int? maxTokens,
    List<Map<String, dynamic>>? tools,
    ToolCallHandler? onToolCall,
    Map<String, String>? extraHeaders,
    Map<String, dynamic>? extraBody,
    bool stream = true,
    String? requestId,
    bool allowImagesApiRouting = true,
    bool ocrActive = false,
    AutoRetryOptions? retryOverride,
  }) {
    toolCallHandler = onToolCall;
    return controller.stream;
  }
}

class _SequencedDirectorTransport {
  final List<StreamController<ChatStreamChunk>> controllers = [];
  final List<Completer<StreamController<ChatStreamChunk>>> _waiters = [];

  Stream<ChatStreamChunk> send({
    required ProviderConfig config,
    required String modelId,
    required List<Map<String, dynamic>> messages,
    List<String>? userMediaPaths,
    int? thinkingBudget,
    double? temperature,
    double? topP,
    int? maxTokens,
    List<Map<String, dynamic>>? tools,
    ToolCallHandler? onToolCall,
    Map<String, String>? extraHeaders,
    Map<String, dynamic>? extraBody,
    bool stream = true,
    String? requestId,
    bool allowImagesApiRouting = true,
    bool ocrActive = false,
    AutoRetryOptions? retryOverride,
  }) {
    final controller = StreamController<ChatStreamChunk>();
    controllers.add(controller);
    if (_waiters.isNotEmpty) {
      _waiters.removeAt(0).complete(controller);
    }
    return controller.stream;
  }

  Future<StreamController<ChatStreamChunk>> waitForController(int index) {
    if (controllers.length > index) {
      return Future.value(controllers[index]);
    }
    final completer = Completer<StreamController<ChatStreamChunk>>();
    _waiters.add(completer);
    return completer.future;
  }

  Future<void> close() async {
    for (final controller in controllers) {
      await controller.close();
    }
  }
}

void main() {
  late _FakeDirectorTransport transport;
  late DirectorRunner runner;
  late GroupChat group;

  setUp(() {
    businessPrefs = BusinessPreferences.memoryForTests();
    businessPrefs = BusinessPreferences.memoryForTests({});
    transport = _FakeDirectorTransport();
    runner = DirectorRunner(
      chatService: ChatService(),
      contextBuilder: DirectorContextBuilder(chatService: ChatService()),
      sendMessageStream: transport.send,
    );
    group = GroupChat(
      name: 'test group',
      conversationId: 'conversation-1',
      directorModelProvider: 'TestProvider',
      directorModelId: 'test-model',
    );
  });

  tearDown(() {
    transport.controller.close();
  });

  Future<DirectorDecision> runDirector({
    DirectorRuntimeLogSink? onRuntimeLog,
    String? sourceMessageId,
  }) {
    final assistants = <Assistant>[
      Assistant(id: 'a1', name: 'Alpha'),
      Assistant(id: 'a2', name: 'Beta'),
    ];
    return runner.run(
      group: group,
      newUserContent: '[user]: hi',
      rosterAssistants: assistants,
      userName: 'user',
      memberNames: const <String>['user', 'Alpha', 'Beta'],
      settings: SettingsProvider(preferences: businessPrefs),
      modelSupportsTools: (providerKey, modelId) => true,
      publicMessages: const <ChatMessage>[],
      versionSelections: const <String, int>{},
      assistantsById: {for (final a in assistants) a.id: a},
      sourceMessageId: sourceMessageId,
      onRuntimeLog: onRuntimeLog,
    );
  }

  test('first tool call returns a neutral result and cancels the stream '
      'immediately', () async {
    GroupChatDirectorRuntimeLog? runtimeLog;
    final future = runDirector(
      sourceMessageId: 'source-user',
      onRuntimeLog: (log) => runtimeLog = log,
    );

    transport.controller.add(
      ChatStreamChunk(
        content: '',
        isDone: false,
        totalTokens: 0,
        toolCalls: <ToolCallInfo>[
          ToolCallInfo(
            id: 't1',
            name: DirectorTools.selectSpeaker,
            arguments: const <String, dynamic>{'assistant_id': 'a1'},
          ),
        ],
      ),
    );
    transport.controller.add(
      ChatStreamChunk(content: '', isDone: true, totalTokens: 0),
    );

    final decision = await future.timeout(const Duration(seconds: 5));
    expect(decision.kind, DirectorDecisionKind.selectSpeaker);
    expect(decision.assistantId, 'a1');

    await pumpEventQueue();
    expect(transport.subscriptionCancelled, isTrue);

    final handler = transport.toolCallHandler;
    expect(handler, isNotNull);
    final result = await handler!(
      DirectorTools.selectSpeaker,
      const <String, dynamic>{'assistant_id': 'a1'},
      toolCallId: 't2',
    );
    final decoded = jsonDecode(result) as Map<String, dynamic>;
    expect(decoded['ok'], isTrue);
    expect(result, isNot(contains('ignored')));
    expect(runtimeLog, isNotNull);
    expect(runtimeLog!.sourceMessageId, 'source-user');
    expect(runtimeLog!.attemptCount, 1);
    expect(runtimeLog!.decisionKind, 'selectSpeaker');
    expect(runtimeLog!.attemptErrors, isEmpty);
  });

  test(
    'follow-up tool calls in the same stream stay neutral (no retry bait)',
    () async {
      final future = runDirector();

      transport.controller.add(
        ChatStreamChunk(
          content: '',
          isDone: false,
          totalTokens: 0,
          toolCalls: <ToolCallInfo>[
            ToolCallInfo(
              id: 't1',
              name: DirectorTools.selectSpeaker,
              arguments: const <String, dynamic>{'assistant_id': 'a1'},
            ),
          ],
        ),
      );
      final decision = await future.timeout(const Duration(seconds: 5));
      expect(decision.assistantId, 'a1');

      // Provider keeps sending follow-up calls before the cancel lands.
      final handler = transport.toolCallHandler!;
      final first = await handler(
        DirectorTools.selectSpeaker,
        const <String, dynamic>{'assistant_id': 'a2'},
        toolCallId: 't2',
      );
      final second = await handler(
        DirectorTools.endTurn,
        const <String, dynamic>{'reason': 'x'},
        toolCallId: 't3',
      );
      expect(first, isNot(contains('ignored')));
      expect(second, isNot(contains('ignored')));
      expect(jsonDecode(first)['ok'], isTrue);
      expect(jsonDecode(second)['ok'], isTrue);
    },
  );

  test('a failed first call is retried and emits one runtime record', () async {
    final sequenced = _SequencedDirectorTransport();
    final retryRunner = DirectorRunner(
      chatService: ChatService(),
      contextBuilder: DirectorContextBuilder(chatService: ChatService()),
      sendMessageStream: sequenced.send,
    );
    final logs = <GroupChatDirectorRuntimeLog>[];
    final future = retryRunner.run(
      group: group,
      newUserContent: '[user]: hi',
      rosterAssistants: [Assistant(id: 'a1', name: 'Alpha')],
      userName: 'user',
      memberNames: const <String>['user', 'Alpha'],
      settings: SettingsProvider(preferences: businessPrefs),
      modelSupportsTools: (providerKey, modelId) => true,
      publicMessages: const <ChatMessage>[],
      versionSelections: const <String, int>{},
      assistantsById: <String, Assistant>{
        'a1': Assistant(id: 'a1', name: 'Alpha'),
      },
      sourceMessageId: 'source-assistant',
      trigger: GroupChatDirectorLogTrigger.assistant,
      onRuntimeLog: logs.add,
    );

    final first = await sequenced.waitForController(0);
    first.addError(StateError('first call failed'));
    final retry = await sequenced.waitForController(1);
    retry.add(
      ChatStreamChunk(
        content: '',
        isDone: false,
        totalTokens: 0,
        toolCalls: <ToolCallInfo>[
          ToolCallInfo(
            id: 'retry-tool',
            name: DirectorTools.endTurn,
            arguments: const <String, dynamic>{'reason': 'retry worked'},
          ),
        ],
      ),
    );

    final decision = await future.timeout(const Duration(seconds: 5));
    expect(decision.kind, DirectorDecisionKind.endTurn);
    expect(logs, hasLength(1));
    expect(logs.single.attemptCount, 2);
    expect(logs.single.attemptErrors, hasLength(1));
    expect(logs.single.attemptErrors.single, contains('first call failed'));
    expect(logs.single.failure, isNull);

    await sequenced.close();
  });

  test('free-text fallback is included in the runtime record', () async {
    final sequenced = _SequencedDirectorTransport();
    final fallbackRunner = DirectorRunner(
      chatService: ChatService(),
      contextBuilder: DirectorContextBuilder(chatService: ChatService()),
      sendMessageStream: sequenced.send,
    );
    final logs = <GroupChatDirectorRuntimeLog>[];
    final future = fallbackRunner.run(
      group: group,
      newUserContent: '[user]: hi',
      rosterAssistants: [Assistant(id: 'a1', name: 'Alpha')],
      userName: 'user',
      memberNames: const <String>['user', 'Alpha'],
      settings: SettingsProvider(preferences: businessPrefs),
      modelSupportsTools: (providerKey, modelId) => true,
      publicMessages: const <ChatMessage>[],
      versionSelections: const <String, int>{},
      assistantsById: <String, Assistant>{
        'a1': Assistant(id: 'a1', name: 'Alpha'),
      },
      sourceMessageId: 'source-fallback',
      onRuntimeLog: logs.add,
    );

    final first = await sequenced.waitForController(0);
    first.add(
      ChatStreamChunk(content: 'silence', isDone: false, totalTokens: 1),
    );
    await first.close();
    final retry = await sequenced.waitForController(1);
    retry.add(
      ChatStreamChunk(content: 'silence', isDone: false, totalTokens: 1),
    );
    await retry.close();

    final decision = await future.timeout(const Duration(seconds: 5));
    expect(decision.kind, DirectorDecisionKind.endTurn);
    expect(decision.fallback, isTrue);
    expect(logs, hasLength(1));
    expect(logs.single.attemptCount, 2);
    expect(logs.single.fallback, isTrue);
    expect(logs.single.freeText, 'silence');

    await sequenced.close();
  });

  test(
    'configuration failures are recorded once without a model request',
    () async {
      final logs = <GroupChatDirectorRuntimeLog>[];
      final noModelGroup = GroupChat(
        name: 'test group',
        conversationId: 'conversation-1',
      );

      await expectLater(
        runner.run(
          group: noModelGroup,
          newUserContent: '[user]: hi',
          rosterAssistants: [Assistant(id: 'a1', name: 'Alpha')],
          userName: 'user',
          memberNames: const <String>['user', 'Alpha'],
          settings: SettingsProvider(preferences: businessPrefs),
          modelSupportsTools: (providerKey, modelId) => true,
          publicMessages: const <ChatMessage>[],
          versionSelections: const <String, int>{},
          assistantsById: <String, Assistant>{
            'a1': Assistant(id: 'a1', name: 'Alpha'),
          },
          sourceMessageId: 'source-no-model',
          onRuntimeLog: logs.add,
        ),
        throwsA(isA<DirectorSoftError>()),
      );

      expect(logs, hasLength(1));
      expect(logs.single.failure, 'no_model');
      expect(logs.single.attemptCount, 0);
    },
  );

  test('tool capability failures are recorded once', () async {
    final logs = <GroupChatDirectorRuntimeLog>[];

    await expectLater(
      runner.run(
        group: group,
        newUserContent: '[user]: hi',
        rosterAssistants: [Assistant(id: 'a1', name: 'Alpha')],
        userName: 'user',
        memberNames: const <String>['user', 'Alpha'],
        settings: SettingsProvider(preferences: businessPrefs),
        modelSupportsTools: (providerKey, modelId) => false,
        publicMessages: const <ChatMessage>[],
        versionSelections: const <String, int>{},
        assistantsById: <String, Assistant>{
          'a1': Assistant(id: 'a1', name: 'Alpha'),
        },
        sourceMessageId: 'source-no-tools',
        onRuntimeLog: logs.add,
      ),
      throwsA(isA<DirectorSoftError>()),
    );
    expect(logs, hasLength(1));
    expect(logs.single.failure, 'no_tools');
  });
}
