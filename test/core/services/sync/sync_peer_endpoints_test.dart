import 'package:Cuplivo/core/services/sync/sync_limits.dart';
import 'package:Cuplivo/core/services/sync/sync_store.dart';
import 'package:flutter_test/flutter_test.dart';

/// The peer record's endpoint set: how it orders, how it stays bounded, and the
/// read-time upgrade of a record 4.0.0 wrote with a single `lastHost`/`lastPort`
/// pair (those files are on real devices, so the upgrade is what keeps a paired
/// phone syncing across the app update instead of forcing a re-scan).
void main() {
  SyncPeerRecord record() => SyncPeerRecord(
    deviceId: 'd' * 64,
    certPem: 'pem',
    secret: 'secret',
    name: 'peer',
    platform: 'android',
  );

  group('SyncPeerRecord endpoints', () {
    test('promotes the endpoint a session succeeded over', () {
      final peer = record();
      peer.rememberEndpointCandidates([
        ('10.0.0.3', 9527),
        ('192.168.1.7', 9527),
      ]);
      expect(peer.primaryEndpoint?.host, '10.0.0.3');

      peer.noteEndpointSuccess('192.168.1.7', 9527);
      expect(peer.primaryEndpoint?.host, '192.168.1.7');
      expect(
        peer.endpoints.length,
        2,
        reason: 'the candidate that lost is kept as a hint',
      );
      expect(peer.endpoints.first.lastSuccessAt, isNotNull);
    });

    test('does not add the same address twice', () {
      final peer = record();
      peer.noteEndpointSuccess('192.168.1.7', 9527);
      peer.rememberEndpointCandidates([('192.168.1.7', 9527)]);
      expect(peer.endpoints.length, 1);
    });

    test('caps the remembered set', () {
      final peer = record();
      for (var i = 0; i < kMaxPeerEndpoints + 3; i++) {
        peer.noteEndpointSuccess('10.0.0.$i', 9527);
      }
      expect(peer.endpoints.length, kMaxPeerEndpoints);
      expect(peer.primaryEndpoint?.host, '10.0.0.${kMaxPeerEndpoints + 2}');
    });

    test('manual repair moves one address and leaves the rest alone', () {
      final peer = record();
      peer.noteEndpointSuccess('10.0.0.3', 9527);
      peer.rememberEndpointCandidates([('192.168.1.7', 9527)]);

      expect(
        peer.editEndpoint('10.0.0.3', 9527, '172.20.10.1', 0),
        isFalse,
        reason: 'the edit path refuses the port the add path refuses',
      );
      expect(peer.editEndpoint('10.0.0.3', 9527, '172.20.10.1', -5), isFalse);
      expect(peer.primaryEndpoint?.host, '10.0.0.3');

      expect(peer.editEndpoint('10.0.0.3', 9527, '172.20.10.1', 9527), isTrue);

      // The other network is not collateral damage: it is the memory of where
      // this pair has already met, and a repair of one address says nothing
      // about it.
      expect(peer.endpoints.map((e) => e.label).toList(), [
        '172.20.10.1:9527',
        '192.168.1.7:9527',
      ]);
      expect(
        peer.endpoints.first.successCount,
        1,
        reason:
            'the tile kept its history — it is the same (device, network) '
            'pair at a new address',
      );
      expect(peer.endpointFor('10.0.0.3', 9527), isNull);
    });

    test('an edit onto a remembered address leaves one tile for it', () {
      final peer = record();
      peer.rememberEndpointCandidates([
        ('10.0.0.3', 9527),
        ('192.168.1.7', 9527),
      ]);
      peer.noteEndpointSuccess('10.0.0.3', 9527);

      expect(peer.editEndpoint('10.0.0.3', 9527, '192.168.1.7', 9527), isTrue);

      expect(peer.endpoints, hasLength(1));
      expect(peer.primaryEndpoint?.label, '192.168.1.7:9527');
      expect(
        peer.endpoints.single.successCount,
        1,
        reason: 'the tile the user edited is the one that survives',
      );
    });

    test('a typed address joins the end of the set, and never twice', () {
      final peer = record();
      peer.noteEndpointSuccess('192.168.1.7', 9527);

      expect(peer.addEndpoint('10.0.0.3', 9527), SyncEndpointAdd.added);
      expect(peer.endpoints.map((e) => e.host).toList(), [
        '192.168.1.7',
        '10.0.0.3',
      ], reason: 'a typed address has proved nothing, so it dials last');
      expect(peer.endpoints.last.addedAt, isNotNull);

      // Three ways to add nothing, and the caller can tell them apart: this is
      // the difference between "already remembered", "that is not an address"
      // and "the set is full" — a bool made all three read as failure and made
      // the third one report success.
      expect(peer.addEndpoint('10.0.0.3', 9527), SyncEndpointAdd.duplicate);
      expect(peer.addEndpoint('  ', 9527), SyncEndpointAdd.invalid);
      expect(peer.addEndpoint('10.0.0.9', 0), SyncEndpointAdd.invalid);
      expect(
        peer.addEndpoint('10.0.0.9', -1),
        SyncEndpointAdd.invalid,
        reason: 'a negative port is not a port either',
      );
      expect(peer.endpoints, hasLength(2));
    });

    test(
      'a full set refuses a new address instead of evicting a known one',
      () {
        final peer = record();
        for (var i = 0; i < kMaxPeerEndpoints; i++) {
          peer.noteEndpointSuccess('10.0.0.$i', 9527);
        }
        expect(peer.endpoints, hasLength(kMaxPeerEndpoints));

        expect(
          peer.addEndpoint('192.168.1.7', 9527),
          SyncEndpointAdd.full,
          reason: 'the cap is a refusal the caller can see, not a silent trim',
        );
        expect(peer.endpoints, hasLength(kMaxPeerEndpoints));
        expect(
          peer.endpointFor('192.168.1.7', 9527),
          isNull,
          reason: 'a typed address never displaces one a session ran over',
        );
        expect(
          peer.endpointFor('10.0.0.0', 9527),
          isNotNull,
          reason: 'and nothing at the tail was dropped to make room',
        );
      },
    );

    test('pairing reports the candidates the cap could not take', () {
      final peer = record();
      for (var i = 0; i < kMaxPeerEndpoints; i++) {
        peer.noteEndpointSuccess('10.0.0.$i', 9527);
      }
      final dropped = peer.rememberEndpointCandidates([
        ('192.168.1.7', 9527),
        ('192.168.1.8', 9527),
      ]);
      expect(dropped, [('192.168.1.7', 9527), ('192.168.1.8', 9527)]);
      expect(peer.endpoints, hasLength(kMaxPeerEndpoints));
    });

    test('naming one address leaves the others unnamed', () {
      final peer = record();
      peer.rememberEndpointCandidates([
        ('10.0.0.3', 9527),
        ('192.168.1.7', 9527),
      ]);

      expect(peer.renameEndpoint('10.0.0.3', 9527, '  家中网络  '), isTrue);
      expect(peer.endpoints.first.customName, '家中网络');
      expect(peer.endpoints.first.displayName, '家中网络');
      expect(peer.endpoints.last.displayName, '192.168.1.7');

      // A blank answer puts the address back on the tile rather than showing an
      // empty name.
      peer.renameEndpoint('10.0.0.3', 9527, '  ');
      expect(peer.endpoints.first.customName, isNull);
      expect(peer.endpoints.first.displayName, '10.0.0.3');

      expect(peer.renameEndpoint('1.2.3.4', 1, 'x'), isFalse);
    });

    test('an endpoint name and its counters round-trip', () {
      final peer = record();
      peer.addEndpoint('10.0.0.3', 9527);
      peer.renameEndpoint('10.0.0.3', 9527, '公司网络');
      peer.endpoints.single
        ..recordSession()
        ..recordProbe(
          answered: true,
          latency: const Duration(milliseconds: 12),
        );

      final restored = SyncPeerRecord.fromJson(peer.toJson());
      expect(restored.endpoints.single.customName, '公司网络');
      expect(restored.endpoints.single.displayName, '公司网络');
      expect(restored.endpoints.single.successCount, 1);
      expect(restored.endpoints.single.lastLatencyMs, 12);
    });

    test('a blank stored name reads as no name', () {
      final restored = SyncPeerRecord.fromJson({
        'deviceId': 'd' * 64,
        'certPem': 'pem',
        'secret': 'secret',
        'name': 'peer',
        'endpoints': [
          {'host': '10.0.0.3', 'port': 9527, 'customName': '   '},
        ],
      });
      expect(restored.endpoints.single.customName, isNull);
      expect(restored.endpoints.single.displayName, '10.0.0.3');
    });

    test('a re-pair keeps the networks it left behind the fresh ones', () {
      // A record that last synced on the office network.
      final previous = record();
      previous.noteEndpointSuccess('10.0.0.3', 9527);
      previous.rememberEndpointCandidates([('10.0.0.9', 9527)]);

      // The pair moves home: the pairing proves the new address, the QR
      // advertises the peer's current candidates, and the old network is
      // carried over behind them instead of being forgotten.
      final peer = record();
      peer.noteEndpointSuccess('192.168.1.7', 9527);
      peer.rememberEndpointCandidates([('192.168.1.9', 9527)]);
      peer.rememberEndpointHistory(previous.endpoints);

      expect(peer.endpoints.map((e) => e.host).toList(), [
        '192.168.1.7',
        '192.168.1.9',
        '10.0.0.3',
        '10.0.0.9',
      ]);
      expect(
        peer.endpoints.last.lastSuccessAt,
        isNull,
        reason: 'a carried hint is not re-stamped as a success',
      );
      expect(
        peer.endpoints[2].lastSuccessAt,
        isNotNull,
        reason: 'the office address keeps the stamp it earned there',
      );
    });

    test('carrying history neither duplicates nor outgrows the set', () {
      final previous = record();
      previous.noteEndpointSuccess('10.0.0.3', 9527);
      for (var i = 0; i < kMaxPeerEndpoints + 2; i++) {
        previous.rememberEndpointCandidates([('10.0.1.$i', 9527)]);
      }

      final peer = record();
      // The address the pairing proved is also in the old set: it must not be
      // remembered twice.
      peer.noteEndpointSuccess('10.0.0.3', 9527);
      peer.rememberEndpointHistory(previous.endpoints);

      expect(
        peer.endpoints.where((e) => e.host == '10.0.0.3').length,
        1,
        reason: 'the proven address is not duplicated by its own history',
      );
      expect(peer.endpoints.length, kMaxPeerEndpoints);
      expect(
        peer.primaryEndpoint?.host,
        '10.0.0.3',
        reason: 'carried history never displaces the address that answered',
      );
    });

    test('a re-pair keeps the name and history of the address it proves', () {
      // The tile the user named at home, with the sessions and the measurement
      // that belong to that (device, network) pair.
      final previous = record();
      previous.noteEndpointSuccess('192.168.1.7', 9527);
      final oldTile = previous.endpoints.single
        ..customName = '家中网络'
        ..successCount = 41
        ..addedAt = DateTime(2025, 6, 1)
        ..recordProbe(
          answered: true,
          latency: const Duration(milliseconds: 12),
          at: DateTime(2026, 1, 1),
        );

      // Re-pairing on that same network proves the address the old tile holds:
      // the fresh copy is created first, the history merge arrives second, and
      // the merge must not discard the tile it collides with.
      final peer = record();
      peer.noteEndpointSuccess('192.168.1.7', 9527);
      peer.rememberEndpointHistory(previous.endpoints);

      expect(peer.endpoints, hasLength(1), reason: 'one address is one tile');
      final tile = peer.endpoints.single;
      expect(tile.displayName, '家中网络', reason: 'the name outlives a re-pair');
      expect(
        tile.successCount,
        42,
        reason: 'the pairing session counts on top of the history it found',
      );
      expect(tile.lastLatencyMs, 12, reason: 'the measurement is still true');
      expect(
        tile.addedAt,
        oldTile.addedAt,
        reason: 'a tile is not "first learned" when it is re-paired',
      );
    });

    test('a re-pair keeps the history of every address it advertises', () {
      // The office address that carried sessions, and the home address known
      // only as a candidate the old pairing advertised.
      final previous = record();
      previous.noteEndpointSuccess('10.0.0.3', 9527);
      previous.rememberEndpointCandidates([('192.168.1.9', 9527)]);
      previous.endpoints[1]
        ..customName = '家中网络'
        ..successCount = 7
        ..recordProbe(
          answered: true,
          latency: const Duration(milliseconds: 9),
          at: DateTime(2026, 2, 1),
        );

      // The new pairing proves the home address and advertises both networks.
      final peer = record();
      peer.noteEndpointSuccess('192.168.1.7', 9527);
      peer.rememberEndpointCandidates([
        ('10.0.0.3', 9527),
        ('192.168.1.9', 9527),
      ]);
      peer.rememberEndpointHistory(previous.endpoints);

      expect(peer.endpoints.map((e) => e.host).toList(), [
        '192.168.1.7',
        '10.0.0.3',
        '192.168.1.9',
      ]);
      final office = peer.endpointFor('10.0.0.3', 9527)!;
      expect(
        office.successCount,
        1,
        reason: 'an advertised address that already carried a session keeps it',
      );
      expect(office.lastSuccessAt, isNotNull);
      final home = peer.endpointFor('192.168.1.9', 9527)!;
      expect(home.displayName, '家中网络');
      expect(home.successCount, 7);
      expect(home.lastLatencyMs, 9);
    });

    test('round-trips through JSON', () {
      final peer = record();
      peer.noteEndpointSuccess('192.168.1.7', 9527);
      peer.rememberEndpointCandidates([('10.0.0.3', 9527)]);

      final restored = SyncPeerRecord.fromJson(peer.toJson());
      expect(
        restored.endpoints.map((endpoint) => endpoint.label).toList(),
        peer.endpoints.map((endpoint) => endpoint.label).toList(),
      );
      expect(restored.endpoints.first.lastSuccessAt, isNotNull);
      expect(restored.endpoints.last.lastSuccessAt, isNull);
      expect(restored.toJson().containsKey('lastHost'), isFalse);
    });

    test('upgrades the single endpoint 4.0.0 stored', () {
      final restored = SyncPeerRecord.fromJson({
        'deviceId': 'd' * 64,
        'certPem': 'pem',
        'secret': 'secret',
        'name': 'peer',
        'platform': 'android',
        'lastHost': '192.168.1.7',
        'lastPort': 9527,
        'lastSyncedAtMs': 1735689600000,
      });

      expect(restored.endpoints.length, 1);
      expect(restored.primaryEndpoint?.host, '192.168.1.7');
      expect(restored.primaryEndpoint?.port, 9527);
      expect(
        restored.primaryEndpoint?.lastSuccessAt,
        DateTime.fromMillisecondsSinceEpoch(1735689600000),
        reason: 'the last sync seeds the ordering clock',
      );
    });

    test('an address without a port reads as no endpoint at all', () {
      // 4.0 could persist this shape (a pairing where the initiator advertised
      // no listener port), and it was not dialable then either.
      final restored = SyncPeerRecord.fromJson({
        'deviceId': 'd' * 64,
        'certPem': 'pem',
        'secret': 'secret',
        'lastHost': '192.168.1.7',
      });
      expect(restored.endpoints, isEmpty);
      expect(restored.primaryEndpoint, isNull);
    });

    test('the set wins over legacy fields in the same file', () {
      final restored = SyncPeerRecord.fromJson({
        'deviceId': 'd' * 64,
        'certPem': 'pem',
        'secret': 'secret',
        'endpoints': [
          {'host': '10.0.0.3', 'port': 9527},
        ],
        'lastHost': '192.168.1.7',
        'lastPort': 1,
      });
      expect(restored.endpoints.length, 1);
      expect(restored.primaryEndpoint?.host, '10.0.0.3');
    });
  });

  group('SyncPeerRecord naming', () {
    test('a manual rename round-trips and wins over the reported name', () {
      final peer = record();
      peer.customName = 'Studio';
      expect(peer.displayName, 'Studio');

      final restored = SyncPeerRecord.fromJson(peer.toJson());
      expect(restored.displayName, 'Studio');
      expect(
        restored.name,
        'peer',
        reason: 'the reported name is still tracked beside the override',
      );
    });

    test('a record with no override reads as the reported name', () {
      final restored = SyncPeerRecord.fromJson({
        'deviceId': 'd' * 64,
        'certPem': 'pem',
        'secret': 'secret',
        'name': 'peer',
      });
      expect(restored.customName, isNull);
      expect(restored.displayName, 'peer');
    });

    test('a blank override is no override', () {
      // An empty rename dialog must not blank a card.
      final restored = SyncPeerRecord.fromJson({
        'deviceId': 'd' * 64,
        'certPem': 'pem',
        'secret': 'secret',
        'name': 'peer',
        'customName': '   ',
      });
      expect(restored.customName, isNull);
      expect(restored.displayName, 'peer');
    });

    test('an override is not written when there is none', () {
      expect(record().toJson().containsKey('customName'), isFalse);
    });
  });
}
