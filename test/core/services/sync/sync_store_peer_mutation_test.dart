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
}
