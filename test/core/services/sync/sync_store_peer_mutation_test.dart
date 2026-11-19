import 'dart:io';

import 'package:Cuplivo/core/services/sync/sync_store.dart';
import 'package:flutter_test/flutter_test.dart';

/// `SyncStore.mutatePeer` is the one merge path for a peer record. Two owners
/// write it concurrently — the panel (a rename, an endpoint edit, the measured
/// latency) and a session (`lastSyncedAt`, `lastReport`) — and a whole-record
/// write from a copy read earlier drops whatever the other one wrote.
void main() {
  late Directory root;
  late SyncStore store;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('cuplivo_sync_store_peer_');
    store = SyncStore(root);
  });

  tearDown(() async {
    try {
      await root.delete(recursive: true);
    } catch (_) {}
  });

  SyncPeerRecord record() => SyncPeerRecord(
    deviceId: 'peer-1',
    certPem: 'cert',
    secret: 'secret',
    name: 'Peer',
    platform: 'windows',
  );

  test('two writers of one record both land', () async {
    await store.savePeer(record());

    // Issued together and not awaited in between: each mutation reads the record
    // inside its own section, so neither can overwrite the other's field with a
    // copy taken before it.
    final rename = store.mutatePeer('peer-1', (peer) {
      peer.customName = 'renamed';
      return true;
    });
    final outcome = store.mutatePeer('peer-1', (peer) {
      peer.lastSyncedAt = DateTime.now();
      peer.secret = 'rotated';
      return true;
    });
    await Future.wait([rename, outcome]);

    final after = (await store.readPeer('peer-1'))!;
    expect(after.customName, 'renamed');
    expect(after.lastSyncedAt, isNotNull);
    expect(after.secret, 'rotated');
  });

  test('a mutation that changes nothing does not rewrite the record', () async {
    final file = File(
      '${root.path}${Platform.pathSeparator}peers'
      '${Platform.pathSeparator}peer-1.json',
    );
    await store.savePeer(record());
    final before = await file.readAsBytes();

    // The callback says "nothing changed" after touching the copy it was given:
    // the record is not written, so the change is discarded rather than saved —
    // which is what keeps a no-op probe round from moving a "last measured"
    // stamp it did not measure.
    final kept = await store.mutatePeer('peer-1', (peer) {
      peer.customName = 'discarded';
      return false;
    });

    expect(kept, isNotNull);
    expect(await file.readAsBytes(), before);
    expect((await store.readPeer('peer-1'))!.customName, isNull);
  });

  test('an absent record is not created by a mutation', () async {
    final created = await store.mutatePeer('nobody', (peer) {
      peer.customName = 'x';
      return true;
    });

    expect(created, isNull);
    expect(await store.readPeer('nobody'), isNull);
  });

  test('a failed mutation does not block the next one', () async {
    await store.savePeer(record());

    await expectLater(
      store.mutatePeer('peer-1', (peer) => throw StateError('write blew up')),
      throwsA(isA<StateError>()),
    );
    final after = await store.mutatePeer('peer-1', (peer) {
      peer.customName = 'after-the-failure';
      return true;
    });

    expect(after?.customName, 'after-the-failure');
    expect((await store.readPeer('peer-1'))!.customName, 'after-the-failure');
  });

  test('a pairing write and a session mutation of one peer both land', () async {
    // Pairing writes the record whole (`savePeer` — the record's *origin*), and
    // it happens on its own lane, so it can be in flight beside a session that
    // is mutating the same record. Both went through one temporary path until
    // `savePeer` joined the record's write chain: the loser's rename is what
    // Windows refuses, and the record on disk kept the OLD secret while memory
    // held the new one — a paired device that answers 401 after the next launch.
    await store.savePeer(record());
    for (var round = 0; round < 40; round++) {
      final rotated = record()..secret = 'secret-$round';
      final pairing = store.savePeer(rotated);
      final session = store.mutatePeer('peer-1', (peer) {
        peer.lastSyncedAt = DateTime.now();
        return true;
      });
      // Neither may throw: a refusal here is a pairing answered 500 after the
      // PIN was spent, or a session that ends on a 500 after its checkpoint.
      await Future.wait([pairing, session]);

      final after = (await store.readPeer('peer-1'))!;
      expect(
        after.secret,
        'secret-$round',
        reason: 'the pairing record is what the listener authenticates with',
      );
      expect(after.lastSyncedAt, isNotNull, reason: 'the session write landed');
    }
  });

  test('a mutation issued after the pairing wins the field it set', () async {
    // The chain decides the order, so a mutation queued behind a pairing reads
    // what the pairing wrote — which is the point of reading inside the section.
    await store.savePeer(record());
    final pairing = store.savePeer(record()..secret = 'rotated');
    final session = store.mutatePeer('peer-1', (peer) {
      peer.customName = 'named-later';
      return true;
    });
    await Future.wait([pairing, session]);

    final after = (await store.readPeer('peer-1'))!;
    expect(after.secret, 'rotated');
    expect(after.customName, 'named-later');
  });

  test(
    'a revocation and a mutation of one peer do not leave it half-there',
    () async {
      await store.savePeer(record());
      final session = store.mutatePeer('peer-1', (peer) {
        peer.lastSyncedAt = DateTime.now();
        return true;
      });
      final revocation = store.deletePeer('peer-1');
      await Future.wait([session, revocation]);

      // Whatever the order, the record is either gone (the revocation ran last) or
      // present with both writes applied (the mutation ran last) — never re-created
      // by a write that started before the delete and finished after it.
      final after = await store.readPeer('peer-1');
      if (after != null) expect(after.lastSyncedAt, isNotNull);
    },
  );
}
