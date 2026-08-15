import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import 'package:Cuplivo/core/models/assistant.dart';
import 'package:Cuplivo/core/models/assistant_regex.dart';
import 'package:Cuplivo/core/models/chat_message.dart';
import 'package:Cuplivo/core/services/api/chat_api_service.dart';
import 'package:Cuplivo/core/services/chat/chat_service.dart';
import 'package:Cuplivo/core/services/generation_engine.dart';
import 'package:Cuplivo/core/services/streaming_content_notifier.dart';
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

  @override
  Future<void> deleteMessage(String messageId) async {
    for (final list in messagesByConversation.values) {
      list.removeWhere((m) => m.id == messageId);
    }
  }
}

void main() {
  late _FakeChatService chatService;
  late Map<String, StreamController<ChatStreamChunk>> streamControllers;
  late GenerationEngine service;

  /// Conversation id -> placeholder message id (the engine keys streams by
  /// the slot messageId — requestId — not the conversation id).
  final midFor = <String, String>{};

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
    String? reasoning,
  }) {
    controllerFor(midFor[id] ?? id).add(
      ChatStreamChunk(
        content: content,
        isDone: false,
        totalTokens: 0,
        toolCalls: calls,
        toolResults: results,
        reasoning: reasoning,
      ),
    );
  }

  Future<void> closeStream(String id) =>
      controllerFor(midFor[id] ?? id).close();

  /// Mirrors the engine server: wait-mode creates the placeholder + round
  /// synchronously, then startRound attaches the request and runs.
  Future<String> startChild({
    required String id,
    String? parent,
    bool wait = true,
  }) async {
    final placeholder = await chatService.addMessage(
      conversationId: id,
      role: 'assistant',
      content: '',
      isStreaming: true,
    );
    midFor[id] = placeholder.id;
    service.prepareRound(
      conversationId: id,
      assistantMessageId: placeholder.id,
      parentConversationId: parent,
      wait: wait,
    );
    service.startRound(
      conversationId: id,
      slots: [
        GenerationSlotRequest(
          assistantMessageId: placeholder.id,
          apiMessages: const [],
          config: config,
          modelId: 'model-1',
        ),
      ],
      parentConversationId: parent,
      wait: wait,
    );
    // Let `_runSlot` reach its `await for` so the single-subscription test
    // stream is already being listened to.
    await pumpEventQueue();
    return placeholder.id;
  }

  setUp(() {
    chatService = _FakeChatService();
    streamControllers = <String, StreamController<ChatStreamChunk>>{};
    service = GenerationEngine(
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
            required allowImagesApiRouting,
            required ocrActive,
            partialImageNotice,
          }) {
            return (streamControllers[requestId ?? ''] ??=
                    StreamController<ChatStreamChunk>())
                .stream;
          },
    );
  });

  tearDown(() async {
    for (final c in streamControllers.values) {
      // Skip controllers the test already closed: a second close() on an
      // already-closed controller hangs under testWidgets fake-async.
      if (!c.isClosed) {
        await c.close();
      }
    }
  });

  group('GenerationEngine wait-mode', () {
    test(
      'waitFor resolves with the full streamed output on completion',
      () async {
        await startChild(id: 'child-1', parent: 'parent-1');
        // Capture the slot reference before completion: the engine drops
        // round/slot records after they settle.
        final slot = service.slotFor('child-1')!;
        final future = service.waitFor('child-1');

        pumpChunk('child-1', 'hello ');
        pumpChunk('child-1', 'world');
        await closeStream('child-1');

        final result = await future;
        expect(result.text, 'hello world');
        expect(result.cancelled, isFalse);
        expect(result.error, isNull);

        expect(slot.status, SlotStatus.done);
        expect(slot.streamedChars, 11);
        expect(slot.isWait, isTrue);
        expect(slot.parentConversationId, 'parent-1');
      },
    );

    test('slot tracks last tool call and result', () async {
      await startChild(id: 'child-1', parent: 'parent-1');
      final slot = service.slotFor('child-1')!;
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

      expect(slot.lastStep, 'kelivo_read');
      expect(slot.lastStepKind, SlotLastStepKind.done);
      expect(slot.toolCallCount, 1);
    });

    test(
      'tool events are persisted so tool cards render after completion',
      () async {
        final mid = await startChild(id: 'child-1', parent: 'parent-1');
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

      streamControllers[midFor['child-1']]!.add(
        ChatStreamChunk(
          content: '',
          reasoning: 'thinking step 1',
          isDone: false,
          totalTokens: 0,
        ),
      );
      streamControllers[midFor['child-1']]!.add(
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
      'multi-round tool-call reasoning persists per-round segments and splits '
      '(issue #254)',
      () async {
        await startChild(id: 'child-1', parent: 'parent-1');
        final future = service.waitFor('child-1');

        // think₁ → tool₁ (call+result) → think₂ → tool₂ (call+result) → body
        pumpChunk('child-1', '', reasoning: 'first analysis');
        pumpChunk(
          'child-1',
          '',
          calls: [
            ToolCallInfo(id: 'call-1', name: 'kelivo_read', arguments: {}),
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
        pumpChunk('child-1', '', reasoning: 'second analysis');
        pumpChunk(
          'child-1',
          '',
          calls: [
            ToolCallInfo(id: 'call-2', name: 'kelivo_write', arguments: {}),
          ],
        );
        pumpChunk(
          'child-1',
          '',
          results: [
            ToolResultInfo(
              id: 'call-2',
              name: 'kelivo_write',
              arguments: {},
              content: 'written',
            ),
          ],
        );
        pumpChunk('child-1', 'final body');
        await closeStream('child-1');
        await future;

        final messages = chatService.messagesByConversation['child-1']!;
        final payload =
            jsonDecode(messages.last.reasoningSegmentsJson!)
                as Map<String, dynamic>;
        final segments = (payload['segments'] as List).cast<Map>();
        expect(segments, hasLength(2));
        expect(segments[0]['text'], 'first analysis');
        expect(segments[0]['toolStartIndex'], 0);
        expect(segments[0]['finishedAt'], isNotNull);
        expect(segments[1]['text'], 'second analysis');
        // think₂ came after tool₁, so it starts after the first tool.
        expect(segments[1]['toolStartIndex'], 1);
        expect(segments[1]['finishedAt'], isNotNull);
        final splits = (payload['contentSplits'] as Map)
            .cast<String, dynamic>();
        expect(splits['offsets'], [0]);
        // Both thinking rounds precede the body.
        expect(splits['reasoningCounts'], [2]);
        expect(splits['toolCounts'], [2]);
      },
    );

    test(
      'content between tool rounds records a split per episode (issue #254)',
      () async {
        await startChild(id: 'child-1', parent: 'parent-1');
        final future = service.waitFor('child-1');

        // think → body₁ → tool → body₂: two thinking→content episodes.
        pumpChunk('child-1', '', reasoning: 'thinking');
        pumpChunk('child-1', 'intro ');
        pumpChunk(
          'child-1',
          '',
          calls: [
            ToolCallInfo(id: 'call-1', name: 'kelivo_read', arguments: {}),
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
        pumpChunk('child-1', 'body');
        await closeStream('child-1');
        await future;

        final messages = chatService.messagesByConversation['child-1']!;
        final payload =
            jsonDecode(messages.last.reasoningSegmentsJson!)
                as Map<String, dynamic>;
        final splits = (payload['contentSplits'] as Map)
            .cast<String, dynamic>();
        // First split at content start (0); second split after "intro "
        // (6 chars), before the tool.
        expect(splits['offsets'], [0, 6]);
        expect(splits['reasoningCounts'], [1, 1]);
        expect(splits['toolCounts'], [0, 1]);
      },
    );

    test(
      'cancel resolves the waiter and unwinds the run like production',
      () async {
        await startChild(id: 'child-1', parent: 'parent-1');
        final future = service.waitFor('child-1');
        pumpChunk('child-1', 'partial');

        service.cancelConversation('child-1');

        final result = await future;
        expect(result.cancelled, isTrue);
        expect(result.text, isEmpty);

        // Production flow: cancelRequest makes the real stream error, the
        // catch persists what streamed so far, and the record is dropped.
        streamControllers[midFor['child-1']]!.addError(StateError('cancelled'));
        await pumpEventQueue();

        expect(service.slotFor('child-1'), isNull);
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

      service.cancelConversation('parent-1');

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

        service.cancelConversation('parent-1');

        final grandResult = await grandFuture;
        expect(grandResult.cancelled, isTrue);
      },
    );

    test('waitFor returns the transformed content, consistent with the '
        'persisted row (assistant regex persist rules)', () async {
      final transformAssistant = Assistant(
        id: 'assistant-1',
        name: 'Transform Bot',
        regexRules: [
          AssistantRegex(
            id: 'r1',
            name: 'replace foo',
            pattern: 'foo',
            replacement: 'bar',
            scopes: const [AssistantRegexScope.assistant],
          ),
        ],
      );
      final placeholder = await chatService.addMessage(
        conversationId: 'child-1',
        role: 'assistant',
        content: '',
        isStreaming: true,
      );
      service.prepareRound(
        conversationId: 'child-1',
        assistantMessageId: placeholder.id,
        parentConversationId: 'parent-1',
        wait: true,
      );
      service.startRound(
        conversationId: 'child-1',
        slots: [
          GenerationSlotRequest(
            assistantMessageId: placeholder.id,
            apiMessages: const [],
            config: config,
            modelId: 'model-1',
            assistant: transformAssistant,
          ),
        ],
        parentConversationId: 'parent-1',
        wait: true,
      );
      await pumpEventQueue();

      pumpChunk('child-1', 'foo world');
      await closeStream('child-1');

      final result = await service.waitFor('child-1');
      expect(result.text, 'bar world');
      final messages = chatService.messagesByConversation['child-1']!;
      expect(messages.last.content, 'bar world');
    });

    test('stream error resolves the waiter with the error', () async {
      await startChild(id: 'child-1', parent: 'parent-1');
      final slot = service.slotFor('child-1')!;
      final future = service.waitFor('child-1');
      pumpChunk('child-1', 'before boom');
      streamControllers[midFor['child-1']]!.addError(StateError('boom'));
      await closeStream('child-1');

      final result = await future;
      expect(result.error, contains('boom'));
      expect(slot.status, SlotStatus.error);
    });

    test('waitFor on an unknown conversation resolves with an error', () async {
      final result = await service.waitFor('nope');
      expect(result.error, isNotNull);
    });

    test('prepareRound registers the round before generation starts so '
        'waitFor never races the async pipeline', () async {
      // Simulates the engine server: the started JSON travels back through
      // pure microtasks while the generation suspends on real I/O. The
      // handler's waitFor must find the round already registered.
      final placeholder = await chatService.addMessage(
        conversationId: 'child-1',
        role: 'assistant',
        content: '',
        isStreaming: true,
      );
      final slot = service.prepareRound(
        conversationId: 'child-1',
        assistantMessageId: placeholder.id,
        parentConversationId: 'parent-1',
        wait: true,
        targetName: 'Research Bot',
      );
      expect(slot.targetName, 'Research Bot');
      final future = service.waitFor('child-1');

      // Generation starts late and resolves the same round.
      service.startRound(
        conversationId: 'child-1',
        slots: [
          GenerationSlotRequest(
            assistantMessageId: placeholder.id,
            apiMessages: const [],
            config: config,
            modelId: 'model-1',
          ),
        ],
        parentConversationId: 'parent-1',
        wait: true,
      );
      await pumpEventQueue();
      pumpChunk('child-1', 'result text');
      await closeStream('child-1');

      final result = await future;
      expect(result.text, 'result text');
      expect(result.error, isNull);
      expect(slot.targetName, 'Research Bot');
    });

    test('cancel before _run starts aborts the generation without '
        'persisting anything', () async {
      final placeholder = await chatService.addMessage(
        conversationId: 'child-1',
        role: 'assistant',
        content: '',
        isStreaming: true,
      );
      service.prepareRound(
        conversationId: 'child-1',
        assistantMessageId: placeholder.id,
        parentConversationId: 'parent-1',
        wait: true,
      );
      final future = service.waitFor('child-1');

      // User cancels during the engine-side window (between prepareRound and
      // the generation actually starting).
      service.cancelConversation('child-1');
      final result = await future;
      expect(result.cancelled, isTrue);

      // A late start must abort: the empty placeholder is deleted, the round
      // is gone, and the status is NOT overwritten to done.
      service.startRound(
        conversationId: 'child-1',
        slots: [
          GenerationSlotRequest(
            assistantMessageId: placeholder.id,
            apiMessages: const [],
            config: config,
            modelId: 'model-1',
          ),
        ],
        parentConversationId: 'parent-1',
        wait: true,
      );
      await pumpEventQueue();
      expect(
        chatService.messagesByConversation['child-1'] ?? const [],
        isEmpty,
      );
      expect(service.isActive('child-1'), isFalse);
      expect(service.slotFor('child-1'), isNull);
    });

    test('waitSlotsFor returns only wait-mode slots of the parent', () async {
      await startChild(id: 'child-wait', parent: 'parent-1', wait: true);
      await startChild(id: 'child-fire', parent: 'parent-1', wait: false);
      await startChild(id: 'other', parent: 'other-parent', wait: true);

      final slots = service.waitSlotsFor('parent-1');
      expect(slots.map((s) => s.conversationId), ['child-wait']);
    });
  });

  group('GenerationEngine N-slot rounds and tool events', () {
    test(
      'an N-slot round streams every slot and settles them independently',
      () async {
        final p1 = await chatService.addMessage(
          conversationId: 'round-1',
          role: 'assistant',
          content: '',
          isStreaming: true,
        );
        final p2 = await chatService.addMessage(
          conversationId: 'round-1',
          role: 'assistant',
          content: '',
          isStreaming: true,
        );
        midFor['slot-a'] = p1.id;
        midFor['slot-b'] = p2.id;

        service.startRound(
          conversationId: 'round-1',
          slots: [
            GenerationSlotRequest(
              assistantMessageId: p1.id,
              apiMessages: const [],
              config: config,
              modelId: 'model-1',
            ),
            GenerationSlotRequest(
              assistantMessageId: p2.id,
              apiMessages: const [],
              config: config,
              modelId: 'model-1',
            ),
          ],
        );
        await pumpEventQueue();
        expect(service.slotsFor('round-1'), hasLength(2));

        pumpChunk('slot-a', 'thread A ');
        pumpChunk('slot-b', 'thread B ');
        await closeStream('slot-a');
        await closeStream('slot-b');
        await pumpEventQueue();

        final msgs = chatService.messagesByConversation['round-1']!;
        final a = msgs.firstWhere((m) => m.id == p1.id);
        final b = msgs.firstWhere((m) => m.id == p2.id);
        expect(a.content, 'thread A ');
        expect(b.content, 'thread B ');
        expect(a.isStreaming, isFalse);
        expect(b.isStreaming, isFalse);
        expect(service.isActive('round-1'), isFalse);
      },
    );

    test('no-id tool events keep multiple results and complete the oldest '
        'still-loading placeholder', () async {
      await startChild(id: 't1', wait: false);
      final mid = midFor['t1']!;

      // Two no-id calls create per-name placeholder slots.
      pumpChunk(
        't1',
        '',
        calls: [
          ToolCallInfo(id: '', name: 'search_web', arguments: const {}),
          ToolCallInfo(id: '', name: 'search_web', arguments: const {}),
        ],
      );
      // Two no-id results complete the placeholders oldest-first; both must
      // survive persistence (dedupeToolEvents keeps no-id results with
      // different content).
      pumpChunk(
        't1',
        '',
        results: [
          ToolResultInfo(
            id: '',
            name: 'search_web',
            arguments: const {},
            content: '{"items":["A"]}',
          ),
          ToolResultInfo(
            id: '',
            name: 'search_web',
            arguments: const {},
            content: '{"items":["B"]}',
          ),
        ],
      );
      await pumpEventQueue();

      final persisted = chatService.toolEventsByMessage[mid]!;
      expect(persisted, hasLength(2));
      expect(
        persisted.map((e) => e['content']),
        containsAll(['{"items":["A"]}', '{"items":["B"]}']),
      );
      expect(
        persisted.where((e) => e['content'] == null),
        isEmpty,
        reason: 'no loading placeholder may survive a completed result',
      );

      await closeStream('t1');
      await pumpEventQueue();
    });
  });

  group(
    'GenerationEngine live rendering (pacing ramp + reasoning throttle)',
    () {
      late StreamingContentNotifier notifier;
      late List<String> contentUpdates;
      late List<String> reasoningUpdates;

      // Page-like slot start. NOTE: cannot reuse `startChild` — its trailing
      // `pumpEventQueue()` hangs under testWidgets fake-async; `tester.pump()`
      // is the fake-clock-flush equivalent here.
      Future<String> startPageSlot(WidgetTester tester, String id) async {
        final placeholder = await chatService.addMessage(
          conversationId: id,
          role: 'assistant',
          content: '',
          isStreaming: true,
        );
        midFor[id] = placeholder.id;
        service.startRound(
          conversationId: id,
          slots: [
            GenerationSlotRequest(
              assistantMessageId: placeholder.id,
              apiMessages: const [],
              config: config,
              modelId: 'model-1',
            ),
          ],
        );
        await tester.pump();
        final slot = service.slotForMessage(placeholder.id)!;
        slot.uiNotifier = notifier;
        notifier.getNotifier(placeholder.id).addListener(() {
          contentUpdates.add(
            notifier.getNotifier(placeholder.id).value.content,
          );
        });
        notifier.getNotifier(placeholder.id).addListener(() {
          final text = notifier.getNotifier(placeholder.id).value.reasoningText;
          if (text != null && text.isNotEmpty) {
            reasoningUpdates.add(text);
          }
        });
        return placeholder.id;
      }

      setUp(() {
        notifier = StreamingContentNotifier();
        contentUpdates = <String>[];
        reasoningUpdates = <String>[];
      });

      testWidgets(
        'content is buffered until the 50ms tick, then published in slices',
        (tester) async {
          await startPageSlot(tester, 'p1');
          pumpChunk('p1', 'abcdefghijklmnopqrstuvwxyz');
          await tester.pump();

          expect(
            contentUpdates,
            isEmpty,
            reason: 'the ramp must buffer until its first tick',
          );

          await tester.pump(const Duration(milliseconds: 50));
          expect(contentUpdates, hasLength(1));
          expect(contentUpdates.single.length, greaterThanOrEqualTo(2));
          expect(contentUpdates.single.length, lessThan(26));

          await closeStream('p1');
          await tester.pump();
          // Settle flush jumps to the final content.
          expect(contentUpdates.last, 'abcdefghijklmnopqrstuvwxyz');
        },
      );

      testWidgets('does not re-publish an unchanged full frame', (
        tester,
      ) async {
        await startPageSlot(tester, 'p2');
        pumpChunk('p2', 'ok');
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 50));
        expect(contentUpdates, ['ok']);

        await tester.pump(const Duration(milliseconds: 50));
        expect(contentUpdates, [
          'ok',
        ], reason: 'unchanged frame must not re-fire');

        await closeStream('p2');
        await tester.pump();
      });

      testWidgets('adapts pick count to a large backlog', (tester) async {
        await startPageSlot(tester, 'p3');
        pumpChunk('p3', 'a' * 320);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 50));

        expect(contentUpdates, hasLength(1));
        expect(contentUpdates.single.length, greaterThan(40));
        expect(contentUpdates.single.length, lessThan(320));

        await closeStream('p3');
        await tester.pump();
      });

      testWidgets('settle flushes the final content immediately', (
        tester,
      ) async {
        await startPageSlot(tester, 'p4');
        pumpChunk('p4', 'final answer');
        await tester.pump();
        expect(contentUpdates, isEmpty);

        await closeStream('p4');
        await tester.pump();
        expect(contentUpdates, ['final answer']);
      });

      testWidgets('one-character final backlog is flushed on settle', (
        tester,
      ) async {
        await startPageSlot(tester, 'p5');
        pumpChunk('p5', 'ab');
        pumpChunk('p5', 'c');
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 50));
        expect(contentUpdates, ['ab']);

        await closeStream('p5');
        await tester.pump();
        expect(contentUpdates, ['ab', 'abc']);
      });

      testWidgets('reasoning UI updates coalesce to one per 150ms', (
        tester,
      ) async {
        await startPageSlot(tester, 'r1');
        for (var i = 0; i < 5; i++) {
          pumpChunk('r1', '', reasoning: 't$i');
        }
        await tester.pump();
        // All five chunks are buffered; nothing reaches the card before the
        // 150ms coalescing tick.
        await tester.pump(const Duration(milliseconds: 100));
        expect(reasoningUpdates, isEmpty);

        await tester.pump(const Duration(milliseconds: 60));
        expect(reasoningUpdates, hasLength(1));
        expect(reasoningUpdates.single, 't0t1t2t3t4');

        // No new reasoning — no further update (the settle flush must not
        // duplicate the unchanged snapshot).
        await tester.pump(const Duration(milliseconds: 200));
        expect(reasoningUpdates, hasLength(1));

        await closeStream('r1');
        await tester.pump();
        expect(reasoningUpdates, hasLength(1));
      });

      testWidgets('settle flushes reasoning that was not yet coalesced', (
        tester,
      ) async {
        await startPageSlot(tester, 'r2');
        for (var i = 0; i < 3; i++) {
          pumpChunk('r2', '', reasoning: 's$i');
        }
        await tester.pump();
        // Stream settles before the 150ms coalescing tick: the final
        // thinking state must still reach the live card.
        expect(reasoningUpdates, isEmpty);
        await closeStream('r2');
        await tester.pump();
        expect(reasoningUpdates, ['s0s1s2']);
      });
    },
  );
}
