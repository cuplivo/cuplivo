import 'package:Cuplivo/core/database/app_database.dart';
import 'package:Cuplivo/core/database/chat_database_repository.dart';
import 'package:Cuplivo/core/models/chat_message.dart';
import 'package:Cuplivo/core/models/conversation.dart';
import 'package:Cuplivo/core/services/sync/sync_models.dart';
import 'package:drift/drift.dart' show Variable;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

/// Regressions for the order re-derivation inside a sync apply. Both were found
/// on a real device, and neither was visible to a test that compares message id
/// sets: one aborts the session with a unique-constraint failure, the other
/// silently leaves orders in the shifted range.
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

  /// Wire rows carry every column (the sender does `SELECT *`), so the fixtures
  /// do too: a missing NOT NULL column would fail for a reason the protocol
  /// cannot actually produce.
  Map<String, dynamic> conversationRow() => {
    'id': conversationId,
    'title': conversationId,
    'created_at': 1,
    'updated_at': 999999999,
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

  Map<String, dynamic> messageRow(
    String id,
    int timestampUs, {
    int order = 0,
    String role = 'user',
  }) => {
    'id': id,
    'conversation_id': conversationId,
    'role': role,
    'timestamp': timestampUs,
    'model_id': null,
    'provider_id': null,
    'total_tokens': null,
    'is_streaming': 0,
    'reasoning_start_at': null,
    'reasoning_finished_at': null,
    'translation': null,
    'reasoning_segments_json': null,
    'group_id': null,
    'version': 0,
    'prompt_tokens': null,
    'completion_tokens': null,
    'cached_tokens': null,
    'duration_ms': null,
    'message_order': order,
    'updated_at': null,
    'sender_id': null,
    // NOT NULL with a default: an explicit null defeats the default, and a
    // real wire row always carries the stored value.
    'extras_json': '{}',
  };

  Map<String, dynamic> partRow(String revisionId, int timestampUs) => {
    'conversation_id': conversationId,
    'revision_id': revisionId,
    'ordinal': 0,
    'kind': 'text',
    'payload': revisionId,
    'created_at': timestampUs,
    'updated_at': timestampUs,
  };

  SyncSubtreePayload payloadOf(
    List<({String id, int order, int timestampUs})> rows,
  ) => SyncSubtreePayload(
    conversation: conversationRow(),
    messages: [
      for (final row in rows)
        messageRow(row.id, row.timestampUs, order: row.order),
    ],
    parts: [for (final row in rows) partRow(row.id, row.timestampUs)],
  );

  /// Seeds rows with explicit orders and timestamps, so a test can create the
  /// stored-order/timestamp-order mismatch the re-derivation has to fix.
  Future<void> seed(
    List<({String id, int order, int timestampUs})> rows,
  ) async {
    await repository.putMigrationBatch(
      conversations: [
        Conversation(
          id: conversationId,
          title: conversationId,
        ).copyWith(messageIds: [for (final row in rows) row.id]),
      ],
      messages: [
        for (final row in rows)
          (
            message: ChatMessage(
              id: row.id,
              conversationId: conversationId,
              role: 'user',
              content: row.id,
              timestamp: DateTime.fromMicrosecondsSinceEpoch(row.timestampUs),
            ),
            messageOrder: row.order,
          ),
      ],
      toolEventsByMessageId: const {},
      geminiSignaturesByMessageId: const {},
    );
  }

  Future<List<({String id, int order})>> storedOrder() async {
    final rows = await database
        .customSelect(
          'SELECT id, message_order FROM message_rows '
          'WHERE conversation_id = ? ORDER BY message_order, id;',
          variables: [Variable.withString(conversationId)],
        )
        .get();
    return [
      for (final row in rows)
        (id: row.read<String>('id'), order: row.read<int>('message_order')),
    ];
  }

  Future<SyncSubtreeApplyOutcome> apply(SyncSubtreePayload payload) =>
      repository.syncApplySubtree(
        payload: payload,
        myDeviceId: 'me',
        peerDeviceId: 'peer',
        checkpointRows: const {},
      );

  test('a swap among stored rows does not trip the unique key', () async {
    // Stored order disagrees with timestamp order: m1 (newer) sits first, so a
    // re-derivation wants to swap the two. The peer's rows are older, so they
    // all lose LWW — no upserts, no deletions — which is exactly the case that
    // used to swap the two orders in place under the unique key.
    await seed([
      (id: 'm1', order: 0, timestampUs: 2000000),
      (id: 'm2', order: 1, timestampUs: 1000000),
    ]);

    final outcome = await apply(
      payloadOf([
        (id: 'm1', order: 0, timestampUs: 1500000),
        (id: 'm2', order: 1, timestampUs: 500000),
      ]),
    );

    expect(outcome.deferred, isFalse);
    expect(await storedOrder(), [
      (id: 'm2', order: 0),
      (id: 'm1', order: 1),
    ], reason: 'timestamp order wins, and no order may collide on the way');
  });

  test(
    'an apply that inserts still lands every row in the final range',
    () async {
      await seed([
        (id: 'm1', order: 0, timestampUs: 1000000),
        (id: 'm2', order: 1, timestampUs: 2000000),
      ]);

      // One new row arrives; the two local rows keep their positions, which is
      // the case the old skip-optimisation mis-handled by leaving them shifted.
      await apply(
        SyncSubtreePayload(
          conversation: conversationRow(),
          messages: [messageRow('m3', 3000000, order: 2, role: 'assistant')],
          parts: [partRow('m3', 3000000)],
        ),
      );

      expect(await storedOrder(), [
        (id: 'm1', order: 0),
        (id: 'm2', order: 1),
        (id: 'm3', order: 2),
      ], reason: 'an inserted row must not leave the shifted locals behind');
    },
  );

  test(
    'an already-shifted conversation is repaired, not collided with',
    () async {
      // The state the old build could leave behind: orders far above the count.
      // The peer's rows are older, so nothing is upserted and the repair is the
      // only thing this apply does.
      await seed([
        (id: 'm1', order: 1000000, timestampUs: 2000000),
        (id: 'm2', order: 1000001, timestampUs: 3000000),
      ]);

      await apply(
        payloadOf([
          (id: 'm1', order: 1000000, timestampUs: 1000000),
          (id: 'm2', order: 1000001, timestampUs: 1500000),
        ]),
      );

      expect(await storedOrder(), [(id: 'm1', order: 0), (id: 'm2', order: 1)]);
    },
  );
}
