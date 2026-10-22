import 'dart:io';

import 'package:Cuplivo/core/database/app_database.dart';
import 'package:Cuplivo/core/database/chat_database_repository.dart';
import 'package:Cuplivo/core/models/chat_message.dart';
import 'package:Cuplivo/core/models/conversation.dart';
import 'package:Cuplivo/core/services/recycle/recycle_service.dart';
import 'package:flutter_test/flutter_test.dart';

/// What a conversation deletion leaves behind, and what a restore puts back.
///
/// The boundary this file also pins: deleting one message is not a bin
/// operation, and a bulk reset stages nothing at all.
/// A bin that says when it starts writing, for the test that has to prove the
/// write is not on the delete's own path.
///
/// [onStage] runs at the moment the snapshot is handed over, so it can read the
/// database and answer whether the delete had already committed by then.
class _RecordingStore extends RecycleStore {
  _RecordingStore({required super.directory});

  Future<void> Function(String key)? onStage;
  final List<String> stagedKeys = <String>[];

  @override
  Future<RecycleEntry?> stageRows({
    required RecycleEntryType type,
    required RecycleOrigin origin,
    required RecycleReason reason,
    required String key,
    required String title,
    required Map<String, List<Map<String, Object?>>> tables,
    String? kindWire,
    RecycleGroup? group,
  }) async {
    stagedKeys.add(key);
    await onStage?.call(key);
    return super.stageRows(
      type: type,
      origin: origin,
      reason: reason,
      key: key,
      title: title,
      tables: tables,
      kindWire: kindWire,
      group: group,
    );
  }
}

void main() {
  group('conversation deletion recovery', () {
    late Directory directory;
    late Directory binRoot;
    late AppDatabase database;
    late _RecordingStore store;
    late RecycleService recycle;
    late ChatDatabaseRepository repository;

    setUp(() async {
      directory = await Directory.systemTemp.createTemp('kelivo_recycle_conv_');
      binRoot = Directory('${directory.path}/bin');
      database = AppDatabase.open(file: File('${directory.path}/chat.sqlite'));
      store = _RecordingStore(directory: () async => binRoot);
      recycle = RecycleService(database, store: store);
      repository = ChatDatabaseRepository(database, recycle: recycle);
      await repository.ensureReady();
    });

    tearDown(() async {
      await repository.close();
      if (await directory.exists()) await directory.delete(recursive: true);
    });

    /// The bin writes *after* the operation that fed it — a delete must not wait
    /// for its own safety net — so an assertion about the bin lets that write
    /// finish first. The "stages nothing" tests go through here for the same
    /// reason and one more: without it they would pass merely because the write
    /// had not started yet.
    Future<List<RecycleEntry>> binEntries() async {
      await recycle.settle();
      return recycle.list();
    }

    Future<void> seedConversation(String id, {int messages = 2}) async {
      final createdAt = DateTime.utc(2026, 8, 1);
      await repository.putMigrationBatch(
        conversations: [
          Conversation(
            id: id,
            title: 'Topic $id',
            createdAt: createdAt,
            updatedAt: createdAt,
            messageIds: [
              for (var index = 0; index < messages; index++) '$id-m$index',
            ],
          ),
        ],
        messages: [
          for (var index = 0; index < messages; index++)
            (
              message: ChatMessage(
                id: '$id-m$index',
                role: index == 0 ? 'user' : 'assistant',
                content: 'message $index',
                conversationId: id,
                groupId: '$id-m$index',
                version: 0,
                timestamp: createdAt.add(Duration(minutes: index)),
              ),
              messageOrder: index,
            ),
        ],
        toolEventsByMessageId: const {},
        geminiSignaturesByMessageId: const {},
      );
    }

    test('a deleted conversation is staged with its whole subtree', () async {
      await seedConversation('c1');
      final partsBefore = await repository.syncReadMessagePartRows('c1');

      await repository.deleteConversation('c1');

      final entry = (await binEntries()).single;
      expect(entry.type, RecycleEntryType.conversation);
      expect(entry.key, 'c1');
      expect(entry.title, 'Topic c1');
      expect(entry.origin, RecycleOrigin.local);
      expect(entry.reason, RecycleReason.deleted);

      final tables = await store.readTables(entry);
      expect(tables!['conversation_rows']!.single['title'], 'Topic c1');
      expect(tables['message_rows'], hasLength(2));
      expect(tables['message_part_rows'], hasLength(partsBefore.length));
    });

    test('restoring brings the subtree back and wins the next clock', () async {
      await seedConversation('c1');
      final partsBefore = await repository.syncReadMessagePartRows('c1');
      await repository.deleteConversation('c1');
      final entry = (await binEntries()).single;
      final staged = await store.readTables(entry);
      final stagedClock =
          staged!['conversation_rows']!.single['updated_at']! as int;

      expect(await recycle.restore(entry), RecycleRestoreOutcome.restored);

      final restored = await repository.syncReadConversationRow('c1');
      expect(restored, isNotNull);
      expect(restored!['title'], 'Topic c1');
      expect(
        restored['updated_at'] as int,
        greaterThan(stagedClock),
        reason: 'a restore is a fresh local write, not a clock resurrection',
      );
      expect(await repository.syncReadMessageRows('c1'), hasLength(2));
      expect(
        (await repository.syncReadMessagePartRows('c1')).length,
        partsBefore.length,
      );
      expect(
        await repository.readTombstones(),
        isEmpty,
        reason: 'the deletion record goes with the deletion it recorded',
      );
      expect(
        await binEntries(),
        isEmpty,
        reason: 'the entry is retired by its own restore',
      );
    });

    test('a conversation that is present again is not overwritten', () async {
      await seedConversation('c1');
      await repository.deleteConversation('c1');
      final entry = (await binEntries()).single;
      await seedConversation('c1');

      expect(
        await recycle.restore(entry),
        RecycleRestoreOutcome.skippedExisting,
      );
      expect(
        await binEntries(),
        hasLength(1),
        reason: 'nothing was restored, so nothing is retired',
      );
    });

    test('a peer deletion stages with the remote origin', () async {
      await seedConversation('c1');

      expect(await repository.syncApplyPeerDeletion('c1'), isTrue);

      final entry = (await binEntries()).single;
      expect(entry.origin, RecycleOrigin.remote);
      expect(entry.key, 'c1');
    });

    test('a delete returns before the bin has begun writing', () async {
      // The delete is something the user waits for; the bin is only its safety
      // net. "Detached" therefore has to mean the bin's decode and encode are not
      // on the delete's own stack — an async body runs synchronously up to its
      // first await, so *calling* the closure puts that work back on the path.
      await seedConversation('c1');

      await repository.deleteConversation('c1');

      expect(
        store.stagedKeys,
        isEmpty,
        reason: 'nothing may be decoded or written on the delete\'s own path',
      );
      await recycle.settle();
      expect(store.stagedKeys, ['c1']);
    });

    test('the capture crosses the transaction it was taken in', () async {
      // The other half, and the one a detach alone cannot give: the capture has
      // to be staged *after* the transaction that removed the rows commits, or
      // the decode holds the write transaction open for its duration. Read per
      // staging rather than into one variable: a build that stages twice would
      // otherwise let the second, later reading answer for the first.
      await seedConversation('c1');
      final rowPresentWhenStaged = <bool>[];
      store.onStage = (key) async {
        rowPresentWhenStaged.add(
          await repository.syncReadConversationRow(key) != null,
        );
      };

      await repository.deleteConversation('c1');
      await recycle.settle();

      expect(rowPresentWhenStaged, isNotEmpty);
      expect(
        rowPresentWhenStaged.first,
        isFalse,
        reason: 'the write runs after the delete committed, not before it',
      );
    });

    test('deleting one message stages nothing', () async {
      await seedConversation('c1');

      await repository.deleteMessage('c1-m1');

      expect(
        await binEntries(),
        isEmpty,
        reason:
            'message-level deletion is an edit inside a conversation, '
            'not a conversation leaving the bin\'s custody',
      );
      expect(await repository.syncReadMessageRows('c1'), hasLength(1));
    });

    test('a bulk reset stages nothing', () async {
      await seedConversation('c1');
      await seedConversation('c2');

      await repository.clearAllData();

      expect(
        await binEntries(),
        isEmpty,
        reason: 'replacing the whole local state is not a deletion intent',
      );
      expect(await repository.readTombstones(), isEmpty);
    });
  });
}
