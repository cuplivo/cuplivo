import 'package:flutter_test/flutter_test.dart';

import 'package:Cuplivo/core/models/token_usage.dart';

void main() {
  group('merge', () {
    test(
      'merge preserves explicit total when split token fields are missing',
      () {
        final merged = const TokenUsage().merge(
          const TokenUsage(totalTokens: 895),
        );

        expect(merged.promptTokens, 0);
        expect(merged.completionTokens, 0);
        expect(merged.cachedTokens, 0);
        expect(merged.totalTokens, 895);
      },
    );

    test('merge takes per-field max (within-stream cumulative snapshots)', () {
      final a = const TokenUsage(
        promptTokens: 100,
        completionTokens: 10,
        cachedTokens: 5,
        totalTokens: 110,
      );
      final b = const TokenUsage(
        promptTokens: 100,
        completionTokens: 40,
        cachedTokens: 5,
        totalTokens: 140,
      );

      final merged = a.merge(b);

      expect(merged.promptTokens, 100);
      expect(merged.completionTokens, 40);
      expect(merged.cachedTokens, 5);
      expect(merged.totalTokens, 140);
    });

    test('merge keeps existing value when other field is zero', () {
      final a = const TokenUsage(
        promptTokens: 100,
        completionTokens: 40,
        cachedTokens: 5,
        totalTokens: 140,
      );
      final b = const TokenUsage(
        promptTokens: 0,
        completionTokens: 0,
        cachedTokens: 0,
        totalTokens: 0,
      );

      final merged = a.merge(b);

      expect(merged.promptTokens, 100);
      expect(merged.completionTokens, 40);
      expect(merged.cachedTokens, 5);
      expect(merged.totalTokens, 140);
    });
  });

  group('sum', () {
    test('sums element-wise across independent request rounds', () {
      final round1 = const TokenUsage(
        promptTokens: 1000,
        completionTokens: 20,
        cachedTokens: 300,
        totalTokens: 1020,
      );
      final round2 = const TokenUsage(
        promptTokens: 1200,
        completionTokens: 500,
        cachedTokens: 400,
        totalTokens: 1700,
      );

      final total = round1.sum(round2);

      expect(total.promptTokens, 2200);
      expect(total.completionTokens, 520);
      expect(total.cachedTokens, 700);
      // totalTokens is derived from the summed split fields, not the sum of
      // the providers' explicit totals.
      expect(total.totalTokens, 2720);
    });

    test('sum with zero usage is identity', () {
      const round = TokenUsage(
        promptTokens: 50,
        completionTokens: 30,
        cachedTokens: 10,
        totalTokens: 80,
      );

      final total = const TokenUsage().sum(round);

      expect(total.promptTokens, 50);
      expect(total.completionTokens, 30);
      expect(total.cachedTokens, 10);
      expect(total.totalTokens, 80);
    });
  });

  group('accumulate', () {
    test('null accumulated starts from the first round', () {
      final result = TokenUsage.accumulate(
        null,
        const TokenUsage(promptTokens: 10, completionTokens: 2),
      );

      expect(result!.promptTokens, 10);
      expect(result.completionTokens, 2);
      expect(result.totalTokens, 12);
    });

    test('null round leaves the accumulator unchanged', () {
      const acc = TokenUsage(promptTokens: 10, completionTokens: 2);

      final result = TokenUsage.accumulate(acc, null);

      expect(result, same(acc));
    });

    test('accumulates multiple rounds in order', () {
      var acc = TokenUsage.accumulate(
        null,
        const TokenUsage(promptTokens: 10, completionTokens: 2),
      );
      acc = TokenUsage.accumulate(
        acc,
        const TokenUsage(promptTokens: 15, completionTokens: 8),
      );

      expect(acc!.promptTokens, 25);
      expect(acc.completionTokens, 10);
      expect(acc.totalTokens, 35);
    });
  });

  group('fromGeminiUsageMetadata', () {
    test('null input returns zero TokenUsage', () {
      final result = TokenUsage.fromGeminiUsageMetadata(null);

      expect(result.promptTokens, 0);
      expect(result.completionTokens, 0);
      expect(result.cachedTokens, 0);
      expect(result.totalTokens, 0);
    });

    test('empty map returns zero TokenUsage', () {
      final result = TokenUsage.fromGeminiUsageMetadata(<String, dynamic>{});

      expect(result.promptTokens, 0);
      expect(result.completionTokens, 0);
      expect(result.cachedTokens, 0);
      expect(result.totalTokens, 0);
    });

    test('all fields present with cachedContentTokenCount > 0', () {
      final result = TokenUsage.fromGeminiUsageMetadata({
        'promptTokenCount': 100,
        'candidatesTokenCount': 50,
        'cachedContentTokenCount': 42,
        'totalTokenCount': 192,
      });

      expect(result.promptTokens, 100);
      expect(result.completionTokens, 50);
      expect(result.cachedTokens, 42);
      expect(result.totalTokens, 192);
    });

    test('cachedContentTokenCount is 0', () {
      final result = TokenUsage.fromGeminiUsageMetadata({
        'promptTokenCount': 100,
        'candidatesTokenCount': 50,
        'cachedContentTokenCount': 0,
        'totalTokenCount': 150,
      });

      expect(result.cachedTokens, 0);
    });

    test('cachedContentTokenCount is missing', () {
      final result = TokenUsage.fromGeminiUsageMetadata({
        'promptTokenCount': 100,
        'candidatesTokenCount': 50,
        'totalTokenCount': 150,
      });

      expect(result.cachedTokens, 0);
    });

    test('all fields are zero', () {
      final result = TokenUsage.fromGeminiUsageMetadata({
        'promptTokenCount': 0,
        'candidatesTokenCount': 0,
        'cachedContentTokenCount': 0,
        'totalTokenCount': 0,
      });

      expect(result.promptTokens, 0);
      expect(result.completionTokens, 0);
      expect(result.cachedTokens, 0);
      expect(result.totalTokens, 0);
    });
  });
}
