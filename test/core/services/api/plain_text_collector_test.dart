import 'dart:async';

import 'package:Cuplivo/core/providers/settings_provider.dart';
import 'package:Cuplivo/core/services/api/chat_api_service.dart';
import 'package:Cuplivo/core/services/api/plain_text_collector.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  ProviderConfig testConfig() {
    return ProviderConfig(
      id: 'CollectorTest',
      enabled: true,
      name: 'CollectorTest',
      apiKey: 'test-key',
      baseUrl: 'https://example.test',
      providerType: ProviderKind.openai,
      useResponseApi: false,
    );
  }

  PlainTextStreamSender fakeSender(
    StreamController<ChatStreamChunk> chunks, {
    void Function(String? requestId, int? thinkingBudget, bool ocrActive)?
    onParams,
  }) {
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
    }) {
      onParams?.call(requestId, thinkingBudget, ocrActive);
      return chunks.stream;
    };
  }

  test('collect accumulates chunk content into one string', () async {
    final chunks = StreamController<ChatStreamChunk>();
    addTearDown(() => chunks.close());
    final collector = PlainTextCollector(sendMessageStream: fakeSender(chunks));

    final future = collector.collect(
      config: testConfig(),
      modelId: 'm',
      messages: [
        {'role': 'user', 'content': 'hi'},
      ],
    );
    await pumpEventQueue();
    chunks
      ..add(ChatStreamChunk(content: 'Hel', isDone: false, totalTokens: 0))
      ..add(ChatStreamChunk(content: 'lo ', isDone: false, totalTokens: 0))
      ..add(ChatStreamChunk(content: 'World', isDone: true, totalTokens: 5));
    await chunks.close();

    expect(await future, 'Hello World');
  });

  test('onAccumulated reports the full buffer per non-empty chunk', () async {
    final chunks = StreamController<ChatStreamChunk>();
    addTearDown(() => chunks.close());
    final collector = PlainTextCollector(sendMessageStream: fakeSender(chunks));

    final snapshots = <String>[];
    final future = collector.collect(
      config: testConfig(),
      modelId: 'm',
      messages: const [],
      onAccumulated: snapshots.add,
    );
    await pumpEventQueue();
    chunks
      ..add(ChatStreamChunk(content: 'ab', isDone: false, totalTokens: 0))
      ..add(ChatStreamChunk(content: '', isDone: false, totalTokens: 0))
      ..add(ChatStreamChunk(content: 'c', isDone: true, totalTokens: 1));
    await chunks.close();
    await future;

    expect(snapshots, ['ab', 'abc']);
  });

  test(
    'coalesces live updates and flushes the final accumulated value',
    () async {
      final chunks = StreamController<ChatStreamChunk>();
      addTearDown(() => chunks.close());
      final collector = PlainTextCollector(
        sendMessageStream: fakeSender(chunks),
      );
      final snapshots = <String>[];

      final future = collector.collect(
        config: testConfig(),
        modelId: 'm',
        messages: const [],
        updateInterval: const Duration(milliseconds: 20),
        onAccumulated: snapshots.add,
      );
      await pumpEventQueue();
      chunks
        ..add(ChatStreamChunk(content: 'a', isDone: false, totalTokens: 0))
        ..add(ChatStreamChunk(content: 'b', isDone: false, totalTokens: 0))
        ..add(ChatStreamChunk(content: '', isDone: false, totalTokens: 0))
        ..add(ChatStreamChunk(content: 'c', isDone: true, totalTokens: 3));
      await chunks.close();

      expect(await future, 'abc');
      expect(snapshots, isNotEmpty);
      expect(snapshots.last, 'abc');
      expect(snapshots.length, lessThan(3));
    },
  );

  test('passes through requestId, thinkingBudget and ocrActive', () async {
    final chunks = StreamController<ChatStreamChunk>();
    addTearDown(() => chunks.close());
    String? seenRequestId;
    int? seenBudget;
    bool? seenOcr;
    final collector = PlainTextCollector(
      sendMessageStream: fakeSender(
        chunks,
        onParams: (requestId, thinkingBudget, ocrActive) {
          seenRequestId = requestId;
          seenBudget = thinkingBudget;
          seenOcr = ocrActive;
        },
      ),
    );

    final future = collector.collect(
      config: testConfig(),
      modelId: 'm',
      messages: const [],
      thinkingBudget: 1024,
      requestId: 'translate_1',
      ocrActive: true,
    );
    await pumpEventQueue();
    chunks.add(ChatStreamChunk(content: 'ok', isDone: true, totalTokens: 2));
    await chunks.close();
    await future;

    expect(seenRequestId, 'translate_1');
    expect(seenBudget, 1024);
    expect(seenOcr, isTrue);
  });

  test('propagates stream errors to the caller', () async {
    final chunks = StreamController<ChatStreamChunk>();
    addTearDown(() => chunks.close());
    final collector = PlainTextCollector(sendMessageStream: fakeSender(chunks));

    final future = collector.collect(
      config: testConfig(),
      modelId: 'm',
      messages: const [],
    );
    await pumpEventQueue();
    chunks.addError(Exception('boom'));
    await expectLater(future, throwsA(isA<Exception>()));
  });

  test('cancels a pending throttled update when the stream errors', () async {
    final chunks = StreamController<ChatStreamChunk>();
    addTearDown(() => chunks.close());
    final collector = PlainTextCollector(sendMessageStream: fakeSender(chunks));
    final snapshots = <String>[];

    final future = collector.collect(
      config: testConfig(),
      modelId: 'm',
      messages: const [],
      updateInterval: const Duration(milliseconds: 20),
      onAccumulated: snapshots.add,
    );
    await pumpEventQueue();
    chunks.add(
      ChatStreamChunk(content: 'partial', isDone: false, totalTokens: 1),
    );
    chunks.addError(Exception('boom'));

    await expectLater(future, throwsA(isA<Exception>()));
    await Future<void>.delayed(const Duration(milliseconds: 30));
    expect(snapshots, isEmpty);
  });
}
