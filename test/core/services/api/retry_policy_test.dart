import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:Cuplivo/core/models/auto_retry_options.dart';
import 'package:Cuplivo/core/services/api/retry_policy.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

AutoRetryOptions _options({
  bool enabled = false,
  int maxRetries = 3,
  int initialDelayMs = 1000,
  double multiplier = 2.0,
  int maxDelayMs = 30000,
  bool jitter = false,
  bool retryOnNetworkError = true,
  Set<int> retryStatusCodes = const <int>{},
  List<String> retryKeywords = const <String>[],
  List<String> stopKeywords = const <String>[],
}) {
  return AutoRetryOptions(
    enabled: enabled,
    maxRetries: maxRetries,
    initialDelayMs: initialDelayMs,
    multiplier: multiplier,
    maxDelayMs: maxDelayMs,
    jitter: jitter,
    retryOnNetworkError: retryOnNetworkError,
    retryStatusCodes: retryStatusCodes,
    retryKeywords: retryKeywords,
    stopKeywords: stopKeywords,
  );
}

void main() {
  group('httpStatusFromError', () {
    test('parses status from exception text', () {
      expect(
        httpStatusFromError(HttpException('HTTP 429: Too Many Requests')),
        429,
      );
      expect(httpStatusFromError(HttpException('http 503: unavailable')), 503);
    });

    test('returns null without a status', () {
      expect(httpStatusFromError(const SocketException('closed')), isNull);
      expect(httpStatusFromError(TimeoutException('t')), isNull);
    });
  });

  group('shouldRetryError', () {
    final enabled = _options(
      enabled: true,
      retryStatusCodes: {429, 500, 502, 503, 504},
      retryKeywords: ['rate limit', '超时'],
      stopKeywords: ['余额', 'quota'],
    );

    test('retries 429 and 5xx statuses, not 404', () {
      expect(
        shouldRetryError(HttpException('HTTP 429: rate limited'), enabled),
        true,
      );
      expect(
        shouldRetryError(HttpException('HTTP 503: unavailable'), enabled),
        true,
      );
      expect(
        shouldRetryError(HttpException('HTTP 404: not found'), enabled),
        false,
      );
    });

    test('retries retry keywords without a status', () {
      expect(
        shouldRetryError(HttpException('host busy: rate limit'), enabled),
        true,
      );
      expect(shouldRetryError(TimeoutException('request 超时'), enabled), true);
    });

    test('stop keywords beat retry keywords and status codes', () {
      expect(shouldRetryError(HttpException('HTTP 429: 余额不足'), enabled), false);
      expect(
        shouldRetryError(TimeoutException('quota exceeded'), enabled),
        false,
      );
    });

    test('transport failures honor retryOnNetworkError', () {
      expect(
        shouldRetryError(const SocketException('conn reset'), enabled),
        true,
      );
      expect(
        shouldRetryError(
          const SocketException('conn reset'),
          _options(enabled: true, retryOnNetworkError: false),
        ),
        false,
      );
      expect(
        shouldRetryError(http.ClientException('connection lost'), enabled),
        true,
      );
      expect(
        shouldRetryError(
          http.ClientException('connection lost'),
          _options(enabled: true, retryOnNetworkError: false),
        ),
        false,
      );
    });

    test('status-bearing ClientException is not a network miss', () {
      final e = http.ClientException('HTTP 404: gone');
      // Not a transport failure (has a status), not in codes -> no retry.
      expect(shouldRetryError(e, enabled), false);
    });

    test('mid-stream disconnect HttpException retries via abort message', () {
      expect(
        shouldRetryError(
          HttpException('Connection closed while receiving data'),
          enabled,
        ),
        true,
      );
    });

    test('user cancel never retries', () {
      expect(
        shouldRetryError(http.ClientException('cancelled'), enabled),
        false,
      );
      expect(
        shouldRetryError(
          DioException(
            requestOptions: RequestOptions(path: '/'),
            type: DioExceptionType.cancel,
          ),
          enabled,
        ),
        false,
      );
    });

    test('per-call retryOnNetworkError override wins', () {
      final e = const SocketException('down');
      expect(shouldRetryError(e, enabled, retryOnNetworkError: false), false);
      expect(
        shouldRetryError(
          e,
          _options(enabled: true, retryOnNetworkError: false),
          retryOnNetworkError: true,
        ),
        true,
      );
    });

    test('the enabled flag lives at the retry loop, not in the policy', () {
      // Retrying-stream tests own the enabled=false behavior; here we only
      // assert the policy ignores the enabled flag (it decides retryability).
      expect(
        shouldRetryError(
          HttpException('HTTP 500: boom'),
          _options(enabled: false, retryStatusCodes: {429, 500}),
        ),
        true,
      );
    });
  });

  group('isCancelledGenerationError', () {
    test('requestCancelled wins even over a 429', () {
      expect(
        isCancelledGenerationError(
          HttpException('HTTP 429: busy'),
          requestCancelled: true,
        ),
        true,
      );
    });

    test('ClientException cancelled counts as user cancel', () {
      expect(
        isCancelledGenerationError(
          http.ClientException('cancelled'),
          requestCancelled: false,
        ),
        true,
      );
    });
  });

  group('prepareErrorAction', () {
    test(
      'user stop -> skip, cancel without stop -> cancelled, else failed',
      () {
        expect(
          prepareErrorAction(
            http.ClientException('cancelled'),
            requestCancelled: true,
          ),
          PrepareErrorAction.skip,
        );
        expect(
          prepareErrorAction(
            http.ClientException('cancelled'),
            requestCancelled: false,
          ),
          PrepareErrorAction.cancelled,
        );
        expect(
          prepareErrorAction(
            HttpException('HTTP 500: boom'),
            requestCancelled: false,
          ),
          PrepareErrorAction.failed,
        );
      },
    );
  });

  group('backoffDelay', () {
    test('exponential then capped at maxDelay', () {
      final o = _options(
        enabled: true,
        initialDelayMs: 1000,
        multiplier: 2.0,
        maxDelayMs: 8000,
        jitter: false,
      );
      expect(backoffDelay(0, o).inMilliseconds, 1000);
      expect(backoffDelay(1, o).inMilliseconds, 2000);
      expect(backoffDelay(2, o).inMilliseconds, 4000);
      expect(backoffDelay(3, o).inMilliseconds, 8000);
      expect(backoffDelay(4, o).inMilliseconds, 8000);
    });

    test('jitter stays within ±20% and never exceeds maxDelay', () {
      final o = _options(
        enabled: true,
        initialDelayMs: 2000,
        multiplier: 2.0,
        maxDelayMs: 20000,
        jitter: true,
      );
      final rng = Random(42);
      var maxSeen = 0;
      var minSeen = 1 << 30;
      for (var i = 0; i < 40; i++) {
        final ms = backoffDelay(2, o, random: rng).inMilliseconds;
        expect(ms, inInclusiveRange(6400, 9600));
        maxSeen = max(maxSeen, ms);
        minSeen = min(minSeen, ms);
      }
      expect(maxSeen, isNot(equals(minSeen)));
    });

    test('huge multiplier clamps instead of producing NaN', () {
      final o = _options(
        enabled: true,
        initialDelayMs: 1000,
        multiplier: 1e308,
        maxDelayMs: 10000,
        jitter: false,
      );
      expect(backoffDelay(5, o).inMilliseconds, 10000);
    });
  });
}
