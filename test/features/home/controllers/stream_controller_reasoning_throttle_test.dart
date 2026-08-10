import 'package:flutter_test/flutter_test.dart';
import 'package:Cuplivo/core/models/chat_message.dart';
import 'package:Cuplivo/core/providers/settings_provider.dart';
import 'package:Cuplivo/core/services/api/chat_api_service.dart';
import 'package:Cuplivo/core/services/chat/chat_service.dart';
import 'package:Cuplivo/features/home/controllers/stream_controller.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Requirement-driven tests for the issue #232 reasoning throttle:
/// - Happy path: N chunks collapse into one flush write per 500ms cadence.
/// - Boundary: chunks arriving across cadence windows produce one flush each.
/// - State transition: finishReasoningAndPersist persists the final snapshot
///   after throttled chunks (flush + final writes).
/// - Interaction: cleanupTimers cancels pending flush/UI timers.
/// - Failure path: a failing flush write is logged and the finish-path
///   persist still recovers the final state.
/// - Interaction: thinking-card UI updates coalesce to ~150ms cadence.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  SharedPreferences.setMockInitialValues(const {});

  StreamController buildController({String? currentConversationId}) {
    return StreamController(
      chatService: ChatService(),
      onStateChanged: () {},
      getSettingsProvider: SettingsProvider.new,
      getCurrentConversationId: () => currentConversationId,
    );
  }

  StreamingState buildStreamingState() {
    final message = ChatMessage(
      id: 'assistant-message',
      role: 'assistant',
      content: '',
      conversationId: 'conversation-1',
      isStreaming: true,
    );
    return StreamingState(
      GenerationContext(
        assistantMessage: message,
        apiMessages: const [],
        userMediaPaths: const [],
        allowImagesApiRouting: false,
        providerKey: 'test',
        modelId: 'test-model',
        assistant: null,
        settings: SettingsProvider(),
        config: ProviderConfig(
          id: 'test',
          enabled: true,
          name: 'Test',
          apiKey: '',
          baseUrl: '',
        ),
        toolDefs: const [],
        supportsReasoning: true,
        enableReasoning: true,
        streamOutput: true,
      ),
    );
  }

  ChatStreamChunk reasoningChunk(String text) {
    return ChatStreamChunk(
      content: '',
      reasoning: text,
      isDone: false,
      totalTokens: 0,
    );
  }

  testWidgets('reasoning chunks coalesce into a single 500ms flush write', (
    tester,
  ) async {
    final controller = buildController(currentConversationId: 'conversation-1');
    final state = buildStreamingState();
    var writes = 0;
    String? lastText;
    String? lastJson;

    for (var i = 0; i < 5; i++) {
      await controller.handleReasoningChunk(
        reasoningChunk('think $i\n'),
        state,
        updateReasoningInDb:
            (
              messageId, {
              String? reasoningText,
              DateTime? reasoningStartAt,
              String? reasoningSegmentsJson,
            }) async {
              writes++;
              lastText = reasoningText;
              lastJson = reasoningSegmentsJson;
            },
      );
    }

    expect(writes, 0, reason: 'nothing persisted before the cadence elapses');
    await tester.pump(const Duration(milliseconds: 499));
    expect(writes, 0);
    await tester.pump(const Duration(milliseconds: 2));
    expect(writes, 1, reason: '5 chunks collapse into exactly one flush write');
    expect(lastText, 'think 0\nthink 1\nthink 2\nthink 3\nthink 4\n');
    expect(lastJson, contains('think 4'));

    controller.cleanupTimers('assistant-message');
  });

  testWidgets('continued chunks produce one flush per 500ms window', (
    tester,
  ) async {
    final controller = buildController(currentConversationId: 'conversation-1');
    final state = buildStreamingState();
    var writes = 0;
    String? lastText;

    for (var i = 0; i < 3; i++) {
      await controller.handleReasoningChunk(
        reasoningChunk('part $i '),
        state,
        updateReasoningInDb:
            (
              messageId, {
              String? reasoningText,
              DateTime? reasoningStartAt,
              String? reasoningSegmentsJson,
            }) async {
              writes++;
              lastText = reasoningText;
            },
      );
    }
    await tester.pump(const Duration(milliseconds: 500));
    expect(writes, 1);

    for (var i = 3; i < 5; i++) {
      await controller.handleReasoningChunk(
        reasoningChunk('part $i '),
        state,
        updateReasoningInDb:
            (
              messageId, {
              String? reasoningText,
              DateTime? reasoningStartAt,
              String? reasoningSegmentsJson,
            }) async {
              writes++;
              lastText = reasoningText;
            },
      );
    }
    await tester.pump(const Duration(milliseconds: 500));
    expect(writes, 2, reason: 'each cadence window flushes once');
    expect(lastText, 'part 0 part 1 part 2 part 3 part 4 ');

    controller.cleanupTimers('assistant-message');
  });

  testWidgets('finishReasoningAndPersist persists the final snapshot after '
      'throttled chunks', (tester) async {
    final controller = buildController();
    final state = buildStreamingState();
    final persistedTexts = <String?>[];

    for (var i = 0; i < 3; i++) {
      await controller.handleReasoningChunk(
        reasoningChunk('part $i '),
        state,
        updateReasoningInDb:
            (
              messageId, {
              String? reasoningText,
              DateTime? reasoningStartAt,
              String? reasoningSegmentsJson,
            }) async {
              persistedTexts.add(reasoningText);
            },
      );
    }

    await controller.finishReasoningAndPersist(
      state.messageId,
      updateReasoningInDb:
          (
            messageId, {
            String? reasoningText,
            DateTime? reasoningStartAt,
            DateTime? reasoningFinishedAt,
            String? reasoningSegmentsJson,
          }) async {
            persistedTexts.add(reasoningText);
          },
    );

    expect(
      persistedTexts.length,
      2,
      reason:
          'final text write + final segments write (no redundant flush '
          'on the normal finish path)',
    );
    expect(persistedTexts[0], 'part 0 part 1 part 2 ');

    controller.cleanupTimers('assistant-message');
  });

  testWidgets('interleaved thinking: finish, more chunks, finish again keeps '
      'the full snapshot and finishedAt', (tester) async {
    final controller = buildController();
    final state = buildStreamingState();
    final persistedTexts = <String?>[];
    var finishedAtWrites = 0;

    await controller.handleReasoningChunk(
      reasoningChunk('first '),
      state,
      updateReasoningInDb:
          (
            messageId, {
            String? reasoningText,
            DateTime? reasoningStartAt,
            String? reasoningSegmentsJson,
          }) async {
            persistedTexts.add(reasoningText);
          },
    );
    // Thinking -> body transition (content starts while reasoning streams).
    await controller.finishReasoningAndPersist(
      state.messageId,
      updateReasoningInDb:
          (
            messageId, {
            String? reasoningText,
            DateTime? reasoningStartAt,
            DateTime? reasoningFinishedAt,
            String? reasoningSegmentsJson,
          }) async {
            persistedTexts.add(reasoningText);
            if (reasoningFinishedAt != null) finishedAtWrites++;
          },
    );

    // Reasoning resumes after the transition.
    await controller.handleReasoningChunk(
      reasoningChunk('second '),
      state,
      updateReasoningInDb:
          (
            messageId, {
            String? reasoningText,
            DateTime? reasoningStartAt,
            String? reasoningSegmentsJson,
          }) async {
            persistedTexts.add(reasoningText);
          },
    );
    await controller.finishReasoningAndPersist(
      state.messageId,
      updateReasoningInDb:
          (
            messageId, {
            String? reasoningText,
            DateTime? reasoningStartAt,
            DateTime? reasoningFinishedAt,
            String? reasoningSegmentsJson,
          }) async {
            persistedTexts.add(reasoningText);
            if (reasoningFinishedAt != null) finishedAtWrites++;
          },
    );

    expect(
      persistedTexts.whereType<String>().last,
      'first second ',
      reason: 'the final text write carries the full accumulated snapshot',
    );
    expect(finishedAtWrites, 2, reason: 'finishedAt is never reverted');

    controller.cleanupTimers('assistant-message');
  });

  testWidgets('a failed flush is retried by the next chunk cadence', (
    tester,
  ) async {
    final controller = buildController(currentConversationId: 'conversation-1');
    final state = buildStreamingState();
    final writes = <String?>[];
    var shouldThrow = true;

    await controller.handleReasoningChunk(
      reasoningChunk('first '),
      state,
      updateReasoningInDb:
          (
            messageId, {
            String? reasoningText,
            DateTime? reasoningStartAt,
            String? reasoningSegmentsJson,
          }) async {
            writes.add(reasoningText);
            if (shouldThrow) throw Exception('db full');
          },
    );
    await tester.pump(const Duration(milliseconds: 500));
    expect(
      writes.length,
      1,
      reason: 'first flush attempt throws and is logged',
    );

    // Next chunk re-marks dirty; the retry succeeds with the full snapshot.
    shouldThrow = false;
    await controller.handleReasoningChunk(
      reasoningChunk('second '),
      state,
      updateReasoningInDb:
          (
            messageId, {
            String? reasoningText,
            DateTime? reasoningStartAt,
            String? reasoningSegmentsJson,
          }) async {
            writes.add(reasoningText);
          },
    );
    await tester.pump(const Duration(milliseconds: 500));
    expect(writes.length, 2, reason: 'retry write succeeds');
    expect(writes.last, 'first second ');

    controller.cleanupTimers('assistant-message');
  });

  testWidgets('onStreamTick fires once per 150ms UI window', (tester) async {
    var ticks = 0;
    final controller = StreamController(
      chatService: ChatService(),
      onStateChanged: () {},
      onStreamTick: () => ticks++,
      getSettingsProvider: SettingsProvider.new,
      getCurrentConversationId: () => 'conversation-1',
    );
    final state = buildStreamingState();

    for (var i = 0; i < 4; i++) {
      await controller.handleReasoningChunk(
        reasoningChunk('t$i '),
        state,
        updateReasoningInDb:
            (
              messageId, {
              String? reasoningText,
              DateTime? reasoningStartAt,
              String? reasoningSegmentsJson,
            }) async {},
      );
    }
    await tester.pump(const Duration(milliseconds: 150));
    expect(ticks, 1, reason: '4 chunks collapse into one tick');

    await tester.pump(const Duration(milliseconds: 150));
    expect(ticks, 1, reason: 'no chunks in the next window -> no tick');

    controller.cleanupTimers('assistant-message');
  });

  testWidgets('cleanupTimers cancels pending reasoning flush and UI timer', (
    tester,
  ) async {
    final controller = buildController(currentConversationId: 'conversation-1');
    final state = buildStreamingState();
    var writes = 0;
    var notifies = 0;
    final notifier = controller.streamingContentNotifier.getNotifier(
      'assistant-message',
    );
    notifier.addListener(() => notifies++);

    await controller.handleReasoningChunk(
      reasoningChunk('x'),
      state,
      updateReasoningInDb:
          (
            messageId, {
            String? reasoningText,
            DateTime? reasoningStartAt,
            String? reasoningSegmentsJson,
          }) async {
            writes++;
          },
    );

    controller.cleanupTimers('assistant-message');
    await tester.pump(const Duration(milliseconds: 700));

    expect(writes, 0, reason: 'cancelled flush timer never fires');
    expect(notifies, 0, reason: 'cancelled UI timer never fires');
  });

  testWidgets('failed flush is logged and finish path still persists', (
    tester,
  ) async {
    final controller = buildController();
    final state = buildStreamingState();
    final calls = <String?>[];
    var shouldThrow = true;

    await controller.handleReasoningChunk(
      reasoningChunk('boo '),
      state,
      updateReasoningInDb:
          (
            messageId, {
            String? reasoningText,
            DateTime? reasoningStartAt,
            String? reasoningSegmentsJson,
          }) async {
            calls.add(reasoningText);
            if (shouldThrow) throw Exception('db full');
          },
    );

    await tester.pump(const Duration(milliseconds: 500));
    expect(
      calls.length,
      1,
      reason: 'flush attempted once; the throw is caught inside the timer',
    );

    shouldThrow = false;
    await controller.finishReasoningAndPersist(
      state.messageId,
      updateReasoningInDb:
          (
            messageId, {
            String? reasoningText,
            DateTime? reasoningStartAt,
            DateTime? reasoningFinishedAt,
            String? reasoningSegmentsJson,
          }) async {
            calls.add(reasoningText);
          },
    );

    expect(calls.length, 3, reason: 'finish path persists text + segments');
    expect(calls[1], 'boo ', reason: 'final text write recovers the snapshot');

    controller.cleanupTimers('assistant-message');
  });

  testWidgets('thinking-card UI updates coalesce to one per 150ms', (
    tester,
  ) async {
    final controller = buildController(currentConversationId: 'conversation-1');
    final state = buildStreamingState();
    final notifier = controller.streamingContentNotifier.getNotifier(
      'assistant-message',
    );
    var notifies = 0;
    notifier.addListener(() => notifies++);

    for (var i = 0; i < 4; i++) {
      await controller.handleReasoningChunk(
        reasoningChunk('t$i '),
        state,
        updateReasoningInDb:
            (
              messageId, {
              String? reasoningText,
              DateTime? reasoningStartAt,
              String? reasoningSegmentsJson,
            }) async {},
      );
    }

    await tester.pump(const Duration(milliseconds: 149));
    expect(notifies, 0);
    await tester.pump(const Duration(milliseconds: 2));
    expect(notifies, 1, reason: '4 chunks collapse into one UI update');
    expect(notifier.value.reasoningText, 't0 t1 t2 t3 ');

    controller.cleanupTimers('assistant-message');
  });
}
