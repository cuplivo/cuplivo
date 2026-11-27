import 'dart:io';

import 'package:Cuplivo/core/services/sync/sync_models.dart';
import 'package:Cuplivo/core/services/sync/sync_store.dart';
import 'package:flutter_test/flutter_test.dart';

/// The data epoch and the checkpoint reset: what a bulk replacement of the
/// database (a restore, an overwrite import) owes the sync state. The
/// checkpoint's premise — "the peer lacks a row because it deleted it" — is
/// false after one, and the peer must be able to tell.
void main() {
  late Directory root;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('cuplivo_sync_store_epoch_');
  });

  tearDown(() async {
    if (await root.exists()) await root.delete(recursive: true);
  });

  test('a store without an epoch file reads zero', () async {
    expect(await SyncStore(root).readDataEpoch(), 0);
  });

  test('a bulk replacement resets checkpoints and bumps the epoch', () async {
    final store = SyncStore(root);
    await store.ensureDirectories();
    await store.saveCheckpoint(
      'peer-1',
      SyncCheckpoint({
        'conv-1': const SyncCheckpointConversation(
          updatedAtUs: 1,
          digest: 'digest-1',
          rows: {'m1': 1},
        ),
      }),
    );
    expect((await store.loadCheckpoint('peer-1')).conversations, hasLength(1));

    await SyncStore.resetForBulkReplacement(root);

    expect(await store.readDataEpoch(), 1);
    expect(
      (await store.loadCheckpoint('peer-1')).conversations,
      isEmpty,
      reason: 'the entry described a history the replaced database lost',
    );

    // Repeating is safe — an interrupted cutover may run it again — and only
    // costs one more re-convergence.
    await SyncStore.resetForBulkReplacement(root);
    expect(await store.readDataEpoch(), 2);
  });

  test('an unreadable epoch file degrades to zero', () async {
    await File('${root.path}/epoch.json').writeAsString('not json');
    expect(await SyncStore(root).readDataEpoch(), 0);
  });

  test('loadSession reads the epoch before the checkpoint', () async {
    // The order is the guard, and it is invisible in the return value: both
    // readings look identical until a replacement fits between them. So the pair
    // is pinned by watching the two reads themselves — swapping the two lines in
    // [SyncStore.loadSession] fails here.
    final store = _OrderProbeStore(root);
    await store.ensureDirectories();
    await store.saveCheckpoint('peer-1', _rowFaceCheckpoint('workspace', 'w1'));

    final opened = await store.loadSession('peer-1');

    expect(
      store.order,
      ['epoch', 'checkpoint'],
      reason:
          'a replacement sweeps the checkpoints and only then bumps the epoch, '
          'so the epoch has to be the first read of the pair',
    );
    expect(opened.previous.entities, isNotEmpty);
  });

  test('a session that reads its epoch first survives a replacement landing '
      'between its two reads', () async {
    // The engine plans from one pair of reads ([SyncStore.loadSession]), and the
    // order *inside* that pair is half of the guard: a replacement sweeps the
    // checkpoints and only then bumps the epoch.
    final store = SyncStore(root);
    await store.ensureDirectories();
    await store.saveCheckpoint('peer-1', _rowFaceCheckpoint('workspace', 'w1'));

    final epochAtHello = await store
        .readDataEpoch(); // loadSession's first read
    // A settings-only restore lands in the window this order opens.
    await SyncStore.resetRowFaceForBulkReplacement(root);
    final previous = await store.loadCheckpoint('peer-1'); // its second read

    await store.saveCheckpointUnlessReplaced(
      'peer-1',
      epochAtHello: epochAtHello,
      checkpoint: previous,
    );

    expect(
      (await store.loadCheckpoint('peer-1')).entities,
      isEmpty,
      reason:
          'the epoch read before the checkpoint is what makes the closing save '
          'see the replacement and skip; the reset entries stay dropped',
    );
  });

  test('control: the reversed read order puts the dropped rows back', () async {
    // Not a defect this suite endorses — the hazard [SyncStore.loadSession]
    // exists to make unreachable, pinned so that nobody "simplifies" the pair
    // back into two reads in the engine's old order. Checkpoint first, epoch
    // second, and a replacement that fits entirely between the two reads compares
    // equal at save time: the entries the reset dropped go back on disk, and one
    // session later the peer reads them as deletions and deletes rows nobody
    // deleted.
    final store = SyncStore(root);
    await store.ensureDirectories();
    await store.saveCheckpoint('peer-1', _rowFaceCheckpoint('workspace', 'w1'));

    final previous = await store.loadCheckpoint(
      'peer-1',
    ); // the wrong first read
    await SyncStore.resetRowFaceForBulkReplacement(root);
    final epochAtHello = await store.readDataEpoch(); // the wrong second read

    await store.saveCheckpointUnlessReplaced(
      'peer-1',
      epochAtHello: epochAtHello,
      checkpoint: previous,
    );

    expect(
      (await store.loadCheckpoint('peer-1')).entities,
      isNotEmpty,
      reason:
          'if this ever fails, a reset became immune to the read order: tighten '
          '[SyncStore.loadSession] and delete this control',
    );
  });

  test('a session whose epoch still matches writes its checkpoint', () async {
    final store = SyncStore(root);
    await store.ensureDirectories();
    final epochAtHello = await store.readDataEpoch();

    await store.saveCheckpointUnlessReplaced(
      'peer-1',
      epochAtHello: epochAtHello,
      checkpoint: SyncCheckpoint({
        'conv-1': const SyncCheckpointConversation(
          updatedAtUs: 1,
          digest: 'digest-1',
          rows: {'m1': 1},
        ),
      }),
    );

    expect(
      (await store.loadCheckpoint('peer-1')).conversations,
      contains('conv-1'),
      reason:
          'the ordinary path is unchanged, or no session would ever advance',
    );
  });
}

/// A checkpoint carrying one business row entry — the half a settings-only
/// overwrite drops and the conversation half does not.
SyncCheckpoint _rowFaceCheckpoint(String kindWire, String id) => SyncCheckpoint(
  const {},
  entities: {
    kindWire: {id: const SyncCheckpointEntry(updatedAtUs: 5, digest: 'agreed')},
  },
);

/// Records the order in which [SyncStore.loadSession] performs its two reads.
class _OrderProbeStore extends SyncStore {
  _OrderProbeStore(super.root);

  final List<String> order = [];

  @override
  Future<int> readDataEpoch() {
    order.add('epoch');
    return super.readDataEpoch();
  }

  @override
  Future<SyncCheckpoint> loadCheckpoint(String deviceId) {
    order.add('checkpoint');
    return super.loadCheckpoint(deviceId);
  }
}
