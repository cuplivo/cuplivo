import 'package:flutter_test/flutter_test.dart';

import 'package:Cuplivo/features/harness/controllers/dsh_chat_session.dart';
import 'package:Cuplivo/features/harness/services/dsh_context_usage.dart';
import 'package:Cuplivo/features/home/services/context_usage_service.dart';

void main() {
  group('dshContextUsageSnapshot', () {
    test('a missing projection hides the ring', () {
      final snapshot = dshContextUsageSnapshot(
        pressure: null,
        remoteId: 'r1',
        sessionId: 's1',
      );
      expect(snapshot, isNull);
    });

    test('a projection without a window hides the ring', () {
      final snapshot = dshContextUsageSnapshot(
        pressure: const DshContextPressure(pressureTokens: 100),
        remoteId: 'r1',
        sessionId: 's1',
      );
      expect(snapshot, isNull);
    });

    test('maps the Host pressure to a two-segment exact snapshot', () {
      final computedAt = DateTime.utc(2026, 11, 20);
      final snapshot = dshContextUsageSnapshot(
        pressure: const DshContextPressure(
          pressureTokens: 8930,
          projectedTokens: 10000,
          contextWindow: 1048576,
        ),
        remoteId: 'r1',
        sessionId: 's1',
        providerKey: 'deepseek',
        modelId: 'deepseek-flash',
        computedAt: computedAt,
      );

      expect(snapshot, isNotNull);
      final usage = snapshot!;
      expect(usage.state, ContextUsageState.exact);
      expect(usage.usedTokens, 10000);
      expect(usage.contextWindow, 1048576);
      expect(usage.ratio, closeTo(10000 / 1048576, 1e-9));
      expect(usage.conversationId, 'dsh:r1:s1');
      expect(usage.providerKey, 'deepseek');
      expect(usage.modelId, 'deepseek-flash');
      expect(usage.computedAt, computedAt);
      // The Host exposes one pressure number; no bucket may be invented.
      expect(usage.buckets.total, 0);
      expect(usage.hasUnknownNativeTokens, isFalse);
    });

    test('falls back to the current transcript when no projection exists', () {
      final snapshot = dshContextUsageSnapshot(
        pressure: const DshContextPressure(
          pressureTokens: 4200,
          contextWindow: 100000,
        ),
        remoteId: 'r1',
        sessionId: 's1',
      );
      expect(snapshot?.usedTokens, 4200);
    });

    test('a negative pressure clamps to zero', () {
      final snapshot = dshContextUsageSnapshot(
        pressure: const DshContextPressure(
          pressureTokens: -5,
          contextWindow: 1000,
        ),
        remoteId: 'r1',
        sessionId: 's1',
      );
      expect(snapshot?.usedTokens, 0);
    });
  });
}
