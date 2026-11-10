import 'package:Cuplivo/core/providers/sync_provider.dart';
import 'package:Cuplivo/core/services/sync/sync_engine.dart';
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

  group('what counts as an arrival', () {
    SyncSessionReport report({
      int conversationsReceived = 0,
      int messagesUpserted = 0,
      int messagesDeleted = 0,
      int conversationsDeletedLocally = 0,
      int entityRows = 0,
      int preferenceRows = 0,
      int entityRowsReceived = 0,
      int preferenceRowsReceived = 0,
      int blobsMoved = 0,
      int skillsUpdated = 0,
    }) => SyncSessionReport(
      success: true,
      summary: 'test',
      conversationsReceived: conversationsReceived,
      messagesUpserted: messagesUpserted,
      messagesDeleted: messagesDeleted,
      conversationsDeletedLocally: conversationsDeletedLocally,
      entityRows: entityRows,
      preferenceRows: preferenceRows,
      entityRowsReceived: entityRowsReceived,
      preferenceRowsReceived: preferenceRowsReceived,
      blobsMoved: blobsMoved,
      skillsUpdated: skillsUpdated,
    );

    test('nothing moved is not an arrival', () {
      expect(syncBroughtDataHere(report()), isFalse);
    });

    test('business rows that only went out are not an arrival', () {
      // The aggregates count both directions, which is what the card's "moved"
      // chip wants; a session that only pushed them changed nothing here.
      expect(
        syncBroughtDataHere(report(entityRows: 2, preferenceRows: 3)),
        isFalse,
      );
    });

    test('business rows that came in are an arrival', () {
      expect(syncBroughtDataHere(report(entityRowsReceived: 1)), isTrue);
      expect(syncBroughtDataHere(report(preferenceRowsReceived: 1)), isTrue);
    });

    test('every received side counts on its own', () {
      expect(syncBroughtDataHere(report(conversationsReceived: 1)), isTrue);
      expect(syncBroughtDataHere(report(messagesUpserted: 1)), isTrue);
      expect(syncBroughtDataHere(report(messagesDeleted: 1)), isTrue);
      expect(
        syncBroughtDataHere(report(conversationsDeletedLocally: 1)),
        isTrue,
      );
      expect(syncBroughtDataHere(report(blobsMoved: 1)), isTrue);
      expect(syncBroughtDataHere(report(skillsUpdated: 1)), isTrue);
    });
  });
}
