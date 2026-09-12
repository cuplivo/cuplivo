import 'dart:convert';

import 'package:Cuplivo/core/database/business_preferences.dart';
import 'package:Cuplivo/core/models/chat_message.dart';
import 'package:Cuplivo/core/models/conversation.dart';
import 'package:Cuplivo/core/providers/settings_provider.dart';
import 'package:Cuplivo/core/services/chat/chat_service.dart';
import 'package:Cuplivo/core/services/generation_engine.dart';
import 'package:Cuplivo/features/home/controllers/chat_controller.dart';
import 'package:Cuplivo/features/home/controllers/stream_controller.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

/// Records the silent payload writes triggered by a manual toggle.
class _RecordingChatService extends ChatService {
  final List<({String messageId, String? segmentsJson})> reasoningUpdates = [];

  /// In-memory conversation/message store for the ChatController scenarios.
  final Map<String, List<ChatMessage>> _messagesByConversation =
      <String, List<ChatMessage>>{};

  /// When set, [updateMessageSilent] fails like a DB write error would.
  bool failSilentUpdates = false;

  void seedMessage(ChatMessage message) {
    (_messagesByConversation[message.conversationId] ??= <ChatMessage>[]).add(
      message,
    );
  }

  @override
  int getMessageCount(String conversationId) =>
      _messagesByConversation[conversationId]?.length ?? 0;

  @override
  List<ChatMessage> getRecentMessages(
    String conversationId, {
    int minMessages = ChatService.defaultInitialMessageMin,
    int textBudget = ChatService.defaultInitialTextBudget,
    int maxMessages = ChatService.defaultInitialMessageMax,
  }) => List<ChatMessage>.of(
    _messagesByConversation[conversationId] ?? const <ChatMessage>[],
  );

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
    if (failSilentUpdates) throw Exception('db write failed');
    if (reasoningSegmentsJson != null) {
      reasoningUpdates.add((
        messageId: messageId,
        segmentsJson: reasoningSegmentsJson,
      ));
    }
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  StreamController buildController(ChatService chatService) {
    return StreamController(
      chatService: chatService,
      onStateChanged: () {},
      getSettingsProvider: () =>
          SettingsProvider(preferences: BusinessPreferences.memoryForTests()),
      getCurrentConversationId: () => 'conversation-1',
    );
  }

  ReasoningSegmentData segment(String text, {required bool expanded}) {
    return ReasoningSegmentData()
      ..text = text
      ..expanded = expanded
      ..finishedAt = DateTime(2024, 1, 1);
  }

  test('buildReasoningSegmentsJson emits a full v2 payload preserving '
      'segments, contentSplits and reasoningDetails', () {
    final controller = buildController(_RecordingChatService());
    controller.setReasoningSegments('m1', [
      segment('first', expanded: true),
      segment('second', expanded: false),
    ]);
    controller.setContentSplitData(
      'm1',
      const ContentSplitData(
        offsets: [5],
        reasoningCounts: [1],
        toolCounts: [0],
      ),
    );
    controller.reasoningDetails['m1'] = const [
      {'type': 'reasoning.text', 'text': 'signed'},
    ];

    final payload = controller.buildReasoningSegmentsJson('m1');

    expect(payload, isNotNull);
    final decoded = jsonDecode(payload!) as Map<String, dynamic>;
    expect(decoded['v'], 2);
    final segments = (decoded['segments'] as List).cast<Map>();
    expect(segments, hasLength(2));
    expect(segments[0]['expanded'], isTrue);
    expect(segments[1]['expanded'], isFalse);
    final splits = (decoded['contentSplits'] as Map).cast<String, dynamic>();
    expect(splits['offsets'], const [5]);
    expect(splits['reasoningCounts'], const [1]);
    expect(splits['toolCounts'], const [0]);
    expect(decoded['reasoningDetails'], isNotNull);
  });

  test('buildReasoningSegmentsJson returns null without segments (plain '
      'reasoningText fallback stays out of scope)', () {
    final controller = buildController(_RecordingChatService());
    controller.setReasoningData('m1', ReasoningData()..text = 'plain');

    expect(controller.buildReasoningSegmentsJson('m1'), isNull);
  });

  test('a message that never had splits keeps the legacy segments-only '
      'shape', () {
    final controller = buildController(_RecordingChatService());
    controller.setReasoningSegments('m1', [segment('think', expanded: true)]);

    final payload = controller.buildReasoningSegmentsJson('m1')!;

    expect(jsonDecode(payload), isA<List<dynamic>>());
  });

  test('persistReasoningSegments writes the built payload through '
      'updateMessageSilent', () async {
    final chatService = _RecordingChatService();
    final controller = buildController(chatService);
    controller.setReasoningSegments('m1', [segment('think', expanded: true)]);

    final payload = controller.buildReasoningSegmentsJson('m1')!;
    await controller.persistReasoningSegments('m1', payload);

    expect(chatService.reasoningUpdates, hasLength(1));
    expect(chatService.reasoningUpdates.single.messageId, 'm1');
    expect(chatService.reasoningUpdates.single.segmentsJson, payload);
  });

  test('persisted expanded flag round-trips through deserialize', () {
    final controller = buildController(_RecordingChatService());
    controller.setReasoningSegments('m1', [segment('think', expanded: true)]);

    final expanded = controller.buildReasoningSegmentsJson('m1')!;
    expect(
      controller.deserializeReasoningSegments(expanded).single.expanded,
      isTrue,
    );

    controller.reasoningSegments['m1']!.single.expanded = false;
    final collapsed = controller.buildReasoningSegmentsJson('m1')!;
    expect(
      controller.deserializeReasoningSegments(collapsed).single.expanded,
      isFalse,
    );
  });

  test('syncEngineUiState mirrors vendor reasoningDetails into the payload '
      '(issue #737 follow-up: a same-session toggle must not drop them)', () {
    final controller = buildController(_RecordingChatService());
    const details = [
      {'type': 'reasoning.text', 'text': 'signed'},
    ];

    controller.syncEngineUiState(
      'm1',
      GenerationSlotUiState(
        reasoningText: 'think',
        segments: [segment('think', expanded: true)],
        contentSplitOffsets: const [0],
        reasoningCountAtSplit: const [1],
        toolCountAtSplit: const [0],
        toolEvents: const [],
        totalTokens: 0,
        reasoningDetails: details,
      ),
    );

    expect(controller.reasoningDetails['m1'], details);
    final payload = controller.buildReasoningSegmentsJson('m1')!;
    final decoded = jsonDecode(payload) as Map<String, dynamic>;
    expect(decoded['reasoningDetails'], details);
  });

  test('persistReasoningSegments logs a DB failure instead of leaving it '
      'unhandled', () async {
    final chatService = _RecordingChatService()..failSilentUpdates = true;
    final controller = buildController(chatService);
    controller.setReasoningSegments('m1', [segment('think', expanded: true)]);
    final payload = controller.buildReasoningSegmentsJson('m1')!;

    final logs = <String>[];
    final original = debugPrint;
    debugPrint = (String? message, {int? wrapWidth}) {
      if (message != null) logs.add(message);
    };
    addTearDown(() => debugPrint = original);

    await controller.persistReasoningSegments('m1', payload);

    expect(logs.any((line) => line.contains('persist failed for m1')), isTrue);
  });

  test('persistReasoningExpansionIfSettled swaps the settled row, invalidates '
      'the grouped cache and persists the payload', () {
    final chatService = _RecordingChatService();
    final conversation = Conversation(id: 'c1', title: 'T');
    final seedPayload = serializeReasoningSegmentsWithSplits([
      segment('think', expanded: true),
    ]);
    chatService.seedMessage(
      ChatMessage(
        id: 'm1',
        role: 'assistant',
        content: 'answer',
        conversationId: conversation.id,
        isStreaming: false,
        reasoningSegmentsJson: seedPayload,
      ),
    );

    final chatController = ChatController(chatService: chatService);
    chatController.setCurrentConversation(conversation);
    final controller = buildController(chatService);
    controller.setReasoningSegments('m1', [segment('think', expanded: false)]);

    // Prime the grouped cache with the pre-toggle row.
    final before = chatController.groupedMessages;
    expect((before['m1']!.single.reasoningSegmentsJson!), seedPayload);

    controller.persistReasoningExpansionIfSettled(
      'm1',
      chatController: chatController,
    );

    // The live list row was swapped with the new payload...
    final swapped = chatController.messages.single.reasoningSegmentsJson!;
    final swappedDecoded = (jsonDecode(swapped) as List).cast<Map>().single;
    expect(swappedDecoded['expanded'], isFalse);
    // ...the grouped cache was invalidated (a fresh map, not the memoized
    // one) and reflects the new row...
    final after = chatController.groupedMessages;
    expect(identical(after, before), isFalse);
    expect(after['m1']!.single.reasoningSegmentsJson, swapped);
    // ...and the payload reached the database layer.
    expect(chatService.reasoningUpdates, hasLength(1));
    expect(chatService.reasoningUpdates.single.segmentsJson, swapped);
  });

  test('persistReasoningExpansionIfSettled skips streaming and unknown '
      'messages', () {
    final chatService = _RecordingChatService();
    final conversation = Conversation(id: 'c1', title: 'T');
    final streamingPayload = serializeReasoningSegmentsWithSplits([
      segment('think', expanded: true),
    ]);
    chatService.seedMessage(
      ChatMessage(
        id: 'm-streaming',
        role: 'assistant',
        content: 'partial',
        conversationId: conversation.id,
        isStreaming: true,
        reasoningSegmentsJson: streamingPayload,
      ),
    );

    final chatController = ChatController(chatService: chatService);
    chatController.setCurrentConversation(conversation);
    final controller = buildController(chatService);
    controller.setReasoningSegments('m-streaming', [
      segment('think', expanded: false),
    ]);
    final cacheBefore = chatController.groupedMessages;

    controller.persistReasoningExpansionIfSettled(
      'm-streaming',
      chatController: chatController,
    );
    controller.persistReasoningExpansionIfSettled(
      'm-unknown',
      chatController: chatController,
    );

    expect(chatService.reasoningUpdates, isEmpty);
    expect(
      chatController.messages.single.reasoningSegmentsJson,
      streamingPayload,
    );
    // Nothing changed, so the memoized cache was not rebuilt either.
    expect(identical(chatController.groupedMessages, cacheBefore), isTrue);
  });

  test('persistReasoningExpansionIfSettled also skips rows the engine still '
      'tracks as actively streaming (settle-window race)', () {
    final chatService = _RecordingChatService();
    final conversation = Conversation(id: 'c1', title: 'T');
    final payload = serializeReasoningSegmentsWithSplits([
      segment('think', expanded: true),
    ]);
    chatService.seedMessage(
      ChatMessage(
        id: 'm-active',
        role: 'assistant',
        content: 'partial',
        conversationId: conversation.id,
        // The engine clears this row flag before it publishes its settle
        // snapshot, so the controller's own set is the authority in that
        // window.
        isStreaming: false,
        reasoningSegmentsJson: payload,
      ),
    );

    final chatController = ChatController(chatService: chatService);
    chatController.setCurrentConversation(conversation);
    final controller = buildController(chatService);
    controller.setReasoningSegments('m-active', [
      segment('think', expanded: false),
    ]);
    controller.markStreamingStarted('m-active');
    final cacheBefore = chatController.groupedMessages;

    controller.persistReasoningExpansionIfSettled(
      'm-active',
      chatController: chatController,
    );

    expect(chatService.reasoningUpdates, isEmpty);
    expect(chatController.messages.single.reasoningSegmentsJson, payload);
    expect(identical(chatController.groupedMessages, cacheBefore), isTrue);
  });
}
