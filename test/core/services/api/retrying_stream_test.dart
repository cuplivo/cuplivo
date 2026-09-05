import 'dart:async';
import 'dart:io';

import 'package:Cuplivo/core/models/auto_retry_options.dart';
import 'package:Cuplivo/core/services/api/retrying_stream.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

AutoRetryOptions _fastRetry({int maxRetries = 3}) => AutoRetryOptions(
  enabled: true,
  maxRetries: maxRetries,
  initialDelayMs: 0,
  multiplier: 2.0,
  maxDelayMs: 0,
  jitter: false,
  retryOnNetworkError: true,
  retryStatusCodes: const {429},
  retryKeywords: const [],
  stopKeywords: const [],
);

Future<(List<String>, Object?)> _collect(Stream<String> stream) async {
  final out = <String>[];
  Object? error;
  try {
    await for (final item in stream) {
      out.add(item);
    }
  } catch (e) {
    error = e;
  }
  return (out, error);
}

void main() {
  test('fail-then-succeed retries and yields the recovered value', () async {
    var attempts = 0;
    final stream = retryingStream<String>(
      options: _fastRetry(),
      isCancelled: () => false,
      shouldRetry: (e) => true,
      retryEvent: (attempt, delay, err) => 'pending:$attempt:$delay',
      attemptStartEvent: () => 'start',
      attempt: (i) async* {
        attempts++;
        if (attempts == 1) throw HttpException('HTTP 429: busy');
        yield 'ok';
      },
    );
    final (items, error) = await _collect(stream);
    expect(error, isNull);
    expect(items.length, 3);
    expect(items[0].startsWith('pending:0:'), true);
    expect(items[1], 'start');
    expect(items[2], 'ok');
    expect(attempts, 2);
  });

  test('no retry after an attempt has yielded visible output', () async {
    var attempts = 0;
    final stream = retryingStream<String>(
      options: _fastRetry(),
      isCancelled: () => false,
      shouldRetry: (e) => true,
      attempt: (i) async* {
        attempts++;
        yield 'partial';
        throw HttpException('HTTP 500: later');
      },
    );
    final (items, error) = await _collect(stream);
    expect(items, ['partial']);
    expect(error, isA<HttpException>());
    expect(attempts, 1);
  });

  test('usage-only items do not block retry when isOutput is set', () async {
    var attempts = 0;
    final stream = retryingStream<String>(
      options: _fastRetry(),
      isCancelled: () => false,
      shouldRetry: (e) => true,
      isOutput: (s) => s.startsWith('payload'),
      attempt: (i) async* {
        attempts++;
        yield 'usage';
        if (attempts == 1) {
          throw HttpException('HTTP 429: busy');
        }
        yield 'payload:done';
      },
    );
    final (items, error) = await _collect(stream);
    expect(error, isNull);
    expect(items, ['usage', 'usage', 'payload:done']);
    expect(attempts, 2);
  });

  test('isCancelled interrupt throws ClientException without retry', () async {
    var attempts = 0;
    final stream = retryingStream<String>(
      options: _fastRetry(),
      isCancelled: () => true,
      shouldRetry: (e) => true,
      attempt: (i) async* {
        attempts++;
        yield 'x';
      },
    );
    final (items, error) = await _collect(stream);
    expect(items, isEmpty);
    expect(error, isA<http.ClientException>());
    expect(attempts, 0);
  });

  test('cancel during a long backoff completes immediately', () async {
    final gate = Completer<void>();
    var attempts = 0;
    final stream = retryingStream<String>(
      options: AutoRetryOptions(
        enabled: true,
        maxRetries: 5,
        initialDelayMs: 8000,
        multiplier: 2.0,
        maxDelayMs: 8000,
        jitter: false,
        retryOnNetworkError: true,
        retryStatusCodes: {429},
        retryKeywords: [],
        stopKeywords: [],
      ),
      isCancelled: () => gate.isCompleted,
      shouldRetry: (e) => true,
      cancelled: gate.future,
      attempt: (i) async* {
        attempts++;
        throw HttpException('HTTP 429: busy');
      },
    );
    final sw = Stopwatch()..start();
    late Future<(List<String>, Object?)> collectFuture;
    collectFuture = _collect(stream);
    await Future<void>.delayed(const Duration(milliseconds: 200));
    gate.complete();
    final (items, error) = await collectFuture;
    sw.stop();
    expect(items, isEmpty);
    expect(error, isA<http.ClientException>());
    expect(sw.elapsedMilliseconds, lessThan(1500));
    expect(attempts, 1);
  });

  test('maxRetries exhaustion rethrows the SAME last error instance', () async {
    final last = HttpException('HTTP 500: never');
    final stream = retryingStream<String>(
      options: _fastRetry(maxRetries: 1),
      isCancelled: () => false,
      shouldRetry: (e) => true,
      attempt: (i) async* {
        throw last;
      },
    );
    final (items, error) = await _collect(stream);
    expect(items, isEmpty);
    expect(identical(error, last), true);
  });

  test('disabled options never retry (first attempt only)', () async {
    var attempts = 0;
    final stream = retryingStream<String>(
      options: _fastRetry(maxRetries: 3).copyWith(enabled: false),
      isCancelled: () => false,
      shouldRetry: (e) => true,
      attempt: (i) async* {
        attempts++;
        throw HttpException('HTTP 429: busy');
      },
    );
    final (items, error) = await _collect(stream);
    expect(items, isEmpty);
    expect(error, isA<HttpException>());
    expect(attempts, 1);
  });

  test('retryEvent flows before backoff only', () async {
    var attempts = 0;
    final events = <String>[];
    final stream = retryingStream<String>(
      options: _fastRetry(maxRetries: 2),
      isCancelled: () => false,
      shouldRetry: (e) => e.toString().contains('429'),
      retryEvent: (a, d, e) {
        events.add('retry:$a');
        return 'event:$a';
      },
      attempt: (i) async* {
        attempts++;
        if (i < 2) {
          throw HttpException('HTTP 429: busy');
        }
        yield 'done';
      },
    );
    final (items, error) = await _collect(stream);
    expect(error, isNull);
    expect(events, ['retry:0', 'retry:1']);
    expect(items, ['event:0', 'event:1', 'done']);
    expect(attempts, 3);
  });

  test('non-retryable error propagates without an extra attempt', () async {
    var attempts = 0;
    final stream = retryingStream<String>(
      options: _fastRetry(),
      isCancelled: () => false,
      shouldRetry: (e) => false,
      attempt: (i) async* {
        attempts++;
        throw HttpException('HTTP 404: gone');
      },
    );
    final (items, error) = await _collect(stream);
    expect(items, isEmpty);
    expect(error, isA<HttpException>());
    expect(attempts, 1);
  });
}
