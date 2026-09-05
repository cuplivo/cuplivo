import 'dart:io';

import 'package:Cuplivo/core/models/auto_retry_options.dart';
import 'package:Cuplivo/core/providers/settings_provider.dart';
import 'package:Cuplivo/core/services/api/chat_api_service.dart';
import 'package:Cuplivo/core/services/api/retry_policy.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

/// Options with 0 ms delays (fast tests).
AutoRetryOptions _fastRetry() => AutoRetryOptions(
  enabled: true,
  maxRetries: 2,
  initialDelayMs: 0,
  multiplier: 2.0,
  maxDelayMs: 0,
  jitter: false,
  retryOnNetworkError: true,
  retryStatusCodes: const {408, 425, 429, 500, 502, 503, 504},
  retryKeywords: const ['访问量过大', 'too many requests'],
  stopKeywords: const ['余额', 'quota'],
);

ProviderConfig _openAIConfig(String baseUrl) => ProviderConfig(
  id: 'test-openai',
  enabled: true,
  name: 'test',
  apiKey: 'test',
  baseUrl: baseUrl,
  models: const [],
);

/// Drops every request's socket -> status-less network error.
Future<HttpServer> _dropConnectionServer(void Function() onRequest) async {
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  server.listen((request) async {
    onRequest();
    try {
      final socket = await request.response.detachSocket();
      socket.destroy();
    } catch (_) {}
  });
  return server;
}

/// Always answers 429 with a limit keyword body.
Future<HttpServer> _rateLimitServer(int Function() counter) async {
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  server.listen((request) {
    counter();
    request.response
      ..statusCode = 429
      ..headers.contentType = ContentType.text
      ..write('HTTP 429: 访问量过大');
    request.response.close();
  });
  return server;
}

Future<(List<ChatStreamChunk>, Object?)> _collect(
  Stream<ChatStreamChunk> stream,
) async {
  final out = <ChatStreamChunk>[];
  try {
    await for (final c in stream) {
      out.add(c);
    }
  } catch (e) {
    return (out, e);
  }
  return (out, null);
}

void main() {
  tearDown(() {
    ChatApiService.debugClientFactory = null;
    // The process-wide static is a test-facing global: reset it so retry
    // config never leaks into later tests in the same process.
    AutoRetryConfig.current = const AutoRetryOptions.defaults();
  });

  test('text chat retries status-less network errors', () async {
    var requests = 0;
    final server = await _dropConnectionServer(() => requests++);
    addTearDown(() => server.close(force: true));
    final stream = ChatApiService.sendMessageStream(
      config: _openAIConfig('http://127.0.0.1:${server.port}/v1'),
      modelId: 'gpt-4o-mini',
      messages: const [
        {'role': 'user', 'content': 'hi'},
      ],
      stream: false,
      requestId: 'nw-retry',
      retryOverride: _fastRetry(),
    );
    final (chunks, error) = await _collect(stream);
    expect(error, isNotNull);
    expect(requests, 3); // 1 + 2 retries
    // The retry countdown event reached the consumer.
    expect(chunks.where((c) => c.retryPending != null).length, 2);
    final pending = chunks.firstWhere((c) => c.retryPending != null);
    expect(pending.retryPending!.attempt, 1);
    expect(pending.retryPending!.maxRetries, 2);
    expect(pending.retryAttemptStart, false);
  });

  test('429 with retry keyword then a healthy SSE stream recovers', () async {
    var requests = 0;
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) async {
      requests++;
      if (requests == 1) {
        request.response
          ..statusCode = 429
          ..headers.contentType = ContentType.text
          ..write('大量请求: rate limit');
        await request.response.close();
        return;
      }
      request.response
        ..headers.contentType = ContentType.text
        ..write(
          'data: {"choices":[{"delta":{"content":"hel"}}]}\n\n'
          'data: {"choices":[{"delta":{"content":"lo"}}]}\n\n'
          'data: [DONE]\n\n',
        );
      await request.response.close();
    });
    addTearDown(() => server.close(force: true));
    final stream = ChatApiService.sendMessageStream(
      config: _openAIConfig('http://127.0.0.1:${server.port}/v1'),
      modelId: 'gpt-4o-mini',
      messages: const [
        {'role': 'user', 'content': 'hi'},
      ],
      stream: true,
      requestId: 'kw-retry',
      retryOverride: _fastRetry(),
    );
    final (chunks, error) = await _collect(stream);
    expect(error, isNull);
    expect(requests, 2);
    final text = chunks.map((c) => c.content).join();
    expect(text, 'hello');
    expect(chunks.where((c) => c.retryPending != null).length, greaterThan(0));
  });

  test('cancelRequest aborts a long backoff wait immediately', () async {
    final server = await _rateLimitServer(() => 0);
    addTearDown(() => server.close(force: true));
    final slow = _fastRetry().copyWith(
      maxRetries: 5,
      initialDelayMs: 8000,
      maxDelayMs: 8000,
    );
    final sw = Stopwatch()..start();
    late Future<(List<ChatStreamChunk>, Object?)> collectFuture;
    collectFuture = _collect(
      ChatApiService.sendMessageStream(
        config: _openAIConfig('http://127.0.0.1:${server.port}/v1'),
        modelId: 'gpt-4o-mini',
        messages: const [
          {'role': 'user', 'content': 'hi'},
        ],
        stream: false,
        requestId: 'cancel-backoff',
        retryOverride: slow,
      ),
    );
    await Future<void>.delayed(const Duration(milliseconds: 300));
    ChatApiService.cancelRequest('cancel-backoff');
    final (_, error) = await collectFuture;
    sw.stop();
    expect(error, isA<http.ClientException>());
    expect(sw.elapsedMilliseconds, lessThan(1500));
  });

  test('image generation never retries status-less disconnects', () async {
    var requests = 0;
    final server = await _dropConnectionServer(() => requests++);
    addTearDown(() => server.close(force: true));
    final stream = ChatApiService.sendMessageStream(
      config: _openAIConfig('http://127.0.0.1:${server.port}/v1'),
      modelId: 'dall-e-3',
      messages: const [
        {'role': 'user', 'content': 'a cat'},
      ],
      stream: false,
      requestId: 'img-retry',
      retryOverride: _fastRetry(),
    );
    final (_, error) = await _collect(stream);
    expect(error, isNotNull);
    expect(requests, 1);
  });

  test('disabled options keep current behavior (single attempt)', () async {
    var requests = 0;
    final server = await _dropConnectionServer(() => requests++);
    addTearDown(() => server.close(force: true));
    final stream = ChatApiService.sendMessageStream(
      config: _openAIConfig('http://127.0.0.1:${server.port}/v1'),
      modelId: 'gpt-4o-mini',
      messages: const [
        {'role': 'user', 'content': 'hi'},
      ],
      stream: false,
      requestId: 'off-retry',
      retryOverride: const AutoRetryOptions.defaults(),
    );
    final (_, error) = await _collect(stream);
    expect(error, isNotNull);
    expect(requests, 1);
  });
}
