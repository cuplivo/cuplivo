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
}
