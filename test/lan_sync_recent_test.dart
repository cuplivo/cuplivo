import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:Cuplivo/core/services/sync/lan_sync_recent.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  group('mergeRecentEndpoints', () {
    test('inserts the newest endpoint at the front', () {
      final merged = mergeRecentEndpoints(
        const [(host: '192.168.1.5', port: 9527)],
        (host: '10.0.0.3', port: 9000),
      );
      expect(merged, [
        (host: '10.0.0.3', port: 9000),
        (host: '192.168.1.5', port: 9527),
      ]);
    });

    test('moves a duplicate to the front without growing the list', () {
      final merged = mergeRecentEndpoints(
        const [
          (host: 'a', port: 1),
          (host: 'b', port: 2),
          (host: 'c', port: 3),
        ],
        (host: 'b', port: 2),
      );
      expect(merged, [
        (host: 'b', port: 2),
        (host: 'a', port: 1),
        (host: 'c', port: 3),
      ]);
    });

    test('caps at maxEntries, dropping the oldest', () {
      var current = <LanSyncEndpoint>[];
      for (var i = 0; i < LanSyncRecentEndpoints.maxEntries + 2; i++) {
        current = mergeRecentEndpoints(current, (host: 'h$i', port: i));
      }
      expect(current.length, LanSyncRecentEndpoints.maxEntries);
      expect(current.first, (host: 'h6', port: 6));
      expect(current.last, (host: 'h2', port: 2));
    });
  });

  group('LanSyncRecentEndpoints storage', () {
    test('record then load round-trips newest first', () async {
      await LanSyncRecentEndpoints.record(host: '192.168.1.5', port: 9527);
      await LanSyncRecentEndpoints.record(host: '10.0.0.3', port: 9000);

      final loaded = await LanSyncRecentEndpoints.load();
      expect(loaded, [
        (host: '10.0.0.3', port: 9000),
        (host: '192.168.1.5', port: 9527),
      ]);
    });

    test('record reuses the passed-in current list and dedupes', () async {
      final first = await LanSyncRecentEndpoints.record(
        host: '192.168.1.5',
        port: 9527,
      );
      final second = await LanSyncRecentEndpoints.record(
        host: '192.168.1.5',
        port: 9527,
        current: first,
      );
      expect(second, [(host: '192.168.1.5', port: 9527)]);
      expect(await LanSyncRecentEndpoints.load(), second);
    });

    test('load skips malformed entries', () async {
      SharedPreferences.setMockInitialValues({
        LanSyncRecentEndpoints.storageKey: [
          'not-json',
          '{"h":"192.168.1.5","p":9527}',
          '{"h":"","p":1}',
          '{"h":"10.0.0.3","p":"9000"}',
        ],
      });

      final loaded = await LanSyncRecentEndpoints.load();
      expect(loaded, [(host: '192.168.1.5', port: 9527)]);
    });
  });
}
