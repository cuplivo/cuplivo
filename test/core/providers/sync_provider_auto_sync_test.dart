import 'package:Cuplivo/core/providers/sync_provider.dart';
import 'package:flutter_test/flutter_test.dart';

/// The automatic-round cadence, in isolation: the foreground trigger itself
/// needs two live engines (see the integration suite), but *when* a round is
/// allowed is a pure decision and is tested as one.
void main() {
  final t0 = DateTime(2026, 9, 1, 12);

  test('the first round always runs', () {
    expect(shouldAutoSyncNow(t0, null), isTrue);
  });

  test('a round inside the interval is skipped', () {
    expect(shouldAutoSyncNow(t0.add(const Duration(seconds: 1)), t0), isFalse);
    expect(
      shouldAutoSyncNow(
        t0.add(autoSyncInterval - const Duration(seconds: 1)),
        t0,
      ),
      isFalse,
    );
  });

  test('the interval boundary and beyond run again', () {
    expect(shouldAutoSyncNow(t0.add(autoSyncInterval), t0), isTrue);
    expect(shouldAutoSyncNow(t0.add(autoSyncInterval * 3), t0), isTrue);
  });

  test('the interval is a minute, matching the documented cadence', () {
    expect(autoSyncInterval, const Duration(seconds: 60));
  });
}
