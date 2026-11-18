import 'dart:io';

import 'package:Cuplivo/core/database/app_database.dart';
import 'package:Cuplivo/core/database/chat_database_repository.dart';
import 'package:Cuplivo/core/models/conversation.dart';
import 'package:Cuplivo/core/services/recycle/recycle_service.dart';
import 'package:Cuplivo/core/services/sync/sync_family_registry.dart';
import 'package:Cuplivo/core/services/sync/sync_models.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/sync_payload.dart';

/// Recovery for the conversation documents a sync replaces.
///
/// The business face stages a row its comparison loses to; a conversation
/// document is a whole record — a compaction history, the image-context
/// switches — and losing it used to leave only the report line. The apply now
/// stages the losing copy before the write, and the bin can name it by its
/// extension kind (these kinds are not `BusinessEntityKind` members).
void main() {
  late Directory root;
  late AppDatabase database;
  late RecycleStore store;
  late RecycleService recycle;
  late ChatDatabaseRepository repository;
  const conversationId = 'conv';
  const conversationTitle = 'Compressed chat';

  final compressionFamily = kSyncFamilies.singleWhere(
    (family) =>
        family.table == 'extension_entity_rows' &&
        family.kind == 'conversationCompression',
  );

  setUp(() async {
    root = await Directory.systemTemp.createTemp('kelivo_recycle_document_');
    database = AppDatabase(NativeDatabase.memory());
    store = RecycleStore(directory: () async => root);
    recycle = RecycleService(database, store: store);
    repository = ChatDatabaseRepository(database, recycle: recycle);
    await repository.ensureReady();
    await repository.putMigrationBatch(
      conversations: [
        Conversation(id: conversationId, title: conversationTitle),
      ],
      messages: const [],
      toolEventsByMessageId: const {},
      geminiSignaturesByMessageId: const {},
    );
  });

  tearDown(() async {
    await database.close();
    if (await root.exists()) await root.delete(recursive: true);
  });

  Map<String, dynamic> conversationRow() => {
    'id': conversationId,
    'title': conversationTitle,
    'created_at': 1,
    'updated_at': 1,
    'is_pinned': 0,
    'assistant_id': null,
    'truncate_index': 0,
    'version_selections_json': null,
    'summary': null,
    'last_summarized_message_count': 0,
    'chat_suggestions_json': null,
    'injected_memory_hash': null,
    'last_memory_extracted_order': 0,
    'chat_model_provider': null,
    'chat_model_id': null,
    'extras_json': null,
  };

  Map<String, dynamic> documentRow({
    required String payload,
    required int updatedAt,
  }) => {
    'kind': compressionFamily.kind,
    'id': conversationId,
    'sort_order': 0,
    'owner_id': conversationId,
    'payload': payload,
    'updated_at': updatedAt,
  };

  Future<SyncSubtreeApplyOutcome> apply(String payload, int at) =>
      repository.syncApplySubtree(
        payload: subtreePayload(
          conversation: conversationRow(),
          families: {
            compressionFamily.name: [
              documentRow(payload: payload, updatedAt: at),
            ],
          },
        ),
        myDeviceId: 'me',
        peerDeviceId: 'peer',
        checkpointRows: const {},
      );

  Future<List<Map<String, dynamic>>> document() =>
      repository.syncReadFamilyRows(compressionFamily, conversationId);

  test('a document the peer replaces is staged and can be restored', () async {
    await apply('{"formatVersion":1,"history":["mine"]}', 100);
    await apply('{"formatVersion":1,"history":["theirs"]}', 200);

    // The bin writes after the operation that fed it, like every other stage.
    await recycle.settle();
    final entry = (await recycle.list()).single;
    expect(entry.type, RecycleEntryType.businessEntity);
    expect(entry.kindWire, 'conversationCompression');
    expect(entry.key, conversationId);
    expect(
      entry.title,
      conversationTitle,
      reason: 'the payload names nothing; the conversation title is the label',
    );
    expect(entry.origin, RecycleOrigin.remote);
    expect(entry.reason, RecycleReason.overwritten);

    expect((await document()).single['payload'], contains('theirs'));

    expect(await recycle.restore(entry), RecycleRestoreOutcome.restored);
    expect(
      (await document()).single['payload'],
      '{"formatVersion":1,"history":["mine"]}',
      reason: 'the restore puts the losing record back, not a summary of it',
    );
    // The restored row displaced the peer's copy, which the bin now holds.
    await recycle.settle();
    expect((await recycle.list()).single.kindWire, 'conversationCompression');
  });

  test(
    'a document whose conversation is gone is refused, not orphaned',
    () async {
      await apply('{"formatVersion":1,"history":["mine"]}', 100);
      await apply('{"formatVersion":1,"history":["theirs"]}', 200);
      await recycle.settle();

      await repository.deleteConversation(conversationId);
      await recycle.settle();
      expect(
        await document(),
        isEmpty,
        reason: "the delete takes the conversation's documents with it",
      );

      final entry = (await recycle.list()).singleWhere(
        (candidate) => candidate.kindWire == compressionFamily.kind,
      );
      expect(
        await recycle.restore(entry),
        RecycleRestoreOutcome.conversationGone,
        reason:
            'extension_entity_rows has no foreign key to the conversation, so a '
            'row written here would outlive the only thing that could read it',
      );
      expect(await document(), isEmpty);
      await recycle.settle();
      expect(
        (await recycle.list()).map((candidate) => candidate.id),
        contains(entry.id),
        reason:
            'the entry waits for the conversation rather than being consumed',
      );
    },
  );

  test('a document that did not change is not staged', () async {
    await apply('{"formatVersion":1,"history":["same"]}', 100);
    await apply('{"formatVersion":1,"history":["same"]}', 200);

    await recycle.settle();
    expect(
      await recycle.list(),
      isEmpty,
      reason: 'a newer clock over the same document is not a loss',
    );
  });
}
