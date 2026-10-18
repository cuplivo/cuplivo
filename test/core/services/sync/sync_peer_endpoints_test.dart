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

      expect(peer.addEndpoint('10.0.0.3', 9527), isTrue);
      expect(peer.endpoints.map((e) => e.host).toList(), [
        '192.168.1.7',
        '10.0.0.3',
      ], reason: 'a typed address has proved nothing, so it dials last');
      expect(peer.endpoints.last.addedAt, isNotNull);

      expect(peer.addEndpoint('10.0.0.3', 9527), isFalse);
      expect(peer.addEndpoint('  ', 9527), isFalse);
      expect(peer.addEndpoint('10.0.0.9', 0), isFalse);
      expect(peer.endpoints, hasLength(2));
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
