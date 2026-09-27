import 'package:flutter_test/flutter_test.dart';

import 'package:Cuplivo/core/services/sync/sync_merge.dart';
import 'package:Cuplivo/core/services/sync/sync_models.dart';

SyncManifestEntry _entry(int updatedAtUs, Map<String, int> rows) =>
    SyncManifestEntry(
      updatedAtUs: updatedAtUs,
      messageCount: rows.length,
      digest: computeConversationDigest(
        rows.entries.map((e) => (id: e.key, updatedAtUs: e.value)),
      ),
    );

SyncManifest _manifest(Map<String, SyncManifestEntry> conversations) =>
    SyncManifest(conversations);

SyncCheckpoint _checkpoint(Map<String, SyncManifestEntry> like) =>
    SyncCheckpoint({
      for (final entry in like.entries)
        entry.key: SyncCheckpointConversation(
          updatedAtUs: entry.value.updatedAtUs,
          digest: entry.value.digest,
          rows: const {},
        ),
    });

Map<String, dynamic> _msg(
  String id,
  int timestampUs, {
  int? updatedAtUs,
  int messageOrder = 0,
}) => {
  'id': id,
  'timestamp': timestampUs,
  'message_order': messageOrder,
  if (updatedAtUs != null) 'updated_at': updatedAtUs,
};

void main() {
  group('planSync', () {
    test('identical states need no transfer', () {
      final a = _manifest({
        'c1': _entry(10, {'m1': 5}),
      });
      final plan = planSync(
        mine: a,
        peers: a,
        checkpoint: _checkpoint(a.conversations),
      );
      expect(plan.single.action, SyncConvAction.none);
    });

    test('one-sided change routes to the sender', () {
      final base = {
        'c1': _entry(10, {'m1': 5}),
      };
      final changed = {
        'c1': _entry(20, {'m1': 5, 'm2': 6}),
      };
      final cp = _checkpoint(base);
      expect(
        planSync(
          mine: _manifest(changed),
          peers: _manifest(base),
          checkpoint: cp,
        ).single.action,
        SyncConvAction.iSend,
      );
      expect(
        planSync(
          mine: _manifest(base),
          peers: _manifest(changed),
          checkpoint: cp,
        ).single.action,
        SyncConvAction.peerSends,
      );
    });

    test('both changed since checkpoint makes both send', () {
      final base = {
        'c1': _entry(10, {'m1': 5}),
      };
      final cp = _checkpoint(base);
      final left = {
        'c1': _entry(20, {'m1': 5, 'm2': 6}),
      };
      final right = {
        'c1': _entry(30, {'m1': 5, 'm3': 7}),
      };
      final plan = planSync(
        mine: _manifest(left),
        peers: _manifest(right),
        checkpoint: cp,
      );
      expect(plan.single.action, SyncConvAction.bothSend);
    });

    test('first sync with no checkpoint sends the haves', () {
      final mine = _manifest({
        'c1': _entry(10, {'m1': 5}),
      });
      final empty = _manifest({});
      expect(
        planSync(
          mine: mine,
          peers: empty,
          checkpoint: SyncCheckpoint.empty,
        ).single.action,
        SyncConvAction.iSend,
      );
      expect(
        planSync(
          mine: empty,
          peers: mine,
          checkpoint: SyncCheckpoint.empty,
        ).single.action,
        SyncConvAction.peerSends,
      );
    });

    test('deletion propagates only to the unmodified side', () {
      final base = {
        'c1': _entry(10, {'m1': 5}),
      };
      final cp = _checkpoint(base);
      final modified = {
        'c1': _entry(20, {'m1': 5, 'm2': 6}),
      };
      // Deleted here, peer unmodified: peer must delete.
      expect(
        planSync(
          mine: _manifest({}),
          peers: _manifest(base),
          checkpoint: cp,
        ).single.action,
        SyncConvAction.peerDeletes,
      );
      // Deleted here, peer modified: peer keeps and sends (edit beats delete).
      expect(
        planSync(
          mine: _manifest({}),
          peers: _manifest(modified),
          checkpoint: cp,
        ).single.action,
        SyncConvAction.peerSends,
      );
    });

    test('deleted on both sides collapses to nothing', () {
      final cp = _checkpoint({
        'c1': _entry(10, {'m1': 5}),
      });
      expect(
        planSync(
          mine: _manifest({}),
          peers: _manifest({}),
          checkpoint: cp,
        ).single.action,
        SyncConvAction.bothDeleted,
      );
    });

    test('plan is symmetric under role swap', () {
      final base = {
        'c1': _entry(10, {'m1': 5}),
      };
      final cp = _checkpoint(base);
      final left = _manifest({
        'c1': _entry(20, {'m1': 5, 'm2': 6}),
        'gone-here': _entry(11, {'x': 1}),
      });
      final right = _manifest({
        'c1': _entry(25, {'m1': 5, 'm3': 7}),
        'new-there': _entry(30, {'y': 1}),
      });
      final mine = planSync(mine: left, peers: right, checkpoint: cp);
      final theirs = planSync(mine: right, peers: left, checkpoint: cp);
      final mineById = {
        for (final plan in mine) plan.conversationId: plan.action,
      };
      final theirsById = {
        for (final plan in theirs) plan.conversationId: plan.action,
      };
      SyncConvAction mirror(SyncConvAction action) => switch (action) {
        SyncConvAction.iSend => SyncConvAction.peerSends,
        SyncConvAction.peerSends => SyncConvAction.iSend,
        SyncConvAction.peerDeletes => SyncConvAction.iDelete,
        SyncConvAction.iDelete => SyncConvAction.peerDeletes,
        _ => action,
      };
      expect(mineById.keys.toSet(), equals(theirsById.keys.toSet()));
      for (final entry in mineById.entries) {
        expect(
          mirror(entry.value),
          theirsById[entry.key],
          reason: '${entry.key}: ${entry.value} must mirror',
        );
      }
    });
  });

  group('mergeConversationRow', () {
    test('newer updated_at wins on either side', () {
      final local = {'id': 'c1', 'updated_at': 10};
      final incoming = {'id': 'c1', 'updated_at': 20};
      expect(
        mergeConversationRow(
          local: local,
          incoming: incoming,
          myDeviceId: 'a',
          peerDeviceId: 'b',
        ).incomingWon,
        isTrue,
      );
      expect(
        mergeConversationRow(
          local: incoming,
          incoming: local,
          myDeviceId: 'a',
          peerDeviceId: 'b',
        ).incomingWon,
        isFalse,
      );
    });

    test('timestamp tie falls deterministically to the higher deviceId', () {
      final local = {'id': 'c1', 'updated_at': 10};
      final incoming = {'id': 'c1', 'updated_at': 10};
      expect(
        mergeConversationRow(
          local: local,
          incoming: incoming,
          myDeviceId: 'z-device',
          peerDeviceId: 'a-device',
        ).incomingWon,
        isFalse,
      );
      expect(
        mergeConversationRow(
          local: local,
          incoming: incoming,
          myDeviceId: 'a-device',
          peerDeviceId: 'z-device',
        ).incomingWon,
        isTrue,
      );
    });
  });

  group('mergeMessageRows', () {
    test('unknown rows insert, newer rows overwrite, older rows stay', () {
      final plan = mergeMessageRows(
        local: {
          'm1': _msg('m1', 5, updatedAtUs: 5),
          'm2': _msg('m2', 6, updatedAtUs: 50),
        },
        incoming: {
          'm1': _msg('m1', 5, updatedAtUs: 9),
          'm2': _msg('m2', 6, updatedAtUs: 40),
          'm3': _msg('m3', 7),
        },
        checkpointRows: const {},
        myDeviceId: 'a',
        peerDeviceId: 'b',
      );
      expect(
        plan.upserts.map((row) => row['id']),
        unorderedEquals(['m1', 'm3']),
      );
      expect(plan.deletes, isEmpty);
    });

    test('tie falls to the higher deviceId, identically on both peers', () {
      Map<String, Map<String, dynamic>> asMap(
        List<Map<String, dynamic>> rows,
      ) => {for (final row in rows) row['id'] as String: row};
      final tie = [_msg('m1', 5, updatedAtUs: 9)];
      // Peer 'z' wins over me 'a' …
      expect(
        mergeMessageRows(
          local: asMap(tie),
          incoming: asMap(tie),
          checkpointRows: const {},
          myDeviceId: 'a',
          peerDeviceId: 'z',
        ).upserts,
        isNotEmpty,
      );
      // …and 'z' also wins when it is the local side against peer 'a'.
      expect(
        mergeMessageRows(
          local: asMap(tie),
          incoming: asMap(tie),
          checkpointRows: const {},
          myDeviceId: 'z',
          peerDeviceId: 'a',
        ).upserts,
        isEmpty,
      );
    });

    test('peer deletion removes only untouched rows; edited rows survive', () {
      final plan = mergeMessageRows(
        local: {
          'kept-new': _msg('kept-new', 1),
          'edited': _msg('edited', 2, updatedAtUs: 99),
        },
        incoming: {},
        checkpointRows: const {'kept-new': 1, 'edited': 2},
        myDeviceId: 'a',
        peerDeviceId: 'b',
      );
      expect(plan.deletes, ['kept-new']);
      expect(plan.upserts, isEmpty);
    });

    test('rows created here since the last sync are never deleted', () {
      final plan = mergeMessageRows(
        local: {'fresh': _msg('fresh', 3)},
        incoming: {},
        checkpointRows: const {},
        myDeviceId: 'a',
        peerDeviceId: 'b',
      );
      expect(plan.deletes, isEmpty);
    });
  });

  group('rederiveMessageOrder', () {
    test('the carried slot leads; a tie falls to timestamp then id', () {
      final order = rederiveMessageOrder([
        _msg('b2', 20, messageOrder: 2),
        _msg('b1', 20, messageOrder: 1),
        _msg('a1', 10, messageOrder: 0),
        _msg('a2', 12, messageOrder: 1),
      ]);
      expect(order, {'a1': 0, 'a2': 1, 'b1': 2, 'b2': 3});
    });

    test('a deliberate anchor slot survives a later change', () {
      // m3 is a regeneration of m0 that the app moved back onto the slot its
      // deleted sibling held, so it belongs before m2 even though its own
      // timestamp is newer. Deriving from (timestamp, id) alone would move it
      // after m2 and lose the placement for good.
      final order = rederiveMessageOrder([
        _msg('m5', 500, messageOrder: 3),
        _msg('m3', 300, messageOrder: 1),
        _msg('m0', 100, messageOrder: 0),
        _msg('m2', 200, messageOrder: 2),
      ]);
      expect(order, {'m0': 0, 'm3': 1, 'm2': 2, 'm5': 3});
    });

    test('the assignment stays dense and unique', () {
      // Two rows claim one slot: the result is still 0..n-1 with no repeats.
      final order = rederiveMessageOrder([
        _msg('x', 10, messageOrder: 7),
        _msg('y', 20, messageOrder: 7),
        _msg('z', 30, messageOrder: 9),
      ]);
      expect(order.values.toSet(), {0, 1, 2});
      expect(order['x'], 0);
      expect(order['y'], 1);
      expect(order['z'], 2);
    });
  });

  group('buildCheckpointConversation', () {
    test('digest is order-independent and edit-sensitive', () {
      Map<String, dynamic> row(String id, int ts, {int? up}) =>
          _msg(id, ts, updatedAtUs: up);
      final first = buildCheckpointConversation(
        conversationRow: {'updated_at': 1},
        messageRows: [row('m1', 5), row('m2', 6)],
      );
      final reordered = buildCheckpointConversation(
        conversationRow: {'updated_at': 1},
        messageRows: [row('m2', 6), row('m1', 5)],
      );
      final edited = buildCheckpointConversation(
        conversationRow: {'updated_at': 1},
        messageRows: [row('m1', 5, up: 9), row('m2', 6)],
      );
      expect(first.digest, reordered.digest);
      expect(first.digest, isNot(equals(edited.digest)));
      expect(first.rows, {'m1': 5, 'm2': 6});
    });
  });

  group('planRowSync', () {
    // The decision table both faces share. One row, three views of it.
    test('agreement is nothing to do', () {
      expect(
        planRowSync(mineDigest: 'd', peerDigest: 'd', checkpointDigest: 'd'),
        SyncConvAction.none,
      );
      expect(
        planRowSync(mineDigest: 'd', peerDigest: 'd', checkpointDigest: null),
        SyncConvAction.none,
      );
    });

    test('a row only one side has travels that way', () {
      expect(
        planRowSync(mineDigest: 'd', peerDigest: null, checkpointDigest: null),
        SyncConvAction.iSend,
      );
      expect(
        planRowSync(mineDigest: null, peerDigest: 'd', checkpointDigest: null),
        SyncConvAction.peerSends,
      );
    });

    test('deletions propagate only when the other side is unmodified', () {
      // Peer deleted it; we still hold exactly what the checkpoint recorded.
      expect(
        planRowSync(mineDigest: 'd', peerDigest: null, checkpointDigest: 'd'),
        SyncConvAction.iDelete,
      );
      // We edited it since: edit beats delete.
      expect(
        planRowSync(
          mineDigest: 'edited',
          peerDigest: null,
          checkpointDigest: 'd',
        ),
        SyncConvAction.iSend,
      );
      // We deleted it; the peer is unmodified, so it must delete too.
      expect(
        planRowSync(mineDigest: null, peerDigest: 'd', checkpointDigest: 'd'),
        SyncConvAction.peerDeletes,
      );
      expect(
        planRowSync(
          mineDigest: null,
          peerDigest: 'edited',
          checkpointDigest: 'd',
        ),
        SyncConvAction.peerSends,
      );
      expect(
        planRowSync(mineDigest: null, peerDigest: null, checkpointDigest: 'd'),
        SyncConvAction.bothDeleted,
      );
    });

    test('divergence since the checkpoint exchanges both ways', () {
      expect(
        planRowSync(mineDigest: 'a', peerDigest: 'b', checkpointDigest: 'c'),
        SyncConvAction.bothSend,
      );
      expect(
        planRowSync(mineDigest: 'a', peerDigest: 'b', checkpointDigest: null),
        SyncConvAction.bothSend,
      );
      expect(
        planRowSync(
          mineDigest: 'mine',
          peerDigest: 'cp',
          checkpointDigest: 'cp',
        ),
        SyncConvAction.iSend,
      );
      expect(
        planRowSync(
          mineDigest: 'cp',
          peerDigest: 'theirs',
          checkpointDigest: 'cp',
        ),
        SyncConvAction.peerSends,
      );
    });
  });

  group('planBusinessSync', () {
    SyncManifestEntry entry(String digest) =>
        SyncManifestEntry(updatedAtUs: 1, messageCount: 0, digest: digest);

    test('covers entity kinds and preference keys with one table', () {
      final mine = SyncManifest(
        const {},
        entities: {
          'assistant_rows': {'a1': entry('x')},
        },
        preferences: {'user_name': entry('y')},
      );
      final peers = SyncManifest(
        const {},
        entities: {
          'world_book_rows': {'w1': entry('z')},
        },
      );
      final plan = planBusinessSync(
        mine: mine,
        peers: peers,
        checkpoint: SyncCheckpoint.empty,
      );
      final byId = {
        for (final item in plan) syncBusinessKey(item.kindWire, item.id): item,
      };
      expect(
        byId[syncBusinessKey('assistant_rows', 'a1')]!.action,
        SyncConvAction.iSend,
      );
      expect(
        byId[syncBusinessKey('world_book_rows', 'w1')]!.action,
        SyncConvAction.peerSends,
      );
      expect(
        byId[syncBusinessKey(kSyncPreferenceWire, 'user_name')]!.action,
        SyncConvAction.iSend,
      );
    });

    test('a key the peer dropped since the checkpoint is deleted here', () {
      final mine = SyncManifest(
        const {},
        preferences: {'user_name': entry('y')},
      );
      final checkpoint = SyncCheckpoint(
        const {},
        preferences: {
          'user_name': const SyncCheckpointEntry(updatedAtUs: 1, digest: 'y'),
        },
      );
      final plan = planBusinessSync(
        mine: mine,
        peers: const SyncManifest({}),
        checkpoint: checkpoint,
      );
      expect(plan.single.action, SyncConvAction.iDelete);
    });
  });

  group('incomingBusinessRowWins', () {
    test('the newer clock wins', () {
      expect(
        incomingBusinessRowWins(
          localUpdatedAtUs: 10,
          incomingUpdatedAtUs: 11,
          myDeviceId: 'aaa',
          peerDeviceId: 'bbb',
        ),
        isTrue,
      );
      expect(
        incomingBusinessRowWins(
          localUpdatedAtUs: 11,
          incomingUpdatedAtUs: 10,
          myDeviceId: 'aaa',
          peerDeviceId: 'bbb',
        ),
        isFalse,
      );
    });

    test('a tie falls to the higher deviceId, on both sides', () {
      // The peer has the higher id: it wins here...
      expect(
        incomingBusinessRowWins(
          localUpdatedAtUs: 10,
          incomingUpdatedAtUs: 10,
          myDeviceId: 'aaa',
          peerDeviceId: 'bbb',
        ),
        isTrue,
      );
      // ...and on the peer, the same comparison is evaluated from its side with
      // the same verdict (its own id is higher, so it keeps its row).
      expect(
        incomingBusinessRowWins(
          localUpdatedAtUs: 10,
          incomingUpdatedAtUs: 10,
          myDeviceId: 'bbb',
          peerDeviceId: 'aaa',
        ),
        isFalse,
      );
    });
  });

  group('businessContentDigest', () {
    test('is content-sensitive and stable', () {
      expect(
        businessContentDigest('{"a":1}'),
        businessContentDigest('{"a":1}'),
      );
      expect(
        businessContentDigest('{"a":1}'),
        isNot(businessContentDigest('{"a":2}')),
      );
    });
  });

  group('skill content planning (slice 3)', () {
    const skillWire = 'skill';
    const payloadDigest = 'payload-digest';

    SyncManifest skillManifest(String id, int clockUs, String dirHash) =>
        SyncManifest(
          const {},
          entities: {
            skillWire: {
              id: SyncManifestEntry(
                updatedAtUs: clockUs,
                messageCount: 0,
                digest: combineSkillDigest(payloadDigest, dirHash),
              ),
            },
          },
        );

    test('a content-only edit is visible even though the record clock is '
        'unchanged', () {
      const clock = 1000;
      final mine = skillManifest('s', clock, 'hash-a');
      // Same record clock, same payload digest, a different body: without the
      // directory hash in the digest this would read as "nothing changed".
      final peers = skillManifest('s', clock, 'hash-b');
      final checkpoint = SyncCheckpoint(
        const {},
        entities: {
          skillWire: {
            's': SyncCheckpointEntry(
              updatedAtUs: clock,
              digest: combineSkillDigest(payloadDigest, 'hash-a'),
            ),
          },
        },
      );

      final plan = planSkillContentSync(
        mine: mine,
        peers: peers,
        checkpoint: checkpoint,
        skillWire: skillWire,
      );

      // The unchanged side adopts the changed side.
      expect(plan.single.action, SyncConvAction.peerSends);
    });

    test('both sides changed the body with different clocks', () {
      const mine = SyncManifestEntry(
        updatedAtUs: 2000,
        messageCount: 0,
        digest: 'mine',
      );
      const peer = SyncManifestEntry(
        updatedAtUs: 3000,
        messageCount: 0,
        digest: 'peer',
      );
      final plan = planSkillContentSync(
        mine: SyncManifest(
          const {},
          entities: {
            skillWire: {'s': mine},
          },
        ),
        peers: SyncManifest(
          const {},
          entities: {
            skillWire: {'s': peer},
          },
        ),
        checkpoint: SyncCheckpoint(
          const {},
          entities: {
            skillWire: {
              's': const SyncCheckpointEntry(updatedAtUs: 1000, digest: 'old'),
            },
          },
        ),
        skillWire: skillWire,
      );

      expect(plan.single.action, SyncConvAction.bothSend);
      // The one LWW rule decides the winner: the newer record clock, then the
      // higher deviceId — evaluated symmetrically by both peers.
      expect(
        incomingBusinessRowWins(
          localUpdatedAtUs: mine.updatedAtUs,
          incomingUpdatedAtUs: peer.updatedAtUs,
          myDeviceId: 'aaa',
          peerDeviceId: 'bbb',
        ),
        isTrue,
      );
      expect(
        incomingBusinessRowWins(
          localUpdatedAtUs: peer.updatedAtUs,
          incomingUpdatedAtUs: mine.updatedAtUs,
          myDeviceId: 'bbb',
          peerDeviceId: 'aaa',
        ),
        isFalse,
      );
    });

    test('an untouched skill deleted on the peer is deleted here', () {
      final plan = planSkillContentSync(
        mine: skillManifest('s', 1000, 'hash-a'),
        peers: const SyncManifest({}),
        checkpoint: SyncCheckpoint(
          const {},
          entities: {
            skillWire: {
              's': SyncCheckpointEntry(
                updatedAtUs: 1000,
                digest: combineSkillDigest(payloadDigest, 'hash-a'),
              ),
            },
          },
        ),
        skillWire: skillWire,
      );
      expect(plan.single.action, SyncConvAction.iDelete);
    });

    test('a skill local to one device is offered to the other', () {
      final plan = planSkillContentSync(
        mine: skillManifest('s', 1000, 'hash-a'),
        peers: const SyncManifest({}),
        checkpoint: SyncCheckpoint.empty,
        skillWire: skillWire,
      );
      expect(plan.single.action, SyncConvAction.iSend);
    });

    test('a record without a body compares unequal to one with a body', () {
      // The sentinel is a legal digest value, so "no directory here" cannot
      // silently equal a real directory hash.
      expect(
        combineSkillDigest(payloadDigest, 'missing'),
        isNot(combineSkillDigest(payloadDigest, 'hash-a')),
      );
    });
  });

  group('blob wire shapes (slice 3)', () {
    test('a blob entry round-trips and keys its retry by target', () {
      const entry = SyncBlobEntry(
        kind: SyncBlobEntry.kindSkillDir,
        key: 'writer',
        contentHash: 'abc123',
      );
      final decoded = SyncBlobEntry.fromJson(entry.toJson());
      expect(decoded.kind, entry.kind);
      expect(decoded.key, entry.key);
      expect(decoded.contentHash, entry.contentHash);
      expect(decoded.target, entry.target);
      expect(decoded, entry, reason: 'equality ignores byteSize');

      expect(entry.withSize(42).byteSize, 42);
      expect(entry.withSize(42), entry);
    });

    test('hello carries the listener port the responder pulls from', () {
      final hello = SyncHello(
        protocolVersion: kSyncProtocolVersion,
        schemaVersion: 7,
        deviceId: 'd1',
        deviceName: 'laptop',
        platform: 'windows',
        manifest: const SyncManifest({}),
        listenPort: 9527,
      );
      final decoded = SyncHello.fromJson(hello.toJson());
      expect(decoded.listenPort, 9527);
      expect(decoded.protocolVersion, kSyncProtocolVersion);
      // Absent means "no listener": a v3 peer never invents one.
      expect(
        SyncHello.fromJson(
          SyncHello(
            protocolVersion: kSyncProtocolVersion,
            schemaVersion: 7,
            deviceId: 'd1',
            deviceName: 'laptop',
            platform: 'windows',
            manifest: const SyncManifest({}),
          ).toJson(),
        ).listenPort,
        isNull,
      );
    });

    test('hello carries the clock reading the skew warning comes from', () {
      final hello = SyncHello(
        protocolVersion: kSyncProtocolVersion,
        schemaVersion: 7,
        deviceId: 'd1',
        deviceName: 'laptop',
        platform: 'windows',
        manifest: const SyncManifest({}),
        clockUs: 1700000000000000,
      );
      expect(SyncHello.fromJson(hello.toJson()).clockUs, 1700000000000000);
      // A body without the reading degrades to "no reading", not an error.
      expect(
        SyncHello.fromJson(
          SyncHello(
            protocolVersion: kSyncProtocolVersion,
            schemaVersion: 7,
            deviceId: 'd1',
            deviceName: 'laptop',
            platform: 'windows',
            manifest: const SyncManifest({}),
          ).toJson(),
        ).clockUs,
        isNull,
      );
    });

    test('a peer report round-trips the lost-row counters and the skew', () {
      const report = SyncPeerReport(
        success: true,
        entityRowsLost: 2,
        preferencesLost: 1,
        clockSkewMs: -420000,
      );
      final decoded = SyncPeerReport.fromJson(report.toJson());
      expect(decoded.entityRowsLost, 2);
      expect(decoded.preferencesLost, 1);
      expect(decoded.clockSkewMs, -420000);

      // No warning is an absent field, never an invented zero: "not measured"
      // and "measured, perfectly aligned" must stay distinguishable.
      const clean = SyncPeerReport(success: true);
      expect(clean.toJson().containsKey('clockSkewMs'), isFalse);
      expect(SyncPeerReport.fromJson(clean.toJson()).clockSkewMs, isNull);
      expect(SyncPeerReport.fromJson(clean.toJson()).entityRowsLost, 0);
    });

    test('a delta batch round-trips its manifest and skill hashes', () {
      final batch = SyncDeltaBatch(
        const [],
        assets: const [
          SyncBlobEntry(
            kind: SyncBlobEntry.kindFile,
            key: 'kelivo-file:///images/a.png',
            contentHash: 'h1',
            byteSize: 12,
          ),
        ],
        skillHashes: const {'writer': 'dirhash'},
      );
      final decoded = SyncDeltaBatch.decodeJson(batch.encodeJson());
      expect(decoded.assets.single.key, 'kelivo-file:///images/a.png');
      expect(decoded.assets.single.byteSize, 12);
      expect(decoded.skillHashes, {'writer': 'dirhash'});
    });

    test('a checkpoint round-trips pending blobs and skill baselines', () {
      final checkpoint = SyncCheckpoint(
        const {},
        pendingBlobs: const {
          'file\u0000kelivo-file:///images/a.png': SyncBlobEntry(
            kind: SyncBlobEntry.kindFile,
            key: 'kelivo-file:///images/a.png',
            contentHash: 'h1',
          ),
        },
        skillHashes: const {'writer': 'dirhash'},
      );
      final decoded = SyncCheckpoint.fromJson(checkpoint.toJson());
      expect(decoded.pendingBlobs.keys.single, contains('images/a.png'));
      expect(decoded.pendingBlobs.values.single.contentHash, 'h1');
      expect(decoded.skillHashes, {'writer': 'dirhash'});
      // A checkpoint written before slice 3 simply has neither map.
      final legacy = SyncCheckpoint.fromJson(const {'version': 1});
      expect(legacy.pendingBlobs, isEmpty);
      expect(legacy.skillHashes, isEmpty);
      expect(legacy.unappliedConversations, isEmpty);
      expect(legacy.unappliedBusiness, isFalse);
    });

    test('hello and checkpoint round-trip the deferred-apply report', () {
      // A device that could not apply what it received must be able to say so:
      // without it the peer reads the silence as a deletion.
      final hello = SyncHello(
        protocolVersion: kSyncProtocolVersion,
        schemaVersion: 3,
        deviceId: 'd1',
        deviceName: 'one',
        platform: 'test',
        manifest: const SyncManifest({}),
        unappliedConversations: const ['conv-1', 'conv-2'],
        unappliedBusiness: true,
      );
      final decodedHello = SyncHello.fromJson(hello.toJson());
      expect(decodedHello.unappliedConversations, ['conv-1', 'conv-2']);
      expect(decodedHello.unappliedBusiness, isTrue);

      final checkpoint = SyncCheckpoint(
        const {},
        unappliedConversations: const ['conv-1'],
        unappliedBusiness: true,
      );
      final decoded = SyncCheckpoint.fromJson(checkpoint.toJson());
      expect(decoded.unappliedConversations, ['conv-1']);
      expect(decoded.unappliedBusiness, isTrue);
      // Both fields are omitted when there is nothing to report, so an
      // untouched checkpoint file stays the shape it always was.
      final quiet = SyncCheckpoint.fromJson(SyncCheckpoint(const {}).toJson());
      expect(quiet.unappliedConversations, isEmpty);
      expect(quiet.unappliedBusiness, isFalse);
    });

    test('an apply acknowledgement round-trips what it deferred', () {
      final ack = SyncApplyAck(
        applied: 2,
        deferred: const {'conv-2'},
        businessDeferred: true,
        deferredSkills: const {'skill-1'},
      );
      final decoded = SyncApplyAck.fromJson(ack.toJson());
      expect(decoded.applied, 2);
      expect(decoded.deferred, {'conv-2'});
      expect(decoded.businessDeferred, isTrue);
      expect(decoded.deferredSkills, {'skill-1'});
      // Nothing deferred: the fields are absent, and both mean "confirmed".
      final empty = SyncApplyAck.fromJson(const {'applied': 0});
      expect(empty.deferred, isEmpty);
      expect(empty.businessDeferred, isFalse);
      expect(empty.deferredSkills, isEmpty);
    });

    test('a hello round-trips its announced deletions and their digests', () {
      // A deleted conversation is announced by name and by the digest both
      // sides last agreed on: the digest is what lets the receiver tell a
      // deletion from an edit it made since.
      final hello = SyncHello(
        protocolVersion: kSyncProtocolVersion,
        schemaVersion: 3,
        deviceId: 'd1',
        deviceName: 'one',
        platform: 'test',
        manifest: const SyncManifest({}),
        deletedConversations: const {'conv-1': 'digest-a', 'conv-2': 'digest-b'},
      );
      final decoded = SyncHello.fromJson(hello.toJson());
      expect(decoded.deletedConversations, {
        'conv-1': 'digest-a',
        'conv-2': 'digest-b',
      });
      // Omitted when there is nothing to announce.
      final quiet = SyncHello.fromJson(
        SyncHello(
          protocolVersion: kSyncProtocolVersion,
          schemaVersion: 3,
          deviceId: 'd1',
          deviceName: 'one',
          platform: 'test',
          manifest: const SyncManifest({}),
        ).toJson(),
      );
      expect(quiet.deletedConversations, isEmpty);
    });
  });
}
