import 'dart:async';

import 'package:Cuplivo/core/models/chat_message.dart';
import 'package:Cuplivo/core/models/token_usage.dart';
import 'package:Cuplivo/core/providers/settings_provider.dart';
import 'package:Cuplivo/core/services/api/chat_api_service.dart';
import 'package:Cuplivo/core/services/chat/chat_service.dart';
import 'package:Cuplivo/core/services/generation_engine.dart';
import 'package:Cuplivo/features/group_chat/services/group_chat_slot_runner.dart';
import 'package:Cuplivo/features/home/controllers/stream_controller.dart'
    as stream_ctrl;
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Records persistence calls instead of touching a real database.
class _RecordingChatService extends ChatService {
  final List<
    ({
      String messageId,
      String? content,
      bool? isStreaming,
      int? totalTokens,
      int? contextTokens,
      int? promptTokens,
      int? completionTokens,
      int? cachedTokens,
    })
  >
  updates = [];
  final List<({String messageId, String content})> silentContent = [];
  final List<({String messageId, DateTime? finishedAt})>
  reasoningFinishedAtUpdates = [];
  final List<({String messageId, String? segmentsJson})>
  reasoningSegmentsUpdates = [];
  final List<({String messageId, DateTime? finishedAt})>
  updateFinishedAtRecords = [];

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
    updates.add((
      messageId: messageId,
      content: content,
      isStreaming: isStreaming,
      totalTokens: totalTokens,
      contextTokens: contextTokens,
      promptTokens: promptTokens,
      completionTokens: completionTokens,
      cachedTokens: cachedTokens,
    ));
    if (reasoningFinishedAt != null) {
      updateFinishedAtRecords.add((
        messageId: messageId,
        finishedAt: reasoningFinishedAt,
      ));
    }
    if (reasoningSegmentsJson != null) {
      reasoningSegmentsUpdates.add((
        messageId: messageId,
        segmentsJson: reasoningSegmentsJson,
      ));
    }
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
    Object? translation,
    String? reasoningSegmentsJson,
    int? promptTokens,
    int? completionTokens,
    int? cachedTokens,
    int? durationMs,
  }) async {
    if (content != null) {
      silentContent.add((messageId: messageId, content: content));
    }
    if (reasoningFinishedAt != null) {
      reasoningFinishedAtUpdates.add((
        messageId: messageId,
        finishedAt: reasoningFinishedAt,
      ));
    }
    if (reasoningSegmentsJson != null) {
      reasoningSegmentsUpdates.add((
        messageId: messageId,
        segmentsJson: reasoningSegmentsJson,
      ));
    }
  }

  @override
  Future<void> setGeminiThoughtSignature(
    String messageId,
    String signature,
  ) async {}

  @override
  Future<void> setToolEvents(
    String messageId,
    List<Map<String, dynamic>> events,
  ) async {}
}

void main() {
  Future<SettingsProvider> makeSettings() async {
    SharedPreferences.setMockInitialValues({});
    return SettingsProvider();
  }

  stream_ctrl.GenerationContext buildCtx(
    SettingsProvider settings,
    ProviderConfig config, {
    String messageId = 'm1',
    bool supportsReasoning = false,
  }) {
    return stream_ctrl.GenerationContext(
      assistantMessage: ChatMessage(
        id: messageId,
        role: 'assistant',
        content: '',
        conversationId: 'c1',
      ),
      apiMessages: [
        {'role': 'user', 'content': 'hi'},
      ],
      userMediaPaths: const [],
      allowImagesApiRouting: false,
      providerKey: 'SlotRunnerTest',
      modelId: 'test-model',
      assistant: null,
      settings: settings,
      config: config,
      toolDefs: const [],
      supportsReasoning: supportsReasoning,
      enableReasoning: supportsReasoning,
      streamOutput: true,
    );
  }

  ProviderConfig testConfig() {
    return ProviderConfig(
      id: 'SlotRunnerTest',
      enabled: true,
      name: 'SlotRunnerTest',
      apiKey: 'test-key',
      baseUrl: 'https://example.test',
      providerType: ProviderKind.openai,
      useResponseApi: false,
    );
  }

  EngineChatStreamProvider fakeSender(
    StreamController<ChatStreamChunk> chunks,
  ) {
    return ({
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
      String Function(int received, int requested)? partialImageNotice,
    }) => chunks.stream;
  }

  Future<void> waitForSilentContent(
    _RecordingChatService svc,
    String messageId,
    String target,
  ) async {
    for (var i = 0; i < 300; i++) {
      final matches = svc.silentContent
          .where((c) => c.messageId == messageId && c.content == target)
          .toList();
      if (matches.isNotEmpty) return;
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    fail('timed out waiting for persisted content "$target"');
  }

  Future<void> waitForFinalize(
    _RecordingChatService svc,
    String messageId,
  ) async {
    for (var i = 0; i < 300; i++) {
      final matches = svc.updates.where(
        (u) => u.messageId == messageId && u.isStreaming == false,
      );
      if (matches.isNotEmpty) return;
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    fail('timed out waiting for finalize (isStreaming: false)');
  }

  (GroupChatSlotRunner, GenerationEngine) makeRunner(
    _RecordingChatService fake,
    stream_ctrl.StreamController sc,
    StreamController<ChatStreamChunk> chunks,
  ) {
    final engine = GenerationEngine(
      chatService: fake,
      streamProvider: fakeSender(chunks),
    );
    return (GroupChatSlotRunner(engine: engine, streamController: sc), engine);
  }

  test('reasoning ends when the body starts: finishedAt persisted, split '
      'recorded so the panel renders above the body', () async {
    final settings = await makeSettings();
    final fake = _RecordingChatService();
    final sc = stream_ctrl.StreamController(
      chatService: fake,
      onStateChanged: () {},
      getSettingsProvider: () => settings,
      getCurrentConversationId: () => 'c1',
    );
    final chunkStream = StreamController<ChatStreamChunk>();
    addTearDown(() => chunkStream.close());
    final (runner, _) = makeRunner(fake, sc, chunkStream);

    final running = runner.executeStream(
      buildCtx(
        settings,
        testConfig(),
        messageId: 'm1',
        supportsReasoning: true,
      ),
    );

    await pumpEventQueue();
    chunkStream.add(
      ChatStreamChunk(
        content: '',
        reasoning: 'let me think about this',
        isDone: false,
        totalTokens: 0,
      ),
    );
    await pumpEventQueue();
    expect(
      fake.updateFinishedAtRecords,
      isEmpty,
      reason: 'timer keeps running while only reasoning streams',
    );
    // Live bridge: the page reasoning maps must carry the in-flight segment.
    expect(sc.reasoning['m1'], isNotNull);
    expect(sc.reasoning['m1']!.text, 'let me think about this');
    expect(sc.reasoning['m1']!.finishedAt, isNull);
    expect(sc.reasoningSegments['m1'], hasLength(1));

    chunkStream.add(
      ChatStreamChunk(content: 'Answer', isDone: false, totalTokens: 3),
    );
    await pumpEventQueue();
    expect(
      fake.updateFinishedAtRecords,
      isEmpty,
      reason: 'elapsed timer keeps running while the body streams',
    );
    // Live bridge: the content split is mirrored into the page maps.
    expect(sc.contentSplits['m1']!.offsets, [0]);

    chunkStream.add(ChatStreamChunk(content: '', isDone: true, totalTokens: 3));
    await chunkStream.close();
    await running.timeout(const Duration(seconds: 5));
    await waitForFinalize(fake, 'm1');

    // Split recorded at offset 0 → reasoning card renders above the body.
    final segmentsUpdate = fake.reasoningSegmentsUpdates.lastOrNull;
    expect(segmentsUpdate, isNotNull);
    final splits = sc.deserializeContentSplits(segmentsUpdate!.segmentsJson);
    expect(splits?.offsets, [0]);
    expect(
      fake.updateFinishedAtRecords.where(
        (u) => u.messageId == 'm1' && u.finishedAt != null,
      ),
      isNotEmpty,
      reason: 'final persisted row must carry reasoningFinishedAt',
    );
  });

  test('executeStream future completes only after the stream ends and the '
      'final content is persisted', () async {
    final settings = await makeSettings();
    final fake = _RecordingChatService();
    final sc = stream_ctrl.StreamController(
      chatService: fake,
      onStateChanged: () {},
      getSettingsProvider: () => settings,
      getCurrentConversationId: () => 'c1',
    );
    final chunkStream = StreamController<ChatStreamChunk>();
    addTearDown(() => chunkStream.close());
    final (runner, _) = makeRunner(fake, sc, chunkStream);

    var completed = false;
    final running = runner
        .executeStream(buildCtx(settings, testConfig()))
        .then((_) => completed = true);

    await pumpEventQueue();
    chunkStream.add(
      ChatStreamChunk(content: 'Hello ', isDone: false, totalTokens: 0),
    );
    // Wait until the first chunk was persisted while the stream is in flight.
    await waitForSilentContent(fake, 'm1', 'Hello ');

    // Regression: the future must NOT complete before the stream ended —
    // otherwise callers (director turn builder) read the still-empty
    // placeholder content instead of the final assistant message.
    expect(completed, isFalse, reason: 'stream must still be in flight');
    expect(
      fake.updates.where((u) => u.isStreaming == false),
      isEmpty,
      reason: 'final write must not happen before the stream ends',
    );

    chunkStream.add(
      ChatStreamChunk(content: 'World', isDone: true, totalTokens: 5),
    );
    await chunkStream.close();
    await running.timeout(const Duration(seconds: 5));

    expect(completed, isTrue);
    final finalUpdate = fake.updates.lastWhere((u) => u.isStreaming == false);
    expect(finalUpdate.content, 'Hello World');
  });

  test(
    'finish persists consumed totals and contextTokens (multi-round)',
    () async {
      final settings = await makeSettings();
      final fake = _RecordingChatService();
      final sc = stream_ctrl.StreamController(
        chatService: fake,
        onStateChanged: () {},
        getSettingsProvider: () => settings,
        getCurrentConversationId: () => 'c1',
      );
      final chunkStream = StreamController<ChatStreamChunk>();
      addTearDown(() => chunkStream.close());
      final (runner, _) = makeRunner(fake, sc, chunkStream);

      final running = runner.executeStream(buildCtx(settings, testConfig()));

      // Round 1: first request's usage (context = 1020).
      const round1Usage = TokenUsage(
        promptTokens: 1000,
        completionTokens: 20,
        cachedTokens: 300,
        totalTokens: 1020,
      );
      await pumpEventQueue();
      chunkStream.add(
        ChatStreamChunk(
          content: 'thinking',
          isDone: false,
          totalTokens: 1020,
          usage: round1Usage,
        ),
      );

      // Round 2: follow-up request's own usage, consumed = sum of both rounds.
      const round2Usage = TokenUsage(
        promptTokens: 1200,
        completionTokens: 500,
        cachedTokens: 400,
        totalTokens: 1700,
      );
      const consumed = TokenUsage(
        promptTokens: 2200,
        completionTokens: 520,
        cachedTokens: 700,
        totalTokens: 2720,
      );
      chunkStream.add(
        ChatStreamChunk(
          content: 'Answer',
          isDone: false,
          totalTokens: 1700,
          usage: round2Usage,
          consumedUsage: consumed,
        ),
      );
      chunkStream.add(
        ChatStreamChunk(
          content: '',
          isDone: true,
          totalTokens: 1700,
          usage: round2Usage,
          consumedUsage: consumed,
        ),
      );
      await chunkStream.close();
      await running.timeout(const Duration(seconds: 5));

      final finalUpdate = fake.updates.lastWhere((u) => u.isStreaming == false);
      expect(finalUpdate.content, 'thinkingAnswer');
      // Consumed semantics: sum across both rounds.
      expect(finalUpdate.totalTokens, 2720);
      expect(finalUpdate.promptTokens, 2200);
      expect(finalUpdate.completionTokens, 520);
      expect(finalUpdate.cachedTokens, 700);
      // Context semantics: last round's total.
      expect(finalUpdate.contextTokens, 1700);
    },
  );

  test('cancel completes the future and finalizes the message', () async {
    final settings = await makeSettings();
    final fake = _RecordingChatService();
    final sc = stream_ctrl.StreamController(
      chatService: fake,
      onStateChanged: () {},
      getSettingsProvider: () => settings,
      getCurrentConversationId: () => 'c1',
    );
    final chunkStream = StreamController<ChatStreamChunk>();
    addTearDown(() => chunkStream.close());
    final (runner, _) = makeRunner(fake, sc, chunkStream);

    final running = runner.executeStream(buildCtx(settings, testConfig()));
    await pumpEventQueue();
    chunkStream.add(
      ChatStreamChunk(content: 'Partial', isDone: false, totalTokens: 0),
    );
    await waitForSilentContent(fake, 'm1', 'Partial');

    runner.cancel('m1');
    await running.timeout(const Duration(seconds: 5));

    // Real HTTP: cancelRequest unwinds the stream, the engine's fail path
    // persists the partial content with isStreaming: false. The fake stream
    // only unwinds when closed — mirror that, then assert the finalize.
    await chunkStream.close();
    await waitForFinalize(fake, 'm1');
  });

  test('stream error completes the future and finalizes the message', () async {
    final settings = await makeSettings();
    final fake = _RecordingChatService();
    final sc = stream_ctrl.StreamController(
      chatService: fake,
      onStateChanged: () {},
      getSettingsProvider: () => settings,
      getCurrentConversationId: () => 'c1',
    );
    final chunkStream = StreamController<ChatStreamChunk>();
    addTearDown(() => chunkStream.close());
    final (runner, _) = makeRunner(fake, sc, chunkStream);

    final running = runner.executeStream(buildCtx(settings, testConfig()));
    await pumpEventQueue();
    chunkStream.addError(Exception('boom'));
    await running.timeout(const Duration(seconds: 5));

    final finalUpdate = fake.updates.lastWhere((u) => u.isStreaming == false);
    // Page policy: raw error text, no 'Error: ' prefix (mirrors the
    // pre-engine chat_actions/group executor behavior).
    expect(finalUpdate.content, 'Exception: boom');
  });

  test('tool events flow into the page maps (live tool cards)', () async {
    final settings = await makeSettings();
    final fake = _RecordingChatService();
    final sc = stream_ctrl.StreamController(
      chatService: fake,
      onStateChanged: () {},
      getSettingsProvider: () => settings,
      getCurrentConversationId: () => 'c1',
    );
    final chunkStream = StreamController<ChatStreamChunk>();
    addTearDown(() => chunkStream.close());
    final (runner, _) = makeRunner(fake, sc, chunkStream);

    final running = runner.executeStream(buildCtx(settings, testConfig()));
    await pumpEventQueue();
    chunkStream.add(
      ChatStreamChunk(
        content: '',
        isDone: false,
        totalTokens: 0,
        toolCalls: [
          ToolCallInfo(
            id: 'tool-1',
            name: 'search_web',
            arguments: const {'query': 'Kelivo'},
          ),
        ],
      ),
    );
    await pumpEventQueue();

    // Live bridge: the call placeholder is mirrored into the page maps.
    final parts = sc.toolParts['m1'];
    expect(parts, hasLength(1));
    expect(parts!.single.toolName, 'search_web');
    expect(parts.single.loading, isTrue);

    chunkStream.add(
      ChatStreamChunk(
        content: '',
        isDone: false,
        totalTokens: 0,
        toolResults: [
          ToolResultInfo(
            id: 'tool-1',
            name: 'search_web',
            arguments: const {'query': 'Kelivo'},
            content: '{"items":[{"title":"Hit","url":"https://x.example"}]}',
          ),
        ],
      ),
    );
    await pumpEventQueue();

    // The result replaces the placeholder: loading cleared, content set.
    final completed = sc.toolParts['m1']!;
    expect(completed, hasLength(1));
    expect(completed.single.loading, isFalse);
    expect(completed.single.content, contains('"title":"Hit"'));

    chunkStream.add(ChatStreamChunk(content: '', isDone: true, totalTokens: 0));
    await chunkStream.close();
    await running.timeout(const Duration(seconds: 5));
  });

  test('truncation warning fires once with the raw reason', () async {
    final settings = await makeSettings();
    final fake = _RecordingChatService();
    final sc = stream_ctrl.StreamController(
      chatService: fake,
      onStateChanged: () {},
      getSettingsProvider: () => settings,
      getCurrentConversationId: () => 'c1',
    );
    final chunkStream = StreamController<ChatStreamChunk>();
    addTearDown(() => chunkStream.close());
    final reasons = <String>[];
    final runner = GroupChatSlotRunner(
      engine: GenerationEngine(
        chatService: fake,
        streamProvider: fakeSender(chunkStream),
      ),
      streamController: sc,
      onTruncationWarning: reasons.add,
    );

    final running = runner.executeStream(buildCtx(settings, testConfig()));
    await pumpEventQueue();
    chunkStream.add(
      ChatStreamChunk(
        content: 'partial answer',
        isDone: true,
        totalTokens: 10,
        truncationReason: 'max_tokens',
      ),
    );
    await chunkStream.close();
    await running.timeout(const Duration(seconds: 5));

    expect(reasons, ['max_tokens']);
  });
}
