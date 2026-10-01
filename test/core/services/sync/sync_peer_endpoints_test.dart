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

    test('manual repair replaces the whole set', () {
      final peer = record();
      peer.noteEndpointSuccess('10.0.0.3', 9527);
      peer.rememberEndpointCandidates([('192.168.1.7', 9527)]);
      peer.replaceEndpoints('172.20.10.1', 9527);
      expect(peer.endpoints.length, 1);
      expect(peer.primaryEndpoint?.label, '172.20.10.1:9527');
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
