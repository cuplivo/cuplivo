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

  test('a session whose epoch was superseded cannot write its checkpoint', () async {
    // A restore is a live operation with no lock: a sync round can be in flight
    // when it lands. That round read `previous` before the reset and would save
    // its own copy over it at the end — putting the replaced row entries back and,
    // one session later, ordering the peer to delete rows nobody deleted.
    final store = SyncStore(root);
    await store.ensureDirectories();
    await store.saveCheckpoint(
      'peer-1',
      SyncCheckpoint({
        'before': const SyncCheckpointConversation(
          updatedAtUs: 1,
          digest: 'digest-1',
          rows: {'m1': 1},
        ),
      }),
    );
    final epochAtHello = await store.readDataEpoch();

    await SyncStore.resetRowFaceForBulkReplacement(root);

    await store.saveCheckpointUnlessReplaced(
      'peer-1',
      epochAtHello: epochAtHello,
      checkpoint: SyncCheckpoint({
        'stale': const SyncCheckpointConversation(
          updatedAtUs: 2,
          digest: 'digest-2',
          rows: {'m2': 2},
        ),
      }),
    );

    final after = await store.loadCheckpoint('peer-1');
    expect(
      after.conversations,
      contains('before'),
      reason: 'the replacement kept the conversation half, and it stays kept',
    );
    expect(
      after.conversations,
      isNot(contains('stale')),
      reason:
          'a session that outlived the reset must not re-advance the entries',
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
