import 'dart:async';
import 'dart:convert';

import 'package:Cuplivo/core/models/assistant.dart';
import 'package:Cuplivo/core/models/chat_message.dart';
import 'package:Cuplivo/core/models/conversation.dart';
import 'package:Cuplivo/core/providers/settings_provider.dart';
import 'package:Cuplivo/core/services/api/chat_api_service.dart';
import 'package:Cuplivo/core/services/proactive_care_decision_tools.dart';
import 'package:Cuplivo/core/services/proactive_care_message_flow.dart';
import 'package:Cuplivo/core/services/proactive_care_service.dart';
import 'package:flutter_test/flutter_test.dart';

/// Queued fake transport: one [StreamController] per send attempt, so the
/// retry path gets its own stream. Modeled on the director retry test fake.
class _FakeDecisionTransport {
  final List<StreamController<ChatStreamChunk>> _pending = [];
  final List<bool> subscriptionCancelled = [];
  final List<List<Map<String, dynamic>>> capturedMessages = [];
  final List<List<Map<String, dynamic>>?> capturedTools = [];
  final List<ToolCallHandler?> capturedHandlers = [];
  final List<String?> capturedRequestIds = [];
  int sendCount = 0;

  StreamController<ChatStreamChunk> enqueue() {
    final index = _pending.length;
    final controller = StreamController<ChatStreamChunk>();
    controller.onCancel = () => subscriptionCancelled[index] = true;
    _pending.add(controller);
    subscriptionCancelled.add(false);
    return controller;
  }

  Stream<ChatStreamChunk> send({
    required ProviderConfig config,
    required String modelId,
    required List<Map<String, dynamic>> messages,
    List<Map<String, dynamic>>? tools,
    ToolCallHandler? onToolCall,
    int? thinkingBudget,
    double? temperature,
    double? topP,
    int? maxTokens,
    bool stream = true,
    String? requestId,
  }) {
    final index = sendCount++;
    capturedMessages.add(messages);
    capturedTools.add(tools);
    capturedHandlers.add(onToolCall);
    capturedRequestIds.add(requestId);
    return _pending[index].stream;
  }

  Future<void> closeAll() async {
    for (final controller in _pending) {
      await controller.close();
    }
  }
}

/// Tomorrow 09:30 with no microseconds, so ISO-8601 round-trips exactly and
/// it is always strictly after the flow's internal `now`.
DateTime futureTime() {
  final now = DateTime.now();
  return DateTime(now.year, now.month, now.day + 1, 9, 30);
}

ChatStreamChunk toolChunk(
  String name,
  Map<String, dynamic> arguments, {
  String id = 't1',
}) {
  return ChatStreamChunk(
    content: '',
    isDone: false,
    totalTokens: 0,
    toolCalls: <ToolCallInfo>[
      ToolCallInfo(id: id, name: name, arguments: arguments),
    ],
  );
}

ChatStreamChunk updateChunk(DateTime time, {String id = 't1', String? name}) {
  return toolChunk(
    name ?? ProactiveCareDecisionTools.updateTime,
    <String, dynamic>{'next_care_time': time.toIso8601String()},
    id: id,
  );
}

void main() {
  late _FakeDecisionTransport transport;

  setUp(() {
    transport = _FakeDecisionTransport();
  });

  tearDown(() async {
    await transport.closeAll();
  });

  group('directed history', () {
    test('uses only the active root-to-leaf branch', () {
      const conversationId = 'conversation-1';
      final history = ProactiveCareMessageFlow.buildHistory(
        conversation: Conversation(
          id: conversationId,
          title: 'test',
          activeMessageId: 'a5',
        ),
        messages: [
          ChatMessage(
            id: 'u1',
            role: 'user',
            content: '1',
            conversationId: conversationId,
          ),
          ChatMessage(
            id: 'a2',
            role: 'assistant',
            content: '2',
            conversationId: conversationId,
            parentMessageId: 'u1',
          ),
          ChatMessage(
            id: 'a3',
            role: 'assistant',
            content: '3',
            conversationId: conversationId,
            parentMessageId: 'u1',
          ),
          ChatMessage(
            id: 'u4',
            role: 'user',
            content: '4',
            conversationId: conversationId,
          ),
          ChatMessage(
            id: 'a5',
            role: 'assistant',
            content: '5',
            conversationId: conversationId,
            parentMessageId: 'u4',
          ),
        ],
      );

      expect(history, [
        {'role': 'user', 'content': '4'},
        {'role': 'assistant', 'content': '5'},
      ]);
    });
  });

  Future<DateTime?> decide({
    List<Map<String, dynamic>>? history,
    Duration decisionTimeout = const Duration(seconds: 45),
  }) {
    return ProactiveCareMessageFlow.decideNextCareTime(
      config: ProviderConfig.defaultsFor('TestProvider'),
      modelId: 'test-model',
      assistant: Assistant(id: 'a1', name: 'Alpha'),
      userNickname: 'tester',
      history:
          history ??
          const <Map<String, dynamic>>[
            {'role': 'user', 'content': 'hi'},
            {'role': 'assistant', 'content': 'hello'},
          ],
      decisionPrompt: 'test',
      sendMessageStream: transport.send,
      decisionTimeout: decisionTimeout,
    );
  }

  group('decision flow', () {
    test(
      '1: valid future time via chunk toolCalls returns the exact time',
      () async {
        final controller = transport.enqueue();
        final time = futureTime();

        final future = decide();
        controller.add(updateChunk(time));
        final result = await future.timeout(const Duration(seconds: 5));

        expect(result, time);
        expect(transport.sendCount, 1);

        await pumpEventQueue();
        expect(transport.subscriptionCancelled[0], isTrue);

        final tools = transport.capturedTools[0];
        expect(tools, isNotNull);
        expect(tools, hasLength(2));
        for (final def in tools!) {
          expect(def['type'], 'function');
        }
        expect(
          Map<String, dynamic>.from(tools[0]['function'] as Map)['name'],
          ProactiveCareDecisionTools.updateTime,
        );
        expect(
          Map<String, dynamic>.from(tools[1]['function'] as Map)['name'],
          ProactiveCareDecisionTools.keepTime,
        );

        // Message wiring: system prompt first, tool reminder last.
        expect(transport.capturedMessages[0].first, {
          'role': 'system',
          'content': 'test',
        });
        expect(
          transport.capturedMessages[0].last['content'] as String,
          endsWith(ProactiveCareService.builtinDecisionToolReminder),
        );
        expect(
          transport.capturedRequestIds[0],
          startsWith('proactive-care-decision-a1-'),
        );
      },
    );

    test(
      '2: decision via onToolCall handler returns the time neutrally',
      () async {
        transport.enqueue();
        final time = futureTime();

        final future = decide();
        final handler = transport.capturedHandlers[0];
        expect(handler, isNotNull);
        final resultString = await handler!(
          ProactiveCareDecisionTools.updateTime,
          <String, dynamic>{'next_care_time': time.toIso8601String()},
          toolCallId: 't1',
        );
        expect(
          (jsonDecode(resultString) as Map<String, dynamic>)['ok'],
          isTrue,
        );
        expect(resultString, isNot(contains('ignored')));

        final result = await future.timeout(const Duration(seconds: 5));
        expect(result, time);
        expect(transport.sendCount, 1);

        await pumpEventQueue();
        expect(transport.subscriptionCancelled[0], isTrue);
      },
    );

    test('3: UTC input is converted to local time', () async {
      final controller = transport.enqueue();
      final utc = DateTime.now().toUtc().add(const Duration(days: 1));

      final future = decide();
      controller.add(updateChunk(utc));
      final result = await future.timeout(const Duration(seconds: 5));

      expect(result, isNotNull);
      expect(result!.isUtc, isFalse);
      expect(result.toUtc(), utc);
    });

    test('4: past time is final (null, no retry)', () async {
      final controller = transport.enqueue();
      final past = DateTime.now().subtract(const Duration(hours: 1));

      final future = decide();
      controller.add(updateChunk(past));
      final result = await future.timeout(const Duration(seconds: 5));

      expect(result, isNull);
      expect(transport.sendCount, 1);
    });

    test('5: malformed time arg is final (null, no retry)', () async {
      final controller = transport.enqueue();

      final future = decide();
      controller.add(
        toolChunk(
          ProactiveCareDecisionTools.updateTime,
          const <String, dynamic>{'next_care_time': 'not-a-date'},
        ),
      );
      final result = await future.timeout(const Duration(seconds: 5));

      expect(result, isNull);
      expect(transport.sendCount, 1);
    });

    test(
      '6: missing or empty next_care_time is final (null, no retry)',
      () async {
        final first = transport.enqueue();
        final firstFuture = decide();
        first.add(
          toolChunk(
            ProactiveCareDecisionTools.updateTime,
            const <String, dynamic>{},
          ),
        );
        expect(await firstFuture.timeout(const Duration(seconds: 5)), isNull);
        expect(transport.sendCount, 1);

        final second = transport.enqueue();
        final secondFuture = decide();
        second.add(
          toolChunk(
            ProactiveCareDecisionTools.updateTime,
            const <String, dynamic>{'next_care_time': ''},
          ),
        );
        expect(await secondFuture.timeout(const Duration(seconds: 5)), isNull);
        expect(transport.sendCount, 2);
      },
    );

    test('7: keep_care_time returns null and cancels without retry', () async {
      final controller = transport.enqueue();

      final future = decide();
      controller.add(
        toolChunk(
          ProactiveCareDecisionTools.keepTime,
          const <String, dynamic>{},
        ),
      );
      final result = await future.timeout(const Duration(seconds: 5));

      expect(result, isNull);
      expect(transport.sendCount, 1);

      await pumpEventQueue();
      expect(transport.subscriptionCancelled[0], isTrue);
    });

    test('8: free text on both attempts returns null and retry appends the '
        'tool-only directive', () async {
      final first = transport.enqueue();
      final second = transport.enqueue();

      final future = decide();
      first.add(
        ChatStreamChunk(
          content: 'I think we should wait a bit longer.',
          isDone: false,
          totalTokens: 0,
        ),
      );
      await first.close();
      second.add(
        ChatStreamChunk(
          content: 'Still no tools, sorry.',
          isDone: false,
          totalTokens: 0,
        ),
      );
      await second.close();

      final result = await future.timeout(const Duration(seconds: 5));
      expect(result, isNull);
      expect(transport.sendCount, 2);

      final retryLast = transport.capturedMessages[1].last;
      expect(retryLast['role'], 'user');
      expect(
        retryLast['content'] as String,
        contains(ProactiveCareDecisionTools.updateTime),
      );
      expect(
        retryLast['content'] as String,
        contains(ProactiveCareDecisionTools.keepTime),
      );
      expect(
        transport.capturedRequestIds[1],
        '${transport.capturedRequestIds[0]}-retry',
      );
    });

    test('9: first stream error retries and returns the retry time', () async {
      final first = transport.enqueue();
      final second = transport.enqueue();
      final time = futureTime();

      final future = decide();
      first.addError(Exception('network down'));
      second.add(updateChunk(time));

      final result = await future.timeout(const Duration(seconds: 5));
      expect(result, time);
      expect(transport.sendCount, 2);
    });

    test('10: follow-up handler calls after a decision stay neutral', () async {
      transport.enqueue();
      final time = futureTime();

      final future = decide();
      final handler = transport.capturedHandlers[0]!;
      await handler(ProactiveCareDecisionTools.updateTime, <String, dynamic>{
        'next_care_time': time.toIso8601String(),
      }, toolCallId: 't1');
      final result = await future.timeout(const Duration(seconds: 5));
      expect(result, time);

      // Provider keeps sending follow-up calls before the cancel lands.
      final followUpKeep = await handler(
        ProactiveCareDecisionTools.keepTime,
        const <String, dynamic>{},
        toolCallId: 't2',
      );
      final followUpUpdate = await handler(
        ProactiveCareDecisionTools.updateTime,
        <String, dynamic>{
          'next_care_time': time.add(const Duration(days: 1)).toIso8601String(),
        },
        toolCallId: 't3',
      );
      expect(followUpKeep, isNot(contains('ignored')));
      expect(followUpUpdate, isNot(contains('ignored')));
      expect((jsonDecode(followUpKeep) as Map<String, dynamic>)['ok'], isTrue);
      expect(
        (jsonDecode(followUpUpdate) as Map<String, dynamic>)['ok'],
        isTrue,
      );
      expect(transport.sendCount, 1);
    });

    test('11: lenient tool-name matching accepts Update-Care-Time', () async {
      final controller = transport.enqueue();
      final time = futureTime();

      final future = decide();
      controller.add(updateChunk(time, name: 'Update-Care-Time'));
      final result = await future.timeout(const Duration(seconds: 5));

      expect(result, time);
      expect(transport.sendCount, 1);
    });

    test('12: empty history returns null without sending', () async {
      final result = await decide(
        history: const <Map<String, dynamic>>[],
      ).timeout(const Duration(seconds: 5));
      expect(result, isNull);
      expect(transport.sendCount, 0);
    });

    test(
      '15: unknown tool name stays undecided, later valid call settles',
      () async {
        final controller = transport.enqueue();
        final time = futureTime();

        var completed = false;
        final future = decide();
        unawaited(future.then((_) => completed = true));

        controller.add(
          toolChunk('some_unknown_tool', const <String, dynamic>{'x': 1}),
        );
        await pumpEventQueue();
        expect(completed, isFalse);

        controller.add(updateChunk(time, id: 't2'));
        final result = await future.timeout(const Duration(seconds: 5));
        expect(result, time);
        expect(transport.sendCount, 1);
      },
    );

    test('16: both attempts error returns null after two sends', () async {
      final first = transport.enqueue();
      final second = transport.enqueue();

      final future = decide();
      first.addError(Exception('first down'));
      second.addError(Exception('second down'));

      final result = await future.timeout(const Duration(seconds: 5));
      expect(result, isNull);
      expect(transport.sendCount, 2);
    });

    test(
      '17: handler and chunk double delivery decides once, first wins',
      () async {
        final controller = transport.enqueue();
        final time = futureTime();

        final future = decide();
        final handler = transport.capturedHandlers[0]!;
        await handler(
          ProactiveCareDecisionTools.keepTime,
          const <String, dynamic>{},
          toolCallId: 't1',
        );
        // Same/duplicate call also arrives as a chunk before cancel lands.
        controller.add(updateChunk(time, id: 't2'));

        final result = await future.timeout(const Duration(seconds: 5));
        expect(result, isNull);
        expect(transport.sendCount, 1);
      },
    );

    test(
      '18: first attempt timeout retries and second attempt decides',
      () async {
        transport.enqueue();
        final second = transport.enqueue();
        final time = futureTime();

        final future = decide(
          decisionTimeout: const Duration(milliseconds: 20),
        );
        // First stream never emits; the chunk is buffered for attempt 2.
        second.add(updateChunk(time));

        final result = await future.timeout(const Duration(seconds: 5));
        expect(result, time);
        expect(transport.sendCount, 2);
      },
    );

    test('19: both attempts timing out returns null after two sends', () async {
      transport.enqueue();
      transport.enqueue();

      final result = await decide(
        decisionTimeout: const Duration(milliseconds: 20),
      ).timeout(const Duration(seconds: 5));

      expect(result, isNull);
      expect(transport.sendCount, 2);
    });

    test('20: timeout cancels the hung attempt subscription', () async {
      transport.enqueue();
      transport.enqueue();

      final result = await decide(
        decisionTimeout: const Duration(milliseconds: 20),
      ).timeout(const Duration(seconds: 5));
      expect(result, isNull);

      await pumpEventQueue();
      expect(transport.subscriptionCancelled[0], isTrue);
    });

    test(
      '22: validation uses a fresh clock, not the request-level now',
      () async {
        final controller = transport.enqueue();

        // Timing margin: the proposed time is t0+150ms, future relative to
        // the request-level clock captured inside decide() (~t0), but the
        // chunk is only delivered after a real 300ms delay, so the fresh
        // validation clock is already >= t0+300ms and the time is past.
        // Direction is deterministic on any machine speed: the delay must
        // elapse before the chunk arrives, and 300ms > 150ms. Reverting to
        // the stale request-level clock would accept the time and fail here.
        final t0 = DateTime.now();
        final future = decide();
        await Future<void>.delayed(const Duration(milliseconds: 300));
        controller.add(updateChunk(t0.add(const Duration(milliseconds: 150))));

        final result = await future.timeout(const Duration(seconds: 5));

        expect(result, isNull);
        // Invalid/past args are final: no retry.
        expect(transport.sendCount, 1);
      },
    );
  });

  group('ProactiveCareService', () {
    test('21: empty decision prompt omits the system message', () {
      final messages = ProactiveCareService.buildDecisionApiMessages(
        decisionPrompt: '',
        currentNextCareTime: null,
        now: DateTime(2026, 8, 3, 12),
        history: const <Map<String, dynamic>>[
          {'role': 'user', 'content': 'hi'},
        ],
      );

      expect(messages.where((m) => m['role'] == 'system'), isEmpty);
      expect(messages.first['role'], 'user');
      expect(
        messages.first['content'] as String,
        startsWith(ProactiveCareService.chatHistoryPrefix),
      );
    });
  });

  group('ProactiveCareDecisionTools', () {
    final now = DateTime(2026, 8, 3, 12);

    test('13: parseUpdateTimeArgs keeps the old JSON-decision semantics', () {
      // Valid local future time.
      expect(
        ProactiveCareDecisionTools.parseUpdateTimeArgs(const <String, dynamic>{
          'next_care_time': '2026-08-04T09:30:00',
        }, now: now),
        DateTime(2026, 8, 4, 9, 30),
      );
      // Past rejected.
      expect(
        ProactiveCareDecisionTools.parseUpdateTimeArgs(const <String, dynamic>{
          'next_care_time': '2026-08-02T09:30:00',
        }, now: now),
        isNull,
      );
      // Exactly now rejected (strictly after).
      expect(
        ProactiveCareDecisionTools.parseUpdateTimeArgs(const <String, dynamic>{
          'next_care_time': '2026-08-03T12:00:00',
        }, now: now),
        isNull,
      );
      // UTC converted to local, TZ-independent.
      final utcResult = ProactiveCareDecisionTools.parseUpdateTimeArgs(
        const <String, dynamic>{'next_care_time': '2026-08-04T01:30:00Z'},
        now: now,
      );
      expect(utcResult, isNotNull);
      expect(utcResult!.isUtc, isFalse);
      expect(utcResult.toUtc(), DateTime.utc(2026, 8, 4, 1, 30));
      // Non-string rejected.
      expect(
        ProactiveCareDecisionTools.parseUpdateTimeArgs(const <String, dynamic>{
          'next_care_time': 12345,
        }, now: now),
        isNull,
      );
      // Missing rejected.
      expect(
        ProactiveCareDecisionTools.parseUpdateTimeArgs(
          const <String, dynamic>{},
          now: now,
        ),
        isNull,
      );
      // Empty string rejected.
      expect(
        ProactiveCareDecisionTools.parseUpdateTimeArgs(const <String, dynamic>{
          'next_care_time': '   ',
        }, now: now),
        isNull,
      );
    });

    test('14: definitions() are OpenAI-shaped function tools', () {
      final defs = ProactiveCareDecisionTools.definitions();
      expect(defs, hasLength(2));
      for (final def in defs) {
        expect(def['type'], 'function');
      }
      final update = Map<String, dynamic>.from(defs[0]['function'] as Map);
      expect(update['name'], ProactiveCareDecisionTools.updateTime);
      final params = Map<String, dynamic>.from(update['parameters'] as Map);
      expect(params['required'], ['next_care_time']);
      final keep = Map<String, dynamic>.from(defs[1]['function'] as Map);
      expect(keep['name'], ProactiveCareDecisionTools.keepTime);
    });
  });
}
