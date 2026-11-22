import 'dart:io';

import 'package:Cuplivo/core/database/app_database.dart';
import 'package:Cuplivo/core/database/chat_database_repository.dart';
import 'package:Cuplivo/core/models/conversation.dart';
import 'package:Cuplivo/core/services/recycle/recycle_service.dart';
import 'package:Cuplivo/core/services/sync/sync_merge.dart';
import 'package:flutter_test/flutter_test.dart';

/// A restore is a local write, so it must move the clock **sync** reads — and
/// must not move the one the list reads.
///
/// The plan asks [copyWrittenSinceAgreement] whether this device wrote the row
/// since the two sides last agreed. The recycle bin's restore is the case that
/// question exists for: the row goes back while every message comes back
/// byte-identical, so the digest still matches the agreement and only the row
/// clock can tell "restored here" from "untouched here". Since the display clock
/// no longer doubles as the sync clock, the restore re-stamps the key and leaves
/// `updated_at` at the value the row was deleted with — the conversation returns
/// to its old place and date group, which is what an undo should do.
void main() {
  late Directory directory;
  late AppDatabase database;
  late RecycleService recycle;
  late ChatDatabaseRepository repository;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('restore_clock_');
    database = AppDatabase.open(file: File('${directory.path}/chat.sqlite'));
    recycle = RecycleService(
      database,
      store: RecycleStore(
        directory: () async => Directory('${directory.path}/bin'),
      ),
    );
    repository = ChatDatabaseRepository(database, recycle: recycle);
    await repository.ensureReady();
  });

  tearDown(() async {
    await repository.close();
    if (await directory.exists()) await directory.delete(recursive: true);
  });

  test('a restored conversation reads as "written here since"', () async {
    final createdAt = DateTime.utc(2026, 8, 1);
    await repository.putConversation(
      Conversation(
        id: 'conv',
        title: 'Topic',
        createdAt: createdAt,
        updatedAt: createdAt,
        extras: const {'keep': 'yes'},
      ),
    );

    final before = (await repository.syncReadConversationRow('conv'))!;
    final clockBefore = effectiveConversationClock(before);
    final updatedAtBefore = (before['updated_at'] as num).toInt();
    final digest = await repository.syncConversationDigest('conv');

    await repository.deleteConversation('conv');
    await recycle.settle();
    final entry = (await recycle.list()).single;
    expect(await recycle.restore(entry), RecycleRestoreOutcome.restored);

    final after = (await repository.syncReadConversationRow('conv'))!;
    // The display clock does not move: an undo is not activity, so the row goes
    // back into the list where it was.
    expect((after['updated_at'] as num).toInt(), updatedAtBefore);
    // The clock sync compares does move.
    expect(effectiveConversationClock(after), greaterThan(clockBefore));

    // The archived bag survives being stamped.
    expect((await repository.getConversation('conv'))!.extras['keep'], 'yes');

    // What the next session asks: the peer's copy is gone (the deletion
    // propagated), the checkpoint still names the pre-deletion agreement, and
    // this device wrote the row since. Before the stamp, this was `iDelete`.
    expect(
      planRowSync(
        mineDigest: digest,
        peerDigest: null,
        checkpointDigest: digest,
        mineClock: effectiveConversationClock(after),
        checkpointClock: clockBefore,
      ),
      SyncConvAction.iSend,
    );
  });
}
