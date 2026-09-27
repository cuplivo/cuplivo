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

Map<String, dynamic> _msg(String id, int timestampUs, {int? updatedAtUs}) => {
  'id': id,
  'timestamp': timestampUs,
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
    test('concurrent appends interleave by timestamp then id', () {
      final order = rederiveMessageOrder([
        _msg('b2', 20),
        _msg('a1', 10),
        _msg('b1', 20),
        _msg('a2', 12),
      ]);
      expect(order, {'a1': 0, 'a2': 1, 'b1': 2, 'b2': 3});
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
}
