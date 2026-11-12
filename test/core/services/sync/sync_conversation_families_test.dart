import 'package:Cuplivo/core/database/app_database.dart';
import 'package:Cuplivo/core/database/chat_database_repository.dart';
import 'package:Cuplivo/core/models/conversation.dart';
import 'package:Cuplivo/core/services/sync/sync_family_registry.dart';
import 'package:Cuplivo/core/services/sync/sync_models.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../../support/sync_payload.dart';

/// The conversation's own families, and the rule that applies them (D-7).
///
/// These four families — the compression history, the image-context switches,
/// the compression configuration and the provider artifacts — were device-local
/// until this protocol version. Each is stored as **one row per conversation**,
/// so a divergence between the two devices cannot be merged row by row: the newer
/// copy replaces the older whole. What matters here is that the replacement
/// happens and is *counted*, and that a row claiming to belong elsewhere is
/// refused.
void main() {
  late AppDatabase database;
  late ChatDatabaseRepository repository;
  const conversationId = 'conv';

  final contextFamily = syncFamilyFor(
    'extension_entity_rows',
    kind: 'conversationContext',
  )!;
  final imageContextFamily = syncFamilyFor(
    'extension_entity_rows',
    kind: 'conversationImageContext',
  )!;
  final artifactsFamily = syncFamilyOfTable('provider_artifact_rows');

  setUp(() async {
    database = AppDatabase(NativeDatabase.memory());
    repository = ChatDatabaseRepository(database);
    await repository.ensureReady();
    // A subtree applies onto a conversation this device already has (or one it
    // deleted and is being handed back), so the fixture seeds it through the
    // repository's own path: the conversation row's NOT NULL columns are the
    // app's business, not the wire's.
    await repository.putMigrationBatch(
      conversations: [Conversation(id: conversationId, title: conversationId)],
      messages: const [],
      toolEventsByMessageId: const {},
      geminiSignaturesByMessageId: const {},
    );
  });

  tearDown(() => database.close());

  Map<String, dynamic> conversationRow() => {
    'id': conversationId,
    'title': conversationId,
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

  /// An `extension_entity_rows` document as the sender's `SELECT *` produces it.
  Map<String, dynamic> documentRow({
    required String kind,
    required String payload,
    required int updatedAt,
    String id = conversationId,
  }) => {
    'kind': kind,
    'id': id,
    'sort_order': 0,
    'owner_id': id,
    'payload': payload,
    'updated_at': updatedAt,
  };

  /// Wire rows carry every column, and an artifact hangs off a revision: the
  /// schema cascades `provider_artifact_rows.revision_id`, so a fixture without
  /// its message would fail for a reason the protocol cannot produce.
  Map<String, dynamic> messageRow(
    String id,
    int timestampUs, {
    int order = 0,
  }) => {
    'id': id,
    'conversation_id': conversationId,
    'role': 'assistant',
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
    'updated_at': timestampUs,
    'sender_id': null,
    'extras_json': '{}',
  };

  SyncSubtreePayload payloadWith(
    Map<String, List<Map<String, dynamic>>> families,
  ) => subtreePayload(
    conversation: conversationRow(),
    // Built over the registry's own family names, so a rename cannot leave this
    // test asserting against a key nothing writes.
    families: families,
  );

  Future<SyncSubtreeApplyOutcome> apply(SyncSubtreePayload payload) =>
      repository.syncApplySubtree(
        payload: payload,
        myDeviceId: 'me',
        peerDeviceId: 'peer',
        checkpointRows: const {},
      );

  Future<List<Map<String, dynamic>>> documents(SyncFamily family) =>
      repository.syncReadFamilyRows(family, conversationId);

  test('a conversation document arrives with the subtree', () async {
    await apply(
      payloadWith({
        contextFamily.name: [
          documentRow(
            kind: contextFamily.kind!,
            payload: '{"ops":[{"id":"op1"}]}',
            updatedAt: 100,
          ),
        ],
      }),
    );

    final read = await documents(contextFamily);
    expect(read, hasLength(1));
    expect(read.single['payload'], '{"ops":[{"id":"op1"}]}');
  });

  test(
    'the newer document replaces the older, and the report counts it',
    () async {
      await apply(
        payloadWith({
          contextFamily.name: [
            documentRow(
              kind: contextFamily.kind!,
              payload: '{"ops":["mine"]}',
              updatedAt: 100,
            ),
          ],
        }),
      );

      final outcome = await apply(
        payloadWith({
          contextFamily.name: [
            documentRow(
              kind: contextFamily.kind!,
              payload: '{"ops":["theirs"]}',
              updatedAt: 200,
            ),
          ],
        }),
      );

      final read = await documents(contextFamily);
      expect(read.single['payload'], '{"ops":["theirs"]}');
      expect(
        outcome.documentsReplaced,
        1,
        reason:
            'this device had a compression history of its own and lost it; the '
            'report is the only place that can say so',
      );
    },
  );

  test('an older document is refused', () async {
    await apply(
      payloadWith({
        contextFamily.name: [
          documentRow(
            kind: contextFamily.kind!,
            payload: '{"ops":["mine"]}',
            updatedAt: 200,
          ),
        ],
      }),
    );

    final outcome = await apply(
      payloadWith({
        contextFamily.name: [
          documentRow(
            kind: contextFamily.kind!,
            payload: '{"ops":["stale"]}',
            updatedAt: 100,
          ),
        ],
      }),
    );

    expect(
      (await documents(contextFamily)).single['payload'],
      '{"ops":["mine"]}',
    );
    expect(outcome.documentsReplaced, 0);
  });

  test('an echo of the same document at a newer clock is not a loss', () async {
    const document = '{"ops":["same"]}';
    await apply(
      payloadWith({
        contextFamily.name: [
          documentRow(
            kind: contextFamily.kind!,
            payload: document,
            updatedAt: 100,
          ),
        ],
      }),
    );

    final outcome = await apply(
      payloadWith({
        contextFamily.name: [
          documentRow(
            kind: contextFamily.kind!,
            payload: document,
            updatedAt: 200,
          ),
        ],
      }),
    );

    expect(
      outcome.documentsReplaced,
      0,
      reason:
          'a bothSend echoes our own row back; nothing of ours was replaced',
    );
  });

  test('a document claiming another conversation is dropped', () async {
    await apply(
      payloadWith({
        contextFamily.name: [
          documentRow(
            kind: contextFamily.kind!,
            payload: '{"ops":["smuggled"]}',
            updatedAt: 100,
            id: 'someone-else',
          ),
        ],
      }),
    );

    expect(await documents(contextFamily), isEmpty);
  });

  test('a document claiming another kind is dropped', () async {
    await apply(
      payloadWith({
        contextFamily.name: [
          // The row travels under the compression-history key while claiming to
          // be the image context: a crafted cross-reference no honest peer can
          // produce, since its own reader filters by kind.
          documentRow(
            kind: imageContextFamily.kind!,
            payload: '{"auto":true}',
            updatedAt: 100,
          ),
        ],
      }),
    );

    expect(await documents(contextFamily), isEmpty);
    expect(await documents(imageContextFamily), isEmpty);
  });

  test('provider artifacts ride the subtree and merge per row', () async {
    Map<String, dynamic> artifact(String payload, int updatedAt) => {
      'conversation_id': conversationId,
      'revision_id': 'm1',
      'kind': 'signature',
      'payload': payload,
      'created_at': 1,
      'updated_at': updatedAt,
    };

    SyncSubtreePayload payload(Map<String, dynamic> row) => subtreePayload(
      conversation: conversationRow(),
      messages: [messageRow('m1', 1)],
      families: {
        artifactsFamily.name: [row],
      },
    );

    await apply(payload(artifact('first', 100)));
    final outcome = await apply(payload(artifact('second', 200)));

    final read = await documents(artifactsFamily);
    expect(read.single['payload'], 'second');
    expect(outcome.documentsReplaced, 1);
  });
}
