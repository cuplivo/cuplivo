import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import 'package:Cuplivo/core/models/chat_message.dart';
import 'package:Cuplivo/core/services/api/chat_api_service.dart';
import 'package:Cuplivo/core/services/chat/chat_service.dart';
import 'package:Cuplivo/core/services/headless_generation_service.dart';
import 'package:Cuplivo/core/providers/settings_provider.dart';

class _FakeChatService extends ChatService {
  final messagesByConversation = <String, List<ChatMessage>>{};
  final toolEventsByMessage = <String, List<Map<String, dynamic>>>{};
  int _nextMessageId = 1;

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
  Future<void> updateMessage(
    String messageId, {
    String? content,
    int? totalTokens,
    int? contextTokens,
    bool? isStreaming,
    String? reasoningText,
    DateTime? reasoningStartAt,
    DateTime? reasoningFinishedAt,
    String? translation,
    String? reasoningSegmentsJson,
    int? promptTokens,
    int? completionTokens,
    int? cachedTokens,
    int? durationMs,
    Object? groupId = ChatMessage.sentinel,
    Object? subgroupId = ChatMessage.sentinel,
    Object? version = ChatMessage.sentinel,
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
  late _FakeChatService chatService;
  late Map<String, StreamController<ChatStreamChunk>> streamControllers;
  late HeadlessGenerationService service;

  final config = ProviderConfig(
    id: 'test',
    enabled: true,
    name: 'test',
    apiKey: 'test',
    baseUrl: 'https://example.com',
    models: const [],
  );

  StreamController<ChatStreamChunk> controllerFor(String id) =>
      streamControllers.putIfAbsent(
        id,
        () => StreamController<ChatStreamChunk>(),
      );

  void pumpChunk(
    String id,
    String content, {
    List<ToolCallInfo>? calls,
    List<ToolResultInfo>? results,
  }) {
    controllerFor(id).add(
      ChatStreamChunk(
        content: content,
        isDone: false,
        totalTokens: 0,
        toolCalls: calls,
        toolResults: results,
      ),
    );
  }

  Future<void> closeStream(String id) => controllerFor(id).close();

  Future<void> startChild({
    required String id,
    String? parent,
    bool wait = true,
  }) async {
    service.start(
      conversationId: id,
      assistantId: 'assistant-1',
      apiMessages: const [],
      config: config,
      modelId: 'model-1',
      parentConversationId: parent,
      wait: wait,
    );
    // Let `_run` reach its `await for` (after the async addMessage) so the
    // single-subscription test stream is already being listened to.
    await pumpEventQueue();
  }

  setUp(() {
    chatService = _FakeChatService();
    streamControllers = <String, StreamController<ChatStreamChunk>>{};
    service = HeadlessGenerationService(
      chatService: chatService,
      chatStreamProvider:
          ({
            required config,
            required modelId,
            required messages,
            tools,
            onToolCall,
            thinkingBudget,
            temperature,
            topP,
            maxTokens,
            required stream,
            required requestId,
          }) {
            return (streamControllers[requestId] ??=
                    StreamController<ChatStreamChunk>())
                .stream;
          },
    );
  });

  tearDown(() async {
    for (final c in streamControllers.values) {
      await c.close();
    }
  });

  group('HeadlessGenerationService wait-mode', () {
    test(
      'waitFor resolves with the full streamed output on completion',
      () async {
        await startChild(id: 'child-1', parent: 'parent-1');
        final future = service.waitFor('child-1');

        pumpChunk('child-1', 'hello ');
        pumpChunk('child-1', 'world');
        await closeStream('child-1');

        final result = await future;
        expect(result.text, 'hello world');
        expect(result.cancelled, isFalse);
        expect(result.error, isNull);

        final job = service.jobFor('child-1');
        expect(job, isNotNull);
        expect(job!.status, SubagentJobStatus.done);
        expect(job.streamedChars, 11);
        expect(job.isWait, isTrue);
        expect(job.parentConversationId, 'parent-1');
      },
    );

    test('job tracks last tool call and result', () async {
      await startChild(id: 'child-1', parent: 'parent-1');
      final future = service.waitFor('child-1');

      pumpChunk(
        'child-1',
        '',
        calls: [ToolCallInfo(id: 'call-1', name: 'kelivo_read', arguments: {})],
      );
      pumpChunk(
        'child-1',
        '',
        results: [
          ToolResultInfo(
            id: 'call-1',
            name: 'kelivo_read',
            arguments: {},
            content: 'file content',
          ),
        ],
      );
      await closeStream('child-1');
      await future;

      final job = service.jobFor('child-1');
      expect(job!.lastStep, 'kelivo_read');
      expect(job.lastStepKind, SubagentLastStepKind.done);
      expect(job.toolCallCount, 1);
    });

    test(
      'tool events are persisted so tool cards render after completion',
      () async {
        await startChild(id: 'child-1', parent: 'parent-1');
        final future = service.waitFor('child-1');

        pumpChunk(
          'child-1',
          'answer',
          calls: [
            ToolCallInfo(id: 'call-1', name: 'kelivo_read', arguments: {}),
            ToolCallInfo(id: 'call-2', name: 'kelivo_write', arguments: {}),
          ],
        );
        pumpChunk(
          'child-1',
          '',
          results: [
            ToolResultInfo(
              id: 'call-1',
              name: 'kelivo_read',
              arguments: {},
              content: 'file content',
            ),
          ],
        );
        await closeStream('child-1');
        await future;

        final mid = service.jobFor('child-1')!.assistantMessageId!;
        final events = chatService.toolEventsByMessage[mid]!;
        expect(events.length, 2);
        final byId = {for (final e in events) e['id'] as String: e};
        expect(byId['call-1']!['content'], 'file content');
        expect(byId['call-2']!['content'], isNull);
        expect(byId['call-2']!['name'], 'kelivo_write');
      },
    );

    test('reasoning is accumulated and persisted with the message', () async {
      await startChild(id: 'child-1', parent: 'parent-1');
      final future = service.waitFor('child-1');

      streamControllers['child-1']!.add(
        ChatStreamChunk(
          content: '',
          reasoning: 'thinking step 1',
          isDone: false,
          totalTokens: 0,
        ),
      );
      streamControllers['child-1']!.add(
        ChatStreamChunk(
          content: 'final answer',
          reasoning: ' step 2',
          isDone: false,
          totalTokens: 0,
        ),
      );
      await closeStream('child-1');
      await future;

      final messages = chatService.messagesByConversation['child-1']!;
      expect(messages.last.content, 'final answer');
      expect(messages.last.reasoningText, 'thinking step 1 step 2');
      expect(messages.last.isStreaming, isFalse);
      // Timestamps: startAt set at first reasoning chunk, finishedAt at stream
      // end (mirrors the page pipeline semantics). Same-millisecond
      // start/finish is legal under concurrent test-file load, so only
      // assert finishedAt never precedes startAt.
      expect(messages.last.reasoningStartAt, isNotNull);
      expect(messages.last.reasoningFinishedAt, isNotNull);
      expect(
        messages.last.reasoningFinishedAt!.isBefore(
          messages.last.reasoningStartAt!,
        ),
        isFalse,
      );
      // v2 payload with one thinking→content split so rendering interleaves.
      final payload =
          jsonDecode(messages.last.reasoningSegmentsJson!)
              as Map<String, dynamic>;
      expect(payload['v'], 2);
      final segments = (payload['segments'] as List).cast<Map>();
      expect(segments, hasLength(1));
      expect(segments.first['text'], 'thinking step 1 step 2');
      expect(segments.first['expanded'], isFalse);
      final splits = (payload['contentSplits'] as Map).cast<String, dynamic>();
      expect(splits['offsets'], [0]);
      expect(splits['reasoningCounts'], [1]);
      expect(splits['toolCounts'], [0]);
    });

    test(
      'cancel resolves the waiter and unwinds the run like production',
      () async {
        await startChild(id: 'child-1', parent: 'parent-1');
        final future = service.waitFor('child-1');
        pumpChunk('child-1', 'partial');

        service.cancel('child-1');

        final result = await future;
        expect(result.cancelled, isTrue);
        expect(result.text, isEmpty);

        // Production flow: cancelRequest makes the real stream error, the
        // catch persists what streamed so far, and the record is dropped.
        streamControllers['child-1']!.addError(StateError('cancelled'));
        await pumpEventQueue();

        expect(service.jobFor('child-1'), isNull);
        final messages =
            chatService.messagesByConversation['child-1'] ?? const [];
        expect(messages, isNotEmpty);
        expect(messages.last.content, 'partial');
        expect(messages.last.isStreaming, isFalse);
      },
    );

    test('cancelling the parent cascades to wait-mode children only', () async {
      await startChild(id: 'child-wait', parent: 'parent-1', wait: true);
      await startChild(id: 'child-fire', parent: 'parent-1', wait: false);
      final childFuture = service.waitFor('child-wait');
      final orphanFuture = service.waitFor('child-fire');

      service.cancel('parent-1');

      final childResult = await childFuture;
      expect(childResult.cancelled, isTrue);

      // Fire-and-forget sub-agent keeps running: completing its stream does
      // not surface a cancelled result.
      pumpChunk('child-fire', 'still running');
      await closeStream('child-fire');
      final orphanResult = await orphanFuture;
      expect(orphanResult.cancelled, isFalse);
      expect(orphanResult.text, 'still running');
    });

    test(
      'cancelling the parent cascades recursively through the wait chain',
      () async {
        await startChild(id: 'child-wait', parent: 'parent-1', wait: true);
        await startChild(id: 'grandchild', parent: 'child-wait', wait: true);
        final grandFuture = service.waitFor('grandchild');

        service.cancel('parent-1');

        final grandResult = await grandFuture;
        expect(grandResult.cancelled, isTrue);
      },
    );

    test('stream error resolves the waiter with the error', () async {
      await startChild(id: 'child-1', parent: 'parent-1');
      final future = service.waitFor('child-1');
      pumpChunk('child-1', 'before boom');
      streamControllers['child-1']!.addError(StateError('boom'));
      await closeStream('child-1');

      final result = await future;
      expect(result.error, contains('boom'));
      expect(service.jobFor('child-1')!.status, SubagentJobStatus.error);
    });

    test('waitFor on an unknown conversation resolves with an error', () async {
      final result = await service.waitFor('nope');
      expect(result.error, isNotNull);
    });

    test('prepareJob registers the job before generation starts so waitFor '
        'never races the async pipeline', () async {
      // Simulates the engine: the started JSON travels back through pure
      // microtasks while the generation suspends on real I/O. The handler's
      // waitFor must find the record already registered.
      service.prepareJob(
        conversationId: 'child-1',
        parentConversationId: 'parent-1',
        wait: true,
        targetName: 'Research Bot',
      );
      final future = service.waitFor('child-1');

      // Generation starts late and resolves the same record.
      await startChild(id: 'child-1', parent: 'parent-1');
      pumpChunk('child-1', 'result text');
      await closeStream('child-1');

      final result = await future;
      expect(result.text, 'result text');
      expect(result.error, isNull);
      expect(service.jobFor('child-1')!.targetName, 'Research Bot');
    });

    test('cancel before _run starts aborts the generation without '
        'persisting anything', () async {
      service.prepareJob(
        conversationId: 'child-1',
        parentConversationId: 'parent-1',
        wait: true,
      );
      final future = service.waitFor('child-1');

      // User cancels during the engine-side window (between prepareJob and
      // the generation actually starting).
      service.cancel('child-1');
      final result = await future;
      expect(result.cancelled, isTrue);

      // A late start must abort: no placeholder message, job gone, and the
      // status is NOT overwritten to done.
      await startChild(id: 'child-1', parent: 'parent-1');
      expect(
        chatService.messagesByConversation['child-1'] ?? const [],
        isEmpty,
      );
      expect(service.isActive('child-1'), isFalse);
      expect(service.jobFor('child-1'), isNull);
    });

    test('waitJobsFor returns only wait-mode jobs of the parent', () async {
      await startChild(id: 'child-wait', parent: 'parent-1', wait: true);
      await startChild(id: 'child-fire', parent: 'parent-1', wait: false);
      await startChild(id: 'other', parent: 'other-parent', wait: true);

      final jobs = service.waitJobsFor('parent-1');
      expect(jobs.map((j) => j.conversationId), ['child-wait']);
    });
  });
}
