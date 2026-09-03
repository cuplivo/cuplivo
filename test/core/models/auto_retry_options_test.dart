import 'dart:convert';

import 'package:Cuplivo/core/models/auto_retry_options.dart';
import 'package:flutter_test/flutter_test.dart';

AutoRetryOptions _options({
  bool enabled = true,
  int maxRetries = 3,
  int initialDelayMs = 1000,
  double multiplier = 2.0,
  int maxDelayMs = 30000,
  bool jitter = true,
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
  group('defaults', () {
    const defaults = AutoRetryOptions.defaults();
    test('off by default with upstream-compatible values', () {
      expect(defaults.enabled, false);
      expect(defaults.maxRetries, 3);
      expect(defaults.initialDelayMs, 1000);
      expect(defaults.multiplier, 2.0);
      expect(defaults.maxDelayMs, 30000);
      expect(defaults.jitter, true);
      expect(defaults.retryOnNetworkError, true);
      expect(defaults.retryStatusCodes, {
        408,
        425,
        429,
        500,
        502,
        503,
        504,
        529,
      });
      expect(defaults.retryKeywords, contains('访问量过大'));
      expect(defaults.stopKeywords, contains('余额'));
    });
  });

  group('json round trip', () {
    test('toJson/fromJson preserves all fields', () {
      final original = AutoRetryOptions(
        enabled: true,
        maxRetries: 5,
        initialDelayMs: 250,
        multiplier: 1.5,
        maxDelayMs: 10000,
        jitter: false,
        retryOnNetworkError: false,
        retryStatusCodes: {429, 503},
        retryKeywords: ['rate limit'],
        stopKeywords: ['balance'],
      );
      final decoded = AutoRetryOptions.fromJson(
        jsonDecode(jsonEncode(original.toJson())) as Map<String, dynamic>,
      );
      expect(decoded.enabled, original.enabled);
      expect(decoded.maxRetries, original.maxRetries);
      expect(decoded.initialDelayMs, original.initialDelayMs);
      expect(decoded.multiplier, original.multiplier);
      expect(decoded.maxDelayMs, original.maxDelayMs);
      expect(decoded.jitter, original.jitter);
      expect(decoded.retryOnNetworkError, original.retryOnNetworkError);
      expect(decoded.retryStatusCodes, original.retryStatusCodes);
      expect(decoded.retryKeywords, original.retryKeywords);
      expect(decoded.stopKeywords, original.stopKeywords);
    });

    test('missing fields fall back to defaults', () {
      final decoded = AutoRetryOptions.fromJson(const <String, dynamic>{});
      expect(decoded.enabled, false);
      expect(decoded.maxRetries, 3);
      expect(decoded.initialDelayMs, 1000);
      expect(decoded.multiplier, 2.0);
      expect(decoded.maxDelayMs, 30000);
      expect(decoded.jitter, true);
      expect(decoded.retryOnNetworkError, true);
      expect(
        decoded.retryStatusCodes,
        AutoRetryOptions.defaultRetryStatusCodes,
      );
      expect(decoded.retryKeywords, AutoRetryOptions.defaultRetryKeywords);
      expect(decoded.stopKeywords, AutoRetryOptions.defaultStopKeywords);
    });

    test('present-but-empty lists stay empty', () {
      final decoded = AutoRetryOptions.fromJson(const <String, dynamic>{
        'retryStatusCodes': <dynamic>[],
        'retryKeywords': <String>[],
        'stopKeywords': <String>[],
      });
      expect(decoded.retryStatusCodes, isEmpty);
      expect(decoded.retryKeywords, isEmpty);
      expect(decoded.stopKeywords, isEmpty);
    });

    test('garbage-typed json values fall back to defaults', () {
      final decoded = AutoRetryOptions.fromJson(const <String, dynamic>{
        'enabled': 'yes',
        'maxRetries': 'not-a-number',
        'multiplier': 'abc',
      });
      expect(decoded.enabled, false);
      expect(decoded.maxRetries, 3);
      expect(decoded.multiplier, 2.0);
    });
  });

  group('clamping', () {
    test('maxRetries clamps to 0..10', () {
      expect(_options(maxRetries: -1).maxRetries, 0);
      expect(_options(maxRetries: 100).maxRetries, 10);
      expect(_options(maxRetries: 5).maxRetries, 5);
    });

    test('negative delays clamp to 0', () {
      expect(AutoRetryOptions.clampDelayMs(-5), 0);
      expect(AutoRetryOptions.clampDelayMs(0), 0);
      expect(AutoRetryOptions.clampDelayMs(100), 100);
    });

    test(
      'multiplier clamps: <=0/non-finite -> default, huge -> maxMultiplier',
      () {
        expect(AutoRetryOptions.clampMultiplier(0), 2.0);
        expect(AutoRetryOptions.clampMultiplier(-1), 2.0);
        expect(AutoRetryOptions.clampMultiplier(double.nan), 2.0);
        // Non-finite (infinity) falls back to the default, not maxMultiplier.
        expect(AutoRetryOptions.clampMultiplier(double.infinity), 2.0);
        expect(
          AutoRetryOptions.clampMultiplier(1e308),
          AutoRetryOptions.maxMultiplier,
        );
        expect(AutoRetryOptions.clampMultiplier(1.5), 1.5);
      },
    );
  });
}
