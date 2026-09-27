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
    String? groupId,
    int version = 0,
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
    'group_id': groupId,
    'version': version,
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

  test('a stored order that disagrees with timestamps is left alone', () async {
    // Stored order disagrees with timestamp order: m1 (newer) sits first. That
    // placement is the app's own — a revision moved onto the slot its deleted
    // sibling held — so the apply must not re-derive it away. The peer's rows
    // are older, so they all lose LWW and the apply's only decision is the
    // order.
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
    expect(
      await storedOrder(),
      [(id: 'm1', order: 0), (id: 'm2', order: 1)],
      reason: 'the carried slot leads, not the timestamp',
    );
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

      expect(
        await storedOrder(),
        [(id: 'm1', order: 0), (id: 'm2', order: 1), (id: 'm3', order: 2)],
        reason: 'an inserted row must not leave the shifted locals behind',
      );
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

  Future<List<({String id, String? groupId, int version})>> storedSlots() async {
    final rows = await database
        .customSelect(
          'SELECT id, group_id, version FROM message_rows '
          'WHERE conversation_id = ? ORDER BY id;',
          variables: [Variable.withString(conversationId)],
        )
        .get();
    return [
      for (final row in rows)
        (
          id: row.read<String>('id'),
          groupId: row.read<String?>('group_id'),
          version: row.read<int>('version'),
        ),
    ];
  }

  test('rival regenerations converge on one row per version slot', () async {
    // Both devices regenerated the same message: m3 here, m2 there, same group
    // and version, different ids. Merging by id keeps both, and the schema's
    // UNIQUE(conversation_id, group_id, version) then fails the insert — which
    // aborted the apply and, because the checkpoint is never written, every
    // later session of that pair too.
    await repository.putMigrationBatch(
      conversations: [
        Conversation(
          id: conversationId,
          title: conversationId,
        ).copyWith(messageIds: const ['m1', 'm3']),
      ],
      messages: [
        (
          message: ChatMessage(
            id: 'm1',
            conversationId: conversationId,
            role: 'user',
            content: 'm1',
            timestamp: DateTime.fromMicrosecondsSinceEpoch(1000000),
          ),
          messageOrder: 0,
        ),
        (
          message: ChatMessage(
            id: 'm3',
            conversationId: conversationId,
            role: 'assistant',
            content: 'mine',
            timestamp: DateTime.fromMicrosecondsSinceEpoch(3000000),
            groupId: 'm1',
            version: 1,
          ),
          messageOrder: 1,
        ),
      ],
      toolEventsByMessageId: const {},
      geminiSignaturesByMessageId: const {},
    );

    final incoming = SyncSubtreePayload(
      conversation: conversationRow(),
      messages: [
        messageRow('m1', 1000000, order: 0),
        messageRow(
          'm2',
          2000000,
          order: 1,
          role: 'assistant',
          groupId: 'm1',
          version: 1,
        ),
      ],
      parts: [partRow('m1', 1000000), partRow('m2', 2000000)],
    );

    final outcome = await apply(incoming);
    expect(outcome.deferred, isFalse);
    // The newer mutation clock keeps the slot; the rival row is gone with its
    // parts, and the report counts it rather than dropping it in silence.
    expect(await storedSlots(), [
      (id: 'm1', groupId: null, version: 0),
      (id: 'm3', groupId: 'm1', version: 1),
    ]);
    expect(outcome.deletedMessages, 1);

    // Converged: the same payload applied again is a no-op, because the losing
    // side computes the identical verdict.
    final again = await apply(incoming);
    expect(again.deferred, isFalse);
    expect(await storedSlots(), [
      (id: 'm1', groupId: null, version: 0),
      (id: 'm3', groupId: 'm1', version: 1),
    ]);
  });

  test('a deliberate anchor placement survives a peer-side change', () async {
    // The app's own repair: the user edited a mid-conversation message and
    // deleted the version it replaced, so the surviving revision was moved onto
    // the freed anchor slot (order 1) although its timestamp is the newest.
    await seed([
      (id: 'm0', order: 0, timestampUs: 1000000),
      (id: 'm3', order: 1, timestampUs: 3000000),
      (id: 'm2', order: 2, timestampUs: 2000000),
    ]);

    // An unrelated peer edit, which is enough to make the apply re-derive every
    // order — the step that used to sort by (timestamp, id) and drop m3 below
    // m2 for good, since the order is in no digest.
    final edited = messageRow('m0', 1000000, order: 0);
    edited['updated_at'] = 2000000;
    await apply(
      SyncSubtreePayload(
        conversation: conversationRow(),
        messages: [edited],
        parts: [partRow('m0', 1000000)],
      ),
    );

    expect(await storedOrder(), [
      (id: 'm0', order: 0),
      (id: 'm3', order: 1),
      (id: 'm2', order: 2),
    ]);
  });

  test('a tie on the slot clock falls to the higher row id, on both peers',
      () async {
    // Same clock on both rivals: only a device-independent rule can decide, and
    // both peers must decide identically without negotiating.
    await repository.putMigrationBatch(
      conversations: [
        Conversation(
          id: conversationId,
          title: conversationId,
        ).copyWith(messageIds: const ['g1']),
      ],
      messages: [
        (
          message: ChatMessage(
            id: 'g1',
            conversationId: conversationId,
            role: 'assistant',
            content: 'g1',
            timestamp: DateTime.fromMicrosecondsSinceEpoch(1000000),
            groupId: 'g1',
            version: 1,
          ),
          messageOrder: 0,
        ),
      ],
      toolEventsByMessageId: const {},
      geminiSignaturesByMessageId: const {},
    );

    final outcome = await apply(
      SyncSubtreePayload(
        conversation: conversationRow(),
        messages: [
          messageRow(
            'g0',
            1000000,
            order: 0,
            role: 'assistant',
            groupId: 'g1',
            version: 1,
          ),
        ],
        parts: [partRow('g0', 1000000)],
      ),
    );

    expect(outcome.deferred, isFalse);
    expect(await storedSlots(), [
      (id: 'g1', groupId: 'g1', version: 1),
    ], reason: 'the higher row id keeps the slot at a tied clock');
  });
}
