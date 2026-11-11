import 'package:Cuplivo/core/database/app_database.dart';
import 'package:Cuplivo/core/database/chat_database_repository.dart';
import 'package:Cuplivo/core/services/sync/sync_models.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

/// The memory bookkeeping on a conversation row is this device's alone.
///
/// A peer's `injected_memory_hash` names the message that carries *its* memory
/// snapshot, and this device has none of the peer's freeze rows — so the value
/// can only be wrong here: it claims a snapshot is in context that was never
/// sent, or claims a change that did not happen. Either way the next turn
/// rewrote user messages and the provider's prefix cache collapsed (issue
/// #1086, 1920/250297 on the receiving device).
///
/// `last_memory_extracted_order` is the opposite case: the memory entries do
/// travel, so "these messages have already been read" is a fact about the
/// conversation that both devices share. Whole-row last-write-wins broke it
/// from both sides, which is why the join is max.
void main() {
  late AppDatabase database;
  late ChatDatabaseRepository repository;
  const conversationId = 'conv';

  setUp(() async {
    database = AppDatabase(NativeDatabase.memory());
    repository = ChatDatabaseRepository(database);
    await repository.ensureReady();
  });

  tearDown(() => database.close());

  /// A wire row carries every column of [currentSchemaColumns] except the ones
  /// that never travel — the same shape `syncReadConversationRow` produces.
  Map<String, dynamic> wireConversationRow({
    required String id,
    required int updatedAtUs,
    required int watermark,
  }) => {
    'id': id,
    'title': id,
    'created_at': 1000,
    'updated_at': updatedAtUs,
    'is_pinned': 0,
    'assistant_id': null,
    'truncate_index': 0,
    'version_selections_json': '{}',
    'summary': null,
    'last_summarized_message_count': 0,
    'chat_suggestions_json': '[]',
    'last_memory_extracted_order': watermark,
    'chat_model_provider': null,
    'chat_model_id': null,
    'extras_json': '{}',
  };

  Future<void> seedLocal({
    String? injectedMemoryHash,
    int watermark = -1,
    int updatedAtUs = 1000,
  }) async {
    await database.customStatement(
      'INSERT INTO conversation_rows (id, title, created_at, updated_at, '
      'injected_memory_hash, last_memory_extracted_order) '
      'VALUES (?, ?, ?, ?, ?, ?);',
      [
        conversationId,
        conversationId,
        1000,
        updatedAtUs,
        injectedMemoryHash,
        watermark,
      ],
    );
  }

  Future<void> apply({
    required int updatedAtUs,
    required int watermark,
    String id = conversationId,
  }) async {
    await repository.syncApplySubtree(
      payload: SyncSubtreePayload(
        conversation: wireConversationRow(
          id: id,
          updatedAtUs: updatedAtUs,
          watermark: watermark,
        ),
        messages: const [],
        parts: const [],
        mcpServers: const [],
      ),
      myDeviceId: 'me',
      peerDeviceId: 'peer',
      checkpointRows: const {},
    );
  }

  Future<({String? hash, int watermark})> readLocal([
    String id = conversationId,
  ]) async {
    final row = await (database.select(
      database.conversationRows,
    )..where((t) => t.id.equals(id))).getSingle();
    return (
      hash: row.injectedMemoryHash,
      watermark: row.lastMemoryExtractedOrder,
    );
  }

  test('the wire row carries no memory hash', () async {
    await seedLocal(injectedMemoryHash: 'mine000000000001', watermark: 4);
    final wire = await repository.syncReadWireConversationRow(conversationId);
    expect(wire, isNotNull);
    expect(wire!.containsKey('injected_memory_hash'), isFalse);
    expect(wire['last_memory_extracted_order'], 4);
  });

  test('an incoming row never overwrites the local memory hash', () async {
    await seedLocal(injectedMemoryHash: 'mine000000000001', watermark: 4);
    // Newer on the wire, so it wins the row — and would carry the peer's hash
    // over here if the column had travelled.
    await apply(updatedAtUs: 2000, watermark: 4);
    final local = await readLocal();
    expect(local.hash, 'mine000000000001');
    expect(local.watermark, 4);
  });

  test('the extraction watermark joins with max, not last-write-wins', () async {
    await seedLocal(injectedMemoryHash: null, watermark: 9);
    // The peer's row is newer but its watermark is behind ours: replacing ours
    // would re-read messages this device already extracted.
    await apply(updatedAtUs: 2000, watermark: 3);
    expect((await readLocal()).watermark, 9);

    // And the other direction: the peer is ahead, so its watermark counts even
    // though ours would otherwise win outright.
    await apply(updatedAtUs: 3000, watermark: 12);
    expect((await readLocal()).watermark, 12);
  });

  test(
    'a conversation arriving from a peer keeps its shared watermark',
    () async {
      await apply(updatedAtUs: 2000, watermark: 5, id: 'fresh');
      final fresh = await readLocal('fresh');
      expect(fresh.watermark, 5);
      expect(fresh.hash, isNull);
    },
  );
}
